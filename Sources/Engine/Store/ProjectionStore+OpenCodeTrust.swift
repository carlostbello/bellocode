import Foundation
import GRDB

// Projects whose repository opencode configuration the person trusts (migration `v14-opencode-trust`,
// docs/features/opencode-config.md). App-owned, kept by `rebuild()`. Directories only.

extension ProjectionStore {
    /// Trusted project directories and when each was trusted.
    public func openCodeTrust() async throws -> [String: Date] {
        try await writer.read { db in
            Dictionary(
                try Row.fetchAll(db, sql: "SELECT directory, trusted_at FROM app_opencode_trust").map {
                    ($0["directory"] as String, Date(timeIntervalSince1970: $0["trusted_at"] as Double))
                },
                uniquingKeysWith: { first, _ in first })
        }
    }

    public func setOpenCodeTrust(directory: String, trusted: Bool, at date: Date = Date()) async throws {
        try await writer.write { db in
            if trusted {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO app_opencode_trust (directory, trusted_at) VALUES (?, ?)",
                    arguments: [directory, date.timeIntervalSince1970])
            } else {
                try db.execute(sql: "DELETE FROM app_opencode_trust WHERE directory = ?", arguments: [directory])
            }
        }
    }
}
