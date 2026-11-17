import Darwin
import Foundation
import Synchronization
import Testing
@testable import OpenCodeKit

/// A child process double. It prints a ready line on demand and exits as its behaviour says.
final class FakeProcess: ServerProcess {
    struct Behaviour: Sendable {
        var printsReadyLine = true
        var exitsOnStdinClose = true
        var exitsOnSIGTERM = true
    }

    let pid: Int32
    let port: Int
    let behaviour: Behaviour
    private let ready = OneShot<String?>()
    private let exit = OneShot<ProcessExit>()
    private let recorded = Mutex<(signals: [Int32], stdinClosed: Bool)>(([], false))

    init(pid: Int32, port: Int, behaviour: Behaviour) {
        self.pid = pid
        self.port = port
        self.behaviour = behaviour
        if behaviour.printsReadyLine { ready.fulfill(#"{"url":"http://127.0.0.1:\#(port)"}"#) }
    }

    var signals: [Int32] { recorded.withLock { $0.signals } }
    var stdinClosed: Bool { recorded.withLock { $0.stdinClosed } }

    func readyLine() async throws -> String? { try await ready.value() }
    func waitForExit() async throws -> ProcessExit { try await exit.value() }
    var exitStatus: ProcessExit? { exit.current }

    func closeStdin() {
        recorded.withLock { $0.stdinClosed = true }
        if behaviour.exitsOnStdinClose { finish(ProcessExit(reason: .exited, status: 0)) }
    }

    func signal(_ signal: Int32) {
        guard exit.current == nil else { return }
        recorded.withLock { $0.signals.append(signal) }
        if signal == SIGKILL || (signal == SIGTERM && behaviour.exitsOnSIGTERM) {
            finish(ProcessExit(reason: .signaled, status: signal))
        }
    }

    /// Simulates the child dying on its own.
    func crash() { finish(ProcessExit(reason: .signaled, status: SIGKILL)) }

    private func finish(_ status: ProcessExit) {
        ready.fulfill(nil)
        exit.fulfill(status)
    }
}

final class FakeLauncher: ServerProcessLauncher {
    private let state = Mutex<(processes: [FakeProcess], specs: [LaunchSpec])>(([], []))
    private let behaviour: @Sendable (Int) -> FakeProcess.Behaviour

    init(behaviour: @escaping @Sendable (Int) -> FakeProcess.Behaviour = { _ in .init() }) {
        self.behaviour = behaviour
    }

    var processes: [FakeProcess] { state.withLock { $0.processes } }
    var specs: [LaunchSpec] { state.withLock { $0.specs } }

    func launch(_ spec: LaunchSpec) async throws -> any ServerProcess {
        state.withLock { state in
            let index = state.processes.count
            let process = FakeProcess(pid: Int32(1000 + index), port: 5000 + index, behaviour: behaviour(index))
            state.processes.append(process)
            state.specs.append(spec)
            return process
        }
    }

    func process(onPort port: Int) -> FakeProcess? {
        state.withLock { $0.processes.first { $0.port == port } }
    }
}

/// Answers `GET /api/info` for fake processes; `pidOffset` simulates another server on the port.
struct FakeProbe: ServerInfoProbe {
    let launcher: FakeLauncher
    var pidOffset = 0

    func info(for connection: ServerConnection) async throws -> ServerInfo {
        let port = connection.baseURL.port ?? 0
        guard let process = launcher.process(onPort: port) else { throw URLError(.cannotConnectToHost) }
        return ServerInfo(version: "2.3.0", pid: Int(process.pid) + pidOffset)
    }
}

@Suite("ServerSupervisor state machine", .timeLimit(.minutes(3)))
struct ServerSupervisorTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-supervisor-tests-\(UUID().uuidString)")

    private func configuration(_ modify: (inout ServerConfiguration) -> Void = { _ in }) -> ServerConfiguration {
        var configuration = ServerConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            dataRoot: root,
            helpersDirectory: URL(fileURLWithPath: "/opt/helpers"),
            startTimeout: .seconds(20),
            stopGracePeriod: .seconds(3),
            restartBackoff: BackoffPolicy(initial: .milliseconds(200), maximum: .seconds(30), jitter: 0.2),
            maxConsecutiveFailures: 4,
            healthyAfter: .seconds(30)
        )
        modify(&configuration)
        return configuration
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// Waits for the first state matching `predicate`.
    private func waitFor(
        _ supervisor: ServerSupervisor, _ predicate: @escaping @Sendable (ServerState) -> Bool
    ) async throws -> ServerState {
        try await within(.seconds(5)) {
            for await state in await supervisor.states() where predicate(state) { return state }
            throw CancellationError()
        }
    }

    @Test func startsVerifiesAndPublishesReady() async throws {
        defer { cleanUp() }
        let launcher = FakeLauncher()
        let time = ManualTimeSource()
        let supervisor = ServerSupervisor(
            configuration: configuration(), launcher: launcher, probe: FakeProbe(launcher: launcher), time: time,
            random: { 0.5 }
        )
        let states = await supervisor.states()
        await supervisor.start()
        let seen = try await within(.seconds(5)) {
            var seen: [ServerState] = []
            for await state in states {
                seen.append(state)
                if case .ready = state { break }
            }
            return seen
        }
        #expect(seen.count == 3)
        #expect(seen.first == .stopped)
        #expect(seen.dropFirst().first == .starting(attempt: 1))
        let endpoint = try #require(seen.last?.endpoint)
        #expect(endpoint.pid == 1000)
        #expect(endpoint.generation == 1)
        #expect(endpoint.baseURL.absoluteString == "http://127.0.0.1:5000")
        #expect(try await supervisor.awaitReady() == endpoint)

        let spec = try #require(launcher.specs.first)
        #expect(spec.arguments == ["serve", "--stdio", "--port", "0"])
        #expect(spec.workingDirectory == root)
        let environment = spec.environment
        #expect(environment["XDG_CONFIG_HOME"] == root.appending(path: "config").path)
        #expect(environment["XDG_DATA_HOME"] == root.appending(path: "data").path)
        #expect(environment["XDG_STATE_HOME"] == root.appending(path: "state").path)
        #expect(environment["XDG_CACHE_HOME"] == root.appending(path: "cache").path)
        #expect(environment["HOME"] == root.appending(path: "home").path)
        #expect(environment["PATH"] == "/opt/helpers:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["OPENCODE_DISABLE_AUTOUPDATE"] == "1")
        #expect(environment["OPENCODE_CLIENT"] == "bellocode")
        #expect(environment["OPENCODE_PASSWORD"] == endpoint.connection.credentials.password)
        #expect((environment["OPENCODE_PASSWORD"]?.count ?? 0) >= 40)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "data").path))
        #expect(!environment.keys.contains("USER"))

        await supervisor.stop()
        #expect(await supervisor.state == .stopped)
        #expect(launcher.processes[0].stdinClosed)
        #expect(launcher.processes[0].signals.isEmpty)
    }

    @Test func crashRestartsWithJitteredBackoffAndANewPassword() async throws {
        defer { cleanUp() }
        let launcher = FakeLauncher()
        let time = ManualTimeSource()
        let supervisor = ServerSupervisor(
            configuration: configuration(), launcher: launcher, probe: FakeProbe(launcher: launcher), time: time,
            random: { 1.0 }
        )
        await supervisor.start()
        let first = try #require(try await waitFor(supervisor) { $0.endpoint != nil }.endpoint)

        launcher.processes[0].crash()
        let restarting = try await waitFor(supervisor) { if case .restarting = $0 { true } else { false } }
        // random 1.0 with 20 % jitter: 200 ms * 1.2.
        guard case .restarting(let attempt, let delay, let reason) = restarting else { return }
        #expect(attempt == 1)
        #expect(delay == .milliseconds(240))
        #expect(reason.contains("signal 9"))

        try await time.waitForSleepers()
        time.advance(by: delay)
        let second = try #require(try await waitFor(supervisor) { $0.endpoint?.generation == 2 }.endpoint)
        #expect(second.pid == 1001)
        #expect(second.connection.credentials != first.connection.credentials)
        #expect(launcher.specs[0].environment["OPENCODE_PASSWORD"] != launcher.specs[1].environment["OPENCODE_PASSWORD"])
        await supervisor.stop()
    }

    @Test func identityMismatchKillsTheChildAndRetries() async throws {
        defer { cleanUp() }
        let launcher = FakeLauncher()
        let time = ManualTimeSource()
        let supervisor = ServerSupervisor(
            configuration: configuration(), launcher: launcher, probe: FakeProbe(launcher: launcher, pidOffset: 7),
            time: time, random: { 0.5 }
        )
        await supervisor.start()
        let state = try await waitFor(supervisor) { if case .restarting = $0 { true } else { false } }
        guard case .restarting(_, _, let reason) = state else { return }
        #expect(reason.contains("pid 1007"))
        // The unverified child is released and killed; it is gone either way.
        #expect(launcher.processes[0].stdinClosed)
        #expect(launcher.processes[0].exitStatus != nil)
        #expect(await supervisor.endpoint == nil)
        await supervisor.stop()
    }

    @Test func silentChildTimesOutAndIsKilled() async throws {
        defer { cleanUp() }
        let launcher = FakeLauncher { index in .init(printsReadyLine: index > 0, exitsOnStdinClose: index > 0) }
        let time = ManualTimeSource()
        let supervisor = ServerSupervisor(
            configuration: configuration(), launcher: launcher, probe: FakeProbe(launcher: launcher), time: time,
            random: { 0.5 }
        )
        await supervisor.start()
        try await time.waitForSleepers()
        time.advance(by: .seconds(20))
        let state = try await waitFor(supervisor) { if case .restarting = $0 { true } else { false } }
        guard case .restarting(_, let delay, let reason) = state else { return }
        #expect(reason.contains("timed out"))
        #expect(launcher.processes[0].signals == [SIGKILL])
        try await time.waitForSleepers()
        time.advance(by: delay)
        _ = try await waitFor(supervisor) { $0.endpoint?.pid == 1001 }
        await supervisor.stop()
    }

    @Test func givesUpAfterConsecutiveFailures() async throws {
        defer { cleanUp() }
        let launcher = FakeLauncher { _ in .init(printsReadyLine: false) }
        let time = ManualTimeSource()
        let supervisor = ServerSupervisor(
            configuration: configuration(), launcher: launcher, probe: FakeProbe(launcher: launcher), time: time,
            random: { 0.5 }
        )
        await supervisor.start()
        // Each launch: the start timeout fires, then the backoff sleep.
        for _ in 0..<7 {
            if case .failed = await supervisor.state { break }
            try await time.waitForSleepers()
            time.advance(by: .seconds(60))
        }
        let state = try await waitFor(supervisor) { if case .failed = $0 { true } else { false } }
        guard case .failed(let reason) = state else { return }
        #expect(reason.contains("timed out"))
        #expect(launcher.processes.count == 4)
        #expect(launcher.processes.allSatisfy { $0.exitStatus != nil })
        await expectNotRunning(supervisor)
        await supervisor.stop()
        #expect(await supervisor.state == .stopped)
    }

    @Test func healthyRunResetsTheFailureCount() async throws {
        defer { cleanUp() }
        let launcher = FakeLauncher()
        let time = ManualTimeSource()
        let supervisor = ServerSupervisor(
            configuration: configuration(), launcher: launcher, probe: FakeProbe(launcher: launcher), time: time,
            random: { 0.5 }
        )
        await supervisor.start()
        _ = try await waitFor(supervisor) { $0.endpoint?.generation == 1 }

        // A quick crash counts as a failure.
        launcher.processes[0].crash()
        _ = try await waitFor(supervisor) { $0 == .restarting(attempt: 1, delay: .milliseconds(200), reason: "server killed by signal 9") }
        try await time.waitForSleepers()
        time.advance(by: .milliseconds(200))
        _ = try await waitFor(supervisor) { $0.endpoint?.generation == 2 }
        launcher.processes[1].crash()
        _ = try await waitFor(supervisor) { if case .restarting(2, .milliseconds(400), _) = $0 { true } else { false } }
        try await time.waitForSleepers()
        time.advance(by: .milliseconds(400))
        _ = try await waitFor(supervisor) { $0.endpoint?.generation == 3 }

        // After staying up past `healthyAfter`, the count starts over.
        time.advance(by: .seconds(31))
        launcher.processes[2].crash()
        _ = try await waitFor(supervisor) { if case .restarting(1, .milliseconds(200), _) = $0 { true } else { false } }
        await supervisor.stop()
    }

    @Test func stopEscalatesOnlyWhenTheChildIgnoresStdin() async throws {
        defer { cleanUp() }
        let launcher = FakeLauncher { _ in .init(exitsOnStdinClose: false, exitsOnSIGTERM: false) }
        let time = ManualTimeSource()
        let supervisor = ServerSupervisor(
            configuration: configuration(), launcher: launcher, probe: FakeProbe(launcher: launcher), time: time,
            random: { 0.5 }
        )
        await supervisor.start()
        _ = try await waitFor(supervisor) { $0.endpoint != nil }
        let child = launcher.processes[0]

        let stopping = Task { await supervisor.stop() }
        try await eventually { child.stdinClosed }
        try await time.waitForSleepers()
        #expect(child.signals.isEmpty)
        time.advance(by: .seconds(3))
        try await eventually { child.signals == [SIGTERM] }
        try await time.waitForSleepers()
        time.advance(by: .seconds(3))
        try await eventually { child.signals == [SIGTERM, SIGKILL] }
        await stopping.value
        #expect(await supervisor.state == .stopped)
        #expect(child.exitStatus == ProcessExit(reason: .signaled, status: SIGKILL))
        #expect(launcher.processes.count == 1)
    }

    @Test func stopDuringBackoffDoesNotRelaunch() async throws {
        defer { cleanUp() }
        let launcher = FakeLauncher()
        let time = ManualTimeSource()
        let supervisor = ServerSupervisor(
            configuration: configuration(), launcher: launcher, probe: FakeProbe(launcher: launcher), time: time,
            random: { 0.5 }
        )
        await supervisor.start()
        _ = try await waitFor(supervisor) { $0.endpoint != nil }
        launcher.processes[0].crash()
        _ = try await waitFor(supervisor) { if case .restarting = $0 { true } else { false } }
        await supervisor.stop()
        #expect(await supervisor.state == .stopped)
        #expect(launcher.processes.count == 1)

        // It can be started again.
        await supervisor.start()
        _ = try await waitFor(supervisor) { $0.endpoint?.pid == 1001 }
        await supervisor.stop()
    }

    @Test func missingExecutableFailsWithoutRetrying() async throws {
        defer { cleanUp() }
        let launcher = FakeLauncher()
        let supervisor = ServerSupervisor(
            configuration: configuration { $0.executableURL = URL(fileURLWithPath: "/nonexistent/opencode") },
            launcher: launcher, probe: FakeProbe(launcher: launcher), time: ManualTimeSource()
        )
        await supervisor.start()
        let state = try await waitFor(supervisor) { if case .failed = $0 { true } else { false } }
        #expect(state == .failed(reason: "no executable opencode at /nonexistent/opencode"))
        #expect(launcher.processes.isEmpty)
    }

    /// M9 (docs/reviews/M1-review.md): waiting for a ready server many times while its state does not change (SSE
    /// reconnects against a healthy child) must not accumulate state observers; ended `states()` streams are removed.
    @Test func repeatedReadyWaitsDoNotAccumulateObservers() async throws {
        defer { cleanUp() }
        let launcher = FakeLauncher()
        let supervisor = ServerSupervisor(
            configuration: configuration(), launcher: launcher, probe: FakeProbe(launcher: launcher), time: ManualTimeSource(),
            random: { 0.5 })
        await supervisor.start()
        _ = try await waitFor(supervisor) { $0.endpoint != nil }
        for _ in 0..<500 { _ = try await supervisor.awaitReady() }
        // Streams a consumer abandons are removed when they terminate, without waiting for a state change.
        for _ in 0..<50 {
            var iterator = await supervisor.states().makeAsyncIterator()
            _ = await iterator.next()
        }
        try await within(.seconds(5)) {
            while await supervisor.observerCount > 0 { await Task.yield() }
        }
        #expect(await supervisor.observerCount == 0)
        await supervisor.stop()
    }

    @Test func awaitReadyThrowsWhenStopped() async {
        let supervisor = ServerSupervisor(configuration: configuration(), launcher: FakeLauncher())
        await expectNotRunning(supervisor)
    }

    private func expectNotRunning(_ supervisor: ServerSupervisor) async {
        do {
            _ = try await supervisor.awaitReady()
            Issue.record("expected awaitReady to throw")
        } catch {
            #expect(error is ServerSupervisorError)
        }
    }

    @Test func extraEnvironmentCannotReplaceThePassword() {
        let configuration = configuration { $0.extraEnvironment = ["OPENCODE_PASSWORD": "x", "FOO": "bar", "PATH": "/p"] }
        let credentials = ServerCredentials.random()
        let environment = configuration.environment(credentials: credentials)
        #expect(environment["OPENCODE_PASSWORD"] == credentials.password)
        #expect(environment["FOO"] == "bar")
        #expect(environment["PATH"] == "/p")
    }
}

@Suite("Supervisor support", .timeLimit(.minutes(3)))
struct SupervisorSupportTests {
    @Test func backoffIsCappedAndJittered() {
        let policy = BackoffPolicy(initial: .milliseconds(100), maximum: .seconds(2), multiplier: 2, jitter: 0.5)
        #expect(policy.delay(forAttempt: 1, random: 0.5) == .milliseconds(100))
        #expect(policy.delay(forAttempt: 2, random: 0.5) == .milliseconds(200))
        #expect(policy.delay(forAttempt: 3, random: 0) == .milliseconds(200))
        #expect(policy.delay(forAttempt: 3, random: 0.999_999) == .milliseconds(600))
        #expect(policy.delay(forAttempt: 30, random: 0.5) == .seconds(2))
        #expect(policy.delay(forAttempt: 30, random: 0.999_999) == .seconds(2))
        #expect(policy.delay(forAttempt: 30, random: 0) == .seconds(1))
    }

