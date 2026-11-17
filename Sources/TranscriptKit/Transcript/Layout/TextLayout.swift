import AppKit
import CoreText

/// One typeset line of prose.
struct TextLine {
    let line: CTLine
    let x: CGFloat
    let top: CGFloat
    let baseline: CGFloat
    let height: CGFloat
    /// Fragment-local UTF-16 range.
    let range: Range<Int>
}

/// Lazily created, never-wrapping monospaced lines: height is `lines × lineHeight` (no typesetting to measure), and
/// CTLines are made only for lines that are drawn or hit-tested. A 100 KB code block costs O(lines) arithmetic to
/// measure and ~60 lines to draw. Owned by the main actor after handoff.
final class MonoLines {
    let text: NSString
    let lineStarts: [Int]
    let runs: [TokenRun]
    let lineHeight: CGFloat
    let ascent: CGFloat
    let advance: CGFloat
    /// Width of the longest line (estimated from columns; tabs count four).
    let contentWidth: CGFloat
    private let fonts: TranscriptFonts
    private let baseColor: CGColor
    private var cache: [Int: CTLine] = [:]
    private var cacheOrder: [Int] = []

    init(text: String, runs: [TokenRun], fonts: TranscriptFonts, color: CGColor? = nil) {
        let ns = text as NSString
        self.text = ns
        var starts = [0]
        var columns = 0
        var maxColumns = 0
        let length = ns.length
        var index = 0
        // Walking UTF-16 directly keeps this O(n) without bridging per character.
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: max(1, length))
        ns.getCharacters(buffer, range: NSRange(location: 0, length: length))
        while index < length {
            let unit = buffer[index]
            index += 1
            if unit == 10 {
                starts.append(index)
                maxColumns = max(maxColumns, columns)
                columns = 0
            } else {
                columns += unit == 9 ? 4 : 1
            }
        }
        buffer.deallocate()
        maxColumns = max(maxColumns, columns)
        lineStarts = starts
        self.runs = runs
        lineHeight = fonts.monoLineHeight
        ascent = fonts.monoAscent
        advance = fonts.monoAdvance
        contentWidth = ceil(CGFloat(min(maxColumns, TranscriptTheme.maxDisplayLineUTF16)) * fonts.monoAdvance) + 2
        self.fonts = fonts
        baseColor = color ?? fonts.theme.text
    }

    var lineCount: Int { lineStarts.count }
    var height: CGFloat { CGFloat(lineCount) * lineHeight }

    /// Line range excluding the newline.
    func lineRange(_ index: Int) -> Range<Int> {
        let start = lineStarts[index]
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] - 1 : text.length
        return start..<max(start, end)
    }

    func lineIndex(forOffset offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func line(_ index: Int) -> CTLine {
        if let cached = cache[index] { return cached }
        let range = lineRange(index)
        let displayLength = min(range.count, TranscriptTheme.maxDisplayLineUTF16)
        let string = text.substring(with: NSRange(location: range.lowerBound, length: displayLength))
        let attributed = NSMutableAttributedString(string: string, attributes: fonts.attributes(font: fonts.mono, color: baseColor))
        let style = Self.tabStyle(advance: advance)
        attributed.addAttribute(TranscriptFonts.paragraphKey, value: style, range: NSRange(location: 0, length: displayLength))
        // Runs overlapping this line (runs are sorted by location).
        var low = 0
        var high = runs.count
        while low < high {
            let mid = (low + high) / 2
            if runs[mid].location + runs[mid].length <= range.lowerBound { low = mid + 1 } else { high = mid }
        }
        var cursor = low
        let lineEnd = range.lowerBound + displayLength
        while cursor < runs.count, runs[cursor].location < lineEnd {
            let run = runs[cursor]
            let start = max(run.location, range.lowerBound)
            let end = min(run.location + run.length, lineEnd)
            if end > start {
                let font = run.kind == .diffHeader ? fonts.monoBold : fonts.mono
                attributed.addAttributes(
                    fonts.attributes(font: font, color: fonts.theme.color(for: run.kind)),
                    range: NSRange(location: start - range.lowerBound, length: end - start))
            }
            cursor += 1
        }
        let line = CTLineCreateWithAttributedString(attributed)
        cache[index] = line
        cacheOrder.append(index)
        if cacheOrder.count > 600 {  // bounded: drop the oldest half
            for old in cacheOrder.prefix(300) { cache[old] = nil }
            cacheOrder.removeFirst(300)
        }
        return line
    }

    private static func tabStyle(advance: CGFloat) -> CTParagraphStyle {
        var interval = advance * 4
        return withUnsafeBytes(of: &interval) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: pointer.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
    }
}

