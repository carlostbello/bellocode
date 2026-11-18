import Foundation
import os

/// The workspace container of one project: what exists and whether it matches the current setting.
public struct WorkspaceStatus: Sendable, Equatable {
    public enum Phase: String, Sendable { case absent, stopped, running, outdated }
    public var phase: Phase
    public var containerID: String?
    public var imageID: String?
    /// Why the container is outdated (shown in details): "image changed", "settings changed", "project folder replaced".
    public var outdatedReason: String?
    /// Published container port → host loopback port.
    public var ports: [Int: Int]
    /// Execs the daemon still lists for the container (running or recently ended).
    public var execIDs: [String]

    public init(phase: Phase, containerID: String? = nil, imageID: String? = nil, outdatedReason: String? = nil,
                ports: [Int: Int] = [:], execIDs: [String] = []) {
        self.phase = phase
        self.containerID = containerID
        self.imageID = imageID
        self.outdatedReason = outdatedReason
        self.ports = ports
        self.execIDs = execIDs
    }
}

/// The labelled resources of one project's workspace: what the explicit "Delete Container and Data" action lists and
/// removes. Volumes hold the persistent $HOME and caches; deleting them cannot be undone.
public struct WorkspaceStorage: Sendable, Equatable {
    public var projectKey: String
    /// The workspace, service and leftover one-shot containers of the project.
    public var containers: [String]
    /// Its home and cache volumes and its services' volumes (never a cache shared across projects).
    public var volumes: [String]
    /// Its service network(s).
    public var networks: [String]

    public init(projectKey: String, containers: [String], volumes: [String], networks: [String] = []) {
        self.projectKey = projectKey
        self.containers = containers
        self.volumes = volumes
        self.networks = networks
    }

    public var isEmpty: Bool { containers.isEmpty && volumes.isEmpty && networks.isEmpty }
}

/// Why `ensureRunning` could not make the container run, phrased by what fixes it.
public enum WorkspaceError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The image is not present and pulling was not allowed (the helper never pulls).
    case imageMissing(String)
    /// A mounted folder is missing or not shared with Rancher Desktop's VM.
    case unmountable([String])
    /// A container with our name exists but is not BelloCode's.
    case nameTaken(String)
    case engine(ContainerError)

    public var description: String {
        switch self {
        case .imageMissing(let image): "The image \(image) is not on this Mac yet. Pull it in Project Settings ▸ Environment."
        case .unmountable(let paths):
            "These folders cannot be mounted (missing, or not shared with Rancher Desktop): \(paths.joined(separator: ", "))"
        case .nameTaken(let name): "A container named \(name) exists and is not BelloCode's workspace; rename or remove it."
        case .engine(let error): error.description
        }
    }
}

private let signposter = OSSignposter(subsystem: "app.bellocode.ContainerKit", category: "workspace")

/// Lifecycle of workspace containers: create on first use, start, recreate when the image, the setting or the
/// mounted folders' identity changed, stop when idle, reap stray processes, remove with the project. Every resource is
/// found by label, never by name alone. Used by the app (EnvironmentService) and by `bellocode-exec` (start or create
/// on first use; it never pulls).
public struct WorkspaceManager: Sendable {
    public let client: EngineClient

    public init(client: EngineClient) { self.client = client }

    static func labelFilter(projectKey: String) -> [String] {
        ["\(WorkspaceSpec.labelWorkspace)=1", "\(WorkspaceSpec.labelProjectKey)=\(projectKey)"]
    }

    public func status(_ spec: WorkspaceSpec) async throws -> WorkspaceStatus {
        let image = try await client.inspectImage(spec.image)
        guard let summary = try await client.listContainers(labels: Self.labelFilter(projectKey: spec.projectKey)).first,
              let inspect = try await client.inspectContainer(summary.id) else {
            return WorkspaceStatus(phase: .absent, imageID: image?.id)
        }
        let labels = inspect.config.labels ?? [:]
        var reason: String?
        if labels[WorkspaceSpec.labelConfig] != spec.configHash(imageID: image?.id) {
            reason = image?.id != nil && !inspect.image.isEmpty && inspect.image != image?.id ? "image changed" : "settings changed"
        } else if labels[WorkspaceSpec.labelMountIdentity] != spec.mountIdentity() {
            // A bind mount pins the directory it was created from: a deleted and re-created project folder (a re-clone)
            // would leave the container on the old, empty directory.
            reason = "project folder replaced"
        }
        var ports: [Int: Int] = [:]
        for (key, bindings) in inspect.ports ?? [:] {
            guard let port = Int(key.split(separator: "/").first ?? ""), let host = bindings?.first.flatMap({ Int($0.hostPort) }) else { continue }
            ports[port] = host
        }
        let phase: WorkspaceStatus.Phase = reason != nil ? .outdated : inspect.state.running ? .running : .stopped
        return WorkspaceStatus(phase: phase, containerID: inspect.id, imageID: image?.id, outdatedReason: reason, ports: ports,
                               execIDs: inspect.execIDs ?? [])
    }

