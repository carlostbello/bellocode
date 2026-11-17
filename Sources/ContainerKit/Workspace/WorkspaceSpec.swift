import CryptoKit
import Foundation

/// The per-project "Environment" setting: everything that decides what the workspace container looks like.
/// Secrets are not part of it: they are passed per exec (in memory, over the socket) and never stored in the
/// container's configuration, which `inspect` would reveal and the daemon persists.
public struct WorkspaceSpec: Sendable, Equatable, Codable {
    public enum Network: String, Sendable, Codable {
        /// Default bridge: outbound access, no inbound except published ports.
        case bridge
        /// No network at all (offline builds and tests).
        case none
    }

    /// Host directory of the project (a git repository root). Mounted at the same absolute path.
    public var projectRoot: String
    /// Further host directories mounted at the same path (opencode's worktree directory for this project).
    public var extraMounts: [String]
    public var image: String
    /// `uid:gid` the commands run as; defaults to the host user so files created in the container belong to them.
    public var user: String
    public var network: Network
    /// Container ports published on host loopback when the container is created (host port chosen by the daemon).
    public var publishedPorts: [Int]
    public var cpus: Double
    public var memoryBytes: Int64
    public var pidsLimit: Int64
    /// Non-secret variables baked into the container.
    public var environment: [String: String]
    /// Named caches (volume name suffix → container path), kept across rebuilds.
    public var caches: [String: String]
    /// Extra labels (the spike marks everything with `bellocode.spike=1`).
    public var extraLabels: [String: String]

    public init(projectRoot: String, extraMounts: [String] = [], image: String, user: String = "\(getuid()):\(getgid())",
                network: Network = .bridge, publishedPorts: [Int] = [], cpus: Double = 2, memoryBytes: Int64 = 4 << 30,
                pidsLimit: Int64 = 4096, environment: [String: String] = [:], caches: [String: String] = [:],
                extraLabels: [String: String] = [:]) {
        self.projectRoot = projectRoot
        self.extraMounts = extraMounts
        self.image = image
        self.user = user
        self.network = network
        self.publishedPorts = publishedPorts
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.pidsLimit = pidsLimit
        self.environment = environment
        self.caches = caches
        self.extraLabels = extraLabels
    }

    public static let home = "/home/bellocode"
    public static let labelWorkspace = "app.bellocode.workspace"
    public static let labelProject = "app.bellocode.project"
    public static let labelConfig = "app.bellocode.config"

    /// Stable short identity of the project: names the container and its volumes.
    public var projectKey: String {
        let digest = SHA256.hash(data: Data(projectRoot.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    public var containerName: String { "bellocode-ws-\(projectKey)" }
    public func volumeName(_ cache: String) -> String { "bellocode-\(projectKey)-\(cache)" }

    /// The create body, without the config label.
    public func createBody(imageID: String?) -> ContainerCreate {
        var body = ContainerCreate(image: imageID ?? image)
        body.entrypoint = ["sleep"]
        body.cmd = ["infinity"]
        body.user = user
        body.workingDir = projectRoot
        body.env = (["HOME=\(Self.home)", "BELLOCODE_WORKSPACE=1"] + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        body.labels = [Self.labelWorkspace: "1", Self.labelProject: projectRoot].merging(extraLabels) { a, _ in a }
        body.stopSignal = "SIGTERM"
        body.stopTimeout = 3
        var host = HostConfig()
        host.init_ = true  // tini reaps orphans left by commands
        host.privileged = false
        host.capDrop = ["ALL"]
        // Only root execs issued by BelloCode itself (preparing $HOME) use these; non-root commands have no capabilities.
        host.capAdd = ["CHOWN", "DAC_OVERRIDE", "FOWNER"]
        host.securityOpt = ["no-new-privileges:true"]
        host.nanoCPUs = Int64(cpus * 1_000_000_000)
        host.memory = memoryBytes
        host.pidsLimit = pidsLimit
        host.networkMode = network.rawValue
        host.shmSize = 256 << 20
        var mounts = ([projectRoot] + extraMounts).map { Mount(type: .bind, source: $0, target: $0, createMountpoint: false) }
        mounts += caches.sorted { $0.key < $1.key }.map { Mount(type: .volume, source: volumeName($0.key), target: $0.value) }
        mounts.append(Mount(type: .volume, source: volumeName("home"), target: Self.home))
        host.mounts = mounts
        if network == .bridge, !publishedPorts.isEmpty {
            body.exposedPorts = Dictionary(uniqueKeysWithValues: publishedPorts.map { ("\($0)/tcp", EmptyObject()) })
            // Loopback only: Rancher Desktop forwards a 0.0.0.0 binding to every interface of the Mac.
            host.portBindings = Dictionary(uniqueKeysWithValues: publishedPorts.map { ("\($0)/tcp", [PortBinding(hostIP: "127.0.0.1", hostPort: "")]) })
        }
        body.hostConfig = host
        return body
    }

    /// Hash of everything that requires recreating the container (image ID included), stored as a label.
    public func configHash(imageID: String?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(createBody(imageID: imageID))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// True when `path` is the project or one of its mounts (or inside them).
    public func contains(_ path: String) -> Bool {
        ([projectRoot] + extraMounts).contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}
