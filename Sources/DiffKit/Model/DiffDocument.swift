import Engine
import Foundation

/// One file's diff, ready for display: hunks, plus both full texts when known (context expansion, local re-diff).
public struct DiffFile: Sendable, Hashable, Identifiable {
    public enum Content: Sendable, Hashable {
        case text
        /// Binary content: a placeholder, no lines.
        case binary
        /// An image (by extension): a placeholder naming the format.
        case image
    }

    /// Stable identity: the (new) path.
    public var id: String { path }
    public var path: String
    public var oldPath: String?
    public var status: PatchFile.Status
    public var content: Content
    public var hunks: [PatchHunk]
    public var oldLines: [Substring]?
    public var newLines: [Substring]?
    /// Too large for syntax and word highlights (plain mode).
    public var isLarge: Bool
    public var additions: Int
    public var deletions: Int

    /// Diffs above this many lines (old + new, or hunk lines) are shown in plain mode.
    public static let largeLineCount = 60_000
    /// Texts above this many lines are not diffed locally (the patch is used as given).
    public static let maxLocalDiffLines = 400_000

    public init(
        path: String, oldPath: String? = nil, status: PatchFile.Status, content: Content = .text, hunks: [PatchHunk],
        oldLines: [Substring]? = nil, newLines: [Substring]? = nil
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.content = content
        self.hunks = hunks
        self.oldLines = oldLines
        self.newLines = newLines
        additions = hunks.reduce(0) { $0 + $1.additions }
        deletions = hunks.reduce(0) { $0 + $1.deletions }
        let size = max((oldLines?.count ?? 0) + (newLines?.count ?? 0), hunks.reduce(0) { $0 + $1.lines.count })
        isLarge = size > Self.largeLineCount
    }

    public var canExpandContext: Bool { content == .text && oldLines != nil && newLines != nil }
    public var language: String? { DiffSyntax.language(forPath: path) }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "ico", "icns", "pdf", "svg"]

    /// From a parsed patch; `old`/`new` are the full texts when known.
    public static func from(_ patch: PatchFile, old: String? = nil, new: String? = nil) -> DiffFile {
        let ext = (patch.path as NSString).pathExtension.lowercased()
        let content: Content = imageExtensions.contains(ext) && (patch.isBinary || ext != "svg") ? .image : patch.isBinary ? .binary : .text
        return DiffFile(
            path: patch.path, oldPath: patch.oldPath != patch.newPath ? patch.oldPath : nil, status: patch.status, content: content,
            hunks: content == .text ? patch.hunks : [], oldLines: old.map(LineDiff.lines), newLines: new.map(LineDiff.lines))
    }

    /// Diffs two texts locally (nil: the file is absent on that side). Above `maxLocalDiffLines` no diff is computed and
    /// the file is shown as wholly replaced in plain mode.
    public static func compute(
        path: String, old: String?, new: String?, context: Int = 3, ignoreWhitespace: Bool = false
    ) -> DiffFile {
        let oldLines = old.map(LineDiff.lines) ?? []
        let newLines = new.map(LineDiff.lines) ?? []
        let status: PatchFile.Status = old == nil ? .added : new == nil ? .deleted : .modified
        let hunks: [PatchHunk]
        if oldLines.count + newLines.count > maxLocalDiffLines {
            hunks = [
                PatchHunk(
                    oldStart: oldLines.isEmpty ? 0 : 1, oldCount: oldLines.count, newStart: newLines.isEmpty ? 0 : 1, newCount: newLines.count,
                    lines: oldLines.map { PatchLine(.removed, String($0)) } + newLines.map { PatchLine(.added, String($0)) })
            ]
        } else {
            hunks = LineDiff.hunks(old: oldLines, new: newLines, context: context, ignoreWhitespace: ignoreWhitespace)
        }
        return DiffFile(path: path, status: status, hunks: hunks, oldLines: old == nil ? [] : oldLines, newLines: new == nil ? [] : newLines)
    }

    /// The same file re-diffed with whitespace ignored (or not), when both texts are known; otherwise unchanged.
    public func rediffed(ignoreWhitespace: Bool, context: Int = 3) -> DiffFile {
        guard let oldLines, let newLines, content == .text, oldLines.count + newLines.count <= Self.maxLocalDiffLines else { return self }
        var copy = self
        copy.hunks = LineDiff.hunks(old: oldLines, new: newLines, context: context, ignoreWhitespace: ignoreWhitespace)
        copy.additions = copy.hunks.reduce(0) { $0 + $1.additions }
        copy.deletions = copy.hunks.reduce(0) { $0 + $1.deletions }
        return copy
    }
}

