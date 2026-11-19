import Foundation
import GRDB
import SecretKit

// Secret manager tables (migration `v11-secret-manager`, docs/features/secrets.md). App-owned, kept by `rebuild()`.
// None holds a secret value: the value is only ever in the Keychain.

extension ProjectionStore {
    static let secretsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let secretsDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// The most audit rows kept per secret, and in all.
    public static let auditLimitPerSecret = 200
    public static let auditLimitTotal = 2_000

    /// Every secret's metadata row: the readable ones decoded, the rest by account (never dropped, R09: an unreadable
    /// row may hold a revocation, scope or bindings, so its secret is quarantined rather than treated as missing).
    public struct ManagedSecretRows: Sendable {
        public var secrets: [ManagedSecret]
        public var unreadable: [String]
    }

    /// Throws when the table cannot be read (the caller fails closed; an empty list would read as "no metadata").
    public func managedSecretRows() async throws -> ManagedSecretRows {
        let rows = try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT account, json FROM app_managed_secret").map { row -> (String, Data?) in (row["account"], row["json"]) }
        }
        var out = ManagedSecretRows(secrets: [], unreadable: [])
        for (account, data) in rows {
            if let data, let secret = try? Self.secretsDecoder.decode(ManagedSecret.self, from: data), secret.account == account {
                out.secrets.append(secret)
            } else {
                out.unreadable.append(account)
            }
        }
        return out
    }

    public func managedSecrets() async throws -> [ManagedSecret] {
        try await managedSecretRows().secrets
    }

    /// Records a legacy (pre-modes) secret's metadata only when its account has no row at all: never replaces a row,
    /// readable or not. False when a row already existed.
    public func adoptLegacySecret(_ secret: ManagedSecret) async throws -> Bool {
        let data = try Self.secretsEncoder.encode(secret)
        return try await writer.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO app_managed_secret (account, updated, json) VALUES (?, ?, ?)",
                arguments: [secret.account, Date().timeIntervalSince1970, data])
            return db.changesCount > 0
        }
    }

    public func saveManagedSecret(_ secret: ManagedSecret) async throws {
        let data = try Self.secretsEncoder.encode(secret)
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_managed_secret (account, updated, json) VALUES (?, ?, ?)",
                arguments: [secret.account, Date().timeIntervalSince1970, data])
        }
    }

    /// Removes the secret's row, its placeholders and its audit.
    public func deleteManagedSecret(account: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM app_managed_secret WHERE account = ?", arguments: [account])
            try db.execute(sql: "DELETE FROM app_secret_placeholder WHERE account = ?", arguments: [account])
            try db.execute(sql: "DELETE FROM app_secret_audit WHERE account = ?", arguments: [account])
        }
    }

    public func placeholderGrants() async throws -> [PlaceholderGrant] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT placeholder, account, session_id, project, created FROM app_secret_placeholder").map { row in
                PlaceholderGrant(placeholder: row["placeholder"], account: row["account"], sessionID: row["session_id"],
                                 projectDirectory: row["project"], created: Date(timeIntervalSince1970: row["created"]))
            }
        }
    }

    public func savePlaceholderGrant(_ grant: PlaceholderGrant) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_secret_placeholder (placeholder, account, session_id, project, created) VALUES (?, ?, ?, ?, ?)",
                arguments: [grant.placeholder, grant.account, grant.sessionID, grant.projectDirectory, grant.created.timeIntervalSince1970])
        }
    }

    public func deletePlaceholderGrants(account: String) async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM app_secret_placeholder WHERE account = ?", arguments: [account]) }
    }

    public func deletePlaceholderGrants(sessionIDs: [String]) async throws {
        guard !sessionIDs.isEmpty else { return }
        try await writer.write { db in
            for id in sessionIDs { try db.execute(sql: "DELETE FROM app_secret_placeholder WHERE session_id = ?", arguments: [id]) }
        }
    }

    public func auditEntries(account: String? = nil, limit: Int = 50) async throws -> [SecretAuditEntry] {
        let rows = try await writer.read { db in
            if let account {
                return try Data.fetchAll(db, sql: "SELECT json FROM app_secret_audit WHERE account = ? ORDER BY at DESC LIMIT ?", arguments: [account, limit])
            }
            return try Data.fetchAll(db, sql: "SELECT json FROM app_secret_audit ORDER BY at DESC LIMIT ?", arguments: [limit])
        }
        return rows.compactMap { try? Self.secretsDecoder.decode(SecretAuditEntry.self, from: $0) }
    }

    /// Appends entries and trims to the per-secret and total limits (oldest first).
    public func appendAudit(_ entries: [SecretAuditEntry]) async throws {
        guard !entries.isEmpty else { return }
        let encoded = try entries.map { ($0, try Self.secretsEncoder.encode($0)) }
        try await writer.write { db in
            for (entry, data) in encoded {
                try db.execute(sql: "INSERT OR REPLACE INTO app_secret_audit (id, account, at, json) VALUES (?, ?, ?, ?)",
                               arguments: [entry.id, entry.account, entry.at.timeIntervalSince1970, data])
            }
            for account in Set(entries.map(\.account)) {
                try db.execute(sql: """
                    DELETE FROM app_secret_audit WHERE account = ? AND id NOT IN
                    (SELECT id FROM app_secret_audit WHERE account = ? ORDER BY at DESC LIMIT ?)
                    """, arguments: [account, account, Self.auditLimitPerSecret])
            }
            try db.execute(sql: """
                DELETE FROM app_secret_audit WHERE id NOT IN (SELECT id FROM app_secret_audit ORDER BY at DESC LIMIT ?)
                """, arguments: [Self.auditLimitTotal])
        }
    }
}
