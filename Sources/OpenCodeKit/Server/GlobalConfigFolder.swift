import Darwin
import Foundation

/// BelloCode's opencode global configuration folder (`<data>/opencode/config/opencode/`): the files Settings ▸ opencode
/// opens and the folders it reveals. Missing files are created from a template; an existing file is never rewritten.
public struct GlobalConfigFolder: Sendable, Hashable {
    public let url: URL

    public init(directories: OpenCodeDirectories) { url = directories.globalConfigFolder }
    public init(url: URL) { self.url = url }

    public enum File: String, Sendable, CaseIterable {
        case config = "opencode.json"
        case instructions = "AGENTS.md"
    }

    /// The plural folder names (opencode 2.3.2 also reads the singular `agent/`, `command/`, `skill/`, `plugin/`).
    public enum Folder: String, Sendable, CaseIterable {
        case agents, commands, skills, plugins
    }

    public static func template(for file: File) -> String {
        switch file {
        case .config:
            // JSON (not JSONC) so any editor and `opencode` itself accept it; the schema gives completion in editors.
            return "{\n  \"$schema\": \"https://opencode.ai/config.json\"\n}\n"
        case .instructions:
            return """
                <!--
                Global instructions for every BelloCode thread in every project (opencode reads this file as AGENTS.md).
                Write plain Markdown below; a project's own AGENTS.md is added after it.
                -->

                """
        }
    }

    public func path(of file: File) -> URL { url.appending(path: file.rawValue) }
    public func path(of folder: Folder) -> URL { url.appending(path: folder.rawValue, directoryHint: .isDirectory) }

    /// Returns the file, creating the folder and the template first if it does not exist. `created` is true when the
    /// template was written now.
    @discardableResult
    public func ensure(_ file: File) throws -> (url: URL, created: Bool) {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let target = path(of: file)
        // O_EXCL: never replace a file created meanwhile (the user's editor, the CLI), not even between a check and
        // the write (N14).
        let fd = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        if fd < 0 {
            if errno == EEXIST { return (target, false) }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
        let data = Data(Self.template(for: file).utf8)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path]) }
        return (target, true)
    }

    @discardableResult
    public func ensure(_ folder: Folder) throws -> URL {
        let target = path(of: folder)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    /// A syntax problem in `opencode.json` (opencode drops a malformed document silently: measured on 2.3.2, it simply
    /// disappears from `GET /api/config`). Nil when the file is missing or parses as JSON with comments and trailing
    /// commas (JSONC).
    public func configSyntaxError() -> String? {
        guard let data = try? Data(contentsOf: path(of: .config)) else { return nil }
        return JSONCheck.syntaxError(in: data)
    }
}

/// A small JSONC check (comments and trailing commas allowed, as opencode accepts) reporting line and column. Works on
/// UTF-16 code units, so CR, LF and CRLF line endings, a leading byte order mark and any comment placement behave the
/// same (A25, N14).
public enum JSONCheck {
    public static func syntaxError(in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).isEmpty {
            return "opencode.json is empty: it must contain a JSON object, such as {}."
        }
        let stripped: String
        switch stripChecked(text) {
        case .success(let value): stripped = value
        case .failure(let problem): return "opencode.json, line \(problem.line), column \(problem.column): unterminated /* comment"
        }
        do {
            let value = try JSONSerialization.jsonObject(with: Data(stripped.utf8), options: [.fragmentsAllowed])
            guard value is [String: Any] else { return "opencode.json must contain a JSON object ({ … })." }
            return nil
        } catch {
            let nsError = error as NSError
            let message = (nsError.userInfo["NSDebugDescription"] as? String) ?? nsError.localizedDescription
            if let index = nsError.userInfo["NSJSONSerializationErrorIndex"] as? Int {
                let (line, column) = position(of: index, in: stripped)
                return "opencode.json, line \(line), column \(column): \(message)"
            }
            return "opencode.json: \(message)"
        }
    }

    /// The top-level object of a JSONC document (comments, trailing commas, any line ending, a byte order mark), or nil.
    public static func object(from data: Data) -> [String: Any]? {
        guard case .success(let stripped) = stripChecked(String(decoding: data, as: UTF8.self)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(stripped.utf8))) as? [String: Any]
    }

    struct Unterminated: Error {
        var line: Int
        var column: Int
    }

    /// Comments and a leading byte order mark replaced with spaces (line breaks kept, so offsets and positions stay),
    /// then commas before `}` or `]` (across whitespace and comments) replaced with a space.
    static func strip(_ text: String) -> String {
        switch stripChecked(text) {
        case .success(let value): value
        case .failure: text
        }
    }

    static func stripChecked(_ text: String) -> Result<String, Unterminated> {
        var units = Array(text.utf16)
        let space: UInt16 = 0x20
        func isBreak(_ unit: UInt16) -> Bool { unit == 0x0A || unit == 0x0D }
        if units.first == 0xFEFF { units[0] = space }
        // Pass 1: comments.
        var i = 0
        var inString = false
        while i < units.count {
            let c = units[i]
            if inString {
                if c == 0x5C { i += 2; continue }
                if c == 0x22 { inString = false }
                i += 1
                continue
            }
            if c == 0x22 { inString = true; i += 1; continue }
            if c == 0x2F, i + 1 < units.count, units[i + 1] == 0x2F {
                while i < units.count, !isBreak(units[i]) { units[i] = space; i += 1 }
                continue
            }
            if c == 0x2F, i + 1 < units.count, units[i + 1] == 0x2A {
                let start = i
                units[i] = space; units[i + 1] = space; i += 2
                while i < units.count, !(units[i] == 0x2A && i + 1 < units.count && units[i + 1] == 0x2F) {
                    if !isBreak(units[i]) { units[i] = space }
                    i += 1
                }
                guard i < units.count else {
                    let (line, column) = position(of: start, in: String(decoding: Array(text.utf16), as: UTF16.self))
                    return .failure(Unterminated(line: line, column: column))
                }
                units[i] = space; units[i + 1] = space; i += 2
                continue
            }
            i += 1
        }
        // Pass 2: trailing commas (comments are spaces now).
        i = 0
        inString = false
        while i < units.count {
            let c = units[i]
            if inString {
                if c == 0x5C { i += 2; continue }
                if c == 0x22 { inString = false }
                i += 1
                continue
            }
            if c == 0x22 { inString = true }
            if c == 0x2C {
                var j = i + 1
                while j < units.count, units[j] == space || units[j] == 0x09 || isBreak(units[j]) { j += 1 }
                if j < units.count, units[j] == 0x7D || units[j] == 0x5D { units[i] = space }
            }
            i += 1
        }
        return .success(String(decoding: units, as: UTF16.self))
    }

    /// Line and column (1-based) of a UTF-16 offset; CR, LF and CRLF each end one line.
    static func position(of utf16Index: Int, in text: String) -> (Int, Int) {
        var line = 1
        var column = 1
        var previous: UInt16 = 0
        for (offset, unit) in text.utf16.enumerated() {
            if offset >= utf16Index { break }
            if unit == 0x0A {
                if previous != 0x0D { line += 1 }
                column = 1
            } else if unit == 0x0D {
                line += 1
                column = 1
            } else {
                column += 1
            }
            previous = unit
        }
        return (line, column)
    }
}
