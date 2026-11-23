import AppKit
import BelloCore
import Foundation
import Testing

@testable import BelloCodeApp

@Suite struct LaunchOptionsTests {
    @Test func parsesModes() throws {
        #expect(try LaunchOptions.parse(["app"]) == LaunchOptions())
        #expect(try LaunchOptions.parse(["app", "--smoke-test"]).mode == .smokeTest)
        #expect(try LaunchOptions.parse(["app", "--mock"]).mock == .demo)
        #expect(try LaunchOptions.parse(["app", "--mock", "large"]).mock == .large)
        let snapshot = try LaunchOptions.parse(["app", "--snapshot", "shell", "--snapshot-dir", "/tmp/x"])
        #expect(snapshot.mode == .snapshot(name: "shell"))
        #expect(snapshot.mock == .demo, "a snapshot always runs against the mock")
        #expect(snapshot.snapshotDirectory == "/tmp/x")
        // AppKit's own arguments are skipped with their values.
        #expect(try LaunchOptions.parse(["app", "-NSDocumentRevisionsDebugMode", "YES", "--mock"]).mock == .demo)
    }

    /// S1: a release build has no mock, snapshot or attach mode, and the bundled runtime must be complete.
    @Test func releaseBuildsRefuseDevelopmentModes() throws {
        for flag in ["--mock", "--snapshot", "--snapshot-dir"] {
            #expect(throws: LaunchOptions.ParseError.self) { try LaunchOptions.parse(["app", flag, "x"], development: false) }
        }
        #expect(try LaunchOptions.parse(["app", "--smoke-test"], development: false).mode == .smokeTest)
    }

    @Test func aBundleWithoutTheServerOrHelperDoesNotStart() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-s1-\(UUID().uuidString).app", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let helpers = root.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let bundle = try #require(Bundle(url: root))
        let server = AppRuntime.bundledServerConfiguration(bundle: bundle, dataRoot: root.appending(path: "data"))
        #expect(throws: AppRuntime.LaunchError.incompleteBundle(["Contents/Helpers/opencode", "Contents/Helpers/bellocode-exec"])) {
            try AppRuntime.requireBundledRuntime(server)
        }
        let opencode = helpers.appending(path: "opencode")
        FileManager.default.createFile(atPath: opencode.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        #expect(throws: AppRuntime.LaunchError.incompleteBundle(["Contents/Helpers/bellocode-exec"])) { try AppRuntime.requireBundledRuntime(server) }
        FileManager.default.createFile(atPath: helpers.appending(path: "bellocode-exec").path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        try AppRuntime.requireBundledRuntime(server)
        var noContainers = server
        noContainers.containerExecution = nil
        #expect(throws: AppRuntime.LaunchError.self) { try AppRuntime.requireBundledRuntime(noContainers) }
    }

    @Test func rejectsBadArguments() {
        #expect(throws: LaunchOptions.ParseError.self) { try LaunchOptions.parse(["app", "--mock", "huge"]) }
        #expect(throws: LaunchOptions.ParseError.self) { try LaunchOptions.parse(["app", "--snapshot"]) }
        #expect(throws: LaunchOptions.ParseError.self) { try LaunchOptions.parse(["app", "--snapshot", "../x"]) }
    }
}

/// v1.0.1 NF07: the right panel ships no placeholder tab; a "files" selection saved by an earlier version falls back.
@MainActor @Suite struct RightPanelTabsTests {
    @Test func noPlaceholderTabAndAStaleSelectionFallsBack() {
        let tabs = ShellSurfaces.builtIn.rightPanelTabs
        #expect(!tabs.map(\.id).contains("files"))
        #expect(tabs.map(\.id) == ["changes", "browser", "terminal", "agents", "mergeRequests", "auto", "chrome"])
        let panel = RightPanelViewController(tabs: tabs, selectedID: "files")
        #expect(panel.selectedID == "changes")
    }
}

