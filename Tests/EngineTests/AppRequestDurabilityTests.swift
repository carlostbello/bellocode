import BelloCore
import Foundation
import GRDB
import OpenCodeKit
import Testing

@testable import Engine

/// Deep review 1, C3: BelloCode's own requests (secret requests, app approvals) live in an app-owned table that cache
/// rebuilds, complete server lists and the cache-write give-up never drop.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct AppRequestDurabilityTests {
    static func appCard(_ session: String = "ses_app") -> AppRequest {
        AppRequest(
            id: AppRequest.makeID("secret"), sessionID: SessionID(session),
            kind: .secret(SecretPrompt(label: "Deploy token", reason: "deploy")), received: .now)
    }

    static func permission(_ id: String, session: String = "ses_app") -> PendingRequest {
        .permission(PermissionRequest(
            id: PermissionRequestID(id), sessionID: SessionID(session), action: "shell", resources: ["make"], received: .now))
    }

    func temporaryStore() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "app-requests-\(UUID().uuidString).sqlite")
    }

    @Test func rebuildAndACompleteServerListKeepAnAppRequest() async throws {
        let store = try ProjectionStore(location: .inMemory)
        let card = Self.appCard()
        var batch = StoreBatch()
        batch.pending = [.app(card), Self.permission("per_1")]
        try await store.apply(batch, publish: false)
        // A complete server list without the app request (it is never on the server).
        var server = StoreBatch()
        server.pending = [Self.permission("per_2")]
        server.replaceAllPending = true
        try await store.apply(server, publish: false)
        #expect(Set(try await store.pendingRequests().map(\.id)) == [card.id, "per_2"])
        try await store.rebuild()
        #expect(try await store.pendingRequests().map(\.id) == [card.id], "a cache rebuild keeps the app's own card")
        // Answering it removes it.
        var resolved = StoreBatch()
        resolved.resolvedRequests = [card.id]
        try await store.apply(resolved, publish: false)
        #expect(try await store.pendingRequests().isEmpty)
    }

    @Test func mergingAReplaceAllBatchKeepsQueuedAppRequestWrites() {
        let card = Self.appCard()
        var batch = StoreBatch()
        batch.pending = [.app(card)]
        var server = StoreBatch()
        server.pending = [Self.permission("per_9")]
        server.replaceAllPending = true
        batch.merge(server)
        #expect(Set(batch.pending.map(\.id)) == [card.id, "per_9"])
        #expect(batch.appOwned.pending.map(\.id) == [card.id])
        #expect(batch.cacheOnly.pending.map(\.id) == ["per_9"])
    }

    @Test func repeatedCacheWriteFailuresKeepTheAppCardAcrossRelaunch() async throws {
        let url = temporaryStore()
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let probe = WriteProbe()
        let card = Self.appCard()
        do {
            let engine = try makeOfflineEngine(store: .file(url)) { configuration in
                configuration.writeInterval = .milliseconds(5)
                configuration.writeRetryBackoff = BackoffPolicy(initial: .milliseconds(5), maximum: .milliseconds(20))
            }
            await engine.store.setWriteHook { batch in try await probe.enter(batch) }
            await engine.start()
            await probe.configure(failCacheRows: true)
            var cache = StoreBatch()
            cache.sessions = [Fixtures.session("ses_cache")]
            await engine.core.enqueueWritesForTesting(cache)
            await engine.core.putAppRequest(card)
            let deadline = ContinuousClock.now + .seconds(20)
            while await engine.core.statistics.cacheWritesDropped < 1, ContinuousClock.now < deadline { await Task.yield() }
            #expect(await engine.core.statistics.cacheWritesDropped == 1, "the cache part was given up")
            try await waitUntil("app rows written") { engine.root.storage == .ok }
            await engine.stop()
        }
        // Relaunch: the card is read back from disk (opencode could not have rebuilt it).
        let again = try makeOfflineEngine(store: .file(url))
        await again.start()
        #expect(await again.core.appRequests().map(\.id) == [card.id])
        await again.stop()
    }

    @Test func migrationMovesExistingAppRequestsOutOfTheCache() async throws {
        let url = temporaryStore()
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let card = Self.appCard()
        let encoder = JSONEncoder()
        do {
            // A database as the previous release left it: migrated to v6, the app card in `pending_request`.
            let pool = try DatabasePool(path: url.path)
            try ProjectionSchema.migrator.migrate(pool, upTo: "v6-container-environments")
            let json = try encoder.encode(PendingRequest.app(card))
            try await pool.write { db in
                try db.execute(
                    sql: "INSERT INTO pending_request (id, session_id, kind, received, json) VALUES (?, ?, 'question', ?, ?)",
                    arguments: [card.id, card.sessionID.rawValue, card.received.milliseconds, json])
            }
            try pool.close()
        }
        let store = try await ProjectionStore.open(location: .file(url))
        #expect(try await store.appliedMigrations().contains("v7-app-requests"))
        #expect(try await store.pendingRequests().map(\.id) == [card.id])
        try await store.rebuild()
        #expect(try await store.pendingRequests().map(\.id) == [card.id], "moved out of the rebuildable cache")
    }
}
