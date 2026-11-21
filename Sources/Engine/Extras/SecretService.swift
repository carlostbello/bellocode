import BelloCore
import Darwin
import Foundation
import Observation
import Security
import os

/// Where secret values live. The value is only ever passed as `SecretValue` (redacted description).
public protocol SecretVault: Sendable {
    func store(account: String, label: String, value: SecretValue) throws
    func read(account: String) throws -> SecretValue?
    func delete(account: String) throws
}

/// The Security framework calls a vault makes (tests stand in a Keychain that refuses a step).
struct KeychainCalls: Sendable {
    var add: @Sendable (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
    var update: @Sendable (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) }
    var copy: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus = { SecItemCopyMatching($0, $1) }
    var delete: @Sendable (CFDictionary) -> OSStatus = { SecItemDelete($0) }
}

/// The macOS Keychain, generic passwords under BelloCode's own service, readable only while the Mac is unlocked and
/// never synced (`…ThisDeviceOnly`).
public struct KeychainSecretVault: SecretVault {
    /// Secrets agents asked for.
    public static let service = "app.bellocode.agent-secrets"
    public let service: String
    let calls: KeychainCalls

    public init(service: String = KeychainSecretVault.service) { self.init(service: service, calls: KeychainCalls()) }

    init(service: String, calls: KeychainCalls) {
        self.service = service
        self.calls = calls
    }

