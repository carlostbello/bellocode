import BelloCore
import Foundation
import GRDB

// App-owned outbox of sends whose delivery is not yet settled (migration `v8-app-outbox`, deep review 1, C6). Written
// before a prompt is first dispatched and removed once opencode admits it or definitively refuses it, so a send whose
// answers were lost survives a quit: the next launch asks opencode for the original ID before offering a same-ID retry.
// Kept by `rebuild()`. Holds the prompt text and attachment references (file URLs), never file contents.

/// One unsettled send.
public struct OutboxEntry: Codable, Sendable, Hashable, Identifiable {
    public enum State: Codable, Sendable, Hashable {
        /// Written before the first dispatch; no answer yet. After a relaunch it is treated as delivery unknown.
        case dispatching
        /// Every answer was lost and opencode could not be asked.
        case unknown
        /// opencode answered and does not have it (kept until the person edits or discards it).
        case notSent(String)
    }

    /// The prompt ID (opencode's user message ID once delivered).
    public var id: MessageID
    public var sessionID: SessionID
    public var text: String
    public var attachments: PromptAttachments
    public var delivery: PromptDelivery?
    /// It was a follow-up for a running turn (sent with an inbox delivery).
    public var isFollowUp: Bool
    public var state: State
    public var created: Timestamp

    public init(
        id: MessageID, sessionID: SessionID, text: String, attachments: PromptAttachments, delivery: PromptDelivery?,
        isFollowUp: Bool, state: State, created: Timestamp
    ) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.attachments = attachments
        self.delivery = delivery
        self.isFollowUp = isFollowUp
        self.state = state
        self.created = created
    }

    /// Local attachment files the send still needs (kept by the attachment store until the entry settles).
    public var attachmentFiles: [URL] {
        attachments.files.compactMap { URL(string: $0.uri) }.filter(\.isFileURL)
    }
}

extension ProjectionStore {
    private static let outboxEncoder = JSONEncoder()
    private static let outboxDecoder = JSONDecoder()

    /// Oldest first. An entry that cannot be decoded is skipped (and logged), never fatal.
    public func outbox() async throws -> [OutboxEntry] {
        let rows = try await writer.read { db in try Data.fetchAll(db, sql: "SELECT json FROM app_outbox ORDER BY created, id") }
        return rows.compactMap { data in
            do { return try Self.outboxDecoder.decode(OutboxEntry.self, from: data) } catch {
                EngineSignposts.log.error("outbox entry unreadable: \(String(describing: type(of: error)), privacy: .public)")
                return nil
            }
        }
    }

    public func saveOutbox(_ entry: OutboxEntry) async throws {
        let data = try Self.outboxEncoder.encode(entry)
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_outbox (id, session_id, created, json) VALUES (?, ?, ?, ?)",
                arguments: [entry.id.rawValue, entry.sessionID.rawValue, entry.created.milliseconds, data])
        }
    }

    public func deleteOutbox(_ id: MessageID) async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM app_outbox WHERE id = ?", arguments: [id.rawValue]) }
    }
}
