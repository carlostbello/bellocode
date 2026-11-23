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
    /// A volume or network with one of the project's names exists without BelloCode's labels (R07).
    case foreign(ForeignResourceError)
    case engine(ContainerError)
    /// The container's user resolves to root (N09): its commands would hold the container's capabilities.
    case rootUser(String)
    /// A named user (or group) the image does not define (AF10), so it cannot be shown not to be root.
    case unknownUser(String)
    /// An exec into a container whose configured user is not a nonzero numeric `uid:gid` (container, its user): it was
    /// not created by this version of BelloCode, so nothing runs in it until it is recreated (AF10 follow-up).
    case unverifiedUser(container: String, user: String)

    public var description: String {
        switch self {
        case .rootUser(let user): "The container's user “\(user)” is root in its image; BelloCode never runs commands as root. Use the image's non-root user (remoteUser), or leave it out to use your Mac user."
        case .unknownUser(let user):
            "The container's user “\(user)” is not defined in its image's /etc/passwd (or /etc/group), so BelloCode cannot show it is not root. Use a user the image defines, a numeric uid:gid, or leave remoteUser out to use your Mac user."
        case .unverifiedUser(let container, let user):
            "The container \(container) runs as “\(user.isEmpty ? "the image's default user" : user)”, not as a verified numeric non-root user, so BelloCode runs nothing in it. Restart the project's environment (Project Settings ▸ Environment) to recreate it."
        case .imageMissing(let image): "The image \(image) is not on this Mac yet. Pull it in Project Settings ▸ Environment."
        case .unmountable(let paths):
            "These folders cannot be mounted (missing, or not shared with Rancher Desktop): \(paths.joined(separator: ", "))"
        case .nameTaken(let name): "A container named \(name) exists and is not BelloCode's workspace; rename or remove it."
        case .foreign(let error): error.description
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
        if !WorkspaceUser.isVerifiedContainerUser(inspect.config.user) {
            // AF10: reused or adopted only when it runs as a nonzero numeric uid, as every workspace BelloCode creates
            // does (one created by an earlier version with a name, or by someone else, is replaced).
            reason = "user not verified"
        } else if labels[WorkspaceSpec.labelConfig] != spec.configHash(imageID: image?.id) {
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
        } catch let error as ForeignResourceError {
            throw WorkspaceError.foreign(error)
        } catch {
            throw WorkspaceError.engine(ContainerError.from(error))
        }
    }

    /// After a mounted folder was deleted and re-created, Rancher Desktop's VM keeps resolving the path to the old,
    /// deleted directory for about a second and a half (its file-sharing cache), so a container created at once would
    /// mount an empty directory. Create, check that a marker file written on the Mac a moment ago is visible in every
    /// workspace root, and recreate after a pause until it is (at most ~6 s). The markers are removed at once.
    private func createWithLiveMounts(_ spec: WorkspaceSpec, imageID: String?) async throws -> String {
        let user = try await prepare(spec, imageID: imageID)
        let name = ".bellocode-mount-check-\(UUID().uuidString.prefix(8))"
        let markers = spec.workspaceRoots.map { ($0 as NSString).appendingPathComponent(name) }
        for marker in markers { FileManager.default.createFile(atPath: marker, contents: Data()) }
        defer { for marker in markers { try? FileManager.default.removeItem(atPath: marker) } }
        let check = ["/bin/sh", "-c", "for f; do [ -e \"$f\" ] || exit 9; done", "check"] + markers
        for attempt in 0..<8 {
            let id = try await createContainer(spec, imageID: imageID, user: user)
            let result = try await run(container: id, argv: check, wrap: false, limit: 1024, timeout: .seconds(10))
            if result.exitCode == 0 { return id }
            try await client.removeContainer(id, force: true)
            try await Task.sleep(for: .milliseconds(attempt < 2 ? 500 : 900))
        }
        throw WorkspaceError.unmountable([spec.projectRoot])
    }

    private func create(_ spec: WorkspaceSpec, imageID: String?) async throws -> String {
        try await createContainer(spec, imageID: imageID, user: try await prepare(spec, imageID: imageID))
    }

    /// Everything a new workspace container needs before it exists: its folders mountable, its network and volumes
    /// (owned by this project), its user resolved to a nonzero uid without running the image (AF10), and `$HOME` and
    /// the caches in it given to that user by BelloCode's own image (AF09). Returns the user.
    private func prepare(_ spec: WorkspaceSpec, imageID: String?) async throws -> WorkspaceUser {
        let unmountable = spec.unmountablePaths()
        guard unmountable.isEmpty else { throw WorkspaceError.unmountable(unmountable) }
        if spec.serviceNetwork != nil {
            try await ServiceManager(client: client).ensureNetwork(projectRoot: spec.projectRoot, offline: spec.network == .none, extraLabels: spec.extraLabels)
        }
        for cache in Array(spec.caches.keys) + ["home"] {
            // Creating an existing volume "succeeds" in Docker: a same-name volume without this project's labels is
            // someone else's and is never mounted (R07).
            try await client.ensureOwnedVolume(name: spec.volumeName(cache), labels: [
                WorkspaceSpec.labelWorkspace: "1", WorkspaceSpec.labelProject: spec.projectRoot,
                WorkspaceSpec.labelProjectKey: spec.projectKey,
            ].merging(spec.extraLabels) { a, _ in a }, required: [WorkspaceSpec.labelWorkspace: "1", WorkspaceSpec.labelProjectKey: spec.projectKey])
        }
        for cache in spec.cacheMounts ?? [] {
            let labels = cache.volumeLabels(projectRoot: spec.projectRoot, projectKey: spec.projectKey)
            try await client.ensureOwnedVolume(
                name: cache.volumeName(projectKey: spec.projectKey), labels: labels.merging(spec.extraLabels) { a, _ in a },
                required: labels.filter { $0.key != WorkspaceSpec.labelProject })
        }
        let user = try await verifiedUser(spec, imageID: imageID)
        try await prepareVolumes(spec, user: user)
        return user
    }

    /// Creates and starts the container as `user` (verified, numeric): no program of the image ever runs as root or as
    /// a name it could map to root, and BelloCode runs nothing in it as root afterwards.
    private func createContainer(_ spec: WorkspaceSpec, imageID: String?, user: WorkspaceUser) async throws -> String {
        var body = spec.createBody(imageID: imageID)
        body.user = user.numeric
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
        return id
    }

    /// Marks the short-lived containers BelloCode makes to prepare a workspace (never a workspace: `status` ignores
    /// them; `purge` finds them by the project key).
    public static let labelSetup = "app.bellocode.workspace-setup"

    func setupLabels(_ spec: WorkspaceSpec) -> [String: String] {
        [WorkspaceSpec.labelProject: spec.projectRoot, WorkspaceSpec.labelProjectKey: spec.projectKey, Self.labelSetup: "1"]
            .merging(spec.extraLabels) { a, _ in a }
    }

    /// AF10: the numeric, non-root user the workspace runs as, always with its group. `uid:gid` is taken as it is; a
    /// name, a group name or a uid without a group is resolved from the exact image's own account files, read without
    /// running anything of the image (a uid the image does not list gets group 0, as Docker would give it). The group
    /// is always recorded so that no later exec leaves it to the container's `/etc/passwd`.
    func verifiedUser(_ spec: WorkspaceSpec, imageID: String?) async throws -> WorkspaceUser {
        var user: WorkspaceUser?
        if let numeric = WorkspaceUser.numeric(spec.user), numeric.gid != nil {
            user = numeric
        } else {
            let files = try await accountFiles(image: imageID ?? spec.image, spec: spec)
            user = WorkspaceUser.resolve(spec.user, passwd: files.passwd, group: files.group)
            if user?.gid == nil { user?.gid = 0 }
        }
        guard let user else { throw WorkspaceError.unknownUser(spec.user) }
        guard user.uid != 0 else { throw WorkspaceError.rootUser(spec.user) }
        return user
    }

    /// The image's `/etc/passwd` and `/etc/group`, from a container created from it and never started (no mounts, no
    /// network) and removed at once: the engine's archive endpoint reads the image's files, no program of the image
    /// runs. A missing file is nil; one that is not a regular file (a link) cannot be read so and counts as missing.
    func accountFiles(image: String, spec: WorkspaceSpec) async throws -> (passwd: String?, group: String?) {
        var body = ContainerCreate(image: image)
        body.entrypoint = ["/bellocode-never-started"]
        body.labels = setupLabels(spec)
        var host = HostConfig()
        host.networkMode = "none"
        host.capDrop = ["ALL"]
        host.securityOpt = ["no-new-privileges:true"]
        body.hostConfig = host
        let id = try await client.createContainer(name: nil, body)
        func read(_ path: String) async throws -> String? {
            do {
                let tar = try await client.getArchive(id, path: path)
                return WorkspaceUser.regularFile(inTar: tar).map { String(decoding: $0, as: UTF8.self) }
            } catch ContainerError.notFound {
                return nil
            }
        }
        do {
            let files = (try await read("/etc/passwd"), try await read("/etc/group"))
            try? await client.removeContainer(id, force: true)
            return files
        } catch {
            try? await client.removeContainer(id, force: true)
            throw error
        }
    }

    /// AF09: `$HOME` (a fresh volume belongs to root) and the folders from each cache nested in it up to `$HOME` are
    /// given to the user by BelloCode's own image, never the project's: the egress gateway's image (a base pinned by
    /// digest, built by this process and run by its ID, with no program of a project in it). It runs as root with only
    /// the home and cache volumes mounted, no network and a read-only root, and is removed when done. The workspace
    /// itself then runs as the user with no capabilities, and nothing in it runs as root.
    func prepareVolumes(_ spec: WorkspaceSpec, user: WorkspaceUser) async throws {
        let image: String
        do {
            image = try await EgressGatewayImage.ensure(client: client)
        } catch {
            throw ContainerError.http(status: 500, message: "BelloCode prepares the workspace's home folder with its own helper image, which is not available: \(error)")
        }
        // Not recursively: a shared cache keeps its contents' owners. `-h`: a link in the home volume is not followed.
        let caches = (spec.cacheMounts ?? []).map(\.path).filter { $0.hasPrefix(WorkspaceSpec.home + "/") }
        let owner = user.numeric
        let script = #"mkdir -p "$HOME" && chown -h \#(owner) "$HOME" && for p; do d=$p; while [ "$d" != "$HOME" ] && [ "$d" != "/" ]; do chown -h \#(owner) "$d"; d=$(dirname "$d"); done; done"#
        var body = ContainerCreate(image: image)
        body.entrypoint = ["/bin/sh", "-c", script, "prepare-home"] + caches
        body.user = "0:0"
        body.env = ["HOME=\(WorkspaceSpec.home)"]
        body.labels = setupLabels(spec)
        var host = HostConfig()
        host.privileged = false
        host.capDrop = ["ALL"]
        host.capAdd = ["CHOWN", "DAC_OVERRIDE", "FOWNER"]
        host.securityOpt = ["no-new-privileges:true"]
        host.readonlyRootfs = true
        host.networkMode = "none"
        host.pidsLimit = 64
        host.memory = 128 << 20
        // The same volumes at the same paths as the workspace (the daemon creates the nested caches' parents here).
        host.mounts = [Mount(type: .volume, source: spec.volumeName("home"), target: WorkspaceSpec.home)]
            + (spec.cacheMounts ?? []).sorted { $0.path < $1.path }.map { Mount(type: .volume, source: $0.volumeName(projectKey: spec.projectKey), target: $0.path) }
        body.hostConfig = host
        let id = try await client.createContainer(name: nil, body)
        let client = self.client
        do {
            try await client.startContainer(id)
            let status = try await withDeadline(.seconds(120), operation: "preparing $HOME") { try await client.waitContainer(id) }
            try? await client.removeContainer(id, force: true)
            if status != 0 { throw ContainerError.http(status: 500, message: "preparing $HOME failed (exit \(status))") }
        } catch {
            try? await client.removeContainer(id, force: true)
            throw error
        }
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

    public func listeningPorts(container: String) async throws -> [ListeningPort] {
        let result = try await run(container: container, argv: ContainerProbes.listeningPortsScript, wrap: false, limit: 512 * 1024)
        return ContainerProbes.parseListeningPorts(String(decoding: result.stdout, as: UTF8.self))
    }

    public func processes(container: String) async throws -> [ContainerProcess] {
        let result = try await run(container: container, argv: ContainerProbes.processListScript, wrap: false, limit: 512 * 1024)
        return ContainerProbes.parseProcesses(String(decoding: result.stdout, as: UTF8.self))
    }

    /// Kills processes left behind by finished or cancelled commands (see `ContainerProbes.reaperScript`). Returns how
    /// many were signalled.
    @discardableResult
    public func reap(container: String) async throws -> Int {
        let result = try await run(container: container, argv: ContainerProbes.reaperScript, wrap: false, limit: 4096)
        return Int(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    public func inventory(container: String) async throws -> ContainerProbes.ToolInventory {
        let result = try await run(container: container, argv: ContainerProbes.toolInventoryScript, wrap: false, limit: 64 * 1024)
        return ContainerProbes.parseInventory(String(decoding: result.stdout, as: UTF8.self))
    }

    /// Raises inotify events in the container for host paths that changed (`ContainerProbes.touchScript`).
    public func touch(container: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await run(container: container, argv: ContainerProbes.touchScript(paths), wrap: false, limit: 4096)
    }
}
