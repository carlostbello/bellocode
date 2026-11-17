import BelloCore
import Foundation
import GRDB
import Testing

@testable import Engine

/// M5 (docs/reviews/M1-review.md): opening the projection store never deletes app-owned state on a transient error.
@Suite("Store open safety", .serialized)
struct StoreOpenSafetyTests {
    static func storeWithDraft(_ url: URL) async throws {
        let store = try ProjectionStore(location: .file(url))
        var batch = StoreBatch()
        batch.threadUI = [ThreadUIState(sessionID: "ses_1", draft: "unsent words")]
        try await store.apply(batch)
    }

    static func draft(_ url: URL) async throws -> String? {
        let store = try ProjectionStore(location: .file(url))
        #expect(!store.wasRecreated)
        return try await store.threadUIStates().first?.draft
    }

    /// An unreadable (permission) file is a transient failure: the open throws and the file is left alone.
    @Test func permissionFailureKeepsTheDatabase() async throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite")
        try await Self.storeWithDraft(url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        #expect(throws: ProjectionStore.OpenError.self) { _ = try ProjectionStore(location: .file(url)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try await Self.draft(url) == "unsent words")
    }

    /// A migration that fails is not corruption: the database (with its draft) is kept for the next launch.
    @Test func failedMigrationKeepsTheDatabase() async throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite")
        try await Self.storeWithDraft(url)
        struct Boom: Error {}
        var failing = ProjectionSchema.migrator
        failing.registerMigration("v3-test-failure") { _ in throw Boom() }
        #expect(throws: ProjectionStore.OpenError.self) {
            _ = try ProjectionStore(location: .file(url), changes: ChangeBus(), migrator: failing)
        }
        #expect(try await Self.draft(url) == "unsent words")
    }

    /// A file that is not a database is quarantined (renamed beside it), never deleted, and a new one is created.
    @Test func corruptFileIsQuarantined() async throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite")
        let garbage = Data(repeating: 0x42, count: 8192)
        try garbage.write(to: url)
        let store = try ProjectionStore(location: .file(url))
        guard case .quarantinedCorrupt(let moved) = store.recovery else {
            Issue.record("expected quarantine, got \(store.recovery)")
            return
        }
        #expect(try Data(contentsOf: moved) == garbage)
        #expect(moved.deletingLastPathComponent().path == directory.path)
        #expect(try await store.allSessions().isEmpty)
    }

    /// A newer schema is quarantined too: a newer build's drafts are kept for it.
    @Test func newerSchemaIsQuarantined() async throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite")
        try await Self.storeWithDraft(url)
        let pool = try DatabasePool(path: url.path)
        try await pool.write { db in try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99-future')") }
        try pool.close()
        let store = try ProjectionStore(location: .file(url))
        guard case .quarantinedNewerSchema(let moved) = store.recovery else {
            Issue.record("expected quarantine, got \(store.recovery)")
            return
        }
        let old = try DatabaseQueue(path: moved.path)
        let draft = try await old.read { try String.fetchOne($0, sql: "SELECT draft FROM app_thread") }
        #expect(draft == "unsent words")
    }
}
