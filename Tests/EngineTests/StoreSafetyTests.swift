import BelloCore
import Foundation
import GRDB
import OpenCodeKit
import Synchronization
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

/// Records write attempts; fails or holds them on demand.
actor WriteProbe {
    var attempts = 0
    var inFlight = 0
    var maxInFlight = 0
    var failuresLeft = 0
    var failCacheRows = false
    var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func configure(failures: Int = 0, failCacheRows: Bool = false, hold: Bool = false) {
        failuresLeft = failures
        self.failCacheRows = failCacheRows
        holding = hold
    }

    func release() {
        holding = false
        for continuation in held { continuation.resume() }
        held.removeAll()
    }

    struct Injected: Error {}

    func enter(_ batch: StoreBatch) async throws {
        attempts += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if holding { await withCheckedContinuation { held.append($0) } }
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw Injected()
        }
        if failCacheRows, !batch.cacheOnly.isEmpty { throw Injected() }
    }

    var isHolding: Bool { !held.isEmpty }
}

/// M3 and M8 (docs/reviews/M1-review.md): failed writes are kept and retried; write-behind is one bounded writer.
@Suite("Write-behind safety", .serialized)
@MainActor
struct WriteBehindSafetyTests {
    func engine(_ probe: WriteProbe) async throws -> Engine {
        let engine = try makeOfflineEngine { configuration in
            configuration.writeInterval = .milliseconds(5)
            configuration.writeRetryBackoff = BackoffPolicy(initial: .milliseconds(5), maximum: .milliseconds(20))
        }
        await engine.store.setWriteHook { batch in try await probe.enter(batch) }
        await engine.start()
        return engine
    }

    func storedDraft(_ engine: Engine, _ id: SessionID) async throws -> String? {
        try await engine.store.threadUIStates().first { $0.sessionID == id }?.draft
    }

    @Test func failedWriteIsRetriedAndReportedUntilItSucceeds() async throws {
        let probe = WriteProbe()
        let engine = try await engine(probe)
        let id = SessionID("ses_w")
        // Fail until the failure has been observed (no race with a fast recovery), then let the disk recover.
        await probe.configure(failures: .max)
        await engine.core.updateThreadUI(id) { $0.draft = "keep this" }
        try await waitUntil("failure shown") { engine.root.storage == .writeFailing }
        #expect(engine.storageNotice?.label == "Not saving")
        #expect(try await storedDraft(engine, id) == nil)
        await probe.configure(failures: 0)
        try await waitUntil("recovered") { engine.root.storage == .ok }
        #expect(try await storedDraft(engine, id) == "keep this")
        await engine.stop()
    }

    @Test func stopRetriesAFailingWriteBeforeGivingUp() async throws {
        let probe = WriteProbe()
        let engine = try await engine(probe)
        let id = SessionID("ses_q")
        await probe.configure(hold: true)
        await engine.core.updateThreadUI(id) { $0.draft = "first" }
        // The first write is held; the draft changes again and the held write then fails.
        for _ in 0..<1_000 { if await probe.isHolding { break } else { await Task.yield() } }
        await engine.core.updateThreadUI(id) { $0.draft = "at quit" }
        await probe.configure(failures: 2)
        await probe.release()
        await engine.stop()
        #expect(try await storedDraft(engine, id) == "at quit")
    }

    /// Cache rows that keep failing are dropped (a resync rebuilds them); app-owned rows are kept and written.
    @Test func cacheRowsAreDroppedButAppOwnedRowsAreKept() async throws {
        let probe = WriteProbe()
        let engine = try await engine(probe)
        let id = SessionID("ses_c")
        await probe.configure(failCacheRows: true)
        var reduction = StoreBatch()
        reduction.sessions = [Fixtures.session("ses_cache")]
        await engine.core.enqueueWritesForTesting(reduction)
        await engine.core.updateThreadUI(id) { $0.draft = "mine" }
        let deadline = ContinuousClock.now + .seconds(10)
        while try await storedDraft(engine, id) != "mine", ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(try await storedDraft(engine, id) == "mine")
        try await waitUntil("saving again") { engine.root.storage == .ok }
        let dropped = await engine.core.statistics.cacheWritesDropped
        #expect(dropped == 1)
        #expect(try await engine.store.allSessions().isEmpty)
        await engine.stop()
    }

