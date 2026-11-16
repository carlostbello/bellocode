// SPIKE G1-B: small hand-written Markdown subset -> render blocks, plus cheap keyword highlighting.
//
// Covers the workload: ATX headings, paragraphs, nested bullet/ordered lists, fenced code, GFM tables, inline code,
// emphasis, strong and links. Line oriented, and prefix stable at block starts: parsing a source from the start of
// its last block yields the same blocks as a full parse, which is what tail-only re-parse relies on.

import Foundation

public enum SpikeTextStyle: UInt8, Sendable {
    case body, strong, emphasis, inlineCode, link, heading1, heading2, heading3, marker, muted, mutedItalic
    case toolTitle, statusOK, statusError
    // Monospaced token styles.
    case code, keyword, string, comment, number, diffAdd, diffDel, diffHunk, diffMeta
}

public struct SpikeStyleRun: Sendable, Equatable {
    public var location: Int  // UTF-16
    public var length: Int
    public var style: SpikeTextStyle
}

/// Display text with style runs; offsets are UTF-16 so they map 1:1 to NSString/CoreText indices.
public struct SpikeStyledText: Sendable, Equatable {
    public var text: String
    public var runs: [SpikeStyleRun]
    public var utf16Count: Int

    public init(text: String, runs: [SpikeStyleRun] = []) {
        self.text = text
        self.runs = runs
        utf16Count = text.utf16.count
    }
}

public enum SpikeProseKind: Sendable, Equatable {
    case paragraph
    case heading(Int)
    case listItem(level: Int, markerUTF16: Int)
}

public struct SpikeMonoText: Sendable {
    public enum Flavor: Sendable { case code(String), diff, toolOutput }
    public var flavor: Flavor
    public var text: String
    /// UTF-16 offset of the start of each line.
    public var lineStarts: [Int]
    public var utf16Count: Int

    public init(flavor: Flavor, text: String) {
        self.flavor = flavor
        self.text = text
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        lineStarts = starts
        utf16Count = offset
    }
}

public struct SpikeTable: Sendable {
    public var header: [SpikeStyledText]
    public var rows: [[SpikeStyledText]]
}

/// One render block. Its plain text (for selection and copy) is defined by `plainText(expanded:)`.
public enum SpikeBlock: Sendable {
    case prose(SpikeStyledText, SpikeProseKind)
    case code(SpikeMonoText)
    case table(SpikeTable)
    case tool(SpikeTool, output: SpikeMonoText)
    case reasoning(SpikeStyledText)
    case diff(SpikeMonoText)
    case image(SpikeImageRef)

    public var isCollapsible: Bool {
        switch self {
        case .tool, .reasoning: true
        default: false
        }
    }

    public var defaultExpanded: Bool {
        switch self {
        case .tool(let tool, _): tool.expandedByDefault
        case .reasoning: false
        default: true
        }
    }

    /// Header line for collapsible blocks.
    public func headerText(expanded: Bool) -> String {
        let chevron = expanded ? "▾" : "▸"
        switch self {
        case .tool(let tool, let output):
            let lines = output.lineStarts.count
            return "\(chevron) \(tool.name)  \(tool.title)  ·  \(tool.status.rawValue)  ·  \(lines) line\(lines == 1 ? "" : "s")"
        case .reasoning(let text):
            return "\(chevron) Thinking  ·  \(text.utf16Count) chars"
        default:
            return ""
        }
    }

    public func plainText(expanded: Bool) -> String {
        switch self {
        case .prose(let styled, _): styled.text
        case .code(let mono), .diff(let mono): mono.text
        case .table(let table):
            ([table.header] + table.rows).map { $0.map(\.text).joined(separator: "\t") }.joined(separator: "\n")
        case .tool(_, let output):
            expanded ? headerText(expanded: true) + "\n" + output.text : headerText(expanded: false)
        case .reasoning(let text):
            expanded ? headerText(expanded: true) + "\n" + text.text : headerText(expanded: false)
        case .image(let ref):
            "[Image \(Int(ref.pixelSize.width))×\(Int(ref.pixelSize.height))]"
        }
    }

    /// Separator placed before this block when copying, given the previous block.
    func copySeparator(after previous: SpikeBlock) -> String {
        if case .prose(_, .listItem) = self, case .prose(_, .listItem) = previous { return "\n" }
        return "\n\n"
    }
}

public enum SpikeMarkdown {
    /// Parsed block plus the UTF-8 offset in the parsed source where it starts.
    public struct Parsed: Sendable {
        public var block: SpikeBlock
        public var sourceStart: Int
    }

