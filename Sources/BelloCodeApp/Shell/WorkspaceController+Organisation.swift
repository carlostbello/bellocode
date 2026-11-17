import AppKit
import BelloCore
import Engine

/// A delete waiting out its Undo window. Shared by the action's apply and revert (and redo), so whichever runs last
/// wins and the server delete happens at most once.
@MainActor
final class DeferredDelete {
    let ids: [SessionID]
    /// Weak: the undo coordinator keeps the token (and through it this box) alive.
    weak var token: UndoToken?
    var task: Task<Void, Never>?
    init(ids: [SessionID]) { self.ids = ids }
}

/// A message to reveal once its thread's transcript is on screen (global search results).
struct PendingReveal: Equatable, Sendable {
    var sessionID: SessionID
    var messageID: MessageID
    var query: String
}

/// Sidebar organisation, deferred delete, history and reopen (docs/features/navigation.md). Every action applies at
/// once with a 5-second Undo toast and ⌘Z; nothing asks for confirmation.
extension WorkspaceController {
    /// How long a delete waits for Undo before it is sent to opencode.
    static var deleteDelay: Duration { .seconds(ToastQueue.duration) }

    /// "“Fix tests”" or "3 threads".
    func describe(_ ids: [SessionID]) -> String {
        if ids.count == 1 { return "“\(session(ids[0])?.displayTitle ?? "thread")”" }
        return "\(ids.count) threads"
    }

    /// Applies an organisation change to threads with Undo. Returns the previous values.
    func organise(_ ids: [SessionID], _ transition: OrganisationTransition, name: String, message: String) {
        let ids = ids.filter { !hiddenThreads.contains($0) }
        guard !ids.isEmpty else { return }
        let now = Timestamp.now
        let previous = Dictionary(uniqueKeysWithValues: ids.map { ($0, engine.organisation(of: $0)) })
        let next = previous.mapValues { $0.applying(transition, now: now) }
        guard next != previous else { return }
        apply(next: next, previous: previous, name: name, message: message)
    }

    /// Replaces organisation values with Undo (drops and menu actions share this).
    func apply(next: [SessionID: ThreadOrganisation], previous: [SessionID: ThreadOrganisation], name: String, message: String, animated: Bool = true) {
        let engine = self.engine
        undo.perform(
            ReversibleAction(
                name: name, message: message,
                apply: { [weak self] in
                    self?.animatesNextStructureChange = animated
                    engine.setOrganisation(next)
                },
                revert: { [weak self] in
                    self?.animatesNextStructureChange = animated
                    engine.setOrganisation(previous)
                }))
    }

    func togglePin(_ ids: [SessionID]) {
        let pin = ids.contains { !engine.organisation(of: $0).pinned }
        organise(
            ids, pin ? .pin : .unpin, name: pin ? "Pin" : "Unpin",
            message: "\(pin ? "Pinned" : "Unpinned") \(describe(ids))")
    }

    func toggleSettle(_ ids: [SessionID]) {
        let settle = ids.contains { !engine.organisation(of: $0).settled }
        if settle { noteClosed(ids.filter { state.selection == .thread($0) }) }
        organise(
            ids, settle ? .settle : .unsettle, name: settle ? "Settle" : "Un-settle",
            message: "\(settle ? "Settled" : "Un-settled") \(describe(ids))")
    }

    func snooze(_ ids: [SessionID], until date: Date) {
        noteClosed(ids.filter { state.selection == .thread($0) })
        organise(
            ids, .snooze(until: Timestamp(date)), name: "Snooze",
            message: "Snoozed \(describe(ids)) until \(ThreadRowPresentation.wakeText(date, now: Date()))")
    }

    func wake(_ ids: [SessionID]) {
        organise(ids.filter { engine.organisation(of: $0).isSnoozed }, .wake, name: "Wake", message: "Woke \(describe(ids))")
    }

    func toggleNeverAutoSettle(_ ids: [SessionID]) {
        let never = ids.contains { !engine.organisation(of: $0).neverAutoSettle }
        organise(
            ids, .setNeverAutoSettle(never), name: never ? "Never Auto-Settle" : "Allow Auto-Settle",
            message: never ? "\(describe(ids)) will never be settled automatically" : "\(describe(ids)) can be settled automatically")
    }

