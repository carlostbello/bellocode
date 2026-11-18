import AppKit
import BelloCore
import Engine

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
        if settle { applyWorktreeCleanup(ids, trigger: .settled) }
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

    /// Hides threads now (in every window) and deletes them on the server when the Undo window (5 s) ends; Undo (toast
    /// or ⌘Z, in any window) within it brings them back untouched. Closing the last window or quitting carries the
    /// delete out at once. See `PendingThreadDeletions`.
    func delete(_ id: SessionID) { delete([id]) }

    func delete(_ ids: [SessionID]) {
        deletions.delete(
            ids, name: ids.count == 1 ? "Delete Thread" : "Delete Threads", message: "Deleted \(describe(ids))", from: self)
    }

    /// Sends every pending delete now (they can no longer be undone).
    func commitPendingDeletes() { deletions.commitAll() }

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
            deletions.restore(thread: id)
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

extension WorkspaceController: PendingDeletionListener {
    func pendingDeletionHid(_ ids: [SessionID]) {
        guard let shown = selection?.threadID, ids.contains(shown) else { return }
        let fallback = neighbour(of: shown, excluding: Set(ids))
        leftForDeletion[shown] = fallback
        select(fallback)
    }

    func pendingDeletionRestored(_ ids: [SessionID]) {
        for id in ids {
            guard let fallback = leftForDeletion.removeValue(forKey: id) else { continue }
            if selection == fallback { select(.thread(id)) }
        }
    }

    func pendingDeletionCommitted(_ ids: [SessionID]) {
        for id in ids {
            leftForDeletion[id] = nil
            closeThreadModel(id)
        }
    }
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
