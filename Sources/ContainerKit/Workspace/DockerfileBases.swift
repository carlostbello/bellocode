import Foundation

/// The images a Dockerfile pulls (docs/reviews/release-1.0-review.md, R14): every `FROM` that is not an earlier stage
/// or `scratch`, and every `COPY --from` / `ADD --from` / `RUN --mount=…,from=` naming an image. The image policy's
/// registry allowlist applies to these, never to the tag BelloCode gives the locally built result.
///
/// Variables in those references are expanded from the global `ARG`s (before the first `FROM`) and the build arguments,
/// as Docker does. A reference that still holds a variable cannot be checked, so it is refused rather than guessed.
///
/// The file is read as BuildKit's parser (`frontend/dockerfile/parser`, used by both the BuildKit frontend and the
/// classic builder) reads it (AF11, GV01): lines split at LF with every trailing CR dropped, a byte-order mark dropped
/// from the first line only, leading blanks stripped with Go's `unicode.IsSpace` set, a continuation joined with no
/// separator, builder flags read byte by byte as Docker does. Where Docker's reading depends on a character whose
/// treatment differs between Docker's own code paths or versions (a form feed, vertical tab, NEL, no-break space or
/// other blank that is not a space or tab, or any control character) in an instruction or in a comment before the
/// first instruction, the file is refused: BelloCode never approves a reading it is not sure Docker shares.
public enum DockerfileBases {
    public struct Refusal: Error, Sendable, Equatable, CustomStringConvertible {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
        public var description: String { reason }
    }

    /// The bytes as Docker receives them: text that is not valid UTF-8 is refused (Docker reads it byte by byte in
    /// places and as UTF-8 in others; a lossy decoding here would read something else).
    public static func images(in dockerfile: Data, buildArgs: [String: String] = [:]) -> Result<[String], Refusal> {
        guard let text = String(validating: dockerfile, as: UTF8.self) else {
            return .failure(Refusal("the Dockerfile is not valid UTF-8 text, so BelloCode cannot read it the way Docker does"))
        }
        return images(in: text, buildArgs: buildArgs)
    }

