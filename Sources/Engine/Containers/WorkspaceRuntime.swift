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
    /// Removes the project's containers only; never a volume.
    func remove(projectKey: String) async throws
    /// The project's labelled containers and volumes (what an explicit purge would delete).
    func storage(projectKey: String) async throws -> WorkspaceStorage
    /// Removes the containers and the listed volumes: the explicit "Delete Container and Data" action only.
    func purge(_ storage: WorkspaceStorage) async throws
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
             timeout: Duration) async throws -> ExecResult
    /// Runs a command that receives a secret in a one-shot sibling container (`WorkspaceManager.runSecretCommand`).
    func runSecretCommand(
        _ spec: WorkspaceSpec, shell: String, command: String, workingDir: String, name: String, secret: Data, policy: SecretCommandPolicy,
        timeout: Duration
    ) async throws -> WorkspaceManager.SecretCommandResult
    /// Removes one-shot secret-command containers left by a crash (default: nothing).
    func removeLeftoverSecretContainers() async
    /// The last `tail` lines of the container's own output (bounded), for display only.
    func logs(container: String, tail: Int) async throws -> Data
    func events() -> AsyncStream<EngineMonitorEvent>
    func makeForwarder(container: String, port: ListeningPort, hostPort: Int, user: String) throws -> PortForwarder

    // MARK: Project services (ServiceManager)

    /// Starts the project's services in dependency order with health gating (images must be present).
    func ensureServices(_ specs: [ServiceSpec], projectKey: String, progress: @escaping @Sendable (String, ServiceOutcome?) -> Void) async throws
        -> [String: ServiceOutcome]
    func serviceStatus(projectKey: String, specs: [ServiceSpec]) async throws -> [String: ServiceStatus]
    func stopServices(projectKey: String) async throws
    /// The service's existing named volumes (listed before the explicit delete).
    func serviceVolumes(projectKey: String, service: ServiceDefinition) async throws -> [String]
    /// Removes the service's container and exactly the listed volumes (the explicit destructive action).
    func deleteServiceData(projectKey: String, service: String, volumes: [String]) async throws
    func serviceLogs(container: String, tail: Int, limit: Int) async throws -> (text: String, truncated: Bool)
    /// Forwards a service's port to the Mac's loopback through a relay in the workspace container (services publish
    /// nothing).
    func makeServiceForwarder(workspace: String, service: String, port: Int, hostPort: Int, user: String) throws -> PortForwarder

    // MARK: Caches
    func cacheVolumes() async throws -> [CacheVolume]
    func cleanCache(_ name: String) async throws

    // MARK: Housekeeping
    func prunePlan(keepProjectKeys: Set<String>, pulledImageIDs: Set<String>) async throws -> PrunePlan
    func prune(_ plan: PrunePlan, keepProjectKeys: Set<String>, pulledImageIDs: Set<String>) async throws -> PruneResult

    // MARK: Global MCP servers (docs/features/containers.md, "Global MCP servers")

    /// Creates the stack's network and starts its services in dependency order (images must be present).
    func ensureMCPStack(_ specs: [ServiceSpec], root: String) async throws -> [String: ServiceOutcome]
    /// Forwards the stack's MCP endpoint (a port of one of its services) to the Mac's loopback through a relay in that
    /// service's container; `prepare` runs before each connection (starts the stack on first use).
    func makeStackForwarder(container: String, port: Int, hostPort: Int, prepare: @escaping @Sendable () async -> Bool) throws -> PortForwarder
    /// Containers of global image servers.
    func mcpContainers() async throws -> [ContainerSummary]
    /// Removes stopped image-server containers and those of servers that no longer exist.
    func removeMCPLeftovers(knownIDs: Set<String>) async
    /// Fetches `urls` from inside a container (network diagnostics); nil when the container cannot run the probe.
    func diagnose(container: String, user: String, urls: [String]) async throws -> [NetworkProbeResult]
    /// Runs the trust-store update as root in a new workspace container (`CorporateNetwork.trustStoreUpdateScript`).
    func updateTrustStore(container: String) async -> String
}

extension WorkspaceRuntime {
    /// Removes one-shot secret-command containers left by a crash. Nothing to do in fakes.
    public func removeLeftoverSecretContainers() async {}

