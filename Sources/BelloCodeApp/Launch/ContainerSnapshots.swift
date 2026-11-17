import AppKit
import BelloCore
import ContainerKit
import Engine
import Foundation
import Synchronization

/// `--snapshot containers` (M6-A, docs/features/containers.md): mock data with container execution on a scripted
/// runtime (never Rancher Desktop): the Environment pane with the Ports list, Settings ▸ Containers, a thread and its
/// terminal while the runtime is not running (banners, status item), and a containerised terminal.
extension SnapshotRunner {
    func runContainers() async -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("FAIL cannot create \(directory.path): \(error)")
            return false
        }
        let engine = runtime.engine
        guard let fake = SnapshotWorkspaceRuntime.current else {
            log("FAIL container execution is not configured for the snapshot")
            return false
        }
        let settings = AppSettings(defaults: nil)
        let services = AppServices(settings: settings, auth: runtime.auth)
        let workspace = WorkspaceController(engine: engine, stateStore: ShellStateStore(defaults: nil))
        let controller = MainWindowController(
            workspace: workspace,
            configuration: .init(surfaces: .builtIn(services: services), autosaveSuffix: nil, sourceLabel: runtime.sourceLabel))
        guard let window = controller.window else { return false }
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        controller.showWindow(nil)
        let driver = ShellDriver(controller: controller)
        var written: [String] = []
        func shoot(_ state: String) async {
            guard only.isEmpty || only.contains(state) else { return }
            written += await render(driver, state: state)
        }

        await engine.start()
        guard await waitUntil(timeout: .seconds(20), { engine.root.connection == .live && !engine.root.projects.isEmpty }) else {
            log("FAIL mock never became live")
            return false
        }
        _ = await waitUntil(timeout: .seconds(5)) {
            engine.root.projects.allSatisfy { workspace.projectModel($0).map { !$0.sessionIDs.isEmpty } ?? false }
        }
        guard let project = engine.root.projects.first, let thread = workspace.projectModel(project)?.sessionIDs.first else {
            log("FAIL the mock scenario has no threads")
            return false
        }
        let environments = engine.environments
        // The mock projects' folders must exist to be mounted: created for the run, removed after (only if created).
        var created: [String] = []
        for item in engine.root.projects where !FileManager.default.fileExists(atPath: item.directory) {
            try? FileManager.default.createDirectory(atPath: item.directory, withIntermediateDirectories: true)
            created.append(item.directory)
        }
        let worktreeFolder = engine.git.cachedPreferences(projectDirectory: project.directory).parentDirectory(projectDirectory: project.directory)
        let worktreeExisted = FileManager.default.fileExists(atPath: worktreeFolder)
        defer {
            for path in created { try? FileManager.default.removeItem(atPath: path) }
            if let first = created.first { try? FileManager.default.removeItem(atPath: (first as NSString).deletingLastPathComponent) }
            if !worktreeExisted {
                var folder = worktreeFolder
                for _ in 0..<3 where ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? ["?"]).isEmpty {
                    try? FileManager.default.removeItem(atPath: folder)
                    folder = (folder as NSString).deletingLastPathComponent
                }
            }
        }
        var environmentSettings = ProjectEnvironmentSettings()
        environmentSettings.image = "registry.acme.internal/dev/node:22-2026.11"
        environmentSettings.environment = ["NODE_ENV": "development", "PNPM_HOME": "/home/dev/.pnpm"]
        await environments.update(project.directory, settings: environmentSettings)
        _ = await waitUntil(timeout: .seconds(5)) { environments.runtime?.isReady == true }
        environments.activate(project.directory)
        let environment = environments.environment(for: project.directory)
        _ = await waitUntil(timeout: .seconds(5)) { environment.phase == .ready }
        await environments.refreshPorts(project.directory)

        // 1. A thread in a containerised project: status item, context line, containerised terminal.
        _ = await driver.select(.thread(thread))
        _ = await waitUntil(timeout: .seconds(5)) { workspace.threadModel(thread).phase == .ready }
        driver.perform(.toggleTerminal)
        driver.settle(10)
        try? await Task.sleep(for: .milliseconds(400))
        driver.settle(6)
        await shoot("terminal")

        // 2. The runtime stops: banner above the composer and over the terminal, status item says so.
        fake.setRunning(false)
        await environments.recheckRuntime()
        _ = await waitUntil(timeout: .seconds(5)) { environment.notice != nil }
        driver.settle(10)
        try? await Task.sleep(for: .milliseconds(300))
        driver.settle(6)
        await shoot("runtime-down")
        fake.setRunning(true)
        await environments.recheckRuntime()
        environments.activate(project.directory)
        _ = await waitUntil(timeout: .seconds(5)) { environment.phase == .ready }
        await environments.refreshPorts(project.directory)

        // 3. Settings ▸ Environment (image, limits, variables, Ports) and Settings ▸ Containers.
        EnvironmentSettingsModel.preferredDirectory = project.directory
        let settingsWindow = SettingsWindowController(
            settings: settings, auth: nil, importSource: nil, engine: engine, notifier: nil, openThread: { _ in })
        settingsWindow.show(pane: "environment")
        EnvironmentSettingsModel.last?.select(project.directory)
        settingsWindow.window?.setFrameOrigin(NSPoint(x: 60, y: 60))
        try? await Task.sleep(for: .milliseconds(400))
        if only.isEmpty || only.contains("environment") { written += await renderWindow(settingsWindow.window, state: "environment") }
        settingsWindow.show(pane: "containers")
        try? await Task.sleep(for: .milliseconds(400))
        if only.isEmpty || only.contains("settings") { written += await renderWindow(settingsWindow.window, state: "settings") }
        settingsWindow.close()

        workspace.close()
        controller.close()
        for path in written { log("wrote \(path)") }
        log(written.isEmpty ? "FAIL nothing written" : "PASS \(written.count) images")
        return !written.isEmpty
    }
}

