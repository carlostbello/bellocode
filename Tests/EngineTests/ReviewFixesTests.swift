import BelloCore
import Foundation
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
