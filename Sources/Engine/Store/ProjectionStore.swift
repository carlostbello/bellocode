import BelloCore
import Foundation
import GRDB

/// A set of writes applied in one transaction.
public struct StoreBatch: Sendable {
    public var projects: [Project] = []
    /// Projects not in `projects` are deleted (a complete project list from the server).
    public var replaceAllProjects = false
    public var sessions: [Session] = []
    /// Removes the session with its messages, parts, pending requests, queue and sync state (UI state is kept).
    public var removedSessions: [SessionID] = []
    public var messages: [Message] = []
    public var removedMessages: [MessageID] = []
    /// Drops cached messages of a session that sort before the key: history that is no longer known to be contiguous.
    public var truncatedHistory: [SessionID: MessageSortKey] = [:]
    public var pending: [PendingRequest] = []
    public var resolvedRequests: [String] = []
    /// Pending requests not in `pending` are deleted (a complete list from the server).
    public var replaceAllPending = false
    public var queue: [QueuedPrompt] = []
    public var removedQueue: [MessageID] = []
    /// For these sessions, queue items not in `queue` are deleted.
    public var replaceQueue: Set<SessionID> = []
    public var catalogs: [Catalog] = []
    public var registry: [ProjectEntry] = []
    public var removedRegistry: [String] = []
    public var threadUI: [ThreadUIState] = []
    public var syncStates: [SessionSyncState] = []

    public init() {}

    public var isEmpty: Bool {
        projects.isEmpty && !replaceAllProjects && sessions.isEmpty && removedSessions.isEmpty && messages.isEmpty
            && removedMessages.isEmpty && truncatedHistory.isEmpty && pending.isEmpty && resolvedRequests.isEmpty
            && !replaceAllPending && queue.isEmpty && removedQueue.isEmpty && replaceQueue.isEmpty
            && catalogs.isEmpty && registry.isEmpty && removedRegistry.isEmpty && threadUI.isEmpty
            && syncStates.isEmpty
    }

    /// Folds `other` (newer) into this batch. Later writes to the same row replace earlier ones, so a batch holds at most
    /// one write per row (it is bounded by the number of distinct rows, however long writes are deferred), and a later
    /// removal cancels earlier writes of that row and of what it owns. Applying the merged batch leaves the database as
    /// applying both in order would.
    public mutating func merge(_ other: StoreBatch) {
        if other.replaceAllProjects {
            projects = other.projects
            replaceAllProjects = true
        } else {
            projects = Self.upserting(projects, other.projects, by: \.id)
        }

        let removedSessionIDs = Set(other.removedSessions)
        if !removedSessionIDs.isEmpty {
            sessions.removeAll { removedSessionIDs.contains($0.id) }
            messages.removeAll { removedSessionIDs.contains($0.sessionID) }
            pending.removeAll { removedSessionIDs.contains($0.sessionID) }
            queue.removeAll { removedSessionIDs.contains($0.sessionID) }
            syncStates.removeAll { removedSessionIDs.contains($0.sessionID) }
            truncatedHistory = truncatedHistory.filter { !removedSessionIDs.contains($0.key) }
        }
        removedSessions = Self.unique(removedSessions + other.removedSessions)
        sessions = Self.upserting(sessions, other.sessions, by: \.id)

        // Truncation runs before message upserts: drop earlier writes it would have deleted.
        for (sessionID, key) in other.truncatedHistory {
            messages.removeAll { $0.sessionID == sessionID && $0.sortKey < key }
        }
        truncatedHistory.merge(other.truncatedHistory) { $1 }
        let removedMessageIDs = Set(other.removedMessages)
        if !removedMessageIDs.isEmpty { messages.removeAll { removedMessageIDs.contains($0.id) } }
        removedMessages = Self.unique(removedMessages + other.removedMessages)
        messages = Self.upserting(messages, other.messages, by: \.id)

        if other.replaceAllPending {
            pending = other.pending
            resolvedRequests = other.resolvedRequests
            replaceAllPending = true
        } else {
            let resolved = Set(other.resolvedRequests)
            if !resolved.isEmpty { pending.removeAll { resolved.contains($0.id) } }
            resolvedRequests = Self.unique(resolvedRequests + other.resolvedRequests)
            pending = Self.upserting(pending, other.pending, by: \.id)
        }

        if !other.replaceQueue.isEmpty { queue.removeAll { other.replaceQueue.contains($0.sessionID) } }
        replaceQueue.formUnion(other.replaceQueue)
        let removedQueueIDs = Set(other.removedQueue)
        if !removedQueueIDs.isEmpty { queue.removeAll { removedQueueIDs.contains($0.id) } }
        removedQueue = Self.unique(removedQueue + other.removedQueue)
        queue = Self.upserting(queue, other.queue, by: \.id)

        catalogs = Self.upserting(catalogs, other.catalogs, by: \.directory)
        let removedDirectories = Set(other.removedRegistry)
        if !removedDirectories.isEmpty { registry.removeAll { removedDirectories.contains($0.directory) } }
        removedRegistry = Self.unique(removedRegistry + other.removedRegistry)
        registry = Self.upserting(registry, other.registry, by: \.directory)
        threadUI = Self.upserting(threadUI, other.threadUI, by: \.sessionID)
        syncStates = Self.upserting(syncStates, other.syncStates, by: \.sessionID)
    }

