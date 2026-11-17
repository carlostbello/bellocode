import AppKit
import BelloCore

/// One row's text as assistive technology reads it: the visible blocks' plain text joined by newlines (the row's
/// accessibility value), where each block starts in that string, and where each line starts. Lines come from the
/// row's layout (wrapped prose lines, monospaced lines) when the layout matches the block's text, otherwise from
/// newlines. Built on demand for a row on screen and cached by its cell (review m2).
struct RowAccessibilityText {
    struct Span {
        var block: Int
        var start: Int
        var length: Int
        var end: Int { start + length }
    }

    let string: NSString
    let spans: [Span]
    /// Ascending UTF-16 offsets in `string` where a line starts; the first is 0.
    let lineStarts: [Int]

    var length: Int { string.length }
    var fullRange: NSRange { NSRange(location: 0, length: string.length) }

    init(blocks: [(index: Int, text: String)], layout: RowLayout?) {
        var string = ""
        var spans: [Span] = []
        var starts: [Int] = []
        var offset = 0
        for (position, block) in blocks.enumerated() {
            if position > 0 {
                string += "\n"
                offset += 1
            }
            let text = block.text as NSString
            let span = Span(block: block.index, start: offset, length: text.length)
            spans.append(span)
            starts.append(offset)
            if let layout, block.index < layout.blocks.count, !layout.blocks[block.index].isHidden,
                layout.blocks[block.index].plainLength == text.length
            {
                for fragment in layout.blocks[block.index].fragments {
                    let base = offset + fragment.textStart
                    switch fragment.content {
                    case .lines(let lines): for line in lines { starts.append(base + line.range.lowerBound) }
                    case .mono(let mono): for start in mono.lineStarts { starts.append(base + start) }
                    }
                }
            } else {
                var search = NSRange(location: 0, length: text.length)
                while search.length > 0 {
                    let found = text.range(of: "\n", options: .literal, range: search)
                    guard found.location != NSNotFound else { break }
                    let next = found.location + 1
                    if next < text.length { starts.append(offset + next) }
                    search = NSRange(location: next, length: text.length - next)
                }
            }
            string += block.text
            offset += text.length
        }
        self.string = string as NSString
        self.spans = spans
        var unique: [Int] = []
        for start in starts.sorted() where start <= offset && unique.last != start { unique.append(start) }
        lineStarts = unique.isEmpty ? [0] : unique
    }

