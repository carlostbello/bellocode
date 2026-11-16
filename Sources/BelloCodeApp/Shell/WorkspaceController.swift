import AppKit
import Darwin
import BelloCore
import Engine
import Observation

/// The per-window brain: what is selected, which thread models are open, restoration state, and the commands that
/// act on threads and projects. Views read it; it never touches views (the window controller does), so the selection
/// path is testable without a window.
///
/// Threading: `@MainActor`, `@Observable` (`state` drives the sidebar's unread marks and the content area).
/// Ownership: one per window; `close()` closes every thread model it opened and saves state.
@MainActor
@Observable
final class WorkspaceController {
    /// Thread models kept open after leaving them, so switching back is instant (bounded; least recent closed).
    static let openThreadLimit = 8

    let engine: Engine
    /// Restoration state. Not observed as a whole (a draft keystroke must not re-render the sidebar); the observed
    /// pieces are `selection` and `manualUnread`.
    @ObservationIgnored private(set) var state: ShellState {
        didSet {
            if state.selection != selection { selection = state.selection }
            let unread = Set(state.manualUnread)
            if unread != manualUnread { manualUnread = unread }
        }
    }
    private(set) var selection: ShellSelection?
    /// Threads marked unread by the user (local).
    private(set) var manualUnread: Set<SessionID> = []
    @ObservationIgnored let undo: UndoCoordinator
    /// The window's undo manager (returned by the window delegate, shared with text views).
    @ObservationIgnored let undoManager: UndoManager
    @ObservationIgnored private let stateStore: ShellStateStore
    @ObservationIgnored private var openThreads: [SessionID: ThreadModel] = [:]
    /// Most recent last.
    @ObservationIgnored private var recency: [SessionID] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false

    init(engine: Engine, stateStore: ShellStateStore) {
        self.engine = engine
        self.stateStore = stateStore
        let loaded = stateStore.load()
        state = loaded
        selection = loaded.selection
        manualUnread = Set(loaded.manualUnread)
        let manager = UndoManager()
        manager.levelsOfUndo = 100
        undoManager = manager
        undo = UndoCoordinator(undoManager: { manager })
    }

    // MARK: - Selection

    /// Shows a thread or draft at once from cached state (never a blank pane), and remembers it for relaunch.
    func select(_ selection: ShellSelection?) {
        guard selection != state.selection else { return }
        if case .thread(let id) = selection {
            _ = threadModel(id)
            if state.manualUnread.contains(id) { state.setManualUnread(id, false) }
        }
        state.selection = selection
        scheduleSave()
    }

    /// The open model for a thread (opened on first use; the engine fills it from the cache within milliseconds).
    func threadModel(_ id: SessionID) -> ThreadModel {
        if let model = openThreads[id] {
            recency.removeAll { $0 == id }
            recency.append(id)
            return model
        }
        let model = engine.openThread(id)
        openThreads[id] = model
        recency.append(id)
        evictThreads()
        return model
    }

    private func evictThreads() {
        while recency.count > Self.openThreadLimit {
            guard let index = recency.firstIndex(where: { $0 != state.selection?.threadID }) else { return }
            let id = recency.remove(at: index)
            openThreads.removeValue(forKey: id)?.close()
        }
    }

    var openThreadCount: Int { openThreads.count }

    /// A surface context for a selection (nil when it cannot be shown, for example a removed project's draft).
    func makeContext(for selection: ShellSelection) -> ThreadSurfaceContext? {
        switch selection {
        case .thread(let id):
            let model = threadModel(id)
            let session = model.session ?? row(id)?.session
            let project = session.flatMap(projectItem(for:))
            let directory = project?.directory ?? session?.directory ?? ""
            let context = ThreadSurfaceContext(
                engine: engine, directory: directory, projectName: project?.name ?? Self.name(of: directory), thread: model)
            context.openThread = { [weak self] id in self?.threadModel(id) ?? model }
            return context
        case .draft(let directory):
            guard let project = projectItem(directory: directory) else { return nil }
            let context = ThreadSurfaceContext(
                engine: engine, directory: directory, projectName: project.name, thread: nil,
                newThreadDraft: state.newThreadDrafts[directory] ?? "")
            context.openThread = { [weak self] id in self?.threadModel(id) ?? self!.engine.openThread(id) }
            context.onNewThreadDraftChange = { [weak self] text in
                self?.state.newThreadDrafts[directory] = text
                self?.scheduleSave()
            }
            context.onThreadCreated = { [weak self] id in self?.select(.thread(id)) }
            return context
        }
    }

    // MARK: - Lookups

    func projectItem(directory: String) -> ProjectItem? { engine.root.projects.first { $0.directory == directory } }

