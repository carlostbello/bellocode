import Foundation

/// What happened to a file on one side (index or working tree).
public enum GitChangeKind: String, Sendable, Hashable, Codable {
    case added, modified, deleted, renamed, copied, typeChanged, unmerged, untracked

    /// One-letter status, as in `git status --short` (shown with the word, never alone).
    public var letter: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .unmerged: "U"
        case .untracked: "?"
        }
    }

    public var label: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        case .unmerged: "Conflict"
        case .untracked: "Untracked"
        }
    }

    init?(porcelain code: Character) {
        switch code {
        case "A": self = .added
        case "M": self = .modified
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .unmerged
        default: return nil
        }
    }
}

/// Added and deleted line counts (nil counts: binary).
public struct LineStats: Sendable, Hashable, Codable {
    public var additions: Int
    public var deletions: Int
    public var isBinary: Bool

    public init(additions: Int, deletions: Int, isBinary: Bool = false) {
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
    }

    public static let zero = LineStats(additions: 0, deletions: 0)
}

/// One path in `git status`: its staged (index) and unstaged (working tree) change, which are separate scopes.
public struct GitFileChange: Sendable, Hashable, Identifiable {
    /// Repository-relative path (the new path of a rename).
    public var path: String
    /// The old path of a rename or copy.
    public var originalPath: String?
    public var staged: GitChangeKind?
    public var unstaged: GitChangeKind?
    public var stagedStats: LineStats?
    public var unstagedStats: LineStats?

    public var id: String { path }
    public var isUntracked: Bool { unstaged == .untracked }
    public var isConflicted: Bool { staged == .unmerged || unstaged == .unmerged }

    public init(
        path: String, originalPath: String? = nil, staged: GitChangeKind? = nil, unstaged: GitChangeKind? = nil,
        stagedStats: LineStats? = nil, unstagedStats: LineStats? = nil
    ) {
        self.path = path
        self.originalPath = originalPath
        self.staged = staged
        self.unstaged = unstaged
        self.stagedStats = stagedStats
        self.unstagedStats = unstagedStats
    }

    /// Both sides' counts together.
    public var totalStats: LineStats {
        let parts = [stagedStats, unstagedStats].compactMap { $0 }
        return LineStats(
            additions: parts.reduce(0) { $0 + $1.additions }, deletions: parts.reduce(0) { $0 + $1.deletions },
            isBinary: parts.contains { $0.isBinary })
    }
}

/// A multi-step git operation that stopped (usually on conflicts) and waits for the person.
public enum GitOperation: String, Sendable, Hashable, Codable {
    case merge, rebase, cherryPick, revert

    public var label: String {
        switch self {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        }
    }

    /// The git subcommand that continues or aborts it.
    public var command: String {
        switch self {
        case .merge: "merge"
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        }
    }

    /// Reads the marker files of `gitDirectory` (no git process).
    public static func read(gitDirectory: String) -> GitOperation? {
        let manager = FileManager.default
        func exists(_ name: String) -> Bool { manager.fileExists(atPath: (gitDirectory as NSString).appendingPathComponent(name)) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return nil
    }
}

/// A repository's state: branch, upstream, ahead/behind and changed files.
public struct GitStatus: Sendable, Hashable {
    /// The branch name; nil for a detached HEAD.
    public var branch: String?
    /// The HEAD commit; nil before the first commit.
    public var head: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var files: [GitFileChange]
    /// More files changed than `files` holds (the list was capped).
    public var truncated: Bool
    /// A merge, rebase, cherry-pick or revert stopped half way (read from the git directory); nil otherwise.
    public var operation: GitOperation?

    public init(
        branch: String? = nil, head: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0,
        files: [GitFileChange] = [], truncated: Bool = false
    ) {
        self.branch = branch
        self.head = head
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.files = files
        self.truncated = truncated
    }

    public var isDirty: Bool { !files.isEmpty }
    public var stagedFiles: [GitFileChange] { files.filter { $0.staged != nil } }
    public var unstagedFiles: [GitFileChange] { files.filter { $0.unstaged != nil } }
    public var isDetached: Bool { branch == nil && head != nil }
    public var conflictedFiles: [GitFileChange] { files.filter(\.isConflicted) }
    public var hasConflicts: Bool { operation != nil || files.contains(where: \.isConflicted) }

