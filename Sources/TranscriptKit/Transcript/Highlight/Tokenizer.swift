import Foundation

/// Linear, single-pass tokenizers over UTF-16 code units. Not parsers: they colour the lexical structure that matters
/// for reading (keywords, types, strings, comments, numbers, calls), and never fail: unknown input stays plain.
enum Tokenizer {
    static func tokenize(_ code: [UInt16], spec: LanguageSpec) -> [TokenRun] {
        var lexer = Lexer(code: code, spec: spec)
        switch spec.family {
        case .generic: lexer.generic()
        case .json: lexer.json()
        case .yaml: lexer.yaml()
        case .markup: lexer.markup()
        case .css: lexer.css()
        case .shell: lexer.shell()
        case .diff: lexer.diff()
        }
        return lexer.runs
    }
}

private struct Lexer {
    let code: [UInt16]
    let spec: LanguageSpec
    let count: Int
    var runs: [TokenRun] = []
    var index = 0
    private let lineComments: [[UInt16]]
    private let blockComments: [(open: [UInt16], close: [UInt16])]
    private let strings: [[UInt16]]
    private let multiline: Set<[UInt16]>

    init(code: [UInt16], spec: LanguageSpec) {
        self.code = code
        self.spec = spec
        count = code.count
        lineComments = spec.lineComments.map { Array($0.utf16) }
        blockComments = spec.blockComments.map { (Array($0.open.utf16), Array($0.close.utf16)) }
        strings = spec.strings.map { Array($0.utf16) }
        multiline = Set(spec.multilineStrings.map { Array($0.utf16) })
    }

    // MARK: Primitives

    mutating func emit(_ start: Int, _ end: Int, _ kind: TokenKind) {
        guard end > start else { return }
        runs.append(TokenRun(location: start, length: end - start, kind: kind))
    }

    func matches(_ pattern: [UInt16], at position: Int) -> Bool {
        guard position + pattern.count <= count else { return false }
        for (offset, unit) in pattern.enumerated() where code[position + offset] != unit { return false }
        return true
    }

