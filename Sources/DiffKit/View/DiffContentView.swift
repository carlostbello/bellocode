import AppKit
import CoreText
import DesignSystem
import Engine
import TranscriptKit
import os

/// A position in the diff's text: row and UTF-16 offset in the row's cell on the selection's side.
public struct DiffTextPosition: Sendable, Hashable, Comparable {
    public var row: Int
    public var offset: Int
    public static func < (a: Self, b: Self) -> Bool { (a.row, a.offset) < (b.row, b.offset) }
}

/// A text selection on one side (split) or in the unified column (`side == nil`).
public struct DiffTextSelection: Sendable, Hashable {
    public var side: DiffSide?
    public var anchor: DiffTextPosition
    public var head: DiffTextPosition
    public var start: DiffTextPosition { min(anchor, head) }
    public var end: DiffTextPosition { max(anchor, head) }
    public var isEmpty: Bool { anchor == head }
}

/// A find match: row, side (nil in unified) and UTF-16 range in that cell.
public struct DiffFindMatch: Sendable, Hashable {
    public var row: Int
    public var side: DiffSide?
    public var range: NSRange
}

/// A line that has a review comment (gutter mark).
public struct DiffCommentMark: Sendable, Hashable {
    public var path: String
    public var side: DiffSide
    public var line: Int
    public init(path: String, side: DiffSide, line: Int) {
        self.path = path
        self.side = side
        self.line = line
    }
}

/// The diff's document view: virtualised rows drawn with CoreText (only rows in the dirty rect are drawn; CTLines are
/// cached, bounded), gutters with line numbers, +/− markers (status is never colour only), word highlights computed
/// lazily for visible changed pairs, syntax colours, selection and find highlights, and a shared horizontal offset
/// for long lines (gutters stay put). With wrapping on, lines are cut by columns (monospaced) and rows grow.
///
/// Threading: `@MainActor`. Rows and syntax arrive as immutable values built off the main actor.
@MainActor
final class DiffContentView: NSView {
    // MARK: Inputs

    private(set) var files: [DiffFile] = []
    private(set) var rows: DiffRows = .empty
    private(set) var syntax: [Int: DiffSyntax] = [:]
    var theme: DiffTheme { didSet { if theme != oldValue { themeChanged() } } }
    private(set) var layoutMode: DiffLayout = .unified
    var wraps = false { didSet { if wraps != oldValue { invalidateGeometry() } } }
    var horizontalOffset: CGFloat = 0 {
        didSet {
            let clamped = min(max(0, horizontalOffset), maxHorizontalOffset)
            if clamped != horizontalOffset { horizontalOffset = clamped }
            if horizontalOffset != oldValue { setNeedsDisplay(visibleRect) }
        }
    }
    var currentHunkRow: Int? { didSet { if currentHunkRow != oldValue { redrawRows([oldValue, currentHunkRow]) } } }
    var commentMarks: Set<DiffCommentMark> = [] { didSet { if commentMarks != oldValue { setNeedsDisplay(visibleRect) } } }
    var findMatches: [DiffFindMatch] = [] { didSet { matchesByRow = Dictionary(grouping: findMatches.indices, by: { findMatches[$0].row }); setNeedsDisplay(visibleRect) } }
    var currentMatch: Int? { didSet { if currentMatch != oldValue { setNeedsDisplay(visibleRect) } } }
    var selection: DiffTextSelection? { didSet { if selection != oldValue { setNeedsDisplay(visibleRect); onSelectionChange?() } } }
    /// Files whose hunks can be reverted (a "Revert" button on their hunk headers).
    var revertableFiles: Set<Int> = [] { didSet { if revertableFiles != oldValue { setNeedsDisplay(visibleRect) } } }

    // MARK: Callbacks

