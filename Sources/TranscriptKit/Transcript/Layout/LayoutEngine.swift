import AppKit
import BelloCore
import CoreText
import DesignSystem

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

    public init(
        row: TranscriptRow, ui: RowUIState, width: CGFloat, theme: TranscriptTheme, topPadding: CGFloat,
        imageSizes: [String: CGSize], blocks: [RenderBlock]? = nil, highlighter: any HighlightService,
        cache: RenderBlockCache? = nil
    ) {
        self.row = row
        self.ui = ui
        self.width = width
        self.theme = theme
        self.topPadding = topPadding
        self.imageSizes = imageSizes
        self.blocks = blocks
        self.highlighter = highlighter
        self.cache = cache
    }

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
                label: expanded ? "Hide reasoning" : "Show reasoning", live: reasoning.isStreaming)

        case .groupSummary(let group):
            let expanded = RenderBlocks.isExpanded(.group, content: content, ui: ui)
            return disclosureLine(
                RenderBlocks.summaryText(group), key: .group, expanded: expanded, x: 0, width: width, fonts: fonts,
                label: expanded ? "Collapse tool calls" : "Expand tool calls", hasDuration: group.duration != nil)

        case .toolHeader(let item):
            return layoutToolHeader(item, content: content, ui: ui, nested: nested, width: width, fonts: fonts)

        case .toolDetail(let item):
            let x: CGFloat = (nested ? TranscriptTheme.childIndent : 0) + 20
            return layoutToolDetail(item, x: x, width: width - x, fonts: fonts, highlighter: highlighter)

        case .todo(let list):
            return layoutTodo(list, width: width, fonts: fonts)

        case .file(let file):
            return layoutFile(file, imageSizes: imageSizes, width: width, fonts: fonts)

        case .subagent(let card):
            return layoutSubagent(card, width: width, fonts: fonts)

        case .visual(let visual):
            return layoutVisual(visual, width: width, fonts: fonts)

        case .error(let error):
            // An inline row (visual-language.md §6 "Errors"): triangle `dangerText`, the title in `dangerText` medium,
            // the message in `text`. No tinted box: errors here end a turn but block nothing.
            let text = NSMutableAttributedString(attributedString: fonts.plain(error.title, font: fonts.uiMedium, color: theme.failure))
            text.append(fonts.plain("\n" + error.message, font: fonts.ui, color: theme.text))
            let fragment = ProseTypesetter.layout(
                text, origin: CGPoint(x: 22, y: 0), textStart: 0, width: width - 22, lineSpacing: 0, fallbackFont: fonts.ui,
                lineHeight: theme.uiLineHeight + 2)
            let glyphTop = floor((theme.uiLineHeight + 2 - 14) / 2)
            return BlockLayout(
                size: CGSize(width: width, height: fragment.height), plainLength: fragment.length, fragments: [fragment],
                labels: [Label(glyph: .warning, glyphColor: theme.failure, point: .zero, glyphRect: CGRect(x: 1, y: glyphTop, width: 14, height: 13))],
                kindTag: .card)

        case .lifecycle(let event):
            // One centred `meta text3` line; no rules.
            let attributed = fonts.plain(event.text, font: fonts.small, color: theme.tertiary)
            let textWidth = min(width - 80, ProseTypesetter.width(attributed) + 1)
            let x = floor((width - textWidth) / 2)
            let fragment = ProseTypesetter.layout(
                attributed, origin: CGPoint(x: x, y: 4), textStart: 0, width: textWidth, lineSpacing: 0, truncate: true,
                lineHeight: DS.TextRole.meta.lineHeight(base: theme.baseSize))
            return BlockLayout(
                size: CGSize(width: width, height: fragment.height + 8), plainLength: fragment.length, fragments: [fragment],
                kindTag: .other)

        case .working:
            let attributed = fonts.plain("Working…", font: fonts.ui, color: theme.tertiary)
            let height = TranscriptTheme.toolRowHeight
            let fragment = ProseTypesetter.layout(
                attributed, origin: CGPoint(x: 20, y: 0), textStart: 0, width: width - 20, lineSpacing: 0, truncate: true,
                lineHeight: height)
            return BlockLayout(
                size: CGSize(width: width, height: fragment.height), plainLength: fragment.length, fragments: [fragment],
                labels: [Label(glyph: .running, glyphColor: theme.running, point: .zero, glyphRect: CGRect(x: 0, y: floor((height - 14) / 2), width: 14, height: 14))],
                kindTag: .tool)

        case .unknown(let type):
            let attributed = fonts.plain("Unsupported content (\(type))", font: fonts.italic, color: theme.tertiary)
            let fragment = ProseTypesetter.layout(attributed, origin: .zero, textStart: 0, width: width, lineSpacing: 0, lineHeight: theme.proseLineHeight)
            return BlockLayout(size: CGSize(width: width, height: fragment.height), plainLength: fragment.length, fragments: [fragment])
        }
    }

    static func glyphRect(_ fragment: Fragment, x: CGFloat, size: CGFloat = 14) -> CGRect {
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
            + (muted ? TranscriptTheme.childIndent : 0)
        let available = max(80, width - x)
        // Expanded reasoning: `text2` at 13 / 20 beside a 2 pt guide.
        let color = muted ? theme.secondary : theme.text
        let bodyFont = muted ? fonts.ui : fonts.body

        func prose(_ styled: StyledText, font: CTFont, bold: Bool = false, hang: Int = 0, topSpacing: CGFloat = 0, tag: BlockLayout.KindTag)
            -> BlockLayout
        {
            let attributed = fonts.attributed(styled, base: font, color: color, baseIsBold: bold)
            let deco = ProseTypesetter.decorations(styled, theme: theme)
            let lineHeight = muted ? theme.reasoningLineHeight : fonts.lineHeight(for: font)
            let fragment = ProseTypesetter.layout(
                attributed, origin: CGPoint(x: x, y: 0), textStart: 0, width: available, hangUTF16: hang, lineSpacing: 0,
                fills: deco.fills, strikes: deco.strikes, strikeColor: color, links: deco.links, fallbackFont: font,
                lineHeight: lineHeight)
            return BlockLayout(
                size: CGSize(width: width, height: fragment.height), plainLength: fragment.length, fragments: [fragment],
                isListItem: tag == .list, quoteDepth: block.quoteDepth, topSpacing: topSpacing, kindTag: tag, isMuted: muted)
        }

        switch block.kind {
        case .paragraph(let styled):
            return prose(styled, font: bodyFont, tag: .prose)
        case .heading(let level, let styled):
            let font = muted ? fonts.uiMedium : fonts.headings[min(max(level, 1), 4) - 1]
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
            return prose(StyledText(prefix + styled.text, runs: runs), font: bodyFont, hang: prefixLength, tag: .list)
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

    /// A code block (visual-language.md §6): `codeFill`, `r.md`, a 28 pt header with the language (`meta` mono `text3`)
    /// and a ghost copy icon button, body padding 6 / 14 / 12, `code` 12.5 / 19 with the DesignSystem syntax palette.
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
        let viewport = CGRect(
            x: x, y: header, width: width, height: TranscriptTheme.codePaddingTop + codeHeight + TranscriptTheme.codePaddingBottom)
        let content = CGSize(width: max(width, mono.contentWidth + 2 * padding), height: viewport.height)
        let fragment = Fragment(
            origin: CGPoint(x: x + padding, y: header + TranscriptTheme.codePaddingTop), textStart: 0, length: (code as NSString).length,
            width: max(mono.contentWidth, width - 2 * padding), height: codeHeight, content: .mono(mono), scrolls: true)
        let size = CGSize(width: fullWidth, height: header + viewport.height)
        let box = CGRect(x: x, y: 0, width: width, height: size.height)
        var labels: [Label] = []
        let languageName = (language?.isEmpty == false ? language! : "text")
        let languageLine = CTLineCreateWithAttributedString(fonts.plain(languageName, font: fonts.smallMono, color: theme.tertiary))
        labels.append(Label(line: languageLine, point: CGPoint(x: x + padding, y: floor(header / 2) + 4)))
        // Ghost icon button: 24 pt square, 14 pt glyph, `icon` tint; a check in `successText` once copied.
        let button = CGRect(x: box.maxX - 8 - 24, y: floor((header - 24) / 2) + 1, width: 24, height: 24)
        let glyph = button.insetBy(dx: 5, dy: 5)
        labels.append(Label(glyph: .copy, glyphColor: theme.icon, point: .zero, glyphRect: glyph, role: .copyIdle))
        labels.append(Label(glyph: .check, glyphColor: theme.success, point: .zero, glyphRect: glyph.insetBy(dx: 1, dy: 1), role: .copyDone))
        let hotspot = Hotspot(rect: button, action: .copyCode, label: "Copy code")
        return BlockLayout(
            size: size, plainLength: fragment.length, fragments: [fragment],
            decorations: [Decoration(rect: box, fill: theme.codeBackground, stroke: theme.codeBorder, radius: DS.Radius.md)],
            labels: labels, hotspots: [hotspot], scroll: ScrollArea(viewport: viewport, contentSize: content),
            quoteDepth: quoteDepth, kindTag: .code)
    }

    /// A borderless table (visual-language.md §6): header semibold over a `borderStrong` rule, `border` rules under rows,
    /// cell padding 6 / 12 with the first and last columns flush, tabular digits, Markdown alignment. Narrow tables
    /// stretch to the column; wide ones scroll.
    static func layoutTable(
        _ table: MarkdownTable, x: CGFloat, width: CGFloat, fullWidth: CGFloat, quoteDepth: Int, fonts: TranscriptFonts
    ) -> BlockLayout {
        let theme = fonts.theme
        let columns = max(1, table.columnCount)
        let allRows = [table.header] + table.rows
        let padding: CGFloat = 12
        let lineHeight = theme.monoLineHeight
        func leading(_ column: Int) -> CGFloat { column == 0 ? 0 : padding }
        func trailing(_ column: Int) -> CGFloat { column == columns - 1 ? 0 : padding }
        var natural = [CGFloat](repeating: 36, count: columns)
        var attributedRows: [[NSAttributedString]] = []
        for (rowIndex, row) in allRows.enumerated() {
            var attributedRow: [NSAttributedString] = []
            for column in 0..<columns {
                let cell = column < row.count ? row[column] : StyledText("")
                let font = rowIndex == 0 ? fonts.tabularSemibold : fonts.tabular
                let attributed = fonts.attributed(cell, base: font, color: theme.text, baseIsBold: rowIndex == 0)
                attributedRow.append(attributed)
                natural[column] = max(natural[column], min(340, ProseTypesetter.width(attributed) + leading(column) + trailing(column) + 2))
            }
            attributedRows.append(attributedRow)
        }
        var widths = natural
        let naturalTotal = widths.reduce(0, +)
        let scrolls = naturalTotal > width + 0.5
        if !scrolls, columns > 1 {
            let extra = floor((width - naturalTotal) / CGFloat(columns))
            widths = widths.map { $0 + extra }
            widths[columns - 1] = width - widths.dropLast().reduce(0, +)
        }
        let total = scrolls ? naturalTotal : width
        var fragments: [Fragment] = []
        var decorations: [Decoration] = []
        var y: CGFloat = 0
        var textOffset = 0
        for (rowIndex, row) in allRows.enumerated() {
            var cellX = x
            var rowFragments: [Fragment] = []
            for column in 0..<columns {
                let cell = column < row.count ? row[column] : StyledText("")
                let attributed = attributedRows[rowIndex][column]
                let deco = ProseTypesetter.decorations(cell, theme: theme)
                let cellWidth = widths[column] - leading(column) - trailing(column)
                var originX = cellX + leading(column)
                let natural = ProseTypesetter.width(attributed)
                if natural < cellWidth {
                    let alignment = column < table.alignments.count ? table.alignments[column] : .left
                    if alignment == .right { originX += cellWidth - natural }
                    if alignment == .center { originX += floor((cellWidth - natural) / 2) }
                }
                let fragment = ProseTypesetter.layout(
                    attributed, origin: CGPoint(x: originX, y: y + 6), textStart: textOffset, width: cellWidth, lineSpacing: 0,
                    scrolls: scrolls, fills: deco.fills, strikes: deco.strikes, strikeColor: theme.text, links: deco.links,
                    fallbackFont: fonts.tabular, lineHeight: lineHeight)
                rowFragments.append(fragment)
                textOffset += cell.utf16Count + 1  // \t or \n
                cellX += widths[column]
            }
            let rowHeight = (rowFragments.map(\.height).max() ?? lineHeight) + 12
            decorations.append(
                Decoration(
                    rect: CGRect(x: x, y: y + rowHeight - 1, width: total, height: 1),
                    fill: rowIndex == 0 ? theme.strongSeparator : theme.separator, scrolls: scrolls))
            fragments += rowFragments
            y += rowHeight
        }
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
                decorations: [Decoration(rect: rect, fill: theme.codeBackground, stroke: theme.codeBorder, radius: DS.Radius.md)],
                images: [BlockImage(source: source, rect: rect, radius: DS.Radius.md)], kindTag: .image)
        }
        // Unknown size: a fixed placeholder (replaced, with anchoring, when the image arrives).
        let rect = CGRect(x: x, y: 0, width: min(width, 260), height: 64)
        let caption = alt.isEmpty ? "Image" : alt
        let line = CTLineCreateWithAttributedString(fonts.plain(caption, font: fonts.small, color: theme.tertiary))
        return BlockLayout(
            size: CGSize(width: fullWidth, height: rect.height), plainLength: plain,
            decorations: [Decoration(rect: rect, fill: theme.codeBackground, stroke: theme.codeBorder, radius: DS.Radius.md)],
            labels: [Label(line: line, point: CGPoint(x: x + 14, y: 37))], images: [BlockImage(source: source, rect: rect, radius: DS.Radius.md)],
            kindTag: .image)
    }

    // MARK: User message

    /// The user's bubble (visual-language.md §6): right-aligned, at most 80 % of the column, `message` fill, `r.xl`,
    /// padding 10 / 14, `prose` 14 / 21.
    static func layoutUser(_ user: UserRowContent, imageSizes: [String: CGSize], width: CGFloat, fonts: TranscriptFonts) -> BlockLayout {
        let theme = fonts.theme
        let maxBubble = floor(width * TranscriptTheme.userBubbleMaxFraction)
        let padX: CGFloat = 14
        let padY: CGFloat = 10
        var fragments: [Fragment] = []
        var contentWidth: CGFloat = 0
        var y = padY
        let styled = PromptText.styled(user.text)
        var textFragment: Fragment?
        if !user.text.isEmpty {
            let attributed = fonts.attributed(styled, base: fonts.body, color: theme.text)
            let deco = ProseTypesetter.decorations(styled, theme: theme)
            let fragment = ProseTypesetter.layout(
                attributed, origin: CGPoint(x: 0, y: y), textStart: 0, width: maxBubble - 2 * padX, lineSpacing: 0, fills: deco.fills,
                links: deco.links, fallbackFont: fonts.body, lineHeight: theme.bubbleLineHeight)
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
                    width: bubbleWidth - 2 * padX, height: fragment.height, content: fragment.content, fills: fragment.fills,
                    links: fragment.links, string: fragment.string))
        }
        decorations.append(
            Decoration(
                rect: CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: y), fill: theme.userBubble,
                stroke: theme.increasedContrast ? theme.cardBorder : nil, radius: DS.Radius.xl))
        for (rect, file) in chipItems {
            let placed = rect.offsetBy(dx: bubbleX + padX, dy: 0)
            if file.isImage {
                decorations.append(Decoration(rect: placed, fill: theme.codeBackground, stroke: theme.codeBorder, radius: DS.Radius.sm))
                images.append(BlockImage(source: file.uri, rect: placed, radius: DS.Radius.sm))
            } else {
                decorations.append(Decoration(rect: placed, fill: theme.hoverFill, stroke: theme.separator, radius: DS.Radius.sm))
                labels.append(Label(glyph: .file, glyphColor: theme.icon, point: .zero, glyphRect: CGRect(x: placed.minX + 7, y: placed.minY + 5, width: 14, height: 14)))
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
            // Not delivered until the server acknowledges it (UX rule 5).
            let line = CTLineCreateWithAttributedString(fonts.plain("Sending…", font: fonts.small, color: theme.tertiary))
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            labels.append(Label(line: line, point: CGPoint(x: width - lineWidth - 4, y: y + 15)))
            height += 20
        }
        return BlockLayout(
            size: CGSize(width: width, height: height), plainLength: textFragment?.length ?? 0, fragments: fragments,
            decorations: decorations, labels: labels, hotspots: hotspots, images: images, kindTag: .card)
    }

    // MARK: Tools

    /// A clickable one-line disclosure (work-group summary, reasoning): 24 pt, chevron 12 `text4`, text `body text3`,
    /// a trailing " · 12s" in `text4`.
    static func disclosureLine(
        _ text: String, key: ExpansionKey, expanded: Bool, x: CGFloat, width: CGFloat, fonts: TranscriptFonts, label: String,
        hasDuration: Bool = false, live: Bool = false
    ) -> BlockLayout {
        let theme = fonts.theme
        let attributed = NSMutableAttributedString(attributedString: fonts.plain(text, font: fonts.ui, color: theme.tertiary))
        if hasDuration {
            let range = (text as NSString).range(of: " · ", options: .backwards)
            if range.location != NSNotFound {
                attributed.addAttributes(
                    fonts.attributes(font: fonts.ui, color: theme.quaternary),
                    range: NSRange(location: range.location, length: (text as NSString).length - range.location))
            }
        }
        let height = TranscriptTheme.summaryRowHeight
        let textX = x + 16
        let fragment = ProseTypesetter.layout(
            attributed, origin: CGPoint(x: textX, y: 0), textStart: 0, width: width - textX, lineSpacing: 0, truncate: true,
            lineHeight: height)
        let textWidth = min(width - textX, ProseTypesetter.width(attributed))
        return BlockLayout(
            size: CGSize(width: width, height: height), plainLength: fragment.length, fragments: [fragment],
            labels: [
                Label(
                    glyph: live ? .running : expanded ? .chevronDown : .chevronRight, glyphColor: live ? theme.running : theme.quaternary,
                    point: .zero, glyphRect: CGRect(x: x, y: floor((height - 12) / 2), width: 12, height: 12))
            ],
            hotspots: [Hotspot(rect: CGRect(x: x - 4, y: 0, width: textWidth + textX - x + 10, height: height), action: .toggle(key), label: label)],
            kindTag: .tool)
    }

    /// Lines added and removed in a diff input (`+n` / `−n` beside an edit), counted off the main actor.
    static func diffStat(_ item: ToolItem) -> (added: Int, removed: Int)? {
        guard item.inputIsDiff, !item.input.isEmpty else { return nil }
        var added = 0
        var removed = 0
        for line in item.input.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
            if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
        }
        return added + removed > 0 ? (added, removed) : nil
    }

    /// A tool row (visual-language.md §6): 26 pt; status glyph 14 (check `successText`, triangle `dangerText`, the
    /// spinner while running); verb `text3`; target `text`, mono 12 for paths and commands; ` · Failed` in `dangerText`;
    /// duration `text4`; diff stat `+n` / `−n`; a disclosure chevron when there is detail.
    static func layoutToolHeader(
        _ item: ToolItem, content: RowContent, ui: RowUIState, nested: Bool, width: CGFloat, fonts: TranscriptFonts
    ) -> BlockLayout {
        let theme = fonts.theme
        let x: CGFloat = nested ? TranscriptTheme.childIndent : 0
        let text = RenderBlocks.headerText(item)
        let ns = text as NSString
        let attributed = NSMutableAttributedString(attributedString: fonts.plain(text, font: fonts.ui, color: theme.text))
        let verbLength = min((item.verb as NSString).length, ns.length)
        attributed.addAttributes(fonts.attributes(font: fonts.ui, color: theme.tertiary), range: NSRange(location: 0, length: verbLength))
        let titleLength = min((item.title as NSString).length, ns.length)
        if titleLength > verbLength + 1, item.category != .other {
            attributed.addAttributes(
                fonts.attributes(font: fonts.targetMono, color: theme.text),
                range: NSRange(location: verbLength + 1, length: titleLength - verbLength - 1))
        }
        if ns.length > titleLength {
            let suffix = NSRange(location: titleLength, length: ns.length - titleLength)
            let statusColor: CGColor =
                switch item.status {
                case .failed: theme.failure
                case .preparing, .running: theme.tertiary
                default: theme.quaternary
                }
            attributed.addAttributes(fonts.attributes(font: fonts.ui, color: statusColor), range: suffix)
            if let duration = item.duration, !item.status.isActive {
                let durationText = " · " + DurationText.format(duration)
                let range = ns.range(of: durationText, options: .backwards)
                if range.location != NSNotFound { attributed.addAttributes(fonts.attributes(font: fonts.ui, color: theme.quaternary), range: range) }
            }
        }
        let height = TranscriptTheme.toolRowHeight
        let hasDetail = !item.input.isEmpty || !item.output.isEmpty
        let textX = x + 20
        // Room for the diff stat and the chevron.
        var statLines: [(CTLine, CGFloat)] = []
        if let stat = diffStat(item) {
            if stat.added > 0 {
                let line = CTLineCreateWithAttributedString(fonts.plain("+\(stat.added)", font: fonts.ui, color: theme.success))
                statLines.append((line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))))
            }
            if stat.removed > 0 {
                let line = CTLineCreateWithAttributedString(fonts.plain("−\(stat.removed)", font: fonts.ui, color: theme.failure))
                statLines.append((line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))))
            }
        }
        let statWidth = statLines.reduce(CGFloat(0)) { $0 + $1.1 + 4 } + (statLines.isEmpty ? 0 : 6)
        let available = width - textX - (hasDetail ? 20 : 0) - statWidth
        let fragment = ProseTypesetter.layout(
            attributed, origin: CGPoint(x: textX, y: 0), textStart: 0, width: available, lineSpacing: 0, truncate: true,
            lineHeight: height)
        let textWidth = min(available, ProseTypesetter.width(attributed))
        let statusColor: CGColor =
            switch item.status {
            case .done: theme.success
            case .failed: theme.failure
            case .preparing, .running: theme.running
            case .unknown: theme.tertiary
            }
        var labels = [
            Label(
                glyph: Glyph.status(item.status), glyphColor: statusColor, point: .zero,
                glyphRect: CGRect(x: x, y: floor((height - 14) / 2), width: 14, height: 14))
        ]
        let baseline = fragment.frame.minY + {
            if case .lines(let lines) = fragment.content, let first = lines.first { return first.baseline }
            return 17
        }()
        var cursor = textX + textWidth + 8
        for (line, lineWidth) in statLines {
            labels.append(Label(line: line, point: CGPoint(x: cursor, y: baseline)))
            cursor += lineWidth + 4
        }
        if !statLines.isEmpty { cursor += 2 }
        var hotspots: [Hotspot] = []
        if hasDetail {
            let expanded = RenderBlocks.isExpanded(.tool(item.id), content: content, ui: ui)
            labels.append(
                Label(
                    glyph: expanded ? .chevronDown : .chevronRight, glyphColor: theme.quaternary, point: .zero,
                    glyphRect: CGRect(x: cursor - 3, y: floor((height - 11) / 2), width: 11, height: 11)))
            hotspots.append(
                Hotspot(
                    rect: CGRect(x: x - 4, y: 1, width: cursor + 12 - x, height: height - 2), action: .toggle(.tool(item.id)),
                    label: expanded ? "Hide details" : "Show details"))
        }
        return BlockLayout(
            size: CGSize(width: width, height: height), plainLength: fragment.length, fragments: [fragment], labels: labels,
            hotspots: hotspots, kindTag: .tool)
    }

    /// Tool input and output in a `codeFill` box (mono, scrolls when long or wide).
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
        let padding: CGFloat = 12
        let contentHeight = mono.height + 2 * 8
        let viewportHeight = min(contentHeight, TranscriptTheme.toolOutputMaxHeight)
        let viewport = CGRect(x: x, y: 0, width: width, height: viewportHeight)
        let content = CGSize(width: max(width, mono.contentWidth + 2 * padding), height: contentHeight)
        let fragment = Fragment(
            origin: CGPoint(x: x + padding, y: 8), textStart: 0, length: (text as NSString).length,
            width: max(mono.contentWidth, width - 2 * padding), height: mono.height, content: .mono(mono), scrolls: true)
        var decorations = [Decoration(rect: viewport, fill: theme.codeBackground, stroke: theme.codeBorder, radius: DS.Radius.md)]
        if !item.input.isEmpty, !item.output.isEmpty {
            // A hairline between input and output.
            let inputLines = item.input.utf16.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
            let y = 8 + CGFloat(inputLines) * mono.lineHeight + mono.lineHeight / 2
            decorations.append(Decoration(rect: CGRect(x: x + padding, y: y, width: content.width - 2 * padding, height: 1), fill: theme.separator, scrolls: true))
        }
        return BlockLayout(
            size: CGSize(width: x + width, height: viewportHeight), plainLength: fragment.length, fragments: [fragment],
            decorations: decorations, scroll: ScrollArea(viewport: viewport, contentSize: content), kindTag: .toolDetail)
    }

    // MARK: Cards

    /// The to-do card: `r.lg`, fill only in dark, `border` 70 % in light; header `meta` medium `text3`.
    static func layoutTodo(_ list: TodoListContent, width: CGFloat, fonts: TranscriptFonts) -> BlockLayout {
        let theme = fonts.theme
        let text = RenderBlocks.todoText(list)
        let attributed = NSMutableAttributedString(attributedString: fonts.plain(text, font: fonts.ui, color: theme.text))
        let ns = text as NSString
        let firstLine = ns.range(of: "\n").location == NSNotFound ? ns.length : ns.range(of: "\n").location
        attributed.addAttributes(fonts.attributes(font: fonts.smallBold, color: theme.tertiary), range: NSRange(location: 0, length: firstLine))
        var strikes: [Range<Int>] = []
        var location = firstLine + 1
        for item in list.items {
            let length = (item.text as NSString).length + 2
            guard location + length <= ns.length else { break }
            let range = NSRange(location: location, length: length)
            switch item.state {
            case .completed, .cancelled:
                attributed.addAttributes(fonts.attributes(font: fonts.ui, color: theme.tertiary), range: range)
                strikes.append((location + 2)..<(location + length))
            case .inProgress:
                attributed.addAttributes(fonts.attributes(font: fonts.uiMedium, color: theme.text), range: range)
            case .pending:
                break
            }
            location += length + 1
        }
        let fragment = ProseTypesetter.layout(
            attributed, origin: CGPoint(x: 14, y: 10), textStart: 0, width: width - 28, lineSpacing: 0, strikes: strikes,
            strikeColor: theme.tertiary, fallbackFont: fonts.ui, lineHeight: theme.uiLineHeight + 4)
        let size = CGSize(width: width, height: fragment.height + 20)
        return BlockLayout(
            size: size, plainLength: fragment.length, fragments: [fragment],
            decorations: [Decoration(rect: CGRect(origin: .zero, size: size), fill: theme.cardBackground, stroke: theme.codeBorder, radius: DS.Radius.lg)],
            kindTag: .card)
    }

    static func layoutFile(_ file: FileChip, imageSizes: [String: CGSize], width: CGFloat, fonts: TranscriptFonts) -> BlockLayout {
        let theme = fonts.theme
        if file.isImage {
            let rect = imageRect(source: file.uri, x: 0, width: min(width, 480), maxHeight: 280, imageSizes: imageSizes)
                ?? CGRect(x: 0, y: 0, width: 200, height: 120)
            let caption = ProseTypesetter.layout(
                fonts.plain(file.name, font: fonts.small, color: theme.tertiary), origin: CGPoint(x: 0, y: rect.maxY + 4), textStart: 0,
                width: width, truncate: true)
            return BlockLayout(
                size: CGSize(width: width, height: caption.frame.maxY), plainLength: caption.length, fragments: [caption],
                decorations: [Decoration(rect: rect, fill: theme.codeBackground, stroke: theme.codeBorder, radius: DS.Radius.md)],
                hotspots: [Hotspot(rect: rect, action: .openFile(file.uri), label: "Open \(file.name)")],
                images: [BlockImage(source: file.uri, rect: rect, radius: DS.Radius.md)], kindTag: .image)
        }
        let name = fonts.plain(file.name, font: fonts.ui, color: theme.text)
        let height: CGFloat = DS.Size.control
        let fragment = ProseTypesetter.layout(
            name, origin: CGPoint(x: 30, y: 0), textStart: 0, width: min(width - 40, 420), lineSpacing: 0, truncate: true, lineHeight: height)
        let chipWidth = min(width, ProseTypesetter.width(name) + 42)
        let size = CGSize(width: width, height: height)
        let chip = CGRect(x: 0, y: 0, width: chipWidth, height: size.height)
        return BlockLayout(
            size: size, plainLength: fragment.length, fragments: [fragment],
            decorations: [Decoration(rect: chip, fill: theme.cardBackground, stroke: theme.codeBorder ?? theme.separator, radius: DS.Radius.md)],
            labels: [Label(glyph: .file, glyphColor: theme.icon, point: .zero, glyphRect: CGRect(x: 9, y: floor((size.height - 14) / 2), width: 14, height: 14))],
            hotspots: [Hotspot(rect: chip, action: .openFile(file.uri), label: "Open \(file.name)")], kindTag: .card)
    }

    /// An HTML visual: a title line with ghost Open and Save actions, then the snapshot (or a placeholder while rendering).
    static func layoutVisual(_ visual: VisualCardContent, width: CGFloat, fonts: TranscriptFonts) -> BlockLayout {
        let theme = fonts.theme
        let text = RenderBlocks.visualText(visual)
        let titleLength = (visual.title as NSString).length
        let attributed = NSMutableAttributedString(attributedString: fonts.plain(text, font: fonts.small, color: theme.tertiary))
        attributed.addAttributes(fonts.attributes(font: fonts.uiMedium, color: theme.text), range: NSRange(location: 0, length: titleLength))
        let actions = [("Open in Browser", "open"), ("Save Image", "save")]
        let actionLines = actions.map { (CTLineCreateWithAttributedString(fonts.plain($0.0, font: fonts.ui, color: theme.secondary)), $0.1, $0.0) }
        let actionsWidth = actionLines.reduce(CGFloat(0)) { $0 + CGFloat(CTLineGetTypographicBounds($1.0, nil, nil, nil)) + 18 }
        let lineHeight = DS.Size.controlSmall
        let title = ProseTypesetter.layout(
            attributed, origin: CGPoint(x: 0, y: 0), textStart: 0, width: max(80, width - actionsWidth - 8), lineSpacing: 0, truncate: true,
            lineHeight: lineHeight)
        let imageWidth = min(width, 720)
        let rect = CGRect(x: 0, y: title.frame.maxY + 6, width: imageWidth, height: CGFloat(visual.displayHeight))
        var labels: [Label] = []
        var hotspots: [Hotspot] = [Hotspot(rect: rect, action: .openFile(visual.actionURL("focus")), label: "Interact with \(visual.title)")]
        let baseline: CGFloat = {
            if case .lines(let lines) = title.content, let first = lines.first { return first.baseline }
            return 16
        }()
        var x = width - 8
        for (line, verb, name) in actionLines.reversed() {
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            x -= lineWidth
            labels.append(Label(line: line, point: CGPoint(x: x, y: baseline)))
            hotspots.append(Hotspot(rect: CGRect(x: x - 8, y: 0, width: lineWidth + 16, height: lineHeight), action: .openFile(visual.actionURL(verb)), label: name))
            x -= 18
        }
        var images: [BlockImage] = []
        if visual.status == .ready { images.append(BlockImage(source: visual.imageSource(dark: theme.isDark), rect: rect, radius: DS.Radius.md)) }
        return BlockLayout(
            size: CGSize(width: width, height: rect.maxY + 4), plainLength: title.length, fragments: [title],
            decorations: [Decoration(rect: rect, fill: theme.codeBackground, stroke: theme.codeBorder ?? theme.separator, radius: DS.Radius.md)],
            labels: labels, hotspots: hotspots, images: images, kindTag: .image)
    }

    /// A sub-agent card: status glyph + title `bodyEmph`, `@agent · Status · 12s` in `meta text3` (the status word in its
    /// tone when it needs attention), and a ghost "Open ↗" action.
    static func layoutSubagent(_ card: SubagentCardContent, width: CGFloat, fonts: TranscriptFonts) -> BlockLayout {
        let theme = fonts.theme
        let text = RenderBlocks.subagentText(card)
        let ns = text as NSString
        let titleLength = (card.title as NSString).length
        let attributed = NSMutableAttributedString(attributedString: fonts.plain(text, font: fonts.small, color: theme.tertiary))
        attributed.addAttributes(fonts.attributes(font: fonts.uiMedium, color: theme.text), range: NSRange(location: 0, length: titleLength))
        let wordColor: CGColor? =
            switch card.status {
            case .failed: theme.failure
            case .needsYou: theme.warning
            default: nil
            }
        if let wordColor {
            let range = ns.range(of: card.status.label, options: .backwards)
            if range.location != NSNotFound { attributed.addAttributes(fonts.attributes(font: fonts.small, color: wordColor), range: range) }
        }
        let openWidth: CGFloat = card.childSessionID == nil ? 0 : 76
        let fragment = ProseTypesetter.layout(
            attributed, origin: CGPoint(x: 36, y: 10), textStart: 0, width: width - 50 - openWidth, lineSpacing: 2)
        let size = CGSize(width: width, height: fragment.height + 20)
        let statusColor: CGColor =
            switch card.status {
            case .running, .waitingOnChildren: theme.running
            case .done: theme.success
            case .failed: theme.failure
            case .needsYou: theme.warning
            case .unknown, .stopped: theme.tertiary
            }
        let glyph: Glyph =
            switch card.status {
            case .running, .waitingOnChildren: .running
            case .done: .check
            case .failed, .needsYou: .warning
            case .unknown, .stopped: .dot
            }
        var labels = [Label(glyph: glyph, glyphColor: statusColor, point: .zero, glyphRect: CGRect(x: 14, y: 13, width: 14, height: 14))]
        var hotspots: [Hotspot] = []
        if let child = card.childSessionID {
            let open = CTLineCreateWithAttributedString(fonts.plain("Open", font: fonts.ui, color: theme.secondary))
            let openTextWidth = CGFloat(CTLineGetTypographicBounds(open, nil, nil, nil))
            let button = CGRect(x: width - 12 - (openTextWidth + 34), y: floor((size.height - 24) / 2), width: openTextWidth + 34, height: 24)
            labels.append(Label(line: open, point: CGPoint(x: button.minX + 10, y: button.minY + 16)))
            labels.append(
                Label(glyph: .arrowUpRight, glyphColor: theme.secondary, point: .zero, glyphRect: CGRect(x: button.maxX - 22, y: button.minY + 6, width: 12, height: 12)))
            hotspots.append(Hotspot(rect: button, action: .openChild(child), label: "Open sub-agent thread"))
        }
        return BlockLayout(
            size: size, plainLength: fragment.length, fragments: [fragment],
            decorations: [Decoration(rect: CGRect(origin: .zero, size: size), fill: theme.cardBackground, stroke: theme.codeBorder, radius: DS.Radius.lg)],
            labels: labels, hotspots: hotspots, kindTag: .card)
    }

    // MARK: Estimates

    /// Cheap height estimate without typesetting, used until a row is measured exactly.
    public static func estimate(_ row: TranscriptRow, width: CGFloat, theme: TranscriptTheme, topPadding: CGFloat) -> CGFloat {
        let lineHeight = theme.proseLineHeight
        let monoLine = theme.monoLineHeight
        let charsPerLine = max(20, width / (theme.bodySize * 0.5))
        func prose(_ text: String) -> CGFloat {
            var height: CGFloat = 0
            var fenced = false
            var paragraph = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("```") || line.hasPrefix("~~~") {
                    fenced.toggle()
                    height += fenced ? TranscriptTheme.codeHeaderHeight + TranscriptTheme.codePaddingTop + TranscriptTheme.codePaddingBottom + TranscriptTheme.blockSpacing : 0
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
            height += TranscriptTheme.summaryRowHeight
        case .work(let group):
            let visible = group.isCollapsible ? group.items.filter { !$0.status.isSuccess }.count + 1 : group.items.count
            height += CGFloat(visible) * TranscriptTheme.toolRowHeight
        case .todo(let list):
            height += CGFloat(list.items.count + 1) * (lineHeight + 2) + 18
        case .file(let file):
            height += file.isImage ? 140 : lineHeight + 12
        case .subagent:
            height += 2 * lineHeight + 18
        case .visual(let visual):
            height += visual.displayHeight + lineHeight + 14
        case .error(let error):
            height += prose(error.message) + lineHeight + 18
        case .lifecycle, .working, .unknown:
            height += lineHeight + 8
        }
        return ceil(height)
    }
}
