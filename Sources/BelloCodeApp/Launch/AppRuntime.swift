import AppKit
import BelloCore
import ContainerKit
import Engine
import Foundation
import MockOpenCode
import OpenCodeKit
import os

/// Owns the engine and whatever server it talks to for one app run.
///
/// Sources, in order of precedence: `--mock` (an in-process MockOpenCode with a temporary cache; development builds),
/// then `BELLOCODE_SERVER_URL`/`BELLOCODE_SERVER_PASSWORD` (attach in a separate data namespace; never spawned or stopped
/// by us; development builds only), else the bundled
/// `Contents/Helpers/opencode` under a supervisor, with isolated data in
/// `~/Library/Application Support/BelloCode/opencode` (the user's own opencode config and data are never touched).
///
/// Threading: `@MainActor`. `stop()` stops the engine (which stops a supervised server and waits for the child to
/// exit), then the mock, then deletes the temporary cache.
@MainActor
final class AppRuntime {
    enum Source: Equatable {
        case bundled(executable: URL)
        case attached(URL)
        case mock(LaunchOptions.MockScenario)
    }

    let engine: Engine
    /// The app's one provider sign-in service (Settings, onboarding and the model picker share it). Shut down before
    /// the engine stops.
    let auth: AuthService
    let source: Source
    /// Restoration defaults: the user's for real data, a separate suite for mock data so it never mixes.
    let defaults: UserDefaults
    /// Suffix for AppKit autosave names (window frame, split dividers); empty for real data.
    let autosaveSuffix: String
    private let mockServer: MockOpenCodeServer?
    private let temporaryDirectory: URL?
    private(set) var isStopped = false

    private init(
        engine: Engine, source: Source, defaults: UserDefaults, autosaveSuffix: String, mockServer: MockOpenCodeServer?,
        temporaryDirectory: URL?
    ) {
        self.engine = engine
        auth = engine.makeAuthService(openURL: { url in NSWorkspace.shared.open(url) })
        self.source = source
        self.defaults = defaults
        self.autosaveSuffix = autosaveSuffix
        self.mockServer = mockServer
        self.temporaryDirectory = temporaryDirectory
    }

    /// Why the app cannot start in this build or bundle.
    enum LaunchError: Error, CustomStringConvertible, Equatable {
        case developmentOnly(String)
        case incompleteBundle([String])

        var description: String {
            switch self {
            case .developmentOnly(let what): "\(what) is available only in development builds."
            case .incompleteBundle(let missing):
                "The app bundle is incomplete (missing \(missing.joined(separator: ", "))). BelloCode runs commands only through its bundled server and container helper, so it does not start without them. Reinstall BelloCode."
            }
        }
    }