/// A scripted runtime for snapshots: Rancher Desktop 1.25 ready (or stopped), the image present, a running workspace,
/// a Vite dev server and Postgres listening. Never touches a socket.
final class SnapshotWorkspaceRuntime: WorkspaceRuntime {
    @MainActor static var current: SnapshotWorkspaceRuntime?
    private let running = Mutex(true)
    private let started = Mutex<Set<String>>([])

    func setRunning(_ value: Bool) { running.withLock { $0 = value } }

    var socketPath: String { NSHomeDirectory() + "/.rd/docker.sock" }
    func detect() async -> RuntimeState {
        running.withLock { $0 }
            ? .ready(.init(socketPath: socketPath, engineVersion: "27.3.1", apiVersion: "1.47", arch: "aarch64", rancherVersion: "1.25.0"))
            : .notRunning(socketPath: socketPath)
    }
    func image(_ reference: String) async throws -> ImageSummary? {
        try JSONDecoder().decode(ImageSummary.self, from: Data(#"{"Id":"sha256:5f2a","RepoDigests":["registry.acme.internal/dev/node@sha256:5f2a"]}"#.utf8))
    }
    func pull(_ reference: String, auth: RegistryAuth?, progress: @escaping @Sendable (ProgressMessage) -> Void) async throws {}
    func status(_ spec: WorkspaceSpec) async throws -> WorkspaceStatus {
        started.withLock { $0.contains(spec.containerName) }
            ? WorkspaceStatus(phase: .running, containerID: spec.containerName, imageID: "sha256:5f2a") : WorkspaceStatus(phase: .absent)
    }
    func ensureRunning(_ spec: WorkspaceSpec) async throws -> String {
        _ = started.withLock { $0.insert(spec.containerName) }
        return spec.containerName
    }
    func stop(container: String) async throws {}
    func start(container: String) async throws {}
    func restart(container: String) async throws {}
    func remove(projectKey: String, volumes: Bool) async throws {}
    func removeContainer(_ id: String) async throws {}
    func managedContainers() async throws -> [ContainerSummary] {
        started.withLock { Array($0) }.sorted().map { name in
            ContainerSummary(id: name, names: ["/" + name], image: "registry.acme.internal/dev/node:22-2026.11", state: "running",
                             status: "Up 12 minutes", labels: [WorkspaceSpec.labelWorkspace: "1"])
        }
    }
    func runningExecs(container: String) async -> Int { 1 }
    func listeningPorts(container: String, user: String) async throws -> [ListeningPort] {
        [ListeningPort(port: 5173, address: "127.0.0.1", pid: 412, process: "node (vite)"),
         ListeningPort(port: 5432, address: "0.0.0.0", pid: 77, process: "postgres")]
    }
    func reap(container: String, user: String) async throws -> Int { 0 }
    func inventory(container: String, user: String) async throws -> ContainerProbes.ToolInventory {
        .init(os: "Debian GNU/Linux 12", arch: "aarch64", tools: ["bash", "git", "node", "npm", "pnpm", "python3"])
    }
    func touch(container: String, user: String, paths: [String]) async throws {}
    func run(container: String, argv: [String], workingDir: String?, environment: [String: String], user: String,
             timeout: Duration) async throws -> ExecResult {
        // The isolation probes read their markers here: answer as the container would.
        ExecResult(exitCode: 0, stdout: Data("container Linux\n".utf8), stderr: Data())
    }
    func runSecretCommand(
        _ spec: WorkspaceSpec, shell: String, command: String, workingDir: String, name: String, secret: Data, policy: SecretCommandPolicy,
        timeout: Duration
    ) async throws -> WorkspaceManager.SecretCommandResult {
        WorkspaceManager.SecretCommandResult(exitCode: 0, output: BoundedOutput(limit: 1024))
    }
    func logs(container: String, tail: Int) async throws -> Data { Data("VITE v6.0.3  ready in 412 ms\n".utf8) }
    func events() -> AsyncStream<EngineMonitorEvent> { AsyncStream { _ in } }
    func makeForwarder(container: String, port: ListeningPort, hostPort: Int, user: String) throws -> PortForwarder {
        throw ContainerError.notFound("no forwarding in snapshots")
    }
}
