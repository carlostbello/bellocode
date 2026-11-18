import CryptoKit
import Foundation

// Inline review of a merge request's diff (GitLab 2, docs/features/gitlab.md "Inline review"). Every value here is
// Sendable and built off the main actor. A discussion is shown at a line only when its position names exactly the
// diff version on screen (base, start and head SHA) and that line is in the shown diff; anything else is shown as
// outdated or at the file, never at a guessed line.

/// The three SHAs that identify one version of a merge request's diff (`diff_refs`, a version's `*_commit_sha`).
public struct DiffRefs: Hashable, Sendable, Codable, CustomStringConvertible {
    public var baseSHA: String
    public var startSHA: String
    public var headSHA: String

    public init(baseSHA: String, startSHA: String, headSHA: String) {
        self.baseSHA = baseSHA
        self.startSHA = startSHA
        self.headSHA = headSHA
    }

    public var description: String { "head \(headSHA.prefix(12))" }
    public var isComplete: Bool { !baseSHA.isEmpty && !startSHA.isEmpty && !headSHA.isEmpty }

    /// `{"base_sha":…}` / `{"base_commit_sha":…}`; nil when GitLab has not prepared the diff yet (empty refs).
    static func parse(_ raw: [String: Any]?, commitKeys: Bool = false) -> DiffRefs? {
        guard let raw else { return nil }
        let suffix = commitKeys ? "_commit_sha" : "_sha"
        let refs = DiffRefs(
            baseSHA: raw["base" + suffix] as? String ?? "", startSHA: raw["start" + suffix] as? String ?? "",
            headSHA: raw["head" + suffix] as? String ?? "")
        return refs.isComplete ? refs : nil
    }
}

/// One version of the MR's diff (`GET M/versions`).
public struct MergeRequestVersion: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var refs: DiffRefs
    public var created: Date?
    /// "collected", "overflow", "without_files", "empty" … as GitLab reports it.
    public var state: String?

    public init(id: Int, refs: DiffRefs, created: Date? = nil, state: String? = nil) {
        self.id = id
        self.refs = refs
        self.created = created
        self.state = state
    }
}

public enum ReviewSide: String, Hashable, Sendable, Codable { case old, new }

/// One end of a multi-line comment (`line_range.start` / `.end`), as GitLab wants it: the line code
/// (`sha1(path)_old_new` with GitLab's running counters), the side type (nil for an unchanged line) and the numbers.
public struct ReviewRangePoint: Hashable, Sendable, Codable {
    public var lineCode: String?
    /// "new", "old", or nil (unchanged line).
    public var type: String?
    public var oldLine: Int?
    public var newLine: Int?

    public init(lineCode: String? = nil, type: String? = nil, oldLine: Int? = nil, newLine: Int? = nil) {
        self.lineCode = lineCode
        self.type = type
        self.oldLine = oldLine
        self.newLine = newLine
    }

    static func parse(_ raw: [String: Any]?) -> ReviewRangePoint? {
        guard let raw else { return nil }
        return ReviewRangePoint(lineCode: raw["line_code"] as? String, type: raw["type"] as? String, oldLine: raw["old_line"] as? Int, newLine: raw["new_line"] as? Int)
    }

    var payload: JSONLike {
        var object: [String: JSONLike] = [:]
        if let lineCode { object["line_code"] = .string(lineCode) }
        if let type { object["type"] = .string(type) }
        if let oldLine { object["old_line"] = .int(oldLine) }
        if let newLine { object["new_line"] = .int(newLine) }
        return .object(object)
    }
}

/// A note's place in a diff (`position` of a diff note; the `position[...]` fields of a new thread).
public struct ReviewPosition: Hashable, Sendable, Codable {
    public var refs: DiffRefs
    public var oldPath: String
    public var newPath: String
    /// Set for removed and unchanged lines.
    public var oldLine: Int?
    /// Set for added and unchanged lines.
    public var newLine: Int?
    /// A multi-line comment (the anchor line is the range's end).
    public var rangeStart: ReviewRangePoint?
    public var rangeEnd: ReviewRangePoint?
    /// "text", "image" or "file".
    public var type: String

    public init(
        refs: DiffRefs, oldPath: String, newPath: String, oldLine: Int? = nil, newLine: Int? = nil, rangeStart: ReviewRangePoint? = nil,
        rangeEnd: ReviewRangePoint? = nil, type: String = "text"
    ) {
        self.refs = refs
        self.oldPath = oldPath
        self.newPath = newPath
        self.oldLine = oldLine
        self.newLine = newLine
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.type = type
    }