    func markUnread(_ id: SessionID) { markUnread([id]) }

    func markUnread(_ ids: [SessionID]) {
        organise(ids, .setMarkedUnread(true), name: "Mark as Unread", message: "Marked \(describe(ids)) unread")
    }

    // MARK: - Deferred delete

    /// Hides threads now and deletes them on the server when the Undo window (5 s) ends; Undo (toast or ⌘Z) within it
    /// brings them back untouched. Closing the window or quitting carries the delete out at once.
    func delete(_ id: SessionID) { delete([id]) }

    func delete(_ ids: [SessionID]) {
        let ids = ids.filter { !hiddenThreads.contains($0) }
        guard !ids.isEmpty else { return }
        let selected = state.selection?.threadID.flatMap { ids.contains($0) ? $0 : nil }
        let fallback = selected.flatMap { neighbour(of: $0, excluding: Set(ids)) }
        let deferred = DeferredDelete(ids: ids)
        deferred.token = undo.perform(
            ReversibleAction(
                name: ids.count == 1 ? "Delete Thread" : "Delete Threads", message: "Deleted \(describe(ids))",
                apply: { [weak self] in
                    guard let self else { return }
                    self.hiddenThreads.formUnion(ids)
                    if selected != nil { self.select(fallback) }
                    for id in ids { self.pendingDeletes[id] = deferred }
                    deferred.task?.cancel()
                    deferred.task = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: Self.deleteDelay)
                        guard !Task.isCancelled, let self else { return }
                        self.carryOut(deferred)
                    }
                },
                revert: { [weak self] in
                    guard let self else { return }
                    deferred.task?.cancel()
                    deferred.task = nil
                    self.hiddenThreads.subtract(ids)
                    for id in ids where self.pendingDeletes[id] === deferred { self.pendingDeletes[id] = nil }
                    if let selected { self.select(.thread(selected)) }
                }))
        // Keep the box alive for as long as its delete is pending.
        for id in ids { pendingDeletes[id] = deferred }
    }

    /// Sends a pending delete to opencode; it can no longer be undone.
    func carryOut(_ deferred: DeferredDelete) {
        deferred.task?.cancel()
        deferred.task = nil
        if let token = deferred.token { undo.retire(token) }
        for id in deferred.ids where pendingDeletes[id] === deferred {
            pendingDeletes[id] = nil
            closeThreadModel(id)
            let engine = self.engine
            Task { @MainActor [weak self] in
                do {
                    try await engine.deleteThread(id)
                } catch {
                    // The engine restored the row; show it again and say why.
                    self?.hiddenThreads.remove(id)
                    self?.undo.showNotice((error as? EngineError)?.userMessage ?? "The thread could not be deleted.")
                    return
                }
                self?.hiddenThreads.remove(id)
            }
        }
    }

    func commitPendingDeletes() {
        for box in Array(pendingDeletes.values) { carryOut(box) }
    }

    // MARK: - History and reopen

    var canGoBack: Bool { backStack.contains(where: isShowable) }
    var canGoForward: Bool { forwardStack.contains(where: isShowable) }

    func goBack() {
        guard let target = popShowable(&backStack) else { return NSSound.beep() }
        if let current = state.selection { appendForward(current) }
        select(target, recordsHistory: false)
    }

    func goForward() {
        guard let target = popShowable(&forwardStack) else { return NSSound.beep() }
        if let current = state.selection { appendBack(current) }
        select(target, recordsHistory: false)
    }

    private func popShowable(_ stack: inout [ShellSelection]) -> ShellSelection? {
        while let last = stack.popLast() {
            if isShowable(last), last != state.selection { return last }
        }
        return nil
    }

    func isShowable(_ selection: ShellSelection) -> Bool {
        switch selection {
        case .thread(let id): !hiddenThreads.contains(id) && session(id).map { !$0.isArchived } ?? false
        case .draft(let directory): projectItem(directory: directory) != nil
        }
    }

    func noteClosed(_ ids: [SessionID]) {
        for id in ids {
            closedThreads.removeAll { $0 == id }
            closedThreads.append(id)
        }
        if closedThreads.count > Self.historyLimit { closedThreads.removeFirst(closedThreads.count - Self.historyLimit) }
    }

    var canReopenClosedThread: Bool { closedThreads.contains { session($0) != nil } }

    /// Shows the thread that most recently left the window again: unarchives it, cancels its pending delete, or brings
    /// it back from a shelf.
    func reopenClosedThread() {
        while let id = closedThreads.popLast() {
            if let deferred = pendingDeletes[id] {
                deferred.task?.cancel()
                if let token = deferred.token { undo.retire(token) }
                for other in deferred.ids where pendingDeletes[other] === deferred { pendingDeletes[other] = nil }
                hiddenThreads.subtract(deferred.ids)
            }
            guard let session = session(id) else { continue }
            if session.isArchived { run { try await self.engine.setArchived(id, false) } }
            let organisation = engine.organisation(of: id)
            if organisation.settled || organisation.isSnoozed { engine.organise([id], .unsettle) }
            select(.thread(id))
            return
        }
        NSSound.beep()
    }

    private func appendBack(_ selection: ShellSelection) {
        backStack.removeAll { $0 == selection }
        backStack.append(selection)
    }

    private func appendForward(_ selection: ShellSelection) {
        forwardStack.removeAll { $0 == selection }
        forwardStack.append(selection)
    }

    // MARK: - Sidebar options

    func setGrouping(_ grouping: SidebarGrouping) {
        mutateState { $0.grouping = grouping }
    }

    /// Moves a project up or down in the sidebar order (pinned projects stay above).
    func moveProject(directory: String, by offset: Int) {
        let projects = engine.root.projects
        guard let index = projects.firstIndex(where: { $0.directory == directory }) else { return }
        let target = index + offset
        guard projects.indices.contains(target), projects[target].isPinned == projects[index].isPinned else { return NSSound.beep() }
        let engine = self.engine
        let name = projects[index].name
        undo.perform(
            ReversibleAction(
                name: "Move Project", message: "Moved \(name)",
                apply: { Task { await engine.moveProject(directory: directory, to: target) } },
                revert: { Task { await engine.moveProject(directory: directory, to: index) } }))
    }

    /// Records the right panel's state for the displayed thread (restored when it is shown again).
    func recordPanel(_ panel: ThreadPanelState, for id: SessionID) {
        guard state.threadPanels[id.rawValue] != panel else { return }
        mutateState { $0.setPanel(panel, for: id) }
    }

    func panel(for id: SessionID) -> ThreadPanelState? { state.threadPanels[id.rawValue] }

    func closeThreadModel(_ id: SessionID) { forgetThread(id) }
}

