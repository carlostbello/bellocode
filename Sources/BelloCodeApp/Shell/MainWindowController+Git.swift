import AppKit
import BelloCore
import DiffKit
import Engine
import SwiftUI

/// Git parity: per-window git surfaces (docs/features/git-parity.md). Models are kept per directory (bounded), so
/// switching threads shows cached state at once.
@MainActor
final class GitUIState {
    var models: [String: GitActionsModel] = [:]
    var order: [String] = []
    weak var popover: NSPopover?
    weak var panel: NSPanel?
    /// The one watch on a commit form opening (replaced each time the Git Actions popover opens).
    let commitWatch = CommitFormWatch()
    static let limit = 16
}

/// Opens the commit form when a Git Actions model's `commit` is set. At most one watch is live: starting another
/// retires the previous one, so opening the popover N times never shows (and generates for) one form N times (NF19).
@MainActor
final class CommitFormWatch {
    private var generation = 0

    /// Watches `model.commit` until a form opens (then `show` runs once), replacing any earlier watch.
    func watch(_ model: GitActionsModel, show: @escaping @MainActor (GitActionsModel) -> Void) {
        generation += 1
        arm(model, generation: generation, show: show)
    }

    func cancel() { generation += 1 }

    private func arm(_ model: GitActionsModel, generation: Int, show: @escaping @MainActor (GitActionsModel) -> Void) {
        withObservationTracking { _ = model.commit } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model, self.generation == generation else { return }
                if model.commit != nil { show(model) } else { self.arm(model, generation: generation, show: show) }
            }
        }
    }
}

extension MainWindowController {
    /// The directory git acts on: the displayed thread's checkout, or the draft's project.
    var gitDirectory: String? {
        guard let context = container.context else { return nil }
        return context.directory.isEmpty ? context.projectDirectory : context.directory
    }

    func gitActionsModel() -> GitActionsModel? {
        guard let directory = gitDirectory else { return nil }
        let repository = workspace.engine.git.repository(for: directory)
        if let model = gitUI.models[directory] {
            model.host = gitHost()
            return model
        }
        let model = GitActionsModel(repository: repository, host: gitHost())
        gitUI.models[directory] = model
        gitUI.order.append(directory)
        if gitUI.order.count > GitUIState.limit { gitUI.models[gitUI.order.removeFirst()] = nil }
        Task { await model.reload() }
        return model
    }

    func gitHost() -> GitActionHost {
        let engine = workspace.engine
        var generate: (@MainActor (String) async throws -> String)?
        if let id = container.context?.thread?.sessionID {
            generate = { prompt in try await engine.generateText(in: id, prompt: prompt, task: "Commit message") }
        }
        let create: @MainActor () -> Void = { [weak self] in self?.perform(.createMergeRequest) }
        let open: @MainActor () -> Void = { [weak self] in self?.perform(.showMergeRequests) }
        let confirm: @MainActor (String, String, String) async -> Bool = { [weak self] title, detail, button in
            guard let self else { return false }
            return await self.confirmGit(title, detail, button)
        }
        let notice: @MainActor (String) -> Void = { [weak self] text in self?.workspace.undo.showNotice(text) }
        let publish: @MainActor () -> Void = { [weak self] in self?.presentPublish() }
        return GitActionHost(createMergeRequest: create, openMergeRequest: open, generate: generate, confirm: confirm, notice: notice, publish: publish)
    }

    /// Updates the header's quick-action button from the planner; returns true when its size may have changed.
    func updateGitHeader(_ repository: GitRepositoryModel) -> Bool {
        guard let model = gitActionsModel() else { return false }
        let quick = model.quickAction
        let old = header.commitButton.title
        let changed = repository.status?.files.count ?? 0
        header.commitButton.title = quick.label
        header.commitButton.symbolName = quick.action?.symbolName ?? "arrow.triangle.branch"
        header.commitButton.isEnabled = quick.isEnabled
        header.commitButton.toolTip = quick.hint ?? "\(quick.action?.title ?? quick.label) (⌃⌘↩)"
        header.commitButton.accessibilityTitle = quick.label + (changed > 0 ? ", \(changed) changed file\(changed == 1 ? "" : "s")" : "")
            + (quick.hint.map { ". \($0)" } ?? "")
        _ = model.hasOpenMergeRequest
        if let id = container.context?.thread?.sessionID, let service = workspace.engine.extras?.mergeRequests {
            let open = service.links(for: id).contains { service.snapshots[$0.ref.url]?.state == .opened }
            if model.hasOpenMergeRequest != open { model.hasOpenMergeRequest = open }
        }
        return old != quick.label
    }

