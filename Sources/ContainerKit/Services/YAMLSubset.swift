import Foundation

/// A YAML node of the subset BelloCode reads (compose files). Scalars stay text; the reader of a key decides whether it
/// is a number or a boolean.
public indirect enum YAMLNode: Sendable, Equatable {
    case null
    case scalar(String)
    case sequence([YAMLNode])
    /// Keys in document order.
    case mapping([(key: String, value: YAMLNode)])

    public static func == (lhs: YAMLNode, rhs: YAMLNode) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.scalar(let a), .scalar(let b)): a == b
        case (.sequence(let a), .sequence(let b)): a == b
        case (.mapping(let a), .mapping(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    public subscript(key: String) -> YAMLNode? {
        if case .mapping(let entries) = self { return entries.last { $0.key == key }?.value }
        return nil
    }

    public var string: String? { if case .scalar(let value) = self { value } else { nil } }
    public var entries: [(key: String, value: YAMLNode)]? { if case .mapping(let value) = self { value } else { nil } }
    public var items: [YAMLNode]? { if case .sequence(let value) = self { value } else { nil } }
    public var isNull: Bool { self == .null }
}

public struct YAMLError: Error, Sendable, Equatable, CustomStringConvertible {
    public var line: Int
    public var message: String
    public var description: String { "line \(line): \(message)" }
}

/// Parses the YAML subset compose files use, without any runtime or library: block mappings and sequences (including
/// `- key: value` items), plain, single- and double-quoted scalars, flow sequences and mappings (`[a, b]`, `{a: 1}`),
/// literal and folded block scalars (`|`, `>`, with `-`/`+`), comments and one optional `---`. Anchors, aliases, merge
/// keys, tags, complex keys, directives, tabs for indentation and further documents are refused with the line number,
/// never guessed.
public enum YAMLSubset {
    struct Line {
        var number: Int
        var indent: Int
        /// The content without indentation or comment.
        var text: String
        var raw: String
    }

    public static func parse(_ source: String) throws(YAMLError) -> YAMLNode {
        var lines: [Line] = []
        var started = false
        for (index, raw) in source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let raw = String(raw)
            let number = index + 1
            let leading = raw.prefix { $0 == " " || $0 == "\t" }
            if leading.contains("\t") && !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                throw YAMLError(line: number, message: "tabs cannot indent YAML; use spaces")
            }
            let text = stripComment(String(raw.dropFirst(leading.count))).trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                lines.append(Line(number: number, indent: -1, text: "", raw: raw))
                continue
            }
            if text.hasPrefix("%") { throw YAMLError(line: number, message: "YAML directives are not supported") }
            if text == "---" || text.hasPrefix("--- ") {
                if started { throw YAMLError(line: number, message: "only one YAML document is supported") }
                lines.append(Line(number: number, indent: -1, text: "", raw: raw))
                continue
            }
            if text == "..." { break }
            started = true
            lines.append(Line(number: number, indent: leading.count, text: text, raw: raw))
        }
        var parser = Parser(lines: lines)
        parser.skipBlank()
        guard parser.index < parser.lines.count else { return .null }
        let node = try parser.block(indent: parser.lines[parser.index].indent)
        parser.skipBlank()
        if parser.index < parser.lines.count {
            throw YAMLError(line: parser.lines[parser.index].number, message: "unexpected indentation")
        }
        return node
    }

    /// Removes a `#` comment that starts the text or follows whitespace, outside quotes.
    static func stripComment(_ text: String) -> String {
        var quote: Character?
        var previous: Character = " "
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if let open = quote {
                result.append(character)
                if open == "\"" && character == "\\" {
                    if let next = iterator.next() { result.append(next) }
                    previous = "x"
                    continue
                }
                if character == open { quote = nil }
            } else {
                if character == "#" && (previous == " " || previous == "\t") { break }
                if (character == "\"" || character == "'") && (previous == " " || previous == "[" || previous == "{" || previous == ","
                    || previous == ":" || result.isEmpty || previous == "-") {
                    quote = character
                }
                result.append(character)
            }
            previous = character
        }
        return result
    }

    struct Parser {
        var lines: [Line]
        var index = 0

        mutating func skipBlank() {
            while index < lines.count, lines[index].indent < 0 { index += 1 }
        }

        func isSequenceItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

        mutating func block(indent: Int) throws(YAMLError) -> YAMLNode {
            skipBlank()
            guard index < lines.count else { return .null }
            let line = lines[index]
            if isSequenceItem(line.text) { return try sequence(indent: indent) }
            if try YAMLSubset.splitKey(line.text, line: line.number) != nil { return try mapping(indent: indent) }
            // A lone scalar (or flow collection) as a block's content.
            index += 1
            return try YAMLSubset.inline(line.text, line: line.number)
        }

        mutating func sequence(indent: Int) throws(YAMLError) -> YAMLNode {
            var items: [YAMLNode] = []
            while true {
                skipBlank()
                guard index < lines.count, lines[index].indent == indent, isSequenceItem(lines[index].text) else { break }
                let line = lines[index]
                let content = line.text == "-" ? "" : String(line.text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if content.isEmpty {
                    index += 1
                    skipBlank()
                    if index < lines.count, lines[index].indent > indent {
                        items.append(try block(indent: lines[index].indent))
                    } else {
                        items.append(.null)
                    }
                    continue
                }
                // `- key: value` or `- - x`: the item's content continues at its own column.
                let column = indent + (line.text.count - content.count)
                let startsMapping = try YAMLSubset.splitKey(content, line: line.number) != nil
                if isSequenceItem(content) || startsMapping {
                    lines[index] = Line(number: line.number, indent: column, text: content, raw: line.raw)
                    items.append(try block(indent: column))
                    continue
                }
                index += 1
                items.append(try scalarOrBlock(content, line: line, parentIndent: indent))
            }
            return .sequence(items)
        }

        mutating func mapping(indent: Int) throws(YAMLError) -> YAMLNode {
            var entries: [(key: String, value: YAMLNode)] = []
            while true {
                skipBlank()
                guard index < lines.count, lines[index].indent == indent, !isSequenceItem(lines[index].text) else { break }
                let line = lines[index]
                guard let (key, rest) = try YAMLSubset.splitKey(line.text, line: line.number) else {
                    throw YAMLError(line: line.number, message: "expected “key: value”")
                }
                if key == "<<" { throw YAMLError(line: line.number, message: "merge keys (<<) are not supported") }
                if entries.contains(where: { $0.key == key }) { throw YAMLError(line: line.number, message: "duplicate key “\(key)”") }
                index += 1
                if rest.isEmpty {
                    skipBlank()
                    if index < lines.count, lines[index].indent > indent {
                        entries.append((key, try block(indent: lines[index].indent)))
                    } else if index < lines.count, lines[index].indent == indent, isSequenceItem(lines[index].text) {
                        // `key:` followed by `- item` at the same indentation (common in compose files).
                        entries.append((key, try sequence(indent: indent)))
                    } else {
                        entries.append((key, .null))
                    }
                } else {
                    entries.append((key, try scalarOrBlock(rest, line: line, parentIndent: indent)))
                }
            }
            return .mapping(entries)
        }

        /// An inline value, a block scalar (`|`, `>`), or a flow collection continued over further lines.
        mutating func scalarOrBlock(_ text: String, line: Line, parentIndent: Int) throws(YAMLError) -> YAMLNode {
            if let first = text.first, first == "|" || first == ">" {
                let header = text.dropFirst()
                guard header.allSatisfy({ $0 == "-" || $0 == "+" }) else {
                    throw YAMLError(line: line.number, message: "block scalar indentation indicators are not supported")
                }
                return .scalar(blockScalar(folded: first == ">", chomp: header.first, parentIndent: parentIndent))
            }
            var text = text
            if let first = text.first, first == "[" || first == "{" {
                // A flow collection may continue on more-indented lines until its brackets balance.
                while !YAMLSubset.balanced(text), index < lines.count, lines[index].indent > parentIndent || lines[index].indent < 0 {
                    if lines[index].indent >= 0 { text += " " + lines[index].text }
                    index += 1
                }
            }
            return try YAMLSubset.inline(text, line: line.number)
        }

        mutating func blockScalar(folded: Bool, chomp: Character?, parentIndent: Int) -> String {
            var collected: [String] = []
            var contentIndent: Int?
            while index < lines.count {
                let raw = lines[index].raw
                let leading = raw.prefix { $0 == " " }.count
                let isBlank = raw.trimmingCharacters(in: .whitespaces).isEmpty
                if !isBlank {
                    if leading <= parentIndent { break }
                    if contentIndent == nil { contentIndent = leading }
                    if leading < contentIndent! { break }
                }
                collected.append(isBlank ? "" : String(raw.dropFirst(contentIndent ?? leading)))
                index += 1
            }
            var trailing = 0
            while collected.last == "" {
                collected.removeLast()
                trailing += 1
            }
            var text: String
            if folded {
                text = ""
                for (offset, piece) in collected.enumerated() {
                    if offset > 0 { text += piece.isEmpty || collected[offset - 1].isEmpty ? "\n" : " " }
                    text += piece
                }
            } else {
                text = collected.joined(separator: "\n")
            }
            switch chomp {
            case "-": return text
            case "+": return text + String(repeating: "\n", count: trailing + 1)
            default: return collected.isEmpty ? "" : text + "\n"
            }
        }
    }

    /// `key: rest` when `text` starts a mapping entry (plain or quoted key), else nil.
    static func splitKey(_ text: String, line: Int) throws(YAMLError) -> (String, String)? {
        if text.hasPrefix("? ") { throw YAMLError(line: line, message: "complex keys (?) are not supported") }
        if let first = text.first, first == "\"" || first == "'" {
            guard let end = closingQuote(text, quote: first) else { return nil }
            let after = text[text.index(after: end)...]
            guard after.hasPrefix(":"), after.count == 1 || after.dropFirst().first == " " else { return nil }
            let key = try unquote(String(text[...end]), line: line)
            return (key, String(after.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        if let first = text.first, first == "[" || first == "{" || first == "&" || first == "*" || first == "!" { return nil }
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "[" || character == "{" { depth += 1 }
            if character == "]" || character == "}" { depth -= 1 }
            if character == ":", depth == 0 {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " {
                    let key = String(text[..<index]).trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return nil }
                    return (key, String(text[next...]).trimmingCharacters(in: .whitespaces))
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func closingQuote(_ text: String, quote: Character) -> String.Index? {
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if quote == "\"" && character == "\\" {
                index = text.index(after: index)
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            if character == quote {
                let next = text.index(after: index)
                if quote == "'" && next < text.endIndex && text[next] == "'" {
                    index = text.index(after: next)
                    continue
                }
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func balanced(_ text: String) -> Bool {
        var depth = 0
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            default: break
            }
        }
        return depth <= 0
    }

    /// An inline value: a quoted or plain scalar, or a flow collection.
    static func inline(_ text: String, line: Int) throws(YAMLError) -> YAMLNode {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text == "~" || text == "null" || text == "Null" || text == "NULL" { return .null }
        if let first = text.first {
            if first == "&" { throw YAMLError(line: line, message: "anchors (&) are not supported") }
            if first == "*" { throw YAMLError(line: line, message: "aliases (*) are not supported") }
            if first == "!" { throw YAMLError(line: line, message: "tags (!) are not supported") }
            if first == "[" || first == "{" {
                var flow = FlowParser(characters: Array(text), line: line)
                let node = try flow.value()
                flow.skipSpaces()
                guard flow.index == flow.characters.count else { throw YAMLError(line: line, message: "unexpected text after a flow collection") }
                return node
            }
            if first == "\"" || first == "'" {
                guard let end = closingQuote(text, quote: first), text.index(after: end) == text.endIndex else {
                    throw YAMLError(line: line, message: "unterminated or trailing text after a quoted value")
                }
                return .scalar(try unquote(text, line: line))
            }
        }
        return .scalar(text)
    }

    static func unquote(_ text: String, line: Int) throws(YAMLError) -> String {
        guard let quote = text.first, text.count >= 2, text.last == quote else { return text }
        let body = text.dropFirst().dropLast()
        if quote == "'" { return body.replacingOccurrences(of: "''", with: "'") }
        var result = ""
        var iterator = body.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escaped = iterator.next() else { throw YAMLError(line: line, message: "a backslash ends a quoted value") }
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "\"", "\\", "/", " ": result.append(escaped)
            case "u":
                var hex = ""
                for _ in 0..<4 { if let h = iterator.next() { hex.append(h) } }
                guard let scalar = UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) else {
                    throw YAMLError(line: line, message: "invalid \\u escape")
                }
                result.unicodeScalars.append(scalar)
            default: throw YAMLError(line: line, message: "unsupported escape \\\(escaped)")
            }
        }
        return result
    }

    struct FlowParser {
        var characters: [Character]
        var line: Int
        var index = 0

        mutating func skipSpaces() {
            while index < characters.count, characters[index] == " " { index += 1 }
        }

        mutating func value() throws(YAMLError) -> YAMLNode {
            skipSpaces()
            guard index < characters.count else { return .null }
            switch characters[index] {
            case "[":
                index += 1
                var items: [YAMLNode] = []
                while true {
                    skipSpaces()
                    guard index < characters.count else { throw YAMLError(line: line, message: "unterminated [ … ]") }
                    if characters[index] == "]" { index += 1; break }
                    items.append(try value())
                    skipSpaces()
                    if index < characters.count, characters[index] == "," { index += 1 }
                }
                return .sequence(items)
            case "{":
                index += 1
                var entries: [(key: String, value: YAMLNode)] = []
                while true {
                    skipSpaces()
                    guard index < characters.count else { throw YAMLError(line: line, message: "unterminated { … }") }
                    if characters[index] == "}" { index += 1; break }
                    guard case .scalar(let key) = try scalar(stopAtColon: true) else { throw YAMLError(line: line, message: "a flow mapping needs keys") }
                    skipSpaces()
                    var node = YAMLNode.null
                    if index < characters.count, characters[index] == ":" {
                        index += 1
                        node = try value()
                    }
                    entries.append((key, node))
                    skipSpaces()
                    if index < characters.count, characters[index] == "," { index += 1 }
                }
                return .mapping(entries)
            default:
                return try scalar(stopAtColon: false)
            }
        }

        mutating func scalar(stopAtColon: Bool) throws(YAMLError) -> YAMLNode {
            skipSpaces()
            guard index < characters.count else { return .null }
            let first = characters[index]
            if first == "\"" || first == "'" {
                let rest = String(characters[index...])
                guard let end = YAMLSubset.closingQuote(rest, quote: first) else { throw YAMLError(line: line, message: "unterminated quote") }
                let quoted = String(rest[...end])
                index += quoted.count
                return .scalar(try YAMLSubset.unquote(quoted, line: line))
            }
            var text = ""
            while index < characters.count {
                let character = characters[index]
                if character == "," || character == "]" || character == "}" { break }
                if stopAtColon, character == ":", index + 1 >= characters.count || characters[index + 1] == " " { break }
                text.append(character)
                index += 1
            }
            return try YAMLSubset.inline(text, line: line)
        }
    }
}
