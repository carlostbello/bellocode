import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// An engine with no server (the source never resolves): cache-only behaviour.
@MainActor
func makeOfflineEngine(store: ProjectionStore.Location = .inMemory, configure: (inout EngineConfiguration) -> Void = { _ in })
    throws -> Engine
{
    var configuration = EngineConfiguration(server: .dynamic { nil }, store: store)
    configuration.writeInterval = .milliseconds(20)
    configure(&configuration)
    return try Engine(configuration: configuration)
}

/// Regression tests for docs/reviews/M1-review.md.
@Suite("M1 review fixes", .serialized)
@MainActor
struct ReviewFixesTests {
    // MARK: M1: draft hydration

    /// The thread model opens before its cached draft is read. An edit made in that window must not replace the
    /// restored draft, and the restored draft must not silently replace the edit.
    @Test func draftEditedBeforeHydrationIsMergedNotLost() async throws {
        let engine = try makeOfflineEngine()
        let id = SessionID("ses_draft")
        var batch = StoreBatch()
        batch.threadUI = [ThreadUIState(sessionID: id, draft: "restored text")]
        try await engine.store.apply(batch, publish: false)
        await engine.start()

        let thread = engine.openThread(id)
        // No suspension since `openThread`: the snapshot cannot have been applied yet.
        #expect(!thread.isDraftLoaded)
        #expect(thread.draft == "")
        thread.draft = "typed early"
        try await waitUntil("hydrated") { thread.isDraftLoaded }
        #expect(thread.draft == "restored text\n\ntyped early")
        thread.close()
        await engine.stop()
        let stored = try await engine.store.threadUIStates().first { $0.sessionID == id }
        #expect(stored?.draft == "restored text\n\ntyped early")
    }

    /// Closing (or evicting) a thread before its draft was read must not write the empty placeholder over the stored
    /// draft.
    @Test func closingBeforeHydrationKeepsStoredDraft() async throws {
        let engine = try makeOfflineEngine()
        let id = SessionID("ses_close")
        var batch = StoreBatch()
        batch.threadUI = [ThreadUIState(sessionID: id, draft: "keep me")]
        try await engine.store.apply(batch, publish: false)
        await engine.start()
        let thread = engine.openThread(id)
        #expect(!thread.isDraftLoaded)
        thread.close()
        await engine.stop()
        let stored = try await engine.store.threadUIStates().first { $0.sessionID == id }
        #expect(stored?.draft == "keep me")

        // An edit before hydration is kept together with the stored draft when the thread closes first.
        let again = try makeOfflineEngine()
        try await again.store.apply(batch, publish: false)
        await again.start()
        let reopened = again.openThread(id)
        reopened.draft = "new words"
        reopened.close()
        await again.stop()
        let merged = try await again.store.threadUIStates().first { $0.sessionID == id }
        #expect(merged?.draft == "keep me\n\nnew words")
    }

    @Test func draftMergeRules() {
        #expect(ThreadModel.mergeDrafts(stored: "", local: "a") == "a")
        #expect(ThreadModel.mergeDrafts(stored: "a", local: "") == "a")
        #expect(ThreadModel.mergeDrafts(stored: "a", local: "a") == "a")
        #expect(ThreadModel.mergeDrafts(stored: "abc", local: "abc def") == "abc def")
        #expect(ThreadModel.mergeDrafts(stored: "abc", local: "xyz") == "abc\n\nxyz")
    }
}

// MARK: - M4: ambiguous sends

@Suite("M4 ambiguous sends", .serialized)
@MainActor
struct AmbiguousSendTests {
    @MainActor struct Setup {
        let harness: MockHarness
        let engine: Engine
        let thread: ThreadModel
        var sessionID: String { thread.sessionID.rawValue }
    }

    func setUp() async throws -> Setup {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        let thread = engine.openThread(session.id)
        try await waitUntil("ready") { thread.phase == .ready && thread.isDraftLoaded }
        return Setup(harness: harness, engine: engine, thread: thread)
    }

    func tearDown(_ setup: Setup) async {
        setup.thread.close()
        await setup.engine.stop()
        await setup.harness.stop()
    }