/// A run of selectable text inside a block: wrapped prose lines, or monospaced lines.
final class Fragment {
    enum Content {
        case lines([TextLine])
        case mono(MonoLines)
    }

    let origin: CGPoint
    /// Offset of this fragment's text in the block's plain text.
    let textStart: Int
    let length: Int
    let width: CGFloat
    let height: CGFloat
    let content: Content
    /// Moves with the block's scroll offset (code, tables, tool output).
    let scrolls: Bool
    /// Fragment-local ranges drawn with a rounded fill (inline code, mentions).
    let fills: [(range: Range<Int>, color: CGColor)]
    let strikes: [Range<Int>]
    let strikeColor: CGColor?
    let links: [(range: Range<Int>, url: String)]
    /// Prose text (to keep hit-testing off trailing newlines).
    let string: NSString?

    init(
        origin: CGPoint, textStart: Int, length: Int, width: CGFloat, height: CGFloat, content: Content,
        scrolls: Bool = false, fills: [(range: Range<Int>, color: CGColor)] = [], strikes: [Range<Int>] = [],
        strikeColor: CGColor? = nil, links: [(range: Range<Int>, url: String)] = [], string: NSString? = nil
    ) {
        self.origin = origin
        self.textStart = textStart
        self.length = length
        self.width = width
        self.height = height
        self.content = content
        self.scrolls = scrolls
        self.fills = fills
        self.strikes = strikes
        self.strikeColor = strikeColor
        self.links = links
        self.string = string
    }

    var frame: CGRect { CGRect(origin: origin, size: CGSize(width: width, height: height)) }

    /// Fragment-local point → fragment-local UTF-16 offset.
    func hitTest(_ point: CGPoint) -> Int {
        if point.y < 0 { return 0 }
        if point.y >= height { return length }
        switch content {
        case .lines(let lines):
            guard let line = lines.first(where: { point.y < $0.top + $0.height }) ?? lines.last else { return 0 }
            if point.x <= line.x { return line.range.lowerBound }
            let index = CTLineGetStringIndexForPosition(line.line, CGPoint(x: point.x - line.x, y: 0))
            if index == kCFNotFound { return line.range.lowerBound }
            // Never land after a line's trailing newline.
            var upper = line.range.upperBound
            if let string, upper > line.range.lowerBound, upper <= string.length, string.character(at: upper - 1) == 10 { upper -= 1 }
            return min(max(index, line.range.lowerBound), upper)
        case .mono(let mono):
            let lineIndex = min(mono.lineCount - 1, max(0, Int(point.y / mono.lineHeight)))
            let range = mono.lineRange(lineIndex)
            let index = CTLineGetStringIndexForPosition(mono.line(lineIndex), CGPoint(x: max(0, point.x), y: 0))
            let local = index == kCFNotFound ? 0 : index
            return range.lowerBound + min(max(0, local), range.count)
        }
    }

