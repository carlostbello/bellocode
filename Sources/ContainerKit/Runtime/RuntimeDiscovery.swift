import Foundation

/// What the user's container runtime can do for BelloCode right now. Every state has a sentence for the UI and is never
/// shown by colour alone.
public enum RuntimeState: Sendable, Equatable {
    /// Neither Rancher Desktop nor its user directory exists.
    case notInstalled
    /// Installed, but the Engine API socket is absent or refuses connections (the VM is stopped or starting).
    case notRunning(socketPath: String)
    /// Rancher Desktop is set to containerd: there is no Docker-compatible API for BelloCode to drive.
    case wrongEngine(engine: String)
    /// The socket answers but not like a Docker Engine (or with an API older than BelloCode needs).
    case unsupported(reason: String)
    /// Ready: the Engine API answered `/_ping` and `/version`.
    case ready(Ready)

    public struct Ready: Sendable, Equatable {
        public var socketPath: String
        public var engineVersion: String
        public var apiVersion: String
        public var arch: String
        public var kernel: String?
    }

    public var isReady: Bool { if case .ready = self { true } else { false } }

    /// Text for the runtime status row and for the error a blocked command reports.
    public var userMessage: String {
        switch self {
        case .notInstalled:
            "Rancher Desktop is not installed. Commands run in a container, so BelloCode cannot run them until it is."
        case .notRunning:
            "Rancher Desktop is not running. Start it to run commands; nothing will run on this Mac instead."
        case .wrongEngine(let engine):
            "Rancher Desktop uses the \(engine) engine. In Rancher Desktop ▸ Preferences ▸ Container Engine, choose dockerd (moby)."
        case .unsupported(let reason):
            "The container runtime is not usable: \(reason)"
        case .ready(let ready):
            "Rancher Desktop ready: Docker Engine \(ready.engineVersion), API \(ready.apiVersion), \(ready.arch)"
        }
    }
}

/// The parts of the machine discovery looks at, injectable for tests.
public protocol RuntimeProbeEnvironment: Sendable {
    func fileExists(_ path: String) -> Bool
    func readFile(_ path: String) -> Data?
    /// `/_ping` then `/version` on `socketPath`.
    func probe(socketPath: String) async throws -> EngineVersion
}

public struct LiveRuntimeProbeEnvironment: RuntimeProbeEnvironment {
    public init() {}
    public func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    public func readFile(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }
    public func probe(socketPath: String) async throws -> EngineVersion {
        let client = EngineClient(socketPath: socketPath)
        _ = try await client.ping()
        return try await client.version()
    }
}

/// Finds Rancher Desktop's Docker-compatible Engine API. Read-only: it never starts the VM, never switches engines and
/// never reads the management API's credentials (`rd-engine.json`).
public struct RuntimeDiscovery: Sendable {
    public var home: String
    public var environment: any RuntimeProbeEnvironment
    /// Explicit socket (a setting), tried before Rancher's default.
    public var overrideSocket: String?
    public static let minimumAPIVersion = "1.44"

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

    public func detect() async -> RuntimeState {
        let installed = environment.fileExists(appPath) || environment.fileExists(userAppPath)
            || environment.fileExists(home + "/.rd") || overrideSocket != nil
        guard installed else { return .notInstalled }
        if let engine = configuredEngine(), engine != "moby", engine != "dockerd" {
            return .wrongEngine(engine: engine)
        }
        guard environment.fileExists(socketPath) else { return .notRunning(socketPath: socketPath) }
        do {
            let version = try await environment.probe(socketPath: socketPath)
            guard version.os == "linux" else { return .unsupported(reason: "the engine runs \(version.os) containers") }
            guard Self.compare(version.apiVersion, Self.minimumAPIVersion) >= 0 else {
                return .unsupported(reason: "Engine API \(version.apiVersion) is older than \(Self.minimumAPIVersion)")
            }
            return .ready(.init(socketPath: socketPath, engineVersion: version.version, apiVersion: version.apiVersion,
                                arch: version.arch, kernel: version.kernelVersion))
        } catch let error as SocketError where error.isConnectionRefusedOrMissing {
            return .notRunning(socketPath: socketPath)
        } catch is HTTPParseError {
            // Lima accepts on the forwarded socket even when nothing listens inside the VM, then closes.
            return .notRunning(socketPath: socketPath)
        } catch let error as SocketError {
            return .unsupported(reason: error.description)
        } catch {
            return .unsupported(reason: String(describing: error))
        }
    }

    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}
