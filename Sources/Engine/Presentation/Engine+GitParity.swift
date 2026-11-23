import BelloCore
import Foundation
import OpenCodeKit

/// "Edit from here" (T3 Code composer.md): rewind the conversation to before a user message, optionally putting the
/// workspace files back to the checkpoint taken before that message (docs/features/git-parity.md rows 9–10).
public struct RewindPlan: Sendable {
    public var sessionID: SessionID
    public var messageID: MessageID
    public var directory: String
    /// The file restore, when asked for and possible.
    public var files: GitCheckpoints.RestorePlan?
    /// Why files cannot be restored (shown; the conversation can still be rewound).
    public var filesUnavailable: String?

    public init(sessionID: SessionID, messageID: MessageID, directory: String, files: GitCheckpoints.RestorePlan? = nil, filesUnavailable: String? = nil) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.directory = directory
        self.files = files
        self.filesUnavailable = filesUnavailable
    }
}

public struct AppliedRewind: Sendable {
    public var plan: RewindPlan
    /// Files written (Undo puts their earlier bytes back). Their paths are relative to `root`.
    public var written: [FileChangePlan]
    /// The working tree root the files were restored in (the file plan's, not the session directory: a session opened
    /// in a subdirectory restores, rolls back and undoes worktree-relative paths at the root, AF20).
    public var root: String
}

extension Engine {
    /// Installs the checkpoint capture before every new turn (called from `start`).
    func installCheckpoints() async {
        let runner = GitRunner()
        await core.setTurnWillStart { sessionID, messageID, directory in
            // Bounded: a slow capture (huge untracked files) must not hold the prompt for long.
            let capture = Task {
                try await GitCheckpoints.capture(directory: directory, ref: GitCheckpoints.ref(session: sessionID, message: messageID), runner: runner)
            }
            let watchdog = Task {
                try await Task.sleep(for: .seconds(10))
                capture.cancel()
            }
            _ = try? await capture.value
            watchdog.cancel()
        }
    }

    /// Other live threads working in the git working tree of `directory` (a file restore, which acts on the whole
    /// working tree, would erase their work, as in T3 Code's `isCheckpointRestoreIsolated`). Compared by canonical
    /// working tree root, the scope checkpoints are captured and restored in, not by directory strings: threads in
    /// sibling directories of one checkout share every checkpoint (AF19). A thread in a directory that contains the
    /// root counts too, and so does one whose root cannot be read (fail closed); a thread in a nested repository or
    /// worktree below the root does not. Outside a repository the directory itself stands for the root.
    ///
    /// Every unarchived session the engine knows is checked, in any project, not only the sidebar's top-level rows: a
    /// delegated child (sub-agent) whose parent is listed is not a row of its own but edits the same files (AF19). The
    /// rewound thread's own descendants are the one exception, and only when their work is part of what is rewound:
    /// created after the checkpoint (`rewoundSince`, by turns the rewind removes) and settled (idle, finished or
    /// failed). A descendant still working, waiting on the person, of unknown status, or that already existed before
    /// the checkpoint counts like any other thread, and so do the thread's ancestors.
    public func threadsSharingWorktree(of directory: String, except id: SessionID, rewoundSince: Timestamp? = nil) async -> [Session] {
        let runner = git.runner
        let real = HostGitPaths.real(await Self.worktreeRoot(of: directory, runner: runner) ?? directory)
        let (sessions, statuses) = await core.allSessions()
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let status = Dictionary(statuses.map { ($0.sessionID, $0.status) }, uniquingKeysWith: { first, _ in first })
        func descends(_ session: Session) -> Bool {
            var parent = session.parentID
            var seen: Set<SessionID> = []
            while let current = parent, seen.insert(current).inserted {
                if current == id { return true }
                parent = byID[current]?.parentID
            }
            return false
        }
        func partOfTheRewind(_ session: Session) -> Bool {
            guard let rewoundSince, session.created >= rewoundSince, descends(session) else { return false }
            return [.idle, .finishedUnread, .failed].contains(status[session.id])
        }
        var result: [Session] = []
        for session in sessions.sorted(by: { $0.id.rawValue < $1.id.rawValue })
        where session.id != id && !session.isArchived && !partOfTheRewind(session) {
            let other = HostGitPaths.real(session.directory)
            if other == real || real.hasPrefix(other + "/") {
                result.append(session)
            } else if other.hasPrefix(real + "/") {
                // Below the root: the same working tree unless it is a nested repository or worktree of its own.
                let otherRoot = await Self.worktreeRoot(of: session.directory, runner: runner)
                if otherRoot.map(HostGitPaths.real) ?? real == real { result.append(session) }
            }
        }
        return result
    }

