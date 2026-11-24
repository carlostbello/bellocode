import AppKit
import BelloCore
import ComposerKit
import DiffKit
import Engine

/// What the Changes tab needs from the window: the composer for review comments, the undo coordinator, and a way to
/// show the panel.
@MainActor
protocol ChangesShell: AnyObject {
    var changesComposer: ComposerViewController? { get }
    var changesUndo: UndoCoordinator { get }
    func showChangesPanel()
}

/// The window's "Changes" tab (DiffKit): one panel following the displayed thread or draft, with a cached model per
/// thread (bounded) so switching back shows the last loaded changes at once while they refresh. Created by
/// `ShellSurfaces.builtIn` and bound by `MainWindowController`.
///
/// After each turn of the displayed thread (running → idle) the repository status and the scope reload.
@MainActor
final class ChangesSurfaces: ChangesPanelHost {
    static let modelLimit = 16
    static let optionsKey = "BelloCodeDiffOptions"

    let services: AppServices
    let panel = ChangesPanelController()
    private(set) var engine: Engine?
    private weak var shell: (any ChangesShell)?
    private(set) var context: ThreadSurfaceContext?
    private var models: [String: ChangesModel] = [:]
    private var recency: [String] = []
    private var turnLoop: ObservationLoop?
    private var wasRunning = false

    init(services: AppServices) {
        self.services = services
        panel.host = self
        if let data = UserDefaults.standard.data(forKey: Self.optionsKey), let options = try? JSONDecoder().decode(DiffViewOptions.self, from: data) {
            panel.options = options
        }
    }

    func makeController() -> NSViewController { panel }

    func bind(engine: Engine, shell: any ChangesShell) {
        self.shell = shell
        guard self.engine == nil else { return }
        self.engine = engine
        display(context)
    }

    /// Shows the changes of the displayed thread (or the draft's project).
    func display(_ context: ThreadSurfaceContext?) {
        self.context = context
        turnLoop?.cancel()
        turnLoop = nil
        guard let engine, let context else {
            panel.display(nil)
            return
        }
        let directory = context.directory.isEmpty ? context.projectDirectory : context.directory
        let key = context.thread.map { "thread:" + $0.sessionID.rawValue } ?? "draft:" + directory
        let model = models[key] ?? {
            let model = ChangesModel(git: engine.git, directory: directory, sessionID: context.thread?.sessionID)
            models[key] = model
            return model
        }()
        recency.removeAll { $0 == key }
        recency.append(key)
        while recency.count > Self.modelLimit { models[recency.removeFirst()] = nil }
        if let thread = context.thread {
            model.turns = { [weak thread] in thread.map(Self.turns) ?? [] }
            model.onReversibleChange = { [weak self] change in self?.register(change) }
            wasRunning = thread.isRunning
            turnLoop = ObservationLoop { [weak self, weak thread, weak model] in
                guard let self, let thread, let model else { return }
                let running = thread.isRunning
                if self.wasRunning, !running {
                    model.repository.refresh()
                    model.load()
                }
                self.wasRunning = running
            }
        } else {
            model.onReversibleChange = { [weak self] change in self?.register(change) }
        }
        panel.display(model)
    }

    /// The user prompts of a thread, oldest first.
    static func turns(_ thread: ThreadModel) -> [ChangesTurn] {
        var result: [ChangesTurn] = []
        for id in thread.messageIDs {
            guard let message = thread.message(id)?.message, case .user(let content) = message.kind else { continue }
            let title = content.text.split(separator: "\n").first.map { String($0.prefix(80)) } ?? "Prompt"
            result.append(ChangesTurn(id: id, title: title, index: result.count))
        }
        return result
    }

    /// Re-reads git status (window became key, a commit elsewhere).
    func refreshStatus() { panel.model?.repository.refresh() }

    var model: ChangesModel? { panel.model }

    func saveOptions() {
        if let data = try? JSONEncoder().encode(panel.options) { UserDefaults.standard.set(data, forKey: Self.optionsKey) }
    }

    // MARK: ChangesPanelHost

    func changesPanel(_ panel: ChangesPanelController, addComment comment: DiffReviewComment) -> Bool {
        guard let composer = shell?.changesComposer else {
            shell?.changesUndo.showNotice("Open a thread to send review comments.")
            return false
        }
        // ComposerKit has no review-comment chip yet: the comment is a named text attachment (a chip) with the
        // location, side, quoted lines and the comment.
        let rejected = composer.add(attachments: [.text(comment.promptText, name: "Review \(comment.location).md")], actionName: "Add Review Comment")
        if rejected.isEmpty {
            shell?.changesUndo.showNotice("Comment on \(comment.location) added to the composer")
            return true
        }
        shell?.changesUndo.showNotice(rejected.contains(.draftLoading)
            ? "The thread's draft has not loaded, so the comment was not added. It is still in the comment editor."
            : "The composer has no room for another attachment. The comment is still in the comment editor.")
        return false
    }

