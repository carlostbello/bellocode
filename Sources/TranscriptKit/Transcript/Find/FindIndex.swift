import Foundation

/// A match of the find query: row, block, UTF-16 range in the block's full (expanded) text.
public struct FindMatch: Hashable, Sendable {
    public var rowID: RowID
    public var block: Int
    public var range: Range<Int>

    public init(rowID: RowID, block: Int, range: Range<Int>) {
        self.rowID = rowID
        self.block = block
        self.range = range
    }
}

/// The searchable text of one row: every block's full text, including collapsed ones (find reveals them). One string
/// per block: the case- and diacritic-folded text when folding kept every UTF-16 offset (searched literally, fast),
/// else the original (searched with folding options). Keeping both doubled the index.
public struct FindIndexEntry: Sendable {
    public var rowID: RowID
    public var version: Int
    public var texts: [String]
    /// Per block: `texts[i]` is folded.
    public var folded: [Bool]

    public init(rowID: RowID, version: Int, blocks: [String]) {
        self.rowID = rowID
        self.version = version
        var texts: [String] = []
        var folded: [Bool] = []
        texts.reserveCapacity(blocks.count)
        folded.reserveCapacity(blocks.count)
        for text in blocks {
            let fold = FindSearch.fold(text)
            let keeps = fold.utf16.count == text.utf16.count
            texts.append(keeps ? fold : text)
            folded.append(keeps)
        }
        self.texts = texts
        self.folded = folded
    }

    /// UTF-16 units held (cache report).
    public var utf16Count: Int { texts.reduce(0) { $0 + $1.utf16.count } }
}

public enum FindSearch {
    /// Bound on matches collected (the bar then shows "10,000+").
    public static let matchLimit = 10_000

    /// All matches of `query` in `entries`, in document order. Case- and diacritic-insensitive. Stops early when the
    /// task is cancelled.
    @concurrent
    public static func search(_ entries: [FindIndexEntry], query: String) async -> [FindMatch] {
        matches(entries, query: query)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    public static func matches(_ entries: [FindIndexEntry], query: String) -> [FindMatch] {
        guard !query.isEmpty else { return [] }
        var result: [FindMatch] = []
        let foldedQuery = fold(query)
        let slow: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        for (index, entry) in entries.enumerated() {
            if index & 0xFF == 0, Task.isCancelled { return result }
            for (block, text) in entry.texts.enumerated() {
                // Folded text is searched literally (fast); offsets equal the original's.
                let folded = block < entry.folded.count && entry.folded[block]
                let options: NSString.CompareOptions = folded ? .literal : slow
                let query = folded ? foldedQuery : query
                let ns = text as NSString
                var from = 0
                while from < ns.length {
                    let found = ns.range(of: query, options: options, range: NSRange(location: from, length: ns.length - from))
                    guard found.location != NSNotFound, found.length > 0 else { break }
                    result.append(FindMatch(rowID: entry.rowID, block: block, range: found.location..<(found.location + found.length)))
                    if result.count >= matchLimit { return result }
                    from = found.location + found.length
                }
            }
        }
        return result
    }

    /// Index of the first match at or after `position` (wrapping to 0).
    public static func firstIndex(in matches: [FindMatch], atOrAfter position: TranscriptPosition?, rowIndex: (RowID) -> Int?) -> Int {
        guard let position, let row = rowIndex(position.rowID) else { return 0 }
        for (index, match) in matches.enumerated() {
            guard let matchRow = rowIndex(match.rowID) else { continue }
            if matchRow > row || (matchRow == row && (match.block > position.block || (match.block == position.block && match.range.lowerBound >= position.offset))) {
                return index
            }
        }
        return 0
    }
}
