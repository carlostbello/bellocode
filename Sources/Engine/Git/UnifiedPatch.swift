import Foundation

/// One line of a hunk.
public struct PatchLine: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case context, added, removed }
    public var kind: Kind
    /// The text without its prefix or line terminator.
    public var text: String
    /// Followed by "\ No newline at end of file".
    public var noNewlineAtEnd: Bool

    public init(_ kind: Kind, _ text: String, noNewlineAtEnd: Bool = false) {
        self.kind = kind
        self.text = text
        self.noNewlineAtEnd = noNewlineAtEnd
    }
}

/// A hunk: `@@ -oldStart,oldCount +newStart,newCount @@ section`.
public struct PatchHunk: Sendable, Hashable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// Text after the second `@@` (often the enclosing function).
    public var section: String
    public var lines: [PatchLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String = "", lines: [PatchLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }

    /// The old side: context and removed lines.
    public var oldLines: [String] { lines.filter { $0.kind != .added }.map(\.text) }
    /// The new side: context and added lines.
    public var newLines: [String] { lines.filter { $0.kind != .removed }.map(\.text) }
    public var additions: Int { lines.count { $0.kind == .added } }
    public var deletions: Int { lines.count { $0.kind == .removed } }

    public var header: String {
        func range(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
        return "@@ -\(range(oldStart, oldCount)) +\(range(newStart, newCount)) @@" + (section.isEmpty ? "" : " " + section)
    }

    /// The hunk with old and new swapped (what reverting it applies).
    public var inverted: PatchHunk {
        PatchHunk(
            oldStart: newStart, oldCount: newCount, newStart: oldStart, newCount: oldCount, section: section,
            lines: lines.map { line in
                var copy = line
                copy.kind = line.kind == .added ? .removed : line.kind == .removed ? .added : .context
                return copy
            })
    }
}

/// One file of a unified diff.
public struct PatchFile: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable { case added, deleted, modified, renamed, copied }
    /// Path before the change (nil for an added file).
    public var oldPath: String?
    /// Path after the change (nil for a deleted file).
    public var newPath: String?
    public var status: Status
    public var isBinary: Bool
    public var hunks: [PatchHunk]
    /// Header lines between `diff --git` and the first hunk (index, mode, rename), kept for rendering.
    public var headerLines: [String]

    public init(
        oldPath: String?, newPath: String?, status: Status = .modified, isBinary: Bool = false, hunks: [PatchHunk] = [],
        headerLines: [String] = []
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.status = status
        self.isBinary = isBinary
        self.hunks = hunks
        self.headerLines = headerLines
    }

    /// The path to show: the new path, else the old one.
    public var path: String { newPath ?? oldPath ?? "" }
    public var additions: Int { hunks.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.deletions } }

    /// `git apply`-compatible text for this file restricted to `hunks` (all by default).
    public func render(hunks selected: [PatchHunk]? = nil) -> String {
        let a = oldPath.map { "a/" + $0 } ?? "/dev/null"
        let b = newPath.map { "b/" + $0 } ?? "/dev/null"
        var out = "diff --git a/\(oldPath ?? newPath ?? "") b/\(newPath ?? oldPath ?? "")\n"
        for line in headerLines where !line.hasPrefix("index ") { out += line + "\n" }
        out += "--- \(a)\n+++ \(b)\n"
        for hunk in selected ?? hunks {
            out += hunk.header + "\n"
            for line in hunk.lines {
                out += (line.kind == .added ? "+" : line.kind == .removed ? "-" : " ") + line.text + "\n"
                if line.noNewlineAtEnd { out += "\\ No newline at end of file\n" }
            }
        }
        return out
    }
}