    /// When `checkpoint` was captured, on the server's clock (sessions carry the server's times), rounded up to the
    /// next whole second (git records seconds): a session created in the capture's own second is treated as older
    /// than the checkpoint (fail closed). Nil when it cannot be read.
    func checkpointTime(_ checkpoint: String, directory: String) async -> Timestamp? {
        guard let output = try? await GitRepository(directory: directory, runner: git.runner).git(["log", "-1", "--format=%ct", checkpoint, "--"], allowFailure: true),
              output.status == 0, let seconds = Double(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return await core.serverTime(of: Date(timeIntervalSince1970: seconds + 1))
    }

    /// The working tree root of `directory` (nil outside a repository or when it cannot be read).
    static func worktreeRoot(of directory: String, runner: GitRunner) async -> String? {
        try? await GitRepository(directory: directory, runner: runner).location()?.root
    }

    static func sharedWorktreeMessage(_ count: Int) -> String {
        "Files can only be restored in a worktree no other thread uses (\(count) other thread\(count == 1 ? "" : "s") work here)."
    }

    /// Plans a rewind. With `revertFiles`, the checkpoint taken before `messageID` is planned for restore unless the
    /// directory is shared with another thread, is the project's main checkout, or no checkpoint exists.
    public func planRewind(_ id: SessionID, to messageID: MessageID, directory: String, revertFiles: Bool) async throws -> RewindPlan {
        var plan = RewindPlan(sessionID: id, messageID: messageID, directory: directory)
        guard revertFiles else { return plan }
        let runner = git.runner
        let ref = GitCheckpoints.ref(session: id, message: messageID)
        let checkpoint = await GitCheckpoints.resolve(ref, directory: directory, runner: runner)
        let since = if let checkpoint { await checkpointTime(checkpoint, directory: directory) } else { Timestamp?.none }
        let shared = await threadsSharingWorktree(of: directory, except: id, rewoundSince: since)
        if !shared.isEmpty {
            plan.filesUnavailable = Self.sharedWorktreeMessage(shared.count)
            return plan
        }
        guard let checkpoint else {
            plan.filesUnavailable = "No checkpoint was saved before this message, so files cannot be restored."
            return plan
        }
        do {
            plan.files = try await GitCheckpoints.planRestore(
                directory: directory, checkpoint: checkpoint, undoRef: GitCheckpoints.ref(session: id, message: MessageID(rawValue: "undo-" + messageID.rawValue)),
                runner: runner)
        } catch let error as GitCheckpoints.RestoreError {
            // Never a partial plan: files are not restored and the sheet says why before anything is rewound (R26).
            plan.filesUnavailable = error.userMessage
        }
        return plan
    }

    /// Restores the files (all or nothing; fails without touching the conversation when a file changed meanwhile),
    /// then rewinds the conversation through opencode (`revert.stage files:false` + `revert.commit`). If opencode
    /// refuses, the files are put back. Isolation is checked again just before the files are written: a thread that
    /// started working in the same worktree since the plan refuses the rewind with nothing changed (AF19).
    public func rewind(_ plan: RewindPlan) async throws -> AppliedRewind {
        var written: [FileChangePlan] = []
        let root = plan.files?.directory ?? plan.directory
        if let files = plan.files {
            let since = await checkpointTime(files.checkpoint, directory: files.directory)
            let shared = await threadsSharingWorktree(of: files.directory, except: plan.sessionID, rewoundSince: since)
            guard shared.isEmpty else {
                throw GitError.failed(command: "rewind", status: 1, message: Self.sharedWorktreeMessage(shared.count) + " Nothing was rewound.")
            }
            written = try await GitCheckpoints.apply(files)
        }
        var staged = false
        do {
            let client = try await core.currentClient()
            _ = try await client.stageRevert(sessionID: plan.sessionID.rawValue, messageID: plan.messageID.rawValue, files: false)
            staged = true
            try await client.commitRevert(sessionID: plan.sessionID.rawValue)
        } catch {
            // Never leave a half-applied rewind silently: the staged revert is cleared and the files are put back, and
            // a step of that which fails is part of the error (N17).
            var revertStillStaged = false
            if staged {
                do { try await core.currentClient().clearRevert(sessionID: plan.sessionID.rawValue) } catch { revertStillStaged = true }
            }
            var filesKept: String?
            if !written.isEmpty {
                do { try await GitCheckpoints.undo(written, directory: root) } catch {
                    filesKept = (error as? WorkingCopyError)?.userMessage ?? String(describing: error)
                }
            }
            git.refreshAll(under: root)
            if revertStillStaged || filesKept != nil {
                throw RewindRollbackError(reason: String(describing: error), revertStillStaged: revertStillStaged, filesNotRestored: filesKept)
            }
            throw error
        }
        git.refreshAll(under: root)
        return AppliedRewind(plan: plan, written: written, root: root)
    }

    /// Undo for the files of a rewind (the conversation rewind itself is permanent in opencode), at the root they were
    /// restored in. Throws `WorkingCopyError` naming the path when a file changed since (nothing is overwritten).
    public func undoRewindFiles(_ applied: AppliedRewind) async throws {
        defer { git.refreshAll(under: applied.root) }
        try await GitCheckpoints.undo(applied.written, directory: applied.root)
    }
}

/// A rewind that failed and could not be fully rolled back: what is left over is named.
public struct RewindRollbackError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// Why the rewind failed.
    public var reason: String
    /// opencode still holds the staged revert (clearing it failed; the conversation shows the revert pending).
    public var revertStillStaged: Bool
    /// The files were restored but could not be put back (why), so they no longer match the conversation.
    public var filesNotRestored: String?

