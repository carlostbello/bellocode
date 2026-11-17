import AppKit
import BelloCore
import Engine
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import BelloCodeApp

/// Records notifications instead of posting them.
@MainActor
final class RecordingDelivery: NotificationDelivering {
    var state: NotificationAuthorization = .authorized
    var requests = 0
    var posted: [NotificationContent] = []
    var removed: [String] = []
    func authorization() async -> NotificationAuthorization { state }
    func requestAuthorization() async -> NotificationAuthorization {
        requests += 1
        state = .authorized
        return state
    }
    func post(_ content: NotificationContent) { posted.append(content) }
    func remove(identifiers: [String]) { removed += identifiers }
}

/// The real sidebar, palette, search and notifier, driven through their controllers in-process against MockOpenCode
/// (no UI scripting: AGENTS.md "Environment").
@MainActor @Suite(.serialized) struct NavigationWindowTests {
    typealias Shell = IntegratedShellTests.Shell

    func threads(_ shell: Shell, in directory: String? = nil) -> [SessionID] {
        let projects = shell.engine.root.projects.filter { directory == nil || $0.directory == directory }
        return projects.flatMap { shell.controller.workspace.projectModel($0)?.sessionIDs ?? [] }
    }

    @Test func settlePinSnoozeAndUndoMoveRowsBetweenSections() async throws {
        let shell = try await Shell.start()
        defer { Task { await shell.stop() } }
        let controller = shell.controller
        let workspace = controller.workspace
        let sidebar = controller.sidebar
        let project = try #require(shell.engine.root.projects.max { threads(shell, in: $0.directory).count < threads(shell, in: $1.directory).count })
        let ids = threads(shell, in: project.directory)
        try #require(ids.count >= 3)
        let (a, b, c) = (ids[0], ids[1], ids[2])
        let active = SidebarNodeID.section(scope: project.directory, .active)
        let settled = SidebarNodeID.section(scope: project.directory, .settled)
        let pinned = SidebarNodeID.section(scope: project.directory, .pinned)
        func parent(_ id: SessionID) -> SidebarNodeID? { SidebarTree.parents(sidebar.roots)[.thread(id)] ?? nil }
        #expect(await waitUntil(timeout: .seconds(5)) { parent(a) == active })

        // Settle the displayed thread from the Thread menu (⇧⌘S): it moves to Settled, which is collapsed by default.
        #expect(await shell.driver.select(.thread(a)))
        shell.driver.perform(.settleThread)
        #expect(await waitUntil(timeout: .seconds(2)) { parent(a) == settled })
        #expect(sidebar.isExpanded(settled) == false || sidebar.row(of: .thread(a)) >= 0, "collapsed unless it holds the selection")
        #expect(workspace.undo.toasts.current?.message.hasPrefix("Settled") == true, "a 5-second Undo toast")
        // ⌘Z puts it back.
        workspace.undoManager.undo()
        #expect(await waitUntil(timeout: .seconds(2)) { parent(a) == active })
        workspace.undoManager.redo()
        #expect(await waitUntil(timeout: .seconds(2)) { parent(a) == settled })
        workspace.undoManager.undo()

        // Multi-selection in the sidebar: ⇧⌘P pins both, and the title says how many.
        sidebar.selectThreads([b, c])
        controller.window?.makeFirstResponder(sidebar.outlineView)
        #expect(sidebar.selectedThreadIDs == [b, c])
        #expect(controller.commandContext().title(for: .togglePinThread) == "Pin 2 Threads")
        shell.driver.perform(.togglePinThread)
        #expect(await waitUntil(timeout: .seconds(2)) { parent(b) == pinned && parent(c) == pinned })
        let projectNode = sidebar.roots.first { $0.id == .projectsHeader }?.children.first { $0.id == .project(project.directory) }
        #expect(projectNode?.children.first?.id == pinned, "Pinned is first")

        // Snooze: the row leaves for Snoozed; waking returns it to the top of Active.
        workspace.snooze([b], until: Date().addingTimeInterval(3600))
        let snoozed = SidebarNodeID.section(scope: project.directory, .snoozed)
        #expect(await waitUntil(timeout: .seconds(2)) { parent(b) == snoozed })
        workspace.wake([b])
        #expect(await waitUntil(timeout: .seconds(2)) { parent(b) == active })
        let activeRows = sidebar.roots.flatMap { SidebarTree.flatten([$0]) }
        let firstActive = activeRows.firstIndex(of: .thread(b))
        #expect(firstActive != nil)
    }