    private func base(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    /// Adds the item, or replaces an existing item's value in place. Never deletes first: if the Keychain refuses the
    /// new value (locked, access control, disk), the previous value is still there (N23).
    public func store(account: String, label: String, value: SecretValue) throws {
        let attributes: [CFString: Any] = [
            kSecValueData: value.utf8, kSecAttrLabel: "BelloCode: \(label)", kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = calls.add(base(account).merging(attributes) { _, new in new } as CFDictionary)
        if status == errSecDuplicateItem {
            status = calls.update(base(account) as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else { throw ExtrasError("The Keychain refused to save it (status \(status)).") }
    }

    public func read(account: String) throws -> SecretValue? {
        var query = base(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = calls.copy(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ExtrasError("The Keychain refused to read it (status \(status)).")
        }
        return SecretValue(data: data)
    }

    public func delete(account: String) throws {
        let status = calls.delete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ExtrasError("The Keychain refused to delete it (status \(status)).")
        }
    }
}

/// Tests and the mock app: values in memory only.
public final class InMemorySecretVault: SecretVault {
    private let values = Mutex<[String: Data]>([:])
    public init() {}
    public func store(account: String, label: String, value: SecretValue) throws { values.withLock { $0[account] = value.utf8 } }
    public func read(account: String) throws -> SecretValue? { values.withLock { $0[account] }.map(SecretValue.init(data:)) }
    public func delete(account: String) throws { _ = values.withLock { $0.removeValue(forKey: account) } }
    public var count: Int { values.withLock { $0.count } }
}

import Synchronization

/// Secrets for agents (docs/features/orchestration-extras.md). The agent asks with `request_secret`; the person types
/// the value in a card; it goes to the Keychain. The agent never receives the value: it gets a one-use reference or a
/// one-read path. The value is never in a tool result, a message, an event, a log or the store.
///
/// Delivery: a one-read named pipe (`SecretPipe`, mode 0600 in a 0700 directory of the app's temporary folder). The
/// app holds both ends from creation, so a reader's `open` returns at once and its reads end with end-of-file the
/// moment the pipe is spent, expires (`fileLifetime`) or is cancelled; no reader can wait on it forever. A command uses
/// it as `--token-file PATH` or `"$(cat PATH)"`. Limits: anything running as the user could read it first (the agent's
/// command then gets an empty value, which is visible), and a command that prints the value puts it in the transcript;
/// the guidance tells agents never to print it.
///
/// Each service instance has its own directory (`<root>/<pid>.<random>`); `load()` removes directories left by dead
/// processes and wakes any reader stuck on them.
@MainActor
@Observable
public final class SecretService {
    public private(set) var labels: [StoredSecretLabel] = []
    public private(set) var lastError: String?

    /// A one-use reference, valid for its session only.
    struct Reference {
        var account: String
        var label: String
        var sessionID: SessionID
        var expires: Date
        /// The secret's command-policy revision at issue (R03).
        var revision: String
    }

    nonisolated public static let referencePrefix = "bcsecret_"
    nonisolated public static let referenceLifetime: TimeInterval = 3_600
    nonisolated public static let fileLifetime: TimeInterval = 600
    nonisolated public static let maxReferences = 64
    nonisolated public static let maxPipes = 16
    /// The largest value a pipe can hold without a reader draining it (macOS FIFO buffer).
    nonisolated public static let maxValueBytes = SecretPipe.capacity

    @ObservationIgnored private let vault: any SecretVault
    @ObservationIgnored private let store: ProjectionStore
    @ObservationIgnored private let clock: any WallClock
    @ObservationIgnored private var references: [String: Reference] = [:]
    @ObservationIgnored private var pipes: [String: SecretPipe] = [:]
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let sweepWindow: Duration
    @ObservationIgnored private let log = Logger(subsystem: "app.bellocode", category: "secrets")

    /// `root` holds one directory per service instance; the default is `bellocode-secrets` in the user's temporary
    /// folder. Tests pass their own root.
    public init(
        vault: any SecretVault, store: ProjectionStore, clock: any WallClock, root: URL? = nil,
        sweepWindow: Duration = SecretPipe.defaultSweepWindow
    ) {
        self.vault = vault
        self.store = store
        self.clock = clock
        self.root = root ?? FileManager.default.temporaryDirectory.appending(path: "bellocode-secrets", directoryHint: .isDirectory)
        let instance = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        self.directory = self.root.appending(path: "\(getpid()).\(instance)", directoryHint: .isDirectory)
        self.sweepWindow = sweepWindow
    }

    /// Launch: loads labels and removes pipe directories left behind by a crashed or killed app.
    public func load() async {
        await SecretPipe.removeStale(root: root, legacyParent: FileManager.default.temporaryDirectory)
        labels = (try? await store.secretLabels()) ?? []
    }

    public func shutdown() {
        for pipe in pipes.values { pipe.cancel() }
        pipes.removeAll()
        references.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    public func hasSaved(label: String) -> Bool { labels.contains { $0.label.caseInsensitiveCompare(label) == .orderedSame } }

    /// Deletes a saved secret (Keychain item and label). Cannot be undone; references to it stop working.
    public func delete(account: String) async {
        do {
            try vault.delete(account: account)
            try await store.deleteSecretLabel(account: account)
            // Commands approved "always" for this secret lose their approval with it.
            try await store.deleteGrants(.secretCommand, scopePrefix: account + "\n")
            references = references.filter { $0.value.account != account }
            labels.removeAll { $0.account == account }
            lastError = nil
        } catch {
            lastError = ExtrasError.message(error)
        }
    }

    // MARK: Saving and delivery

    /// Saves (or replaces) the value under `label` and returns the Keychain account.
    func save(label: String, value: SecretValue) async throws -> String {
        guard !value.isEmpty else { throw ExtrasError("The value is empty.") }
        guard value.utf8.count <= Self.maxValueBytes else {
            throw ExtrasError("The value is longer than \(Self.maxValueBytes / 1024) KB, the most a one-read path can carry.")
        }
        let existing = labels.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }
        let account = existing?.account ?? "bcs_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try vault.store(account: account, label: label, value: value)
        let row = StoredSecretLabel(account: account, label: label, created: existing?.created ?? clock.now(), lastUsed: clock.now())
        try await store.saveSecretLabel(row)
        labels.removeAll { $0.account == account }
        labels.append(row)
        labels.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        log.info("secret saved under a label (value not logged)")
        return account
    }

    func account(forLabel label: String) -> String? {
        labels.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }?.account
    }

    /// A fresh one-use reference to `account` for `sessionID`.
    func issueReference(account: String, label: String, for sessionID: SessionID, revision: String = "") -> String {
        let now = clock.now()
        references = references.filter { $0.value.expires > now }
        if references.count >= Self.maxReferences, let oldest = references.min(by: { $0.value.expires < $1.value.expires })?.key {
            references[oldest] = nil
        }
        let reference = Self.referencePrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        references[reference] = Reference(account: account, label: label, sessionID: sessionID, expires: now.addingTimeInterval(Self.referenceLifetime), revision: revision)
        return reference
    }

    /// Exchanges a reference (once) for a one-read pipe path. Only the session it was issued to may use it, and only
    /// while `currentRevision` (the secret's command policy now; nil: not usable by commands) still equals the
    /// revision it was issued under (R03).
    func redeem(_ reference: String, by sessionID: SessionID, currentRevision: ((String) -> String?)? = nil) throws -> (path: String, label: String) {
        guard let entry = references[reference], entry.expires > clock.now() else {
            references[reference] = nil
            throw ExtrasError("That secretRef is unknown, used or expired. Ask again with request_secret.")
        }
        guard entry.sessionID == sessionID else { throw ExtrasError("That secretRef belongs to another thread.") }
        references[reference] = nil
        if let currentRevision, currentRevision(entry.account) != entry.revision {
            throw ExtrasError("“\(entry.label)” changed since this secretRef was issued (its protection, scope or value). Nothing was delivered; ask again with request_secret.")
        }
        return (try deliverFile(account: entry.account), entry.label)
    }

    /// Creates the one-read pipe for `account` and starts filling it. Returns its path.
    func deliverFile(account: String) throws -> String {
        pipes = pipes.filter { !$0.value.isFinished }
        guard pipes.count < Self.maxPipes else { throw ExtrasError("Too many secret files are waiting to be read. Use or let them expire first.") }
        for url in [root, directory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(url.path, 0o700)
        }
        let name = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let path = directory.appending(path: name).path
        let pipe = try SecretPipe(path: path, deadline: clock.now().addingTimeInterval(Self.fileLifetime), clock: clock, sweepWindow: sweepWindow)
        let vault = self.vault
        pipe.start { try? vault.read(account: account) }
        pipes[path] = pipe
        return path
    }

    func touch(account: String) async {
        guard let index = labels.firstIndex(where: { $0.account == account }) else { return }
        labels[index].lastUsed = clock.now()
        try? await store.saveSecretLabel(labels[index])
    }

    /// Pipes not yet spent, expired or cancelled (the bound `maxPipes` counts these).
    var pendingPipeCount: Int { pipes.values.filter { !$0.isFinished }.count }
    /// The directory this instance creates pipes in (tests).
    var pipeDirectory: URL { directory }
}

/// One one-read named pipe for a secret value.
///
/// The pipe is opened by the app at creation for reading and for writing (both non-blocking, close-on-exec), so:
/// - a reader's blocking `open` returns at once (a writer exists), never waiting on the app;
/// - the value is written into the pipe's kernel buffer once, as soon as the vault returns it (never to disk);
/// - when the buffer is drained (the value was read), at the deadline, or on cancellation the pipe *finishes*:
///   unread bytes are discarded, the path is renamed away (new opens fail with ENOENT) and both ends are closed, so every
///   attached reader gets end-of-file at once;
/// - a reader that resolved the path just before the rename and enters `open` after the close would wait for a writer
///   forever, so for `sweepWindow` after finishing the app opens the renamed node for writing whenever a reader is
///   waiting on it (a non-blocking open for writing succeeds only then), which wakes it to an immediate end-of-file.
///
/// Readers are watched by polling `FIONREAD` every `tickInterval` on a private serial queue (not the Swift cooperative
/// pool, so a busy app cannot delay an end-of-file), paced by a ticker thread of the pipe's own that sleeps between
/// ticks: uptime-clock dispatch timers were seen never to fire on macOS 27 while the process was otherwise idle, which
/// left a reader that had the value waiting for its end-of-file. The thread ends when the pipe is finished. A crash closes both ends (attached readers get end-of-file); the
/// node itself is removed, and its waiters woken, by `removeStale` on the next launch.
public final class SecretPipe: Sendable {
    /// The most a non-blocking write puts into a macOS FIFO.
    public static let capacity = 8_192
    public static let defaultSweepWindow: Duration = .milliseconds(250)
    static let tickInterval: TimeInterval = 0.02

    private enum Phase: Sendable {
        case filling
        case live
        /// Finished; still waking late openers of the renamed node until `until`. `waker` is a write end held for one tick.
        case sweeping(until: ContinuousClock.Instant, waker: Int32?)
        case finished
    }

    private struct State: Sendable {
        var phase: Phase = .filling
        var readFD: Int32
        var writeFD: Int32
    }

    let path: String
    private let spentPath: String
    private let deadline: Date
    private let clock: any WallClock
    private let sweepWindow: Duration
    private let queue = DispatchQueue(label: "app.bellocode.secret-pipe", qos: .utility)
    private let state: Mutex<State>

    init(path: String, deadline: Date, clock: any WallClock, sweepWindow: Duration = SecretPipe.defaultSweepWindow) throws {
        guard mkfifo(path, 0o600) == 0 else { throw ExtrasError("Could not create the secret file (errno \(errno)).") }
        let readFD = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        let writeFD = readFD >= 0 ? open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC) : -1
        guard readFD >= 0, writeFD >= 0 else {
            let code = errno
            if readFD >= 0 { close(readFD) }
            unlink(path)
            throw ExtrasError("Could not open the secret file (errno \(code)).")
        }
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        self.path = path
        let url = URL(fileURLWithPath: path)
        spentPath = url.deletingLastPathComponent().appending(path: ".spent-" + url.lastPathComponent).path
        self.deadline = deadline
        self.clock = clock
        self.sweepWindow = sweepWindow
        state = Mutex(State(readFD: readFD, writeFD: writeFD))
    }

    /// Reads the value off the main thread (a Keychain read may wait for the user) and writes it into the pipe once.
    func start(value: @escaping @Sendable () -> SecretValue?) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let secret = value()
            queue.async { self.fill(secret) }
        }
        scheduleTick()
    }

