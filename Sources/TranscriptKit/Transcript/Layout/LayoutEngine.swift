import AppKit
import BelloCore
import CoreText

/// Everything needed to lay out one row, as a `Sendable` value.
public struct RowLayoutInput: Sendable {
    public var row: TranscriptRow
    public var ui: RowUIState
    /// The text column's width (the row is centred in the table by the view).
    public var width: CGFloat
    public var theme: TranscriptTheme
    public var topPadding: CGFloat
    /// Known pixel sizes of images by source, for reserved heights.
    public var imageSizes: [String: CGSize]
    /// Pre-parsed blocks (cache hit or streaming); parsed here when nil.
    public var blocks: [RenderBlock]?
    public var highlighter: any HighlightService
    /// Shared parse cache (finished rows are parsed once).
    public var cache: RenderBlockCache?

    public var key: LayoutKey {
        LayoutKey(
            rowID: row.id, version: row.version, uiVersion: ui.version, width: Int(width.rounded()),
            themeRevision: theme.revision, topPadding: Int(topPadding.rounded()))
    }
}

/// CoreText layout of rows and blocks. Pure functions of their inputs; run off the main actor.
public enum LayoutEngine {
    @concurrent
    public static func layout(_ input: RowLayoutInput) async -> sending RowLayout {
        layoutNow(input, fonts: TranscriptFonts(theme: input.theme))
    }

    static func layoutNow(_ input: RowLayoutInput, fonts: TranscriptFonts) -> RowLayout {
        let blocks = input.blocks ?? input.cache?.blocks(for: input.row) ?? RenderBlocks.blocks(for: input.row)
        let layouts = layoutBlocks(
            blocks, content: input.row.content, ui: input.ui, imageSizes: input.imageSizes, width: input.width, fonts: fonts,
            highlighter: input.highlighter)
        return RowLayout(key: input.key, blocks: layouts, width: input.width, topPadding: input.topPadding, theme: input.theme)
    }

    /// Exact heights for a batch of rows (the measure-all pass). Discards the layouts.
    @concurrent
    public static func measure(_ inputs: [RowLayoutInput]) async -> [(key: LayoutKey, height: CGFloat)] {
        guard let first = inputs.first else { return [] }
        let fonts = TranscriptFonts(theme: first.theme)
        var result: [(LayoutKey, CGFloat)] = []
        result.reserveCapacity(inputs.count)
        for input in inputs {
            if Task.isCancelled { break }
            result.append((input.key, layoutNow(input, fonts: fonts).height))
        }
        return result
    }

    static func layoutBlocks(
        _ blocks: [RenderBlock], content: RowContent, ui: RowUIState, imageSizes: [String: CGSize], width: CGFloat,
        fonts: TranscriptFonts, highlighter: any HighlightService
    ) -> [BlockLayout] {
        let nested: Bool = if case .work(let group) = content { group.isCollapsible } else { false }
        return blocks.map { block in
            guard RenderBlocks.isVisible(block, content: content, ui: ui) else {
                return BlockLayout.hidden(kindTag: tag(block))
            }
            return layoutBlock(
                block, content: content, ui: ui, nested: nested, imageSizes: imageSizes, width: width, fonts: fonts,
                highlighter: highlighter)
        }
    }

    static func tag(_ block: RenderBlock) -> BlockLayout.KindTag {
        switch block.kind {
        case .toolHeader, .groupSummary, .reasoningHeader: .tool
        case .toolDetail: .toolDetail
        case .markdown(let markdown, _): markdown.isListItem ? .list : .prose
        default: .other
        }
    }

    // MARK: Blocks

