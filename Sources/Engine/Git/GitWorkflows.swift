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
    /// The commit the push sends (HEAD when the plan was read): the push sends exactly this, never a later HEAD.
    public var localHead: String
    /// `refs/remotes/<remote>/<branch>` when the plan was read (nil: none). A force push leases on exactly this, so a
    /// remote commit the person never saw is not overwritten even if a fetch advanced the tracking ref meanwhile.
    public var remoteHead: String?
}

/// The push no longer matches its plan (what was shown and confirmed): nothing was pushed (AF06, AF21).
public enum GitPushPlanError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The branch or its HEAD moved.
    case branchChanged
    /// The remote's push URL is no longer the one shown.
    case destinationChanged
    /// The remote has several push URLs: one push would send to all of them, more than one card can show.
    case severalPushURLs(String)
    /// The plan needs a force push and none was confirmed.
    case forceNotConfirmed

    public var description: String { userMessage }

    public var userMessage: String {
        switch self {
        case .branchChanged: "The branch changed since the push was confirmed. Nothing was pushed; push again to review it."
        case .destinationChanged: "The remote's address changed since the push was confirmed. Nothing was pushed; push again to review it."
        case .severalPushURLs(let remote): "\(remote) has several push URLs. BelloCode pushes to one reviewed destination; push from a terminal."
        case .forceNotConfirmed: "The remote has commits this branch does not. Nothing was pushed."
        }
    }
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
        let urls = try await pushURLs(remote)
        guard let url = urls.first else { return nil }
        guard urls.count == 1 else { throw GitPushPlanError.severalPushURLs(remote) }
        guard let localHead = try await revParse("HEAD") else { return nil }
        let remoteRef = "refs/remotes/\(remote)/\(branch)"
        let remoteHead = try await revParse(remoteRef)
        let exists = remoteHead != nil
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
            needsForce: needsForce, setsUpstream: status.upstream == nil, localHead: localHead, remoteHead: remoteHead)
    }

    /// Every push URL of `remote` (`--all`: git pushes to each of them), insteadOf rewriting applied.
    func pushURLs(_ remote: String) async throws -> [String] {
        let output = try await git(["remote", "get-url", "--push", "--all", remote], allowFailure: true)
        guard output.status == 0 else { return [] }
        return output.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Pushes `branch` to `remote` (an ordinary push: never forces; git refuses a non-fast-forward).
    public func push(branch: String, remote: String = "origin", setUpstream: Bool) async throws {
        var arguments = ["push", "--quiet"]
        if setUpstream { arguments.append("-u") }
        arguments += [remote, "HEAD:refs/heads/\(branch)"]
        _ = try await git(arguments, timeout: .seconds(180))
    }

    /// Pushes exactly what `plan` showed and the person (or the agent's approval card) confirmed (AF06, AF21, AV08): its
    /// local commit, to its URL, and nothing else, after checking that the branch, HEAD and the remote's push URL are
    /// still the plan's.
    ///
    /// The push goes to the remote by name, so settings scoped to it (`remote.<name>.sslVerify`, `.proxy`, `.receivepack`)
    /// apply as they would in a terminal (GV10), but its push URL is pinned for this one invocation (`pinnedPush`): the
    /// approved URL is what git connects to even if the remote, or a `url.<base>.insteadOf` rule, changes between the
    /// check and the push, and the URL is never rewritten a second time (a URL handed back to git as a new repository
    /// argument would be, so a rule matching the already-rewritten URL could send the commit to another repository).
    /// Only the approved branch is updated: no annotated tags (`push.followTags`) and no push options. A force push
    /// leases on the remote head the plan saw (`--force-with-lease=<ref>:<oid>`), never on whatever the tracking ref
    /// holds by then. On success the tracking ref and, when the plan said so, the upstream are recorded.
    public func push(_ plan: GitPushPlan, force: Bool) async throws {
        if plan.needsForce && !force { throw GitPushPlanError.forceNotConfirmed }
        let status = try await self.status(limit: 1)
        guard status.branch == plan.branch, try await revParse("HEAD") == plan.localHead else { throw GitPushPlanError.branchChanged }
        let urls = try await pushURLs(plan.remote)
        guard urls.count <= 1 else { throw GitPushPlanError.severalPushURLs(plan.remote) }
        guard urls.first == plan.remoteURL else { throw GitPushPlanError.destinationChanged }
        var arguments = ["push", "--quiet", "--no-follow-tags"]
        if force { arguments.append("--force-with-lease=refs/heads/\(plan.branch):\(plan.remoteHead ?? "")") }
        arguments += [plan.remote, "\(plan.localHead):refs/heads/\(plan.branch)"]
        _ = try await git(arguments, timeout: .seconds(180), configuration: Self.pinnedPush(plan), destinations: [plan.remoteURL])
        // What `git push <remote> <branch>` would have recorded (the source is a commit, not a branch, so git sets no
        // upstream itself, and records the tracking ref only when a fetch refspec covers it).
        _ = try? await git(["update-ref", "refs/remotes/\(plan.remote)/\(plan.branch)", plan.localHead], allowFailure: true)
        if plan.setsUpstream {
            _ = try? await git(["config", "branch.\(plan.branch).remote", plan.remote], allowFailure: true)
            _ = try? await git(["config", "branch.\(plan.branch).merge", "refs/heads/\(plan.branch)"], allowFailure: true)
        }
    }

    /// Configuration that makes `git push <plan.remote>` connect to exactly `plan.remoteURL`, read after every file:
    /// the remote's URLs and push URLs are cleared (an empty value resets the list) and replaced by an unguessable
    /// placeholder that one `insteadOf` rule, ours, maps to the approved URL (with a URL configured, git reads no
    /// legacy `.git/remotes` file that could add another push URL). A rule matches by prefix and the longest wins, so no
    /// rule in a file can out-match ours on the full placeholder; a push URL gets `insteadOf` only, never
    /// `pushInsteadOf`, and git rewrites once. Push options and tag following are off: one ref update, the one shown.
    static func pinnedPush(_ plan: GitPushPlan) -> [GitRunner.Setting] {
        let placeholder = "bellocode-approved-push-\(UUID().uuidString.lowercased()):"
        return [
            GitRunner.Setting("remote.\(plan.remote).url", ""),
            GitRunner.Setting("remote.\(plan.remote).url", placeholder),
            GitRunner.Setting("remote.\(plan.remote).pushurl", ""),
            GitRunner.Setting("remote.\(plan.remote).pushurl", placeholder),
            GitRunner.Setting("url.\(plan.remoteURL).insteadOf", placeholder),
            GitRunner.Setting("push.followTags", "false"),
            GitRunner.Setting("push.pushOption", ""),
            GitRunner.Setting("remote.\(plan.remote).mirror", "false"),
        ]
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
        // Everything against HEAD reads the working tree: plumbing `diff-index`, which never takes the index lock
        // (porcelain `git diff` does after a stat-only change, see GitRepository.status).
        let command = cached.isEmpty ? ["diff-index"] : ["diff", "--cached"]
        let target = cached.isEmpty ? ["HEAD"] : []
        let stat = try await git(command + ["--no-color", "--no-ext-diff", "--no-textconv", "--stat=120"] + target, allowFailure: true).text
        var patch = try await git(command + ["-p", "--no-color", "--no-ext-diff", "--no-textconv", "-U1"] + target, limit: 4 << 20, allowFailure: true).text
        var summary = stat
        // Untracked files are committed too when nothing is staged (commitAll stages them): list them and quote the
        // start of each small text file, as git would commit it (AF01).
        if cached.isEmpty {
            let untracked = GitStatusParser.split(try await git(["ls-files", "--others", "--exclude-standard", "-z"], allowFailure: true).stdout)
            for path in untracked.prefix(50) {
                summary += "\n new file: \(path)"
                guard patch.count < patchLimit, let excerpt = Self.untrackedExcerpt(path, in: directory) else { continue }
                patch += "\n+++ new file \(path)\n" + excerpt
            }
        }
        return (summary, String(patch.prefix(patchLimit)))
    }

    /// The start of untracked `path` as git would commit it, or nil when it is not quoted (large, binary, unreadable,
    /// or reached through a link). Read beneath `directory` without following any link (`ConfinedDirectory`): a link
    /// is committed as its text, so its text is what is quoted, never the file it points to, which may be outside the
    /// checkout. The size is checked on the open file before any byte is read.
    static func untrackedExcerpt(_ path: String, in directory: String) -> String? {
        guard let components = ConfinedDirectory.components(path), let name = components.last,
              case .success(let parent) = ConfinedDirectory.open(root: directory, components.dropLast(), create: false)
        else { return nil }
        switch parent.preview(name, maxSize: 64 << 10, prefix: 8_000) {
        case .regular(let data):
            guard !data.contains(0) else { return nil }
            return String(decoding: data.prefix(2_000), as: UTF8.self)
        case .symlink(let target):
            return "(symbolic link to \(target))"
        case .skipped:
            return nil
        }
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

    /// Applies the stash `hash` (conflicts are reported by git). Kept in the list until dropped. With `index`, the
    /// staged changes are restored to the index too (git refuses when they no longer apply); without it they are
    /// folded into the working tree.
    public func applyStash(_ hash: String, index: Bool = false) async throws {
        _ = try await git(["stash", "apply", "--quiet"] + (index ? ["--index"] : []) + [hash])
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

    /// Applies `hash`, index included, and reports what stopped it: nil only when it applied cleanly and the result
    /// verifiably matches the saved copy (index, tracked working files and untracked files each compared with the
    /// stash), otherwise git's message and the paths concerned (an untracked file in the way, a conflict, a mismatch).
    ///
    /// Untracked files already in the way are checked first: git would otherwise apply the tracked changes and then
    /// stop, leaving a half-restored checkout that the recovery instructions could not describe. "No unmerged paths"
    /// is not proof of a restore: a stash applied without its index loses staged-only content silently (A04).
    func restore(_ hash: String, beforeVerify: (@Sendable () async -> Void)? = nil) async -> (message: String, unresolved: [String])? {
        let inTheWay = await untrackedInTheWay(hash: hash)
        if !inTheWay.isEmpty { return ("Untracked files are in the way; nothing was applied.", inTheWay) }
        do {
            try await applyStash(hash, index: true)
        } catch {
            let message = (error as? GitError)?.userMessage ?? String(describing: error)
            return (message, await unresolvedPaths(hash: hash))
        }
        let unmerged = (try? await git(["diff", "--name-only", "--diff-filter=U", "-z"], allowFailure: true).text) ?? ""
        let paths = unmerged.split(separator: "\0").map(String.init)
        if !paths.isEmpty { return ("Some changes conflict.", paths) }
        await beforeVerify?()
        if let mismatch = await restoreMismatch(hash) {
            return ("The restored changes do not match the saved copy (\(mismatch.part)); the saved copy was kept.", mismatch.paths)
        }
        return nil
    }

    /// Compares the checkout with the stash `hash`: the index with its index commit (`^2`), tracked working files with
    /// its working-tree commit, and its untracked files (`^3`) with the files here. Nil when all three match.
    func restoreMismatch(_ hash: String) async -> (part: String, paths: [String])? {
        let common = ["--no-ext-diff", "--no-textconv", "--ignore-submodules=none", "--no-renames"]
        func differing(_ arguments: [String]) async -> [String]? {
            guard let output = try? await git(["diff"] + common + ["--name-only", "-z"] + arguments + ["--"], allowFailure: true), output.status == 0
            else { return ["(unreadable)"] }
            let paths = output.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            return paths.isEmpty ? nil : paths
        }
        if let paths = await differing(["--cached", "\(hash)^2"]) { return ("staged changes", paths) }
        if let paths = await differing([hash]) { return ("working files", paths) }
        guard case .some(.some) = try? await revParse("\(hash)^3") else { return nil }
        guard let listing = try? await git(["ls-tree", "-r", "-z", "\(hash)^3"], allowFailure: true), listing.status == 0 else {
            return ("untracked files", ["(unreadable)"])
        }
        var links: [(path: String, object: String)] = []
        var files: [(path: String, object: String)] = []
        var missing: [String] = []
        for entry in listing.stdout.split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let tab = text.firstIndex(of: "\t") else { continue }
            let fields = text[..<tab].split(separator: " ")
            guard fields.count == 3 else { continue }
            let path = String(text[text.index(after: tab)...])
            let full = directory + "/" + path
            if fields[0] == "120000" {
                if isSymlink(full) { links.append((path, String(fields[2]))) } else { missing.append(path) }
            } else if FileManager.default.fileExists(atPath: full), !isSymlink(full) {
                files.append((path, String(fields[2])))
            } else {
                missing.append(path)
            }
        }
        if !missing.isEmpty { return ("untracked files", missing) }
        var differ: [String] = []
        // A link's content is its target.
        for link in links {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: directory + "/" + link.path),
                  let output = try? await git(["hash-object", "--stdin"], input: Data(target.utf8), allowFailure: true),
                  output.status == 0, output.text.trimmingCharacters(in: .whitespacesAndNewlines) == link.object
            else { differ.append(link.path); continue }
        }
        var start = 0
        while start < files.count {
            let chunk = files[start..<min(start + 200, files.count)]
            start += chunk.count
            guard let output = try? await git(["hash-object", "--"] + chunk.map(\.path), allowFailure: true), output.status == 0 else {
                differ += chunk.map(\.path)
                continue
            }
            let objects = output.text.split(separator: "\n").map(String.init)
            for (index, entry) in chunk.enumerated() where index >= objects.count || objects[index] != entry.object {
                differ.append(entry.path)
            }
        }
        return differ.isEmpty ? nil : ("untracked files", differ.sorted())
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
        // `refs/stash` is the fallback when no ref of its own could be made: deleting it would drop every stash.
        lines.append("When it applies cleanly: git stash drop (the matching entry)" + (ref == "refs/stash" ? "" : " and git update-ref -d \(ref)"))
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