    /// Pulls `spec.image`, sending `auth` only in the request header.
    public func pull(_ image: String, auth: RegistryAuth?, progress: @Sendable (ProgressMessage) -> Void = { _ in }) async throws {
        try await client.pullImage(image, registryAuth: auth?.headerValue, progress: progress)
    }

    /// Makes sure the container exists, matches the setting and runs. Returns its ID. With `pull` false a missing image
    /// throws `.imageMissing` (the helper uses this; only the app pulls, with progress and credentials).
    @discardableResult
    public func ensureRunning(_ spec: WorkspaceSpec, pull: Bool = false, auth: RegistryAuth? = nil,
                              progress: @Sendable (ProgressMessage) -> Void = { _ in }) async throws -> String {
        let state = signposter.beginInterval("ensureRunning")
        defer { signposter.endInterval("ensureRunning", state) }
        do {
            var status = try await status(spec)
            if status.imageID == nil {
                guard pull else { throw WorkspaceError.imageMissing(spec.image) }
                try await self.pull(spec.image, auth: auth, progress: progress)
                status = try await self.status(spec)
                guard status.imageID != nil else { throw WorkspaceError.imageMissing(spec.image) }
            }
            // Enforced egress: the internal network must exist before the container can be created on it. Without the
            // gateway (started by the app) the container then simply has no way out: fail closed.
            if let egress = spec.egress, status.phase == .absent || status.phase == .outdated {
                try await EgressGateway(client: client).ensureNetwork(scopeKey: egress.scopeKey)
            }
            switch status.phase {
            case .running:
                return status.containerID!
            case .stopped:
                try await client.startContainer(status.containerID!)
                return status.containerID!
            case .outdated:
                try await client.removeContainer(status.containerID!, force: true)
                if status.outdatedReason == "project folder replaced" { return try await createWithLiveMounts(spec, imageID: status.imageID) }
                return try await create(spec, imageID: status.imageID)
            case .absent:
                return try await create(spec, imageID: status.imageID)
            }
        } catch let error as WorkspaceError {
            throw error
        } catch {
            throw WorkspaceError.engine(ContainerError.from(error))
        }
    }

    /// After a mounted folder was deleted and re-created, Rancher Desktop's VM keeps resolving the path to the old,
    /// deleted directory for about a second and a half (its file-sharing cache), so a container created at once would
    /// mount an empty directory. Create, check that a marker file written on the Mac a moment ago is visible in every
    /// workspace root, and recreate after a pause until it is (at most ~6 s). The markers are removed at once.
    private func createWithLiveMounts(_ spec: WorkspaceSpec, imageID: String?) async throws -> String {
        let name = ".bellocode-mount-check-\(UUID().uuidString.prefix(8))"
        let markers = spec.workspaceRoots.map { ($0 as NSString).appendingPathComponent(name) }
        for marker in markers { FileManager.default.createFile(atPath: marker, contents: Data()) }
        defer { for marker in markers { try? FileManager.default.removeItem(atPath: marker) } }
        let check = ["/bin/sh", "-c", "for f; do [ -e \"$f\" ] || exit 9; done", "check"] + markers
        for attempt in 0..<8 {
            let id = try await create(spec, imageID: imageID)
            let result = try await ExecSession.run(client: client, container: id, argv: check, user: spec.user, wrap: false, limit: 1024,
                                                   timeout: .seconds(10))
            if result.exitCode == 0 { return id }
            try await client.removeContainer(id, force: true)
            try await Task.sleep(for: .milliseconds(attempt < 2 ? 500 : 900))
        }
        throw WorkspaceError.unmountable([spec.projectRoot])
    }

