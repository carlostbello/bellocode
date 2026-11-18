import ContainerKit
import Foundation

/// A project's "Environment" setting (Project Settings ▸ Environment). Everything here is non-secret; registry
/// passwords live in the Keychain and secrets for commands travel per exec.
public struct ProjectEnvironmentSettings: Codable, Sendable, Equatable {
    /// The image reference; nil uses the app-wide default (Settings ▸ Containers). There is no built-in default.
    public var image: String?
    /// Non-secret variables set in the container.
    public var environment: [String: String]
    public var resources: ResourceLimits
    /// Extra host folders mounted at the same path (off by default).
    public var userMounts: [UserMount]
    public var network: WorkspaceSpec.Network
    /// Raise inotify events in the container for host-side edits (hot reload, test watchers).
    public var fileWatchBridge: Bool
    /// Stop the container after this many minutes without commands, terminals or forwarded ports (0 = never).
    public var idleStopMinutes: Int
    /// Local (stdio) MCP servers of this project: they run in its container (`bellocode-exec --stdio`).
    public var mcpServers: [MCPServerSetting]
    /// Services defined in the Environment pane (compose subset), used when the project has no compose file.
    public var servicesYAML: String?
    /// Package-manager caches chosen for this project (an image's declared caches apply unless turned off here).
    public var caches: [CacheSelection]

    public init(image: String? = nil, environment: [String: String] = [:], resources: ResourceLimits = .standard,
                userMounts: [UserMount] = [], network: WorkspaceSpec.Network = .bridge, fileWatchBridge: Bool = true,
                idleStopMinutes: Int = 30, mcpServers: [MCPServerSetting] = [], servicesYAML: String? = nil, caches: [CacheSelection] = []) {
        self.caches = caches
        self.mcpServers = mcpServers
        self.servicesYAML = servicesYAML
        self.image = image
        self.environment = environment
        self.resources = resources
        self.userMounts = userMounts
        self.network = network
        self.fileWatchBridge = fileWatchBridge
        self.idleStopMinutes = idleStopMinutes
    }

    public static let `default` = ProjectEnvironmentSettings()

    enum CodingKeys: String, CodingKey { case image, environment, resources, userMounts, network, fileWatchBridge, idleStopMinutes, mcpServers, servicesYAML, caches }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        resources = try c.decodeIfPresent(ResourceLimits.self, forKey: .resources) ?? .standard
        userMounts = try c.decodeIfPresent([UserMount].self, forKey: .userMounts) ?? []
        network = try c.decodeIfPresent(WorkspaceSpec.Network.self, forKey: .network) ?? .bridge
        fileWatchBridge = try c.decodeIfPresent(Bool.self, forKey: .fileWatchBridge) ?? true
        idleStopMinutes = try c.decodeIfPresent(Int.self, forKey: .idleStopMinutes) ?? 30
        mcpServers = try c.decodeIfPresent([MCPServerSetting].self, forKey: .mcpServers) ?? []
        servicesYAML = try c.decodeIfPresent(String.self, forKey: .servicesYAML)
        caches = try c.decodeIfPresent([CacheSelection].self, forKey: .caches) ?? []
    }

    /// The cache mounts for this project: its own choices plus what the image declares (`PackageCache.declared`),
    /// at the image's path when it names one; per project unless shared was chosen for that cache.
    public func cacheMounts(imageDeclared: [PackageCache: String]) -> [CacheMount] {
        var mounts: [PackageCache: CacheMount] = [:]
        for (cache, path) in imageDeclared { mounts[cache] = CacheMount(cache: cache, path: path) }
        for selection in caches {
            if selection.enabled {
                mounts[selection.cache] = CacheMount(cache: selection.cache, path: imageDeclared[selection.cache] ?? selection.cache.defaultPath,
                                                     shared: selection.shared)
            } else {
                mounts[selection.cache] = nil
            }
        }
        return mounts.values.sorted { $0.cache.rawValue < $1.cache.rawValue }
    }

    /// Names that may not be set as plain variables: they are the container's own or BelloCode's.
    public static let reservedVariables: Set<String> = ["HOME", "PATH", "BELLOCODE_WORKSPACE", "BUN_BE_BUN"]

    /// Problems with the setting, phrased for the pane; empty when valid.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        if let image, image.contains(where: \.isWhitespace) || image.isEmpty { errors.append("The image reference has spaces or is empty.") }
        for name in environment.keys.sorted() {
            if name.isEmpty || name.contains("=") || name.first?.isNumber == true { errors.append("“\(name)” is not a valid variable name.") }
            if Self.reservedVariables.contains(name) || name.hasPrefix("BUN_") { errors.append("\(name) cannot be set here.") }
        }
        if resources.cpus <= 0 || resources.memoryBytes < 256 << 20 || resources.pidsLimit < 64 {
            errors.append("Resource limits are too small (at least 0.1 CPU, 256 MB memory, 64 processes).")
        }
        var names = Set<String>()
        for server in mcpServers {
            errors += server.validationErrors()
            if !names.insert(server.name).inserted { errors.append("Two MCP servers are named “\(server.name)”.") }
        }
        for mount in userMounts where !RancherFileSharing.isShared(mount.path) {
            errors.append("\(mount.path) is not shared with Rancher Desktop (only your home folder, /Volumes and temporary folders are).")
        }
        return errors
    }
}

