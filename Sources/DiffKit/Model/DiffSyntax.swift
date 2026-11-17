import Engine
import Foundation
import TranscriptKit

/// Syntax tokens for a diff, per side and line number, from TranscriptKit's `HighlightService`.
///
/// Each side is tokenized as one text (the full file when known, else the hunks' lines joined) so multi-line
/// constructs (block comments, strings) colour correctly, then cut into per-line runs. Built off the main actor;
/// sides above `maxUTF16` stay plain.
public struct DiffSyntax: Sendable {
    /// Line number → runs (UTF-16 offsets relative to the line).
    public var old: [Int: [TokenRun]]
    public var new: [Int: [TokenRun]]

    public static let empty = DiffSyntax(old: [:], new: [:])
    public static let maxUTF16 = 1_500_000

    public func runs(for cell: DiffCell) -> [TokenRun]? {
        cell.side == .old ? old[cell.number] : new[cell.number]
    }

    /// The highlighter language for a path's extension (nil: plain).
    public static func language(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let byName: [String: String] = ["makefile": "shell", "dockerfile": "shell", "package.swift": "swift", "podfile": "ruby", "gemfile": "ruby"]
        if let language = byName[name] { return language }
        let ext = (path as NSString).pathExtension.lowercased()
        let byExtension: [String: String] = [
            "swift": "swift", "ts": "typescript", "tsx": "typescript", "js": "typescript", "jsx": "typescript", "mjs": "typescript",
            "cjs": "typescript", "py": "python", "rs": "rust", "go": "go", "c": "c", "h": "c", "m": "c", "mm": "cpp", "cc": "cpp",
            "cpp": "cpp", "hpp": "cpp", "java": "java", "kt": "kotlin", "kts": "kotlin", "rb": "ruby", "sql": "sql", "json": "json",
            "jsonc": "json", "yml": "yaml", "yaml": "yaml", "sh": "shell", "bash": "shell", "zsh": "shell", "fish": "shell",
            "html": "html", "htm": "html", "xml": "html", "svg": "html", "plist": "html", "vue": "html", "css": "css", "scss": "css",
            "less": "css", "toml": "yaml", "md": nil, "txt": nil,
        ].compactMapValues { $0 }
        return byExtension[ext]
    }

    /// Tokens for one file's diff.
    public static func compute(for file: DiffFile, highlighter: any HighlightService = TokenizerHighlighter.shared) -> DiffSyntax {
        guard !file.isLarge, file.content == .text, let language = file.language, highlighter.supports(language) else { return .empty }
        var result = DiffSyntax.empty
        func side(_ fullLines: [Substring]?, _ hunkSegments: [(start: Int, lines: [String])]) -> [Int: [TokenRun]] {
            if let fullLines, !fullLines.isEmpty {
                return tokenize([(1, fullLines.map(String.init))], language: language, highlighter: highlighter)
            }
            return tokenize(hunkSegments, language: language, highlighter: highlighter)
        }
        let oldSegments = file.hunks.map { (start: $0.oldCount == 0 ? $0.oldStart + 1 : $0.oldStart, lines: $0.oldLines) }
        let newSegments = file.hunks.map { (start: $0.newCount == 0 ? $0.newStart + 1 : $0.newStart, lines: $0.newLines) }
        result.old = side(file.oldLines, oldSegments)
        if Task.isCancelled { return result }
        result.new = side(file.newLines, newSegments)
        return result
    }

    static func tokenize(_ segments: [(start: Int, lines: [String])], language: String, highlighter: any HighlightService) -> [Int: [TokenRun]] {
        var map: [Int: [TokenRun]] = [:]
        var budget = maxUTF16
        for segment in segments where !segment.lines.isEmpty {
            let text = segment.lines.joined(separator: "\n")
            let length = text.utf16.count
            guard length <= budget else { break }
            budget -= length
            let runs = highlighter.tokens(for: text, language: language)
            if Task.isCancelled { return map }
            // Line start offsets (UTF-16).
            var starts: [Int] = []
            starts.reserveCapacity(segment.lines.count)
            var offset = 0
            for line in segment.lines {
                starts.append(offset)
                offset += line.utf16.count + 1
            }
            var lineIndex = 0
            for run in runs {
                var location = run.location
                let end = run.location + run.length
                while location < end {
                    while lineIndex + 1 < starts.count, starts[lineIndex + 1] <= location { lineIndex += 1 }
                    let lineStart = starts[lineIndex]
                    let lineEnd = lineStart + segment.lines[lineIndex].utf16.count
                    let pieceEnd = min(end, lineEnd)
                    if pieceEnd > location {
                        map[segment.start + lineIndex, default: []].append(TokenRun(location: location - lineStart, length: pieceEnd - location, kind: run.kind))
                    }
                    location = max(pieceEnd + 1, location + 1)
                    if lineIndex + 1 >= starts.count { break }
                }
            }
        }
        return map
    }
}