    static func layoutBlock(
        _ block: RenderBlock, content: RowContent, ui: RowUIState, nested: Bool, imageSizes: [String: CGSize],
        width: CGFloat, fonts: TranscriptFonts, highlighter: any HighlightService
    ) -> BlockLayout {
        let theme = fonts.theme
        switch block.kind {
        case .markdown(let markdown, let tone):
            return layoutMarkdown(markdown, tone: tone, imageSizes: imageSizes, width: width, fonts: fonts, highlighter: highlighter)

        case .user(let user):
            return layoutUser(user, imageSizes: imageSizes, width: width, fonts: fonts)

        case .reasoningHeader(let reasoning):
            let expanded = RenderBlocks.isExpanded(.reasoning, content: content, ui: ui)
            return disclosureLine(
                RenderBlocks.reasoningText(reasoning), key: .reasoning, expanded: expanded, x: 0, width: width, fonts: fonts,
                label: expanded ? "Hide reasoning" : "Show reasoning")

        case .groupSummary(let group):
            let expanded = RenderBlocks.isExpanded(.group, content: content, ui: ui)
            return disclosureLine(
                RenderBlocks.summaryText(group), key: .group, expanded: expanded, x: 0, width: width, fonts: fonts,
                label: expanded ? "Collapse tool calls" : "Expand tool calls")

        case .toolHeader(let item):
            return layoutToolHeader(item, content: content, ui: ui, nested: nested, width: width, fonts: fonts)

        case .toolDetail(let item):
            let x: CGFloat = (nested ? 18 : 0) + 18
            return layoutToolDetail(item, x: x, width: width - x, fonts: fonts, highlighter: highlighter)

        case .todo(let list):
            return layoutTodo(list, width: width, fonts: fonts)

        case .file(let file):
            return layoutFile(file, imageSizes: imageSizes, width: width, fonts: fonts)

        case .subagent(let card):
            return layoutSubagent(card, width: width, fonts: fonts)

        case .error(let error):
            let text = NSMutableAttributedString(attributedString: fonts.plain(error.title, font: fonts.bold, color: theme.failure))
            text.append(fonts.plain("\n" + error.message, font: fonts.body, color: theme.text))
            let fragment = ProseTypesetter.layout(text, origin: CGPoint(x: 34, y: 9), textStart: 0, width: width - 46)
            let size = CGSize(width: width, height: fragment.height + 18)
            let failureStroke = theme.failure.copy(alpha: theme.increasedContrast ? 0.8 : 0.35) ?? theme.failure
            return BlockLayout(
                size: size, plainLength: fragment.length, fragments: [fragment],
                decorations: [Decoration(rect: CGRect(origin: .zero, size: size), fill: theme.failureFill, stroke: failureStroke, radius: 8)],
                labels: [Label(glyph: .warning, glyphColor: theme.failure, point: .zero, glyphRect: CGRect(x: 11, y: 11, width: 15, height: 14))],
                kindTag: .card)

        case .lifecycle(let event):
            let attributed = fonts.plain(event.text, font: fonts.small, color: theme.secondary)
            let textWidth = min(width - 80, ProseTypesetter.width(attributed) + 1)
            let x = floor((width - textWidth) / 2)
            let fragment = ProseTypesetter.layout(attributed, origin: CGPoint(x: x, y: 4), textStart: 0, width: textWidth, truncate: true)
            let mid = floor(fragment.height / 2) + 4
            let size = CGSize(width: width, height: fragment.height + 8)
            return BlockLayout(
                size: size, plainLength: fragment.length, fragments: [fragment],
                decorations: [
                    Decoration(rect: CGRect(x: 0, y: mid, width: max(0, x - 12), height: 1), fill: theme.separator),
                    Decoration(rect: CGRect(x: x + textWidth + 12, y: mid, width: max(0, width - x - textWidth - 12), height: 1), fill: theme.separator),
                ], kindTag: .other)

        case .working:
            let attributed = fonts.plain("Working…", font: fonts.body, color: theme.secondary)
            let fragment = ProseTypesetter.layout(attributed, origin: CGPoint(x: 20, y: 0), textStart: 0, width: width - 20, truncate: true)
            return BlockLayout(
                size: CGSize(width: width, height: fragment.height), plainLength: fragment.length, fragments: [fragment],
                labels: [Label(glyph: .running, glyphColor: theme.running, point: .zero, glyphRect: glyphRect(fragment, x: 1))],
                kindTag: .tool)

        case .unknown(let type):
            let attributed = fonts.plain("Unsupported content (\(type))", font: fonts.italic, color: theme.tertiary)
            let fragment = ProseTypesetter.layout(attributed, origin: .zero, textStart: 0, width: width)
            return BlockLayout(size: CGSize(width: width, height: fragment.height), plainLength: fragment.length, fragments: [fragment])
        }
    }

    static func glyphRect(_ fragment: Fragment, x: CGFloat, size: CGFloat = 13) -> CGRect {
        CGRect(x: x, y: fragment.origin.y + floor((fragment.height - size) / 2), width: size, height: size)
    }

    // MARK: Markdown

    static func layoutMarkdown(
        _ block: MarkdownBlock, tone: RenderBlock.Tone, imageSizes: [String: CGSize], width: CGFloat, fonts: TranscriptFonts,
        highlighter: any HighlightService
    ) -> BlockLayout {
        let theme = fonts.theme
        let muted = tone == .muted
        let x = CGFloat(block.indent) * TranscriptTheme.indentStep + CGFloat(block.quoteDepth) * TranscriptTheme.quoteStep
            + (muted ? 18 : 0)
        let available = max(80, width - x)
        let color = muted ? theme.secondary : theme.text
        var decorations: [Decoration] = []
        if muted { decorations.append(Decoration(rect: .zero, fill: nil)) }

        func prose(_ styled: StyledText, font: CTFont, bold: Bool = false, hang: Int = 0, topSpacing: CGFloat = 0, tag: BlockLayout.KindTag)
            -> BlockLayout
        {
            let attributed = fonts.attributed(styled, base: font, color: color, baseIsBold: bold)
            let deco = ProseTypesetter.decorations(styled, theme: theme)
            let fragment = ProseTypesetter.layout(
                attributed, origin: CGPoint(x: x, y: 0), textStart: 0, width: available, hangUTF16: hang, fills: deco.fills,
                strikes: deco.strikes, strikeColor: color, links: deco.links, fallbackFont: font)
            var extra: [Decoration] = []
            if muted {
                extra.append(Decoration(rect: CGRect(x: x - 12, y: 0, width: 2, height: fragment.height), fill: theme.separator, radius: 1))
            }
            return BlockLayout(
                size: CGSize(width: width, height: fragment.height), plainLength: fragment.length, fragments: [fragment],
                decorations: extra, isListItem: tag == .list, quoteDepth: block.quoteDepth, topSpacing: topSpacing, kindTag: tag)
        }

        switch block.kind {
        case .paragraph(let styled):
            return prose(styled, font: muted ? fonts.italic : fonts.body, tag: .prose)
        case .heading(let level, let styled):
            let font = fonts.headings[min(max(level, 1), 4) - 1]
            return prose(styled, font: font, bold: true, topSpacing: level <= 2 ? 8 : 4, tag: .prose)
        case .listItem(let marker, let checkbox, let styled):
            let prefix = checkbox.map { $0 ? "☑ " : "☐ " } ?? marker + " "
            let prefixLength = prefix.utf16.count
            var runs = styled.runs.map { run -> StyleRun in
                var shifted = run
                shifted.location += prefixLength
                return shifted
            }
            runs.insert(StyleRun(location: 0, length: prefixLength, traits: .muted), at: 0)
            return prose(StyledText(prefix + styled.text, runs: runs), font: fonts.body, hang: prefixLength, tag: .list)
        case .code(let language, let code):
            return layoutCode(code, language: language, x: x, width: available, fullWidth: width, quoteDepth: block.quoteDepth, fonts: fonts, highlighter: highlighter)
        case .table(let table):
            return layoutTable(table, x: x, width: available, fullWidth: width, quoteDepth: block.quoteDepth, fonts: fonts)
        case .rule:
            return BlockLayout(
                size: CGSize(width: width, height: 13), plainLength: 0,
                decorations: [Decoration(rect: CGRect(x: x, y: 6, width: available, height: 1), fill: theme.separator)],
                quoteDepth: block.quoteDepth, kindTag: .rule)
        case .image(let source, let alt):
            return layoutImage(source: source, alt: alt, x: x, width: available, fullWidth: width, imageSizes: imageSizes, fonts: fonts)
        }
    }