/// One package-manager cache choice of a project.
public struct CacheSelection: Codable, Sendable, Equatable, Hashable {
    public var cache: PackageCache
    /// Off turns off a cache the image declares.
    public var enabled: Bool
    /// One volume for every project that also opts in (off: the project's own volume).
    public var shared: Bool

    public init(cache: PackageCache, enabled: Bool = true, shared: Bool = false) {
        self.cache = cache
        self.enabled = enabled
        self.shared = shared
    }
}

/// A local (stdio) MCP server of one project. It runs in the project's workspace container: BelloCode registers it with
/// opencode for the project's location with the command rewritten to `bellocode-exec --stdio` (`MCPRouting`).
public struct MCPServerSetting: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// The server's name (its tools appear to the agent as `<name>_<tool>`).
    public var name: String
    /// The program and its arguments, as run inside the container (e.g. `["node", "tools/mcp.js"]`).
    public var command: [String]
    /// Non-secret variables for the server (visible to it in the container).
    public var environment: [String: String]
    public var enabled: Bool
    public var id: String { name }

    public init(name: String, command: [String], environment: [String: String] = [:], enabled: Bool = true) {
        self.name = name
        self.command = command
        self.environment = environment
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey { case name, command, environment, enabled }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode([String].self, forKey: .command)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func validationErrors() -> [String] {
        var errors: [String] = []
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if name.isEmpty || name.unicodeScalars.contains(where: { !allowed.contains($0) }) || name.count > 48 {
            errors.append("MCP server name “\(name)”: use letters, digits, - and _ (at most 48).")
        }
        if command.first?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { errors.append("MCP server “\(name)” has no command.") }
        for key in environment.keys where key.isEmpty || key.contains("=") || key.hasPrefix("BUN_") || key.hasPrefix("BELLOCODE_") {
            errors.append("MCP server “\(name)”: \(key) cannot be set.")
        }
        return errors
    }

    /// Splits a command line the way a shell would for plain words and quotes (no expansion): `node "my tool.js" -v`.
    public static func split(commandLine: String) -> [String] { ShellWords.split(commandLine) }

    /// The command as one line (for the pane), quoting words with spaces or quotes.
    public var commandLine: String {
        command.map { word in
            word.isEmpty || word.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" })
                ? "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" : word
        }.joined(separator: " ")
    }
}

/// App-wide container settings (Settings ▸ Containers), stored as an app preference.
public struct EnvironmentDefaults: Codable, Sendable, Equatable {
    /// The image used by projects that do not set one: an administrator points it at the internal registry.
    public var defaultImage: String?
    /// Another Engine API socket than Rancher Desktop's `~/.rd/docker.sock`.
    public var socketOverride: String?
    /// The image policy set in Settings (an administrator's managed policy wins over it).
    public var imagePolicy: ImagePolicy?

    public init(defaultImage: String? = nil, socketOverride: String? = nil, imagePolicy: ImagePolicy? = nil) {
        self.defaultImage = defaultImage
        self.socketOverride = socketOverride
        self.imagePolicy = imagePolicy
    }

    public static let preferenceKey = "containers.defaults"
}

/// What BelloCode last knew about a project's workspace container (persisted with the setting).
public struct EnvironmentRecord: Codable, Sendable, Equatable {
    public var imageID: String?
    public var imageDigest: String?
    public var containerID: String?
    public var mountIdentity: String?
    public var inventory: ContainerProbes.ToolInventory?
    public var lastUsed: Date?
    /// The caches the image declares (its labels), learned when the image was inspected.
    public var imageCaches: [PackageCache: String]?

    public init(imageID: String? = nil, imageDigest: String? = nil, containerID: String? = nil, mountIdentity: String? = nil,
                inventory: ContainerProbes.ToolInventory? = nil, lastUsed: Date? = nil) {
        self.imageID = imageID
        self.imageDigest = imageDigest
        self.containerID = containerID
        self.mountIdentity = mountIdentity
        self.inventory = inventory
        self.lastUsed = lastUsed
    }
}