    func gitCommandState() -> GitCommandState {
        var state = GitCommandState()
        state.autoPull = workspace.engine.git.autoPullDefaultBranch
        guard let model = gitActionsModel(), model.repository.phase != .notRepository else { return state }
        state.isRepository = true
        let quick = model.quickAction
        state.quickAction = quick.action
        state.quickTitle = quick.action?.shortTitle
        state.quickHint = quick.hint
        let map: [GitAction: ShellCommand] = [
            .commitAndPush: .commitAndPush, .pull: .pullBranch, .pullRebase: .pullRebase, .fetch: .fetchRemote, .sync: .syncBranch,
            .publish: .publishToGitLab, .switchRemoteToHTTPS: .switchRemoteToHTTPS, .abortOperation: .abortGitOperation,
        ]
        for item in model.items {
            if item.isEnabled { state.enabled.insert(item.action) }
            if let command = map[item.action], let reason = item.disabledReason { state.reasons[command.rawValue] = reason }
        }
        state.hasParkedStash = model.repository.parkedStashForCurrentBranch != nil
        state.canHandoff = model.repository.workspaceKind == .mainCheckout && (model.repository.status?.isDirty ?? false) && model.repository.activity == nil
        if let thread = container.context?.thread, !thread.isRunning {
            state.canRewind = thread.messageIDs.contains { thread.message($0)?.message.kind.typeName == "user" }
        }
        if let project = container.context?.projectDirectory {
            let preferences = workspace.engine.git.cachedPreferences(projectDirectory: project)
            state.cleanupOnSettle = preferences.cleanup?.afterSettle ?? false
            state.cleanupOnArchive = preferences.cleanup?.afterArchive ?? false
        }
        return state
    }

    // MARK: Commands

    func performGit(_ command: ShellCommand) {
        let model = gitActionsModel()
        switch command {
        case .gitQuickAction:
            guard let model, let action = model.quickAction.action else { return NSSound.beep() }
            run(action, model)
        case .showGitActions:
            guard let model else { return NSSound.beep() }
            showGitPopover(GitActionsMenuView(model: model, close: { [weak self] in self?.closeGitPopover() }))
            observeCommitForm(model)
        case .commitAndPush: model.map { run(.commitAndPush, $0) }
        case .pushBranch: model.map { run(.push, $0) }
        case .pullBranch: model.map { run(.pull, $0) }
        case .pullRebase: model.map { run(.pullRebase, $0) }
        case .fetchRemote: model.map { run(.fetch, $0) }
        case .syncBranch: model.map { run(.sync, $0) }
        case .publishToGitLab: presentPublish()
        case .switchRemoteToHTTPS: model.map { run(.switchRemoteToHTTPS, $0) }
        case .abortGitOperation: model.map { run(.abortOperation, $0) }
        case .restoreStashedChanges:
            guard let model, let hash = model.repository.parkedStashForCurrentBranch else { return NSSound.beep() }
            Task {
                do {
                    try await model.repository.restoreStash(hash)
                    workspace.undo.showNotice("Restored the stashed changes")
                } catch let recovery as StashRecoveryError {
                    // The recovery steps stay on screen: the work is only in the stash until it is put back (R04).
                    presentStashRecovery(recovery)
                } catch {
                    workspace.undo.showNotice((error as? GitError)?.userMessage ?? "The stash could not be applied; it is still in git stash list.")
                }
            }
        case .cloneFromGitLab: presentClone()
        case .newGitProject: presentNewProject()
        case .moveToNewWorktree: presentHandoff()
        case .editFromHere: presentRewind()
        case .toggleAutoPull: workspace.engine.git.autoPullDefaultBranch.toggle()
        case .toggleCleanupOnSettle, .toggleCleanupOnArchive:
            guard let project = container.context?.projectDirectory else { return }
            let git = workspace.engine.git
            Task {
                var preferences = await git.preferences(projectDirectory: project)
                var policy = preferences.cleanup ?? WorktreeCleanupPolicy()
                if command == .toggleCleanupOnSettle { policy.afterSettle.toggle() } else { policy.afterArchive.toggle() }
                preferences.cleanup = policy
                await git.setPreferences(preferences, projectDirectory: project)
            }
        default: break
        }
    }