    /// The side and line GitLab shows the note at (the new side wins for unchanged lines).
    public var anchor: (side: ReviewSide, line: Int)? {
        if let newLine { return (.new, newLine) }
        if let oldLine { return (.old, oldLine) }
        return nil
    }

    /// The first line of a multi-line comment on the anchor's side (nil for one line).
    public var firstLine: Int? {
        guard let anchor, let start = rangeStart else { return nil }
        let value = anchor.side == .new ? (start.newLine ?? start.oldLine) : (start.oldLine ?? start.newLine)
        guard let value, value < anchor.line else { return nil }
        return value
    }

    public var path: String { newPath.isEmpty ? oldPath : newPath }

    /// "Sources/A.swift:12", "Sources/A.swift:10–14 (old)".
    public var label: String {
        guard let anchor else { return path }
        let lines = firstLine.map { "\($0)–\(anchor.line)" } ?? "\(anchor.line)"
        return "\(path):\(lines)" + (anchor.side == .old ? " (old)" : "")
    }

    /// Parses a note's `position` (nil for a general note or an unsupported shape).
    static func parse(_ raw: [String: Any]?) -> ReviewPosition? {
        guard let raw, let refs = DiffRefs.parse(raw) else { return nil }
        let range = raw["line_range"] as? [String: Any]
        return ReviewPosition(
            refs: refs, oldPath: raw["old_path"] as? String ?? "", newPath: raw["new_path"] as? String ?? "", oldLine: raw["old_line"] as? Int,
            newLine: raw["new_line"] as? Int, rangeStart: ReviewRangePoint.parse(range?["start"] as? [String: Any]),
            rangeEnd: ReviewRangePoint.parse(range?["end"] as? [String: Any]), type: raw["position_type"] as? String ?? "text")
    }

    /// The `position` object POSTed for a new thread or draft note (exactly what the card and preview show).
    public var payload: JSONLike {
        var object: [String: JSONLike] = [
            "position_type": .string(type), "base_sha": .string(refs.baseSHA), "start_sha": .string(refs.startSHA),
            "head_sha": .string(refs.headSHA), "old_path": .string(oldPath), "new_path": .string(newPath),
        ]
        if let oldLine { object["old_line"] = .int(oldLine) }
        if let newLine { object["new_line"] = .int(newLine) }
        if let rangeStart, let rangeEnd, firstLine != nil {
            object["line_range"] = .object(["start": rangeStart.payload, "end": rangeEnd.payload])
        }
        return .object(object)
    }
}

/// One note of a review discussion (bounded body; external, untrusted text).
public struct ReviewNote: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var author: String
    public var body: String
    public var bodyTruncated: Bool
    public var created: Date?
    public var system: Bool
    public var resolvable: Bool
    public var resolved: Bool

    public init(id: Int, author: String, body: String, created: Date? = nil, system: Bool = false, resolvable: Bool = false, resolved: Bool = false) {
        self.id = id
        self.author = author
        bodyTruncated = body.count > NoteDigest.bodyLimit
        self.body = String(body.prefix(NoteDigest.bodyLimit))
        self.created = created
        self.system = system
        self.resolvable = resolvable
        self.resolved = resolved
    }
}

/// A discussion with its diff position (nil: a general comment on the MR).
public struct ReviewDiscussion: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var notes: [ReviewNote]
    public var position: ReviewPosition?
    /// Where the thread was first written (GitLab moves `position` forward while the line still exists).
    public var originalPosition: ReviewPosition?

    public init(id: String, notes: [ReviewNote], position: ReviewPosition? = nil, originalPosition: ReviewPosition? = nil) {
        self.id = id
        self.notes = notes
        self.position = position
        self.originalPosition = originalPosition
    }

    public var visibleNotes: [ReviewNote] { notes.filter { !$0.system } }
    public var isSystem: Bool { notes.allSatisfy(\.system) }
    public var isResolvable: Bool { notes.contains { $0.resolvable } }
    public var isResolved: Bool { isResolvable && notes.filter(\.resolvable).allSatisfy(\.resolved) }
    public var author: String { visibleNotes.first?.author ?? notes.first?.author ?? "" }
    public var created: Date? { notes.first?.created }

    /// "Unresolved", "Resolved", "Comment" (status in words, never colour alone).
    public var stateWord: String { !isResolvable ? "Comment" : isResolved ? "Resolved" : "Unresolved" }
}

