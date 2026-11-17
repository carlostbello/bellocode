import AgentUI
import AppKit
import BelloCore
import Engine
import Foundation
import Testing

@testable import BelloCodeApp

extension CommandContext {
    /// Every input that enables a command set (for shortcut-conflict checks).
    static var everythingAvailable: CommandContext {
        var context = CommandContext(
            hasProjects: true, target: .thread("s1", directory: "/a", isRunning: true), attentionCount: 1, composerVisible: true,
            composerHasText: true, composerRunning: true, hasUnconfirmedSend: true,
            availableRequestCommands: Set(RequestCommandAll.all), terminalAvailable: true, terminalSelected: true,
            terminalHasSelectedText: true)
        context.availableTranscriptCommands = Set(ShellCommand.allCases)
        context.selectedThreadCount = 1
        context.targetsSnoozed = true
        context.canGoBack = true
        context.canGoForward = true
        context.canReopenClosedThread = true
        context.projectCanMoveUp = true
        context.projectCanMoveDown = true
        return context
    }
}

enum RequestCommandAll { static let all = RequestCommand.allCases }

@Suite struct SectionTreeTests {
    func project(_ directory: String, _ sections: [ThreadSection: [SessionID]]) -> SidebarTree.Project {
        SidebarTree.Project(directory: directory, sections: sections)
    }

    @Test func projectsListTheirNonEmptySectionsInOrder() {
        let tree = SidebarTree.build(.init(
            attention: ["b"],
            projects: [project("/p", [.settled: ["e"], .pinned: ["a"], .working: ["c"], .active: ["b"], .snoozed: ["d"]])]))
        #expect(tree.map(\.id) == [.needsYouHeader, .projectsHeader])
        let sections = tree[1].children[0].children.map(\.id)
        #expect(sections == [.section(scope: "/p", .pinned), .section(scope: "/p", .active), .section(scope: "/p", .working),
                             .section(scope: "/p", .snoozed), .section(scope: "/p", .settled)])
    }

    @Test func groupedByStateListsSectionsAcrossProjects() {
        let tree = SidebarTree.build(.init(
            projects: [project("/a", [.active: ["a1"], .settled: ["a2"]]), project("/b", [.active: ["b1"]])], grouping: .byState))
        #expect(tree.map(\.id) == [.section(scope: nil, .active), .section(scope: nil, .settled)])
        #expect(tree[0].children.map(\.id) == [.thread("a1"), .thread("b1")])
        #expect(SidebarNodeID.section(scope: nil, .active).isGroup)
        #expect(!SidebarNodeID.section(scope: "/a", .active).isGroup)
    }

    @Test func filteringHidesEmptyProjectsAndSaysWhenNothingMatches() {
        let projects = [project("/a", [.active: ["fix"]]), project("/b", [.active: ["docs"]])]
        let titles: [SessionID: String] = ["fix": "Fix parser", "docs": "Write docs"]
        let filtered = SidebarFilter.apply("parser", projects: projects, projectName: { $0 == "/a" ? "Alpha" : "Beta" }, title: { titles[$0] ?? "" })
        let tree = SidebarTree.build(.init(projects: filtered, isFiltering: true))
        #expect(tree[0].children.map(\.id) == [.project("/a")])
        // A project whose name matches keeps all its threads.
        let byName = SidebarFilter.apply("beta", projects: projects, projectName: { $0 == "/a" ? "Alpha" : "Beta" }, title: { titles[$0] ?? "" })
        #expect(byName[1].sections[.active] == ["docs"])
        let none = SidebarFilter.apply("zzz", projects: projects, projectName: { _ in "" }, title: { titles[$0] ?? "" })
        #expect(SidebarTree.build(.init(projects: none, isFiltering: true)).map(\.id) == [.noResults])
    }

    @Test func aSectionMoveRemovesAndInsertsOnlyThatRow() {
        let before = SidebarTree.build(.init(projects: [project("/p", [.active: ["a", "b", "c"], .settled: ["z"]])]))
        let after = SidebarTree.build(.init(projects: [project("/p", [.active: ["a", "c"], .settled: ["b", "z"]])]))
        let update = SidebarTree.update(from: before, to: after)
        #expect(update.removals.count == 1)
        #expect(update.removals[0].parent == .section(scope: "/p", .active) && update.removals[0].index == 1)
        #expect(update.insertions.count == 1)
        #expect(update.insertions[0].parent == .section(scope: "/p", .settled) && update.insertions[0].index == 0)
        #expect(update.inserted == [.thread("b")])
    }

    @Test func aNewSectionIsInsertedWholeAndAnEmptiedOneRemoved() {
        let before = SidebarTree.build(.init(projects: [project("/p", [.active: ["a", "b"], .snoozed: ["s"]])]))
        let after = SidebarTree.build(.init(projects: [project("/p", [.active: ["a", "b", "s"], .working: ["w"]])]))
        let update = SidebarTree.update(from: before, to: after)
        // Snoozed (emptied) goes with its row; Working arrives with its row from the data source.
        #expect(update.removals.map(\.index) == [1])
        #expect(update.removals[0].parent == .project("/p"))
        #expect(update.inserted.contains(.section(scope: "/p", .working)))
        #expect(update.inserted.contains(.thread("s")))
        #expect(!update.inserted.contains(.thread("w")), "a new section's rows come with it")
    }

    @Test func statusOnlyChangesProduceNoOperations() {
        let tree = SidebarTree.build(.init(projects: [project("/p", [.active: ["a", "b"]])]))
        #expect(SidebarTree.update(from: tree, to: tree) == SidebarTree.Update())
    }

    @Test func expansionDefaultsAndToggles() {
        var state = ShellState()
        #expect(state.isSectionExpanded(scope: "/p", .active))
        #expect(!state.isSectionExpanded(scope: "/p", .settled), "settled is collapsed by default")
        #expect(!state.isSectionExpanded(scope: "/p", .snoozed))
        state.setSectionExpanded(scope: "/p", .settled, true)
        state.setSectionExpanded(scope: nil, .active, false)
        #expect(state.isSectionExpanded(scope: "/p", .settled))
        #expect(!state.isSectionExpanded(scope: nil, .active))
        state.setSectionExpanded(scope: "/p", .settled, false)
        #expect(state.toggledSections == ["*|active"])
    }
}