    /// Commit actions open the commit form in the popover; the rest run at once.
    func run(_ action: GitAction, _ model: GitActionsModel) {
        Task {
            await model.perform(action)
            if model.commit != nil { showCommitForm(model) }
        }
    }

    func observeCommitForm(_ model: GitActionsModel) {
        gitUI.commitWatch.watch(model) { [weak self] model in self?.showCommitForm(model) }
    }

    func showCommitForm(_ model: GitActionsModel) {
        guard let form = model.commit else { return }
        showGitPopover(GitCommitView(form: form, actions: model, close: { [weak self, weak model] in
            model?.commit = nil
            self?.closeGitPopover()
        }))
    }

    // MARK: Presentation

    func showGitPopover(_ view: some View) {
        closeGitPopover()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let host = NSHostingController(rootView: AnyView(view))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        let anchor: NSView = header.commitButton.isHidden ? header : header.commitButton
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        gitUI.popover = popover
    }

    func closeGitPopover() {
        gitUI.popover?.close()
        gitUI.popover = nil
    }

    /// A floating panel for the larger forms (clone, publish, rewind): not a sheet, closed with Escape.
    func showGitPanel(_ view: some View, title: String) {
        gitUI.panel?.close()
        let host = NSHostingController(rootView: AnyView(view))
        host.sizingOptions = [.preferredContentSize]
        let panel = NSPanel(contentViewController: host)
        panel.title = title
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        if let window { panel.setFrameOrigin(NSPoint(x: window.frame.midX - 260, y: window.frame.midY - 120)) }
        panel.makeKeyAndOrderFront(nil)
        gitUI.panel = panel
    }

    func closeGitPanel() {
        gitUI.panel?.close()
        gitUI.panel = nil
    }

    /// Confirmation for what cannot be undone (push to the default branch, force push, abort): an alert on the window.
    func confirmGit(_ title: String, _ detail: String, _ button: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard let window else { return alert.runModal() == .alertFirstButtonReturn }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    /// Stashed work that could not be put back: the recovery steps stay on screen until dismissed, and can be copied.
    func presentStashRecovery(_ recovery: StashRecoveryError) {
        let alert = NSAlert()
        alert.messageText = recovery.userMessage
        alert.informativeText = recovery.instructions
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Instructions")
        alert.alertStyle = .critical
        let copy = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(recovery.instructions, forType: .string)
        }
        guard let window else {
            if alert.runModal() == .alertSecondButtonReturn { copy() }
            return
        }
        alert.beginSheetModal(for: window) { if $0 == .alertSecondButtonReturn { copy() } }
    }

    // MARK: Clone, publish, new project

    func presentClone() {
        let engine = workspace.engine
        let instances = engine.extras?.mergeRequests.instances ?? []
        let model = GitCloneModel(
            instances: instances, search: { instance, query in try await engine.gitProjects.searchProjects(instance, search: query) },
            start: { [weak self] url, destination in
                let job = try engine.gitProjects.clone(url: url, into: destination)
                self?.workspace.undo.showNotice("Cloning \(job.name)…")
                self?.watchClone(job)
            })
        showGitPanel(GitCloneView(model: model, close: { [weak self] _ in self?.closeGitPanel() }), title: "Clone from GitLab")
    }

