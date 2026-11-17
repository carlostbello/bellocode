import Foundation
import Markdown

/// GFM Markdown to `MarkdownBlock`s through swift-markdown (cmark-gfm). Pure; safe on any thread (each call owns its
/// parse tree). Smart punctuation is off so copied code and quotes stay byte-exact.
public enum MarkdownParser {
    /// Parses `source` into top-level constructs with their UTF-8 source ranges.
    public static func parse(_ source: String) -> [TopLevelBlock] {
        guard !source.isEmpty else { return [] }
        let document = Document(parsing: source, options: [.disableSmartOpts])
        let lines = LineTable(source)
        var result: [TopLevelBlock] = []
        for child in document.children {
            var converter = Converter()
            converter.block(child, indent: 0, quote: 0)
            // Starts are line starts: an indented construct (indented code, " > quote") begins at its line, and
            // re-parsing from mid-line would read it differently.
            let start = child.range.map { lines.lineStart($0.lowerBound) } ?? (result.last?.sourceEnd ?? 0)
            let end = child.range.map { lines.offset($0.upperBound) } ?? start
            result.append(TopLevelBlock(blocks: converter.blocks, sourceStart: start, sourceEnd: max(start, end)))
        }
        return result
    }

    /// The flat block list for `source`.
    public static func blocks(_ source: String) -> [MarkdownBlock] { parse(source).flatMap(\.blocks) }

    /// Whether `source` defines link references (`[name]: url`), which can change earlier blocks: incremental
    /// re-parsing is then disabled.
    public static func hasReferenceDefinitions(_ source: Substring) -> Bool {
        // Line by line: a definition starts a line with up to three spaces, then `[label]:`.
        var lineStart = true
        var spaces = 0
        var inLabel = false
        var afterLabel = false
        for byte in source.utf8 {
            if byte == 10 {
                lineStart = true
                spaces = 0
                inLabel = false
                afterLabel = false
                continue
            }
            if afterLabel {
                if byte == 58 { return true }  // :
                lineStart = false
                afterLabel = false
                continue
            }
            if inLabel {
                if byte == 93 { inLabel = false; afterLabel = true }  // ]
                continue
            }
            guard lineStart else { continue }
            if byte == 32, spaces < 3 {
                spaces += 1
            } else if byte == 91 {  // [
                inLabel = true
            } else {
                lineStart = false
            }
        }
        return false
    }

    // MARK: Conversion

    private struct Converter {
        var blocks: [MarkdownBlock] = []

        mutating func block(_ markup: any Markup, indent: Int, quote: Int, marker: (String, Bool?)? = nil) {
            switch markup {
            case let paragraph as Paragraph:
                // A paragraph that is only an image becomes an image block.
                let children = Array(paragraph.children)
                if marker == nil, children.count == 1, let image = children[0] as? Image {
                    blocks.append(MarkdownBlock(.image(source: image.source ?? "", alt: image.plainText), indent: indent, quoteDepth: quote))
                    return
                }
                let text = Converter.inline(paragraph)
                if let (mark, checkbox) = marker {
                    blocks.append(MarkdownBlock(.listItem(marker: mark, checkbox: checkbox, text), indent: indent, quoteDepth: quote))
                } else {
                    blocks.append(MarkdownBlock(.paragraph(text), indent: indent, quoteDepth: quote))
                }
            case let heading as Heading:
                emitMarkerIfNeeded(marker, indent: indent, quote: quote)
                blocks.append(MarkdownBlock(.heading(level: heading.level, Converter.inline(heading)), indent: indent, quoteDepth: quote))
            case let code as CodeBlock:
                emitMarkerIfNeeded(marker, indent: indent, quote: quote)
                var text = code.code
                if text.hasSuffix("\n") { text.removeLast() }
                let language = code.language?.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
                blocks.append(
                    MarkdownBlock(.code(language: language?.isEmpty == true ? nil : language, code: text), indent: indent, quoteDepth: quote))
            case let html as HTMLBlock:
                emitMarkerIfNeeded(marker, indent: indent, quote: quote)
                var text = html.rawHTML
                if text.hasSuffix("\n") { text.removeLast() }
                blocks.append(MarkdownBlock(.code(language: "html", code: text), indent: indent, quoteDepth: quote))
            case let quoteBlock as BlockQuote:
                emitMarkerIfNeeded(marker, indent: indent, quote: quote)
                for child in quoteBlock.children { block(child, indent: indent, quote: quote + 1) }
            case let list as UnorderedList:
                emitMarkerIfNeeded(marker, indent: indent, quote: quote)
                let bullet = ["•", "◦", "▪"][min(indent, 2)]
                for item in list.listItems { listItem(item, marker: bullet, indent: indent, quote: quote) }
            case let list as OrderedList:
                emitMarkerIfNeeded(marker, indent: indent, quote: quote)
                var number = Int(list.startIndex)
                for item in list.listItems {
                    listItem(item, marker: "\(number).", indent: indent, quote: quote)
                    number += 1
                }
            case is ThematicBreak:
                blocks.append(MarkdownBlock(.rule, indent: indent, quoteDepth: quote))
            case let table as Markdown.Table:
                emitMarkerIfNeeded(marker, indent: indent, quote: quote)
                let header: [StyledText] = Array(table.head.cells.map { Converter.inline($0) })
                let count = header.count
                let rows: [[StyledText]] = Array(table.body.rows.map { row -> [StyledText] in
                    var cells: [StyledText] = Array(row.cells.map { Converter.inline($0) })
                    if cells.count < count { cells += Array(repeating: StyledText(""), count: count - cells.count) }
                    return Array(cells.prefix(count))
                })
                let alignments = (0..<count).map { index -> MarkdownTable.Alignment in
                    let alignment = index < table.columnAlignments.count ? table.columnAlignments[index] : nil
                    switch alignment {
                    case .center: return .center
                    case .right: return .right
                    default: return .left
                    }
                }
                blocks.append(
                    MarkdownBlock(.table(MarkdownTable(header: header, rows: rows, alignments: alignments)), indent: indent, quoteDepth: quote))
            default:
                // Directives, custom blocks: keep their text readable.
                emitMarkerIfNeeded(marker, indent: indent, quote: quote)
                let text = markup.format()
                if !text.isEmpty { blocks.append(MarkdownBlock(.paragraph(StyledText(text)), indent: indent, quoteDepth: quote)) }
            }
        }