@Suite struct SidebarDropTests {
    let now = Timestamp(milliseconds: 1_000_000)

    func proposal(
        _ threads: [SessionID], to section: ThreadSection, project: String? = "/p", index: Int = 0, rows: [SessionID] = [],
        organisation: [SessionID: ThreadOrganisation] = [:], keys: [SessionID: Double] = [:], projects: [SessionID: String] = [:]
    ) -> SidebarDrop.Proposal {
        var projectOf: [SessionID: String] = [:]
        for id in threads + rows { projectOf[id] = projects[id] ?? "/p" }
        return SidebarDrop.Proposal(
            threads: threads, projectOf: projectOf, organisation: organisation, targetProject: project, targetSection: section,
            index: index, sectionRows: rows, sortKeys: keys, now: now)
    }

    func resolve(_ proposal: SidebarDrop.Proposal) -> SidebarDrop.Outcome {
        SidebarDrop.resolve(proposal, snoozeUntil: Timestamp(milliseconds: 9_000_000))
    }

    @Test func dragBetweenSectionsChangesState() {
        guard case .move(let pinned, let badge) = resolve(proposal(["a"], to: .pinned)) else { Issue.record("forbidden"); return }
        #expect(badge == "Pin" && pinned["a"]?.pinned == true)
        guard case .move(let settled, let settleBadge) = resolve(proposal(["a"], to: .settled, organisation: ["a": ThreadOrganisation(pinned: true)])) else { return }
        #expect(settleBadge == "Settle" && settled["a"]?.settled == true && settled["a"]?.pinned == false)
        guard case .move(let snoozed, let snoozeBadge) = resolve(proposal(["a"], to: .snoozed)) else { return }
        #expect(snoozeBadge.hasPrefix("Snooze until") && snoozed["a"]?.snoozedUntil == Timestamp(milliseconds: 9_000_000))
        let woken = resolve(proposal(["a"], to: .active, organisation: ["a": ThreadOrganisation(snoozedUntil: now, snoozedAt: now)]))
        #expect(woken.badge == "Wake")
        let unsettled = resolve(proposal(["a"], to: .active, organisation: ["a": ThreadOrganisation(settled: true, settledAt: now)]))
        #expect(unsettled.badge == "Un-settle")
    }

    @Test func forbiddenDropsSayWhy() {
        let crossProject = resolve(proposal(["a"], to: .active, project: "/other"))
        #expect(crossProject == .forbidden(SidebarDrop.crossProjectReason))
        #expect(resolve(proposal(["a"], to: .working)) == .forbidden(SidebarDrop.workingReason))
        // Grouped by state (no project): any thread may move between sections.
        #expect(resolve(proposal(["a"], to: .settled, project: nil, projects: ["a": "/x"])).isAllowed)
    }