    /// Fragment-local rects for a fragment-local range, limited to `clip`. `extendsPastEnd`: the selection continues
    /// after this fragment, so the last line's highlight runs to the fragment's right edge.
    func rects(_ range: Range<Int>, clip: CGRect, extendsPastEnd: Bool, toEdge: Bool = true) -> [CGRect] {
        var rects: [CGRect] = []
        switch content {
        case .lines(let lines):
            for (index, line) in lines.enumerated() where line.top + line.height >= clip.minY && line.top <= clip.maxY {
                let continues = range.upperBound > line.range.upperBound || (extendsPastEnd && index == lines.count - 1 && range.upperBound >= line.range.upperBound)
                let lo = max(range.lowerBound, line.range.lowerBound)
                let hi = min(range.upperBound, line.range.upperBound)
                guard lo < hi || (toEdge && continues && lo <= line.range.upperBound && range.lowerBound <= line.range.upperBound) else { continue }
                let x0 = CTLineGetOffsetForStringIndex(line.line, lo, nil)
                let lineEnd = CGFloat(CTLineGetTypographicBounds(line.line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line.line))
                let x1 = continues ? (toEdge ? max(width - line.x, x0 + 4) : max(lineEnd, x0 + 1)) : CTLineGetOffsetForStringIndex(line.line, hi, nil)
                rects.append(CGRect(x: line.x + x0, y: line.top, width: max(1, x1 - x0), height: line.height))
            }
        case .mono(let mono):
            guard mono.lineCount > 0 else { return [] }
            let first = max(0, Int(clip.minY / mono.lineHeight))
            let last = min(mono.lineCount - 1, Int(clip.maxY / mono.lineHeight))
            guard first <= last else { return [] }
            for index in first...last {
                let lineRange = mono.lineRange(index)
                let lo = max(range.lowerBound, lineRange.lowerBound)
                let hi = min(range.upperBound, lineRange.upperBound)
                let continues = range.upperBound > lineRange.upperBound || (extendsPastEnd && index == mono.lineCount - 1)
                guard lo <= hi, range.lowerBound <= lineRange.upperBound, range.upperBound >= lineRange.lowerBound,
                    !(range.upperBound == lineRange.lowerBound && lineRange.count > 0 && !continues)
                else { continue }
                if lo == hi && !continues { continue }
                let line = mono.line(index)
                let cap = TranscriptTheme.maxDisplayLineUTF16
                let x0 = CTLineGetOffsetForStringIndex(line, min(lo - lineRange.lowerBound, cap), nil)
                let x1 = continues
                    ? max(x0 + mono.advance, CTLineGetOffsetForStringIndex(line, min(lineRange.count, cap), nil) + mono.advance)
                    : CTLineGetOffsetForStringIndex(line, min(hi - lineRange.lowerBound, cap), nil)
                rects.append(CGRect(x: x0, y: CGFloat(index) * mono.lineHeight, width: max(2, x1 - x0), height: mono.lineHeight))
            }
        }
        return rects
    }

    /// Fragment-local rect of the line holding a fragment-local offset.
    func rect(forOffset offset: Int) -> CGRect {
        switch content {
        case .lines(let lines):
            let line = lines.first(where: { $0.range.contains(offset) }) ?? lines.last
            guard let line else { return CGRect(x: 0, y: 0, width: width, height: 16) }
            let x = CTLineGetOffsetForStringIndex(line.line, offset, nil)
            return CGRect(x: line.x + x, y: line.top, width: 1, height: line.height)
        case .mono(let mono):
            let index = mono.lineIndex(forOffset: offset)
            let range = mono.lineRange(index)
            let x = CTLineGetOffsetForStringIndex(mono.line(index), min(offset - range.lowerBound, TranscriptTheme.maxDisplayLineUTF16), nil)
            return CGRect(x: x, y: CGFloat(index) * mono.lineHeight, width: 1, height: mono.lineHeight)
        }
    }

    func link(at offset: Int) -> String? { links.first { $0.range.contains(offset) }?.url }