    /// Finishes now: attached readers get end-of-file, the path disappears.
    func cancel() { state.withLock { finish(&$0) } }

    /// Fully done: closed, swept and removed.
    var isFinished: Bool {
        state.withLock { if case .finished = $0.phase { true } else { false } }
    }

    /// Spent, expired or cancelled: its path is gone and attached readers have end-of-file (may still be sweeping).
    var isSpent: Bool {
        state.withLock {
            switch $0.phase {
            case .filling, .live: false
            case .sweeping, .finished: true
            }
        }
    }

    private func fill(_ secret: SecretValue?) {
        state.withLock { state in
            guard case .filling = state.phase else { return }
            guard let secret, !secret.isEmpty, secret.utf8.count <= Self.capacity else { return finish(&state) }
            let written = secret.utf8.withUnsafeBytes { write(state.writeFD, $0.baseAddress!, $0.count) }
            if written == secret.utf8.count { state.phase = .live } else { finish(&state) }
        }
    }

    private func scheduleTick() {
        Thread.detachNewThread { [self] in
            repeat {
                Thread.sleep(forTimeInterval: Self.tickInterval)
            } while queue.sync(execute: { tick() })
        }
    }

    /// One step of the state machine; false once finished.
    private func tick() -> Bool {
        state.withLock { state in
            switch state.phase {
            case .filling:
                if clock.now() >= deadline { finish(&state) }
            case .live:
                if clock.now() >= deadline || Self.available(state.readFD) == 0 { finish(&state) }
            case .sweeping(let until, let waker):
                if let waker {
                    close(waker)
                    state.phase = .sweeping(until: until, waker: nil)
                } else if ContinuousClock.now < until {
                    let fd = open(spentPath, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
                    if fd >= 0 {
                        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                        state.phase = .sweeping(until: until, waker: fd)
                    }
                } else {
                    unlink(spentPath)
                    state.phase = .finished
                    return false
                }
            case .finished:
                return false
            }
            return true
        }
    }

    /// Discards unread bytes, renames the node away and closes both ends.
    private func finish(_ state: inout State) {
        switch state.phase {
        case .filling, .live: break
        case .sweeping, .finished: return
        }
        var scratch = [UInt8](repeating: 0, count: 1_024)
        while read(state.readFD, &scratch, scratch.count) > 0 {}
        scratch.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
        if rename(path, spentPath) != 0 { unlink(path) }
        close(state.writeFD)
        close(state.readFD)
        state.readFD = -1
        state.writeFD = -1
        state.phase = .sweeping(until: ContinuousClock.now + sweepWindow, waker: nil)
    }

    /// `FIONREAD` (`_IOR('f', 127, int)`), a macro Swift does not import.
    private static let fionread: UInt = 0x4004_667F

    private static func available(_ fd: Int32) -> Int32 {
        var count: Int32 = 0
        return ioctl(fd, fionread, &count) == 0 ? count : -1
    }

    // MARK: Launch cleanup

    /// Removes per-instance directories under `root` whose process is gone (and the older `bellocode-secrets-<pid>`
    /// directories in `legacyParent`), first waking any reader blocked on a pipe in them.
    nonisolated static func removeStale(root: URL, legacyParent: URL) async {
        let manager = FileManager.default
        var stale: [URL] = []
        for name in (try? manager.contentsOfDirectory(atPath: root.path)) ?? [] {
            if let pid = Int32(name.split(separator: ".").first ?? ""), !isAlive(pid) { stale.append(root.appending(path: name)) }
        }
        for name in (try? manager.contentsOfDirectory(atPath: legacyParent.path)) ?? [] where name.hasPrefix("bellocode-secrets-") {
            if let pid = Int32(name.dropFirst("bellocode-secrets-".count)), !isAlive(pid) { stale.append(legacyParent.appending(path: name)) }
        }
        for directory in stale {
            for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] {
                wakeReaders(directory.appending(path: name).path)
            }
            try? manager.removeItem(at: directory)
        }
    }

    /// If a reader is blocked opening the FIFO at `path`, briefly becomes its writer so it sees end-of-file.
    static func wakeReaders(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { return }
        let fd = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 { close(fd) }
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
