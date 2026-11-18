import CryptoKit
import Foundation

/// Resource limits of a workspace container. Defaults fit inside Rancher Desktop's default VM.
public struct ResourceLimits: Sendable, Equatable, Codable, Hashable {
    public var cpus: Double
    public var memoryBytes: Int64
    public var pidsLimit: Int64

    public init(cpus: Double = 2, memoryBytes: Int64 = 4 << 30, pidsLimit: Int64 = 4096) {
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.pidsLimit = pidsLimit
    }

    public static let standard = ResourceLimits()
}

/// An extra host folder mounted into the container (off by default; the project setting lists them explicitly).
public struct UserMount: Sendable, Equatable, Codable, Hashable {
    public var path: String
    public var readOnly: Bool
    public init(path: String, readOnly: Bool = true) {
        self.path = path
        self.readOnly = readOnly
    }
}

/// Folders Rancher Desktop shares with its VM by default. A bind mount of anything else fails at create
/// ("bind source path does not exist"), so BelloCode checks before creating and names the folder.
public enum RancherFileSharing {
    public static func sharedPrefixes(home: String = NSHomeDirectory()) -> [String] {
        [home, "/Volumes", "/private/tmp", "/tmp", "/var/folders", "/private/var/folders", "/tmp/rancher-desktop"]
    }

