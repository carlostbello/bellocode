import BelloCore
import Foundation

/// One thread's full-text matches, for the global search list (grouped by thread, with project and date).
public struct ThreadSearchGroup: Hashable, Sendable, Identifiable {
    public struct Hit: Hashable, Sendable, Identifiable {
        public var messageID: MessageID
        /// The thread the message is in (a sub-agent's, when it is not the group's).
        public var sessionID: SessionID
        public var snippet: SearchSnippet
        public var created: Timestamp
        public var id: MessageID { messageID }
    }

    /// The top-level thread.
    public var sessionID: SessionID
    public var title: String
    public var projectID: ProjectID?
    public var directory: String
    public var isArchived: Bool
    /// In rank order (best first), at most `hitsPerThread`.
    public var hits: [Hit]
    /// All matches in this thread (the list shows the first few).
    public var totalHits: Int
    public var newest: Timestamp
    public var id: SessionID { sessionID }
}

/// A snippet with its highlighted ranges (character offsets), parsed from the store's markers.
public struct SearchSnippet: Hashable, Sendable {
    public var text: String
    public var highlights: [Range<Int>]

    public init(text: String, highlights: [Range<Int>] = []) {
        self.text = text
        self.highlights = highlights
    }

    /// Parses `open`/`close` markers; collapses whitespace runs (a snippet is one line).
    public init(marked: String, open: Character = MessageSearch.openMarker, close: Character = MessageSearch.closeMarker) {
        var output: [Character] = []
        var highlights: [Range<Int>] = []
        var start: Int?
        var lastWasSpace = false
        for character in marked {
            if character == open { start = output.count; continue }
            if character == close {
                if let begin = start, output.count > begin { highlights.append(begin..<output.count) }
                start = nil
                continue
            }
            if character.isWhitespace {
                if lastWasSpace { continue }
                lastWasSpace = true
                output.append(" ")
            } else {
                lastWasSpace = false
                output.append(character)
            }
        }
        text = String(output)
        self.highlights = highlights
    }
}

/// Maps store hits to thread groups. Pure; tested directly.
public enum MessageSearch {
    /// Private-use markers, so brackets in message text are never mistaken for highlights.
    public static let openMarker: Character = "\u{E000}"
    public static let closeMarker: Character = "\u{E001}"
    public static let hitsPerThread = 3

    /// Groups hits under their top-level thread, keeping the store's rank order for both groups (by best hit) and hits.
    /// Hits in threads the engine does not know (deleted since indexing) are dropped.
    public static func group(_ hits: [SearchHit], sessions: [SessionID: Session]) -> [ThreadSearchGroup] {
        var order: [SessionID] = []
        var groups: [SessionID: ThreadSearchGroup] = [:]
        for hit in hits {
            guard let session = sessions[hit.sessionID] else { continue }
            var top = session
            var depth = 0
            while let parent = top.parentID, let next = sessions[parent], depth < 32 {
                top = next
                depth += 1
            }
            let entry = ThreadSearchGroup.Hit(
                messageID: hit.messageID, sessionID: hit.sessionID, snippet: SearchSnippet(marked: hit.snippet), created: hit.created)
            if var group = groups[top.id] {
                group.totalHits += 1
                if group.hits.count < hitsPerThread { group.hits.append(entry) }
                group.newest = max(group.newest, hit.created)
                groups[top.id] = group
            } else {
                order.append(top.id)
                groups[top.id] = ThreadSearchGroup(
                    sessionID: top.id, title: top.displayTitle, projectID: top.projectID, directory: top.directory,
                    isArchived: top.isArchived, hits: [entry], totalHits: 1, newest: hit.created)
            }
        }
        return order.compactMap { groups[$0] }
    }
}

extension Engine {
    /// Full-text search over cached message text, grouped by top-level thread (best match first).
    public func searchMessages(_ query: String, limit: Int = 200) async throws -> [ThreadSearchGroup] {
        let hits = try await core.search(
            query, limit: limit, markers: (String(MessageSearch.openMarker), String(MessageSearch.closeMarker)))
        let sessions = await core.sessionsByID(Set(hits.map(\.sessionID)))
        return MessageSearch.group(hits, sessions: sessions)
    }
}