    var onToggleFile: ((Int) -> Void)?
    var onExpandGap: ((DiffRow, _ all: Bool) -> Void)?
    var onRevertHunk: ((Int, Int) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onCurrentHunkChange: ((Int?) -> Void)?
    var contextMenuProvider: ((Int?, NSEvent) -> NSMenu?)?
    var keyHandler: ((NSEvent) -> Bool)?

    // MARK: Geometry and caches

    private var rowTops: [CGFloat] = [0]
    private var rowColumns: [(Int, Int)] = []
    private var lineCache = BoundedCache<LineKey, CTLine>(limit: 4_000)
    private var numberCache = BoundedCache<Int, CTLine>(limit: 2_000)
    private var wordCache = BoundedCache<Int, IntraLineHighlight>(limit: 8_192)
    private var revertButtons: [Int: CGRect] = [:]
    private var matchesByRow: [Int: [Int]] = [:]
    private var generation = 0
    private var lastWidth: CGFloat = 0
    static let signposter = OSSignposter(subsystem: "dev.bellocode.diffkit", category: .pointsOfInterest)
    /// Time spent in `draw(_:)` (last call), for the benchmark harness.
    private(set) var lastDrawDuration: Duration = .zero

    private struct LineKey: Hashable {
        var generation: Int
        var row: Int
        var side: UInt8
        var segment: Int
    }

    init(theme: DiffTheme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Diff")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { setNeedsDisplay(visibleRect); return true }
    override func resignFirstResponder() -> Bool { setNeedsDisplay(visibleRect); return true }

    // MARK: Content

    /// Replaces the rows (built off the main actor) and syntax. Caches keyed by the old rows are dropped.
    func setContent(files: [DiffFile], rows: DiffRows, syntax: [Int: DiffSyntax], layout: DiffLayout) {
        self.files = files
        self.rows = rows
        self.syntax = syntax
        layoutMode = layout
        generation += 1
        lineCache.removeAll()
        wordCache.removeAll()
        rowColumns = rows.rows.map { row in (row.left.map { DiffRowBuilder.columns($0.text) } ?? 0, row.right.map { DiffRowBuilder.columns($0.text) } ?? 0) }
        if let selection, selection.end.row >= rows.rows.count { self.selection = nil }
        if let row = currentHunkRow, row >= rows.rows.count { currentHunkRow = nil }
        invalidateGeometry()
    }

    /// Syntax arrived later than the rows (it is computed after them).
    func setSyntax(_ syntax: [Int: DiffSyntax]) {
        self.syntax = syntax
        generation += 1
        lineCache.removeAll()
        setNeedsDisplay(visibleRect)
    }

    private func themeChanged() {
        generation += 1
        lineCache.removeAll()
        numberCache.removeAll()
        invalidateGeometry()
    }

    // MARK: Geometry

    var gutterWidth: CGFloat { CGFloat(max(3, String(max(rows.maxLineNumber, 1)).count) + 1) * theme.charWidth + 6 }
    var markerWidth: CGFloat { theme.charWidth * 2 }
    var columnWidth: CGFloat {
        switch layoutMode {
        case .unified: max(40, bounds.width - 2 * gutterWidth - markerWidth)
        case .split: max(40, floor(bounds.width / 2) - gutterWidth - markerWidth)
        }
    }

    var maxHorizontalOffset: CGFloat {
        guard !wraps else { return 0 }
        let columns = max(rows.maxColumnsLeft, rows.maxColumnsRight)
        return max(0, CGFloat(columns) * theme.charWidth + theme.charWidth * 2 - columnWidth)
    }

    private var wrapColumns: Int { max(20, Int(columnWidth / theme.charWidth) - 1) }

    func height(ofRow index: Int) -> CGFloat {
        let row = rows.rows[index]
        switch row.kind {
        case .fileHeader: return theme.fileHeaderHeight
        case .hunkHeader: return theme.rowHeight + 6
        case .gap: return theme.rowHeight + 4
        case .notice: return theme.rowHeight + 12
        case .line:
            guard wraps else { return theme.rowHeight }
            let columns = rowColumns[index]
            let segments = max(1, (max(columns.0, columns.1) + wrapColumns - 1) / wrapColumns)
            return theme.rowHeight * CGFloat(segments)
        }
    }

    func invalidateGeometry() {
        let interval = Self.signposter.beginInterval("diffGeometry")
        defer { Self.signposter.endInterval("diffGeometry", interval) }
        var tops = [CGFloat](repeating: 0, count: rows.rows.count + 1)
        var y: CGFloat = 0
        if !wraps {
            for index in rows.rows.indices {
                tops[index] = y
                switch rows.rows[index].kind {
                case .line: y += theme.rowHeight
                default: y += height(ofRow: index)
                }
            }
        } else {
            for index in rows.rows.indices {
                tops[index] = y
                y += height(ofRow: index)
            }
        }
        tops[rows.rows.count] = y
        rowTops = tops
        lastWidth = bounds.width
        let height = max(y + theme.rowHeight * 2, enclosingScrollView?.contentSize.height ?? 0)
        if frame.height != height { setFrameSize(NSSize(width: frame.width, height: height)) }
        horizontalOffset = min(horizontalOffset, maxHorizontalOffset)
        lineCache.removeAll()
        setNeedsDisplay(bounds)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            if wraps { invalidateGeometry() } else { horizontalOffset = min(horizontalOffset, maxHorizontalOffset); setNeedsDisplay(visibleRect) }
        }
    }

    var totalHeight: CGFloat { rowTops.last ?? 0 }

    func rowRect(_ index: Int) -> CGRect {
        guard index >= 0, index + 1 < rowTops.count else { return .zero }
        return CGRect(x: 0, y: rowTops[index], width: bounds.width, height: rowTops[index + 1] - rowTops[index])
    }

    /// The row at a y coordinate (clamped), by binary search over row tops.
    func rowIndex(atY y: CGFloat) -> Int? {
        guard !rows.rows.isEmpty else { return nil }
        var low = 0
        var high = rows.rows.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if rowTops[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let start = ContinuousClock.now
        let interval = Self.signposter.beginInterval("diffDraw")
        defer {
            Self.signposter.endInterval("diffDraw", interval)
            lastDrawDuration = ContinuousClock.now - start
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(theme.background)
        context.fill(dirtyRect)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        guard let first = rowIndex(atY: dirtyRect.minY), let last = rowIndex(atY: dirtyRect.maxY) else {
            drawEmpty(context)
            return
        }
        for index in first...last { drawRow(index, in: context) }
    }

    private func drawEmpty(_ context: CGContext) {}

    private func drawRow(_ index: Int, in context: CGContext) {
        let row = rows.rows[index]
        let rect = rowRect(index)
        switch row.kind {
        case .fileHeader: drawFileHeader(row, index: index, rect: rect, in: context)
        case .hunkHeader: drawHunkHeader(row, index: index, rect: rect, in: context)
        case .gap(let hidden, let expandable): drawGap(hidden: hidden, expandable: expandable, rect: rect, in: context)
        case .notice: drawNotice(row.text, rect: rect, in: context)
        case .line: drawLine(row, index: index, rect: rect, in: context)
        }
    }

    private func uiLine(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    }

    private func draw(_ line: CTLine, x: CGFloat, rect: CGRect, in context: CGContext) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.textPosition = CGPoint(x: x, y: rect.minY + floor((rect.height - ascent - descent) / 2) + ascent)
        CTLineDraw(line, context)
    }

    private func drawFileHeader(_ row: DiffRow, index: Int, rect: CGRect, in context: CGContext) {
        let file = files[row.fileIndex]
        let band = rect.insetBy(dx: 0, dy: 0).divided(atDistance: 6, from: .minYEdge).remainder
        context.setFillColor(theme.fileHeaderFill)
        context.fill(band)
        context.setFillColor(theme.base.separator)
        context.fill(CGRect(x: 0, y: band.minY, width: rect.width, height: 1))
        context.fill(CGRect(x: 0, y: band.maxY - 1, width: rect.width, height: 1))
        let collapsed = rows.rows.indices.contains(index + 1) ? rows.rows[index + 1].fileIndex != row.fileIndex || rows.rows[index + 1].kind == .fileHeader : true
        var x: CGFloat = 8
        let chevron = uiLine(collapsed && !file.hunks.isEmpty ? "▸" : "▾", font: theme.uiFont, color: theme.base.secondary)
        draw(chevron, x: x, rect: band, in: context)
        x += 14
        let (letter, color) = Self.statusBadge(file.status, theme: theme)
        let badge = uiLine(letter, font: theme.uiBoldFont, color: color)
        let badgeWidth = CTLineGetTypographicBounds(badge, nil, nil, nil) + 8
        let badgeRect = CGRect(x: x, y: band.midY - 8, width: badgeWidth, height: 16)
        context.setFillColor(color.copy(alpha: 0.15) ?? color)
        context.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()
        draw(badge, x: x + 4, rect: band, in: context)
        x += badgeWidth + 8
        let counts = NSMutableAttributedString()
        if file.additions > 0 { counts.append(NSAttributedString(string: "+\(file.additions) ", attributes: [.font: theme.uiFont, .foregroundColor: theme.addedMarker])) }
        if file.deletions > 0 { counts.append(NSAttributedString(string: "−\(file.deletions)", attributes: [.font: theme.uiFont, .foregroundColor: theme.removedMarker])) }
        let countsLine = CTLineCreateWithAttributedString(counts)
        let countsWidth = CTLineGetTypographicBounds(countsLine, nil, nil, nil)
        let pathText = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
        let available = rect.width - x - countsWidth - 20
        let path = CTLineCreateTruncatedLine(
            uiLine(pathText, font: theme.uiBoldFont, color: theme.base.text), max(40, available), .middle,
            uiLine("…", font: theme.uiBoldFont, color: theme.base.text)) ?? uiLine(pathText, font: theme.uiBoldFont, color: theme.base.text)
        draw(path, x: x, rect: band, in: context)
        draw(countsLine, x: rect.width - countsWidth - 12, rect: band, in: context)
    }

    static func statusBadge(_ status: PatchFile.Status, theme: DiffTheme) -> (String, CGColor) {
        switch status {
        case .added: ("A", theme.addedMarker)
        case .deleted: ("D", theme.removedMarker)
        case .renamed: ("R", theme.base.accent)
        case .copied: ("C", theme.base.accent)
        case .modified: ("M", theme.base.running)
        }
    }

    private func drawHunkHeader(_ row: DiffRow, index: Int, rect: CGRect, in context: CGContext) {
        context.setFillColor(theme.hunkFill)
        context.fill(rect)
        if currentHunkRow == index {
            context.setFillColor(theme.focusBar)
            context.fill(CGRect(x: 0, y: rect.minY, width: 3, height: rect.height))
        }
        let line = uiLine(row.text, font: theme.font, color: theme.hunkText)
        draw(line, x: (layoutMode == .unified ? 2 * gutterWidth : gutterWidth) + 4, rect: rect, in: context)
        revertButtons[index] = nil
        if revertableFiles.contains(row.fileIndex) {
            let button = uiLine("Revert Hunk", font: theme.uiFont, color: theme.base.accent)
            let width = CTLineGetTypographicBounds(button, nil, nil, nil)
            let frame = CGRect(x: rect.width - width - 14, y: rect.minY, width: width + 10, height: rect.height)
            revertButtons[index] = frame
            draw(button, x: frame.minX + 5, rect: rect, in: context)
        }
    }

    private func drawGap(hidden: Int, expandable: Bool, rect: CGRect, in context: CGContext) {
        context.setFillColor(theme.gapFill)
        context.fill(rect)
        let text = "⋯ \(hidden) unchanged line\(hidden == 1 ? "" : "s")" + (expandable ? "  ·  Click to show 20 more, ⌥-click for all" : "")
        let line = uiLine(text, font: theme.uiFont, color: theme.base.secondary)
        draw(line, x: (layoutMode == .unified ? 2 * gutterWidth : gutterWidth) + 4, rect: rect, in: context)
    }

    private func drawNotice(_ text: String, rect: CGRect, in context: CGContext) {
        let line = uiLine(text, font: theme.uiFont, color: theme.base.secondary)
        draw(line, x: 2 * gutterWidth + 4, rect: rect, in: context)
    }

    private func drawLine(_ row: DiffRow, index: Int, rect: CGRect, in context: CGContext) {
        switch layoutMode {
        case .unified:
            guard let cell = row.cell else { return }
            let oldNumber = cell.kind == .added ? nil : (cell.kind == .context ? cell.otherNumber : cell.number)
            let newNumber = cell.kind == .removed ? nil : cell.number
            drawCell(
                cell, row: row, index: index, side: 0, gutters: [oldNumber, newNumber], x: 0, width: rect.width, rect: rect, in: context)
        case .split:
            let half = floor(rect.width / 2)
            drawCell(row.left, row: row, index: index, side: 1, gutters: [row.left?.number], x: 0, width: half, rect: rect, in: context)
            drawCell(row.right, row: row, index: index, side: 2, gutters: [row.right?.number], x: half + 1, width: rect.width - half - 1, rect: rect, in: context)
            context.setFillColor(theme.base.separator)
            context.fill(CGRect(x: half, y: rect.minY, width: 1, height: rect.height))
        }
    }

    /// Draws one cell (nil: an empty side in split view) with its gutters, marker, fills, highlights and text.
    private func drawCell(
        _ cell: DiffCell?, row: DiffRow, index: Int, side: UInt8, gutters: [Int?], x: CGFloat, width: CGFloat, rect: CGRect, in context: CGContext
    ) {
        let gutterTotal = CGFloat(gutters.count) * gutterWidth
        guard let cell else {
            // An empty side: a faint fill with diagonal hatching, so alignment gaps read as "no line here".
            let area = CGRect(x: x, y: rect.minY, width: width, height: rect.height)
            context.setFillColor(theme.emptyCellFill)
            context.fill(area)
            context.saveGState()
            context.clip(to: area)
            context.setStrokeColor(theme.emptyCellFill)
            context.setLineWidth(1)
            var stripe = x - rect.height - CGFloat(Int(rect.minY) % 8)
            while stripe < area.maxX {
                context.move(to: CGPoint(x: stripe, y: area.maxY))
                context.addLine(to: CGPoint(x: stripe + area.height, y: area.minY))
                stripe += 8
            }
            context.strokePath()
            context.restoreGState()
            return
        }
        let (fill, gutterFill, markerColor, marker): (CGColor?, CGColor?, CGColor, String) =
            switch cell.kind {
            case .added: (theme.addedFill, theme.addedGutterFill, theme.addedMarker, "+")
            case .removed: (theme.removedFill, theme.removedGutterFill, theme.removedMarker, "−")
            case .context: (nil, nil, theme.gutterText, " ")
            }
        if let fill {
            context.setFillColor(fill)
            context.fill(CGRect(x: x + gutterTotal, y: rect.minY, width: width - gutterTotal, height: rect.height))
        }
        if let gutterFill {
            context.setFillColor(gutterFill)
            context.fill(CGRect(x: x, y: rect.minY, width: gutterTotal, height: rect.height))
        }
        let lineRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: theme.rowHeight)
        let file = files[row.fileIndex]
        for (offset, number) in gutters.enumerated() {
            guard let number else { continue }
            let numberLine = numberCache.value(for: number) { uiLine(String(number), font: theme.font, color: theme.gutterText) }
            let numberWidth = CTLineGetTypographicBounds(numberLine, nil, nil, nil)
            draw(numberLine, x: x + CGFloat(offset + 1) * gutterWidth - numberWidth - 6, rect: lineRect, in: context)
            if commentMarks.contains(DiffCommentMark(path: file.path, side: cell.side, line: number)), offset == gutters.count - 1 {
                context.setFillColor(theme.commentMark)
                context.fillEllipse(in: CGRect(x: x + 3, y: lineRect.midY - 3, width: 6, height: 6))
            }
        }
        if cell.kind != .context {
            draw(uiLine(marker, font: theme.boldFont, color: markerColor), x: x + gutterTotal + 3, rect: lineRect, in: context)
        }
        let textX = x + gutterTotal + markerWidth
        let textWidth = width - gutterTotal - markerWidth
        context.saveGState()
        context.clip(to: CGRect(x: textX, y: rect.minY, width: textWidth, height: rect.height))
        let segments = wraps ? segmentRanges(cell.text) : [NSRange(location: 0, length: min(cell.text.utf16.count, TranscriptTheme.maxDisplayLineUTF16))]
        let selectionSide: DiffSide? = layoutMode == .unified ? nil : cell.side
        let highlight = row.pairIndex.map { word(for: $0) }
        let wordRanges = highlight.map { cell.kind == .removed ? $0.removed : $0.added } ?? []
        for (segmentIndex, range) in segments.enumerated() {
            let line = ctLine(row: index, side: side, segment: segmentIndex, cell: cell, file: row.fileIndex, range: range)
            let origin = CGPoint(x: textX + 2 - (wraps ? 0 : horizontalOffset), y: rect.minY + CGFloat(segmentIndex) * theme.rowHeight)
            let segmentRect = CGRect(x: textX, y: origin.y, width: textWidth, height: theme.rowHeight)
            func fillRanges(_ ranges: [NSRange], color: CGColor, inset: CGFloat = 1) {
                for range in ranges {
                    let clipped = NSIntersectionRange(range, NSRange(location: segments[segmentIndex].location, length: segments[segmentIndex].length))
                    guard clipped.length > 0 || (range.length == 0 && clipped.location == range.location) else { continue }
                    let start = CTLineGetOffsetForStringIndex(line, clipped.location - segments[segmentIndex].location, nil)
                    let end = CTLineGetOffsetForStringIndex(line, clipped.location + clipped.length - segments[segmentIndex].location, nil)
                    context.setFillColor(color)
                    context.fill(CGRect(x: origin.x + start, y: segmentRect.minY + inset, width: max(2, end - start), height: segmentRect.height - 2 * inset))
                }
            }
            fillRanges(wordRanges, color: cell.kind == .removed ? theme.removedWordFill : theme.addedWordFill, inset: 0.5)
            if let indices = matchesByRow[index] {
                for matchIndex in indices where findMatches[matchIndex].side == selectionSide {
                    fillRanges([findMatches[matchIndex].range], color: matchIndex == currentMatch ? theme.base.findCurrent : theme.base.findHighlight)
                }
            }
            if let range = selectedRange(row: index, side: selectionSide, length: cell.text.utf16.count) {
                fillRanges([range], color: window?.firstResponder === self ? theme.base.selection : theme.base.inactiveSelection, inset: 0)
            }
            draw(line, x: origin.x, rect: segmentRect, in: context)
        }
        context.restoreGState()
    }

    /// UTF-16 ranges of the wrapped segments of a line (cut by columns; tabs count to the next stop of 4).
    private func segmentRanges(_ text: String) -> [NSRange] {
        let limit = wrapColumns
        var ranges: [NSRange] = []
        var start = 0
        var column = 0
        var index = 0
        for unit in text.utf16 {
            let width = unit == 9 ? 4 - column % 4 : (unit & 0xFC00 == 0xDC00 ? 0 : 1)
            if column + width > limit, index > start {
                ranges.append(NSRange(location: start, length: index - start))
                start = index
                column = 0
            }
            column += unit == 9 ? 4 - column % 4 : width
            index += 1
            if ranges.count > 2_000 { break }
        }
        ranges.append(NSRange(location: start, length: max(0, min(index, text.utf16.count) - start)))
        return ranges
    }

    private func ctLine(row: Int, side: UInt8, segment: Int, cell: DiffCell, file: Int, range: NSRange) -> CTLine {
        let key = LineKey(generation: generation, row: row, side: side, segment: segment)
        return lineCache.value(for: key) {
            let text = cell.text as NSString
            let full = NSMutableAttributedString(
                string: text.substring(with: NSRange(location: 0, length: min(text.length, max(range.location + range.length, 0)))),
                attributes: [.font: theme.font, .foregroundColor: theme.base.text, .paragraphStyle: tabStyle])
            if let runs = syntax[file]?.runs(for: cell) {
                for run in runs where run.location < full.length {
                    let length = min(run.length, full.length - run.location)
                    full.addAttribute(.foregroundColor, value: theme.base.color(for: run.kind), range: NSRange(location: run.location, length: length))
                }
            }
            let piece = full.attributedSubstring(from: NSRange(location: min(range.location, full.length), length: min(range.length, max(0, full.length - range.location))))
            return CTLineCreateWithAttributedString(piece)
        }
    }

    private lazy var tabStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = theme.charWidth * 4
        return style
    }()

