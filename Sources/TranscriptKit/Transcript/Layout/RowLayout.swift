import AppKit
import CoreText

/// Cache key of a row layout: content revision, presentation state, width, theme and spacing.
public struct LayoutKey: Hashable, Sendable {
    public var rowID: RowID
    public var version: Int
    public var uiVersion: Int
    public var width: Int
    public var themeRevision: Int
    public var topPadding: Int
}

/// The selected part of one row. `start`/`end` nil: the selection continues beyond the row in that direction.
public struct RowSelection: Equatable, Sendable {
    public var start: (block: Int, offset: Int)?
    public var end: (block: Int, offset: Int)?

    public static func == (lhs: RowSelection, rhs: RowSelection) -> Bool {
        lhs.start?.block == rhs.start?.block && lhs.start?.offset == rhs.start?.offset && lhs.end?.block == rhs.end?.block
            && lhs.end?.offset == rhs.end?.offset && (lhs.start == nil) == (rhs.start == nil) && (lhs.end == nil) == (rhs.end == nil)
    }

    /// The selected range of a block, and whether the selection continues past the block's end.
    func range(forBlock block: Int, length: Int) -> (range: Range<Int>, extends: Bool)? {
        if let start, block < start.block { return nil }
        if let end, block > end.block { return nil }
        let lo = start.map { $0.block == block ? min($0.offset, length) : 0 } ?? 0
        let hi: Int
        let extends: Bool
        if let end, end.block == block {
            hi = min(end.offset, length)
            extends = false
        } else {
            hi = length
            extends = true
        }
        if lo < hi || (extends && lo <= hi) { return (lo..<hi, extends) }
        return nil
    }

    /// Whether the selection covers the start of `block` (selected from offset 0 or from before it).
    func coversStart(of block: Int) -> Bool {
        if let start { return start.block < block || (start.block == block && start.offset == 0) }
        return true
    }
}

/// The laid-out form of one row. Created off the main actor and handed over with `sending`; immutable afterwards
/// (only `MonoLines` creates CTLines lazily, on the main actor).
public final class RowLayout {
    public let key: LayoutKey
    public let height: CGFloat
    let blocks: [BlockLayout]
    let origins: [CGPoint]
    let theme: TranscriptTheme
    let width: CGFloat

    init(key: LayoutKey, blocks: [BlockLayout], width: CGFloat, topPadding: CGFloat, theme: TranscriptTheme) {
        self.key = key
        self.blocks = blocks
        self.theme = theme
        self.width = width
        var origins: [CGPoint] = []
        var y = topPadding
        var previous: BlockLayout?
        for block in blocks {
            if block.isHidden {
                origins.append(CGPoint(x: 0, y: y))
                continue
            }
            if let previous { y += Self.spacing(previous, block) + block.topSpacing }
            origins.append(CGPoint(x: 0, y: y))
            y += block.size.height
            previous = block
        }
        self.origins = origins
        height = ceil(y + 2)
    }

    static func spacing(_ previous: BlockLayout, _ next: BlockLayout) -> CGFloat {
        switch (previous.kindTag, next.kindTag) {
        case (.list, .list): TranscriptTheme.listSpacing
        case (.tool, .tool): 1
        case (.tool, .toolDetail): 3
        case (.toolDetail, .tool): 6
        default: TranscriptTheme.blockSpacing
        }
    }

    func blockFrame(_ index: Int) -> CGRect { CGRect(origin: origins[index], size: blocks[index].size) }

    /// Approximate memory cost in CTLines (prose lines plus a bounded share of lazily realised mono lines).
    public lazy var cost: Int = blocks.reduce(1) { total, block in
        total + block.fragments.reduce(1) { sum, fragment in
            switch fragment.content {
            case .lines(let lines): sum + lines.count
            case .mono(let mono): sum + min(mono.lineCount, MonoLines.cacheLimit)
            }
        }
    }

    var visibleBlockIndices: [Int] { blocks.indices.filter { !blocks[$0].isHidden } }

    /// Row-local point → (block, offset).
    func hitTest(_ point: CGPoint, scrollOffsets: [Int: CGPoint] = [:]) -> (block: Int, offset: Int) {
        let visible = visibleBlockIndices
        guard let first = visible.first, let last = visible.last else { return (0, 0) }
        for (position, index) in visible.enumerated() {
            let frame = blockFrame(index)
            let nextTop = position + 1 < visible.count ? blockFrame(visible[position + 1]).minY : .greatestFiniteMagnitude
            if point.y < frame.maxY + (nextTop - frame.maxY) / 2 {
                if point.y < frame.minY && index == first { return (index, 0) }
                let local = CGPoint(x: point.x - frame.minX, y: min(max(point.y - frame.minY, -1), frame.height + 1))
                return (index, blocks[index].hitTest(local, scrollOffset: scrollOffsets[index] ?? .zero))
            }
        }
        return (last, blocks[last].plainLength)
    }

    /// The visible block containing (or nearest below) row-local `y`.
    func blockIndex(atY y: CGFloat) -> Int {
        let visible = visibleBlockIndices
        guard let fallback = visible.last else { return 0 }
        return visible.first { blockFrame($0).maxY > y } ?? fallback
    }

