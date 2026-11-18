import Foundation

// Subsets of the Docker Engine API v1.45+ schemas that BelloCode uses. Unknown fields are ignored on decode.

public struct EngineVersion: Decodable, Sendable, Equatable {
    public var version: String
    public var apiVersion: String
    public var minAPIVersion: String?
    public var os: String
    public var arch: String
    public var kernelVersion: String?

    enum CodingKeys: String, CodingKey {
        case version = "Version", apiVersion = "ApiVersion", minAPIVersion = "MinAPIVersion", os = "Os", arch = "Arch"
        case kernelVersion = "KernelVersion"
    }
}

public struct EngineInfo: Decodable, Sendable, Equatable {
    public var name: String?
    public var operatingSystem: String?
    public var ncpu: Int?
    public var memTotal: Int64?
    public var serverVersion: String?
    public var containers: Int?
    public var images: Int?

    enum CodingKeys: String, CodingKey {
        case name = "Name", operatingSystem = "OperatingSystem", ncpu = "NCPU", memTotal = "MemTotal"
        case serverVersion = "ServerVersion", containers = "Containers", images = "Images"
    }
}

public struct ImageSummary: Decodable, Sendable, Equatable {
    public var id: String
    public var repoDigests: [String]?
    public var architecture: String?
    public var size: Int64?
    public var labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", repoDigests = "RepoDigests", architecture = "Architecture", size = "Size"
        case config = "Config"
    }
    enum ConfigKeys: String, CodingKey { case labels = "Labels" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repoDigests = try c.decodeIfPresent([String].self, forKey: .repoDigests)
        architecture = try c.decodeIfPresent(String.self, forKey: .architecture)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        if let config = try? c.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config) {
            labels = try config.decodeIfPresent([String: String].self, forKey: .labels)
        }
    }
}

/// One line of `POST /images/create` or `POST /build` progress.
public struct ProgressMessage: Decodable, Sendable, Equatable {
    public var status: String?
    public var id: String?
    public var stream: String?
    public var error: String?
    public var progressDetail: Detail?
    public var aux: Aux?

    public struct Detail: Decodable, Sendable, Equatable {
        public var current: Int64?
        public var total: Int64?
    }
    public struct Aux: Decodable, Sendable, Equatable {
        public var id: String?
        enum CodingKeys: String, CodingKey { case id = "ID" }
    }
    enum CodingKeys: String, CodingKey {
        case status, id, stream, error, progressDetail, aux
        case errorDetail
    }
    struct ErrorDetail: Decodable { var message: String? }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        stream = try c.decodeIfPresent(String.self, forKey: .stream)
        progressDetail = try? c.decodeIfPresent(Detail.self, forKey: .progressDetail)
        aux = try? c.decodeIfPresent(Aux.self, forKey: .aux)
        error = try c.decodeIfPresent(String.self, forKey: .error)
            ?? (try? c.decodeIfPresent(ErrorDetail.self, forKey: .errorDetail))?.message
    }
}

public struct PortBinding: Codable, Sendable, Equatable, Hashable {
    public var hostIP: String
    public var hostPort: String
    public init(hostIP: String = "127.0.0.1", hostPort: String) {
        self.hostIP = hostIP
        self.hostPort = hostPort
    }
    enum CodingKeys: String, CodingKey { case hostIP = "HostIp", hostPort = "HostPort" }
}

public struct Mount: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case bind, volume, tmpfs }
    public var type: Kind
    public var source: String?
    public var target: String
    public var readOnly: Bool?
    public var bindOptions: BindOptions?

    public struct BindOptions: Codable, Sendable, Equatable, Hashable {
        public var createMountpoint: Bool?
        enum CodingKeys: String, CodingKey { case createMountpoint = "CreateMountpoint" }
    }

    public init(type: Kind, source: String?, target: String, readOnly: Bool? = nil, createMountpoint: Bool? = nil) {
        self.type = type
        self.source = source
        self.target = target
        self.readOnly = readOnly
        self.bindOptions = createMountpoint.map { BindOptions(createMountpoint: $0) }
    }
    enum CodingKeys: String, CodingKey {
        case type = "Type", source = "Source", target = "Target", readOnly = "ReadOnly", bindOptions = "BindOptions"
    }
}

