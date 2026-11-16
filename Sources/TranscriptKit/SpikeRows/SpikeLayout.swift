// SPIKE G1-B: CoreText layout of one transcript item into immutable-after-handoff layout objects.
//
// Layout runs off the main actor (`@concurrent`) and hands back a freshly created, non-Sendable layout object with
// `sending`, so no `@unchecked Sendable` is needed. Monospaced blocks (code, diffs, tool output) never wrap: their
// height is `lines × lineHeight` with no typesetting, and their CTLines are created lazily for visible lines only.
// That is how a 100 KB code block stays cheap: measuring it is O(lines) arithmetic, drawing touches ~60 lines.

import AppKit
import CoreText

// MARK: Theme

public struct SpikeTheme: Sendable, Equatable {
    public var bodySize: CGFloat = 13.5
    public var monoSize: CGFloat = 11.5
    public var text: CGColor
    public var secondary: CGColor
    public var link: CGColor
    public var codeBackground: CGColor
    public var cardBackground: CGColor
    public var cardStroke: CGColor
    public var userBubble: CGColor
    public var keyword: CGColor
    public var string: CGColor
    public var comment: CGColor
    public var number: CGColor
    public var diffAdd: CGColor
    public var diffDel: CGColor
    public var diffHunk: CGColor
    public var error: CGColor
    public var ok: CGColor
    public var selection: CGColor
    public var findHighlight: CGColor

    public static let horizontalInset: CGFloat = 24
    public static let verticalPadding: CGFloat = 10
    public static let blockSpacing: CGFloat = 8
    /// Display limit for one monospaced line (copy still returns the full line).
    public static let maxDisplayLineUTF16 = 400

    @MainActor
    public static func resolve(for appearance: NSAppearance) -> SpikeTheme {
        var theme: SpikeTheme?
        appearance.performAsCurrentDrawingAppearance {
            func c(_ color: NSColor) -> CGColor { color.cgColor }
            theme = SpikeTheme(
                text: c(.labelColor), secondary: c(.secondaryLabelColor), link: c(.linkColor),
                codeBackground: c(.textColor.withAlphaComponent(0.05)), cardBackground: c(.textColor.withAlphaComponent(0.035)),
                cardStroke: c(.separatorColor), userBubble: c(.controlAccentColor.withAlphaComponent(0.10)),
                keyword: c(.systemPink), string: c(.systemOrange), comment: c(.systemGray), number: c(.systemPurple),
                diffAdd: c(.systemGreen), diffDel: c(.systemRed), diffHunk: c(.systemTeal), error: c(.systemRed),
                ok: c(.systemGreen), selection: c(.selectedTextBackgroundColor),
                findHighlight: c(.findHighlightColor.withAlphaComponent(0.6)))
        }
        return theme!
    }
}

/// Fonts for one layout pass. CTFonts are not Sendable, so each off-main pass creates its own (cheap: CoreText
/// caches font instances).
final class SpikeFonts {
    let body: CTFont
    let strong: CTFont
    let emphasis: CTFont
    let inlineCode: CTFont
    let h1: CTFont
    let h2: CTFont
    let h3: CTFont
    let mono: CTFont
    let monoLineHeight: CGFloat
    let monoAscent: CGFloat
    let theme: SpikeTheme

    init(theme: SpikeTheme) {
        self.theme = theme
        body = CTFontCreateUIFontForLanguage(.system, theme.bodySize, nil)!
        strong = CTFontCreateUIFontForLanguage(.emphasizedSystem, theme.bodySize, nil)!
        emphasis = CTFontCreateCopyWithSymbolicTraits(body, 0, nil, .traitItalic, .traitItalic) ?? body
        mono = CTFontCreateWithName("Menlo" as CFString, theme.monoSize, nil)
        inlineCode = CTFontCreateWithName("Menlo" as CFString, theme.bodySize - 1, nil)
        h1 = CTFontCreateUIFontForLanguage(.emphasizedSystem, theme.bodySize + 8, nil)!
        h2 = CTFontCreateUIFontForLanguage(.emphasizedSystem, theme.bodySize + 5, nil)!
        h3 = CTFontCreateUIFontForLanguage(.emphasizedSystem, theme.bodySize + 2, nil)!
        monoAscent = ceil(CTFontGetAscent(mono))
        monoLineHeight = ceil(CTFontGetAscent(mono) + CTFontGetDescent(mono) + CTFontGetLeading(mono)) + 3
    }

    func attributed(_ styled: SpikeStyledText, base: SpikeTextStyle = .body) -> NSAttributedString {
        let string = NSMutableAttributedString(string: styled.text, attributes: attributes(base))
        for run in styled.runs where run.location + run.length <= styled.utf16Count {
            var attrs = attributes(run.style)
            if base == .mutedItalic || base == .heading1 || base == .heading2 || base == .heading3 {
                attrs = attributes(base)  // keep heading/muted font, ignore inline styling in the spike
            }
            string.setAttributes(attrs, range: NSRange(location: run.location, length: run.length))
        }
        return string
    }

