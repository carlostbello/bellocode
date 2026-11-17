import Foundation

/// What the user's container runtime can do for BelloCode right now. Every state has a sentence and a fix for the UI
/// and is never shown by colour alone.
public enum RuntimeState: Sendable, Equatable {
    /// Neither Rancher Desktop nor its user directory exists.
    case notInstalled
    /// Installed, but the Engine API socket is absent, refuses connections or does not answer (stopped or starting).
    case notRunning(socketPath: String)
    /// Rancher Desktop is set to containerd: there is no Docker-compatible API for BelloCode to drive.
    case wrongEngine(engine: String)
    /// The socket answers, but not like a usable Docker Engine: non-Linux containers, or an API version BelloCode does
    /// not speak (older than the minimum, or a daemon that dropped the minimum). `reason` says which.
    case unsupported(reason: String)
    /// Ready: `/_ping` and `/version` answered with a supported API.
    case ready(Ready)

    public struct Ready: Sendable, Equatable {
        public var socketPath: String
        public var engineVersion: String
        public var apiVersion: String
        public var arch: String
        public var kernel: String?
        /// Rancher Desktop's own version (from its app bundle), when found.
        public var rancherVersion: String?
        /// Non-blocking drift notes ("Rancher Desktop 1.30 is newer than the tested 1.25"), shown in the details.
        public var notes: [String]

        public init(socketPath: String, engineVersion: String, apiVersion: String, arch: String, kernel: String? = nil,
                    rancherVersion: String? = nil, notes: [String] = []) {
            self.socketPath = socketPath
            self.engineVersion = engineVersion
            self.apiVersion = apiVersion
            self.arch = arch
            self.kernel = kernel
            self.rancherVersion = rancherVersion
            self.notes = notes
        }
    }

    /// The one action that fixes a non-ready state, named as the button says it.
    public enum Fix: String, Sendable, Equatable {
        case installRancher = "Install Rancher Desktop"
        case startRancher = "Start Rancher Desktop"
        case switchEngine = "Switch the container engine to dockerd"
        case updateRuntime = "Update Rancher Desktop"
    }

    public var isReady: Bool { if case .ready = self { true } else { false } }

    public var fix: Fix? {
        switch self {
        case .notInstalled: .installRancher
        case .notRunning: .startRancher
        case .wrongEngine: .switchEngine
        case .unsupported: .updateRuntime
        case .ready: nil
        }
    }

    /// One word or two for the status item ("Ready", "Not running").
    public var shortLabel: String {
        switch self {
        case .notInstalled: "Not installed"
        case .notRunning: "Not running"
        case .wrongEngine: "Wrong engine"
        case .unsupported: "Unsupported"
        case .ready: "Ready"
        }
    }

    /// Text for the runtime status row and for the error a blocked command reports.
    public var userMessage: String {
        switch self {
        case .notInstalled:
            "Rancher Desktop is not installed. Commands run in a container, so BelloCode cannot run them until it is. Nothing runs on this Mac instead."
        case .notRunning:
            "Rancher Desktop is not running. Start Rancher Desktop to run commands; nothing runs on this Mac instead."
        case .wrongEngine(let engine):
            "Rancher Desktop uses the \(engine) engine. Switch the container engine to dockerd (moby) in Rancher Desktop ▸ Preferences ▸ Container Engine."
        case .unsupported(let reason):
            "The container runtime is not usable: \(reason). Update Rancher Desktop."
        case .ready(let ready):
            "Rancher Desktop\(ready.rancherVersion.map { " \($0)" } ?? "") ready: Docker Engine \(ready.engineVersion), API \(ready.apiVersion), \(ready.arch)"
        }
    }
}

/// The parts of the machine discovery looks at, injectable for tests.
public protocol RuntimeProbeEnvironment: Sendable {
    func fileExists(_ path: String) -> Bool
    func readFile(_ path: String) -> Data?
    /// `/_ping` then `/version` on `socketPath`, each with a short deadline.
    func probe(socketPath: String) async throws -> EngineVersion
}

public struct LiveRuntimeProbeEnvironment: RuntimeProbeEnvironment {
    public init() {}
    public func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    public func readFile(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }
    public func probe(socketPath: String) async throws -> EngineVersion {
        var client = EngineClient(socketPath: socketPath)
        client.requestTimeout = .seconds(4)
        _ = try await client.ping()
        return try await client.version()
    }
}