    public var description: String {
        var parts = ["The rewind failed (\(reason))."]
        if revertStillStaged { parts.append("The revert is still staged in the conversation.") }
        if let filesNotRestored { parts.append("The restored files were not put back: \(filesNotRestored)") }
        return parts.joined(separator: " ")
    }

    public var errorDescription: String? { description }
}

enum HostGitPaths {
    static func real(_ path: String) -> String { URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path }
}

extension Engine {
    public enum WorktreeCleanupTrigger: Sendable { case settled, archived }

    /// Applies the project's cleanup policy to the worktree of thread `id` after it was settled or archived. Removes
    /// only clean worktrees whose work is pushed or merged (`WorktreeService.cleanupVerdict`); the removal can be
    /// undone like a manual one. Returns the removal (for an Undo toast) or nil when kept.
    public func cleanupWorktree(of session: Session, projectDirectory: String, trigger: WorktreeCleanupTrigger) async -> RemovedWorktree? {
        let preferences = await git.preferences(projectDirectory: projectDirectory)
        guard let policy = preferences.cleanup, trigger == .settled ? policy.afterSettle : policy.afterArchive else { return nil }
        guard HostGitPaths.real(session.directory) != HostGitPaths.real(projectDirectory) else { return nil }
        let base = git.repository(for: projectDirectory).baseBranch ?? "main"
        let verdict = await git.worktrees.cleanupVerdict(
            directory: session.directory, projectDirectory: projectDirectory, parent: preferences.parentDirectory(projectDirectory: projectDirectory),
            base: base, sharedByOtherThreads: !(await threadsSharingWorktree(of: session.directory, except: session.id)).isEmpty)
        guard verdict == .remove else { return nil }
        return try? await git.removeWorktree(
            directory: session.directory, projectDirectory: projectDirectory, projectID: session.projectID, deleteBranch: false, force: false)
    }
}

extension Engine {
    /// T3 Code "worktree branch naming": the thread's model proposes a branch name from the first prompt; the
    /// temporary slug branch is renamed only if it has no upstream yet and the proposal is valid and unused.
    /// Returns the new name, or nil when the slug stays.
    @discardableResult
    public func renameGeneratedBranch(_ id: SessionID, created: CreatedWorktree, firstPrompt: String) async -> String? {
        // The temporary name is `<prefix><slug>`; the proposal keeps the same prefix.
        let prefix = created.branch.lastIndex(of: "/").map { String(created.branch[...$0]) } ?? ""
        guard let reply = try? await generateText(in: id, prompt: GitTextGeneration.branchPrompt(firstPrompt: firstPrompt, prefix: prefix), task: "Branch name"),
              let proposal = GitTextGeneration.branchName(from: reply, prefix: prefix), proposal != created.branch
        else { return nil }
        let repository = GitRepository(directory: created.directory, runner: git.runner)
        guard let status = try? await repository.status(limit: 1), status.branch == created.branch, status.upstream == nil,
              (try? await repository.resolves("refs/heads/\(proposal)")) == false
        else { return nil }
        guard (try? await repository.git(["branch", "-m", created.branch, proposal])) != nil else { return nil }
        git.refreshAll(under: created.directory)
        return proposal
    }
}