    func attributes(_ style: SpikeTextStyle) -> [NSAttributedString.Key: Any] {
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let (font, color): (CTFont, CGColor) = switch style {
        case .body: (body, theme.text)
        case .strong: (strong, theme.text)
        case .emphasis: (emphasis, theme.text)
        case .inlineCode: (inlineCode, theme.keyword)
        case .link: (body, theme.link)
        case .heading1: (h1, theme.text)
        case .heading2: (h2, theme.text)
        case .heading3: (h3, theme.text)
        case .marker: (body, theme.secondary)
        case .muted: (body, theme.secondary)
        case .mutedItalic: (emphasis, theme.secondary)
        case .toolTitle: (strong, theme.text)
        case .statusOK: (body, theme.ok)
        case .statusError: (strong, theme.error)
        case .code: (mono, theme.text)
        case .keyword: (mono, theme.keyword)
        case .string: (mono, theme.string)
        case .comment: (mono, theme.comment)
        case .number: (mono, theme.number)
        case .diffAdd: (mono, theme.diffAdd)
        case .diffDel: (mono, theme.diffDel)
        case .diffHunk: (mono, theme.diffHunk)
        case .diffMeta: (mono, theme.secondary)
        }
        return [fontKey: font, colorKey: color]
    }
}

// MARK: Layout objects

public struct SpikeLayoutKey: Hashable, Sendable {
    public var id: Int
    public var revision: Int
    public var uiVersion: Int
    public var width: Int
}

struct SpikeLine {
    let line: CTLine
    let x: CGFloat
    let top: CGFloat
    let baseline: CGFloat
    let height: CGFloat
    /// Fragment-local UTF-16 range.
    let range: Range<Int>
}

/// Lazily created no-wrap monospaced lines. Owned by the main actor after handoff.
final class SpikeMonoLines {
    let text: NSString
    let lineStarts: [Int]
    let flavor: SpikeMonoText.Flavor
    let lineHeight: CGFloat
    let ascent: CGFloat
    private let fonts: SpikeFonts
    private var cache: [Int: CTLine] = [:]

    init(mono: SpikeMonoText, fonts: SpikeFonts) {
        text = mono.text as NSString
        lineStarts = mono.lineStarts
        flavor = mono.flavor
        lineHeight = fonts.monoLineHeight
        ascent = fonts.monoAscent
        self.fonts = fonts
    }

    var lineCount: Int { lineStarts.count }

    /// Line range excluding the newline.
    func lineRange(_ index: Int) -> Range<Int> {
        let start = lineStarts[index]
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] - 1 : text.length
        return start..<max(start, end)
    }

    func line(_ index: Int) -> CTLine {
        if let cached = cache[index] { return cached }
        let range = lineRange(index)
        let displayLength = min(range.count, SpikeTheme.maxDisplayLineUTF16)
        let string = text.substring(with: NSRange(location: range.lowerBound, length: displayLength))
        let attributed = NSMutableAttributedString(string: string, attributes: fonts.attributes(.code))
        for run in SpikeMarkdown.highlight(line: string, flavor: flavor) {
            attributed.setAttributes(fonts.attributes(run.style), range: NSRange(location: run.location, length: run.length))
        }
        let line = CTLineCreateWithAttributedString(attributed)
        if cache.count > 400 { cache.removeAll(keepingCapacity: true) }  // bounded
        cache[index] = line
        return line
    }
}

final class SpikeFragment {
    enum Content {
        case lines([SpikeLine])
        case mono(SpikeMonoLines)
    }

    let origin: CGPoint
    let textStart: Int
    let length: Int
    let width: CGFloat
    let height: CGFloat
    let content: Content

    init(origin: CGPoint, textStart: Int, length: Int, width: CGFloat, height: CGFloat, content: Content) {
        self.origin = origin
        self.textStart = textStart
        self.length = length
        self.width = width
        self.height = height
        self.content = content
    }

    var frame: CGRect { CGRect(origin: origin, size: CGSize(width: width, height: height)) }

    /// Fragment-local point -> fragment-local UTF-16 offset.
    func hitTest(_ point: CGPoint) -> Int {
        if point.y < 0 { return 0 }
        if point.y >= height { return length }
        switch content {
        case .lines(let lines):
            guard let line = lines.first(where: { point.y < $0.top + $0.height }) ?? lines.last else { return 0 }
            let index = CTLineGetStringIndexForPosition(line.line, CGPoint(x: point.x - line.x, y: 0))
            if index == kCFNotFound { return line.range.lowerBound }
            return min(max(index, line.range.lowerBound), line.range.upperBound)
        case .mono(let mono):
            let lineIndex = min(mono.lineCount - 1, max(0, Int(point.y / mono.lineHeight)))
            let range = mono.lineRange(lineIndex)
            let index = CTLineGetStringIndexForPosition(mono.line(lineIndex), CGPoint(x: point.x, y: 0))
            let local = index == kCFNotFound ? 0 : index
            return range.lowerBound + min(max(0, local), range.count)
        }
    }

