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
            try await waitUntil("reply cached") { thread.messageIDs.count >= 2 }
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