/// Finds Rancher Desktop's Docker-compatible Engine API. Read-only: it never starts the VM, never switches engines,
/// and reads only two things of Rancher's: its app bundle's `Info.plist` (version) and `containerEngine.name` in its
/// settings. It never opens the management API's credentials file (`rd-engine.json`).
public struct RuntimeDiscovery: Sendable {
    public var home: String
    public var environment: any RuntimeProbeEnvironment
    /// Explicit socket (a setting), tried instead of Rancher's default.
    public var overrideSocket: String?
    /// The oldest Engine API BelloCode speaks (every endpoint it uses exists there). Requests use this version prefix.
    public static let minimumAPIVersion = "1.44"
    /// The Rancher Desktop line the production path was measured on; newer versions get a drift note, not a refusal.
    public static let testedRancherVersion = "1.25"

    public init(home: String = NSHomeDirectory(), environment: any RuntimeProbeEnvironment = LiveRuntimeProbeEnvironment(),
                overrideSocket: String? = nil) {
        self.home = home
        self.environment = environment
        self.overrideSocket = overrideSocket
    }

    public var appPath: String { "/Applications/Rancher Desktop.app" }
    public var userAppPath: String { home + "/Applications/Rancher Desktop.app" }
    public var socketPath: String { overrideSocket ?? home + "/.rd/docker.sock" }
    /// Rancher Desktop's settings file; only `containerEngine.name` is read.
    public var settingsPath: String { home + "/Library/Preferences/rancher-desktop/settings.json" }

    /// The engine named in Rancher's settings (`moby` or `containerd`), if readable.
    public func configuredEngine() -> String? {
        guard let data = environment.readFile(settingsPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let engine = object["containerEngine"] as? [String: Any] else { return nil }
        return engine["name"] as? String
    }

    /// `CFBundleShortVersionString` of the installed Rancher Desktop app, if any.
    public func rancherVersion() -> String? {
        for app in [appPath, userAppPath] {
            guard let data = environment.readFile(app + "/Contents/Info.plist"),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = plist["CFBundleShortVersionString"] as? String else { continue }
            return version
        }
        return nil
    }

    public func detect() async -> RuntimeState {
        let installed = environment.fileExists(appPath) || environment.fileExists(userAppPath)
            || environment.fileExists(home + "/.rd") || overrideSocket != nil
        guard installed else { return .notInstalled }
        if overrideSocket == nil, let engine = configuredEngine(), engine != "moby", engine != "dockerd" {
            return .wrongEngine(engine: engine)
        }
        guard environment.fileExists(socketPath) else { return .notRunning(socketPath: socketPath) }
        do {
            let version = try await environment.probe(socketPath: socketPath)
            return Self.evaluate(version, socketPath: socketPath, rancherVersion: rancherVersion())
        } catch let error as SocketError where error.isConnectionRefusedOrMissing {
            return .notRunning(socketPath: socketPath)
        } catch is HTTPParseError {
            // Lima accepts on the forwarded socket even when nothing listens inside the VM, then closes.
            return .notRunning(socketPath: socketPath)
        } catch let error as ContainerError {
            switch error {
            case .timedOut, .unreachable: return .notRunning(socketPath: socketPath)
            default: return .unsupported(reason: error.description)
            }
        } catch let error as SocketError {
            return .unsupported(reason: error.description)
        } catch {
            return .unsupported(reason: String(describing: error))
        }
    }

    /// Version policy, pure: Linux only; API at least the minimum; the daemon must still accept the minimum.
    public static func evaluate(_ version: EngineVersion, socketPath: String, rancherVersion: String?) -> RuntimeState {
        guard version.os == "linux" else { return .unsupported(reason: "the engine runs \(version.os) containers, not Linux") }
        guard compare(version.apiVersion, minimumAPIVersion) >= 0 else {
            return .unsupported(reason: "Engine API \(version.apiVersion) is older than \(minimumAPIVersion)")
        }
        if let minimum = version.minAPIVersion, compare(minimum, minimumAPIVersion) > 0 {
            return .unsupported(reason: "the engine no longer accepts API \(minimumAPIVersion) (minimum \(minimum)); BelloCode needs an update")
        }
        var notes: [String] = []
        if let rancherVersion, compare(majorMinor(rancherVersion), testedRancherVersion) > 0 {
            notes.append("Rancher Desktop \(rancherVersion) is newer than the tested \(testedRancherVersion).")
        }
        return .ready(.init(socketPath: socketPath, engineVersion: version.version, apiVersion: version.apiVersion,
                            arch: version.arch, kernel: version.kernelVersion, rancherVersion: rancherVersion, notes: notes))
    }

    static func majorMinor(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    public static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}