@Suite struct ShellStateTests {
    @Test func roundTripsEverything() {
        var state = ShellState()
        state.selection = .thread("ses_1")
        state.collapsedProjects = ["/a"]
        state.isNeedsYouCollapsed = true
        state.isSidebarCollapsed = true
        state.isRightPanelVisible = true
        state.isTerminalVisible = true
        state.rightPanelTab = "agents"
        state.manualUnread = ["ses_2"]
        state.newThreadDrafts = ["/a": "hello"]
        #expect(ShellState.decode(state.encoded()) == state)
        var draft = ShellState()
        draft.selection = .draft(directory: "/b")
        #expect(ShellState.decode(draft.encoded()).selection == .draft(directory: "/b"))
    }

    @Test func unreadableOrOtherVersionFallsBackToDefaults() {
        #expect(ShellState.decode(nil) == ShellState())
        #expect(ShellState.decode(Data("not json".utf8)) == ShellState())
        var future = ShellState()
        future.version = 99
        future.isTerminalVisible = true
        #expect(ShellState.decode(future.encoded()) == ShellState())
    }

    @Test func boundsCachesAndDropsEmptyDrafts() {
        var state = ShellState()
        state.manualUnread = (0..<(ShellState.maxManualUnread + 20)).map { SessionID("ses_\($0)") }
        state.newThreadDrafts = Dictionary(uniqueKeysWithValues: (0..<80).map { ("/p\($0)", "x") })
        state.newThreadDrafts["/empty"] = ""
        let bounded = ShellState.decode(state.encoded())
        #expect(bounded.manualUnread.count == ShellState.maxManualUnread)
        #expect(bounded.manualUnread.last == SessionID("ses_\(ShellState.maxManualUnread + 19)"), "newest kept")
        #expect(bounded.newThreadDrafts.count <= ShellState.maxNewThreadDrafts)
        #expect(bounded.newThreadDrafts["/empty"] == nil)
    }

    @MainActor @Test func storeUsesItsOwnSuite() throws {
        let suite = "BelloCodeAppTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShellStateStore(defaults: defaults)
        var state = ShellState()
        state.selection = .thread("ses_9")
        store.save(state)
        #expect(store.load().selection == .thread("ses_9"))
        #expect(ShellStateStore(defaults: nil).load() == ShellState())
    }
}

@Suite struct CanonicalDirectoryTests {
    @Test func resolvesSymlinksAndTrailingSlash() {
        #expect(WorkspaceController.canonicalDirectory(URL(filePath: "/tmp/", directoryHint: .isDirectory)) == "/private/tmp")
        #expect(WorkspaceController.canonicalDirectory(URL(filePath: "/private/tmp/../tmp")) == "/private/tmp")
        #expect(WorkspaceController.canonicalDirectory(URL(filePath: "/")) == "/")
    }
}

@Suite struct CommandValidationTests {
    let thread = CommandTarget.thread("ses_1", directory: "/p", isRunning: false)
    let running = CommandTarget.thread("ses_1", directory: "/p", isRunning: true)

    @Test func nothingSelected() {
        let context = CommandContext(hasProjects: false)
        #expect(context.isEnabled(.addProject))
        #expect(!context.isEnabled(.newThread), "new thread needs a project")
        for command in [ShellCommand.renameThread, .archiveThread, .deleteThread, .markUnread, .revealInFinder, .copyPath, .stopRun, .sendMessage, .nextNeedsAttention, .focusComposer] {
            #expect(!context.isEnabled(command), "\(command)")
        }
        #expect(context.isEnabled(.focusNextRegion))
        #expect(context.isEnabled(.toggleTerminal))
    }

    @Test func threadSelected() {
        var context = CommandContext(hasProjects: true, target: thread, composerVisible: true)
        for command in [ShellCommand.newThread, .renameThread, .archiveThread, .deleteThread, .markUnread, .togglePinProject, .removeProject, .revealInFinder, .copyPath, .focusComposer] {
            #expect(context.isEnabled(command), "\(command)")
        }
        #expect(!context.isEnabled(.stopRun), "stop only while running")
        #expect(!context.isEnabled(.sendMessage), "send needs text")
        context.composerHasText = true
        #expect(context.isEnabled(.sendMessage))
        context.target = running
        #expect(context.isEnabled(.stopRun))
    }