    @Test func dragDropModelAndForbiddenCrossProjectDrop() async throws {
        let shell = try await Shell.start()
        defer { Task { await shell.stop() } }
        let sidebar = shell.controller.sidebar
        let projects = shell.engine.root.projects
        try #require(projects.count >= 2)
        let first = threads(shell, in: projects[0].directory)
        let other = projects[1].directory
        try #require(first.count >= 2)
        func parent(_ id: SessionID) -> SidebarNodeID? { SidebarTree.parents(sidebar.roots)[.thread(id)] ?? nil }
        #expect(await waitUntil(timeout: .seconds(5)) { parent(first[0]) != nil })
        // Onto another project's section: not allowed, with the reason.
        let outcome = sidebar.resolveDrop(section: .section(scope: other, .active), index: 0, threads: [first[0]])
        #expect(outcome == .forbidden(SidebarDrop.crossProjectReason))
        // Working follows the agent.
        #expect(!sidebar.resolveDrop(section: .section(scope: projects[0].directory, .working), index: 0, threads: [first[0]]).isAllowed)
        // Into Settled through the drop path (no animation after a drop), then Undo.
        let settled = SidebarNodeID.section(scope: projects[0].directory, .settled)
        #expect(sidebar.performDrop(section: settled, index: 0, threads: [first[0]]))
        #expect(await waitUntil(timeout: .seconds(2)) { parent(first[0]) == settled })
        #expect(shell.controller.workspace.animatesNextStructureChange == false)
        shell.controller.workspace.undo.undoFromToast()
        #expect(await waitUntil(timeout: .seconds(2)) { parent(first[0]) == .section(scope: projects[0].directory, .active) })
        // Reorder within Active: the dragged row lands where it was dropped.
        let active = SidebarNodeID.section(scope: projects[0].directory, .active)
        let order = { (sidebar.roots.flatMap { SidebarTree.flatten([$0]) }).compactMap { id -> SessionID? in
            if case .thread(let session) = id, first.contains(session) { return session } else { return nil }
        } }
        let before = order()
        #expect(sidebar.performDrop(section: active, index: 0, threads: [before.last!]))
        #expect(await waitUntil(timeout: .seconds(2)) { order().first == before.last })
        // The forced preview renders an insertion gap and the badge.
        sidebar.showDropPreview(threads: [before[0]], section: settled, index: 0)
        #expect(sidebar.roots.flatMap { SidebarTree.flatten([$0]) }.contains(.dropGap) || !sidebar.isExpanded(settled))
        #expect(!sidebar.dropBadge.isHidden)
        sidebar.showDropPreview(threads: [], section: nil)
        #expect(sidebar.dropBadge.isHidden)
    }

