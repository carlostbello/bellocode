// TEMPORARY: gate G4 packaging proof (docs/spikes/G4-packaging.md).
//
// `BelloCode --smoke-test` runs headless before any UI: it launches the opencode binary bundled in
// Contents/Helpers the way the app will (`serve --stdio --port 0`, isolated XDG directories, per-launch password,
// stdin held open as the ownership lease), makes one authenticated `GET /api/info`, then closes stdin and checks the
// child exits. The real supervisor belongs in OpenCodeKit (ServerSupervisor); delete this file once it exists.

import Foundation
import Synchronization

enum SmokeTest {
    static let launchArgument = "--smoke-test"

    /// Runs the smoke test on the main dispatch queue's run loop and exits with 0 on success, 1 on failure.
    @MainActor
    static func runAndExit() -> Never {
        Task {
            let succeeded = await run()
            exit(succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        dispatchMain()
    }

    @concurrent
    private static func run() async -> Bool {
        let opencodeURL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/opencode")
        let helpersURL = opencodeURL.deletingLastPathComponent()
        log("bundle \(Bundle.main.bundleURL.path)")
        guard FileManager.default.isExecutableFile(atPath: opencodeURL.path) else {
            log("FAIL no executable opencode at \(opencodeURL.path); run from build/BelloCode.app")
            return false
        }

        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let server = Process()
        do {
            for name in ["config", "data", "state", "cache", "home"] {
                try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
            }
            let password = randomPassword()
            server.executableURL = opencodeURL
            server.arguments = ["serve", "--stdio", "--port", "0"]
            server.currentDirectoryURL = root
            server.environment = [
                "HOME": root.appending(path: "home").path,
                "XDG_CONFIG_HOME": root.appending(path: "config").path,
                "XDG_DATA_HOME": root.appending(path: "data").path,
                "XDG_STATE_HOME": root.appending(path: "state").path,
                "XDG_CACHE_HOME": root.appending(path: "cache").path,
                "TMPDIR": FileManager.default.temporaryDirectory.path,
                "PATH": "\(helpersURL.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "OPENCODE_PASSWORD": password,
                "OPENCODE_CLIENT": "bellocode",
                "OPENCODE_DISABLE_AUTOUPDATE": "1",
                "OPENCODE_DISABLE_MODELS_FETCH": "1",
                "OPENCODE_DISABLE_CLAUDE_CODE": "1",
            ]

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            server.standardInput = stdin
            server.standardOutput = stdout
            server.standardError = stderr

            let (exits, exitContinuation) = AsyncStream.makeStream(of: Int32.self)
            server.terminationHandler = { process in
                exitContinuation.yield(process.terminationStatus)
                exitContinuation.finish()
            }

            // Both output pipes are drained for the child's whole life so it can never block on a full pipe.
            let stderrTail = OutputTail()
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { stderrTail.append(data) }
            }
            let (lines, lineContinuation) = AsyncStream.makeStream(of: String.self)
            let stdoutReader = Task {
                do {
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        lineContinuation.yield(line)
                    }
                } catch {}
                lineContinuation.finish()
            }
            defer { stdoutReader.cancel() }

            let clock = ContinuousClock()
            let launched = clock.now
            try server.run()
            log("launched opencode pid \(server.processIdentifier)")

            let firstLine = try await withTimeout(.seconds(15)) {
                var iterator = lines.makeAsyncIterator()
                return await iterator.next()
            }
            guard let firstLine else {
                throw SmokeFailure("server closed stdout before the ready line; stderr: \(stderrTail.text)")
            }
            let readyTime = clock.now - launched
            let ready = try JSONDecoder().decode(ReadyLine.self, from: Data(firstLine.utf8))
            log("ready line \(firstLine) after \(milliseconds(readyTime)) ms")
            guard ready.url.host() == "127.0.0.1" else { throw SmokeFailure("server is not on loopback: \(ready.url)") }

            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let infoURL = ready.url.appending(path: "api/info")

            let unauthenticated = try await status(of: URLRequest(url: infoURL), session: session)
            guard unauthenticated == 401 else { throw SmokeFailure("unauthenticated GET /api/info returned \(unauthenticated)") }
            log("GET /api/info without credentials -> 401 (as expected)")

            var request = URLRequest(url: infoURL)
            let credentials = Data("opencode:\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
            let info = try await serverInfo(request, session: session)
            let healthyTime = clock.now - launched
            guard info.pid == Int(server.processIdentifier) else {
                throw SmokeFailure("server info pid \(info.pid) is not our child \(server.processIdentifier)")
            }
            log("GET /api/info with Basic auth -> 200 version \(info.version) pid \(info.pid) after \(milliseconds(healthyTime)) ms")

            let closing = clock.now
            try stdin.fileHandleForWriting.close()
            let exitStatus = try await withTimeout(.seconds(5)) {
                var iterator = exits.makeAsyncIterator()
                return await iterator.next()
            }
            guard let exitStatus else { throw SmokeFailure("lost the server's exit status") }
            log("closed stdin; server exited with status \(exitStatus) after \(milliseconds(clock.now - closing)) ms")
            guard exitStatus == 0 else { throw SmokeFailure("server exited with status \(exitStatus)") }
            log("PASS")
            return true
        } catch {
            log("FAIL \(error)")
            stop(server)
            return false
        }
    }

    // MARK: Helpers

    private struct ReadyLine: Decodable {
        let url: URL
    }

    /// The fields of `ServerInfo` (Contracts/opencode-2.3.0/openapi.json) this check needs.
    private struct ServerInfo: Decodable {
        let version: String
        let pid: Int
    }

    private struct SmokeFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private struct Timeout: Error, CustomStringConvertible {
        let description = "timed out"
    }

    /// Keeps the last few KB of a stream for failure messages.
    private final class OutputTail: Sendable {
        private let storage = Mutex(Data())

        func append(_ data: Data) {
            storage.withLock { buffer in
                buffer.append(data)
                if buffer.count > 4096 { buffer.removeFirst(buffer.count - 4096) }
            }
        }

        var text: String { storage.withLock { String(decoding: $0, as: UTF8.self) } }
    }

    private static func serverInfo(_ request: URLRequest, session: URLSession) async throws -> ServerInfo {
        // `GET /api/info` answers 503 with retry-after while the server is still starting.
        for _ in 0..<50 {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return try JSONDecoder().decode(ServerInfo.self, from: data) }
            guard code == 503 else { throw SmokeFailure("GET /api/info returned \(code)") }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SmokeFailure("GET /api/info still 503 after 5 s")
    }

    private static func status(of request: URLRequest, session: URLSession) async throws -> Int {
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private static func withTimeout<T: Sendable>(
        _ duration: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw Timeout()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw Timeout() }
            return result
        }
    }

    /// Terminates the child if it is still running: SIGTERM, then SIGKILL after 3 s.
    private static func stop(_ process: Process) {
        guard process.processIdentifier != 0, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        log("stopped server pid \(process.processIdentifier)")
    }

    private static func randomPassword() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func log(_ message: String) {
        print("smoke: \(message)")
    }
}