    @Test func reorderWithinASectionPlacesBetweenNeighbours() throws {
        let rows: [SessionID] = ["a", "b", "c"]
        let keys: [SessionID: Double] = ["a": 300, "b": 200, "c": 100]
        // Drag "c" between "a" and "b" (index 1).
        guard case .move(let changes, _) = resolve(proposal(["c"], to: .active, index: 1, rows: rows, keys: keys)) else {
            Issue.record("forbidden")
            return
        }
        let key = try #require(changes["c"]?.sortKey)
        #expect(key < 300 && key > 200)
        // To the top and the bottom.
        let top = SidebarDrop.sortKeys(inserting: ["c"], before: 0, in: rows, keys: keys)
        #expect(top["c"]! > 300)
        let bottom = SidebarDrop.sortKeys(inserting: ["a"], before: 3, in: rows, keys: keys)
        #expect(bottom["a"]! < 100)
        // Several rows keep their order between the neighbours.
        let two = SidebarDrop.sortKeys(inserting: ["x", "y"], before: 1, in: rows, keys: keys)
        #expect(two["x"]! > two["y"]! && two["x"]! < 300 && two["y"]! > 200)
        // No room left: the section is renumbered, in the intended order.
        let crowded = SidebarDrop.sortKeys(inserting: ["c"], before: 1, in: rows, keys: ["a": 1, "b": 1, "c": 1])
        let order = crowded.sorted { $0.value > $1.value }.map(\.key)
        #expect(order == ["a", "c", "b"])
    }

    @Test func droppingInPlaceChangesNothing() {
        let keys: [SessionID: Double] = ["a": 300, "b": 200]
        guard case .move(let changes, _) = resolve(
            proposal(["a"], to: .active, index: 0, rows: ["a", "b"], organisation: ["a": ThreadOrganisation(sortKey: 300)], keys: keys))
        else { return }
        // A key above b and at or above a's old place; a write is skipped when equal.
        #expect(changes["a"].map { $0.sortKey! > 200 } ?? true)
    }
}

@Suite struct PaletteSearchTests {
    let now = Timestamp(milliseconds: 100 * 86_400_000)

    func item(_ id: String, _ kind: PaletteItem.Kind, _ title: String, disabled: String? = nil) -> PaletteCandidate {
        let payload: PalettePayload = switch kind {
        case .command: .command(.newThread)
        case .thread: .thread(SessionID(id))
        case .project: .project(directory: id, isArchived: false)
        case .file: .file(directory: "/p", path: title)
        case .message: .thread(SessionID(id))
        }
        return PaletteCandidate(
            PaletteItem(id: "\(kind.rawValue):\(id)", kind: kind, payload: payload, title: title, disabledReason: disabled, symbolName: "x"))
    }

    var sources: PaletteSources {
        var sources = PaletteSources()
        sources.commands = [item("newThread", .command, "New Thread"), item("settle", .command, "Settle Thread"),
                            item("stop", .command, "Stop Agent", disabled: "The agent is not running")]
        sources.threads = [item("t1", .thread, "Fix the parser"), item("t2", .thread, "New onboarding flow"), item("t3", .thread, "Settings polish")]
        sources.projects = [item("/p/bello", .project, "BelloCode")]
        sources.files = [item("f1", .file, "Parser.swift")]
        return sources
    }

    @Test func prefixesChooseTheKinds() {
        #expect(PaletteQuery.parse("> new", mode: .quickOpen) == PaletteQuery(scope: .actions, text: "new"))
        #expect(PaletteQuery.parse("@fix", mode: .commands) == PaletteQuery(scope: .threads, text: "fix"))
        #expect(PaletteQuery.parse("#bel", mode: .commands).scope == .projects)
        #expect(PaletteQuery.parse("/par", mode: .commands).scope == .files)
        #expect(PaletteQuery.parse(">x", mode: .messages).scope == .all, "message search has no prefixes")
        let actions = PaletteSearch.results(PaletteQuery(scope: .actions, text: "n"), mode: .quickOpen, sources: sources, frecency: FrecencyIndex(), now: now)
        #expect(actions.map(\.title) == ["Actions"])
    }

    @Test func commandModeListsActionsFirstQuickOpenListsFiles() {
        let commands = PaletteSearch.results(PaletteQuery(scope: .all, text: "new"), mode: .commands, sources: sources, frecency: FrecencyIndex(), now: now)
        #expect(commands.map(\.title) == ["Actions", "Threads"])
        #expect(commands[0].items.first?.title == "New Thread")
        let quick = PaletteSearch.results(PaletteQuery(scope: .all, text: "par"), mode: .quickOpen, sources: sources, frecency: FrecencyIndex(), now: now)
        #expect(quick.map(\.title) == ["Threads", "Files"])
    }

