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
    /// Computed at each launch and added before `extraEnvironment`: the corporate network's certificate bundle
    /// (`NODE_EXTRA_CA_CERTS`) and proxies, which can change while the app runs.
    public var launchEnvironment: (@Sendable () -> [String: String])?
    /// The bundled "bellocode" plugin directory (`Contents/Resources/opencode-plugin`). When set, the server is started
    /// with `OPENCODE_CONFIG_CONTENT` listing it (`OrchestrationContract.serverConfig`), so it loads by local path.
    public var pluginDirectory: URL?
    /// Run every command in workspace containers (docs/features/containers.md). The app always sets it; nil only in
    /// tests and mock mode.
    public var containerExecution: ContainerExecution?
    /// Repository opencode configuration (docs/features/opencode-config.md). `.bellocode` (default): opencode's own
    /// project config is off and BelloCode's plugin loads each repository's `AGENTS.md` (and, for trusted projects,
    /// their agents, commands and skills). `.native`: opencode loads every repository's config and plugins itself.
    public var repositoryConfig: RepositoryConfigPolicy = .bellocode
    /// Read at each launch instead of `repositoryConfig` when set (the app's setting can change while it runs; it
    /// applies at the next server restart).
    public var repositoryConfigProvider: (@Sendable () -> RepositoryConfigPolicy)?
    /// The policy for the next launch.
    public var effectiveRepositoryConfig: RepositoryConfigPolicy { repositoryConfigProvider?() ?? repositoryConfig }
    /// Coordinate with `bellocode-opencode`: hold the data root's lease (`OpenCodeDataLock`) while a server runs,
    /// publish its address (`CLIConnectionFile`, 0600, no secret) and hand its password over `CLIPasswordBroker`.
    public var publishesCLIConnection = true
    /// Tests only: any process of this user may fetch the password (no bundled helper to check against). Never set by
    /// the app (AF18).
    public var allowsAnyCLIPeer = false
    /// Who may fetch the password: the bundled `bellocode-opencode` next to opencode. Nil when it is missing or not
    /// executable: no password is handed out at all (fail closed, AF18), never "any process of this user".
    public var cliPeers: CLIPasswordBroker.Peers? {
        if allowsAnyCLIPeer { return .anyProcessOfThisUser }
        guard let helpers = helpersDirectory else { return nil }
        let helper = helpers.appending(path: "bellocode-opencode").path
        guard FileManager.default.isExecutableFile(atPath: helper) else { return nil }
        return .executables([CLIPasswordBroker.canonical(helper)])
    }

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

    /// The isolated directories under `dataRoot` (shared with the CLI wrapper and Settings ▸ opencode).
    public var directories: OpenCodeDirectories { OpenCodeDirectories(dataRoot: dataRoot, home: homeDirectory) }
    public var configDirectory: URL { directories.config }
    public var dataDirectory: URL { directories.data }
    public var stateDirectory: URL { directories.state }
    public var cacheDirectory: URL { directories.cache }
    public var resolvedHomeDirectory: URL { directories.home }

    /// The command line: `opencode serve --stdio --port 0`.
    public var arguments: [String] { ["serve", "--stdio", "--port", "0"] }

    /// The child's complete environment for one launch.
    public func environment(credentials: ServerCredentials) -> [String: String] {
        let repositoryConfig = effectiveRepositoryConfig
        let helpers = (helpersDirectory ?? executableURL.deletingLastPathComponent()).path
        var environment = directories.isolationEnvironment()
        environment.merge([
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "PATH": basePath.isEmpty ? helpers : "\(helpers):\(basePath)",
            "OPENCODE_PASSWORD": credentials.password,
            "OPENCODE_CLIENT": clientName,
        ]) { _, new in new }
        // Local MCP servers in the isolated configuration files are configured for all projects: refused (MCPRouting).
        let mcpOverrides = containerExecution.map {
            MCPRouting.globalOverrides(configDirectory: configDirectory, helper: $0.helperURL.path).servers
        } ?? [:]
        let projectConfig = OrchestrationContract.ProjectConfigOptions(policy: repositoryConfig, trustFile: directories.trustFile)
        if let pluginDirectory {
            environment["OPENCODE_CONFIG_CONTENT"] = OrchestrationContract.serverConfig(
                pluginDirectory: pluginDirectory, container: containerExecution, mcpServers: mcpOverrides, projectConfig: projectConfig,
                modelDefaultsFile: directories.modelDefaultsFile)
        } else if let containerExecution {
            environment["OPENCODE_CONFIG_CONTENT"] = OrchestrationContract.serverConfig(
                pluginDirectory: nil, container: containerExecution, mcpServers: mcpOverrides)
        }
        if let containerExecution {
            environment.merge(containerExecution.environment) { _, container in container }
            if let shim = containerExecution.gitShimDirectory { environment["PATH"] = "\(shim.path):\(environment["PATH"] ?? basePath)" }
        }
        if let launchEnvironment { environment.merge(launchEnvironment()) { _, launch in launch } }
        environment.merge(extraEnvironment) { _, extra in extra }
        environment["OPENCODE_PASSWORD"] = credentials.password
        // Repository opencode.json and .opencode/ plugins would run inside opencode on the host: off unless the person
        // chose `.native` (docs/features/opencode-config.md). The app's decision, whatever another variable says.
        if repositoryConfig == .bellocode { environment["OPENCODE_DISABLE_PROJECT_CONFIG"] = "1" } else {
            environment["OPENCODE_DISABLE_PROJECT_CONFIG"] = nil
            environment["OPENCODE_CONFIG_PROJECT_DISABLE"] = nil
        }
        for key in environment.keys where Self.forbiddenEnvironmentPrefixes.contains(where: { key.hasPrefix($0) }) {
            environment[key] = nil
        }
        return environment
    }

    /// Creates the isolated directories.
    func prepareDirectories() throws {
        for directory in [configDirectory, dataDirectory, stateDirectory, cacheDirectory, resolvedHomeDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try containerExecution?.installGitShim()
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