    static func layoutCode(
        _ code: String, language: String?, x: CGFloat, width: CGFloat, fullWidth: CGFloat, quoteDepth: Int,
        fonts: TranscriptFonts, highlighter: any HighlightService
    ) -> BlockLayout {
        let theme = fonts.theme
        let header = TranscriptTheme.codeHeaderHeight
        let padding = TranscriptTheme.codePadding
        let runs = highlighter.tokens(for: code, language: language)
        let mono = MonoLines(text: code, runs: runs, fonts: fonts)
        let codeHeight = mono.height
        let viewport = CGRect(x: x, y: header, width: width, height: codeHeight + 2 * 9)
        let content = CGSize(width: max(width, mono.contentWidth + 2 * padding), height: viewport.height)
        let fragment = Fragment(
            origin: CGPoint(x: x + padding, y: header + 9), textStart: 0, length: (code as NSString).length,
            width: max(mono.contentWidth, width - 2 * padding), height: codeHeight, content: .mono(mono), scrolls: true)
        let size = CGSize(width: fullWidth, height: header + viewport.height)
        let box = CGRect(x: x, y: 0, width: width, height: size.height)
        var labels: [Label] = []
        let languageName = (language?.isEmpty == false ? language! : "text")
        let languageLine = CTLineCreateWithAttributedString(fonts.plain(languageName, font: fonts.small, color: theme.secondary))
        labels.append(Label(line: languageLine, point: CGPoint(x: x + padding, y: 18)))
        let copy = CTLineCreateWithAttributedString(fonts.plain("Copy", font: fonts.small, color: theme.secondary))
        let copied = CTLineCreateWithAttributedString(fonts.plain("Copied", font: fonts.small, color: theme.success))
        let copyWidth = CGFloat(CTLineGetTypographicBounds(copy, nil, nil, nil))
        let copiedWidth = CGFloat(CTLineGetTypographicBounds(copied, nil, nil, nil))
        labels.append(Label(line: copy, point: CGPoint(x: box.maxX - padding - copyWidth, y: 18), role: .copyIdle))
        labels.append(Label(line: copied, point: CGPoint(x: box.maxX - padding - copiedWidth, y: 18), role: .copyDone))
        let hotspot = Hotspot(
            rect: CGRect(x: box.maxX - padding - max(copyWidth, copiedWidth) - 8, y: 3, width: max(copyWidth, copiedWidth) + 16, height: header - 6),
            action: .copyCode, label: "Copy code")
        return BlockLayout(
            size: size, plainLength: fragment.length, fragments: [fragment],
            decorations: [
                Decoration(rect: box, fill: theme.codeBackground, stroke: theme.cardBorder, radius: 8),
                Decoration(rect: CGRect(x: x + 1, y: header - 0.5, width: width - 2, height: 0.5), fill: theme.cardBorder),
            ],
            labels: labels, hotspots: [hotspot], scroll: ScrollArea(viewport: viewport, contentSize: content),
            quoteDepth: quoteDepth, kindTag: .code)
    }

