import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// Settings ▸ Models below the UI (docs/features/models.md): which model each background task uses, the reviewer's
/// paid-first rule, preferences, provider refusals, and what reaches opencode.
@Suite("Background models")
struct BackgroundModelResolverTests {
    static func entry(_ provider: String, _ id: String, free: Bool, family: String? = nil, enabled: Bool = true) -> ModelEntry {
        ModelEntry(providerID: provider, modelID: id, name: id, family: family, contextLimit: 1, outputLimit: 1, enabled: enabled, isFree: free)
    }

    /// The live shape of the bug: opencode's free models plus a connected paid provider; opencode's default is free.
    static let mixed = Catalog(
        directory: "/p",
        providers: [ProviderEntry(id: "opencode", name: "OpenCode Zen", activation: "enabled"), ProviderEntry(id: "anthropic", name: "Anthropic", activation: "enabled")],
        models: [
            entry("opencode", "big-pickle", free: true), entry("opencode", "deepseek-v4.1-flash-free", free: true),
            entry("anthropic", "claude-sonnet-5", free: false), entry("anthropic", "claude-haiku-5", free: false, family: "claude-haiku"),
        ],
        defaultModel: ModelSelection(providerID: "opencode", modelID: "big-pickle"), fetched: .now)
    static let freeOnly = Catalog(
        directory: "/p", providers: [ProviderEntry(id: "opencode", name: "OpenCode Zen", activation: "enabled")],
        models: [entry("opencode", "big-pickle", free: true), entry("opencode", "deepseek-v4.1-flash-free", free: true)],
        defaultModel: ModelSelection(providerID: "opencode", modelID: "big-pickle"), fetched: .now)

    static let sonnet = ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5")
    static let haiku = ModelSelection(providerID: "anthropic", modelID: "claude-haiku-5")
    static let pickle = ModelSelection(providerID: "opencode", modelID: "big-pickle")

    // MARK: Reviewer

    @Test func reviewerOrderIsOwnerThenThreadThenServerThenFallback() {
        typealias R = BackgroundModelResolver
        // Owner's model wins, even a free one (an explicit choice).
        #expect(R.reviewer(choice: .specific(Self.pickle), thread: Self.sonnet, catalog: Self.mixed) == .model(Self.pickle, .owner))
        // Same as thread: the thread's paid model.
        #expect(R.reviewer(choice: .sameAsThread, thread: Self.sonnet, catalog: Self.mixed) == .model(Self.sonnet, .thread))
        // A thread on the free default with a paid provider connected: never free; the fast paid fallback.
        #expect(R.reviewer(choice: .sameAsThread, thread: nil, catalog: Self.mixed) == .model(Self.haiku, .fallback))
        #expect(R.reviewer(choice: .sameAsThread, thread: Self.pickle, catalog: Self.mixed) == .model(Self.haiku, .fallback))
        // A paid server default is used.
        var paidDefault = Self.mixed
        paidDefault.defaultModel = Self.sonnet
        #expect(R.reviewer(choice: .sameAsThread, thread: nil, catalog: paidDefault) == .model(Self.sonnet, .serverDefault))
        // Free only: the free models are all there is.
        #expect(R.reviewer(choice: .sameAsThread, thread: nil, catalog: Self.freeOnly) == .model(Self.pickle, .serverDefault))
        // Server default chosen explicitly: opencode's default, whatever it is.
        #expect(R.reviewer(choice: .serverDefault, thread: Self.sonnet, catalog: Self.mixed) == .model(Self.pickle, .serverDefault))
        // No catalog yet: opencode picks.
        #expect(R.reviewer(choice: .sameAsThread, thread: nil, catalog: nil) == .serverDefault)
    }

    @Test func reviewerNeverPicksAFreeModelWhenAPaidOneIsConnected() {
        let choices: [ModelChoice] = [.sameAsThread, .smallModel, .specific(ModelSelection(providerID: "gone", modelID: "x"))]
        let threads: [ModelSelection?] = [nil, Self.pickle, ModelSelection(providerID: "opencode", modelID: "deepseek-v4.1-flash-free")]
        for choice in choices {
            for thread in threads {
                let picked = BackgroundModelResolver.reviewer(choice: choice, thread: thread, catalog: Self.mixed).selection
                #expect(picked?.providerID == "anthropic", "\(choice) with thread \(thread?.token ?? "default") picked \(picked?.token ?? "nil")")
            }
        }
        // And the legacy helper agrees.
        let ref = AutoReviewer.defaultModel(from: Self.mixed.models)
        #expect(ref?.providerID == "anthropic" && ref?.id == "claude-haiku-5")
    }