    private func create(_ spec: WorkspaceSpec, imageID: String?) async throws -> String {
        let unmountable = spec.unmountablePaths()
        guard unmountable.isEmpty else { throw WorkspaceError.unmountable(unmountable) }
        if spec.serviceNetwork != nil {
            try await ServiceManager(client: client).ensureNetwork(projectRoot: spec.projectRoot, offline: spec.network == .none, extraLabels: spec.extraLabels)
        }
        for cache in Array(spec.caches.keys) + ["home"] {
            // Idempotent: creating an existing volume with the same name succeeds.
            try await client.createVolume(name: spec.volumeName(cache), labels: [
                WorkspaceSpec.labelWorkspace: "1", WorkspaceSpec.labelProject: spec.projectRoot,
                WorkspaceSpec.labelProjectKey: spec.projectKey,
            ].merging(spec.extraLabels) { a, _ in a })
        }
        for cache in spec.cacheMounts ?? [] {
            try await client.createVolume(
                name: cache.volumeName(projectKey: spec.projectKey),
                labels: cache.volumeLabels(projectRoot: spec.projectRoot, projectKey: spec.projectKey).merging(spec.extraLabels) { a, _ in a })
        }
        var body = spec.createBody(imageID: imageID)
        body.labels?[WorkspaceSpec.labelConfig] = spec.configHash(imageID: imageID)
        body.labels?[WorkspaceSpec.labelMountIdentity] = spec.mountIdentity()
        let id: String
        do {
            id = try await client.createContainer(name: spec.containerName, body)
        } catch ContainerError.conflict {
            // Two creators raced (the app and a helper): adopt the winner if it is ours and current.
            let status = try await status(spec)
            if let existing = status.containerID, status.phase == .running || status.phase == .stopped {
                if status.phase == .stopped { try await client.startContainer(existing) }
                return existing
            }
            throw WorkspaceError.nameTaken(spec.containerName)
        }
        try await client.startContainer(id)
        try await prepareHome(id, spec: spec)
        if spec.corporateNetwork?.certificateDirectory != nil {
            // Best effort: images without the tool (or a writable store) still trust the roots through the variables.
            _ = try? await ExecSession.run(client: client, container: id, argv: CorporateNetwork.trustStoreUpdateScript, user: "0:0",
                                           wrap: false, limit: 4096, timeout: .seconds(60))
        }
        return id
    }

    /// Creates $HOME for the non-root user (a fresh volume belongs to root). Runs as root, issued by BelloCode only.
    func prepareHome(_ id: String, spec: WorkspaceSpec) async throws {
        // Cache volumes nested in $HOME make the daemon create their parent folders (and a fresh volume) as root: give
        // each folder from the cache up to $HOME to the user (not recursively: a shared cache keeps its contents).
        let caches = (spec.cacheMounts ?? []).map(\.path).filter { $0.hasPrefix(WorkspaceSpec.home + "/") }
        let script = "mkdir -p \"$HOME\" /tmp/.bellocode && chown \(spec.user) \"$HOME\" && chmod 1777 /tmp/.bellocode"
            + #" && for p; do d=$p; while [ "$d" != "$HOME" ] && [ "$d" != "/" ]; do chown \#(spec.user) "$d"; d=$(dirname "$d"); done; done"#
        let result = try await ExecSession.run(
            client: client, container: id, argv: ["/bin/sh", "-c", script, "prepare-home"] + caches,
            user: "0:0", wrap: false, limit: 4096)
        if result.exitCode != 0 { throw ContainerError.http(status: 500, message: "preparing $HOME failed (exit \(result.exitCode))") }
    }

    public func stop(_ spec: WorkspaceSpec) async throws {
        if let id = try await status(spec).containerID { try await client.stopContainer(id, timeout: 3) }
    }

    /// Removes the project's containers. Never its volumes (caches and the persistent $HOME): those go only through
    /// `purge`, the explicit destructive action that lists them first (docs/reviews/deep-review-1.md, U1).
    public func remove(projectKey: String) async throws {
        for container in try await client.listContainers(labels: Self.labelFilter(projectKey: projectKey)) {
            try await client.removeContainer(container.id, force: true)
        }
    }

    /// Everything of one project, by its project-key label (only BelloCode sets it).
    static func projectOnly(_ projectKey: String) -> [String] { ["\(WorkspaceSpec.labelProjectKey)=\(projectKey)"] }

