import BelloCore
import Darwin
import Foundation
import Synchronization
import Testing

@testable import Engine

/// What a `cat`-like reader of a secret path saw. Every reader in these tests has its own bounded wait, so a
/// regression fails fast (`.timedOut`) instead of hanging the suite.
enum PipeRead: Equatable, Sendable {
    case value(String)
    case empty
    case noFile(Int32)
    case timedOut
}

/// Resumes a continuation once, from whichever of the reader thread and the timeout comes first.
private final class OnceContinuation: Sendable {
    private let continuation: Mutex<CheckedContinuation<PipeRead, Never>?>
    init(_ continuation: CheckedContinuation<PipeRead, Never>) { self.continuation = Mutex(continuation) }
    func resume(_ value: PipeRead) { continuation.withLock { $0.take() }?.resume(returning: value) }
}

enum PipeReader {
    /// Opens and reads like `cat`: blocking `open(O_RDONLY)`, blocking reads to end of file, on its own thread.
    /// `afterOpen` runs once the open returned, before the first read (to force interleavings).
    static func read(
        _ path: String, timeout: Duration = .seconds(5), afterOpen: (@Sendable () -> Void)? = nil
    ) async -> PipeRead {
        await withCheckedContinuation { continuation in
            let once = OnceContinuation(continuation)
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.resume(.timedOut) }
            Thread.detachNewThread {
                let fd = open(path, O_RDONLY)
                guard fd >= 0 else {
                    once.resume(.noFile(errno))
                    return
                }
                afterOpen?()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer[0..<count])
                }
                close(fd)
                once.resume(data.isEmpty ? .empty : .value(String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

/// Runs `/bin/sh -c script sh arg` with a bounded wait; nil on timeout or failure to start.
func runShell(_ script: String, _ argument: String, timeout: Duration = .seconds(5)) async -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script, "sh", argument]
    let output = Pipe()
    process.standardOutput = output
    let finished = OnceFlag()
    let done = AsyncStream<Void>.makeStream()
    process.terminationHandler = { _ in done.continuation.yield(); done.continuation.finish() }
    do { try process.run() } catch { return nil }
    let timer = Task {
        try? await Task.sleep(for: timeout)
        if finished.set() { process.terminate() }
    }
    for await _ in done.stream { break }
    let timedOut = !finished.set()
    timer.cancel()
    if timedOut { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
}

final class OnceFlag: Sendable {
    private let done = Mutex(false)
    /// True for the first caller only.
    func set() -> Bool { done.withLock { was in defer { was = true }; return !was } }
    var isSet: Bool { done.withLock { $0 } }
}

/// A vault whose reads wait for `release()`, so a reader can be attached before the value exists.
final class GatedVault: SecretVault {
    let inner = InMemorySecretVault()
    private let gate = DispatchSemaphore(value: 0)
    func store(account: String, label: String, value: SecretValue) throws { try inner.store(account: account, label: label, value: value) }
    func read(account: String) throws -> SecretValue? {
        gate.wait()
        gate.signal()
        return try inner.read(account: account)
    }
    func delete(account: String) throws { try inner.delete(account: account) }
    func release() { gate.signal() }
}

func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "bc-secret-test-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// Spins (bounded) on a condition that another thread makes true.
func spin(_ timeout: Duration = .seconds(3), until condition: () -> Bool) -> Bool {
    let end = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > end { return false }
        usleep(1_000)
    }
    return true
}

/// The interleavings that hung a reader of the old feeder, which polled `open(O_WRONLY | O_NONBLOCK)` for a reader and
/// unlinked at the deadline (a reader blocked in `open` then waited forever). Each is forced, not left to timing.
@Suite(.timeLimit(.minutes(3)))
@MainActor
struct SecretPipeRaceTests {
    nonisolated static let start = Date(timeIntervalSince1970: 1_800_000_000)

    final class Fixture: Sendable {
        let clock = ManualWallClock(SecretPipeRaceTests.start)
        let directory = temporaryRoot()
        let pipe: SecretPipe
        var path: String { pipe.path }

        init(sweepWindow: Duration = SecretPipe.defaultSweepWindow) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            pipe = try SecretPipe(
                path: directory.appending(path: "p").path, deadline: clock.now().addingTimeInterval(SecretService.fileLifetime), clock: clock,
                sweepWindow: sweepWindow)
        }

        func expire() { clock.advance(by: SecretService.fileLifetime + 1) }

