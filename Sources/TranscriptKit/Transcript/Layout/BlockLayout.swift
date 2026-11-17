import AppKit
import BelloCore
import CoreText

/// Something clickable inside a block that is not text.
public enum HotspotAction: Sendable, Hashable {
    case toggle(ExpansionKey)
    case copyCode
    case openChild(SessionID)
    case openFile(String)
}

struct Hotspot {
    var rect: CGRect
    var action: HotspotAction
    /// Accessibility name of the action.
    var label: String
}

struct Decoration {
    var rect: CGRect
    var fill: CGColor?
    var stroke: CGColor?
    var radius: CGFloat = 0
    var lineWidth: CGFloat = 1
    var scrolls = false
}

/// Small vector glyphs (status, chevrons, checkboxes) drawn without fonts.
enum Glyph: Equatable {
    case chevronRight, chevronDown, check, cross, running, preparing, warning, arrowUpRight, dot, file

    func draw(in rect: CGRect, color: CGColor, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(1.4)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let r = rect
        switch self {
        case .chevronRight:
            context.move(to: CGPoint(x: r.minX + r.width * 0.36, y: r.minY + r.height * 0.22))
            context.addLine(to: CGPoint(x: r.minX + r.width * 0.66, y: r.midY))
            context.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY - r.height * 0.22))
            context.strokePath()
        case .chevronDown:
            context.move(to: CGPoint(x: r.minX + r.width * 0.22, y: r.minY + r.height * 0.36))
            context.addLine(to: CGPoint(x: r.midX, y: r.minY + r.height * 0.66))
            context.addLine(to: CGPoint(x: r.maxX - r.width * 0.22, y: r.minY + r.height * 0.36))
            context.strokePath()
        case .check:
            context.setLineWidth(1.6)
            context.move(to: CGPoint(x: r.minX + r.width * 0.2, y: r.midY))
            context.addLine(to: CGPoint(x: r.minX + r.width * 0.42, y: r.maxY - r.height * 0.22))
            context.addLine(to: CGPoint(x: r.maxX - r.width * 0.16, y: r.minY + r.height * 0.24))
            context.strokePath()
        case .cross:
            context.setLineWidth(1.6)
            let inset = r.insetBy(dx: r.width * 0.24, dy: r.height * 0.24)
            context.move(to: CGPoint(x: inset.minX, y: inset.minY))
            context.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
            context.move(to: CGPoint(x: inset.maxX, y: inset.minY))
            context.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
            context.strokePath()
        case .running:
            let circle = r.insetBy(dx: r.width * 0.18, dy: r.height * 0.18)
            context.addArc(
                center: CGPoint(x: circle.midX, y: circle.midY), radius: circle.width / 2, startAngle: -.pi / 2,
                endAngle: .pi, clockwise: false)
            context.strokePath()
        case .preparing:
            let circle = r.insetBy(dx: r.width * 0.2, dy: r.height * 0.2)
            context.setLineDash(phase: 0, lengths: [1.5, 2])
            context.strokeEllipse(in: circle)
        case .warning:
            context.move(to: CGPoint(x: r.midX, y: r.minY + 1))
            context.addLine(to: CGPoint(x: r.maxX - 0.5, y: r.maxY - 1))
            context.addLine(to: CGPoint(x: r.minX + 0.5, y: r.maxY - 1))
            context.closePath()
            context.strokePath()
            context.fill(CGRect(x: r.midX - 0.7, y: r.minY + r.height * 0.36, width: 1.4, height: r.height * 0.3))
            context.fill(CGRect(x: r.midX - 0.7, y: r.maxY - r.height * 0.26, width: 1.4, height: 1.4))
        case .arrowUpRight:
            let inset = r.insetBy(dx: r.width * 0.26, dy: r.height * 0.26)
            context.move(to: CGPoint(x: inset.minX, y: inset.maxY))
            context.addLine(to: CGPoint(x: inset.maxX, y: inset.minY))
            context.move(to: CGPoint(x: inset.minX + inset.width * 0.3, y: inset.minY))
            context.addLine(to: CGPoint(x: inset.maxX, y: inset.minY))
            context.addLine(to: CGPoint(x: inset.maxX, y: inset.minY + inset.height * 0.7))
            context.strokePath()
        case .dot:
            context.fillEllipse(in: r.insetBy(dx: r.width * 0.36, dy: r.height * 0.36))
        case .file:
            let inset = r.insetBy(dx: r.width * 0.24, dy: r.height * 0.14)
            context.addPath(CGPath(roundedRect: inset, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.strokePath()
        }
        context.restoreGState()
    }