    /// What `purge` would delete for a project: its labelled containers (workspace and services), volumes (home,
    /// caches, service data; shared caches carry no project key) and service networks, found by label.
    public func storage(projectKey: String) async throws -> WorkspaceStorage {
        let containers = try await client.listContainers(labels: Self.projectOnly(projectKey))
        let volumes = try await client.listVolumes(labels: Self.projectOnly(projectKey))
        var networks: [String] = []
        for id in try await client.listNetworks(labels: Self.projectOnly(projectKey)) {
            if let network = try await client.inspectNetwork(id) { networks.append(network.name) }
        }
        return WorkspaceStorage(
            projectKey: projectKey, containers: containers.map { $0.name }.sorted(), volumes: volumes.sorted(), networks: networks.sorted())
    }

    /// Removes the project's containers and exactly the volumes and networks named in `storage` that still carry this
    /// project's label (a volume created after the person confirmed is kept). Cannot be undone.
    public func purge(_ storage: WorkspaceStorage) async throws {
        for container in try await client.listContainers(labels: Self.projectOnly(storage.projectKey)) {
            try await client.removeContainer(container.id, force: true)
        }
        let current = Set(try await client.listVolumes(labels: Self.projectOnly(storage.projectKey)))
        for name in storage.volumes where current.contains(name) {
            try await client.removeVolume(name, force: true)
        }
        for id in try await client.listNetworks(labels: Self.projectOnly(storage.projectKey)) {
            if let network = try await client.inspectNetwork(id), storage.networks.contains(network.name) {
                try await client.removeNetwork(network.id)
            }
        }
    }

    /// Every BelloCode-managed workspace and service container, optionally for one project.
    public func managedContainers(projectKey: String? = nil) async throws -> [ContainerSummary] {
        if let projectKey { return try await client.listContainers(labels: Self.projectOnly(projectKey)) }
        let workspaces = try await client.listContainers(labels: ["\(WorkspaceSpec.labelWorkspace)=1"])
        let services = try await client.listContainers(labels: [ServiceLabels.service])
        // Containers the agent created through the filtered Docker endpoint (docker run, docker compose).
        let agent = try await client.listContainers(labels: [DockerAgentLabels.agent])
        var seen = Set(workspaces.map(\.id))
        return workspaces + (services + agent).filter { seen.insert($0.id).inserted }
    }

    /// Commands of the container that are still running (relayed programs such as local MCP servers are not counted:
    /// they run as long as opencode keeps them connected and must not keep the container from idling).
    public func runningExecs(_ status: WorkspaceStatus) async -> Int {
        var running = 0
        for id in status.execIDs.prefix(256) {
            if let inspect = try? await client.inspectExec(id), inspect.running, !inspect.isRelayedProgram { running += 1 }
        }
        return running
    }

    // MARK: Probes

    public func listeningPorts(container: String, user: String) async throws -> [ListeningPort] {
        let result = try await ExecSession.run(client: client, container: container, argv: ContainerProbes.listeningPortsScript,
                                               user: user, wrap: false, limit: 512 * 1024)
        return ContainerProbes.parseListeningPorts(String(decoding: result.stdout, as: UTF8.self))
    }

    public func processes(container: String, user: String) async throws -> [ContainerProcess] {
        let result = try await ExecSession.run(client: client, container: container, argv: ContainerProbes.processListScript,
                                               user: user, wrap: false, limit: 512 * 1024)
        return ContainerProbes.parseProcesses(String(decoding: result.stdout, as: UTF8.self))
    }

    /// Kills processes left behind by finished or cancelled commands (see `ContainerProbes.reaperScript`). Returns how
    /// many were signalled.
    @discardableResult
    public func reap(container: String, user: String) async throws -> Int {
        let result = try await ExecSession.run(client: client, container: container, argv: ContainerProbes.reaperScript,
                                               user: user, wrap: false, limit: 4096)
        return Int(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    public func inventory(container: String, user: String) async throws -> ContainerProbes.ToolInventory {
        let result = try await ExecSession.run(client: client, container: container, argv: ContainerProbes.toolInventoryScript,
                                               user: user, wrap: false, limit: 64 * 1024)
        return ContainerProbes.parseInventory(String(decoding: result.stdout, as: UTF8.self))
    }

    /// Raises inotify events in the container for host paths that changed (`ContainerProbes.touchScript`).
    public func touch(container: String, user: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await ExecSession.run(client: client, container: container, argv: ContainerProbes.touchScript(paths),
                                      user: user, wrap: false, limit: 4096)
    }
}