    @Test func anUnavailableOwnerChoiceFallsThrough() {
        var catalog = Self.mixed
        catalog.providers[1].activation = "disabled"
        #expect(BackgroundModelResolver.availability(of: Self.sonnet, in: catalog) == .unavailable("Provider disabled in opencode"))
        // With the paid provider disabled, nothing paid is usable: free models are allowed again.
        #expect(BackgroundModelResolver.reviewer(choice: .specific(Self.sonnet), thread: nil, catalog: catalog) == .model(Self.pickle, .serverDefault))
        #expect(BackgroundModelResolver.availability(of: ModelSelection(providerID: "x", modelID: "y"), in: catalog) == .missing)
        #expect(BackgroundModelResolver.availability(of: Self.sonnet, in: nil) == .unknown)
    }

    // MARK: Git & GitLab text

    @Test func gitTextOrder() {
        typealias R = BackgroundModelResolver
        #expect(R.gitText(choice: .sameAsThread, thread: Self.sonnet, hasThread: true, small: nil, catalog: Self.mixed) == .thread)
        #expect(R.gitText(choice: .specific(Self.haiku), thread: Self.sonnet, hasThread: true, small: nil, catalog: Self.mixed) == .model(Self.haiku, .owner))
        // Small model: the owner's small model when set…
        #expect(R.gitText(choice: .smallModel, thread: Self.pickle, hasThread: true, small: Self.sonnet, catalog: Self.mixed) == .model(Self.sonnet, .small))
        // …else opencode's fast family of the thread's provider…
        #expect(R.gitText(choice: .smallModel, thread: Self.sonnet, hasThread: true, small: nil, catalog: Self.mixed) == .model(Self.haiku, .small))
        // …else the paid-first fallback.
        #expect(R.gitText(choice: .smallModel, thread: Self.pickle, hasThread: true, small: nil, catalog: Self.mixed) == .model(Self.haiku, .small))
        // A chosen model that is gone: back to the thread.
        let gone = ModelSelection(providerID: "gone", modelID: "x")
        #expect(R.gitText(choice: .specific(gone), thread: Self.sonnet, hasThread: true, small: nil, catalog: Self.mixed) == .thread)
        #expect(R.gitText(choice: .specific(gone), thread: nil, hasThread: false, small: nil, catalog: Self.mixed) == .model(Self.pickle, .serverDefault))
    }

    @Test func childThreadsAndSchedules() {
        typealias R = BackgroundModelResolver
        #expect(R.child(choice: .sameAsThread, parent: Self.sonnet, catalog: Self.mixed) == Self.sonnet)
        #expect(R.child(choice: .serverDefault, parent: Self.sonnet, catalog: Self.mixed) == nil)
        #expect(R.child(choice: .specific(Self.haiku), parent: Self.sonnet, catalog: Self.mixed) == Self.haiku)
        #expect(R.child(choice: .specific(ModelSelection(providerID: "gone", modelID: "x")), parent: Self.sonnet, catalog: Self.mixed) == Self.sonnet)
        // N33: the owner's configured small model is used for "Small model".
        #expect(R.child(choice: .smallModel, parent: Self.sonnet, catalog: Self.mixed, small: Self.pickle) == Self.pickle)
    }

    // MARK: Values

