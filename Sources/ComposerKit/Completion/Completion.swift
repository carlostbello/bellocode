import Foundation

/// One row in the completion popover. Accepting it inserts `token` as an atomic token.
public struct CompletionItem: Hashable, Sendable, Identifiable {
    /// Stable identity (for example the relative path or command name), so a refresh keeps the selection.
    public var id: String
    public var title: String
    public var subtitle: String?
    /// SF Symbol name.
    public var symbolName: String?
    public var token: ComposerToken

    public init(id: String, title: String, subtitle: String? = nil, symbolName: String? = nil, token: ComposerToken) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.token = token
    }
}

/// A source of completions for one trigger character. Queries run off the main actor and must honour cancellation:
/// the composer cancels a query as soon as the user types again.
public protocol CompletionProvider: Sendable {
    /// `@`, `/`, `$`.
    var trigger: Character { get }
    /// Only offer completions when the trigger is the first non-blank character of the prompt (slash commands).
    var requiresPromptStart: Bool { get }
    /// Section name for VoiceOver, for example "Files".
    var title: String { get }
    /// Results for the text typed after the trigger, best first, already bounded.
    func completions(for query: String) async throws -> [CompletionItem]
}

/// The trigger and the text after it, at the caret.
public struct CompletionQuery: Hashable, Sendable {
    public var trigger: Character
    public var text: String
    /// UTF-16 range of trigger plus query: what accepting replaces.
    public var range: NSRange

    public init(trigger: Character, text: String, range: NSRange) {
        self.trigger = trigger
        self.text = text
        self.range = range
    }
}

public enum CompletionTriggerDetector {
    /// Finds the query that ends at `caret`: a trigger at the prompt start or after whitespace, followed by
    /// non-whitespace up to the caret. Trigger characters elsewhere (`src/a`, `me@x`) are part of the query.
    /// `triggers` maps each trigger to whether it requires the prompt start. Text inside `excluded` (tokens) never
    /// starts a query.
    public static func query(
        in text: NSString, caret: Int, triggers: [Character: Bool], excluded: [NSRange] = [], maxLength: Int = 128
    ) -> CompletionQuery? {
        guard caret <= text.length, !triggers.isEmpty else { return nil }
        var index = caret
        var scanned = 0
        while index > 0, scanned <= maxLength {
            let range = text.rangeOfComposedCharacterSequence(at: index - 1)
            let piece = text.substring(with: range)
            guard let character = piece.first, piece.count == 1 else { return nil }
            if character.isWhitespace { return nil }
            if excluded.contains(where: { NSLocationInRange(range.location, $0) }) { return nil }
            if let needsStart = triggers[character] {
                let before = range.location
                let atBoundary = before == 0 || text.substring(with: text.rangeOfComposedCharacterSequence(at: before - 1))
                    .first?.isWhitespace == true
                let atStart = text.substring(to: before).allSatisfy(\.isWhitespace)
                if atBoundary && (!needsStart || atStart) {
                    let queryRange = NSRange(location: NSMaxRange(range), length: caret - NSMaxRange(range))
                    return CompletionQuery(
                        trigger: character, text: text.substring(with: queryRange),
                        range: NSRange(location: before, length: caret - before)
                    )
                }
            }
            index = range.location
            scanned += 1
        }
        return nil
    }
}

/// Subsequence fuzzy matching with bonuses for segment starts, runs and file-name hits. Pure and allocation-light,
/// for use off the main actor.
public enum FuzzyMatcher {
    /// A score (higher is better) or `nil` when `query` is not a subsequence of `candidate`. Case-insensitive.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let needle = Array(query.lowercased().utf8)
        guard !needle.isEmpty else { return 0 }
        let original = Array(candidate.utf8)
        let hay = Array(candidate.lowercased().utf8)
        guard hay.count == original.count, needle.count <= hay.count else {
            return candidate.lowercased().contains(query.lowercased()) ? 1 : nil
        }
        let nameStart = (hay.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 }) ?? 0
        var score = 0
        var n = 0
        var previousMatch = -2
        for (i, byte) in hay.enumerated() where n < needle.count {
            guard byte == needle[n] else { continue }
            score += 1
            if previousMatch == i - 1 { score += 5 }
            let previous: UInt8? = i > 0 ? original[i - 1] : nil
            if let previous {
                if "/_-. ".utf8.contains(previous) { score += 8 }
                if isLower(previous) && isUpper(original[i]) { score += 6 }
            } else {
                score += 10
            }
            if i >= nameStart { score += 2 }
            previousMatch = i
            n += 1
        }
        guard n == needle.count else { return nil }
        let name = String(decoding: hay[nameStart...], as: UTF8.self)
        let lowered = String(decoding: needle, as: UTF8.self)
        if name.hasPrefix(lowered) { score += 30 } else if name.contains(lowered) { score += 15 }
        score -= hay.count / 8
        return score
    }

    /// Ranks `candidates` by score, then shorter key, then key, then id: a total order, so equal inputs always give
    /// the same list (no flicker between refreshes).
    public static func rank<T>(
        _ query: String, _ candidates: [T], key: (T) -> String, id: (T) -> String, limit: Int
    ) -> [T] {
        var scored: [(T, Int, String)] = []
        for candidate in candidates {
            let text = key(candidate)
            if let value = score(query, text) { scored.append((candidate, value, text)) }
        }
        scored.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            let left = lhs.2.utf8.count
            let right = rhs.2.utf8.count
            if left != right { return left < right }
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            return id(lhs.0) < id(rhs.0)
        }
        return scored.prefix(limit).map(\.0)
    }

    private static func isLower(_ byte: UInt8) -> Bool { byte >= 97 && byte <= 122 }
    private static func isUpper(_ byte: UInt8) -> Bool { byte >= 65 && byte <= 90 }
}
