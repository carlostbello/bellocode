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
        if FileManager.default.fileExists(atPath: target.path) { return (target, false) }
        // O_EXCL semantics: never replace a file created meanwhile (the user's editor, the CLI).
        let created = FileManager.default.createFile(atPath: target.path, contents: Data(Self.template(for: file).utf8), attributes: [.posixPermissions: 0o644])
        if !created, !FileManager.default.fileExists(atPath: target.path) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
        return (target, created)
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

/// A small JSONC check (comments and trailing commas allowed, as opencode accepts) reporting line and column.
public enum JSONCheck {
    public static func syntaxError(in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "opencode.json is empty: it must contain a JSON object, such as {}." }
        let stripped = strip(text)
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

    /// Replaces comments with spaces (keeping offsets and newlines) and drops trailing commas before `}` or `]`.
    static func strip(_ text: String) -> String {
        var out: [Character] = []
        let chars = Array(text)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { out.append(" "); i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                out.append(" "); out.append(" "); i += 2
                while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") {
                    out.append(chars[i] == "\n" ? "\n" : " "); i += 1
                }
                if i < chars.count { out.append(" "); out.append(" "); i += 2 }
                continue
            }
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { out.append(" "); i += 1; continue }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    static func position(of utf16Index: Int, in text: String) -> (Int, Int) {
        var line = 1
        var column = 1
        for (offset, unit) in text.utf16.enumerated() {
            if offset >= utf16Index { break }
            if unit == 0x0A { line += 1; column = 1 } else { column += 1 }
        }
        return (line, column)
    }
}