    func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit > 127
            || spec.identifierExtras.contains(unit)
    }

    func isIdentifierPart(_ unit: UInt16) -> Bool { isIdentifierStart(unit) || isDigit(unit) }
    func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }
    func isSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 }

    func endOfLine(from position: Int) -> Int {
        var end = position
        while end < count, code[end] != 10 { end += 1 }
        return end
    }

    func word(_ start: Int, _ end: Int) -> String? {
        guard end - start <= 32 else { return nil }
        let text = String(utf16CodeUnits: Array(code[start..<end]), count: end - start)
        return spec.caseInsensitive ? text.lowercased() : text
    }

    /// Scans a string starting at `index` with `delimiter`; returns its end (after the closing delimiter).
    func scanString(from start: Int, delimiter: [UInt16]) -> Int {
        let allowsNewlines = multiline.contains(delimiter)
        var position = start + delimiter.count
        while position < count {
            let unit = code[position]
            if unit == 92 { position += 2; continue }  // backslash escape
            if unit == 10, !allowsNewlines { return position }
            if matches(delimiter, at: position) { return position + delimiter.count }
            position += 1
        }
        return count
    }

    mutating func number(from start: Int) -> Int {
        var position = start + 1
        while position < count {
            let unit = code[position]
            if isIdentifierPart(unit) || unit == 46 && position + 1 < count && isDigit(code[position + 1]) {
                position += 1
            } else {
                break
            }
        }
        return position
    }

    func nextNonSpace(from position: Int) -> UInt16? {
        var cursor = position
        while cursor < count, isSpace(code[cursor]) { cursor += 1 }
        return cursor < count ? code[cursor] : nil
    }

    // MARK: Generic C-family / scripting languages

    mutating func generic() {
        outer: while index < count {
            if index & 0xFFF == 0, Task.isCancelled { return }
            let unit = code[index]
            for comment in lineComments where matches(comment, at: index) {
                let end = endOfLine(from: index)
                emit(index, end, .comment)
                index = end
                continue outer
            }
            for comment in blockComments where matches(comment.open, at: index) {
                var end = index + comment.open.count
                while end < count, !matches(comment.close, at: end) { end += 1 }
                end = min(count, end + comment.close.count)
                emit(index, end, .comment)
                index = end
                continue outer
            }
            for delimiter in strings where matches(delimiter, at: index) {
                let end = scanString(from: index, delimiter: delimiter)
                emit(index, end, .string)
                index = end
                continue outer
            }
            if isDigit(unit) {
                let end = number(from: index)
                emit(index, end, .number)
                index = end
                continue
            }
            if let prefix = spec.metaPrefix, unit == prefix, index + 1 < count, isIdentifierStart(code[index + 1])
                || (prefix == 35 && code[index + 1] == 91)
            {
                var end = index + 1
                if prefix == 35, code[end] == 91 {  // Rust #[attr]
                    while end < count, code[end] != 93, code[end] != 10 { end += 1 }
                    end = min(count, end + 1)
                } else {
                    while end < count, isIdentifierPart(code[end]) { end += 1 }
                }
                emit(index, end, .meta)
                index = end
                continue
            }
            if isIdentifierStart(unit) {
                var end = index + 1
                while end < count, isIdentifierPart(code[end]) { end += 1 }
                if let word = word(index, end) {
                    if spec.keywords.contains(word) {
                        emit(index, end, .keyword)
                    } else if spec.literals.contains(word) {
                        emit(index, end, .number)
                    } else if spec.types.contains(word) || (spec.capitalizedAreTypes && unit >= 65 && unit <= 90) {
                        emit(index, end, .type)
                    } else if nextNonSpace(from: end) == 40 {  // (
                        emit(index, end, .function)
                    } else if index > 0, code[index - 1] == 46, !isDigit(code[index - 1]) {  // .member
                        emit(index, end, .property)
                    }
                }
                index = end
                continue
            }
            index += 1
        }
    }

    // MARK: JSON

    mutating func json() {
        while index < count {
            if index & 0xFFF == 0, Task.isCancelled { return }
            let unit = code[index]
            if unit == 34 {
                let end = scanString(from: index, delimiter: [34])
                var after = end
                while after < count, isSpace(code[after]) || code[after] == 10 || code[after] == 13 { after += 1 }
                emit(index, end, after < count && code[after] == 58 ? .property : .string)
                index = end
            } else if isDigit(unit) || unit == 45 {
                let end = number(from: index)
                emit(index, end, .number)
                index = end
            } else if isIdentifierStart(unit) {
                var end = index + 1
                while end < count, isIdentifierPart(code[end]) { end += 1 }
                if let word = word(index, end), spec.literals.contains(word) { emit(index, end, .keyword) }
                index = end
            } else if unit == 47, index + 1 < count, code[index + 1] == 47 {  // JSONC comment
                let end = endOfLine(from: index)
                emit(index, end, .comment)
                index = end
            } else {
                index += 1
            }
        }
    }

    // MARK: YAML

    mutating func yaml() {
        while index < count {
            if Task.isCancelled { return }
            let lineEnd = endOfLine(from: index)
            var position = index
            while position < lineEnd, isSpace(code[position]) { position += 1 }
            if position < lineEnd, code[position] == 35 {
                emit(position, lineEnd, .comment)
            } else if matches(Array("---".utf16), at: position) || matches(Array("...".utf16), at: position) {
                emit(position, lineEnd, .meta)
            } else {
                if position + 1 < lineEnd, code[position] == 45, code[position + 1] == 32 { position += 2 }
                // key: value
                var colon = position
                var inQuote: UInt16 = 0
                while colon < lineEnd {
                    let unit = code[colon]
                    if inQuote != 0 { if unit == inQuote { inQuote = 0 } } else if unit == 34 || unit == 39 { inQuote = unit } else if unit == 58,
                        colon + 1 == lineEnd || isSpace(code[colon + 1])
                    {
                        break
                    } else if unit == 35, colon > position, isSpace(code[colon - 1]) {
                        colon = lineEnd
                        break
                    }
                    colon += 1
                }
                var valueStart = position
                if colon < lineEnd {
                    emit(position, colon, .property)
                    valueStart = colon + 1
                }
                yamlValue(from: valueStart, to: lineEnd)
            }
            index = lineEnd + 1
        }
    }

    mutating func yamlValue(from start: Int, to end: Int) {
        var position = start
        while position < end, isSpace(code[position]) { position += 1 }
        guard position < end else { return }
        let unit = code[position]
        // Trailing comment.
        var commentStart = end
        var cursor = position
        var quote: UInt16 = 0
        while cursor < end {
            let c = code[cursor]
            if quote != 0 { if c == quote { quote = 0 } } else if c == 34 || c == 39 { quote = c } else if c == 35, cursor > position, isSpace(code[cursor - 1]) {
                commentStart = cursor
                break
            }
            cursor += 1
        }
        var valueEnd = commentStart
        while valueEnd > position, isSpace(code[valueEnd - 1]) { valueEnd -= 1 }
        if unit == 34 || unit == 39 {
            emit(position, valueEnd, .string)
        } else if unit == 38 || unit == 42 {  // & anchor, * alias
            emit(position, valueEnd, .variable)
        } else if isDigit(unit) || unit == 45 && position + 1 < end && isDigit(code[position + 1]) {
            emit(position, valueEnd, .number)
        } else if let word = word(position, valueEnd), spec.literals.contains(word.lowercased()) {
            emit(position, valueEnd, .keyword)
        } else if unit == 124 || unit == 62 {  // block scalars
            emit(position, position + 1, .meta)
        }
        if commentStart < end { emit(commentStart, end, .comment) }
    }

    // MARK: HTML / XML

    mutating func markup() {
        let commentOpen = Array("<!--".utf16)
        let commentClose = Array("-->".utf16)
        while index < count {
            if index & 0xFFF == 0, Task.isCancelled { return }
            if matches(commentOpen, at: index) {
                var end = index + 4
                while end < count, !matches(commentClose, at: end) { end += 1 }
                end = min(count, end + 3)
                emit(index, end, .comment)
                index = end
                continue
            }
            guard code[index] == 60, index + 1 < count else { index += 1; continue }  // <
            var position = index + 1
            if code[position] == 47 || code[position] == 33 || code[position] == 63 { position += 1 }  // / ! ?
            let nameStart = position
            while position < count, isIdentifierPart(code[position]) || code[position] == 45 || code[position] == 58 { position += 1 }
            guard position > nameStart else { index += 1; continue }
            emit(index, position, .tag)
            // Attributes until '>'.
            while position < count, code[position] != 62 {
                let unit = code[position]
                if unit == 34 || unit == 39 {
                    let end = scanString(from: position, delimiter: [unit])
                    emit(position, end, .string)
                    position = end
                } else if isIdentifierStart(unit) {
                    var end = position + 1
                    while end < count, isIdentifierPart(code[end]) || code[end] == 45 || code[end] == 58 { end += 1 }
                    emit(position, end, .attribute)
                    position = end
                } else {
                    position += 1
                }
            }
            if position < count { emit(position, position + 1, .tag) }
            index = min(count, position + 1)
        }
    }

    // MARK: CSS

    mutating func css() {
        var depth = 0
        while index < count {
            if index & 0xFFF == 0, Task.isCancelled { return }
            let unit = code[index]
            if matches([47, 42], at: index) {  // /*
                var end = index + 2
                while end < count, !matches([42, 47], at: end) { end += 1 }
                end = min(count, end + 2)
                emit(index, end, .comment)
                index = end
            } else if unit == 123 { depth += 1; index += 1 }
            else if unit == 125 { depth = max(0, depth - 1); index += 1 }
            else if unit == 34 || unit == 39 {
                let end = scanString(from: index, delimiter: [unit])
                emit(index, end, .string)
                index = end
            } else if unit == 64 {  // @media
                var end = index + 1
                while end < count, isIdentifierPart(code[end]) || code[end] == 45 { end += 1 }
                emit(index, end, .keyword)
                index = end
            } else if unit == 35, depth > 0 {  // #fff
                var end = index + 1
                while end < count, isIdentifierPart(code[end]) { end += 1 }
                emit(index, end, .number)
                index = end
            } else if isDigit(unit) || (unit == 46 && index + 1 < count && isDigit(code[index + 1])) {
                var end = index + 1
                while end < count, isIdentifierPart(code[end]) || code[end] == 46 || code[end] == 37 { end += 1 }
                emit(index, end, .number)
                index = end
            } else if unit == 33 {  // !important
                var end = index + 1
                while end < count, isIdentifierPart(code[end]) { end += 1 }
                emit(index, end, .keyword)
                index = end
            } else if isIdentifierStart(unit) || unit == 45 || unit == 46 || (unit == 35 && depth == 0) {
                var end = index + 1
                while end < count, isIdentifierPart(code[end]) || code[end] == 45 { end += 1 }
                if depth == 0 {
                    emit(index, end, unit == 46 || unit == 35 ? .type : .tag)
                } else if nextNonSpace(from: end) == 58 {
                    emit(index, end, .property)
                } else if nextNonSpace(from: end) == 40 {
                    emit(index, end, .function)
                }
                index = end
            } else {
                index += 1
            }
        }
    }

    // MARK: Shell

    mutating func shell() {
        var commandPosition = true
        while index < count {
            if index & 0xFFF == 0, Task.isCancelled { return }
            let unit = code[index]
            if unit == 10 || unit == 59 || unit == 124 || unit == 38 {  // newline ; | &
                commandPosition = true
                index += 1
                continue
            }
            if isSpace(unit) { index += 1; continue }
            if unit == 35, index == 0 || isSpace(code[index - 1]) || code[index - 1] == 10 {  // # comment
                let end = endOfLine(from: index)
                emit(index, end, .comment)
                index = end
                continue
            }
            if unit == 34 || unit == 39 {
                let end = scanString(from: index, delimiter: [unit])
                emit(index, end, .string)
                index = end
                commandPosition = false
                continue
            }
            if unit == 36 {  // $VAR, ${VAR}, $(...)
                var end = index + 1
                if end < count, code[end] == 123 {
                    while end < count, code[end] != 125, code[end] != 10 { end += 1 }
                    end = min(count, end + 1)
                } else {
                    while end < count, isIdentifierPart(code[end]) && code[end] != 45 || (end == index + 1 && (code[end] == 63 || code[end] == 64 || isDigit(code[end]))) { end += 1 }
                }
                emit(index, end, .variable)
                index = end
                continue
            }
            if unit == 45, !commandPosition {  // flags
                var end = index + 1
                while end < count, isIdentifierPart(code[end]) || code[end] == 45 || code[end] == 61 { end += 1 }
                emit(index, end, .attribute)
                index = end
                continue
            }
            if isIdentifierStart(unit) || unit == 46 || unit == 47 || unit == 126 {
                var end = index + 1
                while end < count, !isSpace(code[end]), code[end] != 10, code[end] != 59, code[end] != 124, code[end] != 61 { end += 1 }
                if let word = word(index, end), spec.keywords.contains(word) {
                    emit(index, end, .keyword)
                } else if end < count, code[end] == 61 {
                    emit(index, end, .variable)  // NAME=value
                } else if commandPosition {
                    emit(index, end, .function)
                    commandPosition = false
                }
                index = end
                continue
            }
            if isDigit(unit) {
                let end = number(from: index)
                emit(index, end, .number)
                index = end
                continue
            }
            index += 1
        }
    }

    // MARK: Diff

    mutating func diff() {
        while index < count {
            if Task.isCancelled { return }
            let end = endOfLine(from: index)
            let unit = code[index]
            if matches(Array("+++".utf16), at: index) || matches(Array("---".utf16), at: index)
                || matches(Array("diff ".utf16), at: index) || matches(Array("index ".utf16), at: index)
            {
                emit(index, end, .diffHeader)
            } else if unit == 64, matches([64, 64], at: index) {
                emit(index, end, .diffHunk)
            } else if unit == 43 {
                emit(index, end, .diffAdded)
            } else if unit == 45 {
                emit(index, end, .diffRemoved)
            }
            index = end + 1
        }
    }
}
