import BelloCore
import Darwin
import Engine
import Foundation
import OpenCodeKit
import Synchronization

/// `BelloCode --smoke-test` (`make smoke`): a headless check of the bundled server through the same path the app
/// uses. It starts an `Engine` over a `ServerSupervisor` for `Contents/Helpers/opencode` (isolated data in a temporary
/// directory, never the app's or the user's), waits until the engine is live (supervisor readiness, identity check,
/// event stream, first resync), checks that an unauthenticated request is refused, runs a terminal round trip on the
/// bundled PTY daemon (create, echo, exit code), stops the engine, and checks that the server and the shell are gone.
/// Exits 0 on success, 1 on failure.
enum SmokeTest {
    @MainActor
    static func runAndExit() -> Never {
        Task { @MainActor in
            let succeeded = await run()
            exit(succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        dispatchMain()
    }

    @MainActor
    private static func run() async -> Bool {
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = AppRuntime.bundledServerConfiguration(dataRoot: root.appending(path: "opencode"))
        log("bundle \(Bundle.main.bundleURL.path)")
        guard FileManager.default.isExecutableFile(atPath: server.executableURL.path) else {
            log("FAIL no executable opencode at \(server.executableURL.path); run from build/BelloCode.app")
            return false
        }
        let supervisor = ServerSupervisor(configuration: server)
        let engine: Engine
        do {
            engine = try Engine(configuration: EngineConfiguration(server: .supervised(supervisor), store: .inMemory))
        } catch {
            log("FAIL engine: \(error)")
            return false
        }
        let clock = ContinuousClock()
        let started = clock.now
        await engine.start()
        let live = await waitUntil(timeout: .seconds(30)) { engine.root.connection == .live }
        guard live, let endpoint = await supervisor.endpoint, let pid = await supervisor.childPID else {
            log("FAIL engine not live (\(engine.root.connection.label)); server \(await supervisor.state)")
            await engine.stop()
            return false
        }
        log("live after \(milliseconds(clock.now - started)) ms: opencode \(endpoint.info.version) pid \(pid), \(engine.root.projects.count) projects")

        var request = URLRequest(url: endpoint.connection.baseURL.appending(path: "api/info"))
        request.timeoutInterval = 5
        let status = (try? await URLSession.shared.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } ?? 0
        guard status == 401 else {
            log("FAIL unauthenticated GET /api/info returned \(status), expected 401")
            await engine.stop()
            return false
        }
        log("GET /api/info without credentials -> 401 (as expected)")

        guard let shellPID = await terminalRoundTrip(engine: engine, client: OpenCodeClient(endpoint: endpoint), root: root) else {
            await engine.stop()
            return false
        }

        let stopping = clock.now
        await engine.stop()
        // The supervisor waits for the child to exit; signal 0 only probes (ESRCH = no such process).
        let gone = kill(pid, 0) != 0 && errno == ESRCH
        log("engine stopped in \(milliseconds(clock.now - stopping)) ms; server process \(gone ? "exited" : "STILL RUNNING")")
        guard gone else { return false }
        // The PTY daemon ends its shells when the server's lease ends; allow it a moment.
        var shellGone = kill(pid_t(shellPID), 0) != 0
        for _ in 0..<40 where !shellGone {
            try? await Task.sleep(for: .milliseconds(50))
            shellGone = kill(pid_t(shellPID), 0) != 0
        }
        log("terminal shell \(shellGone ? "exited" : "STILL RUNNING") with the server")
        guard shellGone else { return false }
        log("PASS")
        return true
    }

    /// A terminal through the production path (TerminalService, TerminalStream) on the bundled server's PTY daemon.
    /// Returns the shell's pid, or nil on failure.
    @MainActor
    private static func terminalRoundTrip(engine: Engine, client: OpenCodeClient, root: URL) async -> Int? {
        let project = root.appending(path: "project", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        engine.terminals.launch = TerminalLaunch(
            command: "/bin/sh", args: [],
            environment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "])
        let started = ContinuousClock.now
        do {
            let session = try await client.createSession(SessionCreateRequest(directory: project.path, title: "smoke"))
            let terminals = engine.terminals.terminals(for: SessionID(session.id))
            guard let record = await terminals.create(directory: project.path, size: PTYSize(cols: 80, rows: 24)) else {
                log("FAIL terminal: \(terminals.lastError?.userMessage ?? "not created")")
                return nil
            }
            let sink = SmokeSink()
            let stream = engine.terminals.makeStream(record.id, in: terminals, sink: sink)
            stream.resize(to: PTYSize(cols: 80, rows: 24))
            stream.activate()
            stream.send(Array("echo smoke-$((40+2))\r".utf8))
            guard await waitUntil(timeout: .seconds(10), { sink.text.contains("smoke-42") }) else {
                log("FAIL terminal output not received (status \(stream.status))")
                return nil
            }
            stream.send(Array("exit 3\r".utf8))
            guard await waitUntil(timeout: .seconds(10), { terminals.record(record.id)?.state == .exited(code: 3) }) else {
                log("FAIL terminal exit code not received")
                return nil
            }
            log("terminal round trip in \(milliseconds(ContinuousClock.now - started)) ms: output read, exit code 3 kept")
            // A second shell left running, to check it ends with the server.
            guard let survivor = await terminals.create(directory: project.path) else { return nil }
            return try await client.terminal(survivor.id).pid
        } catch {
            log("FAIL terminal: \(error)")
            return nil
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func log(_ message: String) {
        print("smoke: \(message)")
        fflush(stdout)
    }
}

/// Collects terminal output for the smoke test.
private final class SmokeSink: TerminalOutputSink {
    private let output = Mutex(Data())
    var text: String { output.withLock { String(decoding: $0, as: UTF8.self) } }
    func reset(trimmed: Bool) { output.withLock { $0.removeAll() } }
    func feed(_ data: Data) { output.withLock { $0.append(data) } }
}