    /// The external images, in order of appearance (duplicates removed), or why they cannot be determined. Includes a
    /// BuildKit frontend named by a `# syntax=` directive or the `BUILDKIT_SYNTAX` build argument (N04): BuildKit pulls
    /// and runs it before reading the rest.
    ///
    /// Heredoc bodies (N04): a body is skipped only for a heredoc BuildKit's parser would open (an unquoted `<<WORD` word
    /// of a `RUN`, `COPY` or `ADD` in shell form, also under `ONBUILD`), and an unterminated one is refused. Because a
    /// parser that disagrees about a heredoc would see other instructions, the file is also read with no heredocs at all
    /// and the images of both readings are checked; in that second reading only well-formed `FROM` lines count (`FROM
    /// image` or `FROM image AS name`, which is all Docker accepts), so script lines such as Python's `from x import y`
    /// are not taken for instructions.
    public static func images(in dockerfile: String, buildArgs: [String: String] = [:]) -> Result<[String], Refusal> {
        // AF11: the physical lines are taken once, from Unicode scalars (BOM dropped), and every reading shares them.
        let lines = physicalLines(dockerfile)
        let directives = Directives(lines)
        if let problem = directives.problem { return .failure(Refusal(problem)) }
        var images: [String] = []
        func add(_ image: String) { if !images.contains(image) { images.append(image) } }
        for frontend in directives.syntax + [buildArgs["BUILDKIT_SYNTAX"]].compactMap({ $0 }) {
            let value = frontend.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            guard isCheckableReference(value) else {
                return .failure(Refusal("the Dockerfile frontend “\(value)” cannot be checked against the image policy"))
            }
            add(value)
        }
        let withHeredocs: [String]
        switch instructions(lines: lines, escape: directives.escape, heredocs: true) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let lines): withHeredocs = lines
        }
        let without = (try? instructions(lines: lines, escape: directives.escape, heredocs: false).get()) ?? []
        for reading in [withHeredocs, without] {
            switch externalImages(reading, buildArgs: buildArgs, escape: directives.escape) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let found): for image in found { add(image) }
            }
        }
        return .success(images)
    }

    // MARK: Characters as Go reads them

    /// Go's `unicode.IsSpace`: the Unicode White_Space property (tab to CR, space, NEL, no-break space, the Zs blanks,
    /// line and paragraph separators). BuildKit strips these before a comment or an instruction.
    static func isGoSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace }

    /// A character Docker's code paths do not all read alike (GV01): any blank other than space and tab, and any
    /// control character other than tab. In an instruction, or a comment before the first one, it makes the file
    /// unreadable for the policy.
    static func isUncertain(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " || scalar == "\t" { return false }
        return scalar.properties.isWhitespace || scalar.properties.generalCategory == .control
    }

    static func uncertainScalar(_ text: String) -> Unicode.Scalar? { text.unicodeScalars.first(where: isUncertain) }

    static func uncertainRefusal(_ scalar: Unicode.Scalar, line: Int) -> Refusal {
        let code = String(scalar.value, radix: 16, uppercase: true)
        return Refusal("line \(line) of the Dockerfile holds the character U+\(String(repeating: "0", count: max(0, 4 - code.count)) + code), which Docker may read as a blank, so BelloCode cannot read the file the way Docker does")
    }

    /// `text` without its leading Go blanks.
    static func trimLeading(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.drop(while: isGoSpace)))
    }

    /// Go's `strings.TrimSpace`.
    static func trimGoSpace(_ text: String) -> String {
        var view = Substring(text).unicodeScalars.drop(while: isGoSpace)
        while let last = view.last, isGoSpace(last) { view = view.dropLast() }
        return String(String.UnicodeScalarView(view))
    }

    /// The lines as BuildKit reads them: split at each LF, every CR before it dropped (`trimNewline`), and a UTF-8
    /// byte-order mark dropped from the first line only (`discardBOM`), for the directives and the instructions alike
    /// (AF11). Taken from the Unicode scalars, never from Swift `Character`s: CR LF is a single `Character`, and a
    /// combining mark after `#`, a blank or the escape character fuses with it.
    static func physicalLines(_ text: String) -> [String] {
        var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var line = String.UnicodeScalarView(line)
            while line.last == "\r" { line.removeLast() }
            return String(line)
        }
        if let first = lines.first, first.unicodeScalars.first == "\u{FEFF}" {
            lines[0] = String(String.UnicodeScalarView(first.unicodeScalars.dropFirst()))
        }
        return lines
    }

    /// Words split on Go blanks, scalar by scalar.
    static func blankSeparatedWords(_ text: String) -> [String] {
        text.unicodeScalars.split(whereSeparator: isGoSpace).map { String(String.UnicodeScalarView($0)) }
    }

    /// The first and last scalar of a line (AF11: never a `Character`, which may fuse a mark with `#` or the escape).
    static func first(_ text: String) -> Unicode.Scalar? { text.unicodeScalars.first }
    static func last(_ text: String) -> Unicode.Scalar? { text.unicodeScalars.last }

    /// An image reference BelloCode can check: the characters of Docker's reference grammar only. Anything else (a
    /// quote Docker's shell processing would remove, a leftover `$`, a non-ASCII character) is refused, never guessed.
    static func isCheckableReference(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._:/@-".unicodeScalars.contains(scalar))
        }
    }

    // MARK: Instructions

    /// BuildKit's `extractBuilderFlags`, byte by byte as Docker runs it: each byte is a rune of its own, so the bytes
    /// 0x85 and 0xA0 inside a multibyte character end a flag word there. Returns the flags (quotes removed, `\`
    /// escapes applied) and the rest of the line after them.
    static func builderFlags(_ text: String) -> (flags: [String], rest: String) {
        let line = Array(text.utf8)
        func isSpace(_ byte: UInt8) -> Bool { (9...13).contains(byte) || byte == 32 || byte == 0x85 || byte == 0xA0 }
        func rest(_ from: Int) -> String { String(decoding: line[from...], as: UTF8.self) }
        var words: [String] = []
        var word = String.UnicodeScalarView()
        var inWord = false
        var inQuote = false
        var quote: UInt8 = 0
        var blankOK = false
        var pos = 0
        while pos <= line.count {
            var byte: UInt8 = 0
            if pos != line.count { byte = line[pos] }
            if !inWord && !inQuote {
                if pos == line.count { break }
                if isSpace(byte) { pos += 1; continue }
                if byte != UInt8(ascii: "-") || pos + 1 == line.count || line[pos + 1] != UInt8(ascii: "-") { return (words, rest(pos)) }
                inWord = true
            }
            if pos == line.count {
                if String(word) != "--" && (blankOK || !word.isEmpty) { words.append(String(word)) }
                break
            }
            if inWord {
                if isSpace(byte) {
                    inWord = false
                    if String(word) == "--" { return (words, rest(pos)) }
                    if blankOK || !word.isEmpty { words.append(String(word)) }
                    word = String.UnicodeScalarView()
                    blankOK = false
                    pos += 1
                    continue
                }
                if byte == UInt8(ascii: "'") || byte == UInt8(ascii: "\"") {
                    quote = byte
                    blankOK = true
                    inWord = false
                    inQuote = true
                    pos += 1
                    continue
                }
                if byte == UInt8(ascii: "\\") {
                    if pos + 1 == line.count { pos += 1; continue }
                    pos += 1
                    byte = line[pos]
                }
                word.append(Unicode.Scalar(byte))
                pos += 1
                continue
            }
            // In a quote.
            if byte == quote {
                inQuote = false
                inWord = true
                pos += 1
                continue
            }
            if byte == UInt8(ascii: "\\") {
                if pos + 1 == line.count {
                    inQuote = false
                    inWord = true
                    pos += 1
                    continue
                }
                pos += 1
                byte = line[pos]
            }
            word.append(Unicode.Scalar(byte))
            pos += 1
        }
        return (words, "")
    }

    /// The instruction's keyword (lowercased) and the rest, split at the first run of blanks (`splitCommand`).
    static func splitCommand(_ instruction: String) -> (keyword: String, rest: String) {
        let view = trimGoSpace(instruction).unicodeScalars
        guard let blank = view.firstIndex(where: isGoSpace) else { return (String(view).lowercased(), "") }
        let rest = view[blank...].drop(while: isGoSpace)
        return (String(String.UnicodeScalarView(view[..<blank])).lowercased(), String(String.UnicodeScalarView(rest)))
    }

    /// The values of `key` (lowercased) in a `--mount` option, read as Go's `encoding/csv` reads one record (quoted
    /// fields, `""` for a quote), or nil when that reader would fail.
    static func mountFields(_ value: String) -> [String]? {
        let scalars = Array(value.unicodeScalars)
        var fields: [String] = []
        var index = 0
        while true {
            var field = String.UnicodeScalarView()
            if index < scalars.count, scalars[index] == "\"" {
                index += 1
                while true {
                    guard let close = scalars[index...].firstIndex(of: "\"") else { return nil }
                    field.append(contentsOf: scalars[index..<close])
                    index = close + 1
                    if index < scalars.count, scalars[index] == "\"" { field.append("\""); index += 1; continue }
                    break
                }
                fields.append(String(field))
                if index == scalars.count { return fields }
                guard scalars[index] == "," else { return nil }
                index += 1
            } else {
                let end = scalars[index...].firstIndex(of: ",") ?? scalars.count
                field.append(contentsOf: scalars[index..<end])
                if field.contains("\"") { return nil }
                fields.append(String(field))
                if end == scalars.count { return fields }
                index = end + 1
            }
        }
    }

    /// The external images of one reading of the file.
    static func externalImages(_ instructions: [String], buildArgs: [String: String], escape: Unicode.Scalar = "\\") -> Result<[String], Refusal> {
        var images: [String] = []
        var stages: [String] = []
        var globals: [String: String] = [:]
        var seenFrom = false
        func add(_ image: String) { if !images.contains(image) { images.append(image) } }
        func external(_ raw: String, allowIndex: Bool) -> Result<String?, Refusal> {
            guard let value = expand(raw, globals) else {
                return .failure(Refusal("the base image “\(raw)” uses a build argument without a value, so BelloCode cannot check it against the image policy"))
            }
            let lowered = value.lowercased()
            if lowered == "scratch" || stages.contains(lowered) { return .success(nil) }
            if allowIndex, Int(value) != nil { return .success(nil) }
            if value.isEmpty { return .failure(Refusal("a FROM instruction names no image")) }
            guard isCheckableReference(value) else {
                return .failure(Refusal("the base image “\(value)” is not written as a plain image reference, so BelloCode cannot check it against the image policy"))
            }
            return .success(value)
        }
        /// A `--from` of COPY or of a RUN mount is used as written by Docker, or expanded with the stage's own arguments
        /// by later frontends: a variable there cannot be checked.
        func source(_ raw: String) -> Result<String?, Refusal> {
            if raw.contains("$") {
                return .failure(Refusal("the Dockerfile copies from “\(raw)”, which uses a variable, so BelloCode cannot check it against the image policy"))
            }
            return external(raw, allowIndex: true)
        }
        for instruction in instructions {
            let (keyword, rest) = splitCommand(instruction)
            switch keyword {
            case "arg" where !seenFrom:
                for word in dockerWords(rest, escape: escape) {
                    // AF12: `ARG =x` or `ARG =` names nothing; Docker fails such a file, so it is refused, never indexed.
                    let parts = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    guard let name = parts.first, !name.isEmpty else {
                        return .failure(Refusal("the Dockerfile's ARG “\(word)” has no name"))
                    }
                    if let value = buildArgs[name] {
                        globals[name] = value
                    } else if parts.count == 2 {
                        // Docker expands a global default with the arguments before it (`ARG B=$A`); a value this
                        // reader cannot evaluate exactly (quotes inside, escapes, an unset variable) leaves the
                        // argument unknown, so a reference using it is refused.
                        globals[name] = argumentValue(parts[1], globals, escape: escape)
                    } else {
                        globals[name] = nil
                    }
                }
            case "from":
                let operands = blankSeparatedWords(builderFlags(rest).rest)
                // Docker accepts `FROM image` or `FROM image AS name` only; anything else fails the build, so it pulls
                // nothing (and is not an instruction at all when it is a line of a script).
                guard operands.count == 1 || (operands.count == 3 && operands[1].lowercased() == "as") else { continue }
                seenFrom = true
                switch external(operands[0], allowIndex: false) {
                case .failure(let refusal): return .failure(refusal)
                case .success(let image): if let image { add(image) }
                }
                if operands.count == 3 { stages.append(operands[2].lowercased()) }
            case "copy", "add", "run":
                for flag in builderFlags(rest).flags where flag.hasPrefix("--") {
                    var sources: [String] = []
                    let lowered = flag.lowercased()
                    if lowered.hasPrefix("--from=") { sources.append(String(flag.dropFirst("--from=".count))) }
                    if lowered.hasPrefix("--mount=") {
                        guard let fields = mountFields(String(flag.dropFirst("--mount=".count))) else {
                            return .failure(Refusal("the Dockerfile has a RUN mount BelloCode cannot read (“\(flag)”)"))
                        }
                        for field in fields where field.lowercased().hasPrefix("from=") {
                            sources.append(String(field.dropFirst("from=".count)))
                        }
                    }
                    for raw in sources {
                        switch source(raw) {
                        case .failure(let refusal): return .failure(refusal)
                        case .success(let image): if let image { add(image) }
                        }
                    }
                }
            default:
                break
            }
        }
        return .success(images)
    }

    /// A global ARG's default as Docker's shell processing gives it, or nil when this reader cannot be sure.
    static func argumentValue(_ raw: String, _ globals: [String: String], escape: Unicode.Scalar) -> String? {
        var text = raw
        if text.count >= 2, let quote = text.first, quote == "'", text.last == quote {
            let inner = String(text.dropFirst().dropLast())
            return inner.contains("'") ? nil : inner
        }
        if text.count >= 2, text.first == "\"", text.last == "\"" { text = String(text.dropFirst().dropLast()) }
        if text.unicodeScalars.contains(where: { $0 == "\"" || $0 == "'" || $0 == escape }) { return nil }
        return expand(text, globals)
    }

    /// BuildKit's `parseWords`: words split on Go blanks outside quotes, quotes and escapes kept as written.
    static func dockerWords(_ text: String, escape: Unicode.Scalar) -> [String] {
        var words: [String] = []
        var word = String.UnicodeScalarView()
        var quote: Unicode.Scalar?
        var blankOK = false
        var iterator = Array(text.unicodeScalars).makeIterator()
        var started = false
        while let scalar = iterator.next() {
            if let open = quote {
                if scalar == open { quote = nil }
                if scalar == escape, open != "'" {
                    word.append(scalar)
                    guard let next = iterator.next() else { quote = nil; break }
                    word.append(next)
                    continue
                }
                word.append(scalar)
                continue
            }
            if isGoSpace(scalar) {
                if started, blankOK || !word.isEmpty { words.append(String(word)) }
                word = String.UnicodeScalarView()
                blankOK = false
                started = false
                continue
            }
            started = true
            if scalar == "'" || scalar == "\"" { quote = scalar; blankOK = true }
            if scalar == escape {
                guard let next = iterator.next() else { break }
                word.append(scalar)
                word.append(next)
                continue
            }
            word.append(scalar)
        }
        if started || quote != nil, blankOK || !word.isEmpty { words.append(String(word)) }
        return words
    }

    /// BuildKit's parser directives: only consecutive `# key=value` lines with a known key at the very top; the first
    /// other line (a comment, an unknown key, an empty line, an instruction) ends them. A `syntax` key is collected from
    /// any comment before the first instruction (more than BuildKit honours, so a frontend is never missed). The lines
    /// come from `physicalLines` (the first one without its byte-order mark, as Docker reads it: AF11).
    struct Directives {
        var escape: Unicode.Scalar = "\\"
        var syntax: [String] = []
        var problem: String?

        static let known: Set<String> = ["escape", "syntax", "check"]

        init(_ lines: [String]) {
            var active = true
            var seen = Set<String>()
            for line in lines {
                let trimmed = DockerfileBases.trimLeading(line)
                let pair = Self.directive(trimmed)
                if active {
                    if let (key, value) = pair, Self.known.contains(key) {
                        guard seen.insert(key).inserted else {
                            problem = "the Dockerfile sets the \(key) parser directive more than once"
                            return
                        }
                        if key == "escape" {
                            guard value == "\\" || value == "`" else {
                                problem = "the Dockerfile's escape directive “\(value)” is not \\ or `"
                                return
                            }
                            escape = value.unicodeScalars.first!
                        }
                        if key == "syntax" { syntax.append(value) }
                        continue
                    }
                    active = false
                }
                if trimmed.isEmpty { continue }
                guard DockerfileBases.first(trimmed) == "#" else { break }
                if let (key, value) = pair, key == "syntax", !syntax.contains(value) { syntax.append(value) }
            }
        }

        /// `#[ \t]*key[ \t]*=[ \t]*value[ \t]*` (key letters and digits, starting with a letter), lowercased key. Other
        /// blanks never get here: a directive line holding one is refused (`instructions`).
        static func directive(_ line: String) -> (String, String)? {
            func trim(_ text: Substring.UnicodeScalarView) -> String {
                var view = text.drop(while: { $0 == " " || $0 == "\t" })
                while view.last == " " || view.last == "\t" { view = view.dropLast() }
                return String(String.UnicodeScalarView(view))
            }
            guard DockerfileBases.first(line) == "#" else { return nil }
            let body = Substring(line).unicodeScalars.dropFirst()
            guard let equals = body.firstIndex(of: "=") else { return nil }
            let key = trim(body[..<equals])
            let value = trim(body[body.index(after: equals)...])
            guard let head = key.unicodeScalars.first, head.isASCII, CharacterSet.letters.contains(head),
                  key.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }),
                  !value.isEmpty else { return nil }
            return (key.lowercased(), value)
        }
    }

    /// Instructions with continuations joined; comments, parser directives and empty lines dropped (also inside a
    /// continuation, as BuildKit does); with `heredocs`, heredoc bodies dropped and an unterminated heredoc refused.
    static func instructions(_ dockerfile: String, escape: Unicode.Scalar = "\\", heredocs: Bool = true) -> Result<[String], Refusal> {
        instructions(lines: physicalLines(dockerfile), escape: escape, heredocs: heredocs)
    }

    /// BuildKit's `trimContinuationCharacter`: the escape followed only by spaces and tabs ends a continued line; it is
    /// removed with them and nothing is put in its place.
    static func trimContinuation(_ line: String, escape: Unicode.Scalar) -> (String, ended: Bool) {
        var view = Substring(line).unicodeScalars
        while view.last == " " || view.last == "\t" { view = view.dropLast() }
        guard view.last == escape else { return (line, true) }
        return (String(String.UnicodeScalarView(view.dropLast())), false)
    }

    /// The reading with heredocs is BelloCode's reading of the file as Docker parses it: there an uncertain character
    /// (GV01) in an instruction line, an empty line, or a comment before the first instruction (where the parser
    /// directives are) refuses the file, and so does a first instruction that is another frontend's directive form
    /// (`//syntax=`, a JSON document). The reading without heredocs only adds what it finds.
    static func instructions(lines: [String], escape: Unicode.Scalar, heredocs: Bool) -> Result<[String], Refusal> {
        let strict = heredocs
        var result: [String] = []
        var index = 0
        func unsure(_ line: String, _ number: Int) -> Refusal? {
            guard strict, let scalar = uncertainScalar(line) else { return nil }
            return uncertainRefusal(scalar, line: number)
        }
        while index < lines.count {
            let raw = lines[index]
            index += 1
            let token = trimLeading(raw)
            if token.isEmpty || first(token) == "#" {
                if token.isEmpty || result.isEmpty, let refusal = unsure(raw, index) { return .failure(refusal) }
                continue
            }
            if let refusal = unsure(raw, index) { return .failure(refusal) }
            var (line, ended) = trimContinuation(token, escape: escape)
            while !ended, index < lines.count {
                let next = lines[index]
                index += 1
                let trimmed = trimLeading(next)
                // A comment inside a continuation is dropped; an empty line is skipped (BuildKit joins across both).
                if first(trimmed) == "#" { continue }
                if let refusal = unsure(next, index) { return .failure(refusal) }
                if trimmed.isEmpty { continue }
                let part: String
                (part, ended) = trimContinuation(next, escape: escape)
                line += part
            }
            let instruction = trimGoSpace(line)
            if instruction.isEmpty { continue }
            if strict, result.isEmpty, instruction.hasPrefix("//") || instruction.hasPrefix("{") {
                return .failure(Refusal("the Dockerfile starts with “\(instruction.prefix(40))”, a frontend directive form BelloCode cannot check"))
            }
            result.append(instruction)
            guard heredocs else { continue }
            for heredoc in heredocWords(instruction) {
                var closed = false
                while index < lines.count {
                    var candidate = Substring(lines[index]).unicodeScalars
                    index += 1
                    if heredoc.chomp { candidate = candidate.drop(while: { $0 == "\t" }) }
                    if String(String.UnicodeScalarView(candidate)) == heredoc.name { closed = true; break }
                }
                if !closed { return .failure(Refusal("the Dockerfile's heredoc “\(heredoc.name)” is never closed")) }
            }
        }
        return .success(result)
    }

    /// The heredocs an instruction opens, in order: BuildKit opens them only for `RUN`, `COPY` and `ADD` (also after
    /// `ONBUILD`), not in the JSON form, for words (split on blanks outside quotes, quotes kept) matching
    /// `[digits]<<[-]WORD`, with WORD's quotes removed; `-` strips leading tabs from the closing line.
    static func heredocWords(_ instruction: String) -> [(name: String, chomp: Bool)] {
        guard instruction.contains("<<") else { return [] }
        var (keyword, rest) = splitCommand(instruction)
        if keyword == "onbuild" { (keyword, rest) = splitCommand(rest) }
        guard ["run", "copy", "add"].contains(keyword) else { return [] }
        if isJSONForm(builderFlags(rest).rest) { return [] }
        var ends: [(name: String, chomp: Bool)] = []
        for word in shellWords(rest) {
            var rest = Substring(word)
            while let digit = rest.first, digit.isASCII, digit.isNumber { rest = rest.dropFirst() }
            guard rest.hasPrefix("<<") else { continue }
            rest = rest.dropFirst(2)
            let chomp = rest.hasPrefix("-")
            if chomp { rest = rest.dropFirst() }
            guard !rest.isEmpty, !rest.contains("<") else { continue }
            let name = String(rest).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
            if !name.isEmpty { ends.append((name, chomp)) }
        }
        return ends
    }

    /// Docker's exec (JSON) form: the arguments are a JSON array of strings.
    static func isJSONForm(_ arguments: String) -> Bool {
        guard arguments.hasPrefix("["), let data = arguments.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return false }
        return array.allSatisfy { $0 is String }
    }

    /// Words split on blanks outside single or double quotes; quotes and backslashes kept as written (scalar by scalar).
    static func shellWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        var quote: Unicode.Scalar?
        var escaped = false
        for character in text.unicodeScalars {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { current.append(character); escaped = true; continue }
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character; current.append(character); continue }
            if isGoSpace(character) {
                if !current.isEmpty { words.append(String(current)); current = String.UnicodeScalarView() }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(String(current)) }
        return words
    }

    /// `$NAME`, `${NAME}`, `${NAME:-default}`, `${NAME:+alternative}` from `values`; nil when a variable has no value.
    static func expand(_ text: String, _ values: [String: String]) -> String? {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "$" else {
                output.append(character)
                index = text.index(after: index)
                continue
            }
            var cursor = text.index(after: index)
            guard cursor < text.endIndex else { return nil }
            if text[cursor] == "{" {
                guard let close = text[cursor...].firstIndex(of: "}") else { return nil }
                let body = String(text[text.index(after: cursor)..<close])
                index = text.index(after: close)
                if let range = body.range(of: ":-") {
                    let name = String(body[..<range.lowerBound])
                    if let value = values[name], !value.isEmpty { output += value } else {
                        guard let fallback = expand(String(body[range.upperBound...]), values) else { return nil }
                        output += fallback
                    }
                } else if let range = body.range(of: ":+") {
                    let name = String(body[..<range.lowerBound])
                    if let value = values[name], !value.isEmpty {
                        guard let alternative = expand(String(body[range.upperBound...]), values) else { return nil }
                        output += alternative
                    }
                } else {
                    guard let value = values[body] else { return nil }
                    output += value
                }
            } else {
                let start = cursor
                while cursor < text.endIndex, text[cursor].isASCII, text[cursor].isLetter || text[cursor].isNumber || text[cursor] == "_" { cursor = text.index(after: cursor) }
                let name = String(text[start..<cursor])
                guard !name.isEmpty, let value = values[name] else { return nil }
                output += value
                index = cursor
            }
        }
        return output
    }

    static func unquote(_ text: String) -> String {
        if text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first { return String(text.dropFirst().dropLast()) }
        return text
    }
}