    func draw(in context: CGContext, clip: CGRect) {
        for fill in fills {
            context.setFillColor(fill.color)
            for rect in rects(fill.range, clip: clip, extendsPastEnd: false, toEdge: false) {
                let padded = rect.insetBy(dx: -2, dy: 1.5)
                context.addPath(CGPath(roundedRect: padded, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
                context.fillPath()
            }
        }
        switch content {
        case .lines(let lines):
            for line in lines where line.top + line.height >= clip.minY && line.top <= clip.maxY {
                context.textPosition = CGPoint(x: line.x, y: line.baseline)
                CTLineDraw(line.line, context)
            }
            for strike in strikes {
                for rect in rects(strike, clip: clip, extendsPastEnd: false, toEdge: false) {
                    context.setFillColor(strikeColor ?? CGColor(gray: 0.5, alpha: 1))
                    context.fill(CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: 1))
                }
            }
        case .mono(let mono):
            guard mono.lineCount > 0 else { return }
            let first = max(0, Int(clip.minY / mono.lineHeight))
            let last = min(mono.lineCount - 1, Int(clip.maxY / mono.lineHeight))
            guard first <= last else { return }
            for index in first...last {
                context.textPosition = CGPoint(x: 0, y: CGFloat(index) * mono.lineHeight + mono.ascent + 2)
                CTLineDraw(mono.line(index), context)
            }
        }
    }
}

enum ProseTypesetter {
    /// Wraps `attributed` to `width`. `hangUTF16`: continuation lines start at the x of this offset (list markers).
    static func layout(
        _ attributed: NSAttributedString, origin: CGPoint, textStart: Int, width: CGFloat, hangUTF16: Int = 0,
        lineSpacing: CGFloat = 3, scrolls: Bool = false, fills: [(range: Range<Int>, color: CGColor)] = [],
        strikes: [Range<Int>] = [], strikeColor: CGColor? = nil, links: [(range: Range<Int>, url: String)] = [],
        truncate: Bool = false, fallbackFont: CTFont? = nil
    ) -> Fragment {
        let length = attributed.length
        let available = max(24, width)
        if truncate {
            // One line, truncated in the middle when too long.
            let full = CTLineCreateWithAttributedString(attributed)
            let token = CTLineCreateWithAttributedString(NSAttributedString(
                string: "…", attributes: length > 0 ? attributed.attributes(at: max(0, length - 1), effectiveRange: nil) : [:]))
            let line = CTLineCreateTruncatedLine(full, Double(available), .middle, token) ?? full
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(full, &ascent, &descent, &leading)
            if length == 0, let font = fallbackFont { ascent = CTFontGetAscent(font); descent = CTFontGetDescent(font) }
            let height = ceil(ascent + descent) + lineSpacing + 1
            let text = TextLine(line: line, x: 0, top: 0, baseline: ceil(ascent) + lineSpacing / 2, height: height, range: 0..<length)
            return Fragment(
                origin: origin, textStart: textStart, length: length, width: available, height: height,
                content: .lines([text]), scrolls: scrolls, fills: fills, strikes: strikes, strikeColor: strikeColor,
                links: links, string: attributed.string as NSString)
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [TextLine] = []
        var start = 0
        var y: CGFloat = 0
        var hang: CGFloat = 0
        repeat {
            let lineWidth = lines.isEmpty ? available : max(24, available - hang)
            var count = length > 0 ? CTTypesetterSuggestLineBreak(typesetter, start, Double(lineWidth)) : 0
            if count == 0 && start < length { count = 1 }
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            if length == 0 {
                ascent = fallbackFont.map { CTFontGetAscent($0) } ?? 12
                descent = fallbackFont.map { CTFontGetDescent($0) } ?? 4
            }
            let height = ceil(ascent + descent + max(leading, 0)) + lineSpacing
            if lines.isEmpty && hangUTF16 > 0 { hang = CTLineGetOffsetForStringIndex(line, hangUTF16, nil) }
            lines.append(
                TextLine(
                    line: line, x: lines.isEmpty ? 0 : hang, top: y, baseline: y + lineSpacing / 2 + ceil(ascent),
                    height: height, range: start..<(start + count)))
            y += height
            start += count
        } while start < length
        return Fragment(
            origin: origin, textStart: textStart, length: length, width: available, height: y, content: .lines(lines),
            scrolls: scrolls, fills: fills, strikes: strikes, strikeColor: strikeColor, links: links,
            string: attributed.string as NSString)
    }

    /// Natural single-line width of `attributed`.
    static func width(_ attributed: NSAttributedString) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line)))
    }

    /// Fills, strikes and links derived from a styled text's runs.
    static func decorations(_ styled: StyledText, theme: TranscriptTheme) -> (
        fills: [(range: Range<Int>, color: CGColor)], strikes: [Range<Int>], links: [(range: Range<Int>, url: String)]
    ) {
        var fills: [(range: Range<Int>, color: CGColor)] = []
        var strikes: [Range<Int>] = []
        var links: [(range: Range<Int>, url: String)] = []
        for run in styled.runs where run.location + run.length <= styled.utf16Count {
            if run.traits.contains(.code) { fills.append((run.range, theme.inlineCodeFill)) }
            if run.traits.contains(.mention) { fills.append((run.range, theme.mentionFill)) }
            if run.traits.contains(.strike) { strikes.append(run.range) }
            if let link = run.link { links.append((run.range, link)) }
        }
        return (fills, strikes, links)
    }
}