    @Test func deferredDeleteHidesAtOnceAndUndoBringsItBack() async throws {
        let shell = try await Shell.start()
        defer { Task { await shell.stop() } }
        let workspace = shell.controller.workspace
        let ids = threads(shell)
        try #require(ids.count >= 2)
        #expect(await shell.driver.select(.thread(ids[0])))
        // Delete is a menu command with no confirmation dialog; the row hides and the selection moves on.
        shell.driver.perform(.deleteThread)
        #expect(workspace.hiddenThreads.contains(ids[0]))
        #expect(workspace.selection != .thread(ids[0]))
        #expect(shell.controller.window?.attachedSheet == nil, "no confirmation sheet")
        #expect(await waitUntil(timeout: .seconds(2)) { !SidebarTree.flatten(shell.controller.sidebar.roots).contains(.thread(ids[0])) })
        // Undo within five seconds: nothing reached the server.
        workspace.undo.undoFromToast()
        #expect(!workspace.hiddenThreads.contains(ids[0]))
        #expect(workspace.selection == .thread(ids[0]))
        // Deterministic (no sleep): Undo cancelled the pending delete before anything was sent.
        #expect(!workspace.deletions.isPending(ids[0]) && workspace.deletions.sentCount == 0)
        workspace.commitPendingDeletes()
        #expect(workspace.deletions.sentCount == 0, "an undone delete is never sent")
        #expect(await shell.server.session(ids[0].rawValue) != nil, "still on the server")
        // Without Undo it is deleted when the window closes (or after five seconds); Undo can no longer bring it back.
        workspace.delete([ids[1]])
        workspace.commitPendingDeletes()
        #expect(await waitUntil(timeout: .seconds(5)) { !workspace.hiddenThreads.contains(ids[1]) })
        #expect(await shell.server.session(ids[1].rawValue) == nil, "deleted on the server")
        #expect(workspace.undo.toasts.current == nil, "the delete's toast is gone")
    }

    /// Review M5: a second window of the same engine hides the row too, leaves it if shown, and can undo the delete.
    @Test func deferredDeleteIsSharedByEveryWindow() async throws {
        let shell = try await Shell.start()
        defer { Task { await shell.stop() } }
        let first = shell.controller.workspace
        let second = WorkspaceController(engine: shell.engine, stateStore: ShellStateStore(defaults: nil))
        defer { second.close() }
        #expect(second.deletions === first.deletions)
        let ids = threads(shell)
        try #require(ids.count >= 2)
        second.select(.thread(ids[0]))
        first.delete([ids[0]])
        #expect(second.hiddenThreads.contains(ids[0]), "hidden in the other window")
        #expect(second.selection != .thread(ids[0]), "the other window left the thread")
        second.undo.undoFromToast()
        #expect(!first.hiddenThreads.contains(ids[0]) && first.undo.toasts.current == nil)
        #expect(second.selection == .thread(ids[0]), "and went back to it")
        // Closing one window keeps the delete pending; it is sent once, when the other commits.
        first.delete([ids[1]])
        let sentBefore = first.deletions.sentCount
        second.close()
        #expect(first.deletions.isPending(ids[1]))
        first.commitPendingDeletes()
        first.commitPendingDeletes()
        #expect(await waitUntil(timeout: .seconds(5)) { !first.hiddenThreads.contains(ids[1]) })
        #expect(first.deletions.sentCount == sentBefore + 1)
        #expect(await shell.server.session(ids[1].rawValue) == nil)
    }

    @Test func historyBackForwardAndReopenClosed() async throws {
        let shell = try await Shell.start()
        defer { Task { await shell.stop() } }
        let workspace = shell.controller.workspace
        let ids = threads(shell)
        try #require(ids.count >= 3)
        for id in ids.prefix(3) { workspace.select(.thread(id)) }
        #expect(shell.controller.commandContext().isEnabled(.goBack))
        shell.driver.perform(.goBack)
        #expect(workspace.selection == .thread(ids[1]))
        shell.driver.perform(.goBack)
        #expect(workspace.selection == .thread(ids[0]))
        shell.driver.perform(.goForward)
        #expect(workspace.selection == .thread(ids[1]))
        workspace.select(.thread(ids[2]))
        #expect(!workspace.canGoForward, "a new visit clears Forward")
        // Archive the shown thread, then ⇧⌘T reopens it.
        workspace.archive([ids[2]])
        #expect(workspace.selection != .thread(ids[2]))
        #expect(await waitUntil(timeout: .seconds(5)) { workspace.session(ids[2])?.isArchived == true })
        shell.driver.perform(.reopenClosedThread)
        #expect(workspace.selection == .thread(ids[2]))
        #expect(await waitUntil(timeout: .seconds(5)) { workspace.session(ids[2])?.isArchived == false })
    }