    @Test func boundedLogRedactsSplitsAndBounds() {
        let log = BoundedLog(maxLines: 3, maxLineBytes: 10, redactions: ["hunter2"])
        log.append(Array("pw=hunter2\nsecond".utf8), from: .stderr)
        log.append(Array(" half\nthird line is long\nfourth\n".utf8), from: .stderr)
        log.append(Array("partial".utf8), from: .stdout)
        #expect(log.lines.map(\.text) == ["second hal", "third line", "fourth"])
        #expect(log.discardedCount == 1)
        log.flush(.stdout)
        #expect(log.lines.last == BoundedLog.Line(stream: .stdout, text: "partial"))
        let redacted = BoundedLog(redactions: ["hunter2"])
        redacted.append(Array("pw=hunter2\n".utf8), from: .stderr)
        #expect(redacted.text == "pw=<redacted>")
    }

    @Test func oneShotDeliversToEveryWaiterAndHonoursCancellation() async throws {
        let shot = OneShot<Int>()
        async let first = shot.value()
        async let second = shot.value()
        let cancelled = Task { try await shot.value() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await Task.sleep(for: .milliseconds(10))
        #expect(shot.fulfill(5))
        #expect(!shot.fulfill(6))
        #expect(try await first == 5)
        #expect(try await second == 5)
        #expect(try await shot.value() == 5)
    }
}

@Test func boundedLogNeverKeepsAPartialSecret() {
    let secret = "ABCDEFGHIJKLMNOP"
    let log = BoundedLog(maxLines: 10, maxLineBytes: 8, redactions: [secret])
    for offset in 0..<12 {
        log.append(Array((String(repeating: ".", count: offset) + secret + "\n").utf8), from: .stderr)
    }
    #expect(log.lines.allSatisfy { !$0.text.contains("ABC") && !$0.text.contains("NOP") })
}