/// How rows are laid out.
public enum DiffLayout: String, Sendable, Hashable, Codable, CaseIterable {
    case unified, split
}

/// A side of a split diff (unified rows use `.old` for removed lines and `.new` for added and context lines).
public enum DiffSide: Sendable, Hashable { case old, new }

/// One cell: a line on one side.
public struct DiffCell: Sendable, Hashable {
    public var kind: PatchLine.Kind
    /// 1-based line number on `side`.
    public var number: Int
    public var side: DiffSide
    public var text: String
    /// Unified context rows show both numbers.
    public var otherNumber: Int?
    public var noNewlineAtEnd: Bool
}

/// Stable row identity within a document: file ordinal, hunk, line, and a kind tag.
public struct DiffRowID: Sendable, Hashable, Comparable {
    public var file: Int32
    public var hunk: Int32
    public var line: Int32
    public var tag: UInt8

    public static func < (a: Self, b: Self) -> Bool { (a.file, a.hunk, a.line, a.tag) < (b.file, b.hunk, b.line, b.tag) }
}

/// A row of the diff view.
public struct DiffRow: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A file's header (path, status, counts); toggles collapse.
        case fileHeader
        /// `@@ … @@ section`.
        case hunkHeader
        /// Lines (one cell in unified; left/right in split, either may be empty).
        case line
        /// Hidden unchanged lines between hunks (expandable when the file's texts are known).
        case gap(hidden: Int, expandable: Bool)
        /// A placeholder (binary, image, empty, large-file notice).
        case notice
    }

    public var id: DiffRowID
    public var kind: Kind
    public var fileIndex: Int
    /// Hunk index within the file (-1 for file-level rows).
    public var hunkIndex: Int
    public var left: DiffCell?
    public var right: DiffCell?
    /// Header, gap and notice text.
    public var text: String
    /// Index into `DiffRows.pairs` for a changed pair (word highlights), if any.
    public var pairIndex: Int?

    /// The cell of a unified row.
    public var cell: DiffCell? { left ?? right }
}

/// A removed/added line pair eligible for word highlights.
public struct DiffPair: Sendable, Hashable {
    public var removed: String
    public var added: String
}

/// Expanded context of one gap: lines revealed below the previous hunk (`top`) and above the next (`bottom`).
public struct GapExpansion: Sendable, Hashable, Codable {
    public var top: Int
    public var bottom: Int
    public init(top: Int = 0, bottom: Int = 0) {
        self.top = top
        self.bottom = bottom
    }
}

/// Key of a gap: the file and the hunk it precedes (`hunks.count` for the tail).
public struct GapKey: Sendable, Hashable, Codable {
    public var path: String
    public var beforeHunk: Int
    public init(path: String, beforeHunk: Int) {
        self.path = path
        self.beforeHunk = beforeHunk
    }
}

/// The rows of a document for one layout. Immutable and `Sendable`: built off the main actor.
public struct DiffRows: Sendable {
    public var rows: [DiffRow]
    public var pairs: [DiffPair]
    /// Longest line (in columns, tabs at 4) per layout column: unified uses `left`.
    public var maxColumnsLeft: Int
    public var maxColumnsRight: Int
    /// Index of each file's header row.
    public var fileHeaderRows: [Int]
    /// Index of each hunk header row.
    public var hunkHeaderRows: [Int]
    /// Largest line number (gutter width).
    public var maxLineNumber: Int