    static func status(_ status: ToolItemStatus) -> Glyph {
        switch status {
        case .preparing: .preparing
        case .running: .running
        case .done: .check
        case .failed: .cross
        case .unknown: .dot
        }
    }
}

/// A non-selectable piece of text or a glyph drawn in a block.
struct Label {
    enum Role: Equatable {
        case always
        /// Shown while the code block's copy button is idle / just copied.
        case copyIdle, copyDone
    }

    var line: CTLine?
    var glyph: Glyph?
    var glyphColor: CGColor?
    /// Baseline origin for text; the glyph's rect for glyphs.
    var point: CGPoint
    var glyphRect: CGRect = .zero
    var role: Role = .always
    var scrolls = false
}

/// The scrollable part of a block (code, wide tables, tool output), in block coordinates.
struct ScrollArea {
    var viewport: CGRect
    var contentSize: CGSize

    var maxOffset: CGPoint {
        CGPoint(x: max(0, contentSize.width - viewport.width), y: max(0, contentSize.height - viewport.height))
    }

    var scrollsHorizontally: Bool { contentSize.width > viewport.width + 0.5 }
    var scrollsVertically: Bool { contentSize.height > viewport.height + 0.5 }

    func clamp(_ offset: CGPoint) -> CGPoint {
        let limit = maxOffset
        return CGPoint(x: min(max(0, offset.x), limit.x), y: min(max(0, offset.y), limit.y))
    }
}

struct BlockImage {
    var source: String
    var rect: CGRect
    var radius: CGFloat
}

/// The laid-out form of one `RenderBlock`. Immutable after handoff to the main actor.
final class BlockLayout {
    let size: CGSize
    /// Selectable text length (0 when hidden or when nothing is selectable).
    let plainLength: Int
    let fragments: [Fragment]
    let decorations: [Decoration]
    let labels: [Label]
    let hotspots: [Hotspot]
    let images: [BlockImage]
    let scroll: ScrollArea?
    let isListItem: Bool
    let isHidden: Bool
    let quoteDepth: Int
    /// Extra space above this block (headings).
    let topSpacing: CGFloat
    /// Spacing to use before this block when it follows `previousKindTag` (list items pack tighter).
    let kindTag: KindTag
    /// Reasoning body: drawn with a continuous bar at its left (by the row).
    let isMuted: Bool

    enum KindTag: Equatable { case prose, list, code, table, rule, image, tool, toolDetail, card, other }

    init(
        size: CGSize, plainLength: Int, fragments: [Fragment] = [], decorations: [Decoration] = [], labels: [Label] = [],
        hotspots: [Hotspot] = [], images: [BlockImage] = [], scroll: ScrollArea? = nil, isListItem: Bool = false,
        isHidden: Bool = false, quoteDepth: Int = 0, topSpacing: CGFloat = 0, kindTag: KindTag = .other, isMuted: Bool = false
    ) {
        self.size = size
        self.plainLength = plainLength
        self.fragments = fragments
        self.decorations = decorations
        self.labels = labels
        self.hotspots = hotspots
        self.images = images
        self.scroll = scroll
        self.isListItem = isListItem
        self.isHidden = isHidden
        self.quoteDepth = quoteDepth
        self.topSpacing = topSpacing
        self.kindTag = kindTag
        self.isMuted = isMuted
    }

    static func hidden(kindTag: KindTag = .other) -> BlockLayout {
        BlockLayout(size: .zero, plainLength: 0, isHidden: true, kindTag: kindTag)
    }

