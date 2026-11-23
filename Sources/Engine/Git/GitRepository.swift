import Foundation

/// Where a directory sits in git: the repository's main checkout, a linked worktree, or not a repository.
public enum GitWorkspaceKind: String, Sendable, Hashable, Codable {
    case mainCheckout, worktree, notRepository

    public var label: String {
        switch self {
        case .mainCheckout: "Local checkout"
        case .worktree: "Worktree"
        case .notRepository: "Not a git repository"
        }
    }
}

/// Paths of a repository as seen from one directory.
public struct GitLocation: Sendable, Hashable {
    /// The working tree root (the main checkout or the worktree).
    public var root: String
    /// This working tree's git directory (`.git`, or `.git/worktrees/<name>` for a worktree).
    public var gitDirectory: String
    /// The shared git directory of the repository (the main checkout's `.git`).
    public var commonDirectory: String
    public var kind: GitWorkspaceKind

    /// The main checkout's root (the common directory's parent).
    public var mainRoot: String { (commonDirectory as NSString).deletingLastPathComponent }
}

/// A branch from `git for-each-ref`, newest commit first.
public struct GitBranch: Sendable, Hashable, Identifiable {
    public var name: String
    public var isRemote: Bool
    public var upstream: String?
    public var commitDate: Date?
    public var shortHash: String
    /// The worktree that has it checked out, if any.
    public var worktreePath: String?

    public var id: String { (isRemote ? "remote:" : "local:") + name }
    /// `origin/main` → `main`; a local name unchanged.
    public var localName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

/// A commit for the per-commit scope.
public struct GitCommit: Sendable, Hashable, Identifiable {
    public var hash: String
    public var shortHash: String
    public var subject: String
    public var author: String
    public var date: Date
    public var id: String { hash }
}

/// A working tree of the repository (`git worktree list --porcelain`).
public struct GitWorktree: Sendable, Hashable, Identifiable {
    public var path: String
    public var head: String?
    /// nil when detached.
    public var branch: String?
    public var isMain: Bool
    public var isLocked: Bool
    public var isPrunable: Bool
    public var id: String { path }
}

/// Git operations on one directory. A value: every call runs `git` off the main actor through `GitRunner`, honours
/// cancellation and returns `Sendable` results.
public struct GitRepository: Sendable {
    public let directory: String
    public let runner: GitRunner
    /// Places outside the repository git may write to (a new worktree's parent folder); see `HostGit`.
    public var writableRoots: [String]

    public init(directory: String, runner: GitRunner = GitRunner(), writableRoots: [String] = []) {
        self.directory = directory
        self.runner = runner
        self.writableRoots = writableRoots
    }

    public func git(
        _ arguments: [String], input: Data? = nil, timeout: Duration? = nil, limit: Int? = nil, allowFailure: Bool = false,
        configuration: [GitRunner.Setting] = [], destinations: [String] = []
    ) async throws -> GitOutput {
        try await runner.run(
            arguments, in: directory, input: input, timeout: timeout, outputLimit: limit, allowFailure: allowFailure, writableRoots: writableRoots,
            configuration: configuration, destinations: destinations)
    }

    // MARK: Location and status