    /// The rows only BelloCode owns (projects added, drafts and per-thread state): never dropped on a write failure.
    var appOwned: StoreBatch {
        var batch = StoreBatch()
        batch.registry = registry
        batch.removedRegistry = removedRegistry
        batch.threadUI = threadUI
        return batch
    }

    /// Everything else: a cache of opencode state that a resync can rebuild.
    var cacheOnly: StoreBatch {
        var batch = self
        batch.registry = []
        batch.removedRegistry = []
        batch.threadUI = []
        return batch
    }

    /// Rows written (for bounds and diagnostics).
    var rowCount: Int {
        projects.count + sessions.count + removedSessions.count + messages.count + removedMessages.count
            + truncatedHistory.count + pending.count + resolvedRequests.count + queue.count + removedQueue.count
            + catalogs.count + registry.count + removedRegistry.count + threadUI.count + syncStates.count
    }

    /// `existing` with `newer` applied: a row already present is replaced in place, a new one appended.
    private static func upserting<Row, Key: Hashable>(_ existing: [Row], _ newer: [Row], by key: KeyPath<Row, Key>) -> [Row] {
        guard !newer.isEmpty else { return existing }
        var result = existing
        var index: [Key: Int] = [:]
        index.reserveCapacity(result.count + newer.count)
        for (offset, row) in result.enumerated() { index[row[keyPath: key]] = offset }
        for row in newer {
            let id = row[keyPath: key]
            if let offset = index[id] {
                result[offset] = row
            } else {
                index[id] = result.count
                result.append(row)
            }
        }
        return result
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    /// The changes this batch represents, for publishing.
    func changes(sessionProjects: [SessionID: ProjectID]) -> [ProjectionChange] {
        var changes: [ProjectionChange] = []
        changes += projects.map(ProjectionChange.project)
        changes += registry.map(ProjectionChange.registry)
        changes += removedRegistry.map { .registryRemoved(directory: $0) }
        changes += sessions.map(ProjectionChange.session)
        for id in removedSessions {
            if let project = sessionProjects[id] { changes.append(.sessionRemoved(id, projectID: project)) }
        }
        changes += messages.map(ProjectionChange.message)
        changes += truncatedHistory.keys.map(ProjectionChange.threadReset)
        changes += pending.map { .pending($0) }
        changes += queue.map(ProjectionChange.queued)
        changes += threadUI.map(ProjectionChange.threadUI)
        changes += catalogs.map(ProjectionChange.catalog)
        return changes
    }
}

/// How much of a session's server history the cache holds.
public struct SessionSyncState: Hashable, Sendable {
    public var sessionID: SessionID
    /// Cursor for the next older page on the server, if any.
    public var olderCursor: String?
    /// The cache holds the session's complete history.
    public var historyComplete: Bool
    public var synced: Timestamp?