    /// Fragment-local rects for a fragment-local UTF-16 range, limited to `clip` (fragment coordinates).
    func selectionRects(_ range: Range<Int>, clip: CGRect) -> [CGRect] {
        var rects: [CGRect] = []
        switch content {
        case .lines(let lines):
            for line in lines where line.top + line.height >= clip.minY && line.top <= clip.maxY {
                let lo = max(range.lowerBound, line.range.lowerBound)
                let hi = min(range.upperBound, line.range.upperBound)
                guard lo < hi || (range.upperBound > line.range.upperBound && lo <= hi && range.lowerBound <= line.range.upperBound)
                else { continue }
                let x0 = CTLineGetOffsetForStringIndex(line.line, lo, nil)
                let x1 = range.upperBound > line.range.upperBound
                    ? max(width - line.x, x0 + 4) : CTLineGetOffsetForStringIndex(line.line, hi, nil)
                rects.append(CGRect(x: line.x + x0, y: line.top, width: max(1, x1 - x0), height: line.height))
            }
        case .mono(let mono):
            let first = max(0, Int(clip.minY / mono.lineHeight))
            let last = min(mono.lineCount - 1, Int(clip.maxY / mono.lineHeight))
            guard first <= last else { return [] }
            for index in first...last {
                let lineRange = mono.lineRange(index)
                let lo = max(range.lowerBound, lineRange.lowerBound)
                let hi = min(range.upperBound, lineRange.upperBound)
                guard lo <= hi, range.lowerBound <= lineRange.upperBound, range.upperBound >= lineRange.lowerBound,
                      !(range.upperBound == lineRange.lowerBound && lineRange.count > 0) else { continue }
                let line = mono.line(index)
                let x0 = CTLineGetOffsetForStringIndex(line, min(lo - lineRange.lowerBound, SpikeTheme.maxDisplayLineUTF16), nil)
                let x1 = range.upperBound > lineRange.upperBound
                    ? width : CTLineGetOffsetForStringIndex(line, min(hi - lineRange.lowerBound, SpikeTheme.maxDisplayLineUTF16), nil)
                rects.append(CGRect(x: x0, y: CGFloat(index) * mono.lineHeight, width: max(2, x1 - x0), height: mono.lineHeight))
            }
        }
        return rects
    }

    func draw(in context: CGContext, clip: CGRect) {
        switch content {
        case .lines(let lines):
            for line in lines where line.top + line.height >= clip.minY && line.top <= clip.maxY {
                context.textPosition = CGPoint(x: line.x, y: line.baseline)
                CTLineDraw(line.line, context)
            }
        case .mono(let mono):
            let first = max(0, Int(clip.minY / mono.lineHeight))
            let last = min(mono.lineCount - 1, Int(clip.maxY / mono.lineHeight))
            guard first <= last else { return }
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
            for index in first...last {
                context.textPosition = CGPoint(x: 0, y: CGFloat(index) * mono.lineHeight + mono.ascent + 1)
                CTLineDraw(mono.line(index), context)
            }
            context.restoreGState()
        }
    }
}

struct SpikeDecoration {
    var rect: CGRect
    var fill: CGColor?
    var stroke: CGColor?
    var radius: CGFloat = 0
}

final class SpikeBlockLayout {
    let size: CGSize
    let plainLength: Int
    let fragments: [SpikeFragment]
    let decorations: [SpikeDecoration]
    /// Non-selectable labels (block coordinates, baseline origin).
    let labels: [(CTLine, CGPoint)]
    /// Click target that toggles a collapsible block.
    let toggleRect: CGRect?
    let image: (id: Int, rect: CGRect)?
    let isListItem: Bool

    init(size: CGSize, plainLength: Int, fragments: [SpikeFragment], decorations: [SpikeDecoration] = [],
         labels: [(CTLine, CGPoint)] = [], toggleRect: CGRect? = nil, image: (id: Int, rect: CGRect)? = nil,
         isListItem: Bool = false) {
        self.size = size
        self.plainLength = plainLength
        self.fragments = fragments
        self.decorations = decorations
        self.labels = labels
        self.toggleRect = toggleRect
        self.image = image
        self.isListItem = isListItem
    }