    func serverUserMessages(_ setup: Setup) async throws -> [Message] {
        await setup.harness.server.waitUntilIdle(setup.sessionID)
        return try await setup.harness.listedMessages(setup.thread.sessionID).filter { $0.kind.typeName == "user" }
    }

    /// The server admits the prompt but every answer is lost: the engine finds it under its ID instead of telling the
    /// user it was not sent.
    @Test func acceptedWithLostAnswersIsReconciledAsSent() async throws {
        let setup = try await setUp()
        let server = setup.harness.server
        await server.injectHTTPFault(HTTPFault(method: "POST", pathPrefix: "/api/session/\(setup.sessionID)/prompt", action: .dropResponse, count: nil))
        setup.thread.draft = "run the migration"
        let id = await setup.thread.send()
        #expect(id != nil)
        #expect(setup.thread.lastError == nil)
        #expect(setup.thread.draft == "")
        #expect(setup.thread.unconfirmedSends.isEmpty)
        await server.clearHTTPFaults()
        let users = try await serverUserMessages(setup)
        #expect(users.map(\.id) == [id].compactMap { $0 })
        await tearDown(setup)
    }

    /// Answers lost and the server cannot be asked: "delivery unknown", not "not sent". The text is not put back in the
    /// draft; a retry with the same ID is admitted once.
    @Test func unknownDeliveryIsHeldAndRetriedWithTheSameID() async throws {
        let setup = try await setUp()
        let server = setup.harness.server
        let base = "/api/session/\(setup.sessionID)"
        await server.injectHTTPFault(HTTPFault(method: "POST", pathPrefix: "\(base)/prompt", action: .dropResponse, count: nil))
        await server.injectHTTPFault(HTTPFault(method: "GET", pathPrefix: "\(base)/message/", action: .resetConnection, count: nil))
        await server.injectHTTPFault(HTTPFault(method: "GET", pathPrefix: "\(base)/inbox", action: .resetConnection, count: nil))
        setup.thread.draft = "deploy to staging"
        let id = await setup.thread.send()
        #expect(id == nil)
        #expect(setup.thread.lastError == .deliveryUnknown)
        #expect(setup.thread.draft == "", "an unknown send must not invite a second send")
        let held = try #require(setup.thread.unconfirmedSends.first)
        #expect(held.state == .unknown)
        #expect(held.text == "deploy to staging")
        // The optimistic message stays (not delivered, not removed).
        #expect(userMessages(setup.thread).contains { $0.id == held.id })

        await server.clearHTTPFaults()
        await setup.thread.retryUnconfirmed(held.id)
        try await waitUntil("resolved") { setup.thread.unconfirmedSends.isEmpty }
        let users = try await serverUserMessages(setup)
        #expect(users.map(\.id) == [held.id], "admitted exactly once, under the original ID")
        #expect(setup.thread.lastError == .deliveryUnknown || setup.thread.lastError == nil)
        await tearDown(setup)
    }

    /// Never admitted, answers lost, then the server is reachable: it is not there, so it is sent once more under the
    /// same ID and admitted.
    @Test func lostRequestIsResentUnderTheSameIDOnce() async throws {
        let setup = try await setUp()
        let server = setup.harness.server
        await server.injectHTTPFault(HTTPFault(method: "POST", pathPrefix: "/api/session/\(setup.sessionID)/prompt", action: .resetConnection, count: 3))
        let id = await setup.thread.send("format the code")
        #expect(id != nil)
        #expect(setup.thread.unconfirmedSends.isEmpty)
        let users = try await serverUserMessages(setup)
        #expect(users.map(\.id) == [id].compactMap { $0 })
        #expect(await server.promptBodies().count == 1)
        await tearDown(setup)
    }