        deinit {
            pipe.cancel()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func readerThatOpenedBeforeTheDeadlineAndReadsAfterItGetsEndOfFile() async throws {
        let fixture = try Fixture()
        fixture.pipe.start { SecretValue("v") }
        let result = await PipeReader.read(fixture.path) {
            fixture.expire()
            #expect(spin { fixture.pipe.isSpent })
        }
        #expect(result == .empty, "the unread value is discarded at the deadline")
        try await waitUntil("swept and removed") { fixture.pipe.isFinished }
        #expect((try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)).isEmpty)
    }

    @Test func readersRacingTheDeadlineNeverHang() async throws {
        for _ in 0..<30 {
            let fixture = try Fixture(sweepWindow: .milliseconds(10))
            fixture.pipe.start { SecretValue("v") }
            async let reader = PipeReader.read(fixture.path, timeout: .seconds(3))
            fixture.expire()
            let result = await reader
            #expect([.value("v"), .empty, .noFile(ENOENT)].contains(result), "\(result)")
            try await waitUntil("finished") { fixture.pipe.isFinished }
        }
    }

    @Test func cancellingWhileAReaderWaitsForTheValueGivesEndOfFile() async throws {
        let fixture = try Fixture()
        let vault = GatedVault()
        defer { vault.release() }
        try vault.store(account: "a", label: "a", value: SecretValue("late"))
        fixture.pipe.start { try? vault.read(account: "a") }
        let opened = OnceFlag()
        async let reader = PipeReader.read(fixture.path, timeout: .seconds(3)) { _ = opened.set() }
        try await waitUntil("reader attached") { opened.isSet }
        fixture.pipe.cancel()
        #expect(await reader == .empty)
        vault.release()
        try await waitUntil("finished") { fixture.pipe.isFinished }
    }

    @Test func readerArrivingAfterExpiryFindsNoFile() async throws {
        let fixture = try Fixture()
        fixture.pipe.start { SecretValue("v") }
        fixture.expire()
        try await waitUntil("spent") { fixture.pipe.isSpent }
        #expect(await PipeReader.read(fixture.path, timeout: .seconds(3)) == .noFile(ENOENT))
    }

    @Test func twoAttachedReadersRacingGetTheValueOnceBetweenThem() async throws {
        let fixture = try Fixture()
        let vault = GatedVault()
        defer { vault.release() }
        try vault.store(account: "a", label: "a", value: SecretValue("race-value"))
        fixture.pipe.start { try? vault.read(account: "a") }
        let attached = Mutex(0)
        async let first = PipeReader.read(fixture.path, timeout: .seconds(3)) { attached.withLock { $0 += 1 } }
        async let second = PipeReader.read(fixture.path, timeout: .seconds(3)) { attached.withLock { $0 += 1 } }
        try await waitUntil("both attached") { attached.withLock { $0 } == 2 }
        vault.release()
        let results = await [first, second]
        #expect(results.filter { $0 == .value("race-value") }.count == 1, "\(results)")
        #expect(results.filter { $0 == .empty }.count == 1, "the loser gets end-of-file, not a hang: \(results)")
    }

    @Test func readerThatOpensAndClosesWithoutReadingLeavesTheValueForTheNext() async throws {
        let fixture = try Fixture()
        fixture.pipe.start { SecretValue("still-here") }
        let fd = open(fixture.path, O_RDONLY)  // a blocking open: returns at once because the app holds a writer
        #expect(fd >= 0)
        close(fd)
        #expect(await PipeReader.read(fixture.path) == .value("still-here"))
        try await waitUntil("spent after the read") { fixture.pipe.isSpent }
    }

    /// The residual kernel race (a reader resolved the path before the rename and enters `open` after both ends closed)
    /// modelled with a hard link: the sweep wakes it.
    @Test func lateOpenerOfTheSpentNodeIsWoken() async throws {
        let fixture = try Fixture(sweepWindow: .seconds(3))
        fixture.pipe.start { SecretValue("v") }
        let alias = fixture.directory.appending(path: "alias").path
        #expect(link(fixture.path, alias) == 0)
        fixture.pipe.cancel()
        #expect(await PipeReader.read(alias, timeout: .seconds(2)) == .empty)
    }

    @Test func valueAtCapacityIsDeliveredWhole() async throws {
        let fixture = try Fixture()
        let value = String(repeating: "k", count: SecretPipe.capacity)
        fixture.pipe.start { SecretValue(value) }
        #expect(await PipeReader.read(fixture.path) == .value(value))
    }
}

/// Bookkeeping, isolation between instances, shell readers and launch cleanup.
@Suite(.timeLimit(.minutes(3)))
@MainActor
struct SecretDeliveryTests {
    static func makeService(clock: any WallClock = ManualWallClock(SecretPipeRaceTests.start), root: URL) throws -> SecretService {
        SecretService(vault: InMemorySecretVault(), store: try ProjectionStore(location: .inMemory), clock: clock, root: root)
    }

