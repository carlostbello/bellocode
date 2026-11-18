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
    /// Files written (Undo puts their earlier bytes back).
    public var written: [FileChangePlan]
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

    /// Other live threads whose directory is this one, inside it, or contains it (a file restore would erase their
    /// work, as in T3 Code's `isCheckpointRestoreIsolated`).
    public func threadsSharing(directory: String, except id: SessionID) -> [Session] {
        let real = HostGitPaths.real(directory)
        var result: [Session] = []
        for project in root.loadedProjects {
            for sessionID in project.sessionIDs where sessionID != id {
                guard let session = project.row(sessionID)?.session else { continue }
                let other = HostGitPaths.real(session.directory)
                if other == real || other.hasPrefix(real + "/") || real.hasPrefix(other + "/") { result.append(session) }
            }
        }
        return result
    }

    /// Plans a rewind. With `revertFiles`, the checkpoint taken before `messageID` is planned for restore unless the
    /// directory is shared with another thread, is the project's main checkout, or no checkpoint exists.
    public func planRewind(_ id: SessionID, to messageID: MessageID, directory: String, revertFiles: Bool) async throws -> RewindPlan {
        var plan = RewindPlan(sessionID: id, messageID: messageID, directory: directory)
        guard revertFiles else { return plan }
        let shared = threadsSharing(directory: directory, except: id)
        if !shared.isEmpty {
            plan.filesUnavailable = "Files can only be restored in a worktree no other thread uses (\(shared.count) other thread\(shared.count == 1 ? "" : "s") work here)."
            return plan
        }
        let runner = git.runner
        let ref = GitCheckpoints.ref(session: id, message: messageID)
        guard let checkpoint = await GitCheckpoints.resolve(ref, directory: directory, runner: runner) else {
            plan.filesUnavailable = "No checkpoint was saved before this message, so files cannot be restored."
            return plan
        }
        plan.files = try await GitCheckpoints.planRestore(
            directory: directory, checkpoint: checkpoint, undoRef: GitCheckpoints.ref(session: id, message: MessageID(rawValue: "undo-" + messageID.rawValue)),
            runner: runner)
        return plan
    }

    /// Restores the files (all or nothing; fails without touching the conversation when a file changed meanwhile),
    /// then rewinds the conversation through opencode (`revert.stage files:false` + `revert.commit`). If opencode
    /// refuses, the files are put back.
    public func rewind(_ plan: RewindPlan) async throws -> AppliedRewind {
        var written: [FileChangePlan] = []
        if let files = plan.files { written = try await GitCheckpoints.apply(files) }
        do {
            let client = try await core.currentClient()
            _ = try await client.stageRevert(sessionID: plan.sessionID.rawValue, messageID: plan.messageID.rawValue, files: false)
            try await client.commitRevert(sessionID: plan.sessionID.rawValue)
        } catch {
            if !written.isEmpty { try? await GitCheckpoints.undo(written, directory: plan.directory) }
            git.refreshAll(under: plan.directory)
            throw error
        }
        git.refreshAll(under: plan.directory)
        return AppliedRewind(plan: plan, written: written)
    }

    /// Undo for the files of a rewind (the conversation rewind itself is permanent in opencode).
    public func undoRewindFiles(_ applied: AppliedRewind) async throws {
        try await GitCheckpoints.undo(applied.written, directory: applied.plan.directory)
        git.refreshAll(under: applied.plan.directory)
    }
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
            base: base, sharedByOtherThreads: !threadsSharing(directory: session.directory, except: session.id).isEmpty)
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
        guard let reply = try? await generateText(in: id, prompt: GitTextGeneration.branchPrompt(firstPrompt: firstPrompt, prefix: prefix)),
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
