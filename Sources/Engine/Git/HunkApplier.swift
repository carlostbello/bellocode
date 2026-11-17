import Foundation

/// Why a hunk could not be applied to the current text.
public enum HunkApplyError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The lines the hunk expects are not in the file (it changed since the diff was computed).
    case stale(hunkHeader: String)
    /// The expected lines occur more than once at the same distance: applying could change the wrong lines.
    case ambiguous(hunkHeader: String)

    public var description: String {
        switch self {
        case .stale(let header): "The file changed since this diff was made (\(header))."
        case .ambiguous(let header): "The change matches more than one place in the file (\(header))."
        }
    }
}

/// Applies or reverts hunks against the file's current text, verified: a hunk applies only where its expected side
/// matches exactly (at the recorded line, or the nearest unique exact match within `maxOffset` lines, as `git apply`
/// does without fuzz). A stale or ambiguous hunk throws; it never patches other lines.
///
/// Pure and `Sendable`; callers read and write the file.
public enum HunkApplier {
    /// Text split into lines (terminators removed; a CR of CRLF stays on the line, so CRLF files compare as written by
    /// git) plus whether the last line ended with a newline.
    struct Lines {
        var lines: [String]
        var endsWithNewline: Bool

        init(_ text: String) {
            var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            endsWithNewline = text.hasSuffix("\n") || text.isEmpty
            if endsWithNewline, !parts.isEmpty { parts.removeLast() }
            lines = parts
        }

        var text: String {
            guard !lines.isEmpty else { return "" }
            return lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        }
    }

    /// Reverts `hunk` (a change old → new already present in `text`): the new side is replaced by the old side.
    public static func revert(_ hunk: PatchHunk, in text: String, maxOffset: Int = 300) throws -> String {
        try apply(hunk.inverted, to: text, maxOffset: maxOffset)
    }

    /// Reverts several hunks of one file (bottom to top, so earlier positions stay valid).
    public static func revert(_ hunks: [PatchHunk], in text: String, maxOffset: Int = 300) throws -> String {
        try apply(hunks.map(\.inverted), to: text, maxOffset: maxOffset)
    }

    /// Applies hunks (old → new) whose old side must be in `text`.
    public static func apply(_ hunks: [PatchHunk], to text: String, maxOffset: Int = 300) throws -> String {
        var document = Lines(text)
        // Locate every hunk against the original text first, so an earlier hunk cannot shift a later one's match.
        var placements: [(position: Int, hunk: PatchHunk)] = []
        for hunk in hunks { placements.append((try locate(hunk, in: document.lines, maxOffset: maxOffset), hunk)) }
        placements.sort { $0.position > $1.position }
        var lastStart = Int.max
        for (position, hunk) in placements {
            let oldCount = hunk.oldLines.count
            // Overlapping hunks cannot both apply.
            guard position + oldCount <= lastStart else { throw HunkApplyError.stale(hunkHeader: hunk.header) }
            replace(&document, at: position, hunk: hunk)
            lastStart = position
        }
        return document.text
    }

    /// Applies one hunk.
    public static func apply(_ hunk: PatchHunk, to text: String, maxOffset: Int = 300) throws -> String {
        try apply([hunk], to: text, maxOffset: maxOffset)
    }

    /// The 0-based line where `hunk`'s old side starts in `lines`.
    static func locate(_ hunk: PatchHunk, in lines: [String], maxOffset: Int) throws -> Int {
        let expected = hunk.oldLines
        // `@@ -n,0` inserts after line n; otherwise the old side starts at line n.
        let anchor = expected.isEmpty ? hunk.oldStart : max(0, hunk.oldStart - 1)
        if expected.isEmpty {
            // Nothing to verify: only the recorded position is accepted.
            guard anchor <= lines.count else { throw HunkApplyError.stale(hunkHeader: hunk.header) }
            return anchor
        }
        func matches(at position: Int) -> Bool {
            guard position >= 0, position + expected.count <= lines.count else { return false }
            for (offset, line) in expected.enumerated() where lines[position + offset] != line { return false }
            return true
        }
        if matches(at: anchor) { return anchor }
        for distance in 1...max(1, maxOffset) {
            let before = matches(at: anchor - distance)
            let after = matches(at: anchor + distance)
            if before, after { throw HunkApplyError.ambiguous(hunkHeader: hunk.header) }
            if before { return anchor - distance }
            if after { return anchor + distance }
            if anchor - distance < 0, anchor + distance + expected.count > lines.count { break }
        }
        throw HunkApplyError.stale(hunkHeader: hunk.header)
    }

    private static func replace(_ document: inout Lines, at position: Int, hunk: PatchHunk) {
        let oldCount = hunk.oldLines.count
        let replacement = hunk.newLines
        let touchesEnd = position + oldCount >= document.lines.count
        document.lines.replaceSubrange(position..<(position + oldCount), with: replacement)
        if touchesEnd {
            let lastNew = hunk.lines.last { $0.kind != .removed }
            if replacement.isEmpty {
                // The tail was removed: the line now last keeps its terminator.
                document.endsWithNewline = true
            } else if let lastNew {
                document.endsWithNewline = !lastNew.noNewlineAtEnd
            }
        }
    }
}