        /// A list item whose first child is not a paragraph still shows its marker on a line of its own.
        mutating func emitMarkerIfNeeded(_ marker: (String, Bool?)?, indent: Int, quote: Int) {
            guard let (mark, checkbox) = marker else { return }
            blocks.append(MarkdownBlock(.listItem(marker: mark, checkbox: checkbox, StyledText("")), indent: indent, quoteDepth: quote))
        }

        mutating func listItem(_ item: ListItem, marker: String, indent: Int, quote: Int) {
            let checkbox: Bool? =
                switch item.checkbox {
                case .checked: true
                case .unchecked: false
                case nil: nil
                }
            var first = true
            for child in item.children {
                if first {
                    block(child, indent: indent, quote: quote, marker: (marker, checkbox))
                    first = false
                } else {
                    block(child, indent: indent + 1, quote: quote)
                }
            }
            if first {  // empty item
                blocks.append(MarkdownBlock(.listItem(marker: marker, checkbox: checkbox, StyledText("")), indent: indent, quoteDepth: quote))
            }
        }

        static func inline(_ container: any Markup) -> StyledText {
            var builder = StyledTextBuilder()
            for child in container.children { appendInline(child, traits: [], link: nil, into: &builder) }
            return builder.build()
        }

        static func appendInline(_ markup: any Markup, traits: InlineTraits, link: String?, into builder: inout StyledTextBuilder) {
            switch markup {
            case let text as Markdown.Text:
                builder.append(text.string, traits: traits, link: link)
            case let code as InlineCode:
                builder.append(code.code, traits: traits.union(.code), link: link)
            case is SoftBreak:
                builder.append(" ", traits: traits, link: link)
            case is LineBreak:
                builder.append("\n", traits: traits, link: link)
            case let html as InlineHTML:
                builder.append(html.rawHTML, traits: traits.union(.muted), link: link)
            case let symbol as SymbolLink:
                builder.append(symbol.destination ?? "", traits: traits.union(.code), link: link)
            case let image as Image:
                let alt = image.plainText
                builder.append(alt.isEmpty ? "[image]" : "[\(alt)]", traits: traits.union(.link), link: image.source ?? link)
            case let emphasis as Emphasis:
                for child in emphasis.children { appendInline(child, traits: traits.union(.italic), link: link, into: &builder) }
            case let strong as Strong:
                for child in strong.children { appendInline(child, traits: traits.union(.bold), link: link, into: &builder) }
            case let strike as Strikethrough:
                for child in strike.children { appendInline(child, traits: traits.union(.strike), link: link, into: &builder) }
            case let anchor as Markdown.Link:
                let destination = anchor.destination ?? link
                if anchor.childCount == 0 {
                    builder.append(destination ?? "", traits: traits.union(.link), link: destination)
                }
                for child in anchor.children {
                    appendInline(child, traits: traits.union(.link), link: destination, into: &builder)
                }
            default:
                if let container = markup as? any InlineContainer {
                    for child in container.children { appendInline(child, traits: traits, link: link, into: &builder) }
                } else {
                    builder.append(markup.format(), traits: traits, link: link)
                }
            }
        }
    }
}

/// Converts swift-markdown source locations (1-based line, 1-based UTF-8 column) to UTF-8 offsets.
struct LineTable {
    private var starts: [Int] = [0]
    private let length: Int

    init(_ source: String) {
        var offset = 0
        for byte in source.utf8 {
            offset += 1
            if byte == 10 { starts.append(offset) }
        }
        length = offset
    }

    func lineStart(_ location: SourceLocation) -> Int {
        let line = max(1, location.line)
        return line - 1 < starts.count ? starts[line - 1] : length
    }

    func offset(_ location: SourceLocation) -> Int {
        let line = max(1, location.line)
        guard line - 1 < starts.count else { return length }
        return min(length, starts[line - 1] + max(0, location.column - 1))
    }
}
