import Foundation

/// Automatic worktree cleanup (T3 Code Settings ▸ Worktrees ▸ Cleanup), per project in `WorkspacePreferences`.
public struct WorktreeCleanupPolicy: Codable, Sendable, Hashable {
    /// Remove a thread's worktree when the thread is settled.
    public var afterSettle = false
    /// Remove it when the thread is archived.
    public var afterArchive = false
    public init(afterSettle: Bool = false, afterArchive: Bool = false) {
        self.afterSettle = afterSettle
        self.afterArchive = afterArchive
    }
    public var isOff: Bool { !afterSettle && !afterArchive }
}

/// Why a worktree is kept, or that it may go.
public enum WorktreeCleanupVerdict: Sendable, Equatable {
    case remove
    case keep(String)
}

extension WorktreeService {
    /// Whether a worktree may be removed automatically. Kept (always; there is no "delete anyway" policy) when it is
    /// not a BelloCode worktree under the project's worktree folder, has uncommitted, untracked or ignored files, has
    /// commits that are neither pushed nor merged into `base`, is checked out with a detached HEAD whose commit is not
    /// on any branch, or another thread uses it.
    public func cleanupVerdict(directory: String, projectDirectory: String, parent: String, base: String, sharedByOtherThreads: Bool) async
        -> WorktreeCleanupVerdict
    {
        let real = URL(filePath: directory).resolvingSymlinksInPath().path
        let realParent = URL(filePath: parent).resolvingSymlinksInPath().path
        guard real.hasPrefix(realParent + "/") else { return .keep("not a BelloCode worktree") }
        if sharedByOtherThreads { return .keep("another thread uses it") }
        guard let contents = try? await contents(of: directory) else { return .keep("its state could not be read") }
        if !contents.isEmpty { return .keep("it has local files (\(contents.summary))") }
        let repository = GitRepository(directory: directory, runner: runner)
        guard let status = try? await repository.status(limit: 1) else { return .keep("its state could not be read") }
        if status.operation != nil { return .keep("a \(status.operation!.label.lowercased()) is in progress") }
        let merged = (try? await repository.git(["merge-base", "--is-ancestor", "HEAD", base], allowFailure: true).status) == 0
        if merged { return .remove }
        if status.branch == nil { return .keep("detached HEAD with unmerged commits") }
        if status.upstream != nil, status.ahead == 0 { return .remove }
        return .keep("it has commits that are not pushed or merged")
    }

    /// Test seams for handoff failures (run after the stash, and after the worktree is created).
    struct HandoffHooks: Sendable {
        var afterStash: (@Sendable () async -> Void)?
        var afterCreate: (@Sendable (String) async -> Void)?
        /// After the stash applied in the new worktree, before the result is verified.
        var beforeVerify: (@Sendable (String) async -> Void)?
        init(
            afterStash: (@Sendable () async -> Void)? = nil, afterCreate: (@Sendable (String) async -> Void)? = nil,
            beforeVerify: (@Sendable (String) async -> Void)? = nil
        ) {
            self.afterStash = afterStash
            self.afterCreate = afterCreate
            self.beforeVerify = beforeVerify
        }
    }

    /// Worktree handoff (T3 Code `t3_worktree_handoff`): moves the uncommitted work of `projectDirectory`'s checkout
    /// into a new worktree on a new branch from the current HEAD. The changes are stashed (untracked included, by
    /// hash) so the source is clean, the worktree is created, and the stash is applied there with its index (stashes
    /// are shared by a repository's worktrees). The index, the working files and the untracked files are each
    /// verified against the stash before anything that holds a copy is dropped (A04). An operation-specific ref keeps the stash commit reachable throughout.
    ///
    /// On failure the stash goes back to the source. The stash entry, the ref and the new worktree are removed only
    /// once that restore verifiably succeeded; otherwise everything is kept and `StashRecoveryError` says how to
    /// recover (R04). Returns the new worktree.
    public func handoff(from directory: String, branch: String, parent: String) async throws -> CreatedWorktree {
        try await handoff(from: directory, branch: branch, parent: parent, hooks: HandoffHooks())
    }

    func handoff(from directory: String, branch: String, parent: String, hooks: HandoffHooks) async throws -> CreatedWorktree {
        let source = GitRepository(directory: directory, runner: runner, writableRoots: [parent])
        guard let head = try await source.revParse("HEAD") else { throw WorktreeError.baseNotFound("HEAD") }
        guard let stash = try await source.stash(message: "bellocode: handoff to \(branch)") else {
            return try await create(WorktreeCreation(
                projectDirectory: directory, branch: branch, base: head, startFromOrigin: false, parentDirectory: parent, copyOnWrite: false))
        }
        let ref: String
        do {
            ref = try await source.keepRecoveryRef(stash)
        } catch {
            // Nothing else has happened yet: put the work back (the entry stays if that fails).
            if await source.restore(stash) == nil { try? await source.dropStash(stash) }
            throw error
        }
        await hooks.afterStash?()
        /// Puts the work back in the source. Cleans up (drop, ref, the new worktree) only after a verified restore.
        func giveBack(createdAt destination: String?, original: any Error) async -> any Error {
            if let failure = await source.restore(stash) {
                return StashRecoveryError(
                    stash: stash, ref: ref, directory: directory, keptWorktree: destination, unresolved: failure.unresolved, reason: failure.message)
            }
            if let destination {
                _ = try? await remove(directory: destination, projectDirectory: directory, deleteBranch: true, force: true)
            }
            try? await source.dropStash(stash)
            await source.deleteRecoveryRef(ref)
            return original
        }
        let created: CreatedWorktree
        do {
            created = try await create(WorktreeCreation(
                projectDirectory: directory, branch: branch, base: head, startFromOrigin: false, parentDirectory: parent, copyOnWrite: false))
        } catch {
            throw await giveBack(createdAt: nil, original: error)
        }
        await hooks.afterCreate?(created.directory)
        let destination = GitRepository(directory: created.directory, runner: runner)
        let verifyHook = hooks.beforeVerify.map { hook in { @Sendable in await hook(created.directory) } }
        if let failure = await destination.restore(stash, beforeVerify: verifyHook) {
            throw await giveBack(createdAt: created.directory, original: GitError.failed(command: "stash", status: 1, message: failure.message))
        }
        try? await source.dropStash(stash)
        await source.deleteRecoveryRef(ref)
        return created
    }
}