    /// When the clone finishes, opens a new thread draft in it (the person may have started typing in the sidebar's
    /// draft meanwhile; sending there waits on the job, see `ComposerSurface`).
    func watchClone(_ job: GitCloneJob) {
        Task { [weak self] in
            await job.waitUntilDone()
            guard let self else { return }
            switch job.state {
            case .finished:
                self.workspace.undo.showNotice("Cloned \(job.name)")
                self.workspace.newThread(in: job.destination)
            case .failed(let message): self.workspace.undo.showNotice("Clone failed: \(message)")
            case .cancelled: self.workspace.undo.showNotice("Clone cancelled")
            case .cloning: break
            }
        }
    }

    func presentPublish() {
        guard let directory = gitDirectory else { return NSSound.beep() }
        let engine = workspace.engine
        let instances = engine.extras?.mergeRequests.instances ?? []
        let provider = engine.extras?.mergeRequests
        let model = GitPublishModel(
            instances: instances, directory: directory,
            loadNamespaces: { instance in try await provider?.namespaces(instance) ?? [] },
            publish: { instance, name, path, namespace in
                try await engine.gitProjects.publish(directory: directory, instance: instance, name: name, path: path, namespaceID: namespace)
            })
        showGitPanel(GitPublishView(model: model, close: { [weak self] done in
            if done, let url = model.published?.webURL { self?.workspace.undo.showNotice("Published to \(url)") }
            self?.closeGitPanel()
        }), title: "Publish to GitLab")
    }

    func presentNewProject() {
        let alert = NSAlert()
        alert.messageText = "New Project"
        alert.informativeText = "A folder in ~/BelloCode/Projects with git, a README and a first commit."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Project name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let parent = (NSHomeDirectory() as NSString).appendingPathComponent("BelloCode/Projects")
        let engine = workspace.engine
        Task {
            do {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                let directory = try await engine.gitProjects.createProject(named: name, in: parent)
                workspace.newThread(in: directory)
            } catch {
                workspace.undo.showNotice((error as? GitError)?.userMessage ?? "The project could not be created.")
            }
        }
    }

    // MARK: Handoff and rewind

    /// Moves the local checkout's uncommitted changes into a new worktree on a new branch and opens a thread there.
    func presentHandoff() {
        guard let context = container.context, let directory = gitDirectory else { return }
        let engine = workspace.engine
        let project = context.projectDirectory
        let title = context.thread?.session?.displayTitle ?? "changes"
        Task {
            let preferences = await engine.git.preferences(projectDirectory: project)
            do {
                let branch = try await engine.git.worktrees.uniqueBranchName(WorktreeService.slug(title, prefix: preferences.branchPrefix), in: project)
                guard await confirmGit(
                    "Move changes to a new worktree?", "Your uncommitted changes move to a new worktree on \(branch); this checkout becomes clean. If anything fails, the changes stay here.",
                    "Move Changes")
                else { return }
                let created = try await engine.git.worktrees.handoff(from: directory, branch: branch, parent: preferences.parentDirectory(projectDirectory: project))
                engine.git.refreshAll(under: project)
                do {
                    try await workspace.startThread(inWorktree: created.directory, title: created.branch)
                    workspace.undo.showNotice("Moved changes to \(created.branch)")
                } catch {
                    // The changes are safely in the worktree; only the thread is missing.
                    workspace.undo.showNotice("Moved changes to \(created.branch) at \(created.directory), but no thread could be opened there: \(error.localizedDescription)")
                }
            } catch let recovery as StashRecoveryError {
                // Never a transient notice: the work is only in the stash until the person restores it (R04).
                engine.git.refreshAll(under: project)
                presentStashRecovery(recovery)
            } catch {
                workspace.undo.showNotice((error as? GitError)?.userMessage ?? (error as? WorktreeError)?.userMessage ?? "The changes could not be moved.")
            }
        }
    }