    func hitTest(_ point: CGPoint) -> Int {
        guard !fragments.isEmpty else { return point.y < size.height / 2 ? 0 : plainLength }
        if let inside = fragments.first(where: { $0.frame.insetBy(dx: -2, dy: 0).contains(point) }) {
            return inside.textStart + inside.hitTest(CGPoint(x: point.x - inside.origin.x, y: point.y - inside.origin.y))
        }
        // Same band (table rows), nearest by x; otherwise nearest by y.
        let band = fragments.filter { point.y >= $0.frame.minY && point.y < $0.frame.maxY }
        let candidates = band.isEmpty ? fragments : band
        let best = candidates.min { a, b in
            distance(point, a.frame) < distance(point, b.frame)
        }!
        let local = CGPoint(x: point.x - best.origin.x, y: point.y - best.origin.y)
        if point.y < best.frame.minY { return best.textStart }
        if point.y >= best.frame.maxY { return best.textStart + best.length }
        return best.textStart + best.hitTest(local)
    }

    private func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dy * 4 + dx
    }

    /// Block-local selection rects for a block-local range.
    func selectionRects(_ range: Range<Int>, clip: CGRect) -> [CGRect] {
        if fragments.isEmpty {
            return range.lowerBound == 0 && range.upperBound >= plainLength ? [image?.rect ?? CGRect(origin: .zero, size: size)] : []
        }
        var rects: [CGRect] = []
        for fragment in fragments {
            let lo = max(range.lowerBound - fragment.textStart, 0)
            let hi = min(range.upperBound - fragment.textStart, fragment.length)
            let continuesPast = range.upperBound > fragment.textStart + fragment.length
            guard lo < hi || (lo == hi && continuesPast && lo <= fragment.length && range.lowerBound <= fragment.textStart + fragment.length)
            else { continue }
            let localClip = clip.offsetBy(dx: -fragment.origin.x, dy: -fragment.origin.y)
            let localRange = lo..<(continuesPast ? fragment.length + 1 : hi)
            rects += fragment.selectionRects(localRange, clip: localClip)
                .map { $0.offsetBy(dx: fragment.origin.x, dy: fragment.origin.y) }
        }
        return rects
    }

    /// Block-local rect of a block-local offset (for reveal).
    func rect(forOffset offset: Int) -> CGRect {
        guard let fragment = fragments.last(where: { $0.textStart <= offset }) ?? fragments.first else {
            return CGRect(origin: .zero, size: size)
        }
        let local = offset - fragment.textStart
        switch fragment.content {
        case .lines(let lines):
            let line = lines.first(where: { $0.range.contains(local) }) ?? lines.last
            return CGRect(x: fragment.origin.x, y: fragment.origin.y + (line?.top ?? 0), width: fragment.width,
                          height: line?.height ?? 16)
        case .mono(let mono):
            let index = max(0, (mono.lineStarts.lastIndex(where: { $0 <= local }) ?? 0))
            return CGRect(x: fragment.origin.x, y: fragment.origin.y + CGFloat(index) * mono.lineHeight,
                          width: fragment.width, height: mono.lineHeight)
        }
    }
}

/// Selected portion of one row: from (startBlock, startOffset) to (endBlock, endOffset), end exclusive.
public struct SpikeRowSelection: Equatable, Sendable {
    public var startBlock: Int
    public var startOffset: Int
    public var endBlock: Int
    public var endOffset: Int

    public static let whole = SpikeRowSelection(startBlock: 0, startOffset: 0, endBlock: .max, endOffset: 0)

    func range(forBlock block: Int, length: Int) -> Range<Int>? {
        guard block >= startBlock, block <= endBlock else { return nil }
        let lo = block == startBlock ? min(startOffset, length) : 0
        let hi = block == endBlock ? min(endOffset, length) : length + 1  // +1: selection continues past the block
        return lo < hi ? lo..<hi : nil
    }
}

public final class SpikeItemLayout {
    public let key: SpikeLayoutKey
    public let height: CGFloat
    let blocks: [SpikeBlockLayout]
    let origins: [CGPoint]
    let bubble: CGRect?
    let theme: SpikeTheme

    init(key: SpikeLayoutKey, blocks: [SpikeBlockLayout], isUser: Bool, width: CGFloat, theme: SpikeTheme) {
        self.key = key
        self.blocks = blocks
        self.theme = theme
        var origins: [CGPoint] = []
        let inset = SpikeTheme.horizontalInset + (isUser ? 12 : 0)
        var y = SpikeTheme.verticalPadding + (isUser ? 8 : 0)
        for (index, block) in blocks.enumerated() {
            if index > 0 { y += block.isListItem && blocks[index - 1].isListItem ? 3 : SpikeTheme.blockSpacing }
            origins.append(CGPoint(x: inset, y: y))
            y += block.size.height
        }
        y += isUser ? 8 : 0
        bubble = isUser ? CGRect(x: SpikeTheme.horizontalInset - 4, y: SpikeTheme.verticalPadding - 2,
                                 width: width - 2 * SpikeTheme.horizontalInset + 8, height: y - SpikeTheme.verticalPadding + 4) : nil
        self.origins = origins
        height = ceil(y + SpikeTheme.verticalPadding)
    }

