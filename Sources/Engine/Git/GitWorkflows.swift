import Foundation

/// A configured remote: name and its fetch and push URLs.
public struct GitRemote: Sendable, Hashable, Identifiable {
    public var name: String
    public var fetchURL: String
    public var pushURL: String
    public var id: String { name }
}

/// A commit that a push would send (for the push approval card).
public struct GitOutgoingCommit: Sendable, Hashable, Identifiable {
    public var hash: String
    public var shortHash: String
    public var subject: String
    public var id: String { hash }
}

/// What a push would do, read before anything is sent (shown on the agent's approval card and the person's
/// confirmation).
public struct GitPushPlan: Sendable, Hashable {
    public var remote: String
    public var remoteURL: String
    public var branch: String
    /// The remote branch (`origin/<branch>`) exists.
    public var remoteBranchExists: Bool
    /// Commits on the branch that the remote does not have (newest first, at most 50).
    public var commits: [GitOutgoingCommit]
    public var moreCommits: Int
    /// The remote branch has commits the local one lacks: only a force push would succeed.
    public var needsForce: Bool
    public var setsUpstream: Bool
}

// Git parity workflows (docs/features/git-parity.md): fetch, pull, sync, push with plans, remotes, stashes, switching,
// operations in progress. Every call runs confined git (`GitRunner`); network calls authenticate through the app's
// credential helper for configured GitLab remotes.
extension GitRepository {
    // MARK: Remotes

    public func remotes() async throws -> [GitRemote] {
        let output = try await git(["remote"], allowFailure: true)
        guard output.status == 0 else { return [] }
        var result: [GitRemote] = []
        for name in output.text.split(separator: "\n").map(String.init).prefix(32) {
            let fetch = try await git(["remote", "get-url", name], allowFailure: true).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let push = try await git(["remote", "get-url", "--push", name], allowFailure: true).text.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(GitRemote(name: name, fetchURL: fetch, pushURL: push.isEmpty ? fetch : push))
        }
        return result
    }

    /// Points `remote` at `url` (fetch and push).
    public func setRemoteURL(_ remote: String, url: String) async throws {
        _ = try await git(["remote", "set-url", remote, url])
        _ = try await git(["config", "--unset-all", "remote.\(remote).pushurl"], allowFailure: true)
    }

    public func addRemote(_ name: String, url: String) async throws {
        _ = try await git(["remote", "add", name, url])
    }

    // MARK: Network

    /// `git fetch --prune <remote>` (all remotes when nil).
    public func fetch(remote: String? = nil) async throws {
        _ = try await git(["fetch", "--prune", "--quiet"] + (remote.map { [$0] } ?? ["--all"]), timeout: .seconds(120))
    }

    /// Fast-forward only: never creates a merge commit or rewrites history (a diverged branch fails with git's message).
    public func pullFastForward() async throws {
        _ = try await git(["pull", "--ff-only", "--quiet"], timeout: .seconds(180))
    }

    /// Rebases the branch onto its upstream (explicit choice for a diverged branch). Conflicts leave the rebase
    /// stopped; `status().operation` reports it.
    public func pullRebase() async throws {
        _ = try await git(["pull", "--rebase", "--quiet"], timeout: .seconds(180))
    }