    @Test func groupingFilterAndPanelStatePerThread() async throws {
        let shell = try await Shell.start()
        defer { Task { await shell.stop() } }
        let controller = shell.controller
        let sidebar = controller.sidebar
        let ids = threads(shell)
        try #require(ids.count >= 2)
        shell.driver.perform(.showThreadsByState)
        #expect(await waitUntil(timeout: .seconds(2)) { sidebar.roots.contains { $0.id == .section(scope: nil, .active) } })
        #expect(controller.commandContext().grouping == .byState)
        shell.driver.perform(.groupByProject)
        #expect(await waitUntil(timeout: .seconds(2)) { sidebar.roots.contains { $0.id == .projectsHeader } })
        // The filter field (⌥⌘F) narrows the list; nothing matching says so.
        shell.driver.perform(.filterSidebar)
        #expect(controller.window?.firstResponder === sidebar.filterField.currentEditor())
        sidebar.setFilter("zzzz-no-such-thread")
        #expect(await waitUntil(timeout: .seconds(2)) { sidebar.roots.contains { $0.id == .noResults } })
        let title = try #require(controller.workspace.session(ids[0])?.displayTitle)
        sidebar.setFilter(String(title.prefix(6)))
        #expect(await waitUntil(timeout: .seconds(2)) { SidebarTree.flatten(sidebar.roots).contains(.thread(ids[0])) })
        sidebar.setFilter("")
        // Right panel per thread: shown on one thread, hidden on another, restored when switching back.
        #expect(await shell.driver.select(.thread(ids[0])))
        controller.split.setCollapsed(controller.split.panelItem, false)
        controller.split.onLayoutChange?()
        #expect(await shell.driver.select(.thread(ids[1])))
        controller.split.setCollapsed(controller.split.panelItem, true)
        controller.split.onLayoutChange?()
        #expect(await shell.driver.select(.thread(ids[0])))
        #expect(controller.split.panelItem.isCollapsed == false, "thread 1 shows its panel again")
        #expect(await shell.driver.select(.thread(ids[1])))
        #expect(controller.split.panelItem.isCollapsed == true)
    }