    func blockFrame(_ index: Int) -> CGRect { CGRect(origin: origins[index], size: blocks[index].size) }

    /// Item-local point -> (block, offset).
    func hitTest(_ point: CGPoint) -> (block: Int, offset: Int) {
        guard !blocks.isEmpty else { return (0, 0) }
        for index in blocks.indices {
            let frame = blockFrame(index)
            if point.y < frame.maxY + (index + 1 < blocks.count ? (origins[index + 1].y - frame.maxY) / 2 : .greatestFiniteMagnitude) {
                if point.y < frame.minY && index == 0 { return (0, 0) }
                let local = CGPoint(x: point.x - frame.minX, y: min(max(point.y - frame.minY, -1), frame.height + 1))
                return (index, blocks[index].hitTest(local))
            }
        }
        return (blocks.count - 1, blocks[blocks.count - 1].plainLength)
    }

    func toggleHit(_ point: CGPoint) -> Int? {
        for index in blocks.indices {
            if let rect = blocks[index].toggleRect, rect.offsetBy(dx: origins[index].x, dy: origins[index].y).contains(point) {
                return index
            }
        }
        return nil
    }

    /// Index of the block containing (or next below) item-local y.
    func blockIndex(atY y: CGFloat) -> Int {
        guard !blocks.isEmpty else { return 0 }
        return blocks.indices.first { blockFrame($0).maxY > y } ?? blocks.count - 1
    }

