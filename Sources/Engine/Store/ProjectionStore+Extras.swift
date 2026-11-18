import BelloCore
import Foundation
import GRDB

// App-owned tables of the orchestration extras (migration `v5-orchestration-extras`, docs/features/orchestration-extras.md).
// All are kept by `rebuild()`. None holds a secret value.

/// A label of a secret kept in the Keychain (never the value).
public struct StoredSecretLabel: Hashable, Sendable, Identifiable {
    /// The Keychain account (`bcs_…`) under BelloCode's service.
    public var account: String
    public var label: String
    public var created: Date
    public var lastUsed: Date?
    public var id: String { account }

    public init(account: String, label: String, created: Date, lastUsed: Date? = nil) {
        self.account = account
        self.label = label
        self.created = created
        self.lastUsed = lastUsed
    }
}

/// A kind of app-level grant (`app_grant`).
public enum AppGrantKind: String, Sendable {
    /// Agents may create scheduled tasks in this project directory without asking.
    case schedule
    /// HTML visuals may load from this host.
    case network
    /// A saved secret may go to this exact command without asking (scope: `<account>\n<binding digest>`).
    case secretCommand
    /// Agents may babysit merge requests in this project directory without asking.
    case gitlabBabysit
    /// Agents may restart this project's services without asking (scope: the project directory).
    case serviceRestart
}

extension ProjectionStore {
    private static let extrasEncoder = JSONEncoder()
    private static let extrasDecoder = JSONDecoder()

    // MARK: Schedules

    public func schedules() async throws -> [ScheduledTask] {
        let rows = try await writer.read { db in try Data.fetchAll(db, sql: "SELECT json FROM app_schedule ORDER BY id") }
        return rows.compactMap { try? Self.extrasDecoder.decode(ScheduledTask.self, from: $0) }
    }

    public func saveSchedule(_ task: ScheduledTask) async throws {
        let data = try Self.extrasEncoder.encode(task)
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_schedule (id, directory, enabled, next_run, json) VALUES (?, ?, ?, ?, ?)",
                arguments: [task.id, task.directory, task.enabled, task.nextRun?.timeIntervalSince1970, data])
        }
    }

    /// Deletes a task and its runs.
    public func deleteSchedule(_ id: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM app_schedule WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM app_schedule_run WHERE schedule_id = ?", arguments: [id])
        }
    }

    /// Records a run and keeps only the newest `keep` runs of its task (bounded history).
    public func recordScheduleRun(_ run: ScheduleRun, keep: Int = ScheduleRun.historyLimit) async throws {
        let data = try Self.extrasEncoder.encode(run)
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_schedule_run (id, schedule_id, started, json) VALUES (?, ?, ?, ?)",
                arguments: [run.id, run.scheduleID, run.started.timeIntervalSince1970, data])
            try db.execute(
                sql: """
                    DELETE FROM app_schedule_run WHERE schedule_id = ? AND id NOT IN (
                        SELECT id FROM app_schedule_run WHERE schedule_id = ? ORDER BY started DESC LIMIT ?)
                    """,
                arguments: [run.scheduleID, run.scheduleID, keep])
        }
    }

    /// Newest first.
    public func scheduleRuns(_ scheduleID: String, limit: Int = ScheduleRun.historyLimit) async throws -> [ScheduleRun] {
        let rows = try await writer.read { db in
            try Data.fetchAll(
                db, sql: "SELECT json FROM app_schedule_run WHERE schedule_id = ? ORDER BY started DESC LIMIT ?",
                arguments: [scheduleID, limit])
        }
        return rows.compactMap { try? Self.extrasDecoder.decode(ScheduleRun.self, from: $0) }
    }

    // MARK: Grants

    public func grants(_ kind: AppGrantKind) async throws -> Set<String> {
        try await writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT scope FROM app_grant WHERE kind = ?", arguments: [kind.rawValue]))
        }
    }

    public func setGrant(_ kind: AppGrantKind, scope: String, granted: Bool) async throws {
        try await runWriteHook()
        try await writer.write { db in
            if granted {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO app_grant (kind, scope, granted) VALUES (?, ?, ?)",
                    arguments: [kind.rawValue, scope, Date().timeIntervalSince1970])
            } else {
                try db.execute(sql: "DELETE FROM app_grant WHERE kind = ? AND scope = ?", arguments: [kind.rawValue, scope])
            }
        }
    }

    /// Removes every grant of `kind` whose scope starts with `prefix` (a deleted secret's command approvals).
    public func deleteGrants(_ kind: AppGrantKind, scopePrefix prefix: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM app_grant WHERE kind = ? AND substr(scope, 1, ?) = ?", arguments: [kind.rawValue, prefix.utf8.count, prefix])
        }
    }

    // MARK: Merge-request watch state

    public func mergeRequestWatches() async throws -> [MergeRequestWatchRecord] {
        let rows = try await writer.read { db in try Data.fetchAll(db, sql: "SELECT json FROM app_mr_watch") }
        return rows.compactMap { try? Self.extrasDecoder.decode(MergeRequestWatchRecord.self, from: $0) }
    }

    public func saveMergeRequestWatch(_ record: MergeRequestWatchRecord) async throws {
        let data = try Self.extrasEncoder.encode(record)
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_mr_watch (session_id, url, updated, json) VALUES (?, ?, ?, ?)",
                arguments: [record.sessionID.rawValue, record.url, Date().timeIntervalSince1970, data])
        }
    }

    public func deleteMergeRequestWatch(sessionID: SessionID, url: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM app_mr_watch WHERE session_id = ? AND url = ?", arguments: [sessionID.rawValue, url])
        }
    }

    // MARK: Secret labels (never values)

    public func secretLabels() async throws -> [StoredSecretLabel] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT account, label, created, last_used FROM app_secret ORDER BY label COLLATE NOCASE")
                .map { row in
                    StoredSecretLabel(
                        account: row["account"], label: row["label"],
                        created: Date(timeIntervalSince1970: row["created"]),
                        lastUsed: (row["last_used"] as Double?).map(Date.init(timeIntervalSince1970:)))
                }
        }
    }

    public func saveSecretLabel(_ label: StoredSecretLabel) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_secret (account, label, created, last_used) VALUES (?, ?, ?, ?)",
                arguments: [
                    label.account, label.label, label.created.timeIntervalSince1970, label.lastUsed?.timeIntervalSince1970,
                ])
        }
    }

    public func deleteSecretLabel(account: String) async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM app_secret WHERE account = ?", arguments: [account]) }
    }
}