/// One row of `app_environment`.
public struct StoredEnvironment: Codable, Sendable, Equatable {
    public var settings: ProjectEnvironmentSettings
    public var record: EnvironmentRecord

    public init(settings: ProjectEnvironmentSettings = .default, record: EnvironmentRecord = EnvironmentRecord()) {
        self.settings = settings
        self.record = record
    }
}

/// Pull progress, aggregated over layers.
public struct PullProgress: Sendable, Equatable {
    public var fraction: Double?
    public var detail: String
    public init(fraction: Double? = nil, detail: String) {
        self.fraction = fraction
        self.detail = detail
    }
}

/// Where a project's environment stands. Every state has text, a glyph and (when blocked) a fix.
public enum EnvironmentPhase: Sendable, Equatable {
    /// Not checked yet (launch, before the runtime answered).
    case unknown
    /// No image for this project and no app-wide default.
    case noImage
    /// The runtime cannot run anything (not installed, not running, containerd, unsupported).
    case runtimeUnavailable(RuntimeState)
    /// The image is downloading.
    case pulling(PullProgress)
    case pullFailed(message: String, needsSignIn: Bool)
    /// A mounted folder is missing or not shared with Rancher Desktop.
    case unmountable([String])
    /// Creating or starting the container.
    case starting
    /// Running and ready for commands.
    case ready
    /// Image present, container stopped or not created yet: it starts on the first command.
    case idle
    case failed(String)
    /// The project's saved execution policy is not in force yet (still loading) or could not be read: nothing may run
    /// under a guessed (default) policy (S3 in docs/reviews/deep-review-1.md).
    case policyUnavailable(String)
    /// The image is outside the image policy (allowlist, digest, signature, pull policy): nothing is pulled or run.
    case imageRefused(String)

    public var isBlocking: Bool { blocked != nil }

    /// What the helper reports instead of running a command, and the fix shown in the banner.
    public var blocked: ExecHelperConfig.Blocked? {
        switch self {
        case .unknown, .ready, .idle, .starting: nil
        case .noImage:
            .init(message: "No container image is set for this project, so commands cannot run. Choose an image in Project Settings ▸ Environment (or set a default in Settings ▸ Containers).",
                  fix: EnvironmentFix.chooseImage.title)
        case .runtimeUnavailable(let state): .init(message: state.userMessage, fix: EnvironmentFix(state.fix)?.title)
        case .pulling(let progress):
            .init(message: "The project's container image is still downloading (\(progress.detail)). Retry when it finishes.")
        case .pullFailed(let message, let needsSignIn):
            needsSignIn
                ? .init(message: "Pulling the project's image failed: the registry needs you to sign in (\(message)). Sign in to the registry in Project Settings ▸ Environment.",
                        fix: EnvironmentFix.signIn.title)
                : .init(message: "Pulling the project's image failed (\(message)). Check the image name or the network, then retry the pull.",
                        fix: EnvironmentFix.retry.title)
        case .unmountable(let paths):
            .init(message: "The container cannot mount \(paths.joined(separator: ", ")): the folder is missing or not shared with Rancher Desktop (only your home folder, /Volumes and temporary folders are).",
                  fix: EnvironmentFix.openSettings.title)
        case .failed(let message): .init(message: "The project's container failed: \(message)", fix: EnvironmentFix.retry.title)
        case .policyUnavailable(let message): .init(message: message, fix: EnvironmentFix.openSettings.title)
        case .imageRefused(let message): .init(message: message, fix: EnvironmentFix.chooseImage.title)
        }
    }

    /// A short word or two for status lines ("Ready", "Pulling 40 %").
    public var label: String {
        switch self {
        case .unknown: "Checking"
        case .noImage: "No image"
        case .runtimeUnavailable(let state): state.shortLabel
        case .pulling(let progress): progress.fraction.map { "Pulling \(Int($0 * 100)) %" } ?? "Pulling"
        case .pullFailed(_, let signIn): signIn ? "Sign-in needed" : "Pull failed"
        case .unmountable: "Folder not shared"
        case .starting: "Starting"
        case .ready: "Running"
        case .idle: "Stopped"
        case .failed: "Failed"
        case .policyUnavailable: "Settings unavailable"
        case .imageRefused: "Image not allowed"
        }
    }

    /// SF Symbol for the state (always shown with `label`, never alone).
    public var symbolName: String {
        switch self {
        case .unknown, .starting, .pulling: "arrow.triangle.2.circlepath"
        case .ready: "shippingbox.fill"
        case .idle: "shippingbox"
        case .noImage, .unmountable: "exclamationmark.triangle"
        case .runtimeUnavailable, .pullFailed, .failed, .policyUnavailable: "xmark.octagon"
        case .imageRefused: "hand.raised"
        }
    }

