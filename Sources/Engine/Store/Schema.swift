import Foundation
import GRDB

/// The projection database schema. Migrations are append-only and named; never edit one that has shipped.
///
/// Tables holding a cache of opencode state (rebuildable from the server): `project`, `session`, `message`, `part`,
/// `message_fts`, `pending_request`, `queued_prompt`, `catalog`, `session_sync`.
/// Tables holding state only BelloCode owns (kept by `rebuild()`): `app_project`, `app_thread`, `app_preference`,
/// `app_terminal`, `app_schedule`, `app_schedule_run`, `app_grant`, `app_mr_watch`, `app_secret`, `app_environment`,
/// `app_request` (BelloCode's own pending requests: opencode cannot rebuild them).
///
/// Rows store the domain value as JSON (`json`) plus the columns queries filter and sort on. Credentials are never
/// stored: catalog entries are built from DTOs that do not decode secret-bearing fields.
enum ProjectionSchema {
    /// Increase only together with a new migration. Recorded for diagnostics.
    static let currentVersion = 7

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
        // App-owned preferences as JSON values by key (model favourites, recents and hidden models; onboarding state).
        migrator.registerMigration("v2-app-preferences") { db in
            try db.execute(sql: """
                CREATE TABLE app_preference (
                    key TEXT PRIMARY KEY NOT NULL,
                    updated REAL NOT NULL,
                    json BLOB NOT NULL
                );
                """)
        }
        // A thread's terminals (records, exit codes the server forgets, tab order, split, drawer height), one JSON value
        // per session (TerminalService).
        migrator.registerMigration("v3-app-terminals") { db in
            try db.execute(sql: """
                CREATE TABLE app_terminal (
                    session_id TEXT PRIMARY KEY NOT NULL,
                    updated REAL NOT NULL,
                    json BLOB NOT NULL
                );
                """)
        }
        // M2-D: sidebar organisation (docs/features/navigation.md): manual order, when a thread was snoozed or settled
        // (activity after it wakes the thread), the per-thread auto-settle opt-out and "Mark as Unread".
        migrator.registerMigration("v4-thread-organisation") { db in
            try db.execute(sql: """
                ALTER TABLE app_thread ADD COLUMN sort_key REAL;
                ALTER TABLE app_thread ADD COLUMN snoozed_at REAL;
                ALTER TABLE app_thread ADD COLUMN settled_at REAL;
                ALTER TABLE app_thread ADD COLUMN never_auto_settle INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE app_thread ADD COLUMN marked_unread INTEGER NOT NULL DEFAULT 0;
                """)
        }
        // M3-B orchestration extras (docs/features/orchestration-extras.md): scheduled task definitions and their run
        // history (bounded per task), app-level grants (agent schedules per project, network hosts for HTML visuals),
        // merge-request watch state (what each wake already reported), and the labels of secrets kept in the Keychain.
        // `app_secret` never holds a value: only the label, the Keychain account and timestamps.
        migrator.registerMigration("v5-orchestration-extras") { db in
            try db.execute(sql: """
                CREATE TABLE app_schedule (
                    id TEXT PRIMARY KEY NOT NULL,
                    directory TEXT NOT NULL,
                    enabled INTEGER NOT NULL,
                    next_run REAL,
                    json BLOB NOT NULL
                );
                CREATE TABLE app_schedule_run (
                    id TEXT PRIMARY KEY NOT NULL,
                    schedule_id TEXT NOT NULL,
                    started REAL NOT NULL,
                    json BLOB NOT NULL
                );
                CREATE INDEX schedule_run_by_schedule ON app_schedule_run(schedule_id, started DESC);
                CREATE TABLE app_grant (
                    kind TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    granted REAL NOT NULL,
                    PRIMARY KEY (kind, scope)
                );
                CREATE TABLE app_mr_watch (
                    session_id TEXT NOT NULL,
                    url TEXT NOT NULL,
                    updated REAL NOT NULL,
                    json BLOB NOT NULL,
                    PRIMARY KEY (session_id, url)
                );
                CREATE TABLE app_secret (
                    account TEXT PRIMARY KEY NOT NULL,
                    label TEXT NOT NULL UNIQUE,
                    created REAL NOT NULL,
                    last_used REAL
                );
                """)
        }
        // M6-A containerised execution (docs/features/containers.md): each project's Environment setting (image,
        // variables, limits, mounts, network) and what BelloCode last knew about its workspace container (image ID,
        // mount identity, tool inventory). App-owned, kept by `rebuild()`. Registry passwords are never here: they are
        // in the Keychain (`app.bellocode.registry`).
        migrator.registerMigration("v6-container-environments") { db in
            try db.execute(sql: """
                CREATE TABLE app_environment (
                    directory TEXT PRIMARY KEY NOT NULL,
                    updated REAL NOT NULL,
                    json BLOB NOT NULL
                );
                """)
        }
        // Deep review 1, C3: requests only BelloCode creates (secret requests, app approvals; ids `app_…`) leave the
        // rebuildable `pending_request` cache for an app-owned table that `rebuild()`, the cache-write retry and a
        // complete server list never drop. Existing rows move across.
        migrator.registerMigration("v7-app-requests") { db in
            try db.execute(sql: """
                CREATE TABLE app_request (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL,
                    received REAL NOT NULL,
                    json BLOB NOT NULL
                );
                CREATE INDEX app_request_by_session ON app_request(session_id);
                INSERT OR REPLACE INTO app_request (id, session_id, received, json)
                    SELECT id, session_id, received, json FROM pending_request WHERE substr(id, 1, 4) = 'app_';
                DELETE FROM pending_request WHERE substr(id, 1, 4) = 'app_';
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