    /// The repository paths, or nil outside a repository (or when the folder does not exist).
    public func location() async throws -> GitLocation? {
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        let output = try await git(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"], allowFailure: true)
        guard output.status == 0 else { return nil }
        let lines = output.text.split(separator: "\n").map(String.init)
        guard lines.count >= 3 else { return nil }
        let gitDirectory = (lines[1] as NSString).standardizingPath
        let common = (lines[2] as NSString).standardizingPath
        return GitLocation(root: lines[0], gitDirectory: gitDirectory, commonDirectory: common, kind: gitDirectory == common ? .mainCheckout : .worktree)
    }

    /// Branch, upstream, ahead/behind and changed files with per-side line counts.
    public func status(limit: Int = 10_000) async throws -> GitStatus {
        async let porcelain = git(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all", "--find-renames"])
        // Plumbing for the working tree: porcelain `git diff` ignores GIT_OPTIONAL_LOCKS and, after a stat-only change,
        // takes .git/index.lock to refresh the index, failing the user's or an agent's concurrent git ("index.lock: File
        // exists"). `diff-files` never writes the index (and leaves a stat-only change out, as status does).
        async let unstaged = git(["diff-files", "--numstat", "-z", "-M"], allowFailure: true)
        async let staged = git(["diff", "--cached", "--numstat", "-z", "-M"], allowFailure: true)
        var status = GitStatusParser.parse(try await porcelain.stdout, limit: limit)
        if let gitDirectory = try? await git(["rev-parse", "--path-format=absolute", "--git-dir"], allowFailure: true).text
            .trimmingCharacters(in: .whitespacesAndNewlines), !gitDirectory.isEmpty
        {
            status.operation = GitOperation.read(gitDirectory: gitDirectory)
        }
        let unstagedStats = GitStatusParser.parseNumstat(try await unstaged.stdout)
        let stagedStats = GitStatusParser.parseNumstat(try await staged.stdout)
        for index in status.files.indices {
            let path = status.files[index].path
            if status.files[index].staged != nil { status.files[index].stagedStats = stagedStats[path] ?? .zero }
            if status.files[index].isUntracked {
                status.files[index].unstagedStats = Self.untrackedStats(URL(filePath: directory).appending(path: path))
            } else if status.files[index].unstaged != nil {
                status.files[index].unstagedStats = unstagedStats[path] ?? .zero
            }
            try Task.checkCancellation()
        }
        return status
    }

    /// Line count of an untracked file (≤ 4 MB read; larger or non-UTF-8 counts as binary).
    static func untrackedStats(_ url: URL) -> LineStats {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 4 << 20,
              let data = try? Data(contentsOf: url)
        else { return LineStats(additions: 0, deletions: 0, isBinary: true) }
        if data.isEmpty { return .zero }
        if data.prefix(8_000).contains(0) { return LineStats(additions: 0, deletions: 0, isBinary: true) }
        var lines = data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        if data.last != 10 { lines += 1 }
        return LineStats(additions: lines, deletions: 0)
    }

    // MARK: Branches and commits

    /// Local and remote branches, most recently committed first (remote HEAD aliases left out).
    public func branches() async throws -> [GitBranch] {
        let format = "%(refname)%00%(refname:short)%00%(upstream:short)%00%(committerdate:unix)%00%(objectname:short)%00%(worktreepath)"
        let output = try await git(["for-each-ref", "--sort=-committerdate", "--format=\(format)", "refs/heads", "refs/remotes"])
        return output.text.split(separator: "\n").compactMap { line -> GitBranch? in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6, !parts[0].hasSuffix("/HEAD") else { return nil }
            return GitBranch(
                name: parts[1], isRemote: parts[0].hasPrefix("refs/remotes/"), upstream: parts[2].isEmpty ? nil : parts[2],
                commitDate: TimeInterval(parts[3]).map { Date(timeIntervalSince1970: $0) }, shortHash: parts[4],
                worktreePath: parts[5].isEmpty ? nil : parts[5])
        }
    }

    /// Commits in `range` (for example `main..HEAD`), newest first, at most `limit`.
    public func commits(_ range: String = "HEAD", limit: Int = 100) async throws -> [GitCommit] {
        let output = try await git(["log", "--format=%H%x00%h%x00%s%x00%an%x00%at", "-n", String(limit), range, "--"], allowFailure: true)
        guard output.status == 0 else { return [] }
        return output.text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5 else { return nil }
            return GitCommit(
                hash: parts[0], shortHash: parts[1], subject: parts[2], author: parts[3],
                date: Date(timeIntervalSince1970: TimeInterval(parts[4]) ?? 0))
        }
    }

    /// Whether `ref` resolves to a commit.
    public func resolves(_ ref: String) async throws -> Bool {
        try await git(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], allowFailure: true).status == 0
    }