    /// Edit Last Prompt from Here: rewinds to before the thread's last user message, optionally restoring files.
    func presentRewind() {
        guard let thread = container.context?.thread, let directory = gitDirectory else { return }
        let messages = thread.messageIDs.compactMap { thread.message($0)?.message }.filter { $0.kind.typeName == "user" }
        guard let last = messages.last, case .user(let content) = last.kind else { return NSSound.beep() }
        let engine = workspace.engine
        let id = thread.sessionID
        let model = RewindModel(
            prompt: content.text,
            plan: { revert in try await engine.planRewind(id, to: last.id, directory: directory, revertFiles: revert) },
            perform: { [weak self] plan in
                let applied = try await engine.rewind(plan)
                self?.placeRewoundPrompt(content.text, thread: id)
                if !applied.written.isEmpty {
                    _ = self?.workspace.undo.perform(ReversibleAction(
                        name: "Restore Files", message: "Restored \(applied.written.count) file\(applied.written.count == 1 ? "" : "s") to the checkpoint",
                        apply: {}, revert: { [weak self] in
                            Task {
                                await Self.undoRewindFiles(applied, undo: { try await engine.undoRewindFiles($0) }, notice: { self?.workspace.undo.showNotice($0) })
                            }
                        }))
                }
            })
        showGitPanel(RewindView(model: model, close: { [weak self] _ in self?.closeGitPanel() }), title: "Edit from Here")
    }

    /// The rewound prompt goes back to its own thread (NV09): into the visible composer while the window still shows
    /// that thread, else into that thread's draft (in front of what is there), never into another thread's composer.
    func placeRewoundPrompt(_ text: String, thread id: SessionID) {
        if container.context?.thread?.sessionID == id, let composer = changesComposer {
            composer.insert(text: text)
            return
        }
        let thread = workspace.engine.openThread(id)
        thread.draft = thread.draft.isEmpty ? text : text + "\n\n" + thread.draft
        thread.close()
    }

    /// Undo of a rewind's file restore. A failure (a restored file changed since, so nothing is overwritten, or a
    /// write error) is shown with the affected path, never swallowed (NF12).
    static func undoRewindFiles(
        _ applied: AppliedRewind, undo: @MainActor (AppliedRewind) async throws -> Void, notice: @MainActor (String) -> Void
    ) async {
        do {
            try await undo(applied)
        } catch {
            let reason = (error as? WorkingCopyError)?.userMessage ?? (error as? GitError)?.userMessage ?? String(describing: error)
            notice("Could not undo the file restore: \(reason)")
        }
    }

    // MARK: Actions

    @objc func gitQuickAction(_ sender: Any?) { perform(.gitQuickAction) }
    @objc func showGitActions(_ sender: Any?) { perform(.showGitActions) }
    @objc func commitAndPush(_ sender: Any?) { perform(.commitAndPush) }
    @objc func pullBranch(_ sender: Any?) { perform(.pullBranch) }
    @objc func pullRebase(_ sender: Any?) { perform(.pullRebase) }
    @objc func fetchRemote(_ sender: Any?) { perform(.fetchRemote) }
    @objc func syncBranch(_ sender: Any?) { perform(.syncBranch) }
    @objc func publishToGitLab(_ sender: Any?) { perform(.publishToGitLab) }
    @objc func switchRemoteToHTTPS(_ sender: Any?) { perform(.switchRemoteToHTTPS) }
    @objc func abortGitOperation(_ sender: Any?) { perform(.abortGitOperation) }
    @objc func restoreStashedChanges(_ sender: Any?) { perform(.restoreStashedChanges) }
    @objc func cloneFromGitLab(_ sender: Any?) { perform(.cloneFromGitLab) }
    @objc func newGitProject(_ sender: Any?) { perform(.newGitProject) }
    @objc func moveToNewWorktree(_ sender: Any?) { perform(.moveToNewWorktree) }
    @objc func editFromHere(_ sender: Any?) { perform(.editFromHere) }
    @objc func toggleAutoPull(_ sender: Any?) { perform(.toggleAutoPull) }
    @objc func toggleCleanupOnSettle(_ sender: Any?) { perform(.toggleCleanupOnSettle) }
    @objc func toggleCleanupOnArchive(_ sender: Any?) { perform(.toggleCleanupOnArchive) }
}
