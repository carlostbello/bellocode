import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// Deep review 1, C5: a short or empty page that proves the whole history reconciles the cache by session, including
/// rows outside the returned range and rows not in the memory cache, with their parts and search entries.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct HistoryReconcileTests {
    func engine(_ harness: MockHarness, url: URL) throws -> Engine {
        var configuration = EngineConfiguration(server: .fixed(harness.connection), store: .file(url))
        configuration.eventBackoff = BackoffPolicy(initial: .milliseconds(20), maximum: .milliseconds(200))
        configuration.writeInterval = .milliseconds(20)
        return try Engine(configuration: configuration)
    }

    /// Writes cached rows the server does not have (deleted there while BelloCode was away).
    func seedStaleRows(_ store: ProjectionStore, session: SessionID, at ms: Double, prefix: String) async throws -> [MessageID] {
        var batch = StoreBatch()
        batch.messages = [
            Fixtures.userMessage("msg_\(prefix)u", session: session.rawValue, text: "zebra \(prefix) question", at: ms),
            Fixtures.assistantMessage("msg_\(prefix)a", session: session.rawValue, text: "zebra \(prefix) answer", at: ms + 1),
        ]
        try await store.apply(batch, publish: false)
        return batch.messages.map(\.id)
    }

    @Test func aShortenedTailAndAnEmptyHistoryAreReconciledAfterRelaunch() async throws {
        let harness = try await MockHarness.start()
        let url = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        var talked = SessionID("ses_x")
        var empty = SessionID("ses_y")
        do {
            let first = try engine(harness, url: url)
            await first.start()
            try await waitUntil("live") { first.root.connection == .live }
            talked = try await first.createThread(in: "/tmp/mock-project", title: "Talked").id
            empty = try await first.createThread(in: "/tmp/mock-project", title: "Empty").id
            let thread = first.openThread(talked)
            try await waitUntil("ready") { thread.phase == .ready }
            #expect(await thread.send("hello there") != nil)
            await harness.server.waitUntilIdle(talked.rawValue)
            let served = try await harness.listedMessages(talked).map(\.id)
            #expect(!served.isEmpty)
            try await waitUntil("history shown", timeout: .seconds(30)) { Set(served).isSubset(of: Set(thread.messageIDs)) }
            await first.flush()
            thread.close()
            await first.stop()
        }
        // While BelloCode was quit the server lost the tail of one thread and every message of the other.
        let now = Timestamp.now.milliseconds
        let store = try await ProjectionStore.open(location: .file(url))
        let staleTail = try await seedStaleRows(store, session: talked, at: now - 2_000, prefix: "tail")
        let staleAll = try await seedStaleRows(store, session: empty, at: now - 2_000, prefix: "gone")
        // Admitted after the next read (newer than it): must survive.
        let future = try await seedStaleRows(store, session: talked, at: now + 600_000, prefix: "late")
        #expect(try await store.search("zebra").count == 6)

        let second = try engine(harness, url: url)
        await second.start()
        let a = second.openThread(talked)
        let b = second.openThread(empty)
        try await waitUntil("live") { second.root.connection == .live }
        let listed = Set(try await harness.listedMessages(talked).map(\.id))
        let settled = await waitUntilAsync(timeout: .seconds(10)) {
            let cached = try? await second.store.allMessages(sessionID: talked).map(\.id)
            let gone = try? await second.store.allMessages(sessionID: empty).map(\.id)
            return cached.map { !$0.contains(where: staleTail.contains) } == true && gone?.isEmpty == true
        }
        if !settled {
            let cached = try await second.store.allMessages(sessionID: talked).map(\.id.rawValue)
            let gone = try await second.store.allMessages(sessionID: empty).map(\.id.rawValue)
            Issue.record("not reconciled: talked=\(cached) listed=\(listed.map(\.rawValue)) empty=\(gone) a=\(a.messageIDs.map(\.rawValue)) b=\(b.messageIDs.map(\.rawValue))")
        }
        try await waitUntil("shown threads updated") { !a.messageIDs.contains(where: staleTail.contains) && b.messageIDs.isEmpty }
        await second.flush()
        let cachedTalked = Set(try await second.store.allMessages(sessionID: talked).map(\.id))
        #expect(cachedTalked == listed.union(future), "server history plus the newer admission")
        #expect(try await second.store.allMessages(sessionID: empty).map(\.id).isEmpty, "an empty list clears the cache")
        let hits = try await second.store.search("zebra").map(\.messageID)
        #expect(Set(hits) == Set(future), "deleted messages are no longer searchable")
        #expect(staleAll.allSatisfy { !hits.contains($0) })
        #expect(try await second.store.syncState(talked)?.historyComplete == true)
        a.close()
        b.close()
        await second.stop()
        await harness.stop()
    }

    /// A thread's first history page is read before a turn and answered after it (a slow answer under load): the page
    /// is older than the turn's events, so the prompt and reply it does not list stay shown and cached. This used to
    /// remove them (the page is short, so it "proved" the whole history), leaving an empty thread, or a reply
    /// rebuilt from later parts without its prompt or first parts.
    @Test func aHistoryPageAnsweredAfterLaterEventsRemovesNothingNewer() async throws {
        let harness = try await MockHarness.start()
        let url = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let engine = try engine(harness, url: url)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        // The window read reaches the server now (empty history) and its answer waits at the gate.
        await harness.server.injectHTTPFault(HTTPFault(
            method: "GET", pathPrefix: "/api/session/\(session.id.rawValue)/message", action: .holdResponse(gate: "page"), count: 1))
        let thread = engine.openThread(session.id)
        let held = await waitUntilAsync(timeout: .seconds(20)) { await harness.server.heldResponseCount(gate: "page") == 1 }
        try #require(held, "the window read is held at the server")

        // A whole turn arrives by events while the page is in flight.
        await thread.send("hello #script:greeting")
        await harness.server.waitUntilAllIdle()
        try await waitUntil("reply") { thread.status?.status == .finishedUnread }
        await engine.flush()
        try await threadBarrier(engine, thread)
        let shown = thread.messageIDs
        #expect(shown.compactMap { thread.message($0)?.message.kind.typeName } == ["user", "assistant"])

        // The stale, empty page lands.
        await harness.server.releaseResponses(gate: "page")
        let applied = await waitUntilAsync(timeout: .seconds(20)) { (try? await engine.store.syncState(session.id))?.synced != nil }
        #expect(applied, "the held page was applied")
        await engine.flush()
        try await threadBarrier(engine, thread)
        #expect(thread.messageIDs == shown, "nothing newer than the page is removed from the thread")
        let cached = try await engine.store.allMessages(sessionID: session.id).map(\.id)
        #expect(Set(cached) == Set(shown), "nor from the cache")
        thread.close()
        await engine.stop()
        await harness.stop()
    }

    @Test func storeReconcileDeletesPartsAndSearchEntriesInOneBatch() async throws {
        let store = try ProjectionStore(location: .inMemory)
        let session = SessionID("ses_r")
        let ids = try await seedStaleRows(store, session: session, at: 1_000, prefix: "x")
        var batch = StoreBatch()
        batch.reconciledHistory[session] = StoreBatch.HistoryReconcile(keep: [ids[0]], through: Timestamp(milliseconds: 5_000))
        try await store.apply(batch, publish: false)
        #expect(try await store.allMessages(sessionID: session).map(\.id) == [ids[0]])
        #expect(try await store.search("answer").isEmpty)
        #expect(try await store.partCount(messageID: ids[1]) == 0)
    }
}

/// Polls an async condition (store reads) until it holds or the timeout passes.
@MainActor
func waitUntilAsync(timeout: Duration, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