    public static func blocks(for item: SpikeItem) -> [SpikeBlock] {
        var blocks: [SpikeBlock] = []
        for part in item.parts {
            switch part {
            case .markdown(let text): blocks += parse(text).map(\.block)
            case .tool(let tool): blocks.append(.tool(tool, output: SpikeMonoText(flavor: .toolOutput, text: tool.output)))
            case .reasoning(let text): blocks.append(.reasoning(SpikeStyledText(text: text, runs: [])))
            case .diff(let text): blocks.append(.diff(SpikeMonoText(flavor: .diff, text: text)))
            case .image(let ref): blocks.append(.image(ref))
            }
        }
        return blocks
    }

    // MARK: Block parser

    public static func parse(_ source: String) -> [Parsed] {
        // Split into lines with UTF-8 start offsets.
        var lines: [(text: Substring, start: Int)] = []
        var offset = 0
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append((line, offset))
            offset += line.utf8.count + 1
        }
        var result: [Parsed] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].text
            let start = lines[index].start
            if isBlank(line) { index += 1; continue }

            if let fence = fenceInfo(line) {
                var body: [Substring] = []
                index += 1
                while index < lines.count {
                    if lines[index].text.trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) {
                        index += 1
                        break
                    }
                    body.append(lines[index].text)
                    index += 1
                }
                result.append(Parsed(block: .code(SpikeMonoText(flavor: .code(fence.language), text: body.joined(separator: "\n"))),
                                     sourceStart: start))
                continue
            }
            if let level = headingLevel(line) {
                let text = line.dropFirst(level).drop(while: { $0 == " " })
                result.append(Parsed(block: .prose(inline(text), .heading(level)), sourceStart: start))
                index += 1
                continue
            }
            if let item = listItem(line) {
                var text = String(item.text)
                index += 1
                while index < lines.count, !isBlank(lines[index].text), !startsBlock(lines, index),
                      lines[index].text.first == " " {
                    text += " " + lines[index].text.trimmingCharacters(in: .whitespaces)
                    index += 1
                }
                let marker = item.ordered ?? "•"
                var styled = inline(Substring(marker + " " + text))
                let markerLength = (marker + " ").utf16.count
                styled.runs.insert(SpikeStyleRun(location: 0, length: markerLength, style: .marker), at: 0)
                result.append(Parsed(block: .prose(styled, .listItem(level: item.level, markerUTF16: markerLength)),
                                     sourceStart: start))
                continue
            }
            if isTableStart(lines, index) {
                let header = cells(line)
                var rows: [[SpikeStyledText]] = []
                index += 2
                while index < lines.count, lines[index].text.contains("|"), !isBlank(lines[index].text) {
                    var row = cells(lines[index].text)
                    if row.count < header.count {
                        row += Array(repeating: SpikeStyledText(text: ""), count: header.count - row.count)
                    }
                    rows.append(Array(row.prefix(header.count)))
                    index += 1
                }
                result.append(Parsed(block: .table(SpikeTable(header: header, rows: rows)), sourceStart: start))
                continue
            }
            // Paragraph.
            var text = String(line.trimmingCharacters(in: .whitespaces))
            index += 1
            while index < lines.count, !isBlank(lines[index].text), !startsBlock(lines, index) {
                text += " " + lines[index].text.trimmingCharacters(in: .whitespaces)
                index += 1
            }
            result.append(Parsed(block: .prose(inline(Substring(text)), .paragraph), sourceStart: start))
        }
        return result
    }

    private static func isBlank(_ line: Substring) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func startsBlock(_ lines: [(text: Substring, start: Int)], _ index: Int) -> Bool {
        let line = lines[index].text
        return fenceInfo(line) != nil || headingLevel(line) != nil || listItem(line) != nil || isTableStart(lines, index)
    }

    private static func fenceInfo(_ line: Substring) -> (marker: String, language: String)? {
        let trimmed = line.drop(while: { $0 == " " })
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            return (marker, trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func headingLevel(_ line: Substring) -> Int? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level), line.count > level, line[line.index(line.startIndex, offsetBy: level)] == " "
        else { return nil }
        return level
    }

    private static func listItem(_ line: Substring) -> (level: Int, ordered: String?, text: Substring)? {
        let indent = line.prefix(while: { $0 == " " }).count
        let rest = line.dropFirst(indent)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return (indent / 2, nil, rest.dropFirst(2))
        }
        let digits = rest.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count < 4 {
            let after = rest.dropFirst(digits.count)
            if let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " {
                return (indent / 2, String(digits) + String(mark), after.dropFirst(2))
            }
        }
        return nil
    }

    private static func isTableStart(_ lines: [(text: Substring, start: Int)], _ index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].text.contains("|") else { return false }
        let separator = lines[index + 1].text.trimmingCharacters(in: .whitespaces)
        guard separator.contains("-"), separator.contains("|") else { return false }
        return separator.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: Substring) -> [SpikeStyledText] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)[...]
        if trimmed.hasPrefix("|") { trimmed = trimmed.dropFirst() }
        if trimmed.hasSuffix("|") { trimmed = trimmed.dropLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false).map {
            inline(Substring($0.trimmingCharacters(in: .whitespaces)))
        }
    }

    // MARK: Inline parser

    /// Strips inline markup and records style runs (UTF-16 offsets into the display text).
    public static func inline(_ source: Substring) -> SpikeStyledText {
        var output = ""
        var runs: [SpikeStyleRun] = []
        var outLength = 0
        var index = source.startIndex
        func append(_ text: Substring, _ style: SpikeTextStyle?) {
            let length = text.utf16.count
            if let style, length > 0 { runs.append(SpikeStyleRun(location: outLength, length: length, style: style)) }
            output += text
            outLength += length
        }
        var plainStart = index
        func flushPlain(to end: String.Index) {
            if plainStart < end { append(source[plainStart..<end], nil) }
        }
        while index < source.endIndex {
            let character = source[index]
            if character == "`", let close = source[source.index(after: index)...].firstIndex(of: "`") {
                flushPlain(to: index)
                append(source[source.index(after: index)..<close], .inlineCode)
                index = source.index(after: close)
                plainStart = index
                continue
            }
            if character == "*" || character == "_" {
                let isStrong = source[index...].hasPrefix(character == "*" ? "**" : "__")
                let delimiter = isStrong ? String(repeating: character, count: 2) : String(character)
                let contentStart = source.index(index, offsetBy: delimiter.count)
                if contentStart < source.endIndex, source[contentStart] != " ",
                   let close = source[contentStart...].range(of: delimiter), close.lowerBound > contentStart {
                    flushPlain(to: index)
                    append(source[contentStart..<close.lowerBound], isStrong ? .strong : .emphasis)
                    index = close.upperBound
                    plainStart = index
                    continue
                }
            }
            if character == "[", let closeText = source[index...].firstIndex(of: "]"),
               source.index(after: closeText) < source.endIndex, source[source.index(after: closeText)] == "(",
               let closeURL = source[closeText...].firstIndex(of: ")") {
                flushPlain(to: index)
                append(source[source.index(after: index)..<closeText], .link)
                index = source.index(after: closeURL)
                plainStart = index
                continue
            }
            index = source.index(after: index)
        }
        flushPlain(to: source.endIndex)
        return SpikeStyledText(text: output, runs: runs)
    }

    // MARK: Cheap highlighting (one line at a time)

    private static let keywords: Set<String> = [
        "let", "var", "func", "if", "else", "guard", "return", "for", "in", "while", "try", "await", "async", "self",
        "const", "export", "function", "def", "not", "None", "pub", "fn", "match", "mut", "err", "nil", "range",
        "true", "false", "continue", "struct", "class", "enum", "import", "type", "interface", "echo", "grep",
    ]

    /// Style runs for one monospaced line. Bounded: callers pass at most a few hundred characters.
    public static func highlight(line: String, flavor: SpikeMonoText.Flavor) -> [SpikeStyleRun] {
        let utf16 = Array(line.utf16)
        switch flavor {
        case .toolOutput:
            return []
        case .diff:
            guard let first = utf16.first else { return [] }
            let style: SpikeTextStyle? = switch first {
            case 43: line.hasPrefix("+++") ? .diffMeta : .diffAdd  // +
            case 45: line.hasPrefix("---") ? .diffMeta : .diffDel  // -
            case 64: .diffHunk  // @
            default: nil
            }
            return style.map { [SpikeStyleRun(location: 0, length: utf16.count, style: $0)] } ?? []
        case .code:
            var runs: [SpikeStyleRun] = []
            var i = 0
            let count = utf16.count
            while i < count {
                let unit = utf16[i]
                if unit == 34 || unit == 39 || unit == 96 {  // " ' `
                    var j = i + 1
                    while j < count, utf16[j] != unit { j += 1 }
                    j = min(count, j + 1)
                    runs.append(SpikeStyleRun(location: i, length: j - i, style: .string))
                    i = j
                } else if (unit == 47 && i + 1 < count && utf16[i + 1] == 47) || unit == 35 {  // // or #
                    runs.append(SpikeStyleRun(location: i, length: count - i, style: .comment))
                    break
                } else if unit >= 48 && unit <= 57 {
                    var j = i + 1
                    while j < count, utf16[j] >= 48 && utf16[j] <= 57 { j += 1 }
                    runs.append(SpikeStyleRun(location: i, length: j - i, style: .number))
                    i = j
                } else if isIdentifierStart(unit) {
                    var j = i + 1
                    while j < count, isIdentifierStart(utf16[j]) || (utf16[j] >= 48 && utf16[j] <= 57) { j += 1 }
                    if j - i <= 9, let word = String(utf16CodeUnits: Array(utf16[i..<j]), count: j - i) as String?,
                       keywords.contains(word) {
                        runs.append(SpikeStyleRun(location: i, length: j - i, style: .keyword))
                    }
                    i = j
                } else {
                    i += 1
                }
            }
            return runs
        }
    }

    private static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
    }
}
