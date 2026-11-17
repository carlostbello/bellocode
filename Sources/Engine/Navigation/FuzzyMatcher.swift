import Foundation

/// A fuzzy match of a query in a candidate: a score (higher is better) and the matched character offsets (for bold
/// highlighting). Pure and allocation-light: it runs for every candidate on every keystroke.
public struct FuzzyMatch: Hashable, Sendable {
    public var score: Double
    /// Offsets in the candidate's `Character`s.
    public var positions: [Int]
}

/// Subsequence matching with the bonuses a command palette needs: a prefix, word starts (after space, `/`, `-`, `_`,
/// `.`, or a lower-to-upper case change), consecutive runs, and short candidates; gaps cost a little. Case-insensitive,
/// diacritic-insensitive. Each query word must match (in any order) for multi-word queries ("fix test" finds
/// "Tests: fix flaky").
public enum FuzzyMatcher {
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        match(PreparedQuery(query), in: Prepared(candidate))
    }

    /// A query split into folded words once per keystroke.
    public struct PreparedQuery: Sendable {
        let words: [[Character]]
        public init(_ query: String) {
            words = query.split(whereSeparator: { $0 == " " }).map { Prepared(String($0)).folded }
        }
        public var isEmpty: Bool { words.isEmpty }
    }

    /// Matches a prepared query against a prepared candidate (the palette prepares both once).
    public static func match(_ query: PreparedQuery, in target: Prepared) -> FuzzyMatch? {
        let words = query.words
        guard !words.isEmpty else { return FuzzyMatch(score: 0, positions: []) }
        if words.count == 1 { return match(words[0], target) }
        var total = 0.0
        var positions = Set<Int>()
        for word in words {
            guard let match = match(word, target) else { return nil }
            total += match.score
            positions.formUnion(match.positions)
        }
        return FuzzyMatch(score: total, positions: positions.sorted())
    }

    /// A candidate prepared once (folded characters and word-start flags) for matching against many queries.
    public struct Prepared: Sendable {
        let folded: [Character]
        let wordStart: [Bool]

        public init(_ text: String) {
            let original = Array(text)
            folded = Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
            var starts = [Bool](repeating: false, count: folded.count)
            // Folding can change the length (rare); then only the first character counts as a word start.
            if folded.count == original.count {
                for index in original.indices {
                    if index == 0 { starts[index] = true; continue }
                    let previous = original[index - 1]
                    let current = original[index]
                    if " /-_.:\\(".contains(previous) || (previous.isLowercase && current.isUppercase)
                        || (!previous.isNumber && current.isNumber)
                    {
                        starts[index] = true
                    }
                }
            } else if !starts.isEmpty {
                starts[0] = true
            }
            wordStart = starts
        }
    }

    static func match(_ query: [Character], _ target: Prepared) -> FuzzyMatch? {
        let text = target.folded
        guard !query.isEmpty else { return FuzzyMatch(score: 0, positions: []) }
        guard query.count <= text.count else { return nil }
        // Try each occurrence of the first character as a start (bounded), keep the best greedy alignment.
        var best: FuzzyMatch?
        var starts = 0
        var index = 0
        while index <= text.count - query.count, starts < 8 {
            if text[index] == query[0] {
                starts += 1
                if let candidate = align(query, target, from: index), candidate.score > (best?.score ?? -.infinity) {
                    best = candidate
                }
            }
            index += 1
        }
        return best
    }

    private static func align(_ query: [Character], _ target: Prepared, from start: Int) -> FuzzyMatch? {
        let text = target.folded
        var positions: [Int] = []
        positions.reserveCapacity(query.count)
        var score = 0.0
        var textIndex = start
        var previous = -2
        for character in query {
            // Prefer the next word start that matches over a mid-word match, when one is near.
            var found = -1
            var scan = textIndex
            var firstAny = -1
            while scan < text.count {
                if text[scan] == character {
                    if firstAny < 0 { firstAny = scan }
                    if scan == previous + 1 || target.wordStart[scan] { found = scan; break }
                    if scan - firstAny > 12 { break }
                }
                scan += 1
            }
            if found < 0 { found = firstAny }
            guard found >= 0 else { return nil }
            var gain = 1.0
            if found == previous + 1 { gain += 5 }
            if target.wordStart[found] { gain += found == 0 ? 10 : 7 }
            if previous >= 0, found > previous + 1 { gain -= min(Double(found - previous - 1) * 0.25, 3) }
            score += gain
            positions.append(found)
            previous = found
            textIndex = found + 1
        }
        // Shorter candidates and earlier matches rank higher.
        score -= Double(text.count) * 0.02
        score -= Double(positions.first ?? 0) * 0.1
        if positions.count == text.count { score += 5 }
        return FuzzyMatch(score: score, positions: positions)
    }
}