    public init(sessionID: SessionID, olderCursor: String? = nil, historyComplete: Bool = false, synced: Timestamp? = nil) {
        self.sessionID = sessionID
        self.olderCursor = olderCursor
        self.historyComplete = historyComplete
        self.synced = synced
    }
}

/// A contiguous run of a session's messages, oldest first.
public struct MessageWindow: Sendable {
    public var messages: [Message]
    /// The cache holds messages older than the window.
    public var hasOlderCached: Bool
}

public struct SearchHit: Hashable, Sendable {
    public var messageID: MessageID
    public var sessionID: SessionID
    /// A short excerpt around the match, with the match in `[` `]`.
    public var snippet: String
    /// When the message was created.
    public var created: Timestamp = Timestamp(milliseconds: 0)
}

/// The local projection: a rebuildable SQLite cache of opencode state plus BelloCode's own per-project and per-thread
/// state, so every screen opens from disk before the server answers.
///
/// Threading: an actor; every database call is async and runs on GRDB's own queues, never on the main thread.
/// Writes are transactional batches (`apply`). Reads return immutable `Sendable` domain values. Opening (and migrating)
/// is synchronous: create the store off the main actor (`open(location:changes:)`).
///
/// Observation: `changes` routes changes to topic subscribers (`observe`) so a consumer wakes only for its own thread,
/// project or the attention list. `apply` publishes after commit unless told not to (the engine publishes live
/// changes itself, slightly ahead of disk).
///
/// The opencode tables are disposable (`rebuild()` clears them), but the app-owned tables (drafts, projects,
/// preferences) are not. So a database is never deleted: one that is verifiably corrupt (`SQLITE_CORRUPT`,
/// `SQLITE_NOTADB`) or written by a newer schema is moved aside (quarantined, with its WAL) and a new one created
/// (`recovery` says which); any other failure (lock, I/O, permission, a failing migration) throws `OpenError` and leaves
/// the file untouched for a retry. Credentials are never stored.
public actor ProjectionStore {
    public enum Location: Sendable {
        case file(URL)
        case inMemory
    }

    /// What opening had to do to get a usable database.
    public enum Recovery: Sendable, Hashable {
        case none
        /// The file was not a readable database; it was moved to this URL and a new one created.
        case quarantinedCorrupt(URL)
        /// A newer BelloCode wrote the file; it was moved to this URL (for that build) and a new one created.
        case quarantinedNewerSchema(URL)
    }

    /// The database could not be opened for a reason that may pass (locked, I/O, permission, failed migration). The file
    /// was not changed; retry later. The description carries only the SQLite result code or error type, never paths or
    /// content.
    public struct OpenError: Error, Sendable, CustomStringConvertible {
        public var reason: String
        public var description: String { "The local database could not be opened (\(reason)). It was left unchanged." }
    }

    public nonisolated let changes: ChangeBus
    public nonisolated let location: Location
    private let writer: any DatabaseWriter
    public nonisolated let recovery: Recovery
    /// Whether opening found an incompatible or unreadable database and set it aside for a new one.
    public nonisolated var wasRecreated: Bool { recovery != .none }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        return encoder
    }()

    private static let decoder = JSONDecoder()

    public init(location: Location, changes: ChangeBus = ChangeBus()) throws {
        try self.init(location: location, changes: changes, migrator: ProjectionSchema.migrator)
    }

    init(location: Location, changes: ChangeBus, migrator: DatabaseMigrator) throws {
        self.location = location
        self.changes = changes
        let signpost = EngineSignposts.database.beginInterval("open")
        defer { EngineSignposts.database.endInterval("open", signpost) }
        switch location {
        case .inMemory:
            let queue = try DatabaseQueue()
            try migrator.migrate(queue)
            writer = queue
            recovery = .none
        case .file(let url):
            (writer, recovery) = try Self.openFile(url, migrator: migrator)
        }
    }

    /// Opens (and migrates) the store off the caller's actor, so a slow disk or migration never blocks the main thread.
    @concurrent
    public static func open(location: Location, changes: ChangeBus = ChangeBus()) async throws -> ProjectionStore {
        try ProjectionStore(location: location, changes: changes, migrator: ProjectionSchema.migrator)
    }

    @concurrent
    static func open(location: Location, changes: ChangeBus, migrator: DatabaseMigrator) async throws -> ProjectionStore {
        try ProjectionStore(location: location, changes: changes, migrator: migrator)
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "BelloCode.ProjectionStore"
        return configuration
    }

    private enum OpenProblem: Error {
        case corrupt
        case newerSchema
    }