    static func layoutTable(
        _ table: MarkdownTable, x: CGFloat, width: CGFloat, fullWidth: CGFloat, quoteDepth: Int, fonts: TranscriptFonts
    ) -> BlockLayout {
        let theme = fonts.theme
        let columns = max(1, table.columnCount)
        let allRows = [table.header] + table.rows
        let padding: CGFloat = 10
        var natural = [CGFloat](repeating: 36, count: columns)
        var attributedRows: [[NSAttributedString]] = []
        for (rowIndex, row) in allRows.enumerated() {
            var attributedRow: [NSAttributedString] = []
            for column in 0..<columns {
                let cell = column < row.count ? row[column] : StyledText("")
                let font = rowIndex == 0 ? fonts.semibold : fonts.body
                let attributed = fonts.attributed(cell, base: font, color: theme.text, baseIsBold: rowIndex == 0)
                attributedRow.append(attributed)
                natural[column] = max(natural[column], min(340, ProseTypesetter.width(attributed) + 2 * padding + 2))
            }
            attributedRows.append(attributedRow)
        }
        let widths = natural
        let total = widths.reduce(0, +)
        let scrolls = total > width + 0.5
        var fragments: [Fragment] = []
        var decorations: [Decoration] = []
        var y: CGFloat = 0
        var textOffset = 0
        var rowTops: [CGFloat] = []
        for (rowIndex, row) in allRows.enumerated() {
            var cellX = x
            var rowFragments: [Fragment] = []
            rowTops.append(y)
            for column in 0..<columns {
                let cell = column < row.count ? row[column] : StyledText("")
                let attributed = attributedRows[rowIndex][column]
                let deco = ProseTypesetter.decorations(cell, theme: theme)
                let cellWidth = widths[column] - 2 * padding
                var originX = cellX + padding
                let natural = ProseTypesetter.width(attributed)
                if natural < cellWidth {
                    let alignment = column < table.alignments.count ? table.alignments[column] : .left
                    if alignment == .right { originX += cellWidth - natural }
                    if alignment == .center { originX += floor((cellWidth - natural) / 2) }
                }
                let fragment = ProseTypesetter.layout(
                    attributed, origin: CGPoint(x: originX, y: y + 6), textStart: textOffset, width: cellWidth, scrolls: scrolls,
                    fills: deco.fills, strikes: deco.strikes, strikeColor: theme.text, links: deco.links, fallbackFont: fonts.body)
                rowFragments.append(fragment)
                textOffset += cell.utf16Count + 1  // \t or \n
                cellX += widths[column]
            }
            let rowHeight = (rowFragments.map(\.height).max() ?? 16) + 12
            if rowIndex == 0 {
                decorations.append(Decoration(rect: CGRect(x: x, y: y, width: total, height: rowHeight), fill: theme.inlineCodeFill, scrolls: scrolls))
            }
            if rowIndex > 0 {
                decorations.append(Decoration(rect: CGRect(x: x, y: y, width: total, height: 0.5), fill: theme.cardBorder, scrolls: scrolls))
            }
            fragments += rowFragments
            y += rowHeight
        }
        var columnX = x
        for column in 0..<(columns - 1) {
            columnX += widths[column]
            decorations.append(Decoration(rect: CGRect(x: columnX, y: 0, width: 0.5, height: y), fill: theme.cardBorder, scrolls: scrolls))
        }
        decorations.append(
            Decoration(rect: CGRect(x: x, y: 0, width: scrolls ? total : total, height: y), fill: nil, stroke: theme.cardBorder, radius: 6, scrolls: scrolls))
        let scroll = scrolls
            ? ScrollArea(viewport: CGRect(x: x, y: 0, width: width, height: y + 8), contentSize: CGSize(width: total, height: y + 8)) : nil
        return BlockLayout(
            size: CGSize(width: fullWidth, height: y + (scrolls ? 8 : 0)), plainLength: max(0, textOffset - 1), fragments: fragments,
            decorations: decorations, scroll: scroll, quoteDepth: quoteDepth, kindTag: .table)
    }

    static func imageRect(source: String, x: CGFloat, width: CGFloat, maxHeight: CGFloat, imageSizes: [String: CGSize]) -> CGRect? {
        guard let pixels = imageSizes[source], pixels.width > 0, pixels.height > 0 else { return nil }
        // Pixel sizes are shown at 2x when large (screenshots), at 1x when small (icons).
        let points = pixels.width > 800 ? CGSize(width: pixels.width / 2, height: pixels.height / 2) : pixels
        let scale = min(1, width / points.width, maxHeight / points.height)
        return CGRect(x: x, y: 0, width: floor(points.width * scale), height: floor(points.height * scale))
    }

    static func layoutImage(
        source: String, alt: String, x: CGFloat, width: CGFloat, fullWidth: CGFloat, imageSizes: [String: CGSize],
        fonts: TranscriptFonts
    ) -> BlockLayout {
        let theme = fonts.theme
        let plain = MarkdownBlock(.image(source: source, alt: alt)).plainText.utf16.count
        if let rect = imageRect(source: source, x: x, width: width, maxHeight: TranscriptTheme.imageMaxHeight, imageSizes: imageSizes) {
            return BlockLayout(
                size: CGSize(width: fullWidth, height: rect.height), plainLength: plain,
                decorations: [Decoration(rect: rect, fill: theme.codeBackground, stroke: theme.cardBorder, radius: 6)],
                images: [BlockImage(source: source, rect: rect, radius: 6)], kindTag: .image)
        }
        // Unknown size: a fixed placeholder (replaced, with anchoring, when the image arrives).
        let rect = CGRect(x: x, y: 0, width: min(width, 260), height: 64)
        let caption = alt.isEmpty ? "Image" : alt
        let line = CTLineCreateWithAttributedString(fonts.plain(caption, font: fonts.small, color: theme.secondary))
        return BlockLayout(
            size: CGSize(width: fullWidth, height: rect.height), plainLength: plain,
            decorations: [Decoration(rect: rect, fill: theme.codeBackground, stroke: theme.cardBorder, radius: 6)],
            labels: [Label(line: line, point: CGPoint(x: x + 14, y: 37))], images: [BlockImage(source: source, rect: rect, radius: 6)],
            kindTag: .image)
    }