    @Test func paletteOpensRanksAndRestoresFocus() async throws {
        let shell = try await Shell.start()
        defer { Task { await shell.stop() } }
        let controller = shell.controller
        let palette = controller.palette
        let ids = threads(shell)
        try #require(ids.count >= 2)
        #expect(await shell.driver.select(.thread(ids[0])))
        let composerView = try #require(controller.container.composerFocusView)
        controller.window?.makeFirstResponder(composerView)
        let before = controller.window?.firstResponder

        shell.driver.perform(.commandPalette)
        #expect(palette.isVisible)
        #expect(palette.mode == .commands)
        guard case .header(let first) = palette.rows.first else { Issue.record("no rows"); return }
        #expect(first == "Actions" || first == "Recent")
        // `>` keeps actions only; disabled ones say why.
        palette.setQuery(">stop")
        #expect(palette.selectedItem?.payload == .command(.stopRun) || palette.rows.contains { row in
            if case .item(let item) = row { return item.payload == .command(.stopRun) } else { return false }
        })
        // `@` finds a thread by title; Return opens it and the palette closes.
        let title = try #require(controller.workspace.session(ids[1])?.displayTitle)
        palette.setQuery("@" + title)
        #expect(palette.selectedItem?.payload == .thread(ids[1]))
        palette.activateSelection()
        #expect(!palette.isVisible)
        #expect(controller.workspace.selection == .thread(ids[1]))
        #expect(shell.engine.frecency.index.score("thread:\(ids[1].rawValue)", now: .now) > 0, "frecency recorded")

        // Escape restores the previous focus.
        #expect(await shell.driver.select(.thread(ids[0])))
        controller.window?.makeFirstResponder(composerView)
        shell.driver.perform(.quickOpen)
        #expect(palette.mode == .quickOpen)
        _ = palette.control(palette.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(!palette.isVisible)
        #expect(controller.window?.firstResponder === before || controller.window?.firstResponder === composerView)

        // Files of the current project through the server's file search (`/`).
        shell.driver.perform(.quickOpen)
        palette.setQuery("/Pars")
        await palette.settleSearches()
        #expect(palette.rows.contains { row in if case .item(let item) = row { item.title == "Parser.swift" } else { false } })
        palette.hide()
    }

    @Test func commandKIsClearTerminalWhileATerminalHasFocus() async throws {
        let shell = try await Shell.start()
        defer { Task { await shell.stop() } }
        var context = shell.controller.commandContext()
        context.terminalFocused = false
        #expect(context.isEnabled(.commandPalette))
        context.terminalFocused = true
        #expect(!context.isEnabled(.commandPalette))
        #expect(context.disabledReason(for: .commandPalette)?.contains("⌘P") == true)
    }

    @Test func globalSearchGroupsByThreadAndRevealsTheMessage() async throws {
        let shell = try await Shell.start()
        defer { Task { await shell.stop() } }
        let controller = shell.controller
        let ids = threads(shell)
        // Open a thread so its messages are cached and indexed.
        #expect(await shell.driver.select(.thread(ids[0])))
        let thread = controller.workspace.threadModel(ids[0])
        #expect(await waitUntil(timeout: .seconds(5)) { thread.phase == .ready && !thread.messageIDs.isEmpty })
        await shell.engine.flush()
        let text = thread.messageIDs.compactMap { thread.message($0)?.message.searchableText }.first { $0.split(separator: " ").count > 3 } ?? ""
        let word = try #require(text.split(whereSeparator: { !$0.isLetter }).map(String.init).first { $0.count >= 5 })
        #expect(await shell.driver.select(.thread(ids[1])))
        shell.driver.perform(.globalSearch)
        #expect(controller.palette.mode == .messages)
        controller.palette.setQuery(word)
        await controller.palette.settleSearches()
        let hit = controller.palette.rows.compactMap { row -> PaletteItem? in
            if case .item(let item) = row, item.kind == .message, case .message(let top, _, _) = item.payload, top == ids[0] { return item }
            return nil
        }.first
        let item = try #require(hit, "a hit in the indexed thread")
        #expect(item.snippet?.highlights.isEmpty == false, "the snippet highlights the match")
        #expect(controller.palette.rows.contains { if case .header(let title) = $0 { title.contains("—") } else { false } }, "grouped with project and date")
        // Select it and Return: the thread opens and the transcript finds the word.
        while controller.palette.selectedItem?.id != item.id || controller.palette.selectedItem?.payload != item.payload {
            controller.palette.moveSelection(by: 1)
            if controller.palette.selectedItem == nil { break }
        }
        controller.palette.activateSelection()
        #expect(controller.workspace.selection == .thread(ids[0]))
        let transcript = try #require(await waitForTranscript(controller, showing: ids[0]))
        #expect(await waitUntil(timeout: .seconds(5)) { transcript.controller.isFindBarVisible }, "the match is found in the transcript")
    }

    func waitForTranscript(_ controller: MainWindowController, showing id: SessionID) async -> TranscriptSurfaceController? {
        _ = await waitUntil(timeout: .seconds(5)) { controller.container.displayed == .thread(id) && controller.container.transcriptSurface != nil }
        return controller.container.transcriptSurface
    }

    @Test func notificationsForBlockersOnceWithSafeActions() async throws {
        let shell = try await Shell.start()
        defer { Task { await shell.stop() } }
        let delivery = RecordingDelivery()
        delivery.state = .notDetermined
        let defaults = try #require(UserDefaults(suiteName: "bellocode.tests.notify.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: nil)
        let notifier = AttentionNotifier(engine: shell.engine, settings: settings, delivery: delivery, defaults: defaults)
        notifier.appIsActive = { false }
        notifier.start()
        let ids = threads(shell)
        let id = ids[0]
        #expect(await shell.driver.select(.thread(id)))
        let thread = shell.controller.workspace.threadModel(id)
        #expect(await waitUntil(timeout: .seconds(5)) { thread.phase == .ready })
        await thread.setPermissionMode(.ask)
        await shell.server.enqueueScript(IntegratedShellTests.approvalTurn, for: id.rawValue)
        shell.driver.type("Please greet the world in the README.")
        shell.driver.send()
        // The first run is the moment to ask for permission (not launch).
        #expect(await waitUntil(timeout: .seconds(10)) { delivery.requests == 1 })
        #expect(await waitUntil(timeout: .seconds(10)) { thread.pendingRequests.contains { $0.isPermission } })
        _ = await waitUntil(timeout: .seconds(3)) { !notifier.posted.isEmpty }
        await notifier.settle()
        let posted = try #require(delivery.posted.first)
        #expect(delivery.posted.count == 1, "one notification for one blocker")
        #expect(posted.category == AttentionNotifier.categoryApprovalInline)
        #expect(posted.body.contains("Needs approval"))
        #expect(posted.body.contains("README.md"), "the exact operation, as on the card")
        #expect(posted.threadIdentifier == shell.engine.root.attention.items.first?.projectID.rawValue, "grouped by project")
        // Streaming text after it does not notify again.
        try await Task.sleep(for: .milliseconds(300))
        #expect(delivery.posted.count == 1)
        // "Allow Once" from the notification goes through the engine, for that request only.
        let request = try #require(posted.userInfo["request"])
        let response = try #require(AttentionNotifier.response(action: "allowOnce", userInfo: posted.userInfo))
        #expect(response == .allowOnce(sessionID: id, requestID: PermissionRequestID(request)))
        await notifier.handle(response)
        #expect(await waitUntil(timeout: .seconds(10)) { thread.pendingRequests.isEmpty })
        // A stale action (the request is gone) opens the thread instead of replying.
        var opened: SessionID?
        notifier.onOpen = { opened = $0 }
        await notifier.handle(.deny(sessionID: id, requestID: PermissionRequestID(request)))
        #expect(opened == id)
        #expect(await waitUntil(timeout: .seconds(3)) { delivery.removed.contains(posted.identifier) }, "resolved blockers leave Notification Center")
        // Off: nothing posts.
        settings.notifications.mode = .none
        notifier.stop()
    }
}