    /// Opens (or creates) the database. Corrupt or newer-schema files are quarantined; anything else throws.
    private static func openFile(_ url: URL, migrator: DatabaseMigrator) throws -> (any DatabaseWriter, Recovery) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw OpenError(reason: "folder: \((error as NSError).domain) \((error as NSError).code)")
        }
        let problem: OpenProblem
        do {
            return (try openAndMigrate(url, migrator: migrator), .none)
        } catch let found as OpenProblem {
            problem = found
        } catch let error as DatabaseError where [.SQLITE_CORRUPT, .SQLITE_NOTADB].contains(error.resultCode) {
            problem = .corrupt
        } catch let error as DatabaseError {
            EngineSignposts.log.error("projection store unavailable: SQLite \(error.resultCode.rawValue, privacy: .public)")
            throw OpenError(reason: "SQLite result \(error.extendedResultCode.rawValue)")
        } catch {
            EngineSignposts.log.error("projection store unavailable: \(String(describing: type(of: error)), privacy: .public)")
            throw OpenError(reason: String(describing: type(of: error)))
        }
        let label = problem == .corrupt ? "corrupt" : "newer"
        let moved: URL
        do {
            moved = try quarantine(url, label: label)
        } catch {
            throw OpenError(reason: "could not move the \(label) database aside")
        }
        EngineSignposts.log.error("projection store \(label, privacy: .public): moved aside, starting a new one")
        do {
            let writer = try openAndMigrate(url, migrator: migrator)
            return (writer, problem == .corrupt ? .quarantinedCorrupt(moved) : .quarantinedNewerSchema(moved))
        } catch {
            throw OpenError(reason: "new database: \(String(describing: type(of: error)))")
        }
    }

    private static func openAndMigrate(_ url: URL, migrator: DatabaseMigrator) throws -> DatabasePool {
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        do {
            if try pool.read({ try migrator.hasBeenSuperseded($0) }) { throw OpenProblem.newerSchema }
            try migrator.migrate(pool)
            return pool
        } catch {
            try? pool.close()
            throw error
        }
    }

    /// Moves the database and its WAL/SHM files to `<name>.<label>-<timestamp>` beside it (the WAL keeps its suffix, so
    /// the moved database still opens with its last writes).
    private static func quarantine(_ url: URL, label: String) throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let target = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).\(label)-\(stamp)")
        let manager = FileManager.default
        try manager.moveItem(at: url, to: target)
        for suffix in ["-wal", "-shm"] where manager.fileExists(atPath: url.path + suffix) {
            try manager.moveItem(atPath: url.path + suffix, toPath: target.path + suffix)
        }
        pruneQuarantine(beside: url, keep: quarantineLimit)
        return target
    }

    /// Quarantined copies kept beside the database (the newest; older ones are removed).
    static let quarantineLimit = 3

    private static func pruneQuarantine(beside url: URL, keep: Int) {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + "."
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        let stamp = { (name: String) -> Int in Int(name.split(separator: "-").last ?? "") ?? 0 }
        let copies = names.filter { name in
            name.hasPrefix(prefix) && !name.hasSuffix("-wal") && !name.hasSuffix("-shm")
                && (name.contains(".corrupt-") || name.contains(".newer-"))
        }.sorted { stamp($0) > stamp($1) }
        for name in copies.dropFirst(keep) {
            for suffix in ["", "-wal", "-shm"] { try? manager.removeItem(at: directory.appending(path: name + suffix)) }
        }
    }

    /// Tests: runs before every write; throwing fails it, suspending holds it (a stalled disk).
    private var writeHook: (@Sendable (StoreBatch) async throws -> Void)?
    func setWriteHook(_ hook: (@Sendable (StoreBatch) async throws -> Void)?) { writeHook = hook }

    /// Subscribes to changes for one topic.
    public nonisolated func observe(_ topic: ChangeTopic) -> ChangeSubscription { changes.subscribe(topic) }

    // MARK: - Writes

    /// Applies `batch` in one transaction, then publishes its changes (unless `publish` is false).
    public func apply(_ batch: StoreBatch, publish: Bool = true) async throws {
        guard !batch.isEmpty else { return }
        if let writeHook { try await writeHook(batch) }
        let signpost = EngineSignposts.database.beginInterval("write", "\(batch.messages.count) messages")
        defer { EngineSignposts.database.endInterval("write", signpost) }
        let encoder = Self.encoder
        let sessionProjects = try await writer.write { db -> [SessionID: ProjectID] in
            var removedProjects: [SessionID: ProjectID] = [:]
            for id in batch.removedSessions {
                if let project = try String.fetchOne(db, sql: "SELECT project_id FROM session WHERE id = ?", arguments: [id.rawValue]) {
                    removedProjects[id] = ProjectID(project)
                }
            }
            try Self.write(batch, db: db, encoder: encoder)
            return removedProjects
        }
        if publish { changes.publish(batch.changes(sessionProjects: sessionProjects)) }
    }

    private static func json(_ value: some Encodable, _ encoder: JSONEncoder) throws -> Data {
        try encoder.encode(value)
    }

    private static func write(_ batch: StoreBatch, db: Database, encoder: JSONEncoder) throws {
        if batch.replaceAllProjects {
            let keep = Set(batch.projects.map(\.id.rawValue))
            let existing = try String.fetchAll(db, sql: "SELECT id FROM project")
            for id in existing where !keep.contains(id) {
                try db.execute(sql: "DELETE FROM project WHERE id = ?", arguments: [id])
            }
        }
        for project in batch.projects {
            try db.execute(
                sql: "INSERT OR REPLACE INTO project (id, directory, json) VALUES (?, ?, ?)",
                arguments: [project.id.rawValue, project.directory, try json(project, encoder)])
        }
        for id in batch.removedSessions { try deleteSession(id, db: db) }
        for session in batch.sessions {
            try db.execute(
                sql: "INSERT OR REPLACE INTO session (id, project_id, parent_id, updated, json) VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    session.id.rawValue, session.projectID.rawValue, session.parentID?.rawValue,
                    session.updated.milliseconds, try json(session, encoder),
                ])
        }
        for (sessionID, key) in batch.truncatedHistory {
            let seqs = try Int64.fetchAll(
                db,
                sql: "SELECT seq FROM message WHERE session_id = ? AND (created < ? OR (created = ? AND id < ?))",
                arguments: [sessionID.rawValue, key.created.milliseconds, key.created.milliseconds, key.id.rawValue])
            for seq in seqs { try deleteMessage(seq: seq, db: db) }
        }
        for id in batch.removedMessages {
            if let seq = try Int64.fetchOne(db, sql: "SELECT seq FROM message WHERE id = ?", arguments: [id.rawValue]) {
                try deleteMessage(seq: seq, db: db)
            }
        }
        for message in batch.messages { try upsert(message, db: db, encoder: encoder) }
        if batch.replaceAllPending {
            let keep = Set(batch.pending.map(\.id))
            for id in try String.fetchAll(db, sql: "SELECT id FROM pending_request") where !keep.contains(id) {
                try db.execute(sql: "DELETE FROM pending_request WHERE id = ?", arguments: [id])
            }
        }
        for id in batch.resolvedRequests {
            try db.execute(sql: "DELETE FROM pending_request WHERE id = ?", arguments: [id])
        }
        for request in batch.pending {
            try db.execute(
                sql: "INSERT OR REPLACE INTO pending_request (id, session_id, kind, received, json) VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    request.id, request.sessionID.rawValue, request.isPermission ? "permission" : "question",
                    request.received.milliseconds, try json(request, encoder),
                ])
        }
        for sessionID in batch.replaceQueue {
            let keep = Set(batch.queue.filter { $0.sessionID == sessionID }.map(\.id.rawValue))
            for id in try String.fetchAll(db, sql: "SELECT id FROM queued_prompt WHERE session_id = ?", arguments: [sessionID.rawValue])
            where !keep.contains(id) {
                try db.execute(sql: "DELETE FROM queued_prompt WHERE id = ?", arguments: [id])
            }
        }
        for id in batch.removedQueue {
            try db.execute(sql: "DELETE FROM queued_prompt WHERE id = ?", arguments: [id.rawValue])
        }
        for prompt in batch.queue {
            try db.execute(
                sql: "INSERT OR REPLACE INTO queued_prompt (id, session_id, created, json) VALUES (?, ?, ?, ?)",
                arguments: [prompt.id.rawValue, prompt.sessionID.rawValue, prompt.created.milliseconds, try json(prompt, encoder)])
        }
        for catalog in batch.catalogs {
            try db.execute(
                sql: "INSERT OR REPLACE INTO catalog (directory, fetched, json) VALUES (?, ?, ?)",
                arguments: [catalog.directory, catalog.fetched.milliseconds, try json(catalog, encoder)])
        }
        for directory in batch.removedRegistry {
            try db.execute(sql: "DELETE FROM app_project WHERE directory = ?", arguments: [directory])
        }
        for entry in batch.registry {
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO app_project (directory, project_id, sort_order, pinned, archived, added)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    entry.directory, entry.projectID?.rawValue, entry.sortOrder, entry.pinned, entry.archived,
                    entry.added.milliseconds,
                ])
        }
        for state in batch.threadUI {
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO app_thread
                    (session_id, draft, visit_watermark, pinned, snoozed_until, settled, scroll_anchor, scroll_offset,
                     sort_key, snoozed_at, settled_at, never_auto_settle, marked_unread)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    state.sessionID.rawValue, state.draft, state.visitWatermark?.milliseconds, state.pinned,
                    state.snoozedUntil?.milliseconds, state.settled, state.scrollAnchor?.rawValue, state.scrollOffset,
                    state.sortKey, state.snoozedAt?.milliseconds, state.settledAt?.milliseconds, state.neverAutoSettle,
                    state.markedUnread,
                ])
        }
        for sync in batch.syncStates {
            try db.execute(
                sql: "INSERT OR REPLACE INTO session_sync (session_id, older_cursor, history_complete, synced) VALUES (?, ?, ?, ?)",
                arguments: [sync.sessionID.rawValue, sync.olderCursor, sync.historyComplete, sync.synced?.milliseconds])
        }
    }

    private static func upsert(_ message: Message, db: Database, encoder: JSONEncoder) throws {
        var header = message
        header.parts = []
        let seq = try Int64.fetchOne(
            db,
            sql: """
                INSERT INTO message (id, session_id, created, kind, revision, json) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET session_id = excluded.session_id, created = excluded.created,
                    kind = excluded.kind, revision = excluded.revision, json = excluded.json
                RETURNING seq
                """,
            arguments: [
                message.id.rawValue, message.sessionID.rawValue, message.created.milliseconds, message.kind.typeName,
                message.revision, try json(header, encoder),
            ])
        try db.execute(sql: "DELETE FROM part WHERE message_id = ?", arguments: [message.id.rawValue])
        for part in message.parts {
            try db.execute(
                sql: "INSERT OR REPLACE INTO part (id, message_id, session_id, idx, json) VALUES (?, ?, ?, ?, ?)",
                arguments: [part.id.rawValue, message.id.rawValue, message.sessionID.rawValue, part.index, try json(part, encoder)])
        }
        guard let seq else { return }
        try db.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [seq])
        let text = message.searchableText
        if !text.isEmpty {
            try db.execute(sql: "INSERT INTO message_fts (rowid, text) VALUES (?, ?)", arguments: [seq, text])
        }
    }

    private static func deleteMessage(seq: Int64, db: Database) throws {
        try db.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [seq])
        try db.execute(sql: "DELETE FROM message WHERE seq = ?", arguments: [seq])
    }

    private static func deleteSession(_ id: SessionID, db: Database) throws {
        let raw = id.rawValue
        try db.execute(
            sql: "DELETE FROM message_fts WHERE rowid IN (SELECT seq FROM message WHERE session_id = ?)", arguments: [raw])
        try db.execute(sql: "DELETE FROM message WHERE session_id = ?", arguments: [raw])
        try db.execute(sql: "DELETE FROM pending_request WHERE session_id = ?", arguments: [raw])
        try db.execute(sql: "DELETE FROM queued_prompt WHERE session_id = ?", arguments: [raw])
        try db.execute(sql: "DELETE FROM session_sync WHERE session_id = ?", arguments: [raw])
        try db.execute(sql: "DELETE FROM session WHERE id = ?", arguments: [raw])
    }

    /// Clears every cache table (BelloCode-owned project registry and thread UI state are kept), then tells every
    /// subscriber to reload. The next sync refills the cache from the server.
    public func rebuild() async throws {
        let signpost = EngineSignposts.database.beginInterval("rebuild")
        defer { EngineSignposts.database.endInterval("rebuild", signpost) }
        try await writer.write { db in
            for table in ProjectionSchema.cacheTables { try db.execute(sql: "DELETE FROM \(table)") }
        }
        changes.publishReloadAll()
    }

    // MARK: - Reads

    private func read<T: Sendable>(_ name: StaticString, _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        let signpost = EngineSignposts.database.beginInterval(name)
        defer { EngineSignposts.database.endInterval(name, signpost) }
        return try await writer.read(body)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    public func projects() async throws -> [Project] {
        try await read("projects") { db in
            try Data.fetchAll(db, sql: "SELECT json FROM project ORDER BY directory").map { try Self.decode(Project.self, $0) }
        }
    }

    public func registry() async throws -> [ProjectEntry] {
        try await read("registry") { db in
            try Row.fetchAll(db, sql: "SELECT * FROM app_project ORDER BY sort_order, directory").map { row in
                ProjectEntry(
                    directory: row["directory"], projectID: (row["project_id"] as String?).map { ProjectID($0) },
                    sortOrder: row["sort_order"], pinned: row["pinned"], archived: row["archived"],
                    added: Timestamp(milliseconds: row["added"]))
            }
        }
    }

    /// Every session (the engine keeps the session index in memory; this is how it is loaded at launch).
    public func allSessions() async throws -> [Session] {
        try await read("allSessions") { db in
            try Data.fetchAll(db, sql: "SELECT json FROM session ORDER BY updated DESC").map { try Self.decode(Session.self, $0) }
        }
    }

    public func sessions(projectID: ProjectID) async throws -> [Session] {
        try await read("sessions") { db in
            try Data.fetchAll(
                db, sql: "SELECT json FROM session WHERE project_id = ? ORDER BY updated DESC", arguments: [projectID.rawValue]
            ).map { try Self.decode(Session.self, $0) }
        }
    }

    public func session(_ id: SessionID) async throws -> Session? {
        try await read("session") { db in
            try Data.fetchOne(db, sql: "SELECT json FROM session WHERE id = ?", arguments: [id.rawValue])
                .map { try Self.decode(Session.self, $0) }
        }
    }

    /// The newest `limit` messages of a session, oldest first: what a thread shows when it opens.
    public func latestMessages(sessionID: SessionID, limit: Int) async throws -> MessageWindow {
        try await read("latestMessages") { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, json FROM message WHERE session_id = ? ORDER BY created DESC, id DESC LIMIT ?",
                arguments: [sessionID.rawValue, limit + 1])
            let hasOlder = rows.count > limit
            let messages = try Self.assemble(Array(rows.prefix(limit)).reversed(), db: db)
            return MessageWindow(messages: messages, hasOlderCached: hasOlder)
        }
    }

    /// Up to `limit` messages older than `key`, oldest first.
    public func messages(sessionID: SessionID, before key: MessageSortKey, limit: Int) async throws -> MessageWindow {
        try await read("olderMessages") { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, json FROM message WHERE session_id = ? AND (created < ? OR (created = ? AND id < ?))
                    ORDER BY created DESC, id DESC LIMIT ?
                    """,
                arguments: [sessionID.rawValue, key.created.milliseconds, key.created.milliseconds, key.id.rawValue, limit + 1])
            let hasOlder = rows.count > limit
            return MessageWindow(messages: try Self.assemble(Array(rows.prefix(limit)).reversed(), db: db), hasOlderCached: hasOlder)
        }
    }

    /// Every cached message of a session, oldest first (tests and diagnostics; threads page instead).
    public func allMessages(sessionID: SessionID) async throws -> [Message] {
        try await read("allMessages") { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, json FROM message WHERE session_id = ? ORDER BY created, id", arguments: [sessionID.rawValue])
            return try Self.assemble(rows, db: db)
        }
    }

    public func messages(ids: [MessageID]) async throws -> [Message] {
        guard !ids.isEmpty else { return [] }
        return try await read("messagesByID") { db in
            var rows: [Row] = []
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ ids[$0..<min($0 + 500, ids.count)] }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                rows += try Row.fetchAll(
                    db, sql: "SELECT id, json FROM message WHERE id IN (\(marks))",
                    arguments: StatementArguments(chunk.map(\.rawValue)))
            }
            return try Self.assemble(rows, db: db)
        }
    }

    /// IDs of cached messages of a session whose sort key lies in `lower...upper`.
    public func messageIDs(sessionID: SessionID, from lower: MessageSortKey, through upper: MessageSortKey) async throws -> [MessageID] {
        try await read("messageIDsInRange") { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM message WHERE session_id = ?
                    AND (created > ? OR (created = ? AND id >= ?)) AND (created < ? OR (created = ? AND id <= ?))
                    """,
                arguments: [
                    sessionID.rawValue, lower.created.milliseconds, lower.created.milliseconds, lower.id.rawValue,
                    upper.created.milliseconds, upper.created.milliseconds, upper.id.rawValue,
                ]
            ).map { MessageID($0) }
        }
    }

    /// Whether the cache holds any message of the session that sorts before `key`.
    public func hasMessages(sessionID: SessionID, before key: MessageSortKey) async throws -> Bool {
        try await read("hasOlder") { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(SELECT 1 FROM message WHERE session_id = ? AND (created < ? OR (created = ? AND id < ?)))
                    """,
                arguments: [sessionID.rawValue, key.created.milliseconds, key.created.milliseconds, key.id.rawValue]) ?? false
        }
    }

    public func messageCount(sessionID: SessionID) async throws -> Int {
        try await read("messageCount") { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE session_id = ?", arguments: [sessionID.rawValue]) ?? 0
        }
    }

    /// Joins message headers with their parts.
    private static func assemble(_ rows: [Row], db: Database) throws -> [Message] {
        guard !rows.isEmpty else { return [] }
        var messages: [Message] = []
        messages.reserveCapacity(rows.count)
        var indexByID: [String: Int] = [:]
        for row in rows {
            let id: String = row["id"]
            indexByID[id] = messages.count
            messages.append(try decode(Message.self, row["json"]))
        }
        let ids = Array(indexByID.keys)
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ ids[$0..<min($0 + 500, ids.count)] }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let partRows = try Row.fetchAll(
                db, sql: "SELECT message_id, json FROM part WHERE message_id IN (\(marks)) ORDER BY message_id, idx",
                arguments: StatementArguments(Array(chunk)))
            for row in partRows {
                let messageID: String = row["message_id"]
                guard let index = indexByID[messageID] else { continue }
                messages[index].parts.append(try decode(Part.self, row["json"]))
            }
        }
        return messages
    }

    public func pendingRequests() async throws -> [PendingRequest] {
        try await read("pending") { db in
            try Data.fetchAll(db, sql: "SELECT json FROM pending_request ORDER BY received").map { try Self.decode(PendingRequest.self, $0) }
        }
    }

    public func queue() async throws -> [QueuedPrompt] {
        try await read("queue") { db in
            try Data.fetchAll(db, sql: "SELECT json FROM queued_prompt ORDER BY created").map { try Self.decode(QueuedPrompt.self, $0) }
        }
    }

    public func catalogs() async throws -> [Catalog] {
        try await read("catalogs") { db in
            try Data.fetchAll(db, sql: "SELECT json FROM catalog ORDER BY fetched DESC").map { try Self.decode(Catalog.self, $0) }
        }
    }

    public func threadUIStates() async throws -> [ThreadUIState] {
        try await read("threadUI") { db in
            try Row.fetchAll(db, sql: "SELECT * FROM app_thread").map { row in
                ThreadUIState(
                    sessionID: SessionID(row["session_id"] as String), draft: row["draft"],
                    visitWatermark: (row["visit_watermark"] as Double?).map(Timestamp.init(milliseconds:)),
                    pinned: row["pinned"], snoozedUntil: (row["snoozed_until"] as Double?).map(Timestamp.init(milliseconds:)),
                    settled: row["settled"], scrollAnchor: (row["scroll_anchor"] as String?).map { MessageID($0) },
                    scrollOffset: row["scroll_offset"], sortKey: row["sort_key"],
                    snoozedAt: (row["snoozed_at"] as Double?).map(Timestamp.init(milliseconds:)),
                    settledAt: (row["settled_at"] as Double?).map(Timestamp.init(milliseconds:)),
                    neverAutoSettle: row["never_auto_settle"], markedUnread: row["marked_unread"])
            }
        }
    }

    public func syncState(_ sessionID: SessionID) async throws -> SessionSyncState? {
        try await read("syncState") { db in
            try Row.fetchOne(db, sql: "SELECT * FROM session_sync WHERE session_id = ?", arguments: [sessionID.rawValue]).map { row in
                SessionSyncState(
                    sessionID: sessionID, olderCursor: row["older_cursor"], historyComplete: row["history_complete"],
                    synced: (row["synced"] as Double?).map(Timestamp.init(milliseconds:)))
            }
        }
    }

    /// Full-text search over user and assistant message text. `query` is matched as words (prefix match on the last).
    public func search(_ query: String, limit: Int = 50, markers: (open: String, close: String) = ("[", "]")) async throws -> [SearchHit] {
        let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return [] }
        let pattern = words.enumerated().map { index, word in
            "\"\(word)\"" + (index == words.count - 1 ? "*" : "")
        }.joined(separator: " ")
        return try await read("search") { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT m.id AS id, m.session_id AS session_id, m.created AS created,
                        snippet(message_fts, 0, ?, ?, '…', 12) AS snippet
                    FROM message_fts JOIN message m ON m.seq = message_fts.rowid
                    WHERE message_fts MATCH ? ORDER BY rank LIMIT ?
                    """,
                arguments: [markers.open, markers.close, pattern, limit]
            ).map { row in
                SearchHit(
                    messageID: MessageID(row["id"] as String), sessionID: SessionID(row["session_id"] as String),
                    snippet: row["snippet"], created: Timestamp(milliseconds: row["created"] as Double? ?? 0))
            }
        }
    }

    // MARK: - App preferences

    /// An app-owned preference (`app_preference`, kept by `rebuild()`), or nil when unset or unreadable.
    public func preference<Value: Decodable & Sendable>(_ key: String, as type: Value.Type) async throws -> Value? {
        let data = try await read("preference") { db in
            try Data.fetchOne(db, sql: "SELECT json FROM app_preference WHERE key = ?", arguments: [key])
        }
        guard let data else { return nil }
        return try? Self.decode(Value.self, data)
    }

    /// Stores an app-owned preference. Never store credentials here.
    public func setPreference(_ key: String, _ value: some Encodable & Sendable) async throws {
        if let writeHook { try await writeHook(StoreBatch()) }
        let data = try Self.json(value, Self.encoder)
        let now = Date().timeIntervalSince1970
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_preference (key, updated, json) VALUES (?, ?, ?)", arguments: [key, now, data])
        }
    }

    // MARK: - Terminals

    /// A thread's terminal set (`app_terminal`, kept by `rebuild()`), or nil when none was saved or it is unreadable.
    public func terminalSet(_ sessionID: SessionID) async throws -> ThreadTerminalSet? {
        let data = try await read("terminals") { db in
            try Data.fetchOne(db, sql: "SELECT json FROM app_terminal WHERE session_id = ?", arguments: [sessionID.rawValue])
        }
        guard let data else { return nil }
        return try? Self.decode(ThreadTerminalSet.self, data)
    }

    /// Saves a thread's terminal set; an empty set deletes the row.
    public func setTerminalSet(_ set: ThreadTerminalSet, for sessionID: SessionID) async throws {
        let data = set.isEmpty ? nil : try Self.json(set, Self.encoder)
        let now = Date().timeIntervalSince1970
        try await writer.write { db in
            if let data {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO app_terminal (session_id, updated, json) VALUES (?, ?, ?)",
                    arguments: [sessionID.rawValue, now, data])
            } else {
                try db.execute(sql: "DELETE FROM app_terminal WHERE session_id = ?", arguments: [sessionID.rawValue])
            }
        }
    }

    /// Sessions with a saved terminal set (diagnostics, idle sweeps).
    public func terminalSessionIDs() async throws -> [SessionID] {
        try await read("terminals") { db in
            try String.fetchAll(db, sql: "SELECT session_id FROM app_terminal ORDER BY updated DESC").map { SessionID($0) }
        }
    }

    /// Applied migration identifiers (tests, diagnostics).
    public func appliedMigrations() async throws -> [String] {
        try await read("migrations") { db in try Array(ProjectionSchema.migrator.appliedIdentifiers(db)).sorted() }
    }
}