    /// A stalled disk: one write runs; everything after it coalesces into one pending batch of distinct rows, written
    /// once the disk recovers. No chain of tasks or batches builds up.
    @Test func blockedWriterCoalescesInsteadOfChaining() async throws {
        let probe = WriteProbe()
        let engine = try await engine(probe)
        let id = SessionID("ses_b")
        await probe.configure(hold: true)
        await engine.core.updateThreadUI(id) { $0.draft = "0" }
        for _ in 0..<1_000 { if await probe.isHolding { break } else { await Task.yield() } }
        #expect(await probe.isHolding)
        var flushes: [Task<Void, Never>] = []
        for index in 1...200 {
            await engine.core.updateThreadUI(id) { $0.draft = "\(index)" }
            let core = engine.core
            flushes.append(Task { await core.flushWrites() })
        }
        #expect(await engine.core.pendingWriteRows == 1, "one row per thread, however many updates")
        await probe.release()
        for flush in flushes { await flush.value }
        await engine.flush()
        let attempts = await probe.attempts
        #expect(attempts <= 3, "attempts: \(attempts)")
        #expect(await probe.maxInFlight == 1)
        #expect(try await storedDraft(engine, id) == "200")
        await engine.stop()
    }
}

@Suite("StoreBatch coalescing")
struct StoreBatchCoalescingTests {
    @Test func laterRemovalCancelsEarlierWrites() {
        var batch = StoreBatch()
        batch.sessions = [Fixtures.session("ses_1")]
        batch.messages = [Fixtures.userMessage("msg_1", session: "ses_1", text: "a", at: 1)]
        var removal = StoreBatch()
        removal.removedMessages = ["msg_1"]
        batch.merge(removal)
        #expect(batch.messages.isEmpty)
        var removeSession = StoreBatch()
        removeSession.removedSessions = ["ses_1"]
        batch.merge(removeSession)
        #expect(batch.sessions.isEmpty)
        var again = StoreBatch()
        again.messages = [Fixtures.userMessage("msg_2", session: "ses_1", text: "b", at: 2)]
        again.messages.append(Fixtures.userMessage("msg_2", session: "ses_1", text: "c", at: 2))
        batch.merge(again)
        #expect(batch.messages.count == 1)
        #expect(batch.rowCount == 3)
    }

    @Test func appOwnedRowsSplitFromCache() {
        var batch = StoreBatch()
        batch.sessions = [Fixtures.session("ses_1")]
        batch.threadUI = [ThreadUIState(sessionID: "ses_1", draft: "x")]
        #expect(batch.appOwned.threadUI.count == 1 && batch.appOwned.sessions.isEmpty)
        #expect(batch.cacheOnly.threadUI.isEmpty && batch.cacheOnly.sessions.count == 1)
    }
}

@Suite("Preference write safety", .serialized)
@MainActor
struct PreferenceWriteSafetyTests {
    @Test func failedPreferenceWriteIsReportedAndRetried() async throws {
        let store = try ProjectionStore(location: .inMemory)
        let probe = WriteProbe()
        await store.setWriteHook { batch in try await probe.enter(batch) }
        await probe.configure(failures: .max)
        let model = ModelPreferencesModel(store: store, retryBackoff: BackoffPolicy(initial: .milliseconds(5), maximum: .milliseconds(20)))
        await model.load()
        model.update { $0.favourites = ["opencode/big-pickle"] }
        try await waitUntil("failure shown") { model.saveFailed }
        await probe.configure(failures: 0)
        try await waitUntil("retried") { !model.saveFailed }
        let stored = try await store.preference(ModelPreferencesModel.key, as: ModelPreferences.self)
        #expect(stored?.favourites == ["opencode/big-pickle"])
    }
}

/// m1: opening and migrating runs off the main actor. A migration that can only finish once the main actor signals it
/// would deadlock if it ran there.
@Suite("Store open off main")
@MainActor
struct StoreOpenOffMainTests {
    @Test func slowMigrationDoesNotBlockTheMainActor() async throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite")
        let started = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let signalledByMain = Mutex(false)
        var migrator = ProjectionSchema.migrator
        migrator.registerMigration("v3-test-slow") { _ in
            started.signal()
            // Times out (and records it) if the main actor is the one running this migration.
            let ok = proceed.wait(timeout: .now() + 5) == .success
            signalledByMain.withLock { $0 = ok }
        }
        let opening = Task { @MainActor in
            try await ProjectionStore.open(location: .file(url), changes: ChangeBus(), migrator: migrator)
        }
        // Wait for the migration to start without blocking the main actor's executor.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = started.wait(timeout: .now() + 10)
                continuation.resume()
            }
        }
        // The main actor runs while the migration is in progress.
        proceed.signal()
        let store = try await opening.value
        #expect(signalledByMain.withLock { $0 })
        #expect(try await store.appliedMigrations().last == "v3-test-slow")
    }
}