    @Test func choiceTokensRoundTrip() throws {
        let values: [ModelChoice] = [
            .sameAsThread, .serverDefault, .smallModel, .specific(Self.sonnet),
            .specific(ModelSelection(providerID: "openrouter", modelID: "anthropic/claude-haiku-5", variant: "high")),
        ]
        for value in values {
            #expect(ModelChoice(token: value.token) == value)
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(ModelChoice.self, from: data) == value)
        }
        #expect(ModelChoice(token: "nonsense") == nil)
        #expect(ModelSelection(token: "a/b#")?.variant == nil && ModelSelection(token: "a/b#") == nil)
        // The reviewer's settings keep reading old saved values.
        var settings = AutoReviewer.Settings.standard
        #expect(settings.choice == .sameAsThread)
        settings.choice = .specific(Self.haiku)
        #expect(settings.model == "anthropic/claude-haiku-5")
        settings.choice = .sameAsThread
        #expect(settings.model == nil)
        let old = try JSONDecoder().decode(AutoReviewer.Settings.self, from: Data(#"{"model":"opencode/x","timeoutSeconds":5,"maxConcurrent":2,"maxQueued":8,"budgetPerHour":240}"#.utf8))
        #expect(old.choice == .specific(ModelSelection(providerID: "opencode", modelID: "x")))
    }

    @Test func providerRefusalsAreMappedFromOpenCodeErrors() throws {
        func http(_ status: Int, _ json: String) throws -> OpenCodeError {
            .http(status: status, body: try JSONDecoder().decode(ServerErrorBody.self, from: Data(json.utf8)), operation: "generate.text")
        }
        let free = try http(502, #"{"_tag":"ProviderRequestError","providerID":"opencode","reason":"rate_limit","message":"Free usage limit reached","status":429}"#)
        #expect(BackgroundModelError.classify(free) == .quota)
        let rate = try http(502, #"{"_tag":"ProviderRequestError","providerID":"anthropic","reason":"rate_limit","message":"Too many requests"}"#)
        #expect(BackgroundModelError.classify(rate) == .rateLimited)
        let auth = try http(502, #"{"_tag":"ProviderRequestError","providerID":"anthropic","reason":"authentication","message":"invalid x-api-key"}"#)
        #expect(BackgroundModelError.classify(auth) == .authentication)
        let gone = try http(404, #"{"_tag":"ModelNotFoundError","providerID":"a","modelID":"b","message":"Model not found"}"#)
        #expect(BackgroundModelError.classify(gone) == .unavailable)
        let billing = try http(500, #"{"_tag":"UnknownError","message":"insufficient_quota: You exceeded your current quota"}"#)
        #expect(BackgroundModelError.classify(billing) == .quota)
        #expect(BackgroundModelError.classify(EngineError.server("Free usage limit reached")) == .quota)
        // N15: already-translated errors (session.generate) carry the other refusals too.
        #expect(BackgroundModelError.classify(EngineError.server("Too many requests, please slow down")) == .rateLimited)
        #expect(BackgroundModelError.classify(EngineError.rejected("invalid x-api-key")) == .authentication)
        #expect(BackgroundModelError.classify(EngineError.server("Overloaded")) == .overloaded)
        #expect(BackgroundModelError.classify(EngineError.rejected("Model not found: a/b")) == .unavailable)
        #expect(BackgroundModelError.classify(EngineError.server("boom")) == nil)
        #expect(BackgroundModelError.classify(try http(500, #"{"_tag":"UnknownError","message":"boom"}"#)) == nil)
        #expect(BackgroundModelError.classify(OpenCodeError.transport(operation: "x", code: .timedOut)) == nil)
        let message = BackgroundModelError(kind: .quota, model: "OpenCode Zen · Big Pickle", task: "Auto's reviewer").message
        #expect(message.contains("Big Pickle") && message.contains("Settings ▸ Models") && message.contains("usage limit"))
        #expect(message.count < 160, "fits the audit entry with the reviewer's suffix")
    }
}

@Suite("Background models against the mock", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct BackgroundModelMockTests {
    static let project = "/tmp/mock-background-models"

    func start(reviewer: (any AutoReviewer.Model)? = nil, folder: URL? = nil) async throws -> (MockHarness, Engine) {
        try FileManager.default.createDirectory(atPath: Self.project, withIntermediateDirectories: true)
        let harness = try await MockHarness.start(.empty(directory: Self.project))
        var configuration = EngineConfiguration(server: .fixed(harness.connection), store: .inMemory)
        configuration.eventBackoff = BackoffPolicy(initial: .milliseconds(20), maximum: .milliseconds(200))
        configuration.writeInterval = .milliseconds(20)
        configuration.autoReviewerModel = reviewer
        let engine = try Engine(configuration: configuration)
        if let folder {
            let connection = harness.connection
            engine.models = ModelSettingsService(
                store: engine.store, folder: GlobalConfigFolder(url: folder), modelDefaultsFile: folder.appending(path: "bellocode-models.json"),
                client: { OpenCodeClient(connection: connection) })
            engine.models.engine = engine
        }
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        await engine.addProject(directory: Self.project)
        await engine.refreshCatalog(directory: Self.project)
        try await waitUntil("catalog") { engine.root.catalog.catalog(for: Self.project)?.models.isEmpty == false }
        return (harness, engine)
    }

    static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "bellocode-models-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func gitTextSendsTheChosenModelToGenerateText() async throws {
        let (harness, engine) = try await start()
        defer { Task { await engine.stop(); await harness.stop() } }
        let session = try await engine.createThread(in: Self.project, title: "git")
        // Same as thread: the thread's own context (session.generate), no stateless call.
        _ = try await engine.generateText(in: session.id, prompt: "commit message please", task: "Commit message")
        #expect(await harness.server.sessionGenerations() == [session.id.rawValue])
        #expect(await harness.server.generateTextBodies().isEmpty)
        // A chosen paid model: stateless generate.text with that model.
        await engine.models.setGitText(.specific(ModelSelection(providerID: "mockai", modelID: "mock-small")))
        let text = try await engine.generateText(in: session.id, prompt: "commit message please", task: "Commit message")
        #expect(text.hasPrefix("Add launch checklist"))
        let body = try #require(await harness.server.generateTextBodies().last)
        #expect(body["model"]?["providerID"]?.stringValue == "mockai")
        #expect(body["model"]?["id"]?.stringValue == "mock-small")
        #expect(engine.gitTextModelLabel(for: session.id) == "Mock AI · Mock Small")
    }

    @Test func aQuotaRefusalNamesTheModelAndSettings() async throws {
        let (harness, engine) = try await start()
        defer { Task { await engine.stop(); await harness.stop() } }
        let session = try await engine.createThread(in: Self.project, title: "git")
        await engine.models.setGitText(.specific(ModelSelection(providerID: "opencode", modelID: "big-pickle")))
        await harness.server.setGenerateTextFailure(.freeUsageLimit())
        do {
            _ = try await engine.generateText(in: session.id, prompt: "x", task: "Commit message")
            Issue.record("expected a refusal")
        } catch let refusal as BackgroundModelError {
            #expect(refusal.kind == .quota)
            #expect(refusal.message == "Commit message model OpenCode · Big Pickle hit its provider's usage limit. Choose a paid model in Settings ▸ Models.")
        }
    }

    @Test func theReviewerAsksTheResolvedModelAndReportsAQuotaRefusal() async throws {
        let (harness, engine) = try await start()
        defer { Task { await engine.stop(); await harness.stop() } }
        // The mock's default is the free Big Pickle and Mock AI is a paid provider: the reviewer must not use the free one.
        let session = try await engine.createThread(in: Self.project, title: "auto", permissionMode: .auto)
        let thread = engine.openThread(session.id)
        defer { thread.close() }
        try await waitUntil("session") { thread.session != nil }
        let resolution = engine.auto.reviewerResolution(for: thread.session)
        #expect(resolution.selection?.providerID == "mockai", "picked \(resolution.selection?.token ?? "nil")")
        let input = AutoReviewer.Input.sample
        let reviewer = AutoReviewer(backend: OpenCodeReviewModel(client: { harness.client }))
        let allowed = await reviewer.review(input, model: AutoReviewer.modelRef(resolution.selection), label: "Mock AI · Mock Small")
        #expect(allowed.outcome.allows)
        let body = try #require(await harness.server.generateTextBodies().last)
        #expect(body["model"]?["providerID"]?.stringValue == "mockai")
        // The owner picks the free model; its allowance is used up: the escalation says which model and where to fix it.
        await harness.server.setGenerateTextFailure(.freeUsageLimit())
        let refused = await reviewer.review(
            AutoReviewer.Input(action: "shell", tool: "shell", targets: ["make"], command: "make", purpose: "x", policyNote: "y"),
            model: ModelRef(id: "big-pickle", providerID: "opencode"), label: "OpenCode · Big Pickle")
        #expect(refused.outcome.reasonCode == "provider_limit")
        #expect(refused.outcome.explanation.contains("OpenCode · Big Pickle") && refused.outcome.explanation.contains("Settings ▸ Models"))
    }

    @Test func preferencesRoundTripAndTheDefaultsFileFollows() async throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (harness, engine) = try await start(folder: folder)
        defer { Task { await engine.stop(); await harness.stop() } }
        let haiku = ModelSelection(providerID: "mockai", modelID: "mock-small", variant: "high")
        await engine.models.setGitText(.smallModel)
        await engine.models.setDelegated(.specific(haiku))
        #expect(ModelDefaultsFile.read(from: folder.appending(path: "bellocode-models.json"))?.delegated == "mockai/mock-small#high")
        // A fresh service over the same store reads them back.
        let again = ModelSettingsService(store: engine.store, folder: GlobalConfigFolder(url: folder), modelDefaultsFile: nil, client: { harness.client })
        await again.load()
        #expect(again.background == BackgroundModelSettings(gitText: .smallModel, delegated: .specific(haiku)))
        // The reviewer's choice persists through AutoModeService.
        var settings = engine.auto.settings
        settings.choice = .serverDefault
        await engine.auto.updateSettings(settings)
        #expect(try await engine.store.preference("auto.reviewer", as: AutoReviewer.Settings.self)?.choice == .serverDefault)
    }

    @Test func defaultAndSmallModelAreWrittenToOpenCodeJSONAndReloaded() async throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appending(path: "opencode.json")
        try Data("{\n  // mine\n  \"$schema\": \"https://opencode.ai/config.json\",\n  \"agents\": { \"reviewer\": { \"model\": \"a/b\" } }\n}\n".utf8).write(to: config)
        let (harness, engine) = try await start(folder: folder)
        defer { Task { await engine.stop(); await harness.stop() } }
        let mockSmall = ModelSelection(providerID: "mockai", modelID: "mock-small")
        #expect(await engine.models.setDefaultModel(ModelSelection(providerID: "mockai", modelID: "mock-large")) == nil)
        #expect(await engine.models.setSmallModel(mockSmall) == nil)
        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(text.contains("// mine"), "comments are kept")
        #expect(JSONCEditor.string(at: ["model"], in: text) == "mockai/mock-large")
        #expect(JSONCEditor.string(at: ["agents", "title", "model"], in: text) == "mockai/mock-small")
        #expect(JSONCEditor.string(at: ["agents", "reviewer", "model"], in: text) == "a/b")
        #expect(await harness.server.recordedRequests().contains { $0.contains("/api/location/reload") })
        // Read back by a fresh service; removing restores opencode's own choice.
        await engine.models.readConfig()
        #expect(engine.models.configuredSmall == mockSmall)
        #expect(await engine.models.setSmallModel(nil, reload: false) == nil)
        #expect(engine.models.reloadPending)
        #expect(JSONCEditor.value(at: ["agents", "title"], in: try String(contentsOf: config, encoding: .utf8)) == nil)
    }

    final class RecordingRunner: ScheduleRunner {
        var models: [ModelSelection?] = []
        func startThread(
            directory: String, title: String, prompt: String, agent: String?, model: ModelSelection?, permissionMode: PermissionMode?
        ) async throws -> SessionID {
            models.append(model)
            return SessionID("ses_run\(models.count)")
        }
        func send(_ prompt: String, to thread: SessionID) async throws {}
        func threadExists(_ id: SessionID) -> Bool { true }
    }

    @Test func scheduledRunsWithoutAModelUseTheOwnersDefault() async throws {
        let (harness, engine) = try await start()
        defer { Task { await engine.stop(); await harness.stop() } }
        let large = ModelSelection(providerID: "mockai", modelID: "mock-large")
        let creator = try await engine.createThread(in: Self.project, title: "creator", model: large)
        var task = ScheduledTask(name: "Nightly", prompt: "p", rule: .interval(minutes: 60), directory: Self.project, created: Date())
        task.createdBy = creator.id
        // Same as parent: the model of the thread that created the schedule.
        #expect(await engine.extras.scheduledRunModel(task) == large)
        await engine.models.setDelegated(.serverDefault)
        #expect(await engine.extras.scheduledRunModel(task) == nil)
        let small = ModelSelection(providerID: "mockai", modelID: "mock-small")
        await engine.models.setDelegated(.specific(small))
        #expect(await engine.extras.scheduledRunModel(task) == small)

        // The scheduler asks only when the task names no model.
        let clock = ManualWallClock(Date(timeIntervalSince1970: 1_800_000_000))
        let service = SchedulerService(store: try ProjectionStore(location: .inMemory), clock: clock)
        let runner = RecordingRunner()
        service.runner = runner
        service.defaultModel = { _ in small }
        await service.start()
        _ = try await service.create(ScheduledTask(name: "A", prompt: "p", rule: .once(clock.now().addingTimeInterval(60)), directory: "/r", created: clock.now()))
        _ = try await service.create(ScheduledTask(
            name: "B", prompt: "p", rule: .once(clock.now().addingTimeInterval(60)), directory: "/r", model: large, created: clock.now()))
        clock.advance(by: 60)
        await service.tick()
        #expect(Set(runner.models.map { $0?.modelID }) == ["mock-small", "mock-large"])
        service.shutdown()
    }

    @Test func aCredentialChangeRefreshesEveryCatalog() {
        var state = ProjectionState()
        let decoder = OpenCodeEventDecoder()
        let envelope = decoder.decode(Data(#"{"id":"evt_1","created":1,"type":"credential.updated","data":{"integrationID":"anthropic","credentialID":"cred_1"}}"#.utf8))
        let reduction = EventReducer.reduce(envelope, into: &state, now: .now)
        #expect(reduction.effects.contains(.refreshAllCatalogs))
        let model = decoder.decode(Data(#"{"id":"evt_2","created":2,"type":"model.updated","location":{"directory":"/p"},"data":{}}"#.utf8))
        #expect(EventReducer.reduce(model, into: &state, now: .now).effects.contains(.refreshCatalog(directory: "/p")))
    }
}
