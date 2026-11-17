import Foundation

/// Visited pages for address autocomplete. Private tabs never record. Bounded; persisted by the workspace.
public struct BrowserHistory: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public var url: String
        public var title: String
        public var visits: Int
        public var lastVisit: Date
    }

    public static let limit = 500
    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) { self.entries = Array(entries.prefix(Self.limit)) }

    public mutating func record(_ url: URL, title: String, now: Date = Date()) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        let key = url.absoluteString
        if let index = entries.firstIndex(where: { $0.url == key }) {
            var entry = entries.remove(at: index)
            entry.visits += 1
            entry.lastVisit = now
            if !title.isEmpty { entry.title = String(title.prefix(300)) }
            entries.insert(entry, at: 0)
        } else {
            entries.insert(Entry(url: key, title: String(title.prefix(300)), visits: 1, lastVisit: now), at: 0)
            if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        }
    }

    public mutating func updateTitle(_ url: URL, title: String) {
        guard !title.isEmpty, let index = entries.firstIndex(where: { $0.url == url.absoluteString }) else { return }
        entries[index].title = String(title.prefix(300))
    }

    public mutating func clear() { entries.removeAll() }

    /// Suggestions for typed text, best first: URLs whose host-and-path starts with the text, then any whose URL or title
    /// contains it; ties by visits and recency.
    public func suggestions(for typed: String, limit: Int = 8) -> [Entry] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        func stripped(_ url: String) -> String {
            var value = url.lowercased()
            for prefix in ["https://", "http://", "www."] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
            return value
        }
        let scored: [(Entry, Int)] = entries.compactMap { entry in
            let bare = stripped(entry.url)
            if bare.hasPrefix(needle) || entry.url.lowercased().hasPrefix(needle) { return (entry, 2) }
            if bare.contains(needle) || entry.title.lowercased().contains(needle) { return (entry, 1) }
            return nil
        }
        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.visits != rhs.0.visits { return lhs.0.visits > rhs.0.visits }
            return lhs.0.lastVisit > rhs.0.lastVisit
        }.prefix(limit).map(\.0)
    }

    /// The inline completion for typed text: the rest of the best prefix match's host-and-path, or nil.
    public func inlineCompletion(for typed: String) -> String? {
        guard typed.count >= 2, !typed.contains(" ") else { return nil }
        let lower = typed.lowercased()
        for entry in suggestions(for: typed, limit: 20) {
            for candidate in [entry.url, String(entry.url.drop { $0 != "/" }.dropFirst(2))] {
                var value = candidate
                if value.hasPrefix("www."), !lower.hasPrefix("www.") { value.removeFirst(4) }
                if value.lowercased().hasPrefix(lower), value.count > typed.count {
                    var rest = String(value.dropFirst(typed.count))
                    if rest == "/" { rest = "" }
                    return rest.isEmpty ? nil : rest
                }
            }
        }
        return nil
    }
}
