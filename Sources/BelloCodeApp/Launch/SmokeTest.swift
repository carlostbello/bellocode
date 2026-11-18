import BelloCore
import Darwin
import Engine
import SecretKit
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
        // BELLOCODE_SMOKE_KEEP=1 keeps the temporary folder and the container on failure (diagnosis only).
        let keep = ProcessInfo.processInfo.environment["BELLOCODE_SMOKE_KEEP"] == "1"
        defer {
            if !keep { try? FileManager.default.removeItem(at: root) }
            // The worktree folder mounted for the temporary container project (removed only while empty, with its
            // empty parents).
            var folder = (NSHomeDirectory() as NSString).appendingPathComponent(".bellocode/worktrees/container-project")
            for _ in 0..<3 where ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? ["?"]).isEmpty {
                try? FileManager.default.removeItem(atPath: folder)
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        let server = AppRuntime.bundledServerConfiguration(dataRoot: root.appending(path: "opencode"))
        log("bundle \(Bundle.main.bundleURL.path)")
        guard FileManager.default.isExecutableFile(atPath: server.executableURL.path) else {
            log("FAIL no executable opencode at \(server.executableURL.path); run from build/BelloCode.app")
            return false
        }
        let supervisor = ServerSupervisor(configuration: server)
        // Secrets end to end (BELLOCODE_SMOKE_SECRETS=1): a loopback test API the proxy resolves, started first.
        var secretsAPI: SecretsEndToEnd.TestAPI?
        if ProcessInfo.processInfo.environment["BELLOCODE_SMOKE_SECRETS"] == "1" {
            secretsAPI = try? await SecretsEndToEnd.TestAPI(canary: "sk_live_CANARY_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        }
        defer { secretsAPI?.stop() }
        // Containerised execution: checked when Rancher Desktop is ready and the test image is present (never pulled
        // here); otherwise said plainly and the host-only checks run.
        let container = await containerPlan()
        let engine: Engine
        do {
            var configuration = EngineConfiguration(server: .supervised(supervisor), store: .inMemory)
            if container != nil {
                configuration.containers = AppRuntime.containerConfiguration(for: server)
                // Global MCP secrets of the run stay in memory (never the Keychain).
                configuration.containers?.mcpVault = InMemorySecretVault()
                // Enforced egress through the secret manager's proxy (its CA key in memory for the run).
                configuration.secretManager = AppRuntime.secretManagerConfiguration(
                    dataRoot: FileManager.default.temporaryDirectory.appending(path: "bellocode-smoke-egress-\(getpid())"),
                    authorityVault: InMemorySecretVault())
                configuration.secretManager?.enforceEgress = true
                if let secretsAPI { configuration.secretManager?.proxy = secretsAPI.proxyConfiguration }
                configuration.secretVault = InMemorySecretVault()
            }
            engine = try Engine(configuration: configuration)
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

        guard await pluginCheck(client: OpenCodeClient(endpoint: endpoint), root: root) else {
            await engine.stop()
            return false
        }

        var containerProject: String?
        if let image = container {
            let project = root.appending(path: "container-project", directoryHint: .isDirectory).path
            containerProject = project
            guard await containerCheck(engine: engine, client: OpenCodeClient(endpoint: endpoint), project: project, image: image) else {
                if keep { log("kept \(root.path)") } else { await purgeScratch(engine, project) }
                await engine.stop()
                return false
            }
        }

        if let containerProject, let secretsAPI {
            let passed = await SecretsEndToEnd.run(engine: engine, client: OpenCodeClient(endpoint: endpoint), project: containerProject,
                                                   api: secretsAPI, opencodeData: server.dataRoot, log: log)
            log(passed ? "secrets end-to-end passed" : "FAIL secrets end-to-end")
            guard passed else {
                if !keep { await purgeScratch(engine, containerProject) }
                await engine.stop()
                return false
            }
        }

        if let containerProject, ProcessInfo.processInfo.environment["BELLOCODE_SMOKE_E2E"] == "1" {
            let passed = await ContainerEndToEnd.run(engine: engine, client: OpenCodeClient(endpoint: endpoint), project: containerProject, log: log)
            log(passed ? "container end-to-end passed" : "FAIL container end-to-end")
            guard passed else {
                if !keep { await purgeScratch(engine, containerProject) }
                await engine.stop()
                return false
            }
        }

        guard let shellPID = await terminalRoundTrip(
            engine: engine, client: OpenCodeClient(endpoint: endpoint), root: root, containerProject: containerProject)
        else {
            if let containerProject { await purgeScratch(engine, containerProject) }
            await engine.stop()
            return false
        }
        if let containerProject {
            await purgeScratch(engine, containerProject)
            let left = (try? await LiveWorkspaceRuntime().managedContainers())?.filter { $0.labels.values.contains(containerProject) } ?? []
            log(left.isEmpty ? "container removed" : "FAIL container left behind")
            guard left.isEmpty else { await engine.stop(); return false }
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

    /// The bundled "bellocode" plugin (docs/features/orchestration.md): loaded from `Contents/Resources/opencode-plugin`,
    /// compatible contract, every orchestration tool registered for a location.
    @MainActor
    private static func pluginCheck(client: OpenCodeClient, root: URL) async -> Bool {
        guard let directory = AppRuntime.bundledPluginDirectory() else {
            log("FAIL no Contents/Resources/opencode-plugin/server.ts in the bundle")
            return false
        }
        let project = root.appending(path: "plugin-project", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        do {
            let info = try await client.orchestrationInfo(directory: project.path, attempts: 12)
            guard info.isCompatible, info.missingTools.isEmpty else {
                log("FAIL bellocode plugin contract \(info.contract) (expected \(OrchestrationContract.version)); missing tools: \(info.missingTools)")
                return false
            }
            log("bellocode plugin loaded from \(directory.lastPathComponent): contract \(info.contract), \(info.tools.count) tools")
            return true
        } catch {
            log("FAIL bellocode plugin not reachable: \(error)")
            return false
        }
    }

    /// A terminal through the production path (TerminalService, TerminalStream) on the bundled server's PTY daemon.
    /// Returns the shell's pid, or nil on failure.
    @MainActor
    private static func terminalRoundTrip(engine: Engine, client: OpenCodeClient, root: URL, containerProject: String?) async -> Int? {
        let project = containerProject.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? root.appending(path: "project", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        if containerProject != nil {
            // The production launch: bellocode-exec opens a login shell in the project's container.
            guard engine.terminals.launch.isContainer else {
                log("FAIL terminals do not open in the container (\(engine.terminals.launch.command))")
                return nil
            }
        } else {
            engine.terminals.launch = TerminalLaunch(
                command: "/bin/sh", args: [],
                environment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "PS1": "$ "])
        }
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
            log("terminal round trip\(containerProject == nil ? " (host shell)" : " in the container") in \(milliseconds(ContinuousClock.now - started)) ms: output read, exit code 3 kept")
            // A second shell left running, to check it ends with the server.
            guard let survivor = await terminals.create(directory: project.path) else { return nil }
            return try await client.terminal(survivor.id).pid
        } catch {
            log("FAIL terminal: \(error)")
            return nil
        }
    }

    /// The image for the container checks, or nil (with the reason printed) when they are skipped.
    @MainActor
    private static func containerPlan() async -> String? {
        let image = ProcessInfo.processInfo.environment["BELLOCODE_SMOKE_IMAGE"] ?? "node:22-bookworm-slim"
        let runtime = LiveWorkspaceRuntime()
        let state = await runtime.detect()
        guard state.isReady else {
            log("SKIP container checks: \(state.userMessage)")
            return nil
        }
        guard (try? await runtime.image(image)) != nil else {
            log("SKIP container checks: image \(image) is not present (set BELLOCODE_SMOKE_IMAGE to a local image)")
            return nil
        }
        return image
    }

    /// The isolation self-check with the real configuration (shell job, PTY, command template, schedule condition,
    /// terminal) in a temporary project's container.
    @MainActor
    private static func containerCheck(engine: Engine, client: OpenCodeClient, project: String, image: String) async -> Bool {
        try? FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let started = ContinuousClock.now
        do {
            _ = try await client.createSession(SessionCreateRequest(directory: project, title: "smoke container"))
        } catch {
            log("FAIL container project: \(error)")
            return false
        }
        var settings = ProjectEnvironmentSettings()
        settings.image = image
        await engine.environments.update(project, settings: settings)
        let environment = engine.environments.environment(for: project)
        let ready = await waitUntil(timeout: .seconds(60)) {
            engine.environments.activate(project)
            return environment.phase == .ready
        }
        guard ready else {
            log("FAIL project container not ready: \(environment.phase.label) \(environment.phase.blocked?.message ?? "")")
            return false
        }
        log("project container ready in \(milliseconds(ContinuousClock.now - started)) ms (\(image))")
        // Secret manager: the workspace sits behind the egress boundary (internal network, proxy forced, no DNS out).
        if let problem = await engine.secretManager.verifyEgress(projectDirectory: project) {
            log("FAIL egress: \(problem)")
            return false
        }
        log("egress: internal network only, HTTPS_PROXY is BelloCode's proxy, external names do not resolve")
        guard let report = await engine.environments.verifyIsolation(directory: project, full: true) else {
            log("FAIL isolation check did not run")
            return false
        }
        for check in report.checks { log("  isolation: \(check.name): \(check.outcome.word) - \(check.outcome.detail)") }
        log("isolation: \(report.verdict.word): \(report.summary)")
        // Only a full pass counts: a skipped check makes the report "Not verified", which fails the smoke test.
        guard report.verdict == .isolated, report.ranInContainer >= 4 else {
            log("FAIL isolation check (\(report.verdict.word))")
            return false
        }
        return true
    }

    /// Deletes the smoke run's own scratch project container and volumes (the explicit purge: nothing else deletes a volume).
    @MainActor
    private static func purgeScratch(_ engine: Engine, _ project: String) async {
        guard let storage = try? await engine.environments.storageToPurge(project) else { return }
        do { try await engine.environments.purge(project, confirmed: storage) } catch { log("could not remove the scratch container: \(error)") }
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
