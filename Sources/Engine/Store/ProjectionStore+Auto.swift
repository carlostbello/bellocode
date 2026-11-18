import BelloCore
import Foundation
import GRDB

// Auto audit log (migration `v11-auto-audit`, docs/features/auto-mode.md). App-owned (kept by `rebuild()`), bounded.

extension ProjectionStore {
    /// Rows kept per thread (oldest dropped first) and for how long.
    public static let autoAuditPerThread = 500
    public static let autoAuditRetention: TimeInterval = 30 * 24 * 3600

    private static let auditEncoder = JSONEncoder()
    private static let auditDecoder = JSONDecoder()

    public func appendAutoAudit(_ entries: [AutoAuditEntry]) async throws {
        guard !entries.isEmpty else { return }
        let rows = try entries.map { ($0.id, $0.sessionID.rawValue, $0.at.milliseconds, try Self.auditEncoder.encode($0)) }
        let sessions = Set(entries.map(\.sessionID.rawValue))
        let cutoff = (Date().timeIntervalSince1970 - Self.autoAuditRetention) * 1000
        try await writer.write { db in
            for (id, session, at, json) in rows {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO app_auto_audit (id, session_id, at, json) VALUES (?, ?, ?, ?)",
                    arguments: [id, session, at, json])
            }
            for session in sessions {
                try db.execute(
                    sql: """
                        DELETE FROM app_auto_audit WHERE session_id = ? AND id NOT IN
                        (SELECT id FROM app_auto_audit WHERE session_id = ? ORDER BY at DESC LIMIT ?)
                        """,
                    arguments: [session, session, Self.autoAuditPerThread])
            }
            try db.execute(sql: "DELETE FROM app_auto_audit WHERE at < ?", arguments: [cutoff])
        }
    }

    /// Newest first.
    public func autoAudit(sessionID: SessionID, limit: Int = autoAuditPerThread) async throws -> [AutoAuditEntry] {
        let rows = try await writer.read { db in
            try Data.fetchAll(
                db, sql: "SELECT json FROM app_auto_audit WHERE session_id = ? ORDER BY at DESC LIMIT ?",
                arguments: [sessionID.rawValue, limit])
        }
        return rows.compactMap { try? Self.auditDecoder.decode(AutoAuditEntry.self, from: $0) }
    }

    public func deleteAutoAudit(sessionID: SessionID) async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM app_auto_audit WHERE session_id = ?", arguments: [sessionID.rawValue]) }
    }
}
