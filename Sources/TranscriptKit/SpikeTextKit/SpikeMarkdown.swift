// G1-A spike: a small Markdown block splitter and inline styler covering the workload (headings, nested lists,
// links, inline code, emphasis, GFM tables, fenced code), plus the message renderer. Not a CommonMark
// implementation: production would use swift-markdown (see docs/research/02-content-surfaces.md, section 1).

import Foundation

public enum SpikeMarkdown {
    public enum Kind: Sendable, Equatable {
        case paragraph, heading(Int), list, code(String), table
    }

    public struct Block: Sendable {
        public var kind: Kind
        public var lines: [Substring]
        /// True when a complete line follows the block, so more input cannot change it (streaming commit rule).
        public var closed: Bool
        /// UTF-8 offset in the parsed source just past the block's last line.
        public var sourceEnd: Int
    }

    // MARK: Block splitting

    public static func blocks(_ source: Substring) -> [Block] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        // `split` yields a trailing partial line (possibly empty) when the source does not end mid-line.
        var ends: [Int] = []
        ends.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            offset += line.utf8.count + 1
            ends.append(min(offset, source.utf8.count))
        }
        let lastIndex = lines.count - 1
        var blocks: [Block] = []
        var i = 0
        func isBlank(_ line: Substring) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }
        func isFence(_ line: Substring) -> Bool { line.drop(while: { $0 == " " }).hasPrefix("```") }
        func isHeading(_ line: Substring) -> Bool {
            let hashes = line.prefix(while: { $0 == "#" }).count
            return hashes >= 1 && hashes <= 6 && line.dropFirst(hashes).first == " "
        }
        func isListItem(_ line: Substring) -> Bool {
            let body = line.drop(while: { $0 == " " })
            if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") { return true }
            let digits = body.prefix(while: { $0.isASCII && $0.isNumber })
            return !digits.isEmpty && body.dropFirst(digits.count).hasPrefix(". ")
        }
        func isTableStart(_ index: Int) -> Bool {
            index + 1 <= lastIndex && lines[index].hasPrefix("|") && lines[index + 1].hasPrefix("|")
                && lines[index + 1].contains("---")
        }
        while i <= lastIndex {
            let line = lines[i]
            if isBlank(line) { i += 1; continue }
            let start = i
            var kind: Kind
            var closed = false
            if isFence(line) {
                kind = .code(String(line.drop(while: { $0 == " " }).dropFirst(3)).trimmingCharacters(in: .whitespaces))
                i += 1
                while i <= lastIndex, !(lines[i].drop(while: { $0 == " " }) == "```") { i += 1 }
                if i <= lastIndex {
                    closed = i < lastIndex
                    blocks.append(Block(kind: kind, lines: Array(lines[(start + 1)..<i]), closed: closed, sourceEnd: ends[i]))
                    i += 1
                } else {
                    // Unclosed fence (valid to end of input); the opening line itself may be the partial last line.
                    let body = start + 1 <= lastIndex ? Array(lines[(start + 1)...lastIndex]) : []
                    blocks.append(Block(kind: kind, lines: body, closed: false, sourceEnd: ends[lastIndex]))
                }
                continue
            } else if isTableStart(i) {
                kind = .table
                i += 2
                while i <= lastIndex, lines[i].hasPrefix("|") { i += 1 }
            } else if isHeading(line) {
                kind = .heading(line.prefix(while: { $0 == "#" }).count)
                i += 1
            } else if isListItem(line) {
                kind = .list
                i += 1
                while i <= lastIndex, isListItem(lines[i]) { i += 1 }
            } else {
                kind = .paragraph
                i += 1
                while i <= lastIndex, !isBlank(lines[i]), !isFence(lines[i]), !isHeading(lines[i]), !isListItem(lines[i]),
                      !isTableStart(i) { i += 1 }
            }
            // Closed when the line that stopped the block is complete (not the trailing partial line).
            closed = i <= lastIndex && i < lastIndex
            if i > lastIndex { closed = false }
            var blockLines = Array(lines[start..<i])
            if kind == .table, blockLines.count >= 2 { blockLines.remove(at: 1) }
            blocks.append(Block(kind: kind, lines: blockLines, closed: closed, sourceEnd: ends[i - 1]))
        }
        return blocks
    }

    // MARK: Rendering

    public static func render(_ markdown: String, into rich: inout SpikeRich, user: Bool = false) {
        for block in blocks(Substring(markdown)) { render(block, into: &rich, user: user) }
    }

    public static func render(_ block: Block, into rich: inout SpikeRich, user: Bool = false) {
        let base: SpikeBlock = user ? .user : .none
        switch block.kind {
        case .paragraph:
            inline(block.lines.joined(separator: " ")[...], style: .body, into: &rich)
            rich.endParagraph(SpikeParaStyle(block: base))
        case let .heading(level):
            let text = block.lines[0].drop(while: { $0 == "#" }).dropFirst()
            inline(text, style: level <= 1 ? .heading1 : level == 2 ? .heading2 : .heading3, into: &rich)
            var style = SpikeParaStyle(block: base)
            style.heading = UInt8(level)
            rich.endParagraph(style)
        case .list:
            for line in block.lines {
                let spaces = line.prefix(while: { $0 == " " }).count
                var body = line.dropFirst(spaces)
                var marker = "•"
                if body.first == "-" || body.first == "*" || body.first == "+" {
                    body = body.dropFirst(2)
                    if spaces >= 2 { marker = spaces >= 4 ? "▪" : "◦" }
                } else {
                    let digits = body.prefix(while: { $0.isASCII && $0.isNumber })
                    marker = "\(digits)."
                    body = body.dropFirst(digits.count + 2)
                }
                rich.append(marker + "\t", .body)
                inline(body, style: .body, into: &rich)
                var style = SpikeParaStyle(block: base)
                style.isList = true
                style.listDepth = UInt8(min(spaces / 2, 4))
                rich.endParagraph(style)
            }
        case let .code(language):
            let first = rich.paragraphCount
            let lines = block.lines.isEmpty ? [""] : block.lines
            for line in lines {
                highlight(line, language: language, into: &rich)
                rich.endParagraph(SpikeParaStyle(block: .code))
            }
            rich.assignBlock(.code, fromParagraph: first)
        case .table:
            renderTable(block.lines, into: &rich)
        }
    }

    static func renderTable(_ lines: [Substring], into rich: inout SpikeRich) {
        let rows: [[Substring]] = lines.map { line in
            var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces)[...] }
            if cells.first?.isEmpty == true { cells.removeFirst() }
            if cells.last?.isEmpty == true { cells.removeLast() }
            return cells.map { Substring($0) }
        }
        let columnCount = rows.map(\.count).max() ?? 0
        var widths = Array(repeating: 1, count: columnCount)
        for row in rows {
            for (c, cell) in row.enumerated() { widths[c] = min(30, max(widths[c], cell.filter { $0 != "`" }.count)) }
        }
        let first = rich.paragraphCount
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() {
                if c > 0 { rich.append("\t", .tableCell) }
                rich.append(cell.filter { $0 != "`" }, r == 0 ? .tableHeader : .tableCell)
            }
            var style = SpikeParaStyle(block: .table)
            style.columns = widths
            rich.endParagraph(style)
        }
        rich.assignBlock(.table, fromParagraph: first)
    }

    /// Inline Markdown: `code`, **bold**, *italic*, [label](url). Unclosed delimiters render literally.
    public static func inline(_ text: Substring, style: SpikeInline, into rich: inout SpikeRich) {
        let utf8 = text.utf8
        var i = text.startIndex
        var plainStart = i
        func flush(_ upTo: String.Index) {
            if plainStart < upTo { rich.append(text[plainStart..<upTo], style) }
        }
        while i < text.endIndex {
            let byte = utf8[i]
            if byte == UInt8(ascii: "`") {
                let after = utf8.index(after: i)
                if let close = utf8[after...].firstIndex(of: UInt8(ascii: "`")) {
                    flush(i)
                    rich.append(text[after..<close], .inlineCode)
                    i = utf8.index(after: close)
                    plainStart = i
                    continue
                }
            } else if byte == UInt8(ascii: "*") {
                let after = utf8.index(after: i)
                let double = after < text.endIndex && utf8[after] == UInt8(ascii: "*")
                let contentStart = double ? utf8.index(after: after) : after
                if contentStart < text.endIndex, let close = utf8[contentStart...].firstIndex(of: UInt8(ascii: "*")),
                   close > contentStart {
                    let closeEnd = double ? utf8.index(close, offsetBy: 2, limitedBy: text.endIndex) : utf8.index(after: close)
                    if let closeEnd, !double || utf8[utf8.index(after: close)] == UInt8(ascii: "*") {
                        flush(i)
                        rich.append(text[contentStart..<close], double ? .bold : .italic)
                        i = closeEnd
                        plainStart = i
                        continue
                    }
                }
            } else if byte == UInt8(ascii: "[") {
                let after = utf8.index(after: i)
                if let mid = utf8[after...].firstIndex(of: UInt8(ascii: "]")) {
                    let paren = utf8.index(after: mid)
                    if paren < text.endIndex, utf8[paren] == UInt8(ascii: "("),
                       let close = utf8[paren...].firstIndex(of: UInt8(ascii: ")")) {
                        flush(i)
                        rich.appendLink(String(text[after..<mid]), url: String(text[utf8.index(after: paren)..<close]))
                        i = utf8.index(after: close)
                        plainStart = i
                        continue
                    }
                }
            }
            i = utf8.index(after: i)
        }
        flush(text.endIndex)
    }

    private static let keywords: Set<Substring> = [
        "let", "var", "func", "return", "if", "else", "guard", "throw", "throws", "try", "await", "async", "for",
        "in", "const", "export", "function", "def", "not", "yield", "pub", "fn", "match", "nil", "true", "false",
        "import", "struct", "class", "enum", "case", "switch", "while", "then", "fi", "echo", "package", "type",
        "interface", "None", "Some", "err", "self", "Self", "static", "private", "public", "mut",
    ]

    /// Cheap keyword/string/comment/number colouring. The cost model matters for the spike, not fidelity.
    public static func highlight(_ line: Substring, language: String, into rich: inout SpikeRich) {
        let hashComments = language == "python" || language == "bash" || language == "sh"
        let utf8 = line.utf8
        var i = line.startIndex
        var plainStart = i
        func flush(_ upTo: String.Index) { if plainStart < upTo { rich.append(line[plainStart..<upTo], .code) } }
        while i < line.endIndex {
            let byte = utf8[i]
            let next = utf8.index(after: i)
            if (byte == UInt8(ascii: "/") && next < line.endIndex && utf8[next] == UInt8(ascii: "/"))
                || (hashComments && byte == UInt8(ascii: "#")) {
                flush(i)
                rich.append(line[i...], .codeComment)
                return
            }
            if byte == UInt8(ascii: "\"") {
                let close = utf8[next...].firstIndex(of: UInt8(ascii: "\"")).map { utf8.index(after: $0) } ?? line.endIndex
                flush(i)
                rich.append(line[i..<close], .codeString)
                i = close
                plainStart = i
                continue
            }
            if byte >= 48 && byte <= 57 {
                var end = next
                while end < line.endIndex, (48...57).contains(utf8[end]) { end = utf8.index(after: end) }
                flush(i)
                rich.append(line[i..<end], .codeNumber)
                i = end
                plainStart = i
                continue
            }
            if (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95 {
                var end = next
                while end < line.endIndex {
                    let b = utf8[end]
                    if (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || (b >= 48 && b <= 57) {
                        end = utf8.index(after: end)
                    } else { break }
                }
                let word = line[i..<end]
                if keywords.contains(word) {
                    flush(i); rich.append(word, .codeKeyword); plainStart = end
                } else if byte >= 65 && byte <= 90 {
                    flush(i); rich.append(word, .codeType); plainStart = end
                }
                i = end
                continue
            }
            i = next
        }
        flush(line.endIndex)
    }
}

// MARK: - Message renderer

public enum SpikeRenderer {
    public static func render(_ message: SpikeMessage, expanded: Set<String> = []) -> SpikeRich {
        var rich = SpikeRich()
        rich.append(message.role == .user ? "You" : "Assistant", .roleLabel)
        rich.endParagraph(SpikeParaStyle(block: .roleLabel))
        for part in message.parts {
            switch part {
            case let .markdown(text):
                let first = rich.paragraphCount
                SpikeMarkdown.render(text, into: &rich, user: message.role == .user)
                if message.role == .user { rich.assignBlock(.user, fromParagraph: first, keepOthers: true) }
            case let .tool(tool):
                rich.append(renderTool(tool, expanded: expanded.contains(tool.id)))
            case let .reasoning(id, text):
                rich.append(renderReasoning(id: id, text: text, expanded: expanded.contains(id)))
            case let .diff(diff):
                rich.append(renderDiff(diff))
            case let .image(image):
                rich.appendImage(image)
                rich.endParagraph(SpikeParaStyle(block: .image))
                rich.append("\(image.id).png · \(image.width)×\(image.height)", .caption)
                rich.endParagraph(SpikeParaStyle())
            }
        }
        return rich
    }

    public static func renderTool(_ tool: SpikeTool, expanded: Bool) -> SpikeRich {
        var rich = SpikeRich()
        let headerStart = rich.length
        rich.append(expanded ? "▾  " : "▸  ", .toolHeader)
        rich.append(tool.name, .bold)
        rich.append("  \(tool.title)  ·  ", .toolHeader)
        rich.append(tool.status, tool.status == "completed" ? .toolStatusOK : .toolStatusBad)
        rich.append("  ·  \(tool.output.count) lines", .secondary)
        rich.endParagraph(SpikeParaStyle(block: .toolHeader, pos: expanded ? .first : .only))
        rich.cardHeaders.append(SpikeSpan(location: headerStart, length: rich.length - headerStart, value: tool.id))
        if expanded {
            let bodyStart = rich.length
            let first = rich.paragraphCount
            for line in tool.output {
                rich.append(line, .toolBody)
                rich.endParagraph(SpikeParaStyle(block: .toolBody))
            }
            rich.assignBlock(.toolBody, fromParagraph: first, lastOnly: true)
            rich.cardBodies.append(SpikeSpan(location: bodyStart, length: rich.length - bodyStart, value: tool.id))
        }
        return rich
    }

    public static func renderReasoning(id: String, text: String, expanded: Bool) -> SpikeRich {
        var rich = SpikeRich()
        let words = text.split(separator: " ").count
        rich.append(expanded ? "▾  " : "▸  ", .toolHeader)
        rich.append("Thinking", .bold)
        rich.append("  ·  \(words) words", .secondary)
        rich.endParagraph(SpikeParaStyle(block: .reasoningHeader, pos: expanded ? .first : .only))
        rich.cardHeaders.append(SpikeSpan(location: 0, length: rich.length, value: id))
        if expanded {
            let bodyStart = rich.length
            let first = rich.paragraphCount
            for paragraph in text.split(separator: "\n\n") {
                SpikeMarkdown.inline(paragraph, style: .reasoning, into: &rich)
                rich.endParagraph(SpikeParaStyle(block: .reasoningBody))
            }
            rich.assignBlock(.reasoningBody, fromParagraph: first, lastOnly: true)
            rich.cardBodies.append(SpikeSpan(location: bodyStart, length: rich.length - bodyStart, value: id))
        }
        return rich
    }

    public static func renderDiff(_ diff: SpikeDiff) -> SpikeRich {
        var rich = SpikeRich()
        rich.append(diff.path, .diffHeader)
        rich.endParagraph(SpikeParaStyle(block: .diffHeader, pos: .first))
        let body = diff.lines.filter { !$0.hasPrefix("---") && !$0.hasPrefix("+++") }
        for (n, line) in body.enumerated() {
            let block: SpikeBlock
            let style: SpikeInline
            switch line.first {
            case "@": block = .diffHunk; style = .diffHunk
            case "+": block = .diffAdd; style = .diffAdd
            case "-": block = .diffDel; style = .diffDel
            default: block = .diffContext; style = .diffContext
            }
            rich.append(line, style)
            rich.endParagraph(SpikeParaStyle(block: block, pos: n == body.count - 1 ? .last : .middle))
        }
        return rich
    }
}

extension SpikeRich {
    /// Sets the block kind and first/middle/last positions on paragraphs from `start` to the end.
    /// `keepOthers` keeps list/heading settings; `lastOnly` marks only the final paragraph `.last` (others middle).
    public mutating func assignBlock(_ block: SpikeBlock, fromParagraph start: Int, keepOthers: Bool = true, lastOnly: Bool = false) {
        let count = paragraphCount - start
        guard count > 0 else { return }
        for offset in 0..<count {
            let pos: SpikePos
            if lastOnly {
                pos = offset == count - 1 ? .last : .middle
            } else {
                pos = count == 1 ? .only : offset == 0 ? .first : offset == count - 1 ? .last : .middle
            }
            updateParagraph(start + offset) { style in
                style.block = block
                style.pos = pos
                if !keepOthers { style.isList = false; style.heading = 0 }
            }
        }
    }
}