    @Test func projectAndDraftTargetsHaveNoThreadCommands() {
        for target in [CommandTarget.project(directory: "/p", isPinned: false), .draft(directory: "/p", isPinned: true)] {
            let context = CommandContext(hasProjects: true, target: target)
            #expect(!context.isEnabled(.archiveThread))
            #expect(!context.isEnabled(.renameThread))
            #expect(context.isEnabled(.togglePinProject))
            #expect(context.isEnabled(.revealInFinder))
        }
    }

    @Test func textEditingKeysWinWhileTyping() {
        var context = CommandContext(hasProjects: true, target: thread, textInputFocused: true)
        #expect(!context.isEnabled(.archiveThread), "⌘⌫ deletes to line start in text")
        #expect(!context.isEnabled(.deleteThread))
        #expect(context.isEnabled(.markUnread))
        context.textInputFocused = false
        #expect(context.isEnabled(.archiveThread))
    }

    @Test func dynamicTitles() {
        var context = CommandContext(targetProjectPinned: true, isTerminalVisible: true)
        #expect(context.title(for: .togglePinProject) == "Unpin Project")
        #expect(context.title(for: .toggleTerminal) == "Hide Terminal")
        context.targetProjectPinned = false
        context.isTerminalVisible = false
        #expect(context.title(for: .togglePinProject) == "Pin Project")
        #expect(context.title(for: .toggleTerminal) == "Show Terminal")
    }

