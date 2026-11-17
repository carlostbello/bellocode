import Foundation

// VCS, worktree, per-turn diff and revert shapes from Contracts/opencode-2.3.0/openapi.json, checked against the
// pinned binary (docs/features/diff-git.md).

/// `Vcs.Branch`: both fields are absent on the first call for a location (opencode resolves them lazily).
public struct VcsBranch: Codable, Sendable, Hashable {
    public var current: String?
    public var `default`: String?
}

/// `Vcs.Info` (`GET /api/vcs`).
public struct VcsInfo: Codable, Sendable, Hashable {
    public var provider: String?
    public var branch: VcsBranch
}

/// `Vcs.Base` (`GET /api/vcs/base`): the branch a checkout was started from (`reflog`) or the default branch.
public struct VcsBase: Codable, Sendable, Hashable {
    public var name: String
    public var ref: String
    public var source: String
}

/// `added | deleted | modified` (untracked files are reported as `added`).
public struct FileChangeStatus: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let added: Self = "added"
    public static let deleted: Self = "deleted"
    public static let modified: Self = "modified"
}

/// `Vcs.FileStatus` (`GET /api/vcs/status`). Staged and unstaged changes are not distinguished.
public struct VcsFileStatus: Codable, Sendable, Hashable {
    public var file: String
    public var additions: Int
    public var deletions: Int
    public var status: FileChangeStatus
}

/// `FileDiff.Info`: one file's unified patch (`git diff` format, a header then hunks). `more` marks a truncated
/// list.
public struct FileDiffInfo: Codable, Sendable, Hashable {
    public var file: String
    public var patch: String
    public var additions: Int
    public var deletions: Int
    public var status: FileChangeStatus
    public var more: Bool?

    public init(file: String, patch: String, additions: Int, deletions: Int, status: FileChangeStatus, more: Bool? = nil) {
        self.file = file
        self.patch = patch
        self.additions = additions
        self.deletions = deletions
        self.status = status
        self.more = more
    }
}

/// `Vcs.Mode` for `GET /api/vcs/diff`: HEAD → working copy, merge-base → working copy, merge-base → HEAD.
public enum VcsDiffMode: String, Sendable, CaseIterable {
    case working, branch, committed
}

/// `Vcs.Untracked`: how untracked files appear in a working diff.
public enum VcsUntracked: String, Sendable {
    case files, folders
}

/// `Worktree.Directory` (`GET /api/worktree`): the project's saved worktrees, the main checkout included.
public struct WorktreeDirectory: Codable, Sendable, Hashable {
    public var directory: String
    /// `git` for worktrees opencode created or adopted; absent for the main checkout.
    public var strategy: String?
}

/// `Worktree.CreateInput`. opencode always checks out a detached HEAD (`branch` names an existing ref) inside a
/// randomly named folder under `directory`, so BelloCode creates worktrees with git and uses `refresh` instead.
public struct WorktreeCreateRequest: Encodable, Sendable {
    public var projectID: String
    public var from: String?
    public var branch: String?
    public var directory: String?
    public var name: String?

    public init(projectID: String, from: String? = nil, branch: String? = nil, directory: String? = nil, name: String? = nil) {
        self.projectID = projectID
        self.from = from
        self.branch = branch
        self.directory = directory
        self.name = name
    }
}

struct WorktreeRemoveBody: Encodable, Sendable {
    var projectID: String
    var directory: String
    var force: Bool
}

struct WorktreeRefreshBody: Encodable, Sendable {
    var projectID: String
}

/// `Worktree.Info`.
public struct WorktreeInfo: Codable, Sendable, Hashable {
    public var directory: String
}

/// `Session.Revert`: a staged boundary. `files` lists the patches applied when the stage restored files (empty when
/// it did not).
public struct SessionRevertInfo: Codable, Sendable, Hashable {
    public var messageID: String
    public var partID: String?
    public var snapshot: String?
    public var files: [FileDiffInfo]?
}

struct RevertStageBody: Encodable, Sendable {
    var messageID: String
    var files: Bool?
}

/// `WorktreeError` body data: `forceRequired` is true when the worktree holds modified or untracked files.
public struct WorktreeErrorData: Decodable, Sendable, Hashable {
    public var message: String
    public var forceRequired: Bool?
}