public struct HostConfig: Codable, Sendable, Equatable {
    public var mounts: [Mount]?
    public var portBindings: [String: [PortBinding]]?
    public var init_: Bool?
    public var privileged: Bool?
    public var readonlyRootfs: Bool?
    public var capDrop: [String]?
    public var capAdd: [String]?
    public var securityOpt: [String]?
    public var nanoCPUs: Int64?
    public var memory: Int64?
    public var pidsLimit: Int64?
    public var networkMode: String?
    public var autoRemove: Bool?
    public var shmSize: Int64?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case mounts = "Mounts", portBindings = "PortBindings", init_ = "Init", privileged = "Privileged"
        case readonlyRootfs = "ReadonlyRootfs", capDrop = "CapDrop", capAdd = "CapAdd", securityOpt = "SecurityOpt"
        case nanoCPUs = "NanoCpus", memory = "Memory", pidsLimit = "PidsLimit", networkMode = "NetworkMode"
        case autoRemove = "AutoRemove", shmSize = "ShmSize"
    }
}

public struct EmptyObject: Codable, Sendable, Equatable, Hashable { public init() {} }

public struct ContainerCreate: Codable, Sendable, Equatable {
    public var image: String
    public var cmd: [String]?
    public var entrypoint: [String]?
    public var env: [String]?
    public var user: String?
    public var workingDir: String?
    public var labels: [String: String]?
    public var exposedPorts: [String: EmptyObject]?
    public var tty: Bool?
    public var openStdin: Bool?
    public var attachStdin: Bool?
    public var attachStdout: Bool?
    public var attachStderr: Bool?
    public var stopSignal: String?
    public var stopTimeout: Int?
    public var hostConfig: HostConfig?
    public var healthcheck: HealthConfig?
    public var hostname: String?
    public var networkingConfig: NetworkingConfig?

    public init(image: String) { self.image = image }

    enum CodingKeys: String, CodingKey {
        case image = "Image", cmd = "Cmd", entrypoint = "Entrypoint", env = "Env", user = "User"
        case workingDir = "WorkingDir", labels = "Labels", exposedPorts = "ExposedPorts", tty = "Tty"
        case openStdin = "OpenStdin", attachStdin = "AttachStdin", attachStdout = "AttachStdout"
        case attachStderr = "AttachStderr", stopSignal = "StopSignal", stopTimeout = "StopTimeout"
        case hostConfig = "HostConfig", healthcheck = "Healthcheck", hostname = "Hostname", networkingConfig = "NetworkingConfig"
    }
}

/// A container's healthcheck (durations in nanoseconds).
public struct HealthConfig: Codable, Sendable, Equatable, Hashable {
    public var test: [String]
    public var interval: Int64?
    public var timeout: Int64?
    public var startPeriod: Int64?
    public var retries: Int?
    public init(test: [String], interval: Int64? = nil, timeout: Int64? = nil, startPeriod: Int64? = nil, retries: Int? = nil) {
        self.test = test
        self.interval = interval
        self.timeout = timeout
        self.startPeriod = startPeriod
        self.retries = retries
    }
    enum CodingKeys: String, CodingKey { case test = "Test", interval = "Interval", timeout = "Timeout", startPeriod = "StartPeriod", retries = "Retries" }
}

/// Networks a container joins at create, with its DNS aliases there.
public struct NetworkingConfig: Codable, Sendable, Equatable {
    public struct Endpoint: Codable, Sendable, Equatable {
        public var aliases: [String]?
        public init(aliases: [String]?) { self.aliases = aliases }
        enum CodingKeys: String, CodingKey { case aliases = "Aliases" }
    }
    public var endpointsConfig: [String: Endpoint]
    public init(endpointsConfig: [String: Endpoint]) { self.endpointsConfig = endpointsConfig }
    enum CodingKeys: String, CodingKey { case endpointsConfig = "EndpointsConfig" }
}