    // MARK: User message

    static func layoutUser(_ user: UserRowContent, imageSizes: [String: CGSize], width: CGFloat, fonts: TranscriptFonts) -> BlockLayout {
        let theme = fonts.theme
        let maxBubble = floor(width * TranscriptTheme.userBubbleMaxFraction)
        let padX: CGFloat = 13
        let padY: CGFloat = 8
        var fragments: [Fragment] = []
        var contentWidth: CGFloat = 0
        var y = padY
        let styled = PromptText.styled(user.text)
        var textFragment: Fragment?
        if !user.text.isEmpty {
            let attributed = fonts.attributed(styled, base: fonts.body, color: theme.text)
            let deco = ProseTypesetter.decorations(styled, theme: theme)
            let fragment = ProseTypesetter.layout(
                attributed, origin: CGPoint(x: 0, y: y), textStart: 0, width: maxBubble - 2 * padX, fills: deco.fills, links: deco.links)
            if case .lines(let lines) = fragment.content {
                for line in lines {
                    let w = CGFloat(CTLineGetTypographicBounds(line.line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line.line))
                    contentWidth = max(contentWidth, ceil(w + line.x))
                }
            }
            textFragment = fragment
            y += fragment.height
        }
        // Attachments: image thumbnails, then file chips, flowing left to right.
        var chipItems: [(rect: CGRect, file: FileChip)] = []
        var images: [BlockImage] = []
        var labels: [Label] = []
        var hotspots: [Hotspot] = []
        var decorations: [Decoration] = []
        if !user.attachments.isEmpty {
            if textFragment != nil { y += 6 }
            var x: CGFloat = 0
            var rowHeight: CGFloat = 0
            let limit = maxBubble - 2 * padX
            for file in user.attachments {
                let size: CGSize
                if file.isImage {
                    let rect = imageRect(source: file.uri, x: 0, width: 160, maxHeight: 96, imageSizes: imageSizes)
                    size = rect?.size ?? CGSize(width: 96, height: 72)
                } else {
                    let name = fonts.plain(file.name, font: fonts.small, color: theme.text)
                    size = CGSize(width: min(limit, ProseTypesetter.width(name) + 34), height: 24)
                }
                if x > 0, x + size.width > limit {
                    x = 0
                    y += rowHeight + 6
                    rowHeight = 0
                }
                chipItems.append((CGRect(x: x, y: y, width: size.width, height: size.height), file))
                x += size.width + 6
                rowHeight = max(rowHeight, size.height)
                contentWidth = max(contentWidth, x - 6)
            }
            y += rowHeight
        }
        y += padY
        let bubbleWidth = min(maxBubble, max(44, contentWidth + 2 * padX))
        let bubbleX = width - bubbleWidth
        if let fragment = textFragment {
            fragments.append(
                Fragment(
                    origin: CGPoint(x: bubbleX + padX, y: fragment.origin.y), textStart: 0, length: fragment.length,
                    width: fragment.width, height: fragment.height, content: fragment.content, fills: fragment.fills,
                    links: fragment.links, string: fragment.string))
        }
        decorations.append(
            Decoration(
                rect: CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: y), fill: theme.userBubble,
                stroke: theme.increasedContrast ? theme.cardBorder : nil, radius: 14))
        for (rect, file) in chipItems {
            let placed = rect.offsetBy(dx: bubbleX + padX, dy: 0)
            if file.isImage {
                decorations.append(Decoration(rect: placed, fill: theme.codeBackground, stroke: theme.cardBorder, radius: 6))
                images.append(BlockImage(source: file.uri, rect: placed, radius: 6))
            } else {
                decorations.append(Decoration(rect: placed, fill: theme.cardBackground, stroke: theme.cardBorder, radius: 6))
                labels.append(Label(glyph: .file, glyphColor: theme.secondary, point: .zero, glyphRect: CGRect(x: placed.minX + 7, y: placed.minY + 5, width: 14, height: 14)))
                let line = CTLineCreateTruncatedLine(
                    CTLineCreateWithAttributedString(fonts.plain(file.name, font: fonts.small, color: theme.text)),
                    Double(placed.width - 32), .middle,
                    CTLineCreateWithAttributedString(fonts.plain("…", font: fonts.small, color: theme.text)))
                if let line { labels.append(Label(line: line, point: CGPoint(x: placed.minX + 25, y: placed.minY + 16))) }
            }
            hotspots.append(Hotspot(rect: placed, action: .openFile(file.uri), label: "Open \(file.name)"))
        }
        var height = y
        if user.isSending {
            let line = CTLineCreateWithAttributedString(fonts.plain("Sending…", font: fonts.small, color: theme.secondary))
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            labels.append(Label(line: line, point: CGPoint(x: width - lineWidth - 4, y: y + 15)))
            height += 20
        }
        return BlockLayout(
            size: CGSize(width: width, height: height), plainLength: textFragment?.length ?? 0, fragments: fragments,
            decorations: decorations, labels: labels, hotspots: hotspots, images: images, kindTag: .card)
    }

    // MARK: Tools

    /// A clickable one-line disclosure: chevron + secondary text.
    static func disclosureLine(
        _ text: String, key: ExpansionKey, expanded: Bool, x: CGFloat, width: CGFloat, fonts: TranscriptFonts, label: String
    ) -> BlockLayout {
        let theme = fonts.theme
        let attributed = fonts.plain(text, font: fonts.body, color: theme.secondary)
        let fragment = ProseTypesetter.layout(
            attributed, origin: CGPoint(x: x + 18, y: 2), textStart: 0, width: width - x - 18, truncate: true)
        let textWidth = min(width - x - 18, ProseTypesetter.width(attributed))
        let height = fragment.height + 4
        return BlockLayout(
            size: CGSize(width: width, height: height), plainLength: fragment.length, fragments: [fragment],
            labels: [
                Label(
                    glyph: expanded ? .chevronDown : .chevronRight, glyphColor: theme.secondary, point: .zero,
                    glyphRect: CGRect(x: x + 1, y: floor((height - 12) / 2), width: 12, height: 12))
            ],
            hotspots: [Hotspot(rect: CGRect(x: x - 4, y: 0, width: textWidth + 30, height: height), action: .toggle(key), label: label)],
            kindTag: .tool)
    }

    static func layoutToolHeader(
        _ item: ToolItem, content: RowContent, ui: RowUIState, nested: Bool, width: CGFloat, fonts: TranscriptFonts
    ) -> BlockLayout {
        let theme = fonts.theme
        let x: CGFloat = nested ? 18 : 0
        let text = RenderBlocks.headerText(item)
        let attributed = NSMutableAttributedString(attributedString: fonts.plain(text, font: fonts.body, color: theme.text))
        let ns = text as NSString
        let verbLength = (item.verb as NSString).length
        attributed.addAttributes(fonts.attributes(font: fonts.body, color: theme.secondary), range: NSRange(location: 0, length: min(verbLength, ns.length)))
        let titleLength = (item.title as NSString).length
        if ns.length > titleLength {
            let suffix = NSRange(location: titleLength, length: ns.length - titleLength)
            let statusColor: CGColor =
                switch item.status {
                case .failed: theme.failure
                case .preparing, .running: theme.running
                default: theme.tertiary
                }
            attributed.addAttributes(fonts.attributes(font: fonts.body, color: statusColor), range: suffix)
            if let duration = item.duration, !item.status.isActive {
                let durationText = " · " + DurationText.format(duration)
                let range = ns.range(of: durationText, options: .backwards)
                if range.location != NSNotFound { attributed.addAttributes(fonts.attributes(font: fonts.body, color: theme.tertiary), range: range) }
            }
        }
        let hasDetail = !item.input.isEmpty || !item.output.isEmpty
        let textX = x + 18
        let available = width - textX - (hasDetail ? 20 : 0)
        let fragment = ProseTypesetter.layout(attributed, origin: CGPoint(x: textX, y: 2), textStart: 0, width: available, truncate: true)
        let height = fragment.height + 4
        let statusColor: CGColor =
            switch item.status {
            case .done: theme.success
            case .failed: theme.failure
            case .preparing, .running: theme.running
            case .unknown: theme.secondary
            }
        var labels = [
            Label(
                glyph: Glyph.status(item.status), glyphColor: statusColor, point: .zero,
                glyphRect: CGRect(x: x + 1, y: floor((height - 13) / 2), width: 13, height: 13))
        ]
        var hotspots: [Hotspot] = []
        if hasDetail {
            let expanded = RenderBlocks.isExpanded(.tool(item.id), content: content, ui: ui)
            let textWidth = min(available, ProseTypesetter.width(attributed))
            labels.append(
                Label(
                    glyph: expanded ? .chevronDown : .chevronRight, glyphColor: theme.tertiary, point: .zero,
                    glyphRect: CGRect(x: textX + textWidth + 5, y: floor((height - 11) / 2), width: 11, height: 11)))
            hotspots.append(
                Hotspot(
                    rect: CGRect(x: x - 4, y: 0, width: textWidth + textX - x + 24, height: height), action: .toggle(.tool(item.id)),
                    label: expanded ? "Hide details" : "Show details"))
        }
        return BlockLayout(
            size: CGSize(width: width, height: height), plainLength: fragment.length, fragments: [fragment], labels: labels,
            hotspots: hotspots, kindTag: .tool)
    }

    static func layoutToolDetail(
        _ item: ToolItem, x: CGFloat, width: CGFloat, fonts: TranscriptFonts, highlighter: any HighlightService
    ) -> BlockLayout {
        let theme = fonts.theme
        let text = RenderBlocks.detailText(item)
        var runs: [TokenRun] = []
        if !item.input.isEmpty {
            let language: String? =
                item.inputIsDiff ? "diff" : item.category == .command ? "shell" : item.input.hasPrefix("{") ? "json" : nil
            runs = highlighter.tokens(for: item.input, language: language)
        }
        let mono = MonoLines(text: text, runs: runs, fonts: fonts)
        let padding: CGFloat = 10
        let contentHeight = mono.height + 2 * 8
        let viewportHeight = min(contentHeight, TranscriptTheme.toolOutputMaxHeight)
        let viewport = CGRect(x: x, y: 0, width: width, height: viewportHeight)
        let content = CGSize(width: max(width, mono.contentWidth + 2 * padding), height: contentHeight)
        let fragment = Fragment(
            origin: CGPoint(x: x + padding, y: 8), textStart: 0, length: (text as NSString).length,
            width: max(mono.contentWidth, width - 2 * padding), height: mono.height, content: .mono(mono), scrolls: true)
        var decorations = [Decoration(rect: viewport, fill: theme.codeBackground, stroke: theme.cardBorder, radius: 6)]
        if !item.input.isEmpty, !item.output.isEmpty {
            // A hairline between input and output.
            let inputLines = item.input.utf16.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
            let y = 8 + CGFloat(inputLines) * mono.lineHeight + mono.lineHeight / 2
            decorations.append(Decoration(rect: CGRect(x: x + padding, y: y, width: content.width - 2 * padding, height: 0.5), fill: theme.cardBorder, scrolls: true))
        }
        return BlockLayout(
            size: CGSize(width: x + width, height: viewportHeight), plainLength: fragment.length, fragments: [fragment],
            decorations: decorations, scroll: ScrollArea(viewport: viewport, contentSize: content), kindTag: .toolDetail)
    }

    // MARK: Cards

    static func layoutTodo(_ list: TodoListContent, width: CGFloat, fonts: TranscriptFonts) -> BlockLayout {
        let theme = fonts.theme
        let text = RenderBlocks.todoText(list)
        let attributed = NSMutableAttributedString(attributedString: fonts.plain(text, font: fonts.body, color: theme.text))
        let ns = text as NSString
        let firstLine = ns.range(of: "\n").location == NSNotFound ? ns.length : ns.range(of: "\n").location
        attributed.addAttributes(fonts.attributes(font: fonts.smallBold, color: theme.secondary), range: NSRange(location: 0, length: firstLine))
        var strikes: [Range<Int>] = []
        var location = firstLine + 1
        for item in list.items {
            let length = (item.text as NSString).length + 2
            guard location + length <= ns.length else { break }
            let range = NSRange(location: location, length: length)
            switch item.state {
            case .completed, .cancelled:
                attributed.addAttributes(fonts.attributes(font: fonts.body, color: theme.secondary), range: range)
                strikes.append((location + 2)..<(location + length))
            case .inProgress:
                attributed.addAttributes(fonts.attributes(font: fonts.semibold, color: theme.text), range: range)
            case .pending:
                break
            }
            location += length + 1
        }
        let fragment = ProseTypesetter.layout(
            attributed, origin: CGPoint(x: 12, y: 9), textStart: 0, width: width - 24, lineSpacing: 5, strikes: strikes,
            strikeColor: theme.secondary)
        let size = CGSize(width: width, height: fragment.height + 18)
        return BlockLayout(
            size: size, plainLength: fragment.length, fragments: [fragment],
            decorations: [Decoration(rect: CGRect(origin: .zero, size: size), fill: theme.cardBackground, stroke: theme.cardBorder, radius: 8)],
            kindTag: .card)
    }

    static func layoutFile(_ file: FileChip, imageSizes: [String: CGSize], width: CGFloat, fonts: TranscriptFonts) -> BlockLayout {
        let theme = fonts.theme
        if file.isImage {
            let rect = imageRect(source: file.uri, x: 0, width: min(width, 480), maxHeight: 280, imageSizes: imageSizes)
                ?? CGRect(x: 0, y: 0, width: 200, height: 120)
            let caption = ProseTypesetter.layout(
                fonts.plain(file.name, font: fonts.small, color: theme.secondary), origin: CGPoint(x: 0, y: rect.maxY + 4), textStart: 0,
                width: width, truncate: true)
            return BlockLayout(
                size: CGSize(width: width, height: caption.frame.maxY), plainLength: caption.length, fragments: [caption],
                decorations: [Decoration(rect: rect, fill: theme.codeBackground, stroke: theme.cardBorder, radius: 6)],
                hotspots: [Hotspot(rect: rect, action: .openFile(file.uri), label: "Open \(file.name)")],
                images: [BlockImage(source: file.uri, rect: rect, radius: 6)], kindTag: .image)
        }
        let name = fonts.plain(file.name, font: fonts.body, color: theme.text)
        let fragment = ProseTypesetter.layout(name, origin: CGPoint(x: 30, y: 6), textStart: 0, width: min(width - 40, 420), truncate: true)
        let chipWidth = min(width, ProseTypesetter.width(name) + 44)
        let size = CGSize(width: width, height: fragment.height + 12)
        let chip = CGRect(x: 0, y: 0, width: chipWidth, height: size.height)
        return BlockLayout(
            size: size, plainLength: fragment.length, fragments: [fragment],
            decorations: [Decoration(rect: chip, fill: theme.cardBackground, stroke: theme.cardBorder, radius: 7)],
            labels: [Label(glyph: .file, glyphColor: theme.secondary, point: .zero, glyphRect: CGRect(x: 9, y: floor((size.height - 15) / 2), width: 15, height: 15))],
            hotspots: [Hotspot(rect: chip, action: .openFile(file.uri), label: "Open \(file.name)")], kindTag: .card)
    }

    static func layoutSubagent(_ card: SubagentCardContent, width: CGFloat, fonts: TranscriptFonts) -> BlockLayout {
        let theme = fonts.theme
        let text = RenderBlocks.subagentText(card)
        let ns = text as NSString
        let titleLength = (card.title as NSString).length
        let attributed = NSMutableAttributedString(attributedString: fonts.plain(text, font: fonts.small, color: theme.secondary))
        attributed.addAttributes(fonts.attributes(font: fonts.semibold, color: theme.text), range: NSRange(location: 0, length: titleLength))
        if card.status == .failed {
            let range = ns.range(of: SubagentStatus.failed.label, options: .backwards)
            if range.location != NSNotFound { attributed.addAttributes(fonts.attributes(font: fonts.small, color: theme.failure), range: range) }
        }
        let openWidth: CGFloat = card.childSessionID == nil ? 0 : 70
        let fragment = ProseTypesetter.layout(attributed, origin: CGPoint(x: 34, y: 9), textStart: 0, width: width - 46 - openWidth, lineSpacing: 4)
        let size = CGSize(width: width, height: fragment.height + 18)
        let statusColor: CGColor =
            switch card.status {
            case .running: theme.running
            case .done: theme.success
            case .failed: theme.failure
            case .unknown: theme.secondary
            }
        let glyph: Glyph =
            switch card.status {
            case .running: .running
            case .done: .check
            case .failed: .cross
            case .unknown: .dot
            }
        var labels = [Label(glyph: glyph, glyphColor: statusColor, point: .zero, glyphRect: CGRect(x: 12, y: 11, width: 14, height: 14))]
        var hotspots: [Hotspot] = []
        if let child = card.childSessionID {
            let open = CTLineCreateWithAttributedString(fonts.plain("Open", font: fonts.small, color: theme.link))
            let openTextWidth = CGFloat(CTLineGetTypographicBounds(open, nil, nil, nil))
            let x = width - 14 - 12 - openTextWidth
            labels.append(Label(line: open, point: CGPoint(x: x, y: floor(size.height / 2) + 4)))
            labels.append(
                Label(glyph: .arrowUpRight, glyphColor: theme.link, point: .zero, glyphRect: CGRect(x: width - 24, y: floor(size.height / 2) - 6, width: 12, height: 12)))
            hotspots.append(
                Hotspot(rect: CGRect(x: x - 8, y: 4, width: width - x + 4, height: size.height - 8), action: .openChild(child), label: "Open sub-agent thread"))
        }
        return BlockLayout(
            size: size, plainLength: fragment.length, fragments: [fragment],
            decorations: [Decoration(rect: CGRect(origin: .zero, size: size), fill: theme.cardBackground, stroke: theme.cardBorder, radius: 10)],
            labels: labels, hotspots: hotspots, kindTag: .card)
    }

    // MARK: Estimates

    /// Cheap height estimate without typesetting, used until a row is measured exactly.
    public static func estimate(_ row: TranscriptRow, width: CGFloat, theme: TranscriptTheme, topPadding: CGFloat) -> CGFloat {
        let lineHeight = ceil(theme.bodySize * 1.25) + 3
        let monoLine = ceil(theme.monoSize * 1.2) + 4
        let charsPerLine = max(20, width / (theme.bodySize * 0.5))
        func prose(_ text: String) -> CGFloat {
            var height: CGFloat = 0
            var fenced = false
            var paragraph = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("```") || line.hasPrefix("~~~") {
                    fenced.toggle()
                    height += fenced ? TranscriptTheme.codeHeaderHeight + 18 + TranscriptTheme.blockSpacing : 0
                    continue
                }
                if fenced { height += monoLine; continue }
                if line.isEmpty {
                    if paragraph > 0 { height += ceil(CGFloat(paragraph) / charsPerLine) * lineHeight + TranscriptTheme.blockSpacing }
                    paragraph = 0
                } else if line.hasPrefix("|") {
                    height += lineHeight + 12
                } else {
                    paragraph += line.utf8.count
                    if line.hasPrefix("-") || line.hasPrefix("*") || line.first?.isNumber == true { height += 4 }
                }
            }
            height += ceil(CGFloat(paragraph) / charsPerLine) * lineHeight
            return max(lineHeight, height)
        }
        var height = topPadding + 2
        switch row.content {
        case .user(let user):
            height += prose(user.text) * 1.1 + 16 + (user.attachments.isEmpty ? 0 : 34) + (user.isSending ? 20 : 0)
        case .markdown(let text, _):
            height += prose(text)
        case .reasoning:
            height += lineHeight + 4
        case .work(let group):
            let visible = group.isCollapsible ? group.items.filter { !$0.status.isSuccess }.count + 1 : group.items.count
            height += CGFloat(visible) * (lineHeight + 5)
        case .todo(let list):
            height += CGFloat(list.items.count + 1) * (lineHeight + 2) + 18
        case .file(let file):
            height += file.isImage ? 140 : lineHeight + 12
        case .subagent:
            height += 2 * lineHeight + 18
        case .error(let error):
            height += prose(error.message) + lineHeight + 18
        case .lifecycle, .working, .unknown:
            height += lineHeight + 8
        }
        return ceil(height)
    }
}
