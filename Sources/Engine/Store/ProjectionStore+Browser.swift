import Foundation
import GRDB

// Shared browser tables (migration `v13-shared-browser`, docs/features/shared-browser.md). App-owned, kept by
// `rebuild()`. No URLs, titles, cookies or page content: thread → group bindings, deliberate shares, project labels.

extension ProjectionStore {
    static let browserEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let browserDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// Bindings kept (oldest dropped beyond this; a dropped thread simply gets a new group on its next call).
    public static let browserBindingLimit = 500

    public func browserBindings() async throws -> [BrowserBinding] {
        let rows = try await writer.read { db in try Data.fetchAll(db, sql: "SELECT json FROM app_browser_binding") }
        return rows.compactMap { try? Self.browserDecoder.decode(BrowserBinding.self, from: $0) }
    }

    public func saveBrowserBinding(_ binding: BrowserBinding) async throws {
        let data = try Self.browserEncoder.encode(binding)
        let limit = Self.browserBindingLimit
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_browser_binding (session_id, group_slug, project, updated, json) VALUES (?, ?, ?, ?, ?)",
                arguments: [binding.sessionID, binding.group, binding.project, Date().timeIntervalSince1970, data])
            try db.execute(
                sql: "DELETE FROM app_browser_binding WHERE session_id NOT IN (SELECT session_id FROM app_browser_binding ORDER BY updated DESC LIMIT ?)",
                arguments: [limit])
        }
    }

    public func deleteBrowserBindings(sessionIDs: [String]) async throws {
        guard !sessionIDs.isEmpty else { return }
        try await writer.write { db in
            for id in sessionIDs {
                try db.execute(sql: "DELETE FROM app_browser_binding WHERE session_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM app_browser_share WHERE owner_session = ? OR grantee_session = ?", arguments: [id, id])
            }
        }
    }

    public func browserShares() async throws -> [BrowserShare] {
        let rows = try await writer.read { db in try Data.fetchAll(db, sql: "SELECT json FROM app_browser_share ORDER BY created") }
        return rows.compactMap { try? Self.browserDecoder.decode(BrowserShare.self, from: $0) }
    }

    public func saveBrowserShare(_ share: BrowserShare) async throws {
        let data = try Self.browserEncoder.encode(share)
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_browser_share (id, owner_session, grantee_session, tab, created, json) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [share.id, share.ownerSession, share.granteeSession, share.tab, share.created.timeIntervalSince1970, data])
        }
    }

    public func deleteBrowserShare(id: String) async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM app_browser_share WHERE id = ?", arguments: [id]) }
    }

    public func browserLabels() async throws -> [String: String] {
        try await writer.read { db in
            Dictionary(try Row.fetchAll(db, sql: "SELECT project, label FROM app_browser_label").map { ($0["project"] as String, $0["label"] as String) },
                       uniquingKeysWith: { a, _ in a })
        }
    }

    /// Stores a project's label; false when another project already holds it (the caller picks another).
    @discardableResult
    public func saveBrowserLabel(project: String, label: String) async throws -> Bool {
        try await writer.write { db in
            if let holder = try String.fetchOne(db, sql: "SELECT project FROM app_browser_label WHERE label = ?", arguments: [label]), holder != project {
                return false
            }
            try db.execute(sql: "INSERT OR REPLACE INTO app_browser_label (project, label) VALUES (?, ?)", arguments: [project, label])
            return true
        }
    }
}