    /// A definite refusal after a lost answer, with the server confirming it does not have the prompt: not sent, and the
    /// text returns to the draft. A retry of an unknown send that is refused becomes "not sent" with its text kept.
    @Test func definiteRefusalsAreNotSent() async throws {
        let setup = try await setUp()
        let server = setup.harness.server
        let prompt = "/api/session/\(setup.sessionID)/prompt"
        await server.injectHTTPFault(HTTPFault(method: "POST", pathPrefix: prompt, action: .resetConnection, count: 1))
        await server.injectHTTPFault(.status(400, method: "POST", pathPrefix: prompt, tag: "InvalidRequestError", count: nil))
        setup.thread.draft = "bad request"
        #expect(await setup.thread.send() == nil)
        #expect(setup.thread.lastError != .deliveryUnknown)
        #expect(setup.thread.draft == "bad request")
        #expect(setup.thread.unconfirmedSends.isEmpty)
        await server.clearHTTPFaults()

        let base = "/api/session/\(setup.sessionID)"
        await server.injectHTTPFault(HTTPFault(method: "POST", pathPrefix: prompt, action: .resetConnection, count: nil))
        await server.injectHTTPFault(HTTPFault(method: "GET", pathPrefix: "\(base)/message/", action: .resetConnection, count: nil))
        #expect(await setup.thread.send("second") == nil)
        let held = try #require(setup.thread.unconfirmedSends.first)
        await server.clearHTTPFaults()
        await server.injectHTTPFault(.status(400, method: "POST", pathPrefix: prompt, tag: "InvalidRequestError", count: nil))
        await setup.thread.retryUnconfirmed(held.id)
        try await waitUntil("not sent") {
            if case .notSent = setup.thread.unconfirmedSends.first?.state { true } else { false }
        }
        #expect(!userMessages(setup.thread).contains { $0.id == held.id })
        #expect(await setup.thread.takeUnconfirmed(held.id) == "second")
        try await waitUntil("removed") { setup.thread.unconfirmedSends.isEmpty }
        await server.clearHTTPFaults()
        #expect(try await serverUserMessages(setup).isEmpty)
        await tearDown(setup)
    }
}

// MARK: - M2: resync retry while connected

@Suite("M2 resync retry", .serialized)
@MainActor
struct ResyncRetryTests {
    /// The list endpoints fail through every resync attempt while the event stream stays connected. The engine must
    /// show the cache as out of date, then retry (with backoff) until a rebuild succeeds, without a reconnect.
    @Test func failedResyncIsRetriedWhileConnected() async throws {
        let harness = try await MockHarness.start()
        // The three attempts of the connect resync and of the first retry fail; the second retry succeeds.
        await harness.server.injectHTTPFault(.status(500, method: "GET", pathPrefix: "/api/info", count: 6))
        var configuration = EngineConfiguration(server: .fixed(harness.connection), store: .inMemory)
        configuration.eventBackoff = BackoffPolicy(initial: .milliseconds(20), maximum: .milliseconds(200))
        configuration.resyncRetryBackoff = BackoffPolicy(initial: .milliseconds(10), maximum: .milliseconds(40))
        let engine = try Engine(configuration: configuration)
        await engine.start()
        try await waitUntil("stale") {
            if case .offline = engine.root.connection { true } else { false }
        }
        #expect(await harness.server.subscriberCount == 1, "the event stream stays connected")
        try await waitUntil("live after retries") { engine.root.connection == .live }
        let scheduled = await engine.core.resyncRetriesScheduled
        let resyncs = await engine.core.statistics.resyncs
        #expect(scheduled == 2)
        #expect(resyncs == 3, "the connect resync and two retries, no reconnect")
        await engine.stop()
        await harness.stop()
    }

    /// Stopping cancels a pending retry: nothing runs after `stop()`.
    @Test func stopCancelsPendingRetry() async throws {
        let harness = try await MockHarness.start()
        await harness.server.injectHTTPFault(.status(500, method: "GET", pathPrefix: "/api/info", count: nil))
        var configuration = EngineConfiguration(server: .fixed(harness.connection), store: .inMemory)
        configuration.resyncRetryBackoff = BackoffPolicy(initial: .seconds(30), maximum: .seconds(30))
        let engine = try Engine(configuration: configuration)
        await engine.start()
        try await waitUntil("retry scheduled") {
            if case .offline = engine.root.connection { true } else { false }
        }
        await engine.stop()
        let resyncs = await engine.core.statistics.resyncs
        #expect(resyncs == 1)
        #expect(engine.root.connection == .stopped)
        await harness.stop()
    }
}