    @Test func frecencyAndRememberedPicksRank() {
        var frecency = FrecencyIndex()
        // Two threads match "s" equally well by title start; the frecent one wins.
        let query = PaletteQuery(scope: .threads, text: "s")
        let plain = PaletteSearch.results(query, mode: .quickOpen, sources: sources, frecency: frecency, now: now)
        #expect(plain[0].items.first?.id == "thread:t3")
        frecency.record("thread:t1", query: "s", now: now)
        let picked = PaletteSearch.results(query, mode: .quickOpen, sources: sources, frecency: frecency, now: now)
        #expect(picked[0].items.first?.id == "thread:t1", "the pick for this query leads")
    }

    @Test func orderIsStableWhileTypingAndDisabledSinks() {
        let first = PaletteSearch.results(PaletteQuery(scope: .actions, text: "t"), mode: .commands, sources: sources, frecency: FrecencyIndex(), now: now)
        let again = PaletteSearch.results(PaletteQuery(scope: .actions, text: "t"), mode: .commands, sources: sources, frecency: FrecencyIndex(), now: now)
        #expect(first == again)
        #expect(first[0].items.last?.title == "Stop Agent", "disabled commands rank after enabled ones")
    }

    @Test func emptyQueryShowsRecentThenDefaults() {
        var frecency = FrecencyIndex()
        frecency.record("thread:t3", now: now)
        frecency.record("command:settle", now: now)
        let sections = PaletteSearch.results(PaletteQuery(scope: .all, text: ""), mode: .commands, sources: sources, frecency: frecency, now: now)
        #expect(sections.first?.title == "Recent")
        #expect(Set(sections[0].items.map(\.id)) == ["thread:t3", "command:settle"])
        #expect(sections[1].title == "Actions")
        #expect(!sections[1].items.contains { $0.id == "command:settle" }, "recent items are not repeated")
    }

    @Test func messageGroupsBecomeSectionsWithSnippets() {
        let group = ThreadSearchGroup(
            sessionID: "t1", title: "Fix the parser", projectID: "p", directory: "/p/bello", isArchived: false,
            hits: [.init(messageID: "m1", sessionID: "t1", snippet: SearchSnippet(text: "split the parser", highlights: [10..<16]), created: now)],
            totalHits: 4, newest: now)
        let sections = PaletteSearch.messageSections([group], projectName: { _ in "BelloCode" }, now: now.date)
        #expect(sections.count == 1)
        #expect(sections[0].title.hasPrefix("Fix the parser — BelloCode"))
        #expect(sections[0].title.contains("4 matches"))
        #expect(sections[0].items[0].payload == .message(thread: "t1", session: "t1", message: "m1"))
        #expect(sections[0].items[0].snippet?.highlights == [10..<16])
    }
}

@Suite struct FocusAwareShortcutTests {
    /// Which command a key press reaches: the first enabled menu item with that key equivalent, in menu-bar order, as
    /// NSMenu resolves key equivalents (a disabled item does not consume its key).
    @MainActor func owner(of key: String, _ modifiers: NSEvent.ModifierFlags, in menu: NSMenu, context: CommandContext) -> ShellCommand? {
        for item in menu.items {
            if let submenu = item.submenu, let found = owner(of: key, modifiers, in: submenu, context: context) { return found }
            guard item.keyEquivalent == key, item.keyEquivalentModifierMask == modifiers, let action = item.action,
                  let command = ShellCommand.command(for: action), context.isEnabled(command)
            else { continue }
            return command
        }
        return nil
    }

    @MainActor @Test func commandKIsThePaletteExceptInAFocusedTerminal() {
        _ = NSApplication.shared
        let menu = MainMenu.make()
        var context = CommandContext.everythingAvailable
        context.terminalFocused = false
        #expect(owner(of: "k", .command, in: menu, context: context) == .commandPalette)
        context.terminalFocused = true
        #expect(owner(of: "k", .command, in: menu, context: context) == .clearTerminal)
        // With no terminal at all, ⌘K is the palette.
        context.terminalSelected = false
        context.terminalFocused = false
        #expect(owner(of: "k", .command, in: menu, context: context) == .commandPalette)
        #expect(context.disabledReason(for: .clearTerminal) != nil)
    }

    @Test func disabledReasonsExplain() {
        let empty = CommandContext()
        #expect(empty.disabledReason(for: .settleThread) == "Select a thread")
        #expect(empty.disabledReason(for: .goBack) == "No earlier thread")
        #expect(CommandContext.everythingAvailable.disabledReason(for: .newThread) == nil)
    }

