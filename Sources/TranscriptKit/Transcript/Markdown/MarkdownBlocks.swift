import Foundation

/// A Markdown block ready for layout, in document order. Nesting (lists, quotes) is flattened into `indent` and
/// `quoteDepth`, so a message is a flat list of blocks that selection and copy can address by index.
public struct MarkdownBlock: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case paragraph(StyledText)
        case heading(level: Int, StyledText)
        /// A list item's first paragraph. `marker` is "•", "1." …; `checkbox` is set for task items.
        case listItem(marker: String, checkbox: Bool?, StyledText)
        case code(language: String?, code: String)
        case table(MarkdownTable)
        case rule
        case image(source: String, alt: String)
    }

    public var kind: Kind
    /// List nesting (0 = top level). Continuation blocks of a list item are indented one level deeper than its marker.
    public var indent: Int
    public var quoteDepth: Int

    public init(_ kind: Kind, indent: Int = 0, quoteDepth: Int = 0) {
        self.kind = kind
        self.indent = indent
        self.quoteDepth = quoteDepth
    }

    /// Text used for selection, copy and find.
    public var plainText: String {
        switch kind {
        case .paragraph(let text), .heading(_, let text): text.text
        case .listItem(let marker, let checkbox, let text):
            (checkbox.map { $0 ? "☑ " : "☐ " } ?? marker + " ") + text.text
        case .code(_, let code): code
        case .table(let table): table.plainText
        case .rule: "———"
        case .image(_, let alt): "[Image: \(alt.isEmpty ? "untitled" : alt)]"
        }
    }

    public var isListItem: Bool {
        if case .listItem = kind { true } else { false }
    }
}

public struct MarkdownTable: Sendable, Hashable {
    public enum Alignment: Sendable, Hashable { case left, center, right }

    public var header: [StyledText]
    public var rows: [[StyledText]]
    public var alignments: [Alignment]

    public init(header: [StyledText], rows: [[StyledText]], alignments: [Alignment]) {
        self.header = header
        self.rows = rows
        self.alignments = alignments
    }

    public var columnCount: Int { header.count }

    /// Tab-separated rows (pastes into spreadsheets).
    public var plainText: String {
        ([header] + rows).map { row in row.map(\.text).joined(separator: "\t") }.joined(separator: "\n")
    }
}

/// One top-level Markdown construct and the blocks it produced, with its UTF-8 source range in the parsed text.
public struct TopLevelBlock: Sendable, Hashable {
    public var blocks: [MarkdownBlock]
    public var sourceStart: Int
    public var sourceEnd: Int

    public init(blocks: [MarkdownBlock], sourceStart: Int, sourceEnd: Int) {
        self.blocks = blocks
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
    }
}
