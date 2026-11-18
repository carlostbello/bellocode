import BelloCore
import Engine
import Foundation

// Git parity: worktree cleanup policies (T3 Code Settings ▸ Worktrees ▸ Cleanup), applied after settle and archive.
extension WorkspaceController {
    /// Removes the clean, pushed-or-merged worktrees of `ids` when the project's policy says so; each removal gets its
    /// own Undo toast (the worktree and branch come back).
    func applyWorktreeCleanup(_ ids: [SessionID], trigger: Engine.WorktreeCleanupTrigger) {
        let engine = self.engine
        for id in ids {
            guard let session = session(id),
                  let project = engine.root.projects.first(where: { $0.projectID == session.projectID })?.directory
            else { continue }
            Task { [weak self] in
                guard let removed = await engine.cleanupWorktree(of: session, projectDirectory: project, trigger: trigger) else { return }
                var restored = true
                _ = self?.undo.perform(ReversibleAction(
                    name: "Remove Worktree", message: "Removed the clean worktree \(removed.branch ?? (removed.directory as NSString).lastPathComponent)",
                    apply: {
                        guard !restored else { restored = false; return }
                        Task { _ = try? await engine.git.removeWorktree(directory: removed.directory, projectDirectory: project, projectID: session.projectID, deleteBranch: false, force: false) }
                    },
                    revert: {
                        restored = true
                        Task { try? await engine.git.restoreWorktree(removed, projectID: session.projectID) }
                    }))
            }
        }
    }
}
