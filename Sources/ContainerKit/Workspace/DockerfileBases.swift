import Foundation

/// The images a Dockerfile pulls (docs/reviews/release-1.0-review.md, R14): every `FROM` that is not an earlier stage
/// or `scratch`, and every `COPY --from` / `ADD --from` / `RUN --mount=…,from=` naming an image. The image policy's
/// registry allowlist applies to these, never to the tag BelloCode gives the locally built result.
///
/// Variables in those references are expanded from the global `ARG`s (before the first `FROM`) and the build arguments,
/// as Docker does. A reference that still holds a variable cannot be checked, so it is refused rather than guessed.
public enum DockerfileBases {
    public struct Refusal: Error, Sendable, Equatable, CustomStringConvertible {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
        public var description: String { reason }
    }

    /// The external images, in order of appearance (duplicates removed), or why they cannot be determined. Includes a
    /// BuildKit frontend named by a `# syntax=` directive or the `BUILDKIT_SYNTAX` build argument (N04): BuildKit pulls
    /// and runs it before reading the rest.
    ///
    /// Heredoc bodies (N04): a body is skipped only for a heredoc BuildKit's parser would open (an unquoted `<<WORD` word
    /// of a `RUN`, `COPY` or `ADD`, also under `ONBUILD`), and an unterminated one is refused. Because a parser that
    /// disagrees about a heredoc would see other instructions, the file is also read with no heredocs at all and the
    /// images of both readings are checked; in that second reading only well-formed `FROM` lines count (`FROM image` or
    /// `FROM image AS name`, which is all Docker accepts), so script lines such as Python's `from x import y` are not
    /// taken for instructions.
    public static func images(in dockerfile: String, buildArgs: [String: String] = [:]) -> Result<[String], Refusal> {
        // AF11: the physical lines are taken once, from Unicode scalars, and both readings below share them.
        let dockerfile = physicalLines(dockerfile)
        let directives = Directives(dockerfile)
        if let problem = directives.problem { return .failure(Refusal(problem)) }
        var images: [String] = []
        func add(_ image: String) { if !images.contains(image) { images.append(image) } }
        for frontend in directives.syntax + [buildArgs["BUILDKIT_SYNTAX"]].compactMap({ $0 }) {
            let value = frontend.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            if value.contains("$") { return .failure(Refusal("the Dockerfile frontend “\(value)” cannot be checked against the image policy")) }
            add(value)
        }
        let withHeredocs: [String]
        switch instructions(lines: dockerfile, escape: directives.escape, heredocs: true) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let lines): withHeredocs = lines
        }
        let without = (try? instructions(lines: dockerfile, escape: directives.escape, heredocs: false).get()) ?? []
        for reading in [withHeredocs, without] {
            switch externalImages(reading, buildArgs: buildArgs) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let found): for image in found { add(image) }
            }
        }
        return .success(images)
    }

    /// The lines as BuildKit reads them (Go's line scanner): split at each LF, one CR before it dropped. Taken from the
    /// Unicode scalars, never from Swift `Character`s (AF11): CR LF is a single `Character`, so a CRLF file split on
    /// `Character`s is one line (a leading comment then hides every instruction), and a combining mark after `#`, a
    /// blank or the escape character fuses with it, so a `Character` reading would see a different line or word than
    /// Docker does.
    static func physicalLines(_ text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var line = String.UnicodeScalarView(line)
            if line.last == "\r" { line.removeLast() }
            return String(line)
        }
    }

    /// Words split on spaces and tabs, scalar by scalar (AF11).
    static func blankSeparatedWords(_ text: String) -> [String] {
        text.unicodeScalars.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { String(String.UnicodeScalarView($0)) }
    }

    /// The first and last scalar of a line (AF11: never a `Character`, which may fuse a mark with `#` or the escape).
    static func first(_ text: String) -> Unicode.Scalar? { text.unicodeScalars.first }
    static func last(_ text: String) -> Unicode.Scalar? { text.unicodeScalars.last }

    /// The external images of one reading of the file.
    static func externalImages(_ instructions: [String], buildArgs: [String: String]) -> Result<[String], Refusal> {
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
            return .success(value)
        }
        for instruction in instructions {
            let words = blankSeparatedWords(instruction)
            guard let keyword = words.first?.uppercased() else { continue }
            switch keyword {
            case "ARG" where !seenFrom:
                for word in words.dropFirst() {
                    // AF12: `ARG =x` or `ARG =` names nothing; Docker fails such a file, so it is refused, never indexed.
                    let parts = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    guard let name = parts.first, !name.isEmpty else {
                        return .failure(Refusal("the Dockerfile's ARG “\(word)” has no name"))
                    }
                    if let value = buildArgs[name] { globals[name] = value } else if parts.count == 2 { globals[name] = unquote(parts[1]) }
                }
            case "FROM":
                let operands = words.dropFirst().filter { !$0.hasPrefix("--") }
                // Docker accepts `FROM image` or `FROM image AS name` only; anything else fails the build, so it pulls
                // nothing (and is not an instruction at all when it is a line of a script).
                guard operands.count == 1 || (operands.count == 3 && operands[1].uppercased() == "AS") else { continue }
                seenFrom = true
                switch external(operands[0], allowIndex: false) {
                case .failure(let refusal): return .failure(refusal)
                case .success(let image): if let image { add(image) }
                }
                if operands.count == 3 { stages.append(operands[2].lowercased()) }
            case "COPY", "ADD", "RUN":
                for flag in words.dropFirst() where flag.hasPrefix("--") {
                    var sources: [String] = []
                    let lowered = flag.lowercased()
                    if lowered.hasPrefix("--from=") { sources.append(String(flag.dropFirst("--from=".count))) }
                    if lowered.hasPrefix("--mount=") {
                        for option in unquote(String(flag.dropFirst("--mount=".count))).split(separator: ",")
                        where option.lowercased().hasPrefix("from=") {
                            sources.append(String(option.dropFirst("from=".count)))
                        }
                    }
                    for source in sources {
                        switch external(unquote(source), allowIndex: true) {
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

    /// BuildKit's parser directives: only consecutive `# key=value` lines with a known key at the very top; the first
    /// other line (a comment, an unknown key, an empty line, an instruction) ends them. A `syntax` key is collected from
    /// any comment before the first instruction (more than BuildKit honours, so a frontend is never missed).
    struct Directives {
        var escape: Unicode.Scalar = "\\"
        var syntax: [String] = []
        var problem: String?

        static let known: Set<String> = ["escape", "syntax", "check"]

        init(_ lines: [String]) {
            var active = true
            var seen = Set<String>()
            var first = true
            for raw in lines {
                var line = raw
                if first, line.unicodeScalars.first == "\u{FEFF}" { line = String(line.unicodeScalars.dropFirst()) }
                first = false
                let trimmed = line.trimmingCharacters(in: .whitespaces)
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

        /// `# key = value` (key letters and digits, starting with a letter), lowercased key.
        static func directive(_ line: String) -> (String, String)? {
            guard DockerfileBases.first(line) == "#" else { return nil }
            let body = String(line.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard let equals = body.firstIndex(of: "=") else { return nil }
            let key = body[..<equals].trimmingCharacters(in: .whitespaces)
            let value = body[body.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let head = key.first, head.isASCII, head.isLetter, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                  !value.isEmpty else { return nil }
            return (key.lowercased(), value)
        }
    }

    /// Instructions with continuations joined; comments, parser directives and empty lines dropped (also inside a
    /// continuation, as BuildKit does); with `heredocs`, heredoc bodies dropped and an unterminated heredoc refused.
    static func instructions(_ dockerfile: String, escape: Unicode.Scalar = "\\", heredocs: Bool = true) -> Result<[String], Refusal> {
        instructions(lines: physicalLines(dockerfile), escape: escape, heredocs: heredocs)
    }

    static func instructions(lines: [String], escape: Unicode.Scalar, heredocs: Bool) -> Result<[String], Refusal> {
        var result: [String] = []
        var current = ""
        var pending: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let end = pending.first {
                // Ends no later than BuildKit would (it compares the line, tabs stripped for `<<-`, with the word).
                if trimmed == end { pending.removeFirst() }
                continue
            }
            if first(trimmed) == "#" || trimmed.isEmpty { continue }
            if last(trimmed) == escape {
                current += String(trimmed.unicodeScalars.dropLast()) + " "
                continue
            }
            current += trimmed
            let instruction = current.trimmingCharacters(in: .whitespaces)
            if heredocs { pending = heredocWords(instruction) }
            result.append(instruction)
            current = ""
        }
        if !current.isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
        if let open = pending.first {
            return .failure(Refusal("the Dockerfile's heredoc “\(open)” is never closed"))
        }
        return .success(result)
    }

    /// The words ending the heredocs an instruction opens, in order: BuildKit opens them only for `RUN`, `COPY` and `ADD`
    /// (also after `ONBUILD`), not in the JSON form, for words (split on blanks outside quotes, quotes kept) matching
    /// `[digits]<<[-]WORD`, with WORD's quotes removed.
    static func heredocWords(_ instruction: String) -> [String] {
        guard instruction.contains("<<") else { return [] }
        var words = shellWords(instruction)
        guard var keyword = words.first?.uppercased() else { return [] }
        words.removeFirst()
        if keyword == "ONBUILD", let next = words.first {
            keyword = next.uppercased()
            words.removeFirst()
        }
        guard ["RUN", "COPY", "ADD"].contains(keyword), !(words.first?.hasPrefix("[") ?? false) else { return [] }
        var ends: [String] = []
        for word in words {
            var rest = Substring(word)
            while let digit = rest.first, digit.isASCII, digit.isNumber { rest = rest.dropFirst() }
            guard rest.hasPrefix("<<") else { continue }
            rest = rest.dropFirst(2)
            if rest.hasPrefix("-") { rest = rest.dropFirst() }
            guard !rest.isEmpty, !rest.contains("<") else { continue }
            let name = String(rest).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
            if !name.isEmpty { ends.append(name) }
        }
        return ends
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
            if character == " " || character == "\t" {
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
                while cursor < text.endIndex, text[cursor].isLetter || text[cursor].isNumber || text[cursor] == "_" { cursor = text.index(after: cursor) }
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