/// Parses `git diff` output (one or more files). Tolerant: unknown header lines are kept, malformed hunk headers end
/// the file's hunks.
public enum UnifiedPatchParser {
    public static func parse(_ text: String) -> [PatchFile] {
        var files: [PatchFile] = []
        var current: PatchFile?
        var hunk: PatchHunk?
        var remainingOld = 0
        var remainingNew = 0

        func finishHunk() {
            if let finished = hunk { current?.hunks.append(finished) }
            hunk = nil
        }
        func finishFile() {
            finishHunk()
            if let file = current { files.append(file) }
            current = nil
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        for raw in lines {
            var line = Substring(raw)
            if line.hasSuffix("\r"), hunk == nil { line = line.dropLast() }
            if hunk != nil, remainingOld > 0 || remainingNew > 0 {
                switch line.first {
                case " ":
                    hunk?.lines.append(PatchLine(.context, String(line.dropFirst())))
                    remainingOld -= 1
                    remainingNew -= 1
                    continue
                case "+":
                    hunk?.lines.append(PatchLine(.added, String(line.dropFirst())))
                    remainingNew -= 1
                    continue
                case "-":
                    hunk?.lines.append(PatchLine(.removed, String(line.dropFirst())))
                    remainingOld -= 1
                    continue
                case nil:
                    // An empty line inside a hunk is an empty context line (some tools strip the space).
                    hunk?.lines.append(PatchLine(.context, ""))
                    remainingOld -= 1
                    remainingNew -= 1
                    continue
                case "\\":
                    markNoNewline(&hunk)
                    continue
                default:
                    finishHunk()
                }
            }
            if line.hasPrefix("\\"), hunk != nil {
                markNoNewline(&hunk)
                continue
            }
            if line.hasPrefix("diff --git ") {
                finishFile()
                let (a, b) = gitPaths(line.dropFirst("diff --git ".count))
                current = PatchFile(oldPath: a, newPath: b)
                continue
            }
            if line.hasPrefix("@@ ") {
                finishHunk()
                if current == nil { current = PatchFile(oldPath: nil, newPath: nil) }
                guard let parsed = parseHunkHeader(line) else { continue }
                hunk = parsed
                remainingOld = parsed.oldCount
                remainingNew = parsed.newCount
                continue
            }
            if line.hasPrefix("--- ") {
                if current == nil { current = PatchFile(oldPath: nil, newPath: nil) }
                current?.oldPath = path(line.dropFirst(4), prefix: "a/")
                continue
            }
            if line.hasPrefix("+++ ") {
                if current == nil { current = PatchFile(oldPath: nil, newPath: nil) }
                current?.newPath = path(line.dropFirst(4), prefix: "b/")
                continue
            }
            guard current != nil else { continue }
            let header = String(line)
            current?.headerLines.append(header)
            if header.hasPrefix("new file mode") { current?.status = .added }
            if header.hasPrefix("deleted file mode") { current?.status = .deleted }
            if header.hasPrefix("rename from ") {
                current?.status = .renamed
                current?.oldPath = String(header.dropFirst("rename from ".count))
            }
            if header.hasPrefix("rename to ") { current?.newPath = String(header.dropFirst("rename to ".count)) }
            if header.hasPrefix("copy from ") { current?.status = .copied }
            if header.hasPrefix("Binary files ") || header == "GIT binary patch" { current?.isBinary = true }
        }
        finishFile()
        for index in files.indices {
            if files[index].oldPath == nil, files[index].status == .modified { files[index].status = .added }
            if files[index].newPath == nil, files[index].status == .modified { files[index].status = .deleted }
        }
        return files
    }

    private static func markNoNewline(_ hunk: inout PatchHunk?) {
        guard var current = hunk, !current.lines.isEmpty else { return }
        current.lines[current.lines.count - 1].noNewlineAtEnd = true
        hunk = current
    }

    static func parseHunkHeader(_ line: Substring) -> PatchHunk? {
        // @@ -a[,b] +c[,d] @@ section
        let body = line.dropFirst(3)
        guard let end = body.range(of: " @@") else { return nil }
        let ranges = body[..<end.lowerBound].split(separator: " ")
        guard ranges.count == 2, ranges[0].hasPrefix("-"), ranges[1].hasPrefix("+") else { return nil }
        func parse(_ token: Substring) -> (Int, Int)? {
            let parts = token.dropFirst().split(separator: ",")
            guard let start = Int(parts.first ?? "") else { return nil }
            let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            return (start, count)
        }
        guard let old = parse(ranges[0]), let new = parse(ranges[1]) else { return nil }
        let section = body[end.upperBound...].trimmingCharacters(in: .whitespaces)
        return PatchHunk(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1, section: section, lines: [])
    }

    private static func path(_ token: Substring, prefix: String) -> String? {
        var value = String(token)
        if let tab = value.firstIndex(of: "\t") { value = String(value[..<tab]) }
        if value == "/dev/null" { return nil }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
        return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }

    /// `a/x b/y` → ("x", "y"). Paths with spaces are split at " b/".
    private static func gitPaths(_ rest: Substring) -> (String?, String?) {
        let text = String(rest)
        if let range = text.range(of: " b/"), text.hasPrefix("a/") {
            return (String(text[text.index(text.startIndex, offsetBy: 2)..<range.lowerBound]), String(text[range.upperBound...]))
        }
        let parts = text.split(separator: " ", maxSplits: 1)
        return (parts.first.map { String($0.dropFirst(2)) }, parts.count > 1 ? String(parts[1].dropFirst(2)) : nil)
    }
}
