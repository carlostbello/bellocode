import AppKit
import BelloCore
import Engine
import Foundation
import MockOpenCode
import OpenCodeKit
import os

/// Owns the engine and whatever server it talks to for one app run.
///
/// Sources, in order of precedence: `--mock` (an in-process MockOpenCode with a temporary cache), then
/// `BELLOCODE_SERVER_URL`/`BELLOCODE_SERVER_PASSWORD` (attach; never spawned or stopped by us), else the bundled
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

    static func make(options: LaunchOptions, bundle: Bundle = .main) async throws -> AppRuntime {
        if let scenario = options.mock {
            return try await makeMock(scenario)
        }
        if let source = ServerSource.fromEnvironment(), case .fixed(let connection) = source {
            let configuration = EngineConfiguration(server: source, store: .file(try storeURL()))
            return AppRuntime(
                engine: try await Engine.make(configuration: configuration), source: .attached(connection.baseURL), defaults: .standard,
                autosaveSuffix: "", mockServer: nil, temporaryDirectory: nil)
        }
        let server = bundledServerConfiguration(bundle: bundle)
        let configuration = EngineConfiguration(server: .supervised(ServerSupervisor(configuration: server)), store: .file(try storeURL()))
        return AppRuntime(
            engine: try await Engine.make(configuration: configuration), source: .bundled(executable: server.executableURL),
            defaults: .standard, autosaveSuffix: "", mockServer: nil, temporaryDirectory: nil)
    }

    /// The bundled server: `Contents/Helpers/opencode`, helpers first on PATH, isolated data under Application Support.
    nonisolated static func bundledServerConfiguration(bundle: Bundle = .main, dataRoot: URL? = nil) -> ServerConfiguration {
        let helpers = bundle.bundleURL.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        return ServerConfiguration(
            executableURL: helpers.appending(path: "opencode"),
            dataRoot: dataRoot ?? applicationSupport().appending(path: "opencode", directoryHint: .isDirectory),
            helpersDirectory: helpers,
            expectedVersion: bundle.object(forInfoDictionaryKey: "BelloCodeOpenCodeVersion") as? String)
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

    private static func makeMock(_ scenario: LaunchOptions.MockScenario) async throws -> AppRuntime {
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