    /// "3 changed · ↑2 ↓1" style summary (words for VoiceOver come from `accessibleSummary`).
    public var summary: String {
        var parts: [String] = []
        parts.append(files.isEmpty ? "Clean" : "\(files.count) changed")
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        return parts.joined(separator: " · ")
    }

    public var accessibleSummary: String {
        var parts: [String] = [files.isEmpty ? "no uncommitted changes" : "\(files.count) uncommitted file\(files.count == 1 ? "" : "s")"]
        if ahead > 0 { parts.append("\(ahead) commit\(ahead == 1 ? "" : "s") ahead of \(upstream ?? "upstream")") }
        if behind > 0 { parts.append("\(behind) behind") }
        if upstream == nil, branch != nil { parts.append("not published") }
        return parts.joined(separator: ", ")
    }
}

/// Parses `git status --porcelain=v2 --branch -z` and `git diff --numstat -z`.
public enum GitStatusParser {
    /// Parses porcelain v2 output. At most `limit` files are kept (`truncated` set beyond).
    public static func parse(_ data: Data, limit: Int = 10_000) -> GitStatus {
        var status = GitStatus()
        let fields = split(data)
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard let first = field.first else { continue }
            switch first {
            case "#":
                parseHeader(field, into: &status)
            case "1", "2":
                // "1 XY sub mH mI mW hH hI path" / "2 XY sub mH mI mW hH hI Xscore path" + NUL + origPath
                let isRename = first == "2"
                let parts = field.split(separator: " ", maxSplits: isRename ? 9 : 8, omittingEmptySubsequences: false)
                guard parts.count >= (isRename ? 10 : 9) else { continue }
                let xy = Array(parts[1])
                var change = GitFileChange(path: String(parts[isRename ? 9 : 8]))
                if xy.count == 2 {
                    change.staged = GitChangeKind(porcelain: xy[0])
                    change.unstaged = GitChangeKind(porcelain: xy[1])
                }
                if isRename, index < fields.count {
                    change.originalPath = fields[index]
                    index += 1
                }
                append(change, to: &status, limit: limit)
            case "u":
                let parts = field.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count >= 11 else { continue }
                append(GitFileChange(path: String(parts[10]), staged: .unmerged, unstaged: .unmerged), to: &status, limit: limit)
            case "?":
                append(GitFileChange(path: String(field.dropFirst(2)), unstaged: .untracked), to: &status, limit: limit)
            default:
                continue
            }
        }
        return status
    }

    private static func append(_ change: GitFileChange, to status: inout GitStatus, limit: Int) {
        if status.files.count < limit { status.files.append(change) } else { status.truncated = true }
    }

    private static func parseHeader(_ field: String, into status: inout GitStatus) {
        let parts = field.split(separator: " ", maxSplits: 2)
        guard parts.count >= 3 else { return }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.oid": status.head = value == "(initial)" ? nil : value
        case "branch.head": status.branch = value == "(detached)" ? nil : value
        case "branch.upstream": status.upstream = value
        case "branch.ab":
            for token in value.split(separator: " ") {
                if token.hasPrefix("+") { status.ahead = Int(token.dropFirst()) ?? 0 }
                if token.hasPrefix("-") { status.behind = Int(token.dropFirst()) ?? 0 }
            }
        default: break
        }
    }

    /// Parses `git diff --numstat -z`: `add\tdel\tpath\0`, or `add\tdel\t\0old\0new\0` for a rename. Binary files
    /// report `-` counts. Keyed by the (new) path.
    public static func parseNumstat(_ data: Data) -> [String: LineStats] {
        let fields = split(data)
        var result: [String: LineStats] = [:]
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            let parts = field.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let binary = parts[0] == "-"
            let stats = LineStats(additions: Int(parts[0]) ?? 0, deletions: Int(parts[1]) ?? 0, isBinary: binary)
            var path = String(parts[2])
            if path.isEmpty, index + 1 < fields.count {
                path = fields[index + 1]
                index += 2
            }
            result[path] = stats
        }
        return result
    }

    /// NUL-separated fields, decoded as UTF-8 (invalid bytes are replaced).
    static func split(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }
}