    public func revParse(_ ref: String) async throws -> String? {
        let output = try await git(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], allowFailure: true)
        return output.status == 0 ? output.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    public func mergeBase(_ a: String, _ b: String) async throws -> String? {
        let output = try await git(["merge-base", a, b], allowFailure: true)
        return output.status == 0 ? output.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    // MARK: Diffs

    public enum DiffScope: Sendable, Hashable {
        /// Working tree vs index.
        case unstaged
        /// Index vs HEAD.
        case staged
        /// One commit vs its first parent.
        case commit(String)
        /// `from` vs the working tree (merge-base comparisons pass the merge base).
        case workingTree(from: String)
        /// Two revisions.
        case range(from: String, to: String)
    }

    /// Unified patches for a scope (untracked files are included for `.unstaged` and `.workingTree`). `context` is the
    /// number of unchanged lines around each hunk.
    public func diff(_ scope: DiffScope, paths: [String] = [], context: Int = 3, ignoreWhitespace: Bool = false, limit: Int = 64 << 20) async throws
        -> String
    {
        let options = ["--no-color", "--no-ext-diff", "--no-textconv", "-M", "-U\(context)"] + (ignoreWhitespace ? ["-w"] : [])
        var arguments = ["diff"] + options
        switch scope {
        // Scopes that read the working tree use plumbing, which never writes the index (see `status`).
        case .unstaged: arguments = ["diff-files", "-p"] + options
        case .staged: arguments.append("--cached")
        case .commit(let hash):
            arguments = ["show", "--format=", "--no-color", "--no-ext-diff", "--no-textconv", "-M", "-U\(context)"] + (ignoreWhitespace ? ["-w"] : []) + [hash]
        case .workingTree(let from): arguments = ["diff-index", "-p"] + options + [from]
        case .range(let from, let to): arguments += [from, to]
        }
        var text = try await git(arguments + ["--"] + paths, limit: limit).text
        switch scope {
        case .unstaged, .workingTree:
            let untracked = try await git(["ls-files", "--others", "--exclude-standard", "-z", "--"] + paths).stdout
            for path in GitStatusParser.split(untracked).prefix(2_000) {
                try Task.checkCancellation()
                let output = try await git(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-index", "-U\(context)", "--", "/dev/null", path], limit: limit, allowFailure: true)
                text += output.text
            }
        default: break
        }
        return text
    }

    /// A file's content at a revision (`:path` for the index), or nil when it does not exist there.
    public func content(at revision: String, path: String, limit: Int = 32 << 20) async throws -> Data? {
        let output = try await git(["show", "\(revision):\(path)"], limit: limit, allowFailure: true)
        return output.status == 0 ? output.stdout : nil
    }

    // MARK: Index, commit, push

    public func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await git(["add", "-A", "--"] + paths)
    }

    public func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        if try await resolves("HEAD") {
            _ = try await git(["restore", "--staged", "--"] + paths)
        } else {
            _ = try await git(["rm", "--cached", "-r", "-q", "--"] + paths)
        }
    }

    /// Commits the index with `message`; returns the new commit's hash.
    @discardableResult
    public func commit(message: String) async throws -> String {
        _ = try await git(["commit", "-q", "-F", "-"], input: Data(message.utf8))
        return try await revParse("HEAD") ?? ""
    }

    /// Pushes the current branch; publishes it to `remote` when it has no upstream.
    public func push(remote: String = "origin") async throws {
        let status = try await self.status(limit: 1)
        if status.upstream == nil, let branch = status.branch {
            _ = try await git(["push", "-u", remote, branch], timeout: .seconds(180))
        } else {
            _ = try await git(["push"], timeout: .seconds(180))
        }
    }

    public func remoteURL(_ remote: String = "origin") async throws -> String? {
        let output = try await git(["remote", "get-url", remote], allowFailure: true)
        return output.status == 0 ? output.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    // MARK: Worktrees

    public func worktrees() async throws -> [GitWorktree] {
        let output = try await git(["worktree", "list", "--porcelain"])
        var result: [GitWorktree] = []
        var current: GitWorktree?
        for line in output.text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let current { result.append(current) }
                current = GitWorktree(path: String(line.dropFirst(9)), head: nil, branch: nil, isMain: result.isEmpty, isLocked: false, isPrunable: false)
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst(5))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst(7))
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
            } else if line.hasPrefix("locked") {
                current?.isLocked = true
            } else if line.hasPrefix("prunable") {
                current?.isPrunable = true
            }
        }
        if let current { result.append(current) }
        return result
    }
}