    @Test func readerThatNeverArrivesLeavesNothingBehind() async throws {
        let clock = ManualWallClock(SecretPipeRaceTests.start)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try Self.makeService(clock: clock, root: root)
        let account = try await service.save(label: "x", value: SecretValue("v"))
        let path = try service.deliverFile(account: account)
        #expect(service.pendingPipeCount == 1)
        clock.advance(by: SecretService.fileLifetime + 1)
        try await waitUntil("expired") { service.pendingPipeCount == 0 }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect((try FileManager.default.contentsOfDirectory(atPath: service.pipeDirectory.path)).isEmpty, "no spent node left")
        service.shutdown()
        #expect(!FileManager.default.fileExists(atPath: service.pipeDirectory.path))
    }

    @Test func anotherInstancesShutdownDoesNotStrandAReader() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ours = try Self.makeService(root: root)
        let theirs = try Self.makeService(root: root)
        defer { ours.shutdown() }
        let account = try await ours.save(label: "x", value: SecretValue("mine"))
        let path = try ours.deliverFile(account: account)
        let other = try await theirs.save(label: "y", value: SecretValue("theirs"))
        _ = try theirs.deliverFile(account: other)
        theirs.shutdown()
        #expect(ours.pipeDirectory != theirs.pipeDirectory)
        #expect(await PipeReader.read(path, timeout: .seconds(3)) == .value("mine"))
    }

    @Test func boundOnOutstandingPipesIsReal() async throws {
        let clock = ManualWallClock(SecretPipeRaceTests.start)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try Self.makeService(clock: clock, root: root)
        defer { service.shutdown() }
        let account = try await service.save(label: "x", value: SecretValue("v"))
        var paths: [String] = []
        for _ in 0..<SecretService.maxPipes { paths.append(try service.deliverFile(account: account)) }
        #expect(throws: ExtrasError.self) { try service.deliverFile(account: account) }
        #expect(await PipeReader.read(paths[0]) == .value("v"))
        try await waitUntil("a read frees a slot") { service.pendingPipeCount == SecretService.maxPipes - 1 }
        _ = try service.deliverFile(account: account)
        clock.advance(by: SecretService.fileLifetime + 1)
        try await waitUntil("expiry frees every slot") { service.pendingPipeCount == 0 }
    }

    @Test func plainShellCommandsReadIt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try Self.makeService(root: root)
        defer { service.shutdown() }
        let value = "tok-\(UUID().uuidString)"
        let account = try await service.save(label: "x", value: SecretValue(value))
        for script in [#"v=$(cat "$1"); printf %s "${#v}""#, #"v=$(< "$1"); printf %s "${#v}""#, #"n=$(wc -c < "$1"); printf %s $n"#] {
            let path = try service.deliverFile(account: account)
            #expect(await runShell(script, path) == "\(value.utf8.count)", "\(script)")
            #expect(await runShell(#"cat "$1" 2>/dev/null; printf %s "$?""#, path) == "1", "spent: a second command finds nothing")
        }
    }

    @Test func oversizedValuesAreRefused() async throws {
        let root = temporaryRoot()
        let service = try Self.makeService(root: root)
        await #expect(throws: ExtrasError.self) {
            _ = try await service.save(label: "big", value: SecretValue(String(repeating: "x", count: SecretService.maxValueBytes + 1)))
        }
    }

    @Test func launchCleanupWakesReadersAndRemovesDeadInstancesDirectories() async throws {
        let root = temporaryRoot()
        let legacyParent = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: legacyParent)
        }
        let dead = Process()
        dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try dead.run()
        dead.waitUntilExit()
        let deadPID = dead.processIdentifier
        let stale = root.appending(path: "\(deadPID).abc")
        let legacy = legacyParent.appending(path: "bellocode-secrets-\(deadPID)")
        let live = root.appending(path: "\(getpid()).def")
        for directory in [stale, legacy, live] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let orphan = stale.appending(path: "orphan").path
        #expect(mkfifo(orphan, 0o600) == 0)
        #expect(mkfifo(legacy.appending(path: "old").path, 0o600) == 0)
        // A reader of the orphan blocks in open (no writer survives a crash) until cleanup wakes it, or finds no file if
        // cleanup ran first; either way it ends.
        async let reader = PipeReader.read(orphan, timeout: .seconds(3))
        try await Task.sleep(for: .milliseconds(50))
        await SecretPipe.removeStale(root: root, legacyParent: legacyParent)
        #expect([.empty, .noFile(ENOENT)].contains(await reader))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: live.path), "a running instance's directory is kept")
    }
}
