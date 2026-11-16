import BelloCore
import Darwin
import Engine
import Foundation
import OpenCodeKit

/// `BelloCode --smoke-test` (`make smoke`): a headless check of the bundled server through the same path the app
/// uses. It starts an `Engine` over a `ServerSupervisor` for `Contents/Helpers/opencode` (isolated data in a temporary
/// directory, never the app's or the user's), waits until the engine is live (supervisor readiness, identity check,
/// event stream, first resync), checks that an unauthenticated request is refused, stops the engine, and checks that
/// the child process is gone. Exits 0 on success, 1 on failure.
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

        let stopping = clock.now
        await engine.stop()
        // The supervisor waits for the child to exit; signal 0 only probes (ESRCH = no such process).
        let gone = kill(pid, 0) != 0 && errno == ESRCH
        log("engine stopped in \(milliseconds(clock.now - stopping)) ms; server process \(gone ? "exited" : "STILL RUNNING")")
        guard gone else { return false }
        log("PASS")
        return true
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func log(_ message: String) {
        print("smoke: \(message)")
        fflush(stdout)
    }
}