    public var tone: EnvironmentTone {
        switch self {
        case .ready: .success
        case .idle, .unknown: .neutral
        case .starting, .pulling: .info
        case .noImage, .unmountable: .warning
        case .runtimeUnavailable, .pullFailed, .failed, .policyUnavailable, .imageRefused: .danger
        }
    }
}

public enum EnvironmentTone: Sendable, Equatable { case neutral, info, success, warning, danger }

/// The one action that fixes a blocked environment; the app performs it.
public enum EnvironmentFix: String, Sendable, Equatable, CaseIterable {
    case startRancher
    case switchEngine
    case installRancher
    case updateRuntime
    case chooseImage
    case signIn
    case retry
    case openSettings

    public init?(_ fix: RuntimeState.Fix?) {
        switch fix {
        case .startRancher: self = .startRancher
        case .switchEngine: self = .switchEngine
        case .installRancher: self = .installRancher
        case .updateRuntime: self = .updateRuntime
        case nil: return nil
        }
    }

    public var title: String {
        switch self {
        case .startRancher: "Start Rancher Desktop"
        case .switchEngine: "Switch the container engine to dockerd"
        case .installRancher: "Install Rancher Desktop"
        case .updateRuntime: "Update Rancher Desktop"
        case .chooseImage: "Choose an image"
        case .signIn: "Sign in to the registry"
        case .retry: "Retry"
        case .openSettings: "Open Environment Settings"
        }
    }
}

/// A banner for the thread and the terminal drawer: shown while commands cannot run.
public struct EnvironmentNotice: Sendable, Equatable {
    public var title: String
    public var message: String
    public var fix: EnvironmentFix?
    public var tone: EnvironmentTone
    public var symbolName: String

    public init(title: String, message: String, fix: EnvironmentFix?, tone: EnvironmentTone, symbolName: String) {
        self.title = title
        self.message = message
        self.fix = fix
        self.tone = tone
        self.symbolName = symbolName
    }

    /// The banner for a phase, or nil when commands can run.
    public static func from(_ phase: EnvironmentPhase) -> EnvironmentNotice? {
        guard let blocked = phase.blocked else { return nil }
        let title: String = switch phase {
        case .runtimeUnavailable(.wrongEngine): "Commands need the dockerd engine"
        case .runtimeUnavailable: "Commands cannot run: Rancher Desktop is \(phase.label.lowercased())"
        case .noImage: "Commands cannot run: no container image"
        case .pulling: "Downloading the container image"
        case .pullFailed(_, true): "Commands cannot run: sign in to the registry"
        case .pullFailed: "Commands cannot run: the image could not be pulled"
        case .unmountable: "Commands cannot run: a folder cannot be mounted"
        case .policyUnavailable: "Commands cannot run: the environment settings are unavailable"
        case .imageRefused: "Commands cannot run: the image is not allowed"
        default: "Commands cannot run"
        }
        let fix: EnvironmentFix? = switch phase {
        case .runtimeUnavailable(let state): EnvironmentFix(state.fix)
        case .noImage, .imageRefused: .chooseImage
        case .pullFailed(_, let signIn): signIn ? .signIn : .retry
        case .unmountable, .policyUnavailable: .openSettings
        case .failed: .retry
        default: nil
        }
        return EnvironmentNotice(title: title, message: blocked.message, fix: fix, tone: phase.tone, symbolName: phase.symbolName)
    }
}

/// A forwarded port (Ports list).
public struct PortForwardInfo: Sendable, Equatable, Identifiable {
    public var containerPort: Int
    public var hostPort: Int
    public var url: URL
    public var connections: Int
    public var id: Int { containerPort }
}

/// One BelloCode-managed container (Containers view).
public struct ManagedContainer: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var image: String
    public var state: String
    public var status: String
    public var projectDirectory: String?
    public var created: Date?
    /// The service name for a project service container; nil for a workspace.
    public var service: String?
    public var isRunning: Bool { state == "running" }
    /// `healthy`, `unhealthy` or `starting` from Docker's status text, when the container has a healthcheck.
    public var health: String? {
        for word in ["unhealthy", "healthy", "health: starting"] where status.contains("(\(word))") { return word == "health: starting" ? "starting" : word }
        return nil
    }

    public init(id: String, name: String, image: String, state: String, status: String, projectDirectory: String?, created: Date?,
                service: String? = nil) {
        self.service = service
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.projectDirectory = projectDirectory
        self.created = created
    }
}