    func changesPanel(_ panel: ChangesPanelController, didChange change: ReversibleChange) { register(change) }

    func changesPanel(_ panel: ChangesPanelController, notice: String) { shell?.changesUndo.showNotice(notice) }

    /// Registers a completed change with Undo (toast and Edit ▸ Undo). The change already happened, so the first
    /// "apply" is skipped; Redo re-applies it.
    private func register(_ change: ReversibleChange) {
        guard let undo = shell?.changesUndo else { return }
        var applied = false
        undo.perform(
            ReversibleAction(
                name: change.name, message: change.message,
                apply: { [weak undo] in
                    guard applied else {
                        applied = true
                        return
                    }
                    Task {
                        do { try await change.redo() } catch { undo?.showNotice("Redo failed: \(Self.describe(error))") }
                    }
                },
                revert: { [weak undo] in
                    Task {
                        do { try await change.undo() } catch { undo?.showNotice("Undo failed: \(Self.describe(error))") }
                    }
                }))
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? WorkingCopyError { return error.userMessage }
        if let error = error as? GitError { return error.userMessage }
        return "the files changed since."
    }
}

/// Removing the displayed thread's worktree: refuses nothing silently. A worktree holding nothing but its commits is
/// removed at once with Undo (the branch is kept). One holding uncommitted, untracked or ignored files (an `.env`, a
/// local database, build output) asks first, naming a few of them; those files are moved to the Trash and Undo puts
/// them back.
@MainActor
enum WorktreeRemoval {
    static func run(context: ThreadSurfaceContext, engine: Engine, window: NSWindow?, undo: UndoCoordinator) {
        let directory = context.directory
        let projectDirectory = context.projectDirectory
        let projectID = context.thread?.session?.projectID
        Task {
            do {
                let removed = try await engine.git.removeWorktree(
                    directory: directory, projectDirectory: projectDirectory, projectID: projectID, deleteBranch: false, force: false)
                offerUndo(removed, engine: engine, projectID: projectID, undo: undo, message: "Removed worktree \(name(removed)) (branch kept)")
            } catch WorktreeError.filesAtRisk(let contents) {
                guard let window else { return }
                let alert = NSAlert()
                alert.messageText = "Remove the worktree with \(contents.summary)?"
                let more = contents.uncommitted + contents.ignored - contents.examples.count
                let names = contents.examples.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
                alert.informativeText = """
                    \((directory as NSString).abbreviatingWithTildeInPath) holds files that exist nowhere else: \(names). \
                    They will be moved to the Trash, and Undo puts them back. The branch is kept.
                    """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Remove Worktree")
                alert.addButton(withTitle: "Cancel")
                alert.buttons.first?.hasDestructiveAction = true
                guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
                do {
                    let removed = try await engine.git.removeWorktree(
                        directory: directory, projectDirectory: projectDirectory, projectID: projectID, deleteBranch: false, force: true)
                    offerUndo(
                        removed, engine: engine, projectID: projectID, undo: undo,
                        message: "Removed worktree \(name(removed)); its \(contents.summary) are in the Trash")
                } catch {
                    undo.showNotice("The worktree was not removed: \(describe(error))")
                }
            } catch {
                undo.showNotice("The worktree was not removed: \(describe(error))")
            }
        }
    }

    /// The most recent removal of one worktree (Redo replaces it), for the next Undo.
    @MainActor private final class LatestRemoval {
        var value: RemovedWorktree
        init(_ value: RemovedWorktree) { self.value = value }
    }

    private static func name(_ removed: RemovedWorktree) -> String {
        removed.branch ?? (removed.directory as NSString).lastPathComponent
    }

    private static func offerUndo(_ removed: RemovedWorktree, engine: Engine, projectID: ProjectID?, undo: UndoCoordinator, message: String) {
        var applied = false
        // Redo repeats the removal the user already confirmed; the worktree's own files go to the Trash again, and the
        // next Undo restores from that new location.
        let force = removed.heldContents != nil
        let latest = LatestRemoval(removed)
        undo.perform(
            ReversibleAction(
                name: "Remove Worktree", message: message,
                apply: { [weak undo] in
                    guard applied else {
                        applied = true
                        return
                    }
                    Task {
                        do {
                            latest.value = try await engine.git.removeWorktree(
                                directory: removed.directory, projectDirectory: removed.projectDirectory, projectID: projectID,
                                deleteBranch: false, force: force)
                        } catch {
                            undo?.showNotice("The worktree was not removed: \(describe(error))")
                        }
                    }
                },
                revert: { [weak undo] in
                    Task {
                        do { try await engine.git.restoreWorktree(latest.value, projectID: projectID) } catch {
                            undo?.showNotice("The worktree could not be restored: \(describe(error))")
                        }
                    }
                }))
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? WorktreeError { return error.userMessage }
        if let error = error as? GitError { return error.userMessage }
        return "git reported an error."
    }
}
