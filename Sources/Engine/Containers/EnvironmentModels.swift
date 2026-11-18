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

    public init(image: String? = nil, environment: [String: String] = [:], resources: ResourceLimits = .standard,
                userMounts: [UserMount] = [], network: WorkspaceSpec.Network = .bridge, fileWatchBridge: Bool = true,
                idleStopMinutes: Int = 30) {
        self.image = image
        self.environment = environment
        self.resources = resources
        self.userMounts = userMounts
        self.network = network
        self.fileWatchBridge = fileWatchBridge
        self.idleStopMinutes = idleStopMinutes
    }

    public static let `default` = ProjectEnvironmentSettings()

    enum CodingKeys: String, CodingKey { case image, environment, resources, userMounts, network, fileWatchBridge, idleStopMinutes }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        resources = try c.decodeIfPresent(ResourceLimits.self, forKey: .resources) ?? .standard
        userMounts = try c.decodeIfPresent([UserMount].self, forKey: .userMounts) ?? []
        network = try c.decodeIfPresent(WorkspaceSpec.Network.self, forKey: .network) ?? .bridge
        fileWatchBridge = try c.decodeIfPresent(Bool.self, forKey: .fileWatchBridge) ?? true
        idleStopMinutes = try c.decodeIfPresent(Int.self, forKey: .idleStopMinutes) ?? 30
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
        for mount in userMounts where !RancherFileSharing.isShared(mount.path) {
            errors.append("\(mount.path) is not shared with Rancher Desktop (only your home folder, /Volumes and temporary folders are).")
        }
        return errors
    }
}

/// App-wide container settings (Settings ▸ Containers), stored as an app preference.
public struct EnvironmentDefaults: Codable, Sendable, Equatable {
    /// The image used by projects that do not set one: an administrator points it at the internal registry.
    public var defaultImage: String?
    /// Another Engine API socket than Rancher Desktop's `~/.rd/docker.sock`.
    public var socketOverride: String?

    public init(defaultImage: String? = nil, socketOverride: String? = nil) {
        self.defaultImage = defaultImage
        self.socketOverride = socketOverride
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
        }
    }

    public var tone: EnvironmentTone {
        switch self {
        case .ready: .success
        case .idle, .unknown: .neutral
        case .starting, .pulling: .info
        case .noImage, .unmountable: .warning
        case .runtimeUnavailable, .pullFailed, .failed, .policyUnavailable: .danger
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
        default: "Commands cannot run"
        }
        let fix: EnvironmentFix? = switch phase {
        case .runtimeUnavailable(let state): EnvironmentFix(state.fix)
        case .noImage: .chooseImage
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
    public var isRunning: Bool { state == "running" }

    public init(id: String, name: String, image: String, state: String, status: String, projectDirectory: String?, created: Date?) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.projectDirectory = projectDirectory
        self.created = created
    }
}
