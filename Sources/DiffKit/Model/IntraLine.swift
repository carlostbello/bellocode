import Foundation

/// Word-level highlights inside a changed line pair: the UTF-16 ranges of the removed line and of the added line that
/// differ. Computed lazily for visible pairs, with a bounded cost: long lines, many tokens, or pairs that are mostly
/// different get no word highlights (the whole line is already marked).
public struct IntraLineHighlight: Sendable, Hashable {
    public var removed: [NSRange]
    public var added: [NSRange]

    public static let none = IntraLineHighlight(removed: [], added: [])
    public var isEmpty: Bool { removed.isEmpty && added.isEmpty }
}

public enum IntraLine {
    /// Lines longer than this (UTF-16 units) are not compared.
    public static let maxLineLength = 2_000
    /// Token sequences longer than this are not compared.
    public static let maxTokens = 600
    /// Above this changed share (per side) the pair is treated as a whole-line change.
    public static let maxChangedFraction = 0.6

    /// Tokens: runs of letters/digits/underscore, runs of whitespace, or single other characters (UTF-16 ranges).
    static func tokenize(_ units: [UInt16]) -> [(range: NSRange, hash: Int)] {
        var tokens: [(NSRange, Int)] = []
        var index = 0
        func kind(_ unit: UInt16) -> Int {
            if (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit >= 0x80 { return 0 }
            if unit == 32 || unit == 9 { return 1 }
            return 2
        }
        while index < units.count {
            let start = index
            let k = kind(units[index])
            index += 1
            if k != 2 { while index < units.count, kind(units[index]) == k { index += 1 } }
            var hasher = Hasher()
            for unit in units[start..<index] { hasher.combine(unit) }
            tokens.append((NSRange(location: start, length: index - start), hasher.finalize()))
        }
        return tokens
    }

    public static func highlight(removed: String, added: String) -> IntraLineHighlight {
        let a = Array(removed.utf16)
        let b = Array(added.utf16)
        guard a.count <= maxLineLength, b.count <= maxLineLength, a != b else { return .none }
        let ta = tokenize(a)
        let tb = tokenize(b)
        guard ta.count <= maxTokens, tb.count <= maxTokens, !ta.isEmpty, !tb.isEmpty else { return .none }
        var ids: [Int: Int] = [:]
        func id(_ hash: Int) -> Int {
            if let existing = ids[hash] { return existing }
            ids[hash] = ids.count
            return ids.count - 1
        }
        let changes = LineDiff.changes(ta.map { id($0.hash) }, tb.map { id($0.hash) }, budget: 2_000_000)
        func ranges(_ tokens: [(range: NSRange, hash: Int)], _ flags: [Bool]) -> [NSRange] {
            var result: [NSRange] = []
            for (token, changed) in zip(tokens, flags) where changed {
                if let last = result.last, last.location + last.length == token.range.location {
                    result[result.count - 1].length += token.range.length
                } else {
                    result.append(token.range)
                }
            }
            return result
        }
        let removedRanges = ranges(ta, changes.deleted)
        let addedRanges = ranges(tb, changes.inserted)
        let removedShare = Double(removedRanges.reduce(0) { $0 + $1.length }) / Double(max(1, a.count))
        let addedShare = Double(addedRanges.reduce(0) { $0 + $1.length }) / Double(max(1, b.count))
        if removedShare > maxChangedFraction || addedShare > maxChangedFraction { return .none }
        return IntraLineHighlight(removed: removedRanges, added: addedRanges)
    }
}