/// Where a discussion or draft is shown in the diff of one version.
public enum ReviewAnchor: Hashable, Sendable {
    /// At a line of the shown diff (`range`: a multi-line comment's first line, on the same side).
    case line(path: String, side: ReviewSide, line: Int, rangeStart: Int?)
    /// At the file: on this version, but its line is not in the shown diff (hidden context, cut file) or it is a
    /// file-level note. `reason` says which.
    case file(path: String, reason: String)
    /// Written on another version of the diff; shown as outdated with its original place.
    case outdated(ReviewPosition)
    /// A general comment (no position).
    case general

    public var path: String? {
        switch self {
        case .line(let path, _, _, _), .file(let path, _): path
        case .outdated(let position): position.path
        case .general: nil
        }
    }

    /// "Outdated: Sources/A.swift:12 on head 1a2b3c4d5e6f", "Line 120 is not in the shown diff".
    public var note: String? {
        switch self {
        case .line: nil
        case .file(_, let reason): reason
        case .outdated(let position): "Outdated: written on \(position.label) at head \(position.refs.headSHA.prefix(12))"
        case .general: nil
        }
    }
}

/// The lines one file shows on each side (from its hunks), for anchoring, line codes and re-anchoring.
public struct ReviewFileLines: Hashable, Sendable {
    /// One shown line: its kind and GitLab's running old/new counters (what a line code is made of).
    public struct Point: Hashable, Sendable {
        public var kind: PatchLine.Kind
        public var oldPos: Int
        public var newPos: Int
        public var text: String
    }

    public var oldPath: String
    public var newPath: String
    public var oldLines: Set<Int>
    public var newLines: Set<Int>
    /// Each shown line by (side, number).
    public var points: [ReviewLineKey: Point]
    /// The diff was cut or not returned (too large).
    public var incomplete: Bool

    public init(oldPath: String, newPath: String, hunks: [PatchHunk], incomplete: Bool = false) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.incomplete = incomplete
        var old = Set<Int>()
        var new = Set<Int>()
        var points: [ReviewLineKey: Point] = [:]
        for hunk in hunks {
            var o = hunk.oldCount == 0 ? hunk.oldStart + 1 : hunk.oldStart
            var n = hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart
            for line in hunk.lines {
                let point = Point(kind: line.kind, oldPos: o, newPos: n, text: line.text)
                switch line.kind {
                case .context:
                    old.insert(o)
                    new.insert(n)
                    points[ReviewLineKey(side: .new, line: n)] = point
                    points[ReviewLineKey(side: .old, line: o)] = point
                    o += 1
                    n += 1
                case .removed:
                    old.insert(o)
                    points[ReviewLineKey(side: .old, line: o)] = point
                    o += 1
                case .added:
                    new.insert(n)
                    points[ReviewLineKey(side: .new, line: n)] = point
                    n += 1
                }
            }
        }
        oldLines = old
        newLines = new
        self.points = points
    }

    public func text(side: ReviewSide, line: Int) -> String? { points[ReviewLineKey(side: side, line: line)]?.text }

    /// GitLab's line code: `sha1(new path)_old_new` with its running counters.
    public func lineCode(_ point: Point) -> String { SHA1Hex.of(newPath) + "_\(point.oldPos)_\(point.newPos)" }

    /// The position of a comment on lines `first...last` of one side, on version `refs` (nil when a line is not shown).
    /// An unchanged anchor line carries both numbers, as GitLab requires.
    public func position(refs: DiffRefs, side: ReviewSide, first: Int, last: Int) -> ReviewPosition? {
        guard let end = points[ReviewLineKey(side: side, line: last)] else { return nil }
        var position = ReviewPosition(refs: refs, oldPath: oldPath, newPath: newPath)
        switch end.kind {
        case .context:
            position.oldLine = end.oldPos
            position.newLine = end.newPos
        case .added: position.newLine = end.newPos
        case .removed: position.oldLine = end.oldPos
        }
        if first < last {
            let set = side == .new ? newLines : oldLines
            guard (first...last).allSatisfy(set.contains), let start = points[ReviewLineKey(side: side, line: first)] else { return nil }
            func point(_ p: Point) -> ReviewRangePoint {
                ReviewRangePoint(
                    lineCode: lineCode(p), type: p.kind == .added ? "new" : p.kind == .removed ? "old" : nil,
                    oldLine: p.kind == .added ? nil : p.oldPos, newLine: p.kind == .removed ? nil : p.newPos)
            }
            position.rangeStart = point(start)
            position.rangeEnd = point(end)
        }
        return position
    }
}

public struct ReviewLineKey: Hashable, Sendable, Codable {
    public var side: ReviewSide
    public var line: Int
    public init(side: ReviewSide, line: Int) {
        self.side = side
        self.line = line
    }
}