    /// Converts a block-local point to the coordinate space of scrolling content.
    private func contentPoint(_ point: CGPoint, fragment: Fragment, offset: CGPoint) -> CGPoint {
        fragment.scrolls ? CGPoint(x: point.x + offset.x, y: point.y + offset.y) : point
    }

    /// Block-local point → block-local text offset.
    func hitTest(_ point: CGPoint, scrollOffset: CGPoint = .zero) -> Int {
        guard !fragments.isEmpty else { return point.y < size.height / 2 ? 0 : plainLength }
        var clamped = point
        if let scroll, scroll.viewport.contains(point) == false, point.y >= scroll.viewport.minY, point.y < scroll.viewport.maxY {
            clamped.x = min(max(point.x, scroll.viewport.minX), scroll.viewport.maxX - 1)
        }
        let candidates = fragments.map { fragment -> (Fragment, CGPoint) in (fragment, contentPoint(clamped, fragment: fragment, offset: scrollOffset)) }
        if let (inside, local) = candidates.first(where: { $0.0.frame.insetBy(dx: -2, dy: 0).contains($0.1) }) {
            return inside.textStart + inside.hitTest(CGPoint(x: local.x - inside.origin.x, y: local.y - inside.origin.y))
        }
        // Same band (table rows), nearest by x; otherwise nearest by y.
        let band = candidates.filter { $0.1.y >= $0.0.frame.minY && $0.1.y < $0.0.frame.maxY }
        let pool = band.isEmpty ? candidates : band
        let (best, local) = pool.min { a, b in distance(a.1, a.0.frame) < distance(b.1, b.0.frame) }!
        if local.y < best.frame.minY { return best.textStart }
        if local.y >= best.frame.maxY { return best.textStart + best.length }
        return best.textStart + best.hitTest(CGPoint(x: local.x - best.origin.x, y: local.y - best.origin.y))
    }

