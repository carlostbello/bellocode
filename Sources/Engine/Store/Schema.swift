import Foundation
import GRDB

/// The projection database schema. Migrations are append-only and named; never edit one that has shipped.
///
/// Tables holding a cache of opencode state (rebuildable from the server): `project`, `session`, `message`, `part`,
/// `message_fts`, `pending_request`, `queued_prompt`, `catalog`, `session_sync`.
/// Tables holding state only BelloCode owns (kept by `rebuild()`): `app_project`, `app_thread`.
///
/// Rows store the domain value as JSON (`json`) plus the columns queries filter and sort on. Credentials are never
/// stored: catalog entries are built from DTOs that do not decode secret-bearing fields.
enum ProjectionSchema {
    /// Increase only together with a new migration. Recorded for diagnostics.
    static let currentVersion = 1

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-initial") { db in
            try db.execute(sql: """
                CREATE TABLE project (
                    id TEXT PRIMARY KEY NOT NULL,
                    directory TEXT NOT NULL,
                    json BLOB NOT NULL
                );
                CREATE TABLE session (
                    id TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL,
                    parent_id TEXT,
                    updated REAL NOT NULL,
                    json BLOB NOT NULL
                );
                CREATE INDEX session_by_project ON session(project_id, updated DESC);
                CREATE INDEX session_by_parent ON session(parent_id);
                CREATE TABLE message (
                    seq INTEGER PRIMARY KEY,
                    id TEXT NOT NULL UNIQUE,
                    session_id TEXT NOT NULL,
                    created REAL NOT NULL,
                    kind TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    json BLOB NOT NULL
                );
                CREATE INDEX message_by_session ON message(session_id, created, id);
                CREATE TABLE part (
                    id TEXT PRIMARY KEY NOT NULL,
                    message_id TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                    session_id TEXT NOT NULL,
                    idx INTEGER NOT NULL,
                    json BLOB NOT NULL
                );
                CREATE INDEX part_by_message ON part(message_id, idx);
                -- rowid = message.seq
                CREATE VIRTUAL TABLE message_fts USING fts5(text, tokenize = 'unicode61');
                CREATE TABLE pending_request (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    received REAL NOT NULL,
                    json BLOB NOT NULL
                );
                CREATE INDEX pending_by_session ON pending_request(session_id);
                CREATE TABLE queued_prompt (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL,
                    created REAL NOT NULL,
                    json BLOB NOT NULL
                );
                CREATE INDEX queue_by_session ON queued_prompt(session_id, created);
                CREATE TABLE catalog (
                    directory TEXT PRIMARY KEY NOT NULL,
                    fetched REAL NOT NULL,
                    json BLOB NOT NULL
                );
                CREATE TABLE session_sync (
                    session_id TEXT PRIMARY KEY NOT NULL,
                    older_cursor TEXT,
                    history_complete INTEGER NOT NULL DEFAULT 0,
                    synced REAL
                );
                CREATE TABLE app_project (
                    directory TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT,
                    sort_order INTEGER NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    archived INTEGER NOT NULL DEFAULT 0,
                    added REAL NOT NULL
                );
                CREATE TABLE app_thread (
                    session_id TEXT PRIMARY KEY NOT NULL,
                    draft TEXT NOT NULL DEFAULT '',
                    visit_watermark REAL,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    snoozed_until REAL,
                    settled INTEGER NOT NULL DEFAULT 0,
                    scroll_anchor TEXT,
                    scroll_offset REAL NOT NULL DEFAULT 0
                );
                """)
        }
        return migrator
    }

    /// Cache tables, cleared by `rebuild()`.
    static let cacheTables = [
        "part", "message", "message_fts", "pending_request", "queued_prompt", "catalog", "session_sync", "session",
        "project",
    ]
}
