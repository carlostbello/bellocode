import Foundation

/// A position in the transcript: row, block within the row, UTF-16 offset in the block's plain text. Survives row
/// reuse, relayout and scrolling because it names the row by its stable ID.
public struct TranscriptPosition: Hashable, Sendable, CustomStringConvertible {
    public var rowID: RowID
    public var block: Int
    public var offset: Int

    public init(rowID: RowID, block: Int, offset: Int) {
        self.rowID = rowID
        self.block = block
        self.offset = offset
    }

    public var description: String { "\(rowID)#\(block):\(offset)" }
}

/// The transcript-level selection: an anchor (where it started) and a focus (where it ends now).
public struct TranscriptSelection: Equatable, Sendable {
    public var anchor: TranscriptPosition
    public var focus: TranscriptPosition

    public init(anchor: TranscriptPosition, focus: TranscriptPosition) {
        self.anchor = anchor
        self.focus = focus
    }

    public var isEmpty: Bool { anchor == focus }

    /// Start and end in document order. `rowIndex` maps a row ID to its current index.
    public func ordered(_ rowIndex: (RowID) -> Int?) -> (start: TranscriptPosition, end: TranscriptPosition)? {
        guard let a = rowIndex(anchor.rowID), let f = rowIndex(focus.rowID) else { return nil }
        let anchorFirst = a != f ? a < f : anchor.block != focus.block ? anchor.block < focus.block : anchor.offset <= focus.offset
        return anchorFirst ? (anchor, focus) : (focus, anchor)
    }

    /// The part of row `row` (an index) the selection covers.
    public func rowSelection(row: Int, rowID: RowID, _ rowIndex: (RowID) -> Int?) -> RowSelection? {
        guard !isEmpty, let (start, end) = ordered(rowIndex), let startRow = rowIndex(start.rowID),
            let endRow = rowIndex(end.rowID), row >= startRow, row <= endRow
        else { return nil }
        var result = RowSelection(start: nil, end: nil)
        if row == startRow { result.start = (start.block, start.offset) }
        if row == endRow { result.end = (end.block, end.offset) }
        return result
    }
}

/// One row as copy sees it: its blocks, which are visible, and its Markdown source when it has one.
public struct CopyRow: Sendable {
    public var id: RowID
    public var blocks: [RenderBlock]
    public var visible: [Bool]
    /// The row's Markdown source (assistant text), for "Copy as Markdown".
    public var markdownSource: String?

    public init(id: RowID, blocks: [RenderBlock], visible: [Bool], markdownSource: String? = nil) {
        self.id = id
        self.blocks = blocks
        self.visible = visible
        self.markdownSource = markdownSource
    }
}

/// Builds the copied text of a selection from the model (not from views), so rows that scrolled away or were never
/// drawn copy correctly. Collapsed blocks are skipped; tables copy as tab-separated rows; code verbatim.
public enum SelectionText {
    /// Plain text of the selection over `rows` (the rows from the start row to the end row, in order).
    public static func plain(_ rows: [CopyRow], start: TranscriptPosition, end: TranscriptPosition) -> String {
        assemble(rows, start: start, end: end, markdown: false)
    }

    /// Markdown: whole selected Markdown rows contribute their source; partial ones their plain text.
    public static func markdown(_ rows: [CopyRow], start: TranscriptPosition, end: TranscriptPosition) -> String {
        assemble(rows, start: start, end: end, markdown: true)
    }

    private static func assemble(_ rows: [CopyRow], start: TranscriptPosition, end: TranscriptPosition, markdown: Bool) -> String {
        var output = ""
        for (index, row) in rows.enumerated() {
            let isFirst = index == 0 && row.id == start.rowID
            let isLast = index == rows.count - 1 && row.id == end.rowID
            let fromStart = !isFirst || (start.block == 0 && start.offset == 0)
            let lastVisible = row.visible.lastIndex(of: true) ?? -1
            let toEnd = !isLast || end.block > lastVisible
                || (end.block == lastVisible && end.offset >= (row.blocks[lastVisible].plainText as NSString).length)
            var rowText = ""
            if markdown, fromStart, toEnd, let source = row.markdownSource {
                rowText = source.trimmingCharacters(in: .newlines)
            } else {
                var previous: RenderBlock?
                for (blockIndex, block) in row.blocks.enumerated() where row.visible[blockIndex] {
                    if isFirst, blockIndex < start.block { continue }
                    if isLast, blockIndex > end.block { continue }
                    let plain = block.plainText as NSString
                    let lo = isFirst && blockIndex == start.block ? min(start.offset, plain.length) : 0
                    let hi = isLast && blockIndex == end.block ? min(end.offset, plain.length) : plain.length
                    guard hi > lo else { continue }
                    if let previous, !rowText.isEmpty { rowText += separator(previous, block) }
                    rowText += plain.substring(with: NSRange(location: lo, length: hi - lo))
                    previous = block
                }
            }
            guard !rowText.isEmpty else { continue }
            if !output.isEmpty { output += "\n\n" }
            output += rowText
        }
        return output
    }

    static func separator(_ previous: RenderBlock, _ next: RenderBlock) -> String {
        switch (previous.kind, next.kind) {
        case (.markdown(let a, _), .markdown(let b, _)) where a.isListItem && b.isListItem: "\n"
        case (.toolHeader, .toolHeader), (.toolHeader, .toolDetail), (.toolDetail, .toolHeader), (.groupSummary, .toolHeader): "\n"
        default: "\n\n"
        }
    }

    /// Word boundaries around `offset` in `text` (letters, digits and underscores; one character otherwise).
    public static func wordRange(in text: String, at offset: Int) -> Range<Int> {
        let ns = text as NSString
        guard ns.length > 0 else { return 0..<0 }
        let position = min(max(0, offset), ns.length)
        let letters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < ns.length, let scalar = Unicode.Scalar(ns.character(at: index)) else {
                // Surrogate halves (emoji, astral letters) belong to the word they sit in.
                return index >= 0 && index < ns.length && UTF16.isLeadSurrogate(ns.character(at: index)) || index >= 0
                    && index < ns.length && UTF16.isTrailSurrogate(ns.character(at: index))
            }
            return letters.contains(scalar)
        }
        var lo = position
        var hi = position
        if isWord(position) || isWord(position - 1) {
            while isWord(lo - 1) { lo -= 1 }
            while isWord(hi) { hi += 1 }
        } else if position < ns.length {
            let composed = ns.rangeOfComposedCharacterSequence(at: position)
            lo = composed.location
            hi = composed.location + composed.length
        }
        return lo..<hi
    }

    /// The paragraph (line run between newlines) around `offset`.
    public static func paragraphRange(in text: String, at offset: Int) -> Range<Int> {
        let ns = text as NSString
        guard ns.length > 0 else { return 0..<0 }
        let range = ns.paragraphRange(for: NSRange(location: min(offset, ns.length - 1), length: 0))
        var end = range.location + range.length
        if end > range.location, ns.character(at: end - 1) == 10 { end -= 1 }
        return range.location..<end
    }

    /// The offset one composed character before or after `offset` (grapheme-safe).
    public static func step(in text: String, from offset: Int, forward: Bool) -> Int {
        let ns = text as NSString
        if forward {
            guard offset < ns.length else { return ns.length }
            let range = ns.rangeOfComposedCharacterSequence(at: offset)
            return range.location + range.length
        }
        guard offset > 0 else { return 0 }
        return ns.rangeOfComposedCharacterSequence(at: offset - 1).location
    }
}