    public static func isShared(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let standardized = (path as NSString).standardizingPath
        return sharedPrefixes(home: home).contains { standardized == $0 || standardized.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}

/// Everything that decides what one project's workspace container looks like (the project's "Environment" setting
/// plus the folders BelloCode mounts). Secrets are never part of it: they travel per exec, in memory, over the socket,
/// and never land in the container's configuration, which `inspect` reveals and the daemon persists.
public struct WorkspaceSpec: Sendable, Equatable, Codable {
    public enum Network: String, Sendable, Codable, CaseIterable {
        /// Default bridge: outbound access, nothing inbound (dev servers are reached through BelloCode's forwarder).
        case bridge
        /// No network at all (offline builds and tests).
        case none
    }

    /// Host directory of the project (a git repository root). Mounted at the same absolute path.
    public var projectRoot: String
    /// Further host directories BelloCode mounts at the same path: the project's worktree folders.
    public var extraMounts: [String]
    /// Folders the user added in the setting (off by default), at the same path.
    public var userMounts: [UserMount]
    public var image: String
    /// `uid:gid` the commands run as; the host user, so files created in the container belong to them.
    public var user: String
    public var network: Network
    /// Container ports published on host loopback at creation (unused by default; see `PortForwarder`).
    public var publishedPorts: [Int]
    public var resources: ResourceLimits
    /// Non-secret variables set in the container.
    public var environment: [String: String]
    /// Named caches (volume name suffix → container path), kept across rebuilds.
    public var caches: [String: String]
    /// Extra labels (tests mark their containers).
    public var extraLabels: [String: String]
    /// The project's service network (`ServiceLabels.networkName`) when it declares services: the workspace joins it
    /// instead of the default bridge, so services are reachable by name. Offline projects get an internal network.
    public var serviceNetwork: String?
    /// Package-manager caches (`PackageCache`), each a named volume at its path; project-scoped unless shared.
    public var cacheMounts: [CacheMount]?
    /// Enterprise certificates and proxy variables (Corporate network).
    public var corporateNetwork: CorporateNetwork?
    /// The project's service names (added to `NO_PROXY`).
    public var serviceNames: [String]?

    public init(projectRoot: String, extraMounts: [String] = [], userMounts: [UserMount] = [], image: String,
                user: String = "\(getuid()):\(getgid())", network: Network = .bridge, publishedPorts: [Int] = [],
                resources: ResourceLimits = .standard, environment: [String: String] = [:], caches: [String: String] = [:],
                extraLabels: [String: String] = [:]) {
        self.projectRoot = projectRoot
        self.extraMounts = extraMounts
        self.userMounts = userMounts
        self.image = image
        self.user = user
        self.network = network
        self.publishedPorts = publishedPorts
        self.resources = resources
        self.environment = environment
        self.caches = caches
        self.extraLabels = extraLabels
    }

    public static let home = "/home/bellocode"
    /// Marks every resource BelloCode manages (containers, volumes).
    public static let labelWorkspace = "app.bellocode.workspace"
    public static let labelProject = "app.bellocode.project"
    public static let labelProjectKey = "app.bellocode.project-key"
    public static let labelConfig = "app.bellocode.config"
    public static let labelMountIdentity = "app.bellocode.mounts"
    public static let labelImage = "app.bellocode.image"

    /// Every host folder mounted at the same path (project first).
    public var mountedRoots: [String] { [projectRoot] + extraMounts + userMounts.map(\.path) }
    /// Folders commands may run in: the project and its worktrees (user mounts are data, not workspaces).
    public var workspaceRoots: [String] { [projectRoot] + extraMounts }

    /// Device and inode of every mounted host directory. A bind mount keeps referring to the directory it was created
    /// from, so a project folder that was deleted and re-created needs a new container.
    public func mountIdentity() -> String {
        mountedRoots.map(Self.identity(of:)).joined(separator: ",")
    }

    public static func identity(of path: String) -> String {
        var info = stat()
        guard stat(path, &info) == 0 else { return "missing" }
        return "\(info.st_dev):\(info.st_ino)"
    }

    /// Mounted folders that are missing or that Rancher Desktop does not share (creating would fail).
    public func unmountablePaths(home: String = NSHomeDirectory()) -> [String] {
        mountedRoots.filter { path in
            var isDirectory: ObjCBool = false
            return !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || !isDirectory.boolValue
                || !RancherFileSharing.isShared(path, home: home)
        }
    }

    /// Stable short identity of the project: names the container and its volumes.
    public var projectKey: String { Self.projectKey(for: projectRoot) }

    public static func projectKey(for projectRoot: String) -> String {
        let digest = SHA256.hash(data: Data(projectRoot.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    public var containerName: String { Self.containerName(for: projectRoot) }
    public static func containerName(for projectRoot: String) -> String { "bellocode-ws-\(projectKey(for: projectRoot))" }
    public func volumeName(_ cache: String) -> String { "bellocode-\(projectKey)-\(cache)" }

    public var labels: [String: String] {
        [Self.labelWorkspace: "1", Self.labelProject: projectRoot, Self.labelProjectKey: projectKey, Self.labelImage: image]
            .merging(extraLabels) { a, _ in a }
    }

    /// The create body, without the config and mount-identity labels.
    public func createBody(imageID: String?) -> ContainerCreate {
        var body = ContainerCreate(image: imageID ?? image)
        body.entrypoint = ["sleep"]
        body.cmd = ["infinity"]
        body.user = user
        body.workingDir = projectRoot
        body.env = (["HOME=\(Self.home)", "BELLOCODE_WORKSPACE=1"]
            + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        body.labels = labels
        body.stopSignal = "SIGTERM"
        body.stopTimeout = 3
        var host = HostConfig()
        host.init_ = true  // tini reaps orphans left by commands
        host.privileged = false
        host.capDrop = ["ALL"]
        // Only the root exec BelloCode itself issues (preparing $HOME) uses these; commands run as the host
        // user, so they have no capabilities.
        host.capAdd = ["CHOWN", "DAC_OVERRIDE", "FOWNER"]
        host.securityOpt = ["no-new-privileges:true"]
        host.nanoCPUs = Int64(resources.cpus * 1_000_000_000)
        host.memory = resources.memoryBytes
        host.pidsLimit = resources.pidsLimit
        host.networkMode = serviceNetwork ?? network.rawValue
        host.shmSize = 256 << 20
        var mounts = ([projectRoot] + extraMounts).map { Mount(type: .bind, source: $0, target: $0, createMountpoint: false) }
        mounts += userMounts.map { Mount(type: .bind, source: $0.path, target: $0.path, readOnly: $0.readOnly, createMountpoint: false) }
        mounts += caches.sorted { $0.key < $1.key }.map { Mount(type: .volume, source: volumeName($0.key), target: $0.value) }
        mounts.append(Mount(type: .volume, source: volumeName("home"), target: Self.home))
        // Nested in the home volume where the tools expect them (the daemon mounts parents first).
        mounts += (cacheMounts ?? []).sorted { $0.path < $1.path }.map { Mount(type: .volume, source: $0.volumeName(projectKey: projectKey), target: $0.path) }
        host.mounts = mounts
        if network == .bridge, serviceNetwork == nil, !publishedPorts.isEmpty {
            body.exposedPorts = Dictionary(uniqueKeysWithValues: publishedPorts.map { ("\($0)/tcp", EmptyObject()) })
            // Loopback only: Rancher Desktop forwards a 0.0.0.0 binding to every interface of the Mac.
            host.portBindings = Dictionary(uniqueKeysWithValues: publishedPorts.map {
                ("\($0)/tcp", [PortBinding(hostIP: "127.0.0.1", hostPort: "")])
            })
        }
        body.hostConfig = host
        corporateNetwork?.apply(to: &body, noProxyExtra: serviceNames ?? [])
        return body
    }

    /// Hash of everything that requires recreating the container (image ID included), stored as a label.
    public func configHash(imageID: String?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(createBody(imageID: imageID))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// True when `path` is the project or one of its worktree folders (or inside them).
    public func contains(_ path: String) -> Bool {
        workspaceRoots.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}
