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

    /// Worktree handoff (T3 Code `t3_worktree_handoff`): moves the uncommitted work of `projectDirectory`'s checkout
    /// into a new worktree on a new branch from the current HEAD. The changes are stashed (untracked included, by
    /// hash) so the source is clean, the worktree is created, and the stash is applied there (stashes are shared by
    /// a repository's worktrees). On any failure the stash goes back to the source and the worktree is removed;
    /// nothing is lost. Returns the new worktree.
    public func handoff(from directory: String, branch: String, parent: String) async throws -> CreatedWorktree {
        let source = GitRepository(directory: directory, runner: runner, writableRoots: [parent])
        guard let head = try await source.revParse("HEAD") else { throw WorktreeError.baseNotFound("HEAD") }
        let stash = try await source.stash(message: "bellocode: handoff to \(branch)")
        func giveBack() async {
            if let stash {
                _ = try? await source.applyStash(stash)
                _ = try? await source.dropStash(stash)
            }
        }
        let created: CreatedWorktree
        do {
            created = try await create(WorktreeCreation(
                projectDirectory: directory, branch: branch, base: head, startFromOrigin: false, parentDirectory: parent, copyOnWrite: false))
        } catch {
            await giveBack()
            throw error
        }
        guard let stash else { return created }
        do {
            try await GitRepository(directory: created.directory, runner: runner).applyStash(stash)
            try await source.dropStash(stash)
        } catch {
            _ = try? await remove(directory: created.directory, projectDirectory: directory, deleteBranch: true, force: true)
            await giveBack()
            throw error
        }
        return created
    }
}