    private func word(for pair: Int) -> IntraLineHighlight {
        wordCache.value(for: pair) {
            let item = rows.pairs[pair]
            return IntraLine.highlight(removed: item.removed, added: item.added)
        }
    }

    private func redrawRows(_ indices: [Int?]) {
        for index in indices.compactMap({ $0 }) where index < rows.rows.count { setNeedsDisplay(rowRect(index)) }
    }

    // MARK: Selection

    private func selectedRange(row: Int, side: DiffSide?, length: Int) -> NSRange? {
        guard let selection, !selection.isEmpty, selection.side == side else { return nil }
        let start = selection.start
        let end = selection.end
        guard row >= start.row, row <= end.row else { return nil }
        let from = row == start.row ? min(start.offset, length) : 0
        let to = row == end.row ? min(end.offset, length) : length
        // A fully selected line shows a little past its end, like a text view.
        return NSRange(location: from, length: max(0, to - from) + (row < end.row ? 0 : 0))
    }

    func cell(row: Int, side: DiffSide?) -> DiffCell? {
        guard rows.rows.indices.contains(row) else { return nil }
        let item = rows.rows[row]
        guard case .line = item.kind else { return nil }
        if layoutMode == .unified { return item.cell }
        return side == .old ? item.left : item.right
    }

