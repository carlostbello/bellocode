import Foundation

/// Subsequence fuzzy matching for pickers: every query character must appear in order. Matches at word starts,
/// consecutive runs and prefixes score higher; long gaps score lower. Case- and diacritic-insensitive.
public enum FuzzyMatcher {
    /// The score of `query` against `candidate`, or nil when it does not match. An empty query matches with 0.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let needle = Array(normalize(query).filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let original = Array(candidate)
        let hay = Array(normalize(candidate))
        guard hay.count == original.count, needle.count <= hay.count else {
            return normalize(candidate).contains(String(needle)) ? 1 : nil
        }
        var best: Int?
        // Try each possible start of the first character, so "gpt" prefers "GPT mini" over "Gemini Pro Turbo".
        for start in hay.indices where hay[start] == needle[0] {
            guard let total = match(needle, hay, original, from: start) else { continue }
            best = max(best ?? Int.min, total)
        }
        guard var total = best else { return nil }
        let flat = String(hay)
        let text = String(needle)
        if flat == text { total += 40 } else if flat.hasPrefix(text) { total += 20 }
        return total
    }

    /// The best score over several fields of one item (name, ID, provider…).
    public static func score(_ query: String, fields: [String]) -> Int? {
        fields.compactMap { score(query, $0) }.max()
    }

    private static func match(_ needle: [Character], _ hay: [Character], _ original: [Character], from start: Int) -> Int? {
        var score = 0
        var index = start
        var previous = -2
        for character in needle {
            while index < hay.count, hay[index] != character { index += 1 }
            guard index < hay.count else { return nil }
            score += 1
            if isWordStart(original, index) { score += 8 }
            if index == previous + 1 { score += 5 } else if previous >= 0 { score -= min(index - previous - 1, 5) }
            previous = index
            index += 1
        }
        return score - min(start, 10)
    }

    private static func isWordStart(_ characters: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        let current = characters[index]
        if " -_/.:(".contains(previous) { return true }
        if previous.isLowercase, current.isUppercase { return true }
        if previous.isLetter, current.isNumber { return true }
        return false
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