    @Test func titlesFollowTheSelection() {
        var context = CommandContext.everythingAvailable
        context.selectedThreadCount = 3
        #expect(context.title(for: .settleThread) == "Settle 3 Threads")
        context.targetsPinned = true
        context.selectedThreadCount = 1
        #expect(context.title(for: .togglePinThread) == "Unpin Thread")
        #expect(ShellCommand.groupByProject.isChecked(in: context) == true)
    }
}

@Suite struct RestorationTests {
    @Test func newFieldsRoundTripAndOldStateStillDecodes() throws {
        var state = ShellState()
        state.selection = .thread("s1")
        state.grouping = .byState
        state.setSectionExpanded(scope: "/p", .settled, true)
        state.sidebarTopRow = "thread|s9"
        state.sidebarTopOffset = 12
        state.setPanel(ThreadPanelState(isRightPanelVisible: true, rightPanelTab: "changes"), for: "s1")
        let decoded = ShellState.decode(state.encoded())
        #expect(decoded == state)
        // A state saved by M1 (no new keys) keeps its selection instead of falling back to defaults.
        let old = #"{"version":1,"selection":{"thread":{"_0":"s7"}},"collapsedProjects":[],"isNeedsYouCollapsed":false,"isSidebarCollapsed":false,"isRightPanelVisible":true,"isTerminalVisible":false,"manualUnread":[],"newThreadDrafts":{"/p":"draft"}}"#
        let legacy = ShellState.decode(Data(old.utf8))
        #expect(legacy.selection == .thread("s7"))
        #expect(legacy.isRightPanelVisible)
        #expect(legacy.newThreadDrafts["/p"] == "draft")
        #expect(legacy.grouping == .byProject)
    }

    @Test func threadPanelsAreBounded() {
        var state = ShellState()
        for i in 0..<(ShellState.maxThreadPanels + 20) {
            state.setPanel(ThreadPanelState(isRightPanelVisible: i % 2 == 0, rightPanelTab: nil), for: SessionID("s\(i)"))
        }
        let bounded = state.bounded()
        #expect(bounded.threadPanels.count == ShellState.maxThreadPanels)
        #expect(bounded.threadPanels["s0"] == nil, "oldest dropped first")
        #expect(bounded.threadPanels["s\(ShellState.maxThreadPanels + 19)"] != nil)
    }

    @MainActor @Test func windowsRestoreHonoursTheSystemSetting() throws {
        let defaults = try #require(UserDefaults(suiteName: "bellocode.tests.windows.\(UUID().uuidString)"))
        defaults.set(["w2", "w3"], forKey: MainWindows.openWindowsKey)
        defaults.set(Data("{}".utf8), forKey: MainWindows.stateKey(for: "w2"))
        #expect(MainWindows.stateKey(for: MainWindows.primaryID) == "BelloCode.ShellState", "the first window keeps the M1 key")
        var made: [String] = []
        let windows = MainWindows(defaults: defaults) { id in
            made.append(id)
            return TestWindows.make(defaults: defaults, id: id)
        }
        windows.restore(restoresWindows: false)
        #expect(made == [MainWindows.primaryID])
        #expect(defaults.stringArray(forKey: MainWindows.openWindowsKey) == [])
        #expect(defaults.data(forKey: MainWindows.stateKey(for: "w2")) == nil, "closed windows are forgotten")
        windows.closeAllForTermination()
        for controller in windows.all { controller.close() }

        defaults.set(["w2"], forKey: MainWindows.openWindowsKey)
        made = []
        let restoring = MainWindows(defaults: defaults) { id in
            made.append(id)
            return TestWindows.make(defaults: defaults, id: id)
        }
        restoring.restore(restoresWindows: true)
        #expect(made == [MainWindows.primaryID, "w2"])
        restoring.closeAllForTermination()
        for controller in restoring.all { controller.close() }
    }
}

/// Windows over an engine that never connects (window-management tests need no server).
@MainActor
enum TestWindows {
    static let engine: Engine = {
        _ = NSApplication.shared
        return try! Engine(configuration: EngineConfiguration(server: .dynamic { nil }, store: .inMemory))
    }()

    static func make(defaults: UserDefaults, id: String) -> MainWindowController {
        let workspace = WorkspaceController(engine: engine, stateStore: ShellStateStore(defaults: defaults, key: MainWindows.stateKey(for: id)))
        return MainWindowController(workspace: workspace, configuration: .init(surfaces: .builtIn, autosaveSuffix: nil))
    }
}