/// One network (`GET /networks/{id}`): attached containers are listed only by inspect.
public struct NetworkInfo: Decodable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var labels: [String: String]
    public var isInternal: Bool
    public var containers: [String]
    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name", labels = "Labels", isInternal = "Internal", containers = "Containers" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        labels = (try? c.decodeIfPresent([String: String].self, forKey: .labels)) ?? [:]
        isInternal = (try? c.decodeIfPresent(Bool.self, forKey: .isInternal)) ?? false
        containers = Array(((try? c.decodeIfPresent([String: EmptyObject].self, forKey: .containers)) ?? [:]).keys)
    }
    public init(id: String, name: String, labels: [String: String], isInternal: Bool, containers: [String]) {
        self.id = id
        self.name = name
        self.labels = labels
        self.isInternal = isInternal
        self.containers = containers
    }
}

/// One volume with its labels and, from `GET /system/df`, its size and how many containers use it.
public struct VolumeInfo: Decodable, Sendable, Equatable, Hashable {
    public var name: String
    public var labels: [String: String]
    public var size: Int64?
    public var refCount: Int?
    enum CodingKeys: String, CodingKey { case name = "Name", labels = "Labels", usageData = "UsageData" }
    struct Usage: Decodable { var Size: Int64?; var RefCount: Int? }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        labels = (try? c.decodeIfPresent([String: String].self, forKey: .labels)) ?? [:]
        let usage = try? c.decodeIfPresent(Usage.self, forKey: .usageData)
        size = usage?.Size.flatMap { $0 >= 0 ? $0 : nil }
        refCount = usage?.RefCount.flatMap { $0 >= 0 ? $0 : nil }
    }
    public init(name: String, labels: [String: String], size: Int64? = nil, refCount: Int? = nil) {
        self.name = name
        self.labels = labels
        self.size = size
        self.refCount = refCount
    }
}

/// One local image (`GET /images/json`).
public struct ImageListItem: Decodable, Sendable, Equatable, Hashable {
    public var id: String
    public var repoTags: [String]
    public var size: Int64?
    public var containers: Int?
    enum CodingKeys: String, CodingKey { case id = "Id", repoTags = "RepoTags", size = "Size", containers = "Containers" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repoTags = (try? c.decodeIfPresent([String].self, forKey: .repoTags)) ?? []
        size = try? c.decodeIfPresent(Int64.self, forKey: .size)
        containers = try? c.decodeIfPresent(Int.self, forKey: .containers)
    }
}

struct IDResponse: Decodable {
    var id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
}

public struct ContainerSummary: Decodable, Sendable, Equatable {
    public var id: String
    public var names: [String]
    public var image: String
    public var state: String
    public var status: String?
    public var labels: [String: String]
    /// Creation time, seconds since 1970.
    public var created: Int64?

    public init(id: String, names: [String], image: String, state: String, status: String? = nil, labels: [String: String],
                created: Int64? = nil) {
        self.id = id
        self.names = names
        self.image = image
        self.state = state
        self.status = status
        self.labels = labels
        self.created = created
    }

    public var name: String { (names.first ?? id).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    public var isRunning: Bool { state == "running" }

    enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", state = "State", status = "Status", labels = "Labels"
        case created = "Created"
    }
}