    func draw(in context: CGContext, dirty: CGRect, selection: SpikeRowSelection?, find: (block: Int, range: Range<Int>)?,
              images: (Int) -> CGImage?) {
        if let bubble, bubble.intersects(dirty) {
            context.setFillColor(theme.userBubble)
            context.addPath(CGPath(roundedRect: bubble, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.fillPath()
        }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for index in blocks.indices {
            let frame = blockFrame(index)
            guard frame.minY <= dirty.maxY + 1, frame.maxY >= dirty.minY - 1 else { continue }
            let block = blocks[index]
            let clip = dirty.offsetBy(dx: -frame.minX, dy: -frame.minY)
            context.saveGState()
            context.translateBy(x: frame.minX, y: frame.minY)
            for decoration in block.decorations where decoration.rect.intersects(clip.insetBy(dx: -2, dy: -2)) {
                let path = CGPath(roundedRect: decoration.rect, cornerWidth: decoration.radius,
                                  cornerHeight: decoration.radius, transform: nil)
                if let fill = decoration.fill {
                    context.setFillColor(fill)
                    context.addPath(path)
                    context.fillPath()
                }
                if let stroke = decoration.stroke {
                    context.setStrokeColor(stroke)
                    context.setLineWidth(1)
                    context.addPath(path)
                    context.strokePath()
                }
            }
            if let find, find.block == index {
                context.setFillColor(theme.findHighlight)
                for rect in block.selectionRects(find.range, clip: clip) { context.fill(rect) }
            }
            if let range = selection?.range(forBlock: index, length: block.plainLength) {
                context.setFillColor(theme.selection)
                for rect in block.selectionRects(range, clip: clip) { context.fill(rect) }
            }
            if let image = block.image {
                if let cgImage = images(image.id) {
                    context.saveGState()
                    context.translateBy(x: image.rect.minX, y: image.rect.maxY)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(cgImage, in: CGRect(origin: .zero, size: image.rect.size))
                    context.restoreGState()
                }
                if selection?.range(forBlock: index, length: block.plainLength) != nil {
                    context.setFillColor(theme.selection.copy(alpha: 0.55) ?? theme.selection)
                    context.fill(image.rect)
                }
            }
            for (line, point) in block.labels {
                context.textPosition = point
                CTLineDraw(line, context)
            }
            for fragment in block.fragments where fragment.frame.intersects(clip.insetBy(dx: -1, dy: -1)) {
                context.saveGState()
                context.translateBy(x: fragment.origin.x, y: fragment.origin.y)
                fragment.draw(in: context, clip: clip.offsetBy(dx: -fragment.origin.x, dy: -fragment.origin.y))
                context.restoreGState()
            }
            context.restoreGState()
        }
    }
}

// MARK: Engine

public struct SpikeLayoutInput: Sendable {
    public var item: SpikeItem
    /// Pre-parsed blocks (the streaming tail passes its own); parsed from `item` when nil.
    public var blocks: [SpikeBlock]?
    public var ui: SpikeItemUIState
    public var imageSizes: [Int: CGSize]
    public var width: CGFloat
    public var theme: SpikeTheme

    public var key: SpikeLayoutKey {
        SpikeLayoutKey(id: item.id, revision: item.revision, uiVersion: ui.version, width: Int(width.rounded()))
    }
}

public enum SpikeLayoutEngine {
    @concurrent
    public static func layout(_ input: SpikeLayoutInput) async -> sending SpikeItemLayout {
        layoutNow(input, fonts: SpikeFonts(theme: input.theme))
    }

    /// Synchronous layout (also the fallback used on the main actor when a visible row has no layout yet).
    static func layoutNow(_ input: SpikeLayoutInput, fonts: SpikeFonts) -> SpikeItemLayout {
        let blocks = input.blocks ?? SpikeMarkdown.blocks(for: input.item)
        let layouts = layoutBlocks(blocks, startIndex: 0, ui: input.ui, imageSizes: input.imageSizes,
                                   contentWidth: contentWidth(input.width, role: input.item.role), fonts: fonts)
        return SpikeItemLayout(key: input.key, blocks: layouts, isUser: input.item.role == .user, width: input.width,
                               theme: input.theme)
    }

    public static func contentWidth(_ width: CGFloat, role: SpikeRole) -> CGFloat {
        max(160, width - 2 * SpikeTheme.horizontalInset - (role == .user ? 24 : 0))
    }

    /// Exact heights for a batch of items (measure-all pass). Discards the layouts.
    @concurrent
    public static func measure(_ inputs: [SpikeLayoutInput]) async -> [(key: SpikeLayoutKey, height: CGFloat)] {
        guard let first = inputs.first else { return [] }
        let fonts = SpikeFonts(theme: first.theme)
        var result: [(SpikeLayoutKey, CGFloat)] = []
        result.reserveCapacity(inputs.count)
        for input in inputs {
            if Task.isCancelled { break }
            result.append((input.key, layoutNow(input, fonts: fonts).height))
        }
        return result
    }

    /// Cheap height estimate without typesetting (used until a row is measured).
    public static func estimate(_ item: SpikeItem, width: CGFloat) -> CGFloat {
        let charsPerLine = max(20, contentWidth(width, role: item.role) / 7.0)
        var height = 2 * SpikeTheme.verticalPadding + (item.role == .user ? 16 : 0)
        let mono: CGFloat = 17
        for part in item.parts {
            switch part {
            case .markdown(let text):
                var lines = 0
                var fenced = false
                var paragraphChars = 0
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    if line.hasPrefix("```") { fenced.toggle(); height += fenced ? 16 : 0; continue }
                    if fenced { height += mono; continue }
                    if line.isEmpty {
                        if paragraphChars > 0 { lines += Int(ceil(Double(paragraphChars) / charsPerLine)); height += 8 }
                        paragraphChars = 0
                    } else if line.hasPrefix("|") {
                        height += 24
                    } else {
                        paragraphChars += line.utf8.count
                    }
                }
                lines += Int(ceil(Double(paragraphChars) / charsPerLine))
                height += CGFloat(lines) * 18
            case .tool(let tool):
                height += 34 + (tool.expandedByDefault ? CGFloat(tool.output.utf8.count / 30 + 1) * mono : 0)
            case .reasoning:
                height += 34
            case .diff(let text):
                height += 16 + CGFloat(text.utf8.count / 40) * mono
            case .image:
                height += 52
            }
            height += SpikeTheme.blockSpacing
        }
        return ceil(height)
    }

    static func layoutBlocks(_ blocks: [SpikeBlock], startIndex: Int, ui: SpikeItemUIState, imageSizes: [Int: CGSize],
                             contentWidth: CGFloat, fonts: SpikeFonts) -> [SpikeBlockLayout] {
        blocks.enumerated().map { offset, block in
            let index = startIndex + offset
            let expanded = block.defaultExpanded != ui.toggled.contains(index)
            return layoutBlock(block, expanded: expanded, imageSizes: imageSizes, width: contentWidth, fonts: fonts)
        }
    }

    static func layoutBlock(_ block: SpikeBlock, expanded: Bool, imageSizes: [Int: CGSize], width: CGFloat,
                            fonts: SpikeFonts) -> SpikeBlockLayout {
        let theme = fonts.theme
        switch block {
        case .prose(let styled, let kind):
            var base: SpikeTextStyle = .body
            var x: CGFloat = 0
            var hang: CGFloat = 0
            var extraTop: CGFloat = 0
            switch kind {
            case .heading(let level):
                base = level <= 1 ? .heading1 : level == 2 ? .heading2 : .heading3
                extraTop = 4
            case .listItem(let level, let marker):
                x = CGFloat(level) * 18 + 4
                hang = -1 - CGFloat(marker)  // resolved below from the first line
            case .paragraph:
                break
            }
            let fragment = prose(fonts.attributed(styled, base: base), origin: CGPoint(x: x, y: extraTop), textStart: 0,
                                 width: width - x, hangUTF16: hang < 0 ? Int(-hang - 1) : 0)
            if case .listItem = kind {
                return SpikeBlockLayout(size: CGSize(width: width, height: fragment.height + extraTop),
                                        plainLength: styled.utf16Count, fragments: [fragment], isListItem: true)
            }
            return SpikeBlockLayout(size: CGSize(width: width, height: fragment.height + extraTop),
                                    plainLength: styled.utf16Count, fragments: [fragment])

        case .code(let mono), .diff(let mono):
            let lines = SpikeMonoLines(mono: mono, fonts: fonts)
            let height = CGFloat(lines.lineCount) * lines.lineHeight
            let fragment = SpikeFragment(origin: CGPoint(x: 12, y: 8), textStart: 0, length: mono.utf16Count,
                                         width: width - 24, height: height, content: .mono(lines))
            let size = CGSize(width: width, height: height + 16)
            return SpikeBlockLayout(size: size, plainLength: mono.utf16Count, fragments: [fragment],
                                    decorations: [SpikeDecoration(rect: CGRect(origin: .zero, size: size),
                                                                  fill: theme.codeBackground, stroke: nil, radius: 6)])

        case .table(let table):
            return layoutTable(table, width: width, fonts: fonts)

        case .tool(_, let output):
            let header = block.headerText(expanded: expanded)
            let headerStyled = SpikeStyledText(text: header, runs: [])
            let attributed = NSMutableAttributedString(attributedString: fonts.attributed(headerStyled, base: .toolTitle))
            if case .tool(let tool, _) = block, let range = header.range(of: "·  \(tool.status.rawValue)") {
                attributed.setAttributes(fonts.attributes(tool.status == .error ? .statusError : .statusOK),
                                         range: NSRange(range, in: header))
            }
            let headerFragment = prose(attributed, origin: CGPoint(x: 10, y: 7), textStart: 0, width: width - 20, hangUTF16: 0)
            var fragments = [headerFragment]
            var height = headerFragment.height + 14
            var decorations: [SpikeDecoration] = []
            if expanded {
                let lines = SpikeMonoLines(mono: output, fonts: fonts)
                let outputHeight = CGFloat(lines.lineCount) * lines.lineHeight
                let outputRect = CGRect(x: 1, y: height - 2, width: width - 2, height: outputHeight + 12)
                decorations.append(SpikeDecoration(rect: outputRect, fill: theme.codeBackground, stroke: nil))
                fragments.append(SpikeFragment(origin: CGPoint(x: 12, y: height + 4), textStart: header.utf16.count + 1,
                                               length: output.utf16Count, width: width - 24, height: outputHeight,
                                               content: .mono(lines)))
                height += outputHeight + 10
            }
            let size = CGSize(width: width, height: height)
            decorations.insert(SpikeDecoration(rect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
                                               fill: theme.cardBackground, stroke: theme.cardStroke, radius: 6), at: 0)
            return SpikeBlockLayout(size: size, plainLength: block.plainText(expanded: expanded).utf16.count,
                                    fragments: fragments, decorations: decorations,
                                    toggleRect: CGRect(x: 0, y: 0, width: width, height: headerFragment.height + 14))

        case .reasoning(let text):
            let header = block.headerText(expanded: expanded)
            let headerFragment = prose(fonts.attributed(SpikeStyledText(text: header), base: .mutedItalic),
                                       origin: CGPoint(x: 0, y: 2), textStart: 0, width: width, hangUTF16: 0)
            var fragments = [headerFragment]
            var height = headerFragment.height + 4
            var decorations: [SpikeDecoration] = []
            if expanded {
                let body = prose(fonts.attributed(text, base: .mutedItalic), origin: CGPoint(x: 14, y: height + 4),
                                 textStart: header.utf16.count + 1, width: width - 14, hangUTF16: 0)
                decorations.append(SpikeDecoration(rect: CGRect(x: 2, y: height + 4, width: 3, height: body.height),
                                                   fill: theme.cardStroke, stroke: nil))
                fragments.append(body)
                height += body.height + 6
            }
            return SpikeBlockLayout(size: CGSize(width: width, height: height),
                                    plainLength: block.plainText(expanded: expanded).utf16.count, fragments: fragments,
                                    decorations: decorations,
                                    toggleRect: CGRect(x: 0, y: 0, width: min(width, 320), height: headerFragment.height + 4))

        case .image(let ref):
            let plain = block.plainText(expanded: true).utf16.count
            if let size = imageSizes[ref.imageID] {
                let scale = min(1, (width) / (size.width / 2), 360 / (size.height / 2))
                let rect = CGRect(x: 0, y: 0, width: floor(size.width / 2 * scale), height: floor(size.height / 2 * scale))
                return SpikeBlockLayout(size: CGSize(width: width, height: rect.height), plainLength: plain, fragments: [],
                                        decorations: [SpikeDecoration(rect: rect, fill: nil, stroke: theme.cardStroke, radius: 0)],
                                        image: (ref.imageID, rect))
            }
            let rect = CGRect(x: 0, y: 0, width: min(width, 220), height: 44)
            let label = CTLineCreateWithAttributedString(fonts.attributed(SpikeStyledText(text: "Loading image…"), base: .muted))
            return SpikeBlockLayout(size: CGSize(width: width, height: rect.height), plainLength: plain, fragments: [],
                                    decorations: [SpikeDecoration(rect: rect.insetBy(dx: 0.5, dy: 0.5), fill: theme.cardBackground,
                                                                  stroke: theme.cardStroke, radius: 6)],
                                    labels: [(label, CGPoint(x: 14, y: 27))])
        }
    }

    /// Wrapped prose with CTTypesetter. `hangUTF16`: wrapped lines start at the x of this offset (list markers).
    static func prose(_ attributed: NSAttributedString, origin: CGPoint, textStart: Int, width: CGFloat,
                      hangUTF16: Int) -> SpikeFragment {
        let length = attributed.length
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [SpikeLine] = []
        var start = 0
        var y: CGFloat = 0
        var hang: CGFloat = 0
        let available = max(40, width)
        repeat {
            let lineWidth = lines.isEmpty ? available : max(40, available - hang)
            var count = length > 0 ? CTTypesetterSuggestLineBreak(typesetter, start, Double(lineWidth)) : 0
            if count == 0 && start < length { count = 1 }
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            if length == 0 { ascent = 12; descent = 4 }
            let height = ceil(ascent + descent + max(leading, 0)) + 4
            if lines.isEmpty && hangUTF16 > 0 {
                hang = CTLineGetOffsetForStringIndex(line, hangUTF16, nil)
            }
            lines.append(SpikeLine(line: line, x: lines.isEmpty ? 0 : hang, top: y, baseline: y + 2 + ceil(ascent),
                                   height: height, range: start..<(start + count)))
            y += height
            start += count
        } while start < length
        return SpikeFragment(origin: origin, textStart: textStart, length: length, width: available, height: y,
                             content: .lines(lines))
    }

    static func layoutTable(_ table: SpikeTable, width: CGFloat, fonts: SpikeFonts) -> SpikeBlockLayout {
        let theme = fonts.theme
        let columns = table.header.count
        let allRows = [table.header] + table.rows
        let padding: CGFloat = 8
        var natural = [CGFloat](repeating: 40, count: columns)
        for (rowIndex, row) in allRows.enumerated() {
            for (column, cell) in row.enumerated() where column < columns {
                let line = CTLineCreateWithAttributedString(fonts.attributed(cell, base: rowIndex == 0 ? .strong : .body))
                natural[column] = max(natural[column], min(320, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 2 * padding + 2))
            }
        }
        var widths = natural
        let total = natural.reduce(0, +)
        if total > width {
            widths = natural.map { max(60, floor($0 * width / total)) }
        }
        var fragments: [SpikeFragment] = []
        var decorations: [SpikeDecoration] = []
        var y: CGFloat = 0
        var textOffset = 0
        for (rowIndex, row) in allRows.enumerated() {
            var x: CGFloat = 0
            var rowFragments: [SpikeFragment] = []
            for column in 0..<columns {
                let cell = column < row.count ? row[column] : SpikeStyledText(text: "")
                let fragment = prose(fonts.attributed(cell, base: rowIndex == 0 ? .strong : .body),
                                     origin: CGPoint(x: x + padding, y: y + 4), textStart: textOffset,
                                     width: widths[column] - 2 * padding, hangUTF16: 0)
                rowFragments.append(fragment)
                textOffset += cell.utf16Count + 1  // \t or \n
                x += widths[column]
            }
            let rowHeight = (rowFragments.map(\.height).max() ?? 16) + 8
            if rowIndex == 0 {
                decorations.append(SpikeDecoration(rect: CGRect(x: 0, y: y, width: x, height: rowHeight), fill: theme.cardBackground,
                                                   stroke: nil))
            }
            decorations.append(SpikeDecoration(rect: CGRect(x: 0, y: y + rowHeight - 0.5, width: x, height: 0.5),
                                               fill: theme.cardStroke, stroke: nil))
            fragments += rowFragments
            y += rowHeight
        }
        let tableWidth = widths.reduce(0, +)
        decorations.append(SpikeDecoration(rect: CGRect(x: 0.5, y: 0.5, width: tableWidth - 1, height: y - 1), fill: nil,
                                           stroke: theme.cardStroke, radius: 4))
        return SpikeBlockLayout(size: CGSize(width: width, height: y), plainLength: max(0, textOffset - 1),
                                fragments: fragments, decorations: decorations)
    }
}
