import BelloCore
import Foundation
import GRDB

// App-owned GitLab tables (migration `v9-gitlab`, docs/features/gitlab.md). None holds a token.

extension ProjectionStore {
    private static let gitLabEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let gitLabDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    /// Snapshots kept (oldest fetched dropped beyond this).
    public static let mergeRequestSnapshotLimit = 200
    /// Wake-log rows kept per thread and merge request.
    public static let mergeRequestWakeLogLimit = 50

    // MARK: Instances

    public func gitLabInstanceStatuses() async throws -> [String: GitLabInstanceStatus] {
        let rows: [(String, Data)] = try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT base_url, json FROM app_gitlab_instance").map { ($0["base_url"], $0["json"]) }
        }
        var result: [String: GitLabInstanceStatus] = [:]
        for (base, data) in rows {
            if let status = try? Self.gitLabDecoder.decode(GitLabInstanceStatus.self, from: data) { result[base] = status }
        }
        return result
    }

    public func saveGitLabInstanceStatus(_ baseURL: String, _ status: GitLabInstanceStatus) async throws {
        let data = try Self.gitLabEncoder.encode(status)
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_gitlab_instance (base_url, checked, json) VALUES (?, ?, ?)",
                arguments: [baseURL, (status.checked ?? Date()).timeIntervalSince1970, data])
        }
    }

    public func deleteGitLabInstanceStatus(_ baseURL: String) async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM app_gitlab_instance WHERE base_url = ?", arguments: [baseURL]) }
    }

    // MARK: Snapshots (cached-first panel and chips)

    public func mergeRequestSnapshots() async throws -> [MergeRequestSnapshot] {
        let rows = try await writer.read { db in try Data.fetchAll(db, sql: "SELECT json FROM app_mr_snapshot ORDER BY fetched DESC LIMIT ?", arguments: [Self.mergeRequestSnapshotLimit]) }
        return rows.compactMap { try? Self.gitLabDecoder.decode(MergeRequestSnapshot.self, from: $0) }
    }

    public func saveMergeRequestSnapshot(_ snapshot: MergeRequestSnapshot) async throws {
        let data = try Self.gitLabEncoder.encode(snapshot)
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_mr_snapshot (url, fetched, json) VALUES (?, ?, ?)",
                arguments: [snapshot.ref.url, snapshot.fetched.timeIntervalSince1970, data])
            try db.execute(
                sql: "DELETE FROM app_mr_snapshot WHERE url NOT IN (SELECT url FROM app_mr_snapshot ORDER BY fetched DESC LIMIT ?)",
                arguments: [Self.mergeRequestSnapshotLimit])
        }
    }

    // MARK: Wake log

    public func mergeRequestWakeLog(sessionID: SessionID, url: String, limit: Int = ProjectionStore.mergeRequestWakeLogLimit) async throws -> [MergeRequestWakeLogEntry] {
        let rows = try await writer.read { db in
            try Data.fetchAll(
                db, sql: "SELECT json FROM app_mr_wake WHERE session_id = ? AND url = ? ORDER BY at DESC LIMIT ?",
                arguments: [sessionID.rawValue, url, limit])
        }
        return rows.compactMap { try? Self.gitLabDecoder.decode(MergeRequestWakeLogEntry.self, from: $0) }
    }

    public func appendMergeRequestWake(_ entry: MergeRequestWakeLogEntry) async throws {
        let data = try Self.gitLabEncoder.encode(entry)
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_mr_wake (id, session_id, url, at, json) VALUES (?, ?, ?, ?, ?)",
                arguments: [entry.id, entry.sessionID.rawValue, entry.url, entry.at.timeIntervalSince1970, data])
            try db.execute(
                sql: """
                    DELETE FROM app_mr_wake WHERE session_id = ? AND url = ? AND id NOT IN
                        (SELECT id FROM app_mr_wake WHERE session_id = ? AND url = ? ORDER BY at DESC LIMIT ?)
                    """,
                arguments: [entry.sessionID.rawValue, entry.url, entry.sessionID.rawValue, entry.url, Self.mergeRequestWakeLogLimit])
        }
    }

    public func deleteMergeRequestWakes(sessionID: SessionID) async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM app_mr_wake WHERE session_id = ?", arguments: [sessionID.rawValue]) }
    }

    // MARK: Review drafts (migration `v10-gitlab-review`)

    /// Drafts kept per merge request (oldest dropped beyond this, after the person was told by the review's limit).
    public static let reviewDraftLimit = 200

    public func reviewDrafts(mrURL: String) async throws -> [ReviewDraft] {
        let rows = try await writer.read { db in
            try Data.fetchAll(db, sql: "SELECT json FROM app_review_draft WHERE mr_url = ? ORDER BY created", arguments: [mrURL])
        }
        return rows.compactMap { try? Self.gitLabDecoder.decode(ReviewDraft.self, from: $0) }
    }

    public func saveReviewDraft(_ draft: ReviewDraft) async throws {
        let data = try Self.gitLabEncoder.encode(draft)
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_review_draft (id, mr_url, created, json) VALUES (?, ?, ?, ?)",
                arguments: [draft.id, draft.mrURL, draft.created.timeIntervalSince1970, data])
            try db.execute(
                sql: """
                    DELETE FROM app_review_draft WHERE mr_url = ? AND id NOT IN
                    (SELECT id FROM app_review_draft WHERE mr_url = ? ORDER BY created DESC LIMIT ?)
                    """,
                arguments: [draft.mrURL, draft.mrURL, Self.reviewDraftLimit])
        }
    }

    public func deleteReviewDraft(id: String) async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM app_review_draft WHERE id = ?", arguments: [id]) }
    }
}
