import Foundation

/// How to run the opencode server child.
public struct ServerConfiguration: Sendable {
    /// The opencode executable. The app passes `Contents/Helpers/opencode`; tests pass `Vendor/opencode/<v>/opencode`.
    public var executableURL: URL
    /// Root of the isolated data directories (`config`, `data`, `state`, `cache`, `home` beneath it). The app passes
    /// `~/Library/Application Support/BelloCode/opencode`; tests pass a temporary directory. The user's own opencode
    /// directories are never used.
    public var dataRoot: URL
    /// Prepended to the child's PATH (bundled helpers such as `rg`). Defaults to the executable's directory.
    public var helpersDirectory: URL?
    /// The rest of the child's PATH.
    public var basePath: String
    /// The child's HOME. Defaults to `<dataRoot>/home`, so nothing reads or writes the user's home directory.
    public var homeDirectory: URL?
    /// Reported to the server as `OPENCODE_CLIENT`.
    public var clientName: String
    /// When set, a server reporting another version is rejected.
    public var expectedVersion: String?
    /// Added last, overriding the defaults. Never put credentials here.
    public var extraEnvironment: [String: String]
    /// The bundled "bellocode" plugin directory (`Contents/Resources/opencode-plugin`). When set, the server is started
    /// with `OPENCODE_CONFIG_CONTENT` listing it (`OrchestrationContract.serverConfig`), so it loads by local path.
    public var pluginDirectory: URL?

    /// Limit for the ready line plus a verified `GET /api/info`.
    public var startTimeout: Duration
    /// After closing stdin on `stop()`, how long to wait before SIGTERM, and again before SIGKILL.
    public var stopGracePeriod: Duration
    public var restartBackoff: BackoffPolicy
    /// Consecutive failed starts (or crashes before `healthyAfter`) before giving up in `.failed`.
    public var maxConsecutiveFailures: Int
    /// A server that stayed ready this long resets the failure count when it later exits.
    public var healthyAfter: Duration

    public init(
        executableURL: URL,
        dataRoot: URL,
        helpersDirectory: URL? = nil,
        basePath: String = "/usr/bin:/bin:/usr/sbin:/sbin",
        homeDirectory: URL? = nil,
        clientName: String = "bellocode",
        expectedVersion: String? = nil,
        extraEnvironment: [String: String] = [:],
        pluginDirectory: URL? = nil,
        startTimeout: Duration = .seconds(20),
        stopGracePeriod: Duration = .seconds(3),
        restartBackoff: BackoffPolicy = BackoffPolicy(initial: .milliseconds(200), maximum: .seconds(30)),
        maxConsecutiveFailures: Int = 6,
        healthyAfter: Duration = .seconds(30)
    ) {
        self.executableURL = executableURL
        self.dataRoot = dataRoot
        self.helpersDirectory = helpersDirectory
        self.basePath = basePath
        self.homeDirectory = homeDirectory
        self.clientName = clientName
        self.expectedVersion = expectedVersion
        self.extraEnvironment = extraEnvironment
        self.pluginDirectory = pluginDirectory
        self.startTimeout = startTimeout
        self.stopGracePeriod = stopGracePeriod
        self.restartBackoff = restartBackoff
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.healthyAfter = healthyAfter
    }

    /// Isolated directories under `dataRoot`.
    public var configDirectory: URL { dataRoot.appending(path: "config", directoryHint: .isDirectory) }
    public var dataDirectory: URL { dataRoot.appending(path: "data", directoryHint: .isDirectory) }
    public var stateDirectory: URL { dataRoot.appending(path: "state", directoryHint: .isDirectory) }
    public var cacheDirectory: URL { dataRoot.appending(path: "cache", directoryHint: .isDirectory) }
    public var resolvedHomeDirectory: URL {
        homeDirectory ?? dataRoot.appending(path: "home", directoryHint: .isDirectory)
    }

    /// The command line: `opencode serve --stdio --port 0`.
    public var arguments: [String] { ["serve", "--stdio", "--port", "0"] }

    /// The child's complete environment for one launch.
    public func environment(credentials: ServerCredentials) -> [String: String] {
        let helpers = (helpersDirectory ?? executableURL.deletingLastPathComponent()).path
        var environment = [
            "HOME": resolvedHomeDirectory.path,
            "XDG_CONFIG_HOME": configDirectory.path,
            "XDG_DATA_HOME": dataDirectory.path,
            "XDG_STATE_HOME": stateDirectory.path,
            "XDG_CACHE_HOME": cacheDirectory.path,
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "PATH": basePath.isEmpty ? helpers : "\(helpers):\(basePath)",
            "OPENCODE_PASSWORD": credentials.password,
            "OPENCODE_CLIENT": clientName,
            "OPENCODE_DISABLE_AUTOUPDATE": "1",
            "OPENCODE_DISABLE_MODELS_FETCH": "1",
            "OPENCODE_DISABLE_CLAUDE_CODE": "1",
        ]
        if let pluginDirectory {
            environment["OPENCODE_CONFIG_CONTENT"] = OrchestrationContract.serverConfig(pluginDirectory: pluginDirectory)
        }
        environment.merge(extraEnvironment) { _, extra in extra }
        environment["OPENCODE_PASSWORD"] = credentials.password
        return environment
    }

    /// Creates the isolated directories.
    func prepareDirectories() throws {
        for directory in [configDirectory, dataDirectory, stateDirectory, cacheDirectory, resolvedHomeDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

/// Fetches `GET /api/info` from a freshly started server. Injected for tests.
public protocol ServerInfoProbe: Sendable {
    func info(for connection: ServerConnection) async throws -> ServerInfo
}

/// Probes with `OpenCodeClient`, retrying while the server answers 503 (starting).
public struct HTTPServerInfoProbe: ServerInfoProbe {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport.shared) {
        self.transport = transport
    }

    public func info(for connection: ServerConnection) async throws -> ServerInfo {
        let client = OpenCodeClient(connection: connection, transport: transport, requestTimeout: .seconds(5))
        return try await client.waitForInfo()
    }
}