public struct ContainerInspect: Decodable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var image: String
    public var state: State
    public var config: Config
    public var ports: [String: [PortBinding]?]?
    /// Execs created in this container that the daemon still knows (running or recently ended).
    public var execIDs: [String]?
    /// The host configuration as created (mounts, limits, network): what `inspect` reveals to anyone with the socket.
    public var hostConfig: HostConfig?

    public struct State: Decodable, Sendable, Equatable {
        public var status: String
        public var running: Bool
        public var exitCode: Int?
        public var pid: Int?
        public var health: Health?
        public struct Health: Decodable, Sendable, Equatable {
            /// `starting`, `healthy` or `unhealthy`.
            public var status: String
            enum CodingKeys: String, CodingKey { case status = "Status" }
        }
        enum CodingKeys: String, CodingKey { case status = "Status", running = "Running", exitCode = "ExitCode", pid = "Pid", health = "Health" }
    }
    public struct Config: Decodable, Sendable, Equatable {
        public var labels: [String: String]?
        public var image: String?
        /// The container's own environment (never secrets: those travel per exec).
        public var env: [String]?
        enum CodingKeys: String, CodingKey { case labels = "Labels", image = "Image", env = "Env" }
    }
    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", image = "Image", state = "State", config = "Config"
        case networkSettings = "NetworkSettings", execIDs = "ExecIDs", hostConfig = "HostConfig"
    }
    enum NetworkKeys: String, CodingKey { case ports = "Ports" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        image = try c.decode(String.self, forKey: .image)
        state = try c.decode(State.self, forKey: .state)
        config = try c.decode(Config.self, forKey: .config)
        execIDs = try? c.decodeIfPresent([String].self, forKey: .execIDs)
        hostConfig = try? c.decodeIfPresent(HostConfig.self, forKey: .hostConfig)
        if let network = try? c.nestedContainer(keyedBy: NetworkKeys.self, forKey: .networkSettings) {
            ports = try? network.decodeIfPresent([String: [PortBinding]?].self, forKey: .ports)
        }
    }
}

public struct ExecConfig: Encodable, Sendable, Equatable {
    public var cmd: [String]
    public var env: [String]?
    public var workingDir: String?
    public var user: String?
    public var tty: Bool
    public var attachStdin: Bool
    public var attachStdout: Bool = true
    public var attachStderr: Bool = true
    public var consoleSize: [Int]?  // [rows, cols]

    public init(cmd: [String], env: [String]? = nil, workingDir: String? = nil, user: String? = nil, tty: Bool = false,
                attachStdin: Bool = false, consoleSize: (rows: Int, cols: Int)? = nil) {
        self.cmd = cmd
        self.env = env
        self.workingDir = workingDir
        self.user = user
        self.tty = tty
        self.attachStdin = attachStdin
        self.consoleSize = consoleSize.map { [$0.rows, $0.cols] }
    }
    enum CodingKeys: String, CodingKey {
        case cmd = "Cmd", env = "Env", workingDir = "WorkingDir", user = "User", tty = "Tty"
        case attachStdin = "AttachStdin", attachStdout = "AttachStdout", attachStderr = "AttachStderr"
        case consoleSize = "ConsoleSize"
    }
}

public struct ExecInspect: Decodable, Sendable, Equatable {
    public var id: String
    public var running: Bool
    public var exitCode: Int?
    public var pid: Int?
    /// The exec's arguments after its entrypoint (`ProcessConfig.arguments`).
    public var arguments: [String]?
    enum CodingKeys: String, CodingKey { case id = "ID", running = "Running", exitCode = "ExitCode", pid = "Pid", processConfig = "ProcessConfig" }
    struct ProcessConfig: Decodable { var arguments: [String]?; enum CodingKeys: String, CodingKey { case arguments } }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        running = try c.decode(Bool.self, forKey: .running)
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        arguments = (try? c.decodeIfPresent(ProcessConfig.self, forKey: .processConfig))?.arguments
    }

    /// A long-lived relayed program (`StdioRelay`, a local MCP server): not a command, so it neither keeps the
    /// container from idling nor holds back the stray-process reaper.
    public var isRelayedProgram: Bool { (arguments?.count ?? 0) >= 3 && arguments?[2] == StdioRelay.processName }
}

public struct EngineEvent: Decodable, Sendable, Equatable {
    public var type: String
    public var action: String
    public var actorID: String
    public var attributes: [String: String]
    public var time: Int64?

    enum CodingKeys: String, CodingKey { case type = "Type", action = "Action", actor = "Actor", time }
    enum ActorKeys: String, CodingKey { case id = "ID", attributes = "Attributes" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        time = try c.decodeIfPresent(Int64.self, forKey: .time)
        let actor = try c.nestedContainer(keyedBy: ActorKeys.self, forKey: .actor)
        actorID = try actor.decodeIfPresent(String.self, forKey: .id) ?? ""
        attributes = try actor.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
    }
}

struct WaitResponse: Decodable {
    var statusCode: Int
    enum CodingKeys: String, CodingKey { case statusCode = "StatusCode" }
}

struct ContainerErrorBody: Decodable {
    var message: String
}