    /// The line holding `index` (the last line for the end of the text).
    func line(for index: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// A line's range, including its trailing newline.
    func range(forLine line: Int) -> NSRange? {
        guard line >= 0, line < lineStarts.count else { return nil }
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// The block and block offset of a string index (an index on a separator maps to the end of the block before).
    func position(for index: Int) -> (block: Int, offset: Int)? {
        guard let first = spans.first else { return nil }
        let clamped = min(max(0, index), length)
        let span = spans.last { $0.start <= clamped } ?? first
        return (span.block, min(clamped - span.start, span.length))
    }

    /// The string index of a block position; a hidden block maps to the start of the next visible one.
    func index(block: Int, offset: Int) -> Int {
        if let span = spans.first(where: { $0.block == block }) { return span.start + min(max(0, offset), span.length) }
        if let next = spans.first(where: { $0.block > block }) { return next.start }
        return length
    }

    /// The block (style run) holding `index`.
    func blockRange(for index: Int) -> NSRange? {
        guard let span = spans.last(where: { $0.start <= index }) ?? spans.first else { return nil }
        return NSRange(location: span.start, length: span.length)
    }
}

extension TranscriptController {
    /// The accessibility text of row `index` (see `RowAccessibilityText`).
    func accessibilityText(_ index: Int, layout: RowLayout?) -> RowAccessibilityText {
        let rowBlocks = blocks(row: index)
        let visible = visibility(row: index, blocks: rowBlocks)
        let usable = layout.flatMap { $0.key.rowID == rows[index].id && $0.blocks.count == rowBlocks.count ? $0 : nil }
        let shown = rowBlocks.enumerated().filter { visible[$0.offset] }.map { (index: $0.offset, text: $0.element.plainText) }
        return RowAccessibilityText(blocks: shown, layout: usable)
    }

    /// The selected part of row `index` in its accessibility text, or nil when the selection does not touch it.
    func accessibilitySelectedRange(_ index: Int, text: RowAccessibilityText) -> NSRange? {
        let id = rows[index].id
        guard let part = selection?.rowSelection(row: index, rowID: id, { self.rowIndex[$0] }) else {
            // A caret (empty selection) in this row.
            if let selection, selection.isEmpty, selection.anchor.rowID == id {
                return NSRange(location: text.index(block: selection.anchor.block, offset: selection.anchor.offset), length: 0)
            }
            return nil
        }
        let start = part.start.map { text.index(block: $0.block, offset: $0.offset) } ?? 0
        let end = part.end.map { text.index(block: $0.block, offset: $0.offset) } ?? text.length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Selects a range of row `index`'s accessibility text (VoiceOver's text selection commands).
    func setAccessibilitySelectedRange(_ range: NSRange, row index: Int, text: RowAccessibilityText) {
        let id = rows[index].id
        guard let start = text.position(for: range.location), let end = text.position(for: range.location + range.length) else { return }
        setSelection(
            TranscriptSelection(
                anchor: TranscriptPosition(rowID: id, block: start.block, offset: start.offset),
                focus: TranscriptPosition(rowID: id, block: end.block, offset: end.offset)))
    }

    /// Row-local (layout) rect of a range of the accessibility text, from the layout's line geometry. Nil without a
    /// layout that matches the text.
    func accessibilityRect(for range: NSRange, row index: Int, text: RowAccessibilityText, layout: RowLayout) -> CGRect? {
        let id = rows[index].id
        var union: CGRect?
        for span in text.spans where span.block < layout.blocks.count {
            let lo = max(range.location, span.start)
            let hi = min(range.location + range.length, span.end)
            // An empty range (a caret) still has a position.
            guard lo < hi || (range.length == 0 && lo == hi && range.location >= span.start && range.location <= span.end) else { continue }
            let block = layout.blocks[span.block]
            guard !block.isHidden, block.plainLength == span.length else { continue }
            let offset = scrollOffsets[id]?[span.block] ?? .zero
            let local = (lo - span.start)..<(hi - span.start)
            let first = block.rect(forOffset: local.lowerBound, scrollOffset: offset)
            var rect = first
            if !local.isEmpty {
                let last = block.rect(forOffset: local.upperBound, scrollOffset: offset)
                let clip = CGRect(x: -1e6, y: min(first.minY, last.minY) - 1, width: 2e6, height: abs(last.maxY - first.minY) + 2)
                let rects = block.rects(local, clip: clip, scrollOffset: offset)
                rect = rects.reduce(rects.first ?? first) { $0.union($1) }
            }
            let frame = layout.blockFrame(span.block)
            rect = rect.offsetBy(dx: frame.minX, dy: frame.minY)
            union = union.map { $0.union(rect) } ?? rect
            if range.length == 0 { break }
        }
        return union
    }

    /// The accessibility-text index at a row-local (layout) point.
    func accessibilityIndex(at point: CGPoint, row index: Int, text: RowAccessibilityText, layout: RowLayout) -> Int {
        let block = layout.blockIndex(atY: point.y)
        guard block < layout.blocks.count else { return text.length }
        let frame = layout.blockFrame(block)
        let offset = scrollOffsets[rows[index].id]?[block] ?? .zero
        let local = layout.blocks[block].hitTest(CGPoint(x: point.x - frame.minX, y: point.y - frame.minY), scrollOffset: offset)
        return text.index(block: block, offset: local)
    }
}
