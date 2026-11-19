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

    /// The external images, in order of appearance (duplicates removed), or why they cannot be determined.
    public static func images(in dockerfile: String, buildArgs: [String: String] = [:]) -> Result<[String], Refusal> {
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
        for instruction in instructions(dockerfile) {
            let words = instruction.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let keyword = words.first?.uppercased() else { continue }
            switch keyword {
            case "ARG" where !seenFrom:
                for word in words.dropFirst() {
                    let parts = word.split(separator: "=", maxSplits: 1).map(String.init)
                    let name = parts[0]
                    if let value = buildArgs[name] { globals[name] = value } else if parts.count == 2 { globals[name] = unquote(parts[1]) }
                }
            case "FROM":
                seenFrom = true
                let operands = words.dropFirst().filter { !$0.hasPrefix("--") }
                guard let reference = operands.first else { return .failure(Refusal("a FROM instruction names no image")) }
                switch external(reference, allowIndex: false) {
                case .failure(let refusal): return .failure(refusal)
                case .success(let image): if let image { add(image) }
                }
                if operands.count >= 3, operands[1].uppercased() == "AS" { stages.append(operands[2].lowercased()) }
            case "COPY", "ADD", "RUN":
                for flag in words.dropFirst() where flag.hasPrefix("--") {
                    var sources: [String] = []
                    if flag.lowercased().hasPrefix("--from=") { sources.append(String(flag.dropFirst("--from=".count))) }
                    if flag.lowercased().hasPrefix("--mount=") {
                        for option in flag.dropFirst("--mount=".count).split(separator: ",") where option.lowercased().hasPrefix("from=") {
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

    /// Instructions with continuations joined, comments, parser directives and heredoc bodies dropped.
    static func instructions(_ dockerfile: String) -> [String] {
        var escape: Character = "\\"
        var result: [String] = []
        var current = ""
        var heredoc: String?
        var directives = true
        for raw in dockerfile.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let end = heredoc {
                if trimmed == end { heredoc = nil }
                continue
            }
            if trimmed.hasPrefix("#") {
                if directives {
                    let parts = trimmed.dropFirst().split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2, parts[0].lowercased() == "escape", let character = parts[1].first { escape = character }
                }
                continue
            }
            directives = false
            if trimmed.isEmpty, current.isEmpty { continue }
            if trimmed.last == escape {
                current += trimmed.dropLast() + " "
                continue
            }
            current += trimmed
            if let marker = ImageBuildNetwork.heredocMarker(current) { heredoc = marker }
            result.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        }
        if !current.isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
        return result
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