    public static let empty = DiffRows(rows: [], pairs: [], maxColumnsLeft: 0, maxColumnsRight: 0, fileHeaderRows: [], hunkHeaderRows: [], maxLineNumber: 0)
}

/// Options that change the rows.
public struct DiffRowOptions: Sendable, Hashable {
    public var layout: DiffLayout = .unified
    public var collapsedFiles: Set<String> = []
    public var expansions: [GapKey: GapExpansion] = [:]
    /// Show file header rows (off for a single-file view).
    public var showsFileHeaders = true
    public init() {}
}

/// Builds rows. Pure; call it off the main actor.
public enum DiffRowBuilder {
    public static func columns(_ text: some StringProtocol) -> Int {
        var count = 0
        for unit in text.utf16 {
            if unit == 9 { count += 4 - count % 4 } else if unit & 0xFC00 != 0xDC00 { count += 1 }
        }
        return count
    }

    public static func build(_ files: [DiffFile], options: DiffRowOptions) -> DiffRows {
        var result = DiffRows.empty
        var maxLeft = 0
        var maxRight = 0
        var maxNumber = 0
        for (fileIndex, file) in files.enumerated() {
            let f = Int32(fileIndex)
            if options.showsFileHeaders {
                result.fileHeaderRows.append(result.rows.count)
                result.rows.append(DiffRow(id: DiffRowID(file: f, hunk: -1, line: -1, tag: 0), kind: .fileHeader, fileIndex: fileIndex, hunkIndex: -1, text: file.path))
            } else {
                result.fileHeaderRows.append(result.rows.count)
            }
            if options.collapsedFiles.contains(file.path) { continue }
            func notice(_ text: String, tag: UInt8) {
                result.rows.append(DiffRow(id: DiffRowID(file: f, hunk: -1, line: -1, tag: tag), kind: .notice, fileIndex: fileIndex, hunkIndex: -1, text: text))
            }
            switch file.content {
            case .binary:
                notice("Binary file not shown", tag: 1)
                continue
            case .image:
                notice("Image \(file.status == .added ? "added" : file.status == .deleted ? "deleted" : "changed") (\((file.path as NSString).pathExtension.uppercased())). Open it to view.", tag: 1)
                continue
            case .text:
                break
            }
            if file.hunks.isEmpty {
                notice(file.status == .renamed ? "Renamed without changes" : "No changes to show", tag: 1)
                continue
            }
            if file.isLarge { notice("Large diff: syntax and word highlights are off.", tag: 2) }
            var previousOldEnd = 0
            var previousNewEnd = 0
            for (hunkIndex, hunk) in file.hunks.enumerated() {
                let h = Int32(hunkIndex)
                let oldFirst = hunk.oldCount == 0 ? hunk.oldStart + 1 : hunk.oldStart
                let newFirst = hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart
                appendGap(
                    &result, file: file, fileIndex: fileIndex, beforeHunk: hunkIndex, oldFrom: previousOldEnd + 1, oldTo: oldFirst - 1,
                    newFrom: previousNewEnd + 1, options: options, maxLeft: &maxLeft, maxRight: &maxRight)
                result.hunkHeaderRows.append(result.rows.count)
                result.rows.append(
                    DiffRow(id: DiffRowID(file: f, hunk: h, line: -1, tag: 0), kind: .hunkHeader, fileIndex: fileIndex, hunkIndex: hunkIndex, text: hunk.header))
                var oldNumber = oldFirst
                var newNumber = newFirst
                var index = 0
                let lines = hunk.lines
                while index < lines.count {
                    let line = lines[index]
                    if line.kind == .context {
                        let left = DiffCell(kind: .context, number: oldNumber, side: .old, text: line.text, otherNumber: newNumber, noNewlineAtEnd: line.noNewlineAtEnd)
                        let right = DiffCell(kind: .context, number: newNumber, side: .new, text: line.text, otherNumber: nil, noNewlineAtEnd: line.noNewlineAtEnd)
                        let width = columns(line.text)
                        maxLeft = max(maxLeft, width)
                        maxRight = max(maxRight, width)
                        result.rows.append(
                            DiffRow(
                                id: DiffRowID(file: f, hunk: h, line: Int32(index), tag: 0), kind: .line, fileIndex: fileIndex, hunkIndex: hunkIndex,
                                left: options.layout == .split ? left : DiffCell(kind: .context, number: newNumber, side: .new, text: line.text, otherNumber: oldNumber, noNewlineAtEnd: line.noNewlineAtEnd),
                                right: options.layout == .split ? right : nil, text: ""))
                        oldNumber += 1
                        newNumber += 1
                        index += 1
                        continue
                    }
                    // A change block: removed lines then added lines (either may be empty).
                    var removed: [(Int, PatchLine)] = []
                    var added: [(Int, PatchLine)] = []
                    while index < lines.count, lines[index].kind == .removed {
                        removed.append((index, lines[index]))
                        index += 1
                    }
                    while index < lines.count, lines[index].kind == .added {
                        added.append((index, lines[index]))
                        index += 1
                    }
                    let pairCount = file.isLarge ? 0 : min(removed.count, added.count)
                    let pairBase = result.pairs.count
                    for p in 0..<pairCount { result.pairs.append(DiffPair(removed: removed[p].1.text, added: added[p].1.text)) }
                    let removedCells = removed.enumerated().map { offset, item in
                        DiffCell(kind: .removed, number: oldNumber + offset, side: .old, text: item.1.text, otherNumber: nil, noNewlineAtEnd: item.1.noNewlineAtEnd)
                    }
                    let addedCells = added.enumerated().map { offset, item in
                        DiffCell(kind: .added, number: newNumber + offset, side: .new, text: item.1.text, otherNumber: nil, noNewlineAtEnd: item.1.noNewlineAtEnd)
                    }
                    for cell in removedCells { maxLeft = max(maxLeft, columns(cell.text)) }
                    for cell in addedCells {
                        let width = columns(cell.text)
                        if options.layout == .split { maxRight = max(maxRight, width) } else { maxLeft = max(maxLeft, width) }
                    }
                    if options.layout == .split {
                        for row in 0..<max(removed.count, added.count) {
                            let lineIndex = row < removed.count ? removed[row].0 : added[row].0
                            result.rows.append(
                                DiffRow(
                                    id: DiffRowID(file: f, hunk: h, line: Int32(lineIndex), tag: 0), kind: .line, fileIndex: fileIndex,
                                    hunkIndex: hunkIndex, left: row < removedCells.count ? removedCells[row] : nil,
                                    right: row < addedCells.count ? addedCells[row] : nil, text: "", pairIndex: row < pairCount ? pairBase + row : nil))
                        }
                    } else {
                        for (offset, cell) in removedCells.enumerated() {
                            result.rows.append(
                                DiffRow(
                                    id: DiffRowID(file: f, hunk: h, line: Int32(removed[offset].0), tag: 0), kind: .line, fileIndex: fileIndex,
                                    hunkIndex: hunkIndex, left: cell, right: nil, text: "", pairIndex: offset < pairCount ? pairBase + offset : nil))
                        }
                        for (offset, cell) in addedCells.enumerated() {
                            result.rows.append(
                                DiffRow(
                                    id: DiffRowID(file: f, hunk: h, line: Int32(added[offset].0), tag: 0), kind: .line, fileIndex: fileIndex,
                                    hunkIndex: hunkIndex, left: cell, right: nil, text: "", pairIndex: offset < pairCount ? pairBase + offset : nil))
                        }
                    }
                    oldNumber += removed.count
                    newNumber += added.count
                }
                previousOldEnd = oldNumber - 1
                previousNewEnd = newNumber - 1
                maxNumber = max(maxNumber, oldNumber, newNumber)
            }
            // The tail after the last hunk.
            if let oldLines = file.oldLines, file.canExpandContext {
                appendGap(
                    &result, file: file, fileIndex: fileIndex, beforeHunk: file.hunks.count, oldFrom: previousOldEnd + 1, oldTo: oldLines.count,
                    newFrom: previousNewEnd + 1, options: options, maxLeft: &maxLeft, maxRight: &maxRight)
            }
        }
        result.maxColumnsLeft = maxLeft
        result.maxColumnsRight = options.layout == .split ? maxRight : maxLeft
        result.maxLineNumber = maxNumber
        return result
    }