    /// What pushing the current branch to `remote` would send. Fetches nothing (callers fetch first when they want
    /// the remote's current state).
    public func pushPlan(remote: String = "origin") async throws -> GitPushPlan? {
        let status = try await self.status(limit: 1)
        guard let branch = status.branch else { return nil }
        let url = try await git(["remote", "get-url", "--push", remote], allowFailure: true).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        let remoteRef = "refs/remotes/\(remote)/\(branch)"
        let exists = try await resolves(remoteRef)
        var range = "HEAD"
        var needsForce = false
        if exists {
            range = "\(remoteRef)..HEAD"
            needsForce = try await git(["merge-base", "--is-ancestor", remoteRef, "HEAD"], allowFailure: true).status != 0
        } else if let base = try await defaultRemoteBranch(remote: remote) {
            range = "\(remote)/\(base)..HEAD"
        }
        let count = Int(try await git(["rev-list", "--count", range], allowFailure: true).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let log = try await git(["log", "--format=%H%x00%h%x00%s", "-n", "50", range, "--"], allowFailure: true).text
        let commits = log.split(separator: "\n").compactMap { line -> GitOutgoingCommit? in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            return parts.count >= 3 ? GitOutgoingCommit(hash: parts[0], shortHash: parts[1], subject: parts[2]) : nil
        }
        return GitPushPlan(
            remote: remote, remoteURL: url, branch: branch, remoteBranchExists: exists, commits: commits, moreCommits: max(0, count - commits.count),
            needsForce: needsForce, setsUpstream: status.upstream == nil)
    }

    /// Pushes `branch` to `remote`. `force` uses `--force-with-lease` against the remote-tracking ref the plan saw,
    /// so a push that someone else updated meanwhile is refused instead of overwritten.
    public func push(branch: String, remote: String = "origin", setUpstream: Bool, force: Bool = false, expectedRemoteHead: String? = nil) async throws {
        var arguments = ["push", "--quiet"]
        if setUpstream { arguments.append("-u") }
        if force { arguments.append("--force-with-lease=refs/heads/\(branch)" + (expectedRemoteHead.map { ":\($0)" } ?? "")) }
        arguments += [remote, "HEAD:refs/heads/\(branch)"]
        _ = try await git(arguments, timeout: .seconds(180))
    }

    /// The remote's default branch (`refs/remotes/<remote>/HEAD`), else `main`/`master` if present.
    public func defaultRemoteBranch(remote: String = "origin") async throws -> String? {
        let head = try await git(["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"], allowFailure: true)
        if head.status == 0 {
            let name = head.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix(remote + "/") { return String(name.dropFirst(remote.count + 1)) }
        }
        for candidate in ["main", "master"] where try await resolves("refs/remotes/\(remote)/\(candidate)") { return candidate }
        return nil
    }

    /// Commits on HEAD not on `base` (for "commits ahead of the default branch").
    public func count(_ range: String) async throws -> Int {
        Int(try await git(["rev-list", "--count", range], allowFailure: true).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: Commit

    /// Stages everything (tracked and untracked) when nothing is staged yet, then commits. Returns the new hash.
    @discardableResult
    public func commitAll(message: String) async throws -> String {
        let status = try await self.status()
        if status.stagedFiles.isEmpty { _ = try await git(["add", "-A"]) }
        return try await commit(message: message)
    }

    /// Short summary of what would be committed (for generated messages): `--stat` of staged changes, or of all
    /// changes when nothing is staged, plus a bounded patch excerpt.
    public func commitContext(patchLimit: Int = 12_000) async throws -> (stat: String, patch: String) {
        let staged = try await git(["diff", "--cached", "--name-only"], allowFailure: true).text
        let cached = staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : ["--cached"]
        let stat = try await git(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--stat=120"] + cached + (cached.isEmpty ? ["HEAD"] : []), allowFailure: true).text
        var patch = try await git(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "-U1"] + cached + (cached.isEmpty ? ["HEAD"] : []), limit: 4 << 20, allowFailure: true).text
        var summary = stat
        // Untracked files are committed too when nothing is staged (commitAll stages them): list them and quote the
        // start of each small text file.
        if cached.isEmpty {
            let untracked = GitStatusParser.split(try await git(["ls-files", "--others", "--exclude-standard", "-z"], allowFailure: true).stdout)
            for path in untracked.prefix(50) {
                summary += "\n new file: \(path)"
                guard patch.count < patchLimit, let data = FileManager.default.contents(atPath: (directory as NSString).appendingPathComponent(path)),
                      data.count < 64 << 10, !data.prefix(8_000).contains(0)
                else { continue }
                patch += "\n+++ new file \(path)\n" + String(decoding: data.prefix(2_000), as: UTF8.self)
            }
        }
        return (summary, String(patch.prefix(patchLimit)))
    }

    /// Recent commit subjects (repository conventions for generated messages).
    public func recentSubjects(_ limit: Int = 12) async throws -> [String] {
        try await commits("HEAD", limit: limit).map(\.subject)
    }

    // MARK: Switching branches and stashes

    /// Switches to `branch` (creating it from HEAD when `create`). git refuses when local changes would be
    /// overwritten; `GitSwitchError.localChanges` lets the caller offer to stash or bring them along.
    public func switchBranch(_ branch: String, create: Bool) async throws {
        let output = try await git(create ? ["switch", "-c", branch] : ["switch", branch], allowFailure: true)
        guard output.status == 0 else {
            let message = String(decoding: output.stderr, as: UTF8.self)
            if message.contains("would be overwritten") || message.contains("Please commit your changes or stash them") {
                throw GitSwitchError.localChanges(message.split(separator: "\n").filter { $0.hasPrefix("\t") }.map { $0.trimmingCharacters(in: .whitespaces) })
            }
            throw GitError.failed(command: "switch", status: output.status, message: output.message)
        }
    }

    /// Stashes every change (untracked included) under `message`; returns the stash commit's hash, or nil when there
    /// was nothing to stash. The hash, not `stash@{n}`, identifies it later (the stash list is shared by every
    /// worktree and may move). The entry is found by a per-operation token in its message, inside the process-wide
    /// stash lock, never by comparing separate reads of `refs/stash` (another worktree may push in between, R04).
    public func stash(message: String) async throws -> String? {
        try await GitStashLock.shared.run {
            let token = "bc-\(UUID().uuidString.prefix(12).lowercased())"
            _ = try await git(["stash", "push", "--include-untracked", "--quiet", "-m", "\(message) [\(token)]"])
            let list = try await git(["stash", "list", "--format=%H%x09%gs"], allowFailure: true).text
            for line in list.split(separator: "\n") {
                let fields = line.split(separator: "\t", maxSplits: 1)
                if fields.count == 2, fields[1].contains("[\(token)]") { return String(fields[0]) }
            }
            return nil
        }
    }

    /// Applies the stash `hash` (no index restore; conflicts are reported by git). Kept in the list until dropped.
    public func applyStash(_ hash: String) async throws {
        _ = try await git(["stash", "apply", "--quiet", hash])
    }

    /// Drops the stash entry whose commit is `hash` (found by hash, never by a remembered position: the entry's
    /// position is read and verified inside the stash lock immediately before the drop).
    public func dropStash(_ hash: String) async throws {
        try await GitStashLock.shared.run {
            let list = try await git(["stash", "list", "--format=%H"], allowFailure: true).text.split(separator: "\n").map(String.init)
            guard let index = list.firstIndex(of: hash) else { return }
            guard try await revParse("stash@{\(index)}") == hash else {
                throw GitError.failed(command: "stash", status: 1, message: "The stash list changed; the entry was kept.")
            }
            _ = try await git(["stash", "drop", "--quiet", "stash@{\(index)}"])
        }
    }

    /// Keeps `hash` reachable under an operation-specific ref until the work it holds is verifiably restored, so a
    /// dropped or garbage-collected stash entry never loses it. Returns the ref.
    public func keepRecoveryRef(_ hash: String) async throws -> String {
        let ref = "refs/bellocode/recovery/\(UUID().uuidString.lowercased())"
        _ = try await git(["update-ref", ref, hash])
        return ref
    }

    public func deleteRecoveryRef(_ ref: String) async {
        _ = try? await git(["update-ref", "-d", ref], allowFailure: true)
    }

    /// Applies `hash` and reports what stopped it: nil when it applied cleanly with no unmerged paths, otherwise git's
    /// message and the paths left unresolved (an untracked file in the way, a conflict).
    ///
    /// Untracked files already in the way are checked first: git would otherwise apply the tracked changes and then
    /// stop, leaving a half-restored checkout that the recovery instructions could not describe.
    func restore(_ hash: String) async -> (message: String, unresolved: [String])? {
        let inTheWay = await untrackedInTheWay(hash: hash)
        if !inTheWay.isEmpty { return ("Untracked files are in the way; nothing was applied.", inTheWay) }
        do {
            try await applyStash(hash)
        } catch {
            let message = (error as? GitError)?.userMessage ?? String(describing: error)
            return (message, await unresolvedPaths(hash: hash))
        }
        let unmerged = (try? await git(["diff", "--name-only", "--diff-filter=U", "-z"], allowFailure: true).text) ?? ""
        let paths = unmerged.split(separator: "\0").map(String.init)
        return paths.isEmpty ? nil : ("Some changes conflict.", paths)
    }

    /// The paths the stash would restore that are in the way or unmerged here (best effort, for the recovery message).
    private func unresolvedPaths(hash: String) async -> [String] {
        var paths = await untrackedInTheWay(hash: hash)
        let unmerged = (try? await git(["diff", "--name-only", "--diff-filter=U", "-z"], allowFailure: true).text) ?? ""
        paths += unmerged.split(separator: "\0").map(String.init)
        return Array(Set(paths)).sorted()
    }

    /// The stash's untracked files (its third parent) that already exist here.
    private func untrackedInTheWay(hash: String) async -> [String] {
        guard case .some(.some) = try? await revParse("\(hash)^3") else { return [] }
        let untracked = (try? await git(["ls-tree", "-r", "-z", "--name-only", "\(hash)^3"], allowFailure: true).text) ?? ""
        return untracked.split(separator: "\0").map(String.init).filter {
            FileManager.default.fileExists(atPath: directory + "/" + $0) || isSymlink(directory + "/" + $0)
        }
    }

    private func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    // MARK: Operations in progress

    /// Aborts a stopped merge, rebase, cherry-pick or revert (the working tree returns to before it started).
    public func abort(_ operation: GitOperation) async throws {
        _ = try await git([operation.command, "--abort"])
    }

    // MARK: Projects

    /// `git init` with `main`, an optional README, and a first commit when an identity is configured (otherwise the
    /// repository is left without a commit, as T3 Code does).
    public static func initialise(at directory: String, readme: String?, runner: GitRunner) async throws -> Bool {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let repository = GitRepository(directory: directory, runner: runner)
        _ = try await repository.git(["init", "-q", "-b", "main"])
        if let readme { try Data(readme.utf8).write(to: URL(filePath: directory).appending(path: "README.md")) }
        _ = try await repository.git(["add", "-A"])
        let identity = try await repository.git(["config", "user.email"], allowFailure: true)
        let environmentIdentity = runner.environment["GIT_AUTHOR_EMAIL"] != nil
        guard identity.status == 0 || environmentIdentity else { return false }
        return try await repository.git(["commit", "-q", "-m", "Initial commit"], allowFailure: true).status == 0
    }
}

/// Stashed work that could not be put back. The stash entry and an operation-specific ref both still hold it, and
/// nothing that holds a copy (the stash, the ref, a kept worktree) was removed (R04).
public struct StashRecoveryError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The stash commit holding the work.
    public let stash: String
    /// A ref that keeps the commit reachable even if the stash entry is dropped.
    public let ref: String
    /// Where the work belongs.
    public let directory: String
    /// A worktree kept because it may already hold part of the work.
    public let keptWorktree: String?
    /// Paths in the way or left unmerged.
    public let unresolved: [String]
    /// git's reason.
    public let reason: String

    public init(stash: String, ref: String, directory: String, keptWorktree: String? = nil, unresolved: [String], reason: String) {
        self.stash = stash
        self.ref = ref
        self.directory = directory
        self.keptWorktree = keptWorktree
        self.unresolved = unresolved
        self.reason = reason
    }

    public var description: String { userMessage }

    public var userMessage: String {
        "Your uncommitted changes could not be put back automatically. They are safe in stash \(stash.prefix(12))."
    }

    /// What the person does to recover, in the order to do it.
    public var instructions: String {
        var lines: [String] = []
        if !unresolved.isEmpty {
            let list = unresolved.prefix(8).joined(separator: ", ") + (unresolved.count > 8 ? " and \(unresolved.count - 8) more" : "")
            lines.append("In the way or unresolved: \(list). Move or delete these files first.")
        }
        lines.append("Then, in \((directory as NSString).abbreviatingWithTildeInPath), run:")
        lines.append("    git stash apply \(stash)")
        lines.append("When it applies cleanly: git stash drop (the matching entry) and git update-ref -d \(ref)")
        if let keptWorktree {
            lines.append("The new worktree at \((keptWorktree as NSString).abbreviatingWithTildeInPath) was kept; remove it once your changes are back.")
        }
        lines.append("git said: \(reason)")
        return lines.joined(separator: "\n")
    }
}

/// Serialises stash mutations across this process's repositories and worktrees (the stash list is shared by a
/// repository's worktrees, so position lookups must not interleave with pushes or drops).
actor GitStashLock {
    static let shared = GitStashLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if held {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            held = true
        }
        defer {
            if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

public enum GitSwitchError: Error, Sendable, Equatable {
    /// The switch would overwrite these files' local changes.
    case localChanges([String])
}