    public func ensureServices(_ specs: [ServiceSpec], projectKey: String, progress: @escaping @Sendable (String, ServiceOutcome?) -> Void) async throws
        -> [String: ServiceOutcome] { [:] }
    public func serviceStatus(projectKey: String, specs: [ServiceSpec]) async throws -> [String: ServiceStatus] { [:] }
    public func stopServices(projectKey: String) async throws {}
    public func serviceVolumes(projectKey: String, service: ServiceDefinition) async throws -> [String] { [] }
    public func deleteServiceData(projectKey: String, service: String, volumes: [String]) async throws {}
    public func serviceLogs(container: String, tail: Int, limit: Int) async throws -> (text: String, truncated: Bool) { ("", false) }
    public func makeServiceForwarder(workspace: String, service: String, port: Int, hostPort: Int, user: String) throws -> PortForwarder {
        throw ContainerError.notFound("service forwarding is not available here")
    }
    public func cacheVolumes() async throws -> [CacheVolume] { [] }
    public func cleanCache(_ name: String) async throws {}
    public func ensureMCPStack(_ specs: [ServiceSpec], root: String) async throws -> [String: ServiceOutcome] { [:] }
    public func makeStackForwarder(container: String, port: Int, hostPort: Int, prepare: @escaping @Sendable () async -> Bool) throws -> PortForwarder {
        throw ContainerError.notFound("stack forwarding is not available here")
    }
    public func mcpContainers() async throws -> [ContainerSummary] { [] }
    public func removeMCPLeftovers(knownIDs: Set<String>) async {}
    public func diagnose(container: String, user: String, urls: [String]) async throws -> [NetworkProbeResult] { [] }
    public func updateTrustStore(container: String) async -> String { "skipped" }
    public func prunePlan(keepProjectKeys: Set<String>, pulledImageIDs: Set<String>) async throws -> PrunePlan { PrunePlan() }
    public func prune(_ plan: PrunePlan, keepProjectKeys: Set<String>, pulledImageIDs: Set<String>) async throws -> PruneResult { PruneResult() }
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
    public func remove(projectKey: String) async throws { try await manager.remove(projectKey: projectKey) }
    public func storage(projectKey: String) async throws -> WorkspaceStorage { try await manager.storage(projectKey: projectKey) }
    public func purge(_ storage: WorkspaceStorage) async throws { try await manager.purge(storage) }
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
                    timeout: Duration) async throws -> ExecResult {
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
    public func removeLeftoverSecretContainers() async { await manager.removeLeftoverSecretContainers() }
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

    var services: ServiceManager { ServiceManager(client: client) }
    public func ensureServices(_ specs: [ServiceSpec], projectKey: String, progress: @escaping @Sendable (String, ServiceOutcome?) -> Void) async throws
        -> [String: ServiceOutcome] {
        try await services.ensure(specs, projectKey: projectKey, progress: progress)
    }
    public func serviceStatus(projectKey: String, specs: [ServiceSpec]) async throws -> [String: ServiceStatus] {
        var imageIDs: [String: String] = [:]
        for image in Set(specs.map(\.definition.image)) { imageIDs[image] = try? await client.inspectImage(image)?.id }
        return try await services.status(projectKey: projectKey, specs: specs, imageIDs: imageIDs)
    }
    public func stopServices(projectKey: String) async throws { try await services.stopAll(projectKey: projectKey) }
    public func serviceVolumes(projectKey: String, service: ServiceDefinition) async throws -> [String] {
        try await services.volumes(projectKey: projectKey, service: service)
    }
    public func deleteServiceData(projectKey: String, service: String, volumes: [String]) async throws {
        try await services.deleteData(projectKey: projectKey, service: service, volumes: volumes)
    }
    public func serviceLogs(container: String, tail: Int, limit: Int) async throws -> (text: String, truncated: Bool) {
        try await services.logs(container: container, tail: tail, limit: limit)
    }
    public func makeServiceForwarder(workspace: String, service: String, port: Int, hostPort: Int, user: String) throws -> PortForwarder {
        try PortForwarder(client: client, container: workspace, containerPort: port, containerHost: service, hostPort: hostPort, user: user)
    }
    public func cacheVolumes() async throws -> [CacheVolume] { try await manager.cacheVolumes() }
    public func cleanCache(_ name: String) async throws { try await manager.cleanCache(name) }
    public func prunePlan(keepProjectKeys: Set<String>, pulledImageIDs: Set<String>) async throws -> PrunePlan {
        try await manager.prunePlan(keepProjectKeys: keepProjectKeys, pulledImageIDs: pulledImageIDs)
    }
    public func prune(_ plan: PrunePlan, keepProjectKeys: Set<String>, pulledImageIDs: Set<String>) async throws -> PruneResult {
        try await manager.prune(plan, keepProjectKeys: keepProjectKeys, pulledImageIDs: pulledImageIDs)
    }
    public func ensureMCPStack(_ specs: [ServiceSpec], root: String) async throws -> [String: ServiceOutcome] {
        try await services.ensureNetwork(projectRoot: root, offline: false, extraLabels: specs.first?.extraLabels ?? [:])
        return try await services.ensure(specs, projectKey: WorkspaceSpec.projectKey(for: root))
    }
    public func makeStackForwarder(container: String, port: Int, hostPort: Int, prepare: @escaping @Sendable () async -> Bool) throws -> PortForwarder {
        try PortForwarder(client: client, container: container, containerPort: port, containerHost: "127.0.0.1", hostPort: hostPort, prepare: prepare)
    }
    public func mcpContainers() async throws -> [ContainerSummary] { try await ImageMCPRunner(client: client).containers() }
    public func removeMCPLeftovers(knownIDs: Set<String>) async { await ImageMCPRunner(client: client).removeLeftovers(knownIDs: knownIDs) }
    public func diagnose(container: String, user: String, urls: [String]) async throws -> [NetworkProbeResult] {
        let result = try await ExecSession.run(client: client, container: container, argv: NetworkProbe.script(urls: urls), user: user,
                                               wrap: true, limit: 256 * 1024, timeout: .seconds(20 + 12 * urls.count))
        return NetworkProbe.parse(String(decoding: result.stdout, as: UTF8.self), urls: urls)
    }
    public func updateTrustStore(container: String) async -> String {
        let result = try? await ExecSession.run(client: client, container: container, argv: CorporateNetwork.trustStoreUpdateScript, user: "0:0",
                                                wrap: false, limit: 4096, timeout: .seconds(60))
        return result.map { String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "failed"
    }
}
