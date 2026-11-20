import Foundation

/// Minimal edits to a JSONC document (JSON with comments and trailing commas, as opencode accepts): set or remove one
/// value at a key path and keep every other byte (comments, order, formatting) as the person wrote it. Settings ▸
/// Models writes opencode's `model` and `agents.title.model` this way (opencode 2.3.2's config PATCH only accepts
/// `shell`).
public enum JSONCEditor {
    public enum EditError: Error, Equatable, CustomStringConvertible {
        /// The document does not parse (the message carries the position).
        case syntax(String)
        /// A key on the path holds something other than an object.
        case notAnObject(String)

        public var description: String {
            switch self {
            case .syntax(let message): message
            case .notAnObject(let key): "opencode.json: \(key) is not an object, so it cannot be changed from here."
            }
        }
    }

    /// The value at `path`, or nil when absent (or the document does not parse).
    public static func value(at path: [String], in text: String) -> Any? {
        let stripped = JSONCheck.strip(text)
        guard let root = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) else { return nil }
        var current: Any? = root
        for key in path { current = (current as? [String: Any])?[key] }
        return current
    }

    public static func string(at path: [String], in text: String) -> String? { value(at: path, in: text) as? String }

    /// Sets the string at `path` (creating missing objects), or removes it when `value` is nil (and then removes
    /// objects on the path that became empty, never the root). Returns the new text.
    public static func setString(_ value: String?, at path: [String], in text: String) throws -> String {
        precondition(!path.isEmpty)
        if let problem = JSONCheck.syntaxError(in: Data(text.utf8)) { throw EditError.syntax(problem) }
        let encoded = value.map(encode)
        var scanner = Scanner(Array(text.utf16))
        guard let root = scanner.parseValue(at: scanner.skip(0)), case .object(let object) = root.kind else {
            throw EditError.syntax("opencode.json must contain a JSON object ({ … }).")
        }
        let units = Array(text.utf16)
        let edit = try plan(object: object, rootRange: root.range, path: path, depth: 1, encoded: encoded, units: units, scanner: &scanner)
        guard let edit else { return text }
        var result = units
        result.replaceSubrange(edit.range, with: Array(edit.text.utf16))
        return String(decoding: result, as: UTF16.self)
    }

    // MARK: Planning

    struct Edit {
        var range: Range<Int>
        var text: String
    }

    private static func plan(
        object: [Member], rootRange: Range<Int>, path: [String], depth: Int, encoded: String?, units: [UInt16], scanner: inout Scanner
    ) throws -> Edit? {
        let key = path[0]
        let rest = Array(path.dropFirst())
        if let member = object.last(where: { $0.key == key }) {
            if rest.isEmpty {
                if let encoded { return Edit(range: member.value.range, text: encoded) }
                return removal(of: member, in: object, objectRange: rootRange, units: units)
            }
            guard case .object(let inner) = member.value.kind else {
                if encoded == nil { return nil }
                throw EditError.notAnObject(path.prefix(depth).joined(separator: "."))
            }
            // Removing the only thing an object holds removes the object too (an empty `"title": {}` stays out).
            if encoded == nil, collapses(inner, node: member.value, path: rest, units: units) {
                return removal(of: member, in: object, objectRange: rootRange, units: units)
            }
            return try plan(object: inner, rootRange: member.value.range, path: rest, depth: depth + 1, encoded: encoded, units: units, scanner: &scanner)
        }
        guard let encoded else { return nil }
        // Missing: insert `"key": value` (wrapping the rest of the path in objects) into this object.
        let indentUnit = "  "
        let memberIndent = object.first.map { indentation(before: $0.keyRange.lowerBound, units: units) } ?? String(repeating: indentUnit, count: depth)
        let closingIndent = indentation(before: rootRange.upperBound - 1, units: units)
        var valueText = encoded
        for (offset, nested) in rest.enumerated().reversed() {
            let inner = memberIndent + String(repeating: indentUnit, count: offset + 1)
            let outer = memberIndent + String(repeating: indentUnit, count: offset)
            valueText = "{\n\(inner)\(encode(nested)): \(valueText)\n\(outer)}"
        }
        let memberText = "\(encode(key)): \(valueText)"
        if let last = object.last {
            return Edit(range: last.value.range.upperBound..<last.value.range.upperBound, text: ",\n\(memberIndent)\(memberText)")
        }
        // Empty object: right after `{`, on its own line.
        let open = rootRange.lowerBound + 1
        let between = String(decoding: units[open..<(rootRange.upperBound - 1)], as: UTF16.self)
        if between.allSatisfy(\.isWhitespace) {
            return Edit(range: open..<(rootRange.upperBound - 1), text: "\n\(memberIndent)\(memberText)\n\(closingIndent)")
        }
        return Edit(range: open..<open, text: "\n\(memberIndent)\(memberText)")
    }

    /// True when removing `path` would leave `object` empty (and it holds no comments to keep).
    private static func collapses(_ object: [Member], node: Node, path: [String], units: [UInt16]) -> Bool {
        guard object.count == 1, object[0].key == path[0] else { return false }
        let text = String(decoding: units[node.range], as: UTF16.self)
        guard !text.contains("//"), !text.contains("/*") else { return false }
        if path.count == 1 { return true }
        guard case .object(let inner) = object[0].value.kind else { return false }
        return collapses(inner, node: object[0].value, path: Array(path.dropFirst()), units: units)
    }

    /// Removes one member with its separating comma and, when it sits alone on its lines, the whole lines.
    private static func removal(of member: Member, in object: [Member], objectRange: Range<Int>, units: [UInt16]) -> Edit {
        guard let index = object.firstIndex(where: { $0.keyRange == member.keyRange }) else { return Edit(range: 0..<0, text: "") }
        var start = member.keyRange.lowerBound
        var end = member.value.range.upperBound
        if let comma = member.comma {
            end = comma + 1
            // Swallow the rest of the line when it is only whitespace.
            var cursor = end
            while cursor < units.count, units[cursor] == 0x20 || units[cursor] == 0x09 { cursor += 1 }
            if cursor < units.count, units[cursor] == 0x0A { end = cursor + 1 }
            var back = start
            while back > 0, units[back - 1] == 0x20 || units[back - 1] == 0x09 { back -= 1 }
            if back == 0 || units[back - 1] == 0x0A { start = back }
        } else if index > 0 {
            // Last member: drop the comma after the previous one (from its value's end).
            start = object[index - 1].value.range.upperBound
        } else {
            // The only member: everything between the braces that is whitespace around it.
            var back = start
            while back > objectRange.lowerBound + 1, isSpace(units[back - 1]) { back -= 1 }
            start = back
        }
        return Edit(range: start..<end, text: "")
    }

    private static func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D }

    /// The whitespace from the start of the line to `index`, if only whitespace precedes it on that line.
    private static func indentation(before index: Int, units: [UInt16]) -> String {
        var cursor = index
        while cursor > 0, units[cursor - 1] == 0x20 || units[cursor - 1] == 0x09 { cursor -= 1 }
        guard cursor == 0 || units[cursor - 1] == 0x0A else { return "" }
        return String(decoding: units[cursor..<index], as: UTF16.self)
    }

    static func encode(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Scanning (positions in UTF-16 units of the original text)

    struct Member {
        var key: String
        var keyRange: Range<Int>
        var value: Node
        /// The position of the comma after the value, if any.
        var comma: Int?
    }

    indirect enum Kind {
        case object([Member])
        case other
    }

    struct Node {
        var kind: Kind
        var range: Range<Int>
    }

    struct Scanner {
        let units: [UInt16]
        init(_ units: [UInt16]) { self.units = units }

        /// Skips whitespace and comments from `index`.
        func skip(_ index: Int) -> Int {
            var i = index
            while i < units.count {
                let c = units[i]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xFEFF { i += 1; continue }
                if c == 0x2F, i + 1 < units.count, units[i + 1] == 0x2F {
                    while i < units.count, units[i] != 0x0A { i += 1 }
                    continue
                }
                if c == 0x2F, i + 1 < units.count, units[i + 1] == 0x2A {
                    i += 2
                    while i + 1 < units.count, !(units[i] == 0x2A && units[i + 1] == 0x2F) { i += 1 }
                    i = min(units.count, i + 2)
                    continue
                }
                break
            }
            return i
        }

        func stringEnd(_ index: Int) -> Int? {
            var i = index + 1
            while i < units.count {
                if units[i] == 0x5C { i += 2; continue }
                if units[i] == 0x22 { return i + 1 }
                i += 1
            }
            return nil
        }

        func parseValue(at index: Int) -> Node? {
            guard index < units.count else { return nil }
            switch units[index] {
            case 0x7B: return parseObject(at: index)
            case 0x5B:
                var i = skip(index + 1)
                while i < units.count, units[i] != 0x5D {
                    guard let element = parseValue(at: i) else { return nil }
                    i = skip(element.range.upperBound)
                    if i < units.count, units[i] == 0x2C { i = skip(i + 1) }
                }
                guard i < units.count else { return nil }
                return Node(kind: .other, range: index..<(i + 1))
            case 0x22:
                guard let end = stringEnd(index) else { return nil }
                return Node(kind: .other, range: index..<end)
            default:
                var i = index
                while i < units.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D, 0x2F].contains(units[i]) { i += 1 }
                return i > index ? Node(kind: .other, range: index..<i) : nil
            }
        }

        func parseObject(at index: Int) -> Node? {
            var members: [Member] = []
            var i = skip(index + 1)
            while i < units.count, units[i] != 0x7D {
                guard units[i] == 0x22, let keyEnd = stringEnd(i) else { return nil }
                let keyStart = i
                let keyData = String(decoding: units[i..<keyEnd], as: UTF16.self)
                let key = (try? JSONSerialization.jsonObject(with: Data(keyData.utf8), options: .fragmentsAllowed)) as? String ?? ""
                i = skip(keyEnd)
                guard i < units.count, units[i] == 0x3A else { return nil }
                i = skip(i + 1)
                guard let value = parseValue(at: i) else { return nil }
                i = skip(value.range.upperBound)
                var comma: Int?
                if i < units.count, units[i] == 0x2C {
                    comma = i
                    i = skip(i + 1)
                }
                members.append(Member(key: key, keyRange: keyStart..<keyEnd, value: value, comma: comma))
            }
            guard i < units.count else { return nil }
            return Node(kind: .object(members), range: index..<(i + 1))
        }
    }
}