extension CommandContext {
    /// Fills the organisation, history and project-order inputs from the workspace.
    @MainActor
    func with(organisationOf threads: [SessionID], workspace: WorkspaceController, target: CommandTarget?, terminalFocused: Bool) -> CommandContext {
        var context = self
        context.terminalFocused = terminalFocused
        context.selectedThreadCount = threads.count
        let organisations = threads.map { workspace.engine.organisation(of: $0) }
        context.targetsPinned = !organisations.isEmpty && organisations.allSatisfy(\.pinned)
        context.targetsSettled = !organisations.isEmpty && organisations.allSatisfy(\.settled)
        context.targetsSnoozed = organisations.contains(where: \.isSnoozed)
        context.targetsNeverAutoSettle = !organisations.isEmpty && organisations.allSatisfy(\.neverAutoSettle)
        context.grouping = workspace.grouping
        context.canGoBack = workspace.canGoBack
        context.canGoForward = workspace.canGoForward
        context.canReopenClosedThread = workspace.canReopenClosedThread
        if case .project(let directory, _) = target {
            let projects = workspace.engine.root.projects
            if let index = projects.firstIndex(where: { $0.directory == directory }) {
                context.projectCanMoveUp = index > 0 && projects[index - 1].isPinned == projects[index].isPinned
                context.projectCanMoveDown = index + 1 < projects.count && projects[index + 1].isPinned == projects[index].isPinned
            }
        }
        return context
    }
}