    func hotspot(at point: CGPoint) -> (block: Int, hotspot: Hotspot)? {
        for index in visibleBlockIndices {
            let frame = blockFrame(index)
            guard frame.insetBy(dx: -2, dy: -2).contains(point) else { continue }
            if let hotspot = blocks[index].hotspot(at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)) {
                return (index, hotspot)
            }
        }
        return nil
    }

    func link(at point: CGPoint, scrollOffsets: [Int: CGPoint]) -> (block: Int, url: String, range: Range<Int>)? {
        for index in visibleBlockIndices {
            let frame = blockFrame(index)
            guard frame.contains(point) else { continue }
            if let link = blocks[index].link(at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY), scrollOffset: scrollOffsets[index] ?? .zero) {
                return (index, link.url, link.range)
            }
        }
        return nil
    }

    /// The block whose scroll area contains `point`.
    func scrollArea(at point: CGPoint) -> (block: Int, area: ScrollArea)? {
        for index in visibleBlockIndices {
            guard let area = blocks[index].scroll else { continue }
            let frame = blockFrame(index)
            if area.viewport.offsetBy(dx: frame.minX, dy: frame.minY).contains(point) { return (index, area) }
        }
        return nil
    }

    struct DrawState {
        var selection: RowSelection?
        var finds: [(block: Int, range: Range<Int>, current: Bool)] = []
        var scrollOffsets: [Int: CGPoint] = [:]
        var copiedBlock: Int?
        var hover: (block: Int, action: HotspotAction)?
        var selectionColor: CGColor
    }

    func draw(in context: CGContext, dirty: CGRect, state: DrawState, image: (String) -> CGImage?) {
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        drawQuoteBars(context: context, dirty: dirty)
        if let selection = state.selection { drawSelectionGaps(selection, context: context, color: state.selectionColor) }
        for index in blocks.indices where !blocks[index].isHidden {
            let frame = blockFrame(index)
            guard frame.minY <= dirty.maxY + 1, frame.maxY >= dirty.minY - 1 else { continue }
            let block = blocks[index]
            var blockState = BlockLayout.DrawState(selectionColor: state.selectionColor)
            if let selection = state.selection, let range = selection.range(forBlock: index, length: block.plainLength) {
                blockState.selection = range.range
                blockState.selectionExtends = range.extends
            }
            blockState.finds = state.finds.filter { $0.block == index }.map { ($0.range, $0.current) }
            blockState.scrollOffset = state.scrollOffsets[index] ?? .zero
            blockState.copied = state.copiedBlock == index
            if let hover = state.hover, hover.block == index { blockState.hoverHotspot = hover.action }
            context.saveGState()
            context.translateBy(x: frame.minX, y: frame.minY)
            block.draw(in: context, clip: dirty.offsetBy(dx: -frame.minX, dy: -frame.minY), state: blockState, theme: theme, image: image)
            context.restoreGState()
        }
    }

    /// Continuous highlight across the gaps between selected blocks and through the row's padding when the
    /// selection continues into the neighbouring rows.
    private func drawSelectionGaps(_ selection: RowSelection, context: CGContext, color: CGColor) {
        let visible = visibleBlockIndices
        guard let first = visible.first, let last = visible.last else { return }
        context.setFillColor(color)
        if selection.start == nil, selection.range(forBlock: first, length: blocks[first].plainLength) != nil {
            context.fill(CGRect(x: 0, y: 0, width: width, height: blockFrame(first).minY))
        }
        for position in visible.indices.dropLast() {
            let index = visible[position]
            let next = visible[position + 1]
            guard let range = selection.range(forBlock: index, length: blocks[index].plainLength), range.extends,
                selection.range(forBlock: next, length: blocks[next].plainLength) != nil
            else { continue }
            let top = blockFrame(index).maxY
            let bottom = blockFrame(next).minY
            if bottom > top { context.fill(CGRect(x: 0, y: top, width: width, height: bottom - top)) }
        }
        if selection.end == nil, selection.range(forBlock: last, length: blocks[last].plainLength)?.extends == true {
            let top = blockFrame(last).maxY
            context.fill(CGRect(x: 0, y: top, width: width, height: height - top))
        }
    }

    private func drawQuoteBars(context: CGContext, dirty: CGRect) {
        let visible = visibleBlockIndices
        context.setFillColor(theme.separator)
        // Reasoning body: one bar spanning consecutive muted blocks.
        var runStart: CGFloat?
        var runEnd: CGFloat = 0
        for index in visible + [-1] {
            if index >= 0, blocks[index].isMuted {
                let frame = blockFrame(index)
                if runStart == nil { runStart = frame.minY }
                runEnd = frame.maxY
            } else if let start = runStart {
                context.addPath(CGPath(roundedRect: CGRect(x: 6, y: start, width: 2, height: runEnd - start), cornerWidth: 1, cornerHeight: 1, transform: nil))
                context.fillPath()
                runStart = nil
            }
        }
        for (position, index) in visible.enumerated() {
            let depth = blocks[index].quoteDepth
            guard depth > 0 else { continue }
            let frame = blockFrame(index)
            for level in 1...depth {
                var top = frame.minY
                if position > 0 {
                    let previous = visible[position - 1]
                    if blocks[previous].quoteDepth >= level { top = blockFrame(previous).maxY }
                }
                let x = CGFloat(level - 1) * TranscriptTheme.quoteStep + 2
                let rect = CGRect(x: x, y: top, width: 3, height: frame.maxY - top)
                if rect.intersects(dirty) {
                    context.addPath(CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
                    context.fillPath()
                }
            }
        }
    }
}