/// Pure anchoring rules (tested in `ReviewAnchoringTests`).
public enum ReviewAnchoring {
    /// Where a position is shown when `shown` is the version on screen and `files` its files.
    public static func anchor(_ position: ReviewPosition?, shown: DiffRefs, files: [ReviewFileLines]) -> ReviewAnchor {
        guard let position else { return .general }
        guard position.refs == shown else { return .outdated(position) }
        // Renamed files carry both paths; match the pair first, then either side.
        let file =
            files.first { $0.newPath == position.newPath && $0.oldPath == position.oldPath }
            ?? files.first { !position.newPath.isEmpty && $0.newPath == position.newPath }
            ?? files.first { !position.oldPath.isEmpty && $0.oldPath == position.oldPath }
        guard let file else { return .file(path: position.path, reason: "This file is not in the loaded diff (it may be cut or too large).") }
        guard position.type == "text", let anchor = position.anchor else {
            return .file(path: file.newPath, reason: position.type == "image" ? "Comment on the image" : "Comment on the file")
        }
        let present = anchor.side == .new ? file.newLines.contains(anchor.line) : file.oldLines.contains(anchor.line)
        guard present else {
            let side = anchor.side == .old ? "old " : ""
            return .file(path: file.newPath, reason: "On \(side)line \(anchor.line), which is not in the shown diff\(file.incomplete ? " (the file's diff is cut)" : " context").")
        }
        return .line(path: file.newPath, side: anchor.side, line: anchor.line, rangeStart: position.firstLine)
    }
}

/// One file of a version's diff, bounded.
public struct ReviewDiffFile: Hashable, Sendable {
    public var oldPath: String
    public var newPath: String
    public var newFile: Bool
    public var deletedFile: Bool
    public var renamedFile: Bool
    /// GitLab's hunks for the file (no `diff --git` header), possibly cut at the bound.
    public var diff: String
    public var truncated: Bool
    /// Collapsed or too large on GitLab: the content was not returned.
    public var tooLarge: Bool

    public init(oldPath: String, newPath: String, newFile: Bool = false, deletedFile: Bool = false, renamedFile: Bool = false, diff: String, truncated: Bool = false, tooLarge: Bool = false) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.newFile = newFile
        self.deletedFile = deletedFile
        self.renamedFile = renamedFile
        self.diff = diff
        self.truncated = truncated
        self.tooLarge = tooLarge
    }

    /// The hunks, parsed (a cut diff keeps its complete hunks).
    public var patch: PatchFile {
        let header = "diff --git a/\(oldPath) b/\(newPath)\n--- \(newFile ? "/dev/null" : "a/" + oldPath)\n+++ \(deletedFile ? "/dev/null" : "b/" + newPath)\n"
        var file = UnifiedPatchParser.parse(header + diff).first ?? PatchFile(oldPath: oldPath, newPath: newPath)
        if renamedFile { file.status = .renamed }
        if file.oldPath == nil, !newFile { file.oldPath = oldPath }
        if file.newPath == nil, !deletedFile { file.newPath = newPath }
        if renamedFile { file.oldPath = oldPath; file.newPath = newPath }
        return file
    }

    public var lines: ReviewFileLines {
        ReviewFileLines(oldPath: oldPath, newPath: newPath, hunks: patch.hunks, incomplete: truncated || tooLarge)
    }
}

/// A version of the diff with its files (`GET M/versions/:id`).
public struct ReviewDiffVersion: Hashable, Sendable {
    public var version: MergeRequestVersion
    public var files: [ReviewDiffFile]
    /// More files or bytes than BelloCode loads (the list says so; a missing file's notes show at the file).
    public var incomplete: Bool
    /// Versions GitLab reported (newest first), for "version 3 of 3".
    public var count: Int

    public init(version: MergeRequestVersion, files: [ReviewDiffFile], incomplete: Bool = false, count: Int = 1) {
        self.version = version
        self.files = files
        self.incomplete = incomplete
        self.count = count
    }

    public var fileLines: [ReviewFileLines] { files.map(\.lines) }
}

// MARK: - Local drafts

/// A review comment composed in BelloCode and not sent yet (persisted in `app_review_draft`, migration
/// `v10-gitlab-review`). Sent only by an explicit action: as GitLab draft notes published together when the instance
/// offers them, otherwise as single notes.
public struct ReviewDraft: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: Hashable, Sendable, Codable {
        /// A new thread at a position (`lineText`: the anchored line's text, to re-anchor after the MR moved).
        case newThread(ReviewPosition, lineText: String?)
        /// A reply in an existing discussion.
        case reply(discussionID: String)
        /// A general comment on the MR.
        case general
    }