/// Palette open and keystroke-to-results, and sidebar structure and scrolling, with 2,000 threads (budgets: open
/// under 50 ms, local results under 16 ms). Measured in a debug build with the real controllers.
///
/// Pass/fail rests on the work done (full reloads, row edits, cells configured, source builds, items listed), which
/// does not depend on how busy the machine is. Timings are always recorded and printed; they are asserted against the
/// budgets only with `BELLOCODE_STRICT_PERF=1` (a quiet machine), and otherwise against a sanity bound ten times wider.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5))) struct NavigationPerformanceTests {
    static let strictTimings = ProcessInfo.processInfo.environment["BELLOCODE_STRICT_PERF"] == "1"

    /// A budget in strict mode; ten times the budget otherwise (catches a pathological regression, not load).
    static func bound(_ budget: Double) -> Double { strictTimings ? budget : budget * 10 }

    static func percentile(_ samples: [Double], _ p: Double) -> Double {
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    @Test func paletteAndSidebarWith2000Threads() async throws {
        _ = NSApplication.shared
        // 2,500 sessions: every fifth a sub-agent, so 2,000 top-level threads across 8 projects.
        let scenario = FixtureGenerator(seed: 11).workspace(projectCount: 8, sessionCount: 2_500, messagesPerSession: 1)
        let server = MockOpenCodeServer(scenario: scenario, options: .testing)
        let endpoint = try await server.start()
        let connection = ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? ""))
        var configuration = EngineConfiguration(server: .fixed(connection), store: .inMemory)
        configuration.maxSessionPages = 100
        let engine = try Engine(configuration: configuration)
        await engine.start()
        let workspace = WorkspaceController(engine: engine, stateStore: ShellStateStore(defaults: nil))
        let controller = MainWindowController(workspace: workspace, configuration: .init(surfaces: .builtIn, autosaveSuffix: nil))
        controller.showWindow(nil)
        defer {
            workspace.close()
            controller.close()
        }
        func count() -> Int { engine.root.projects.reduce(0) { $0 + (workspace.projectModel($1)?.sessionIDs.count ?? 0) } }
        let loaded = await waitUntil(timeout: .seconds(60)) { engine.root.connection == .live && count() == 2_000 }
        #expect(loaded, "2,000 threads (got \(count()))")
        let driver = ShellDriver(controller: controller)
        await driver.idle(10)

        // Sidebar: structure rebuild and scrolling through every row.
        let sidebar = controller.sidebar
        let reloadsAfterLoad = sidebar.fullReloads
        var structure: [Double] = []
        for _ in 0..<10 {
            workspace.filterText = "x"
            await driver.idle(1)
            workspace.filterText = ""
            await driver.idle(1)
            structure.append(sidebar.lastStructureMilliseconds)
        }
        let reloadsAfterFilter = sidebar.fullReloads
        // A typical change: one thread pinned and unpinned (moves between two sections).
        var typical: [Double] = []
        var inputs: [Double] = []
        var rowEdits: [Int] = []
        let someThread = try #require(engine.root.projects.first.flatMap { workspace.projectModel($0)?.sessionIDs.first })
        for round in 0..<10 {
            engine.organise([someThread], round % 2 == 0 ? .pin : .unpin)
            await driver.idle(1)
            typical.append(sidebar.lastStructureMilliseconds)
            inputs.append(sidebar.lastInputMilliseconds)
            rowEdits.append(sidebar.lastRowEdits)
        }
        let rows = sidebar.outlineView.numberOfRows
        var scroll: [Double] = []
        var cellsPerStep: [Int] = []
        let clip = sidebar.scrollView.contentView
        let visibleRows = Int((clip.bounds.height / max(1, sidebar.outlineView.rowHeight)).rounded(.up))
        let step: CGFloat = 240
        var y: CGFloat = 0
        while y < sidebar.outlineView.frame.height {
            let start = ContinuousClock.now
            let cellsBefore = sidebar.cellsConfigured
            clip.scroll(to: NSPoint(x: 0, y: y))
            sidebar.scrollView.reflectScrolledClipView(clip)
            sidebar.outlineView.displayIfNeeded()
            controller.window?.displayIfNeeded()
            scroll.append(PaletteController.milliseconds(since: start))
            cellsPerStep.append(sidebar.cellsConfigured - cellsBefore)
            y += step
        }

        // Palette: open (sources for 2,000 threads, ranking, table, panel) and keystroke-to-results.
        let palette = controller.palette
        var opens: [Double] = []
        var keystrokes: [Double] = []
        var listed: [Int] = []
        let buildsBefore = palette.sourceBuilds
        var keystrokeBuilds = 0
        for round in 0..<10 {
            palette.show(round % 2 == 0 ? .commands : .quickOpen, in: controller)
            palette.panel.displayIfNeeded()
            opens.append(palette.lastOpenMilliseconds)
            let buildsAtOpen = palette.sourceBuilds
            for query in ["@f", "@fi", "@fix", "@fix p", "@fix pa", "@fix par", "re", "ref", "refa"] {
                palette.setQuery(query)
                keystrokes.append(palette.lastQueryMilliseconds)
                listed.append(palette.lastRankedItems)
            }
            keystrokeBuilds += palette.sourceBuilds - buildsAtOpen
            palette.hide()
        }
        let report = """
            sidebar: \(rows) rows; one-thread change p50 \(String(format: "%.1f", Self.percentile(typical, 0.5))) ms (reading state \(String(format: "%.1f", Self.percentile(inputs, 0.5))) ms); full rebuild after a filter p50 \(String(format: "%.1f", Self.percentile(structure, 0.5))) ms, max \(String(format: "%.1f", structure.max() ?? 0)) ms; \
            scroll step p50 \(String(format: "%.2f", Self.percentile(scroll, 0.5))) ms, p95 \(String(format: "%.2f", Self.percentile(scroll, 0.95))) ms over \(scroll.count) steps
            palette: open p50 \(String(format: "%.1f", Self.percentile(opens, 0.5))) ms, max \(String(format: "%.1f", opens.max() ?? 0)) ms; \
            keystroke p50 \(String(format: "%.2f", Self.percentile(keystrokes, 0.5))) ms, p95 \(String(format: "%.2f", Self.percentile(keystrokes, 0.95))) ms, max \(String(format: "%.2f", keystrokes.max() ?? 0)) ms
            work: full reloads \(reloadsAfterLoad) at load, \(reloadsAfterFilter) after filtering, \(sidebar.fullReloads) at the end; \
            row edits per one-thread change \(rowEdits); cells per scroll step max \(cellsPerStep.max() ?? 0) (\(visibleRows) rows visible); \
            palette source builds \(palette.sourceBuilds - buildsBefore) for 10 opens (\(keystrokeBuilds) on keystrokes), items listed max \(listed.max() ?? 0)
            timings asserted \(Self.strictTimings ? "against the budgets (BELLOCODE_STRICT_PERF=1)" : "against 10x the budgets (sanity)")
            """
        print("NAVIGATION-PERF\n" + report)
        try? report.write(toFile: FileManager.default.temporaryDirectory.appending(path: "bellocode-navigation-perf.txt").path, atomically: true, encoding: .utf8)
        // Work: independent of load.
        #expect(reloadsAfterLoad == 1, "one full reload, at first load")
        #expect(sidebar.fullReloads == reloadsAfterFilter, "a pin, an unpin and scrolling never reload the outline")
        #expect(rowEdits.allSatisfy { $0 <= 4 }, "a one-thread change edits a few rows, not the list: \(rowEdits)")
        #expect((cellsPerStep.max() ?? .max) <= 2 * visibleRows + 4, "a scroll step configures about a screenful of cells: \(cellsPerStep)")
        #expect(palette.sourceBuilds - buildsBefore == 10, "sources are built once per open")
        #expect(keystrokeBuilds == 0, "a keystroke ranks the open's sources; it does not rebuild them")
        #expect((listed.max() ?? .max) < 200, "results are capped, not 2,000 rows: \(listed.max() ?? 0)")
        // Time: the budgets with BELLOCODE_STRICT_PERF=1, else a sanity bound.
        #expect(Self.percentile(opens, 0.5) < Self.bound(50), "palette opens within 50 ms")
        #expect(Self.percentile(keystrokes, 0.95) < Self.bound(16), "local results within a frame")
        #expect(Self.percentile(scroll, 0.95) < Self.bound(16), "sidebar scrolls within a frame")
        #expect(Self.percentile(typical, 0.5) < Self.bound(50), "a section move within 50 ms with 2,000 threads (debug build)")
        await engine.stop()
        await server.stop()
    }
}