    static func make(options: LaunchOptions, bundle: Bundle = .main,
                     environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> AppRuntime {
        if let scenario = options.mock {
            guard LaunchOptions.allowsDevelopmentModes else { throw LaunchError.developmentOnly("Mock mode") }
            if case .snapshot(let name) = options.mode, name == "containers" || name == "containers3" {
                return try await makeMock(scenario, containers: true)
            }
            return try await makeMock(scenario)
        }
        #if BELLOCODE_DEVELOPMENT
        if let source = ServerSource.fromEnvironment(environment), case .fixed(let connection) = source {
            return try await makeAttached(source, url: connection.baseURL)
        }
        #endif
        let server = bundledServerConfiguration(bundle: bundle)
        try requireBundledRuntime(server)
        var configuration = EngineConfiguration(server: .supervised(ServerSupervisor(configuration: server)), store: .file(try storeURL()))
        configuration.containers = containerConfiguration(for: server)
        return AppRuntime(
            engine: try await Engine.make(configuration: configuration), source: .bundled(executable: server.executableURL),
            defaults: .standard, autosaveSuffix: "", mockServer: nil, temporaryDirectory: nil)
    }

    /// The shipped app runs only the bundled, supervised server with its container helper: a bundle missing either
    /// does not start (never a host fallback).
    nonisolated static func requireBundledRuntime(_ server: ServerConfiguration) throws {
        var missing: [String] = []
        if !FileManager.default.isExecutableFile(atPath: server.executableURL.path) { missing.append("Contents/Helpers/opencode") }
        if let helper = server.containerExecution?.helperURL {
            if !FileManager.default.isExecutableFile(atPath: helper.path) { missing.append("Contents/Helpers/bellocode-exec") }
        } else {
            missing.append("container execution")
        }
        if !missing.isEmpty { throw LaunchError.incompleteBundle(missing) }
    }

    #if BELLOCODE_DEVELOPMENT
    /// Development only: attach to a server named by `BELLOCODE_SERVER_URL`. Its own data namespace (cache, defaults,
    /// secrets in memory), so it never reconciles the user's real cache with another server. No container execution:
    /// setup scripts are refused rather than run on the host.
    private static func makeAttached(_ source: ServerSource, url: URL) async throws -> AppRuntime {
        let directory = applicationSupport().appending(path: "Development/attached", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = EngineConfiguration(server: source, store: .file(directory.appending(path: "projection.sqlite")))
        configuration.secretVault = InMemorySecretVault()
        configuration.forgeTokens = InMemorySecretVault()
        configuration.visualsDirectory = directory.appending(path: "visuals", directoryHint: .isDirectory)
        let suite = "com.bellocode.app.attached"
        return AppRuntime(
            engine: try await Engine.make(configuration: configuration), source: .attached(url),
            defaults: UserDefaults(suiteName: suite) ?? .standard, autosaveSuffix: ".attached", mockServer: nil, temporaryDirectory: nil)
    }
    #endif

    /// The bundled server: `Contents/Helpers/opencode`, helpers first on PATH, isolated data under Application Support.
    nonisolated static func bundledServerConfiguration(bundle: Bundle = .main, dataRoot: URL? = nil) -> ServerConfiguration {
        let helpers = bundle.bundleURL.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        let root = dataRoot ?? applicationSupport().appending(path: "opencode", directoryHint: .isDirectory)
        var configuration = ServerConfiguration(
            executableURL: helpers.appending(path: "opencode"),
            dataRoot: root,
            helpersDirectory: helpers,
            expectedVersion: bundle.object(forInfoDictionaryKey: "BelloCodeOpenCodeVersion") as? String,
            pluginDirectory: bundledPluginDirectory(bundle: bundle))
        // Containerised execution (docs/features/containers.md): every command the agent or the user runs goes through
        // bellocode-exec into the project's container. Always on for the bundled server; a bundle without the helper
        // is broken, and the helper path is still configured so commands fail with a message instead of running on
        // the host.
        configuration.containerExecution = ContainerExecution(
            helperURL: helpers.appending(path: "bellocode-exec"),
            execConfigURL: root.appending(path: "bellocode-exec.json"),
            gitShimDirectory: root.appending(path: "git-shim", directoryHint: .isDirectory))
        // Corporate network (docs/features/containers.md): opencode's Bun runtime trusts the selected enterprise roots
        // and uses the administrator's or the Mac's proxies (Bun reads neither the Keychain nor macOS proxy settings).
        let enterprise = certificateDirectory(dataRoot: root).appending(path: CorporateNetwork.enterpriseName)
        configuration.launchEnvironment = {
            EnvironmentService.serverEnvironment(enterpriseBundle: enterprise, proxy: SystemProxySettings.current(), managed: ManagedNetworkPolicy.read())
        }
        return configuration
    }

    /// Where the corporate network's certificate bundles are written (mounted read-only into containers).
    nonisolated static func certificateDirectory(dataRoot: URL) -> URL {
        dataRoot.appending(path: "network/certs", directoryHint: .isDirectory)
    }

    /// The engine's side of containerised execution for a bundled server configuration.
    nonisolated static func containerConfiguration(for server: ServerConfiguration, socketOverride: String? = nil) -> ContainerConfiguration? {
        guard let execution = server.containerExecution else { return nil }
        var configuration = ContainerConfiguration(
            helperURL: execution.helperURL, execConfigURL: execution.execConfigURL, opencodeDataDirectory: server.dataDirectory,
            runtime: LiveWorkspaceRuntime(socketOverride: socketOverride))
        configuration.gitShim = execution.gitShimDirectory?.appending(path: "git")
        configuration.mcpLogDirectory = server.dataRoot.appending(path: "mcp-logs", directoryHint: .isDirectory)
        configuration.opencodeConfigDirectory = server.configDirectory
        configuration.certificateDirectory = certificateDirectory(dataRoot: server.dataRoot)
        configuration.stackDirectory = server.dataRoot.appending(path: "mcp-stacks", directoryHint: .isDirectory)
        return configuration
    }

    /// `Contents/Resources/opencode-plugin` (the "bellocode" server plugin, docs/features/orchestration.md), if bundled.
    nonisolated static func bundledPluginDirectory(bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL.appending(path: "Contents/Resources/opencode-plugin", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.appending(path: "server.ts").path) ? url : nil
    }

    nonisolated static func applicationSupport() -> URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appending(path: "BelloCode", directoryHint: .isDirectory)
    }

    private static func storeURL() throws -> URL {
        let url = EngineConfiguration.defaultStoreURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private static func makeMock(_ scenario: LaunchOptions.MockScenario, containers: Bool = false) async throws -> AppRuntime {
        let data: Scenario = switch scenario {
        case .demo: .demo()
        case .large: .large(sessionCount: 500, largeSessionMessages: 2_000)
        case .workspace: FixtureGenerator(seed: 5).workspace(projectCount: 3, sessionCount: 30, messagesPerSession: 6)
        }
        let server = MockOpenCodeServer(scenario: data, options: MockServerOptions(clock: .realTime))
        let endpoint = try await server.start()
        let directory = FileManager.default.temporaryDirectory.appending(path: "bellocode-mock-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let connection = ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? ""))
        var configuration = EngineConfiguration(server: .fixed(connection), store: .file(directory.appending(path: "projection.sqlite")))
        configuration.defaultDirectory = data.defaultDirectory
        // Orchestration extras on mock data: nothing reaches the Keychain, a GitLab instance or the user's caches.
        configuration.secretVault = InMemorySecretVault()
        configuration.forgeTransport = MockGitLab.transport()
        configuration.forgeTokens = MockGitLab.tokens()
        configuration.mergeRequestPoll = .seconds(2)
        configuration.visualsDirectory = directory.appending(path: "visuals", directoryHint: .isDirectory)
        if containers {
            // `--snapshot containers`: container execution on a scripted runtime (never Rancher Desktop).
            let fake = SnapshotWorkspaceRuntime()
            SnapshotWorkspaceRuntime.current = fake
            configuration.containers = ContainerConfiguration(
                helperURL: URL(filePath: "/Applications/BelloCode.app/Contents/Helpers/bellocode-exec"),
                execConfigURL: directory.appending(path: "bellocode-exec.json"), opencodeDataDirectory: nil, runtime: fake,
                registryVault: InMemorySecretVault())
            // An administrator's policy (as a configuration profile would set it): the organisation's registry only.
            configuration.containers?.managedPolicy = {
                .init(policy: ImagePolicy(allowedPrefixes: ["registry.acme.internal"], pullPolicy: .missing), defaultImage: nil,
                      source: "configuration profile")
            }
            // Containers 3: global MCP secrets in memory, the scripted Mac's enterprise roots (never the real Keychain),
            // no proxy (a transparent one), bundles and logs in the temporary folder.
            configuration.containers?.mcpVault = InMemorySecretVault()
            configuration.containers?.mcpLogDirectory = directory.appending(path: "mcp-logs", directoryHint: .isDirectory)
            configuration.containers?.certificateSource = SnapshotCertificates()
            configuration.containers?.certificateDirectory = directory.appending(path: "certs", directoryHint: .isDirectory)
            configuration.containers?.managedNetwork = { nil }
            configuration.containers?.systemProxy = { SystemProxySettings() }
        }
        let suite = "com.bellocode.app.mock"
        return AppRuntime(
            engine: try await Engine.make(configuration: configuration), source: .mock(scenario),
            defaults: UserDefaults(suiteName: suite) ?? .standard, autosaveSuffix: ".mock", mockServer: server,
            temporaryDirectory: directory)
    }

    /// Stops the engine (and the supervised server: the child exits before this returns), then the mock.
    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        auth.shutdown()
        await auth.cancel()
        await engine.stop()
        if let mockServer { await mockServer.stop() }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    /// Plays a named mock script on the next prompt (snapshots and demos). No effect outside mock mode.
    func enqueueMockScript(named name: String) async {
        guard let mockServer, let script = TurnScript.builtIns[name] else { return }
        await mockServer.enqueueScript(script)
    }

    /// Plays `script` on the next prompt to `sessionID` (any session when nil). No effect outside mock mode.
    func enqueueMockScript(_ script: TurnScript, for sessionID: SessionID? = nil) async {
        await mockServer?.enqueueScript(script, for: sessionID?.rawValue)
    }

    /// Scripts the files a turn changed (the Changes tab's snapshots). No effect outside mock mode.
    func setMockTurnDiff(_ files: [MockOpenCode.JSONValue], for sessionID: SessionID) async {
        await mockServer?.setTurnDiff(sessionID: sessionID.rawValue, files: files)
    }

    /// Plays the agent in mock mode: sends one browser command to the session's attached browser (snapshots).
    func issueMockBrowserCommand(_ sessionID: SessionID, _ action: OpenCodeKit.JSONValue) async -> MockBrowserOutcome? {
        guard let mockServer, let data = try? action.encodedData(), let value = try? MockOpenCode.JSONValue.parse(data) else { return nil }
        return await mockServer.issueBrowserCommand(sessionID: sessionID.rawValue, action: value)
    }

    /// Mock mode: sets a session metadata key (the plugin's interrupt record in Auto snapshots).
    func setMockSessionMetadata(_ sessionID: SessionID, key: String, json: String) async {
        guard let mockServer, let value = try? MockOpenCode.JSONValue.parse(Data(json.utf8)) else { return }
        await mockServer.setSessionMetadataKey(sessionID.rawValue, key, value)
    }

    /// Mock mode: children report to their parent and wake it, as opencode does (orchestration snapshots).
    func setMockChildReports(_ enabled: Bool) async {
        await mockServer?.setChildReports(enabled)
    }

    /// Mock mode: what the plugin's `create_threads` does (top-level threads with `metadata.bellocode`, one group).
    func mockCreateThreads(by creator: SessionID, titles: [String]) async -> [SessionID] {
        guard let mockServer else { return [] }
        return await mockServer.simulateCreateThreads(by: creator.rawValue, titles: titles).map { SessionID($0) }
    }

    /// Takes the mock server off the network (snapshots of the offline state). No effect outside mock mode.
    func takeMockOffline() async {
        await mockServer?.stop()
    }

    /// A short description for the window's connection item ("Mock (demo)", "Attached", …); nil for the bundled server.
    var sourceLabel: String? {
        switch source {
        case .bundled: nil
        case .attached: "Attached server"
        case .mock(let scenario): "Mock (\(scenario.rawValue))"
        }
    }
}
