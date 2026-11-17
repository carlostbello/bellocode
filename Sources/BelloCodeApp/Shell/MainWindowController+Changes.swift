import AppKit
import ComposerKit
import DiffKit
import Engine

/// M2-C: the Changes tab's commands (Changes menu, shortcuts) and the window's side of `ChangesShell`. Kept out of
/// MainWindowController.swift so concurrent shell work merges mechanically.
extension MainWindowController: ChangesShell {
    // MARK: ChangesShell

    var changesComposer: ComposerViewController? { container.composerController?.composer }
    var changesUndo: UndoCoordinator { workspace.undo }

    /// Shows the right panel on the Changes tab.
    func showChangesPanel() {
        if split.panelItem.isCollapsed {
            split.setCollapsed(split.panelItem, false)
        }
        rightPanel.select("changes")
        workspace.updateLayout(rightPanelTab: "changes")
    }

    // MARK: State for validation

    func changesCommandState() -> ChangesCommandState {
        var state = ChangesCommandState()
        guard let changes, let model = changes.model else { return state }
        let panel = changes.panel
        let options = panel.options
        state.available = true
        state.isRepository = model.repository.phase != .notRepository
        state.isDraft = container.context?.isDraft ?? false
        state.isWorktree = model.repository.workspaceKind == .worktree
        state.hasBranch = model.repository.status?.branch != nil
        state.hasHunks = panel.diff.rowCount > 0 && !model.diffFiles.allSatisfy(\.hunks.isEmpty)
        state.fileCount = model.diffFiles.count
        state.hasSelection = panel.diff.hasSelection
        let target = panel.targetFiles.first
        state.hasTargetFile = target != nil
        state.canRevertHunk = panel.diff.currentHunk.map { model.revertablePaths.contains($0.file.path) } ?? false
        state.revertFileTitle = target.flatMap { model.revertTitle(for: $0.path) }
        state.canRevertTurn = model.sessionID != nil && !(container.context?.thread?.isRunning ?? true)
        state.isSplit = options.layout == .split
        state.ignoresWhitespace = options.ignoreWhitespace
        state.wraps = options.wraps
        return state
    }

    // MARK: Commands

    func performChanges(_ command: ShellCommand) {
        guard let changes else { return NSSound.beep() }
        let panel = changes.panel
        switch command {
        case .showChanges:
            showChangesPanel()
            DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(panel.diff.focusView) }
        case .nextChange:
            showChangesPanel()
            panel.diff.nextHunk()
        case .previousChange:
            showChangesPanel()
            panel.diff.previousHunk()
        case .nextChangedFile:
            showChangesPanel()
            panel.diff.nextFile()
        case .previousChangedFile:
            showChangesPanel()
            panel.diff.previousFile()
        case .addReviewComment:
            panel.diff.beginComment()
        case .openInEditor:
            panel.openSelected(nil)
        case .revertHunk:
            panel.revertCurrentHunk(nil)
        case .revertFile:
            panel.revertSelectedFiles(nil)
        case .revertTurn:
            showChangesPanel()
            panel.revertTurn(nil)
        case .commitChanges:
            showChangesPanel()
            panel.beginCommit()
        case .pushBranch:
            panel.push(nil)
        case .createMergeRequest:
            panel.createMergeRequest(nil)
        case .toggleDiffLayout:
            panel.setLayout(panel.options.layout == .split ? .unified : .split)
            changes.saveOptions()
        case .toggleDiffWhitespace:
            panel.toggleWhitespace(nil)
            changes.saveOptions()
        case .toggleDiffWrap:
            panel.toggleWrap(nil)
            changes.saveOptions()
        case .chooseWorkspace:
            container.composerController?.openWorkspacePicker()
        case .chooseBranch:
            container.composerController?.openBranchPicker()
        case .removeWorktree:
            guard let context = container.context else { return }
            WorktreeRemoval.run(context: context, engine: workspace.engine, window: window, undo: workspace.undo)
        default:
            break
        }
    }

    @objc func showChanges(_ sender: Any?) { perform(.showChanges) }
    @objc func nextDiffHunk(_ sender: Any?) { perform(.nextChange) }
    @objc func previousDiffHunk(_ sender: Any?) { perform(.previousChange) }
    @objc func nextDiffFile(_ sender: Any?) { perform(.nextChangedFile) }
    @objc func previousDiffFile(_ sender: Any?) { perform(.previousChangedFile) }
    @objc func addDiffComment(_ sender: Any?) { perform(.addReviewComment) }
    @objc func openChangedFileInEditor(_ sender: Any?) { perform(.openInEditor) }
    @objc func revertDiffHunk(_ sender: Any?) { perform(.revertHunk) }
    @objc func revertChangedFile(_ sender: Any?) { perform(.revertFile) }
    @objc func revertTurnChanges(_ sender: Any?) { perform(.revertTurn) }
    @objc func commitChanges(_ sender: Any?) { perform(.commitChanges) }
    @objc func pushBranch(_ sender: Any?) { perform(.pushBranch) }
    @objc func createMergeRequest(_ sender: Any?) { perform(.createMergeRequest) }
    @objc func toggleDiffLayout(_ sender: Any?) { perform(.toggleDiffLayout) }
    @objc func toggleDiffWhitespace(_ sender: Any?) { perform(.toggleDiffWhitespace) }
    @objc func toggleDiffWrap(_ sender: Any?) { perform(.toggleDiffWrap) }
    @objc func chooseWorkspace(_ sender: Any?) { perform(.chooseWorkspace) }
    @objc func chooseBranch(_ sender: Any?) { perform(.chooseBranch) }
    @objc func removeWorktree(_ sender: Any?) { perform(.removeWorktree) }
}
