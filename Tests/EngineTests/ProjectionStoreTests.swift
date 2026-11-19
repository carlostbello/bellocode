import BelloCore
import Foundation
import GRDB
import Testing

@testable import Engine

@Suite("ProjectionStore")
struct ProjectionStoreTests {
    @Test func migratesFreshDatabaseAndReopensWithoutRecreating() async throws {
        let directory = Fixtures.temporaryDirectory()
        let url = directory.appending(path: "cache.sqlite")
        do {
            let store = try ProjectionStore(location: .file(url))
            #expect(!store.wasRecreated)
            #expect(try await store.appliedMigrations() == ["v1-initial", "v2-app-preferences", "v3-app-terminals", "v4-thread-organisation", "v5-orchestration-extras", "v6-container-environments", "v7-app-requests", "v8-app-outbox", "v9-gitlab", "v10-gitlab-review", "v11-auto-audit", "v12-secret-manager", "v13-shared-browser", "v14-opencode-trust"].sorted())
            var batch = StoreBatch()
            batch.sessions = [Fixtures.session("ses_1")]
            try await store.apply(batch)
        }
        let reopened = try ProjectionStore(location: .file(url))
        #expect(!reopened.wasRecreated)
        #expect(try await reopened.allSessions().map(\.id) == ["ses_1"])
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func databaseFromNewerSchemaIsRecreatedNotFatal() async throws {
        let directory = Fixtures.temporaryDirectory()
        let url = directory.appending(path: "cache.sqlite")
        do {
            let store = try ProjectionStore(location: .file(url))
            var batch = StoreBatch()
            batch.sessions = [Fixtures.session("ses_1")]
            try await store.apply(batch)
        }
        // Simulate a newer build: a migration this build does not know.
        let pool = try DatabasePool(path: url.path)
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99-future')")
        }
        try pool.close()
        let store = try ProjectionStore(location: .file(url))
        #expect(store.wasRecreated)
        #expect(try await store.allSessions().isEmpty)
        #expect(try await store.appliedMigrations() == ["v1-initial", "v2-app-preferences", "v3-app-terminals", "v4-thread-organisation", "v5-orchestration-extras", "v6-container-environments", "v7-app-requests", "v8-app-outbox", "v9-gitlab", "v10-gitlab-review", "v11-auto-audit", "v12-secret-manager", "v13-shared-browser", "v14-opencode-trust"].sorted())
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func unreadableFileIsRecreated() async throws {
        let directory = Fixtures.temporaryDirectory()
        let url = directory.appending(path: "cache.sqlite")
        try Data(repeating: 0x42, count: 8192).write(to: url)
        let store = try ProjectionStore(location: .file(url))
        #expect(store.wasRecreated)
        #expect(try await store.allSessions().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func messagesRoundTripWithPartsAndPageByTime() async throws {
        let store = try ProjectionStore(location: .inMemory)
        var batch = StoreBatch()
        batch.sessions = [Fixtures.session("ses_1")]
        batch.messages = (0..<25).map { index in
            index % 2 == 0
                ? Fixtures.userMessage(String(format: "msg_%03d", index), session: "ses_1", text: "question \(index)", at: Double(index))
                : Fixtures.assistantMessage(String(format: "msg_%03d", index), session: "ses_1", text: "answer \(index)", at: Double(index))
        }
        try await store.apply(batch)
        let window = try await store.latestMessages(sessionID: "ses_1", limit: 10)
        #expect(window.messages.map(\.id.rawValue) == (15..<25).map { String(format: "msg_%03d", $0) })
        #expect(window.hasOlderCached)
        #expect(window.messages.last == batch.messages.last)
        let older = try await store.messages(sessionID: "ses_1", before: window.messages[0].sortKey, limit: 10)
        #expect(older.messages.map(\.id.rawValue) == (5..<15).map { String(format: "msg_%03d", $0) })
        let oldest = try await store.messages(sessionID: "ses_1", before: older.messages[0].sortKey, limit: 10)
        #expect(oldest.messages.count == 5)
        #expect(!oldest.hasOlderCached)
    }

    @Test func upsertReplacesPartsAndSearchIndex() async throws {
        let store = try ProjectionStore(location: .inMemory)
        var batch = StoreBatch()
        batch.messages = [Fixtures.assistantMessage("msg_1", session: "ses_1", text: "the walrus sings", at: 1)]
        try await store.apply(batch)
        #expect(try await store.search("walrus").map(\.messageID) == ["msg_1"])
        batch.messages = [Fixtures.assistantMessage("msg_1", session: "ses_1", text: "a quiet otter", at: 1)]
        try await store.apply(batch)
        #expect(try await store.search("walrus").isEmpty)
        let hits = try await store.search("ott")
        #expect(hits.map(\.messageID) == ["msg_1"])
        #expect(hits.first?.snippet.contains("[otter]") == true)
        #expect(try await store.messages(ids: ["msg_1"]).first?.parts.count == 1)
        var removal = StoreBatch()
        removal.removedMessages = ["msg_1"]
        try await store.apply(removal)
        #expect(try await store.search("otter").isEmpty)
    }

    @Test func removingSessionCascadesButKeepsUIState() async throws {
        let store = try ProjectionStore(location: .inMemory)
        var batch = StoreBatch()
        batch.sessions = [Fixtures.session("ses_1")]
        batch.messages = [Fixtures.userMessage("msg_1", session: "ses_1", text: "hello", at: 1)]
        batch.pending = [
            .permission(PermissionRequest(id: "per_1", sessionID: "ses_1", action: "edit", resources: ["a"], received: Fixtures.t(1)))
        ]
        batch.queue = [QueuedPrompt(id: "msg_2", sessionID: "ses_1", text: "x", delivery: .queue, created: Fixtures.t(2), state: .queued)]
        batch.threadUI = [ThreadUIState(sessionID: "ses_1", draft: "unsent")]
        try await store.apply(batch)
        var removal = StoreBatch()
        removal.removedSessions = ["ses_1"]
        try await store.apply(removal)
        #expect(try await store.allSessions().isEmpty)
        #expect(try await store.messageCount(sessionID: "ses_1") == 0)
        #expect(try await store.pendingRequests().isEmpty)
        #expect(try await store.queue().isEmpty)
        #expect(try await store.search("hello").isEmpty)
        #expect(try await store.threadUIStates().first?.draft == "unsent")
    }

    @Test func rebuildClearsCacheButKeepsAppState() async throws {
        let store = try ProjectionStore(location: .inMemory)
        var batch = StoreBatch()
        batch.sessions = [Fixtures.session("ses_1")]
        batch.registry = [ProjectEntry(directory: "/tmp/p1", sortOrder: 0, pinned: true, added: Fixtures.t(1))]
        batch.threadUI = [ThreadUIState(sessionID: "ses_1", draft: "keep me")]
        try await store.apply(batch)
        let subscription = store.observe(.thread("ses_1"))
        try await store.rebuild()
        #expect(try await store.allSessions().isEmpty)
        #expect(try await store.registry().first?.pinned == true)
        #expect(try await store.threadUIStates().first?.draft == "keep me")
        #expect(subscription.poll()?.overflowed == true)
    }

    @Test func replaceAllAndTruncateHistory() async throws {
        let store = try ProjectionStore(location: .inMemory)
        var batch = StoreBatch()
        batch.projects = [
            Project(id: "a", directory: "/a", created: Fixtures.t(1), updated: Fixtures.t(1)),
            Project(id: "b", directory: "/b", created: Fixtures.t(1), updated: Fixtures.t(1)),
        ]
        batch.messages = (1...5).map { Fixtures.userMessage("msg_\($0)", session: "ses_1", text: "m\($0)", at: Double($0)) }
        batch.pending = [
            .permission(PermissionRequest(id: "per_1", sessionID: "ses_1", action: "edit", resources: [], received: Fixtures.t(1))),
            .permission(PermissionRequest(id: "per_2", sessionID: "ses_1", action: "edit", resources: [], received: Fixtures.t(1))),
        ]
        try await store.apply(batch)
        var next = StoreBatch()
        next.projects = [batch.projects[1]]
        next.replaceAllProjects = true
        next.pending = [batch.pending[1]]
        next.replaceAllPending = true
        next.truncatedHistory["ses_1"] = MessageSortKey(created: Fixtures.t(3), id: "msg_3")
        try await store.apply(next)
        #expect(try await store.projects().map(\.id) == ["b"])
        #expect(try await store.pendingRequests().map(\.id) == ["per_2"])
        #expect(try await store.allMessages(sessionID: "ses_1").map(\.id) == ["msg_3", "msg_4", "msg_5"])
    }

    @Test func subscribersWakeOnlyForTheirTopic() async throws {
        let store = try ProjectionStore(location: .inMemory)
        let thread1 = store.observe(.thread("ses_1"))
        let thread2 = store.observe(.thread("ses_2"))
        let project1 = store.observe(.sessions("p1"))
        let project2 = store.observe(.sessions("p2"))
        let attention = store.observe(.attention)
        var batch = StoreBatch()
        batch.messages = [Fixtures.userMessage("msg_1", session: "ses_1", text: "hi", at: 1)]
        try await store.apply(batch)
        #expect(thread1.poll()?.messages.keys.contains("msg_1") == true)
        #expect(thread2.poll() == nil)
        #expect(project1.poll() == nil)
        #expect(attention.poll() == nil)
        batch = StoreBatch()
        batch.sessions = [Fixtures.session("ses_3", project: "p2")]
        try await store.apply(batch)
        #expect(project2.poll()?.sessions.keys.contains("ses_3") == true)
        #expect(project1.poll() == nil)
        #expect(thread1.poll() == nil)
    }
}

@Suite("ChangeBus")
struct ChangeBusTests {
    @Test func mergesByIdentityAndKeepsHighestRevision() {
        let bus = ChangeBus()
        let subscription = bus.subscribe(.thread("ses_1"))
        var message = Fixtures.userMessage("msg_1", session: "ses_1", text: "a", at: 1)
        message.revision = 3
        bus.publish([.message(message)])
        var stale = message
        stale.revision = 2
        bus.publish([.message(stale)])
        let batch = subscription.poll()
        #expect(batch?.messages["msg_1"]?.revision == 3)
        #expect(subscription.poll() == nil)
    }

    @Test func overflowBecomesAReloadNotSilentLoss() {
        let bus = ChangeBus(subscriberLimit: 10)
        let subscription = bus.subscribe(.thread("ses_1"))
        bus.publish((0..<50).map { .message(Fixtures.userMessage("msg_\($0)", session: "ses_1", text: "", at: Double($0))) })
        let batch = subscription.poll()
        #expect(batch?.overflowed == true)
        #expect(batch?.messages.isEmpty == true)
    }

    @Test func iteratorWakesAndEndsOnCancel() async {
        let bus = ChangeBus()
        let subscription = bus.subscribe(.attention)
        let reader = Task { () -> Int in
            var count = 0
            for await _ in subscription { count += 1 }
            return count
        }
        try? await Task.sleep(for: .milliseconds(20))
        bus.publish([.attention(.empty)])
        try? await Task.sleep(for: .milliseconds(20))
        subscription.cancel()
        #expect(await reader.value == 1)
        #expect(bus.subscriberCount == 0)
    }
}