    func projectItem(for session: Session) -> ProjectItem? {
        engine.root.projects.first { $0.projectID == session.projectID }
            ?? engine.root.projects.first { session.directory.hasPrefix($0.directory) }
    }

    func projectModel(_ item: ProjectItem) -> ProjectModel? { item.projectID.flatMap { engine.root.project($0) } }

    /// The sidebar row model for a session (top-level or child), from whichever project lists it.
    func row(_ id: SessionID) -> SessionRowModel? {
        for item in engine.root.projects {
            if let row = projectModel(item)?.row(id) { return row }
        }
        return nil
    }

    func session(_ id: SessionID) -> Session? { openThreads[id]?.session ?? row(id)?.session }

    /// The path opencode records for a folder: symlinks resolved (`/var/…` is `/private/var/…`, `/tmp` is
    /// `/private/tmp`), standardized, no trailing slash. Without this the sidebar entry never joins opencode's project.
    nonisolated static func canonicalDirectory(_ url: URL) -> String {
        // realpath(3): Foundation's resolvingSymlinksInPath strips "/private" again on macOS.
        var path = url.standardizedFileURL.path(percentEncoded: false)
        if let resolved = realpath(path, nil) {
            path = String(cString: resolved)
            free(resolved)
        }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static func name(of directory: String) -> String {
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty ? directory : name
    }

    /// The command target for a selection.
    func target(for selection: ShellSelection?) -> CommandTarget? {
        switch selection {
        case .thread(let id):
            guard let session = session(id) else { return nil }
            // Unknown (a turn orphaned by a server restart) counts: Stop settles it.
            let running = openThreads[id].map { $0.isRunning || $0.isStatusUnknown }
                ?? row(id)?.status.map { [.running, .stopping, .unknown].contains($0.status) } ?? session.isRunning
            return .thread(id, directory: session.directory, isRunning: running)
        case .draft(let directory):
            return .draft(directory: directory, isPinned: projectItem(directory: directory)?.isPinned ?? false)
        case nil:
            return nil
        }
    }

    /// The project a target belongs to.
    func projectDirectory(for target: CommandTarget) -> String? {
        switch target {
        case .thread(let id, let directory, _):
            if let session = session(id), let project = projectItem(for: session) { return project.directory }
            return projectItem(directory: directory)?.directory
        case .project(let directory, _), .draft(let directory, _):
            return directory
        }
    }

    // MARK: - Commands

    /// New thread: a draft in `directory`, else the selected thread's project, else the first project.
    func newThread(in directory: String? = nil) {
        let directory = directory
            ?? target(for: state.selection).flatMap(projectDirectory(for:))
            ?? engine.root.projects.first?.directory
        guard let directory else { return }
        select(.draft(directory: directory))
    }

    func archive(_ id: SessionID) {
        let title = session(id)?.displayTitle ?? "thread"
        let wasSelected = state.selection == .thread(id)
        let fallback = wasSelected ? neighbour(of: id) : nil
        let engine = self.engine
        undo.perform(
            ReversibleAction(
                name: "Archive Thread", message: "Archived “\(title)”",
                apply: { [weak self] in
                    if wasSelected { self?.select(fallback) }
                    self?.run { try await engine.setArchived(id, true) }
                },
                revert: { [weak self] in self?.run { try await engine.setArchived(id, false) } }))
    }

    func rename(_ id: SessionID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let old = session(id), old.title != trimmed else { return }
        let previous = old.title ?? ""
        let engine = self.engine
        undo.perform(
            ReversibleAction(
                name: "Rename Thread", message: "Renamed to “\(trimmed)”",
                apply: { [weak self] in self?.run { try await engine.renameThread(id, to: trimmed) } },
                revert: { [weak self] in self?.run { try await engine.renameThread(id, to: previous) } }))
    }

    /// Deletes on the server (not undoable; the window confirms first).
    func delete(_ id: SessionID) {
        if state.selection == .thread(id) { select(neighbour(of: id)) }
        openThreads.removeValue(forKey: id)?.close()
        recency.removeAll { $0 == id }
        run { try await self.engine.deleteThread(id) }
    }

    func markUnread(_ id: SessionID) {
        let title = session(id)?.displayTitle ?? "thread"
        undo.perform(
            ReversibleAction(
                name: "Mark as Unread", message: "Marked “\(title)” unread",
                apply: { [weak self] in
                    self?.state.setManualUnread(id, true)
                    self?.scheduleSave()
                },
                revert: { [weak self] in
                    self?.state.setManualUnread(id, false)
                    self?.scheduleSave()
                }))
    }

    func togglePin(directory: String) {
        guard let project = projectItem(directory: directory) else { return }
        let pinned = !project.isPinned
        let engine = self.engine
        undo.perform(
            ReversibleAction(
                name: pinned ? "Pin Project" : "Unpin Project", message: "\(pinned ? "Pinned" : "Unpinned") \(project.name)",
                apply: { Task { await engine.setProjectPinned(directory: directory, pinned) } },
                revert: { Task { await engine.setProjectPinned(directory: directory, !pinned) } }))
    }

    func removeProject(directory: String) {
        guard let project = projectItem(directory: directory) else { return }
        let engine = self.engine
        let previousSelection = state.selection
        let affectsSelection = target(for: previousSelection).flatMap(projectDirectory(for:)) == directory
        undo.perform(
            ReversibleAction(
                name: "Remove Project", message: "Removed \(project.name) from the sidebar",
                apply: { [weak self] in
                    if affectsSelection { self?.select(nil) }
                    Task { await engine.removeProject(directory: directory) }
                },
                revert: { [weak self] in
                    Task {
                        await engine.addProject(directory: directory)
                        if affectsSelection { self?.select(previousSelection) }
                    }
                }))
    }

    /// Adds folders (open panel or drop). Selects the first one's new-thread draft.
    func addProjects(_ urls: [URL]) {
        let directories = urls.map(Self.canonicalDirectory)
        guard !directories.isEmpty else { return }
        let engine = self.engine
        let name = directories.count == 1 ? Self.name(of: directories[0]) : "\(directories.count) projects"
        let previousSelection = state.selection
        undo.perform(
            ReversibleAction(
                name: "Add Project", message: "Added \(name)",
                apply: { [weak self] in
                    Task {
                        for directory in directories { await engine.addProject(directory: directory) }
                        self?.select(.draft(directory: directories[0]))
                    }
                },
                revert: { [weak self] in
                    self?.select(previousSelection)
                    Task { for directory in directories { await engine.removeProject(directory: directory) } }
                }))
    }

    func setCollapsed(_ directory: String, _ collapsed: Bool) {
        guard state.collapsedProjects.contains(directory) != collapsed else { return }
        if collapsed { state.collapsedProjects.insert(directory) } else { state.collapsedProjects.remove(directory) }
        scheduleSave()
    }

    func setNeedsYouCollapsed(_ collapsed: Bool) {
        guard state.isNeedsYouCollapsed != collapsed else { return }
        state.isNeedsYouCollapsed = collapsed
        scheduleSave()
    }

    func updateLayout(sidebarCollapsed: Bool? = nil, rightPanelVisible: Bool? = nil, terminalVisible: Bool? = nil, rightPanelTab: String? = nil) {
        var next = state
        if let sidebarCollapsed { next.isSidebarCollapsed = sidebarCollapsed }
        if let rightPanelVisible { next.isRightPanelVisible = rightPanelVisible }
        if let terminalVisible { next.isTerminalVisible = terminalVisible }
        if let rightPanelTab { next.rightPanelTab = rightPanelTab }
        guard next != state else { return }
        state = next
        scheduleSave()
    }

    /// Selects the next thread that needs the user (wrapping). Returns it.
    @discardableResult
    func selectNextNeedsAttention() -> SessionID? {
        let items = engine.root.attention.items.map(\.sessionID)
        guard let next = nextAttention(after: state.selection?.threadID, in: items) else { return nil }
        select(.thread(next))
        return next
    }

    /// The thread to show after `id` disappears: the next one in its project, else the previous, else the draft.
    private func neighbour(of id: SessionID) -> ShellSelection? {
        guard let session = session(id), let project = projectItem(for: session), let model = projectModel(project) else { return nil }
        let ids = model.sessionIDs
        guard let index = ids.firstIndex(of: id) else { return .draft(directory: project.directory) }
        if index + 1 < ids.count { return .thread(ids[index + 1]) }
        if index > 0 { return .thread(ids[index - 1]) }
        return .draft(directory: project.directory)
    }

    /// Runs an engine command; a failure shows a notice (the engine has already rolled back its optimistic change).
    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor [weak self] in
            do {
                try await body()
            } catch {
                let message = (error as? EngineError)?.userMessage ?? "The change could not be made."
                self?.undo.showNotice(message)
            }
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard !isClosed else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.stateStore.save(self.state)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        stateStore.save(state)
    }

    /// Saves state and closes every open thread model.
    func close() {
        guard !isClosed else { return }
        saveNow()
        isClosed = true
        for model in openThreads.values { model.close() }
        openThreads.removeAll()
        recency.removeAll()
    }
}
