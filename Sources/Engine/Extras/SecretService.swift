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

/// The macOS Keychain, generic passwords under BelloCode's own service, readable only while the Mac is unlocked and
/// never synced (`…ThisDeviceOnly`).
public struct KeychainSecretVault: SecretVault {
    public static let service = "app.bellocode.agent-secrets"

    public init() {}

    private func base(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: account]
    }

    public func store(account: String, label: String, value: SecretValue) throws {
        SecItemDelete(base(account) as CFDictionary)
        var item = base(account)
        item[kSecValueData] = value.utf8
        item[kSecAttrLabel] = "BelloCode agent secret: \(label)"
        item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ExtrasError("The Keychain refused to save it (status \(status)).") }
    }

    public func read(account: String) throws -> SecretValue? {
        var query = base(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ExtrasError("The Keychain refused to read it (status \(status)).")
        }
        return SecretValue(data: data)
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
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
/// Delivery: a named pipe (FIFO, mode 0600, in a 0700 directory of the app's temporary folder) that yields the value
/// to the first process that opens it, then is removed; unopened pipes are removed after `fileLifetime`. A command uses
/// it as `--token-file PATH` or `"$(cat PATH)"`. Limits: anything running as the user could open the pipe first (it
/// would then fail for the agent's command, which is visible), and a command that prints the value puts it in the
/// transcript; the guidance tells agents never to print it.
///
/// Threading: `@MainActor` state; pipe writes run in a short polling task owned by this service and cancelled on
/// shutdown (the pipe is removed then).
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
    }

    public static let referencePrefix = "bcsecret_"
    public static let referenceLifetime: TimeInterval = 3_600
    public static let fileLifetime: TimeInterval = 600
    public static let maxReferences = 64
    public static let maxPipes = 16

    @ObservationIgnored private let vault: any SecretVault
    @ObservationIgnored private let store: ProjectionStore
    @ObservationIgnored private let clock: any WallClock
    @ObservationIgnored private var references: [String: Reference] = [:]
    @ObservationIgnored private var pipes: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let log = Logger(subsystem: "app.bellocode", category: "secrets")

    public init(vault: any SecretVault, store: ProjectionStore, clock: any WallClock, directory: URL? = nil) {
        self.vault = vault
        self.store = store
        self.clock = clock
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appending(path: "bellocode-secrets-\(getpid())", directoryHint: .isDirectory)
    }

    public func load() async {
        labels = (try? await store.secretLabels()) ?? []
    }

    public func shutdown() {
        for task in pipes.values { task.cancel() }
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
    func issueReference(account: String, label: String, for sessionID: SessionID) -> String {
        let now = clock.now()
        references = references.filter { $0.value.expires > now }
        if references.count >= Self.maxReferences, let oldest = references.min(by: { $0.value.expires < $1.value.expires })?.key {
            references[oldest] = nil
        }
        let reference = Self.referencePrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        references[reference] = Reference(account: account, label: label, sessionID: sessionID, expires: now.addingTimeInterval(Self.referenceLifetime))
        return reference
    }

    /// Exchanges a reference (once) for a one-read pipe path. Only the session it was issued to may use it.
    func redeem(_ reference: String, by sessionID: SessionID) throws -> (path: String, label: String) {
        guard let entry = references[reference], entry.expires > clock.now() else {
            references[reference] = nil
            throw ExtrasError("That secretRef is unknown, used or expired. Ask again with request_secret.")
        }
        guard entry.sessionID == sessionID else { throw ExtrasError("That secretRef belongs to another thread.") }
        references[reference] = nil
        return (try deliverFile(account: entry.account), entry.label)
    }

    /// Creates the one-read pipe for `account` and starts feeding it. Returns its path.
    func deliverFile(account: String) throws -> String {
        guard pipes.count < Self.maxPipes else { throw ExtrasError("Too many secret files are waiting to be read. Use or let them expire first.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let path = directory.appending(path: name).path
        guard mkfifo(path, 0o600) == 0 else { throw ExtrasError("Could not create the secret file (errno \(errno)).") }
        let vault = self.vault
        let deadline = clock.now().addingTimeInterval(Self.fileLifetime)
        let clock = self.clock
        pipes[path] = Task { [weak self] in
            await SecretPipe.feed(path: path, deadline: deadline, clock: clock) { try? vault.read(account: account) }
            self?.pipes[path] = nil
        }
        return path
    }

    func touch(account: String) async {
        guard let index = labels.firstIndex(where: { $0.account == account }) else { return }
        labels[index].lastUsed = clock.now()
        try? await store.saveSecretLabel(labels[index])
    }

    /// Paths of pipes not yet read (tests).
    var pendingPipeCount: Int { pipes.count }
}

/// Feeds one named pipe: polls a non-blocking open for writing (fails with ENXIO until a reader opens it), writes the
/// value once, closes and removes the pipe. Removed without writing at the deadline or on cancellation.
enum SecretPipe {
    static func feed(path: String, deadline: Date, clock: any WallClock, value: @Sendable () -> SecretValue?) async {
        defer { unlink(path) }
        while !Task.isCancelled, clock.now() < deadline {
            let fd = open(path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 {
                // One reader has it: no second reader can open a removed pipe.
                unlink(path)
                _ = fcntl(fd, F_SETFL, 0)  // blocking writes for the (small) value
                if let secret = value() {
                    secret.utf8.withUnsafeBytes { buffer in
                        var offset = 0
                        while offset < buffer.count {
                            let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                            if written <= 0 { break }
                            offset += written
                        }
                    }
                }
                close(fd)
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