    /// Hidden unchanged lines `oldFrom...oldTo` (new numbering starts at `newFrom`): revealed lines per the expansion,
    /// then a gap row for the rest.
    private static func appendGap(
        _ result: inout DiffRows, file: DiffFile, fileIndex: Int, beforeHunk: Int, oldFrom: Int, oldTo: Int, newFrom: Int,
        options: DiffRowOptions, maxLeft: inout Int, maxRight: inout Int
    ) {
        let hidden = oldTo - oldFrom + 1
        guard hidden > 0 else { return }
        let f = Int32(fileIndex)
        let h = Int32(beforeHunk)
        guard file.canExpandContext, let oldLines = file.oldLines else {
            result.rows.append(
                DiffRow(id: DiffRowID(file: f, hunk: h, line: -2, tag: 1), kind: .gap(hidden: hidden, expandable: false), fileIndex: fileIndex, hunkIndex: beforeHunk, text: ""))
            return
        }
        let expansion = options.expansions[GapKey(path: file.path, beforeHunk: beforeHunk)] ?? GapExpansion()
        let top = beforeHunk == 0 ? 0 : min(expansion.top, hidden)
        let bottom = min(expansion.bottom, hidden - top)
        func reveal(_ offset: Int) {
            let oldNumber = oldFrom + offset
            let newNumber = newFrom + offset
            guard oldNumber - 1 < oldLines.count else { return }
            let text = String(oldLines[oldNumber - 1])
            let width = columns(text)
            maxLeft = max(maxLeft, width)
            maxRight = max(maxRight, width)
            let id = DiffRowID(file: f, hunk: h, line: Int32(-1_000_000 + offset), tag: 2)
            if options.layout == .split {
                result.rows.append(
                    DiffRow(
                        id: id, kind: .line, fileIndex: fileIndex, hunkIndex: beforeHunk,
                        left: DiffCell(kind: .context, number: oldNumber, side: .old, text: text, otherNumber: newNumber, noNewlineAtEnd: false),
                        right: DiffCell(kind: .context, number: newNumber, side: .new, text: text, otherNumber: nil, noNewlineAtEnd: false), text: ""))
            } else {
                result.rows.append(
                    DiffRow(
                        id: id, kind: .line, fileIndex: fileIndex, hunkIndex: beforeHunk,
                        left: DiffCell(kind: .context, number: newNumber, side: .new, text: text, otherNumber: oldNumber, noNewlineAtEnd: false), right: nil, text: ""))
            }
        }
        for offset in 0..<top { reveal(offset) }
        let remaining = hidden - top - bottom
        if remaining > 0 {
            result.rows.append(
                DiffRow(
                    id: DiffRowID(file: f, hunk: h, line: -2, tag: 1), kind: .gap(hidden: remaining, expandable: true), fileIndex: fileIndex,
                    hunkIndex: beforeHunk, text: ""))
        }
        for offset in (hidden - bottom)..<hidden { reveal(offset) }
    }
}
