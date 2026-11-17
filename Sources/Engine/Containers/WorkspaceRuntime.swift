import ContainerKit
import Foundation

/// The container operations EnvironmentService needs, behind a protocol so the service is tested without a runtime
/// (`FakeWorkspaceRuntime` in the tests) and runs against Rancher Desktop in the app (`LiveWorkspaceRuntime`).
/// Every method runs off the main actor and returns `Sendable` values; none logs command output or environment.
public protocol WorkspaceRuntime: Sendable {
    var socketPath: String { get }
    func detect() async -> RuntimeState
    func image(_ reference: String) async throws -> ImageSummary?
    func pull(_ reference: String, auth: RegistryAuth?, progress: @escaping @Sendable (ProgressMessage) -> Void) async throws
    func status(_ spec: WorkspaceSpec) async throws -> WorkspaceStatus
    func ensureRunning(_ spec: WorkspaceSpec) async throws -> String
    func stop(container: String) async throws
    func start(container: String) async throws
    func restart(container: String) async throws
    func remove(projectKey: String, volumes: Bool) async throws
    func removeContainer(_ id: String) async throws
    func managedContainers() async throws -> [ContainerSummary]
    func runningExecs(container: String) async -> Int
    func listeningPorts(container: String, user: String) async throws -> [ListeningPort]
    func reap(container: String, user: String) async throws -> Int
    func inventory(container: String, user: String) async throws -> ContainerProbes.ToolInventory
    func touch(container: String, user: String, paths: [String]) async throws
    /// Runs one command (non-interactive, wrapped so cancellation stops its group). `environment` is set for this exec
    /// only (secrets); output is bounded.
    func run(container: String, argv: [String], workingDir: String?, environment: [String: String], user: String,
             timeout: Duration) async throws -> (exitCode: Int, stdout: Data, stderr: Data)
    /// Runs a command that receives a secret in a one-shot sibling container (`WorkspaceManager.runSecretCommand`).
    func runSecretCommand(
        _ spec: WorkspaceSpec, shell: String, command: String, workingDir: String, name: String, secret: Data, policy: SecretCommandPolicy,
        timeout: Duration
    ) async throws -> WorkspaceManager.SecretCommandResult
    /// The last `tail` lines of the container's own output (bounded), for display only.
    func logs(container: String, tail: Int) async throws -> Data
    func events() -> AsyncStream<EngineMonitorEvent>
    func makeForwarder(container: String, port: ListeningPort, hostPort: Int, user: String) throws -> PortForwarder
}

/// Rancher Desktop through ContainerKit.
public struct LiveWorkspaceRuntime: WorkspaceRuntime {
    public let socketPath: String
    public let discovery: RuntimeDiscovery
    let client: EngineClient
    var manager: WorkspaceManager { WorkspaceManager(client: client) }

    public init(socketOverride: String? = nil) {
        discovery = RuntimeDiscovery(overrideSocket: socketOverride)
        socketPath = discovery.socketPath
        client = EngineClient(socketPath: discovery.socketPath)
    }

    public func detect() async -> RuntimeState { await discovery.detect() }
    public func image(_ reference: String) async throws -> ImageSummary? { try await client.inspectImage(reference) }
    public func pull(_ reference: String, auth: RegistryAuth?, progress: @escaping @Sendable (ProgressMessage) -> Void) async throws {
        try await manager.pull(reference, auth: auth, progress: progress)
    }
    public func status(_ spec: WorkspaceSpec) async throws -> WorkspaceStatus { try await manager.status(spec) }
    public func ensureRunning(_ spec: WorkspaceSpec) async throws -> String { try await manager.ensureRunning(spec, pull: false) }
    public func stop(container: String) async throws { try await client.stopContainer(container, timeout: 3) }
    public func start(container: String) async throws { try await client.startContainer(container) }
    public func restart(container: String) async throws { try await client.restartContainer(container, timeout: 3) }
    public func remove(projectKey: String, volumes: Bool) async throws { try await manager.remove(projectKey: projectKey, volumes: volumes) }
    public func removeContainer(_ id: String) async throws { try await client.removeContainer(id, force: true) }
    public func managedContainers() async throws -> [ContainerSummary] { try await manager.managedContainers() }
    public func runningExecs(container: String) async -> Int {
        guard let inspect = try? await client.inspectContainer(container) else { return 0 }
        return await manager.runningExecs(WorkspaceStatus(phase: .running, containerID: container, execIDs: inspect.execIDs ?? []))
    }
    public func listeningPorts(container: String, user: String) async throws -> [ListeningPort] {
        try await manager.listeningPorts(container: container, user: user)
    }
    public func reap(container: String, user: String) async throws -> Int { try await manager.reap(container: container, user: user) }
    public func inventory(container: String, user: String) async throws -> ContainerProbes.ToolInventory {
        try await manager.inventory(container: container, user: user)
    }
    public func touch(container: String, user: String, paths: [String]) async throws {
        try await manager.touch(container: container, user: user, paths: paths)
    }
    public func run(container: String, argv: [String], workingDir: String?, environment: [String: String], user: String,
                    timeout: Duration) async throws -> (exitCode: Int, stdout: Data, stderr: Data) {
        try await ExecSession.run(client: client, container: container, argv: argv, workingDir: workingDir, environment: environment,
                                  user: user, wrap: true, limit: 256 * 1024, timeout: timeout)
    }
    public func runSecretCommand(
        _ spec: WorkspaceSpec, shell: String, command: String, workingDir: String, name: String, secret: Data, policy: SecretCommandPolicy,
        timeout: Duration
    ) async throws -> WorkspaceManager.SecretCommandResult {
        try await manager.runSecretCommand(
            spec, shell: shell, command: command, workingDir: workingDir, name: name, secret: secret, policy: policy, timeout: timeout)
    }
    public func logs(container: String, tail: Int) async throws -> Data {
        var data = Data()
        for try await chunk in try await client.logs(container, follow: false, tail: String(tail)) {
            data.append(chunk.bytes)
            if data.count > 512 * 1024 { break }
        }
        return data
    }
    public func events() -> AsyncStream<EngineMonitorEvent> {
        EngineEventMonitor(client: client, labels: ["\(WorkspaceSpec.labelWorkspace)=1"]).stream()
    }
    public func makeForwarder(container: String, port: ListeningPort, hostPort: Int, user: String) throws -> PortForwarder {
        try PortForwarder(client: client, container: container, containerPort: port.port, containerHost: port.relayHost,
                          hostPort: hostPort, user: user)
    }
}