    private func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dy * 4 + dx
    }

    /// Block-local rects for a block-local range. `extendsPastEnd`: the selection continues after this block.
    func rects(_ range: Range<Int>, clip: CGRect, scrollOffset: CGPoint = .zero, extendsPastEnd: Bool = false) -> [CGRect] {
        guard !isHidden else { return [] }
        if fragments.isEmpty {
            return range.lowerBound == 0 && (range.upperBound >= plainLength || extendsPastEnd)
                ? [images.first?.rect ?? CGRect(origin: .zero, size: size)] : []
        }
        var rects: [CGRect] = []
        for (index, fragment) in fragments.enumerated() {
            let lo = max(range.lowerBound - fragment.textStart, 0)
            let hi = min(range.upperBound - fragment.textStart, fragment.length)
            let continues = range.upperBound > fragment.textStart + fragment.length
                || (extendsPastEnd && index == fragments.count - 1)
            guard lo < hi || (continues && lo <= fragment.length && range.lowerBound <= fragment.textStart + fragment.length)
            else { continue }
            let shift = fragment.scrolls ? scrollOffset : .zero
            let localClip = clip.offsetBy(dx: shift.x - fragment.origin.x, dy: shift.y - fragment.origin.y)
            // Inside a table, a selection continuing past a cell highlights only the cell's own text.
            let extend = continues && !(kindTag == .table)
            for rect in fragment.rects(lo..<max(lo, hi), clip: localClip, extendsPastEnd: extend) {
                var moved = rect.offsetBy(dx: fragment.origin.x - shift.x, dy: fragment.origin.y - shift.y)
                if fragment.scrolls, let scroll { moved = moved.intersection(scroll.viewport) }
                if !moved.isNull, !moved.isEmpty { rects.append(moved) }
            }
        }
        return rects
    }

    /// Block-local caret rect of an offset (for reveal and keyboard extension).
    func rect(forOffset offset: Int, scrollOffset: CGPoint = .zero) -> CGRect {
        guard let fragment = fragments.last(where: { $0.textStart <= offset }) ?? fragments.first else {
            return CGRect(origin: .zero, size: CGSize(width: 1, height: max(1, size.height)))
        }
        let shift = fragment.scrolls ? scrollOffset : .zero
        return fragment.rect(forOffset: min(fragment.length, offset - fragment.textStart))
            .offsetBy(dx: fragment.origin.x - shift.x, dy: fragment.origin.y - shift.y)
    }

    func link(at point: CGPoint, scrollOffset: CGPoint = .zero) -> (url: String, range: Range<Int>)? {
        for fragment in fragments where !fragment.links.isEmpty {
            let local = contentPoint(point, fragment: fragment, offset: scrollOffset)
            guard fragment.frame.contains(local) else { continue }
            let offset = fragment.hitTest(CGPoint(x: local.x - fragment.origin.x, y: local.y - fragment.origin.y))
            // The hit offset is the boundary nearest the point; test the character on either side.
            for candidate in [offset, offset - 1] where candidate >= 0 {
                if let link = fragment.links.first(where: { $0.range.contains(candidate) }) {
                    let rects = fragment.rects(link.range, clip: CGRect(x: -1e6, y: -1e6, width: 2e6, height: 2e6), extendsPastEnd: false)
                    let point = CGPoint(x: local.x - fragment.origin.x, y: local.y - fragment.origin.y)
                    if rects.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) {
                        return (link.url, (fragment.textStart + link.range.lowerBound)..<(fragment.textStart + link.range.upperBound))
                    }
                }
            }
        }
        return nil
    }

    func hotspot(at point: CGPoint) -> Hotspot? {
        hotspots.last { $0.rect.contains(point) }
    }

    // MARK: Drawing

    struct DrawState {
        var selection: Range<Int>?
        var selectionExtends = false
        var finds: [(range: Range<Int>, current: Bool)] = []
        var scrollOffset: CGPoint = .zero
        var copied = false
        var hoverHotspot: HotspotAction?
        var selectionColor: CGColor
    }

    func draw(in context: CGContext, clip: CGRect, state: DrawState, theme: TranscriptTheme, image: (String) -> CGImage?) {
        guard !isHidden else { return }
        let offset = state.scrollOffset
        // Static decorations, then scrolling ones clipped to the viewport.
        for decoration in decorations where !decoration.scrolls { draw(decoration, context: context, clip: clip) }
        for hotspot in hotspots where hotspot.action == state.hoverHotspot {
            context.setFillColor(theme.hoverFill)
            context.addPath(CGPath(roundedRect: hotspot.rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
            context.fillPath()
        }
        if let scroll {
            context.saveGState()
            context.clip(to: scroll.viewport)
            context.translateBy(x: -offset.x, y: -offset.y)
            let contentClip = clip.offsetBy(dx: offset.x, dy: offset.y)
            for decoration in decorations where decoration.scrolls { draw(decoration, context: context, clip: contentClip) }
            context.restoreGState()
        }
        for find in state.finds {
            context.setFillColor(find.current ? theme.findCurrent : theme.findHighlight)
            for rect in rects(find.range, clip: clip, scrollOffset: offset) {
                context.addPath(CGPath(roundedRect: rect.insetBy(dx: -1, dy: 0), cornerWidth: 2, cornerHeight: 2, transform: nil))
                context.fillPath()
            }
        }
        if let range = state.selection {
            context.setFillColor(state.selectionColor)
            for rect in rects(range, clip: clip, scrollOffset: offset, extendsPastEnd: state.selectionExtends) { context.fill(rect) }
        }
        for item in images {
            if let cgImage = image(item.source) {
                context.saveGState()
                context.addPath(CGPath(roundedRect: item.rect, cornerWidth: item.radius, cornerHeight: item.radius, transform: nil))
                context.clip()
                context.translateBy(x: item.rect.minX, y: item.rect.maxY)
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(cgImage, in: CGRect(origin: .zero, size: item.rect.size))
                context.restoreGState()
            }
            if state.selection != nil {
                context.setFillColor(state.selectionColor.copy(alpha: 0.45) ?? state.selectionColor)
                context.fill(item.rect)
            }
        }
        for label in labels where !label.scrolls { draw(label, context: context, copied: state.copied) }
        for fragment in fragments where !fragment.scrolls && fragment.frame.intersects(clip.insetBy(dx: -2, dy: -2)) {
            context.saveGState()
            context.translateBy(x: fragment.origin.x, y: fragment.origin.y)
            fragment.draw(in: context, clip: clip.offsetBy(dx: -fragment.origin.x, dy: -fragment.origin.y))
            context.restoreGState()
        }
        if let scroll {
            context.saveGState()
            context.clip(to: scroll.viewport)
            context.translateBy(x: -offset.x, y: -offset.y)
            let contentClip = clip.intersection(scroll.viewport).offsetBy(dx: offset.x, dy: offset.y)
            for label in labels where label.scrolls { draw(label, context: context, copied: state.copied) }
            for fragment in fragments where fragment.scrolls && fragment.frame.intersects(contentClip.insetBy(dx: -2, dy: -2)) {
                context.saveGState()
                context.translateBy(x: fragment.origin.x, y: fragment.origin.y)
                fragment.draw(in: context, clip: contentClip.offsetBy(dx: -fragment.origin.x, dy: -fragment.origin.y))
                context.restoreGState()
            }
            context.restoreGState()
            drawIndicators(scroll, offset: offset, context: context, theme: theme)
        }
    }

    private func draw(_ decoration: Decoration, context: CGContext, clip: CGRect) {
        guard decoration.rect.intersects(clip.insetBy(dx: -2, dy: -2)) else { return }
        let path = CGPath(roundedRect: decoration.rect, cornerWidth: decoration.radius, cornerHeight: decoration.radius, transform: nil)
        if let fill = decoration.fill {
            context.setFillColor(fill)
            context.addPath(path)
            context.fillPath()
        }
        if let stroke = decoration.stroke {
            context.setStrokeColor(stroke)
            context.setLineWidth(decoration.lineWidth)
            context.addPath(CGPath(
                roundedRect: decoration.rect.insetBy(dx: decoration.lineWidth / 2, dy: decoration.lineWidth / 2),
                cornerWidth: decoration.radius, cornerHeight: decoration.radius, transform: nil))
            context.strokePath()
        }
    }

    private func draw(_ label: Label, context: CGContext, copied: Bool) {
        switch label.role {
        case .always: break
        case .copyIdle: if copied { return }
        case .copyDone: if !copied { return }
        }
        if let glyph = label.glyph {
            glyph.draw(in: label.glyphRect, color: label.glyphColor ?? CGColor(gray: 0.5, alpha: 1), context: context)
        }
        if let line = label.line {
            context.textPosition = label.point
            CTLineDraw(line, context)
        }
    }

    /// Thin, quiet scroll indicators for inner scrolling (overlay-scroller style; always shown so the overflow is
    /// discoverable without hover).
    private func drawIndicators(_ scroll: ScrollArea, offset: CGPoint, context: CGContext, theme: TranscriptTheme) {
        let color = theme.tertiary.copy(alpha: 0.35) ?? theme.tertiary
        context.setFillColor(color)
        let viewport = scroll.viewport
        if scroll.scrollsHorizontally {
            let fraction = viewport.width / scroll.contentSize.width
            let width = max(24, viewport.width * fraction)
            let x = viewport.minX + (viewport.width - width) * (offset.x / max(1, scroll.maxOffset.x))
            let bar = CGRect(x: x + 2, y: viewport.maxY - 5, width: width - 4, height: 3)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.fillPath()
        }
        if scroll.scrollsVertically {
            let fraction = viewport.height / scroll.contentSize.height
            let height = max(20, viewport.height * fraction)
            let y = viewport.minY + (viewport.height - height) * (offset.y / max(1, scroll.maxOffset.y))
            let bar = CGRect(x: viewport.maxX - 5, y: y + 2, width: 3, height: height - 4)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.fillPath()
        }
    }
}