    /// The selected text on the selection's side, lines joined with newlines.
    var selectedText: String? {
        guard let selection, !selection.isEmpty else { return nil }
        var parts: [String] = []
        for row in selection.start.row...selection.end.row {
            guard let cell = cell(row: row, side: selection.side) else { continue }
            let text = cell.text as NSString
            let from = row == selection.start.row ? min(selection.start.offset, text.length) : 0
            let to = row == selection.end.row ? min(selection.end.offset, text.length) : text.length
            parts.append(text.substring(with: NSRange(location: from, length: max(0, to - from))))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Hit test: row, side and UTF-16 offset for a point in the text columns.
    func position(at point: CGPoint) -> (DiffTextPosition, DiffSide?)? {
        guard let index = rowIndex(atY: point.y) else { return nil }
        let side: DiffSide?
        let originX: CGFloat
        switch layoutMode {
        case .unified:
            side = nil
            originX = 2 * gutterWidth + markerWidth
        case .split:
            let half = floor(bounds.width / 2)
            side = point.x < half ? .old : .new
            originX = (side == .old ? 0 : half + 1) + gutterWidth + markerWidth
        }
        guard let cell = cell(row: index, side: side) else { return (DiffTextPosition(row: index, offset: 0), side) }
        let rect = rowRect(index)
        let segment = wraps ? min(Int((point.y - rect.minY) / theme.rowHeight), segmentRanges(cell.text).count - 1) : 0
        let ranges = wraps ? segmentRanges(cell.text) : [NSRange(location: 0, length: min(cell.text.utf16.count, TranscriptTheme.maxDisplayLineUTF16))]
        let range = ranges[max(0, segment)]
        let line = ctLine(row: index, side: layoutMode == .unified ? 0 : (side == .old ? 1 : 2), segment: max(0, segment), cell: cell, file: rows.rows[index].fileIndex, range: range)
        let x = point.x - originX - 2 + (wraps ? 0 : horizontalOffset)
        let offset = x <= 0 ? 0 : CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
        return (DiffTextPosition(row: index, offset: range.location + max(0, offset == kCFNotFound ? range.length : offset)), side)
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(atY: point.y), rowRect(index).contains(point) else { selection = nil; return }
        let row = rows.rows[index]
        switch row.kind {
        case .fileHeader:
            onToggleFile?(row.fileIndex)
        case .gap(_, let expandable):
            if expandable { onExpandGap?(row, event.modifierFlags.contains(.option)) }
        case .hunkHeader:
            if let button = revertButtons[index], button.contains(point) {
                onRevertHunk?(row.fileIndex, row.hunkIndex)
            } else {
                currentHunkRow = index
                onCurrentHunkChange?(index)
            }
        case .notice:
            selection = nil
        case .line:
            guard let (position, side) = self.position(at: point) else { return }
            let inGutter: Bool = {
                switch layoutMode {
                case .unified: return point.x < 2 * gutterWidth
                case .split:
                    let half = floor(bounds.width / 2)
                    return point.x < gutterWidth || (point.x > half && point.x < half + 1 + gutterWidth)
                }
            }()
            if event.modifierFlags.contains(.shift), var existing = selection, existing.side == side {
                existing.head = position
                selection = existing
            } else if inGutter || event.clickCount >= 3 {
                let length = cell(row: index, side: side)?.text.utf16.count ?? 0
                selection = DiffTextSelection(side: side, anchor: DiffTextPosition(row: index, offset: 0), head: DiffTextPosition(row: index, offset: length))
                selectingLines = true
            } else if event.clickCount == 2, let text = cell(row: index, side: side)?.text {
                let range = (text as NSString).wordRange(at: position.offset)
                selection = DiffTextSelection(
                    side: side, anchor: DiffTextPosition(row: index, offset: range.location), head: DiffTextPosition(row: index, offset: range.location + range.length))
            } else {
                selection = DiffTextSelection(side: side, anchor: position, head: position)
                selectingLines = false
            }
            currentHunkRow = hunkHeaderRow(containing: index)
        }
    }

    private var selectingLines = false

    override func mouseDragged(with event: NSEvent) {
        guard var current = selection else { return }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(atY: point.y) else { return }
        if selectingLines {
            let length = cell(row: index, side: current.side)?.text.utf16.count ?? 0
            current.head = index >= current.anchor.row ? DiffTextPosition(row: index, offset: length) : DiffTextPosition(row: index, offset: 0)
            if index < current.anchor.row {
                let anchorLength = cell(row: current.anchor.row, side: current.side)?.text.utf16.count ?? 0
                current.anchor = DiffTextPosition(row: current.anchor.row, offset: anchorLength)
            }
        } else {
            var probe = point
            if layoutMode == .split {
                let half = floor(bounds.width / 2)
                probe.x = current.side == .old ? min(point.x, half - 1) : max(point.x, half + 2)
            }
            guard let (position, _) = position(at: probe) else { return }
            current.head = position
        }
        selection = current
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = rowIndex(atY: point.y)
        if let index, selection == nil || !(selection!.start.row...selection!.end.row).contains(index), case .line = rows.rows[index].kind,
           let (position, side) = position(at: point)
        {
            let length = cell(row: index, side: side)?.text.utf16.count ?? 0
            selection = DiffTextSelection(side: side, anchor: DiffTextPosition(row: index, offset: 0), head: DiffTextPosition(row: index, offset: max(length, position.offset)))
        }
        return contextMenuProvider?(index, event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        interpretKeyEvents([event])
    }

    override func scrollWheel(with event: NSEvent) {
        // Horizontal deltas move the shared offset (gutters stay); vertical scrolling goes to the scroll view.
        if !wraps, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            horizontalOffset -= event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : theme.charWidth * 3)
            return
        }
        super.scrollWheel(with: event)
    }

    func hunkHeaderRow(containing index: Int) -> Int? {
        var low = 0
        var high = rows.hunkHeaderRows.count - 1
        var best: Int?
        while low <= high {
            let mid = (low + high) / 2
            if rows.hunkHeaderRows[mid] <= index {
                best = rows.hunkHeaderRows[mid]
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let best, rows.rows[best].fileIndex == rows.rows[index].fileIndex else { return nil }
        return best
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        guard let first = rowIndex(atY: visibleRect.minY), let last = rowIndex(atY: visibleRect.maxY) else { return [] }
        return (first...min(last, first + 120)).map { index -> NSAccessibilityElement in
            let row = rows.rows[index]
            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityFrameInParentSpace(rowRect(index))
            element.setAccessibilityLabel(Self.accessibilityText(row, files: files, layout: layoutMode))
            return element
        }
    }

    static func accessibilityText(_ row: DiffRow, files: [DiffFile], layout: DiffLayout) -> String {
        func describe(_ cell: DiffCell?) -> String {
            guard let cell else { return "no line" }
            let kind = cell.kind == .added ? "added" : cell.kind == .removed ? "removed" : "unchanged"
            return "\(kind) line \(cell.number): \(cell.text)"
        }
        switch row.kind {
        case .fileHeader:
            let file = files[row.fileIndex]
            return "\(file.path), \(file.status.rawValue), \(file.additions) added, \(file.deletions) removed"
        case .hunkHeader: return "Change \(row.hunkIndex + 1): \(row.text)"
        case .gap(let hidden, _): return "\(hidden) unchanged lines hidden"
        case .notice: return row.text
        case .line: return layout == .unified ? describe(row.cell) : "Old: \(describe(row.left)). New: \(describe(row.right))"
        }
    }
}

/// A small LRU-ish cache: bounded count, evicts the least recently used quarter when full.
struct BoundedCache<Key: Hashable, Value> {
    private var storage: [Key: (value: Value, tick: UInt64)] = [:]
    private var tick: UInt64 = 0
    let limit: Int

    init(limit: Int) { self.limit = limit }

    var count: Int { storage.count }

    mutating func value(for key: Key, make: () -> Value) -> Value {
        tick += 1
        if let entry = storage[key] {
            storage[key] = (entry.value, tick)
            return entry.value
        }
        let value = make()
        storage[key] = (value, tick)
        if storage.count > limit {
            let cutoff = storage.values.map(\.tick).sorted()[limit / 4]
            storage = storage.filter { $0.value.tick > cutoff }
        }
        return value
    }

    mutating func removeAll() { storage.removeAll(keepingCapacity: true) }
}

extension NSString {
    /// The word (letters, digits, underscore) around a UTF-16 offset, or a one-character range.
    func wordRange(at offset: Int) -> NSRange {
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let index = min(max(0, offset), length - 1)
        func isWord(_ unit: unichar) -> Bool {
            (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit >= 0x80
        }
        guard isWord(character(at: index)) else { return NSRange(location: index, length: 1) }
        var start = index
        var end = index + 1
        while start > 0, isWord(character(at: start - 1)) { start -= 1 }
        while end < length, isWord(character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }
}