    public var id: String
    public var mrURL: String
    public var kind: Kind
    public var body: String
    /// Reply drafts: resolve (true) or reopen (false) the thread when sent.
    public var resolve: Bool?
    /// The head SHA of the version the person wrote it against.
    public var headSHA: String
    public var created: Date
    /// Written by an agent's `gitlab_create_draft_comment` (shown with its thread).
    public var byAgent: Bool

    public init(id: String = ReviewDraft.makeID(), mrURL: String, kind: Kind, body: String, resolve: Bool? = nil, headSHA: String, created: Date = Date(), byAgent: Bool = false) {
        self.id = id
        self.mrURL = mrURL
        self.kind = kind
        self.body = body
        self.resolve = resolve
        self.headSHA = headSHA
        self.created = created
        self.byAgent = byAgent
    }

    public static func makeID() -> String {
        "rd_" + String(UInt64.random(in: 0...UInt64.max), radix: 36) + String(UInt32.random(in: 0...UInt32.max), radix: 36)
    }

    public var position: ReviewPosition? { if case .newThread(let position, _) = kind { position } else { nil } }
    public var discussionID: String? { if case .reply(let id) = kind { id } else { nil } }

    /// Moves a new-thread draft to `version` when the MR moved: kept only if the same line (path, side, number) shows
    /// the same text in the new version; otherwise nil (the draft stays on its old version, marked outdated, and is
    /// not sent). Replies and general comments follow the new head unchanged.
    public func reanchored(to version: ReviewDiffVersion) -> ReviewDraft? {
        var copy = self
        copy.headSHA = version.version.refs.headSHA
        guard case .newThread(let position, let text) = kind else { return copy }
        if position.refs == version.version.refs { return copy }
        guard let anchor = position.anchor, let text,
            let file = version.files.first(where: { $0.newPath == position.newPath && $0.oldPath == position.oldPath })
        else { return nil }
        let lines = file.lines
        guard lines.text(side: anchor.side, line: anchor.line) == text,
            let moved = lines.position(refs: version.version.refs, side: anchor.side, first: position.firstLine ?? anchor.line, last: anchor.line)
        else { return nil }
        copy.kind = .newThread(moved, lineText: text)
        return copy
    }
}

/// A draft note already on GitLab (`GET M/draft_notes`): the person's own pending comments, visible only to them.
public struct ServerDraftNote: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var body: String
    public var discussionID: String?
    public var position: ReviewPosition?

    public init(id: Int, body: String, discussionID: String? = nil, position: ReviewPosition? = nil) {
        self.id = id
        self.body = String(body.prefix(NoteDigest.bodyLimit))
        self.discussionID = discussionID
        self.position = position
    }
}

/// A review's state on screen: the version shown, its anchored discussions and the person's drafts.
public struct ReviewState: Sendable {
    public var ref: MergeRequestRef
    public var diff: ReviewDiffVersion
    public var discussions: [ReviewDiscussion]
    /// Discussions were cut at the paging bound.
    public var discussionsIncomplete: Bool
    public var serverDrafts: [ServerDraftNote]?
    public var loaded: Date

    public init(ref: MergeRequestRef, diff: ReviewDiffVersion, discussions: [ReviewDiscussion], discussionsIncomplete: Bool = false, serverDrafts: [ServerDraftNote]? = nil, loaded: Date) {
        self.ref = ref
        self.diff = diff
        self.discussions = discussions
        self.discussionsIncomplete = discussionsIncomplete
        self.serverDrafts = serverDrafts
        self.loaded = loaded
    }

    public var refs: DiffRefs { diff.version.refs }

    /// Each non-system discussion with its anchor on the shown version.
    public var anchored: [(discussion: ReviewDiscussion, anchor: ReviewAnchor)] {
        let lines = diff.fileLines
        return discussions.filter { !$0.isSystem }.map { ($0, ReviewAnchoring.anchor($0.position, shown: refs, files: lines)) }
    }
}

/// Why an action was not sent because the MR moved since the version on screen.
public struct ReviewMovedError: Error, Hashable, Sendable, CustomStringConvertible {
    public var shown: DiffRefs
    public var latest: DiffRefs

    public init(shown: DiffRefs, latest: DiffRefs) {
        self.shown = shown
        self.latest = latest
    }

    public var description: String {
        "The merge request changed since this diff was loaded (head \(shown.headSHA.prefix(12)) → \(latest.headSHA.prefix(12))). Nothing was sent. Refresh to review the new version; your drafts are kept."
    }
}

/// GitLab's line codes hash the file path with SHA-1 (an identifier, not a security use).
enum SHA1Hex {
    static func of(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