    @MainActor @Test func everyCommandHasAUniqueSelectorAndShortcut() {
        let selectors = ShellCommand.allCases.map(\.selector)
        #expect(Set(selectors).count == selectors.count)
        for command in ShellCommand.allCases { #expect(ShellCommand.command(for: command.selector) == command) }
        // Focus-aware: a shortcut may be shared only by commands that are never enabled together (⌘K: Command Palette
        // outside a terminal, Clear Terminal inside one). Checked over every focus state with everything else enabled.
        let grouped = Dictionary(grouping: ShellCommand.allCases.filter { !$0.shortcut.key.isEmpty }) {
            "\($0.shortcut.key)-\($0.shortcut.modifiers.rawValue)"
        }
        for (key, commands) in grouped where commands.count > 1 {
            #expect(commands.count == 2, "\(key) is shared by \(commands)")
            for terminalFocused in [false, true] {
                var context = CommandContext.everythingAvailable
                context.terminalFocused = terminalFocused
                let enabled = commands.filter(context.isEnabled)
                #expect(enabled.count <= 1, "\(key): \(enabled) are enabled together (terminal focused: \(terminalFocused))")
            }
        }
        #expect(grouped.values.filter { $0.count > 1 }.map { Set($0) } == [[.commandPalette, .clearTerminal]], "only ⌘K is shared")
        #expect(ShellCommand.newThread.shortcut.key == "n")
        #expect(ShellCommand.nextNeedsAttention.shortcut.modifiers == [.command, .option])
    }

    @MainActor @Test func mainMenuContainsEveryCommand() {
        _ = NSApplication.shared
        let menu = MainMenu.make()
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
        let actions = Set(all(menu).compactMap(\.action))
        for command in ShellCommand.allCases { #expect(actions.contains(command.selector), "\(command) is in the menu") }
        #expect(actions.contains(#selector(NSText.copy(_:))), "standard editing stays")
    }

    @Test func nextNeedsAttentionCycles() {
        let items: [SessionID] = ["a", "b", "c"]
        #expect(nextAttention(after: nil, in: items) == "a")
        #expect(nextAttention(after: "a", in: items) == "b")
        #expect(nextAttention(after: "c", in: items) == "a")
        #expect(nextAttention(after: "zzz", in: items) == "a")
        #expect(nextAttention(after: "a", in: []) == nil)
    }
}

@Suite struct SidebarTreeTests {
    @Test func needsYouFirstThenProjects() {
        let input = SidebarTree.Input(
            attention: ["s2", "s9"],
            projects: [.init(directory: "/a", threadIDs: ["s1", "s2"]), .init(directory: "/b", threadIDs: [])])
        let tree = SidebarTree.build(input)
        #expect(tree.map(\.id) == [.needsYouHeader, .projectsHeader])
        #expect(tree[0].children.map(\.id) == [.attention("s2"), .attention("s9")])
        #expect(tree[1].children.map(\.id) == [.project("/a"), .project("/b")])
        #expect(tree[1].children[0].children.map(\.id) == [.section(scope: "/a", .active)])
        #expect(tree[1].children[0].children[0].children.map(\.id) == [.thread("s1"), .thread("s2")])
        #expect(tree[1].children[1].children.map(\.id) == [.emptyProject("/b")], "empty projects say so")
    }

    @Test func noAttentionNoHeaderAndNoProjectsNoTree() {
        #expect(SidebarTree.build(.init(projects: [.init(directory: "/a", threadIDs: ["s1"])])).map(\.id) == [.projectsHeader])
        #expect(SidebarTree.build(.init()).isEmpty)
    }

    @Test func identitiesAreUniqueEvenWithDuplicateInput() {
        let input = SidebarTree.Input(
            attention: ["s1", "s1"],
            projects: [.init(directory: "/a", threadIDs: ["s1", "s1"]), .init(directory: "/a", threadIDs: ["s3"])])
        let ids = SidebarTree.flatten(SidebarTree.build(input))
        #expect(Set(ids).count == ids.count)
    }

    @Test func statusChangesDoNotMoveRows() {
        // The engine keeps creation order; only the "Needs you" group changes when a thread needs the user.
        let base = SidebarTree.Input(projects: [.init(directory: "/a", threadIDs: ["s3", "s2", "s1"])])
        var blocked = base
        blocked.attention = ["s1"]
        let before = SidebarTree.build(base)[0]
        let after = SidebarTree.build(blocked)[1]
        #expect(before == after, "project rows identical")
    }

    @Test func selectionMapsToTheProjectRowFirst() {
        let tree = SidebarTree.build(.init(attention: ["s1", "s5"], projects: [.init(directory: "/a", threadIDs: ["s1"])]))
        #expect(SidebarTree.node(for: .thread("s1"), in: tree) == .thread("s1"))
        #expect(SidebarTree.node(for: .thread("s5"), in: tree) == .attention("s5"))
        #expect(SidebarTree.node(for: .thread("nope"), in: tree) == nil)
        #expect(SidebarTree.node(for: .draft(directory: "/a"), in: tree) == .project("/a"))
        #expect(SidebarTree.node(for: nil, in: tree) == nil)
    }

    @Test func parentsDetectMoves() {
        let one = SidebarTree.build(.init(projects: [.init(directory: "/a", threadIDs: ["s1"]), .init(directory: "/b", threadIDs: [])]))
        let parents = SidebarTree.parents(one)
        #expect(parents[.thread("s1")] == .some(.section(scope: "/a", .active)))
        #expect(parents[.section(scope: "/a", .active)] == .some(.project("/a")))
        #expect(parents[.projectsHeader] == .some(nil))
    }
}

@Suite struct ThreadRowPresentationTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func session(idle: Double? = nil, busy: Double? = nil, title: String? = "Fix tests") -> Session {
        let t = Timestamp(milliseconds: (now.timeIntervalSince1970 - 600) * 1000)
        return Session(
            id: "ses_1", projectID: "p", title: title, directory: "/p", created: t, updated: t,
            busySince: busy.map { Timestamp(milliseconds: $0) }, idleAt: idle.map { Timestamp(milliseconds: $0) })
    }

    @Test func statusIsNeverColourOnly() {
        for status in SessionStatus.allCases {
            let row = ThreadRowPresentation(session: session(), status: status, manuallyUnread: false, childCount: 0, now: now)
            if status != .idle { #expect(row.accessibilityLabel.contains(status.label), "\(status)") }
            if status != .idle && status != .finishedUnread { #expect(row.glyphStatus == status) }
        }
    }

    @Test func unreadFromStatusOrManualMark() {
        let finished = ThreadRowPresentation(session: session(), status: .finishedUnread, manuallyUnread: false, childCount: 0, now: now)
        #expect(finished.isUnread && finished.glyphStatus == nil)
        let manual = ThreadRowPresentation(session: session(), status: .idle, manuallyUnread: true, childCount: 0, now: now)
        #expect(manual.isUnread)
        #expect(manual.accessibilityLabel.contains("Unread"))
        let read = ThreadRowPresentation(session: session(), status: .idle, manuallyUnread: false, childCount: 0, now: now)
        #expect(!read.isUnread && read.glyphStatus == nil)
    }

    @Test func titleTimeChildrenAndProject() {
        let row = ThreadRowPresentation(
            session: session(title: nil), status: .running, manuallyUnread: false, childCount: 2, projectName: "atlas", now: now)
        #expect(row.title == "New thread")
        #expect(row.timeText == "10m")
        #expect(row.childCount == 2)
        #expect(row.accessibilityLabel.contains("2 sub-agents"))
        #expect(row.accessibilityLabel.contains("atlas"))
        // No derived status yet: falls back to the session's own running flag.
        let fallback = ThreadRowPresentation(session: session(busy: 1), status: nil, manuallyUnread: false, childCount: 0, now: now)
        #expect(fallback.status == .running)
    }
}

@MainActor @Suite struct UndoTests {
    @Test func toastQueueExpiresAfterFiveSeconds() {
        var queue = ToastQueue()
        let start = Date(timeIntervalSince1970: 0)
        let token = ObjectIdentifier(NSObject())
        queue.show(message: "Archived", token: token, now: start)
        let early = queue.expire(now: start.addingTimeInterval(4.9))
        #expect(!early)
        #expect(queue.current?.message == "Archived")
        let due = queue.expire(now: start.addingTimeInterval(5))
        #expect(due)
        #expect(queue.current == nil)
        queue.show(message: "A", token: token, now: start)
        queue.show(message: "B", token: nil, now: start)
        #expect(queue.current?.message == "B", "a newer action replaces the toast")
    }

    @Test func undoAndRedoThroughTheUndoManager() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let coordinator = UndoCoordinator(undoManager: { manager })
        var archived = false
        manager.beginUndoGrouping()
        coordinator.perform(ReversibleAction(name: "Archive Thread", message: "Archived", apply: { archived = true }, revert: { archived = false }))
        manager.endUndoGrouping()
        #expect(archived)
        #expect(manager.undoActionName == "Archive Thread")
        #expect(coordinator.toasts.current?.message == "Archived")
        manager.undo()
        #expect(!archived)
        #expect(coordinator.toasts.current == nil, "undoing the toast's action hides it")
        #expect(manager.canRedo)
        manager.redo()
        #expect(archived)
    }

    @Test func toastUndoRemovesOnlyItsOwnEntry() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let coordinator = UndoCoordinator(undoManager: { manager })
        var log: [String] = []
        manager.beginUndoGrouping()
        coordinator.perform(ReversibleAction(name: "First", message: "1", apply: { log.append("a1") }, revert: { log.append("r1") }))
        manager.endUndoGrouping()
        manager.beginUndoGrouping()
        coordinator.perform(ReversibleAction(name: "Second", message: "2", apply: { log.append("a2") }, revert: { log.append("r2") }))
        manager.endUndoGrouping()
        coordinator.undoFromToast()
        #expect(log == ["a1", "a2", "r2"])
        #expect(coordinator.toasts.current == nil)
        #expect(manager.undoActionName == "First", "the toast's entry is gone; earlier ones stay")
        coordinator.undoFromToast()
        #expect(log == ["a1", "a2", "r2"], "nothing visible to undo")
        manager.undo()
        #expect(log.last == "r1")
    }

    @Test func noticesHaveNoUndo() {
        let coordinator = UndoCoordinator(undoManager: { nil })
        coordinator.showNotice("Copied")
        #expect(coordinator.toasts.current?.token == nil)
        coordinator.undoFromToast()
        #expect(coordinator.toasts.current?.message == "Copied")
    }
}
