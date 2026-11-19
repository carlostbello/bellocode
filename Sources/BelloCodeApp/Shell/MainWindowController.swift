import AgentUI
import AppKit
import BelloCore
import ComposerKit
import DesignSystem
import Engine
import TerminalKit
import UniformTypeIdentifiers

/// The main window: a transparent title bar and a 52 pt header bar (`ShellHeaderBar`) over
/// sidebar | thread (+ terminal drawer) | right panel.
///
/// It is the responder-chain endpoint for every `ShellActions` command (menu items and header buttons have a nil
/// target), validates them through `CommandContext`, keeps the window title/subtitle on project / thread / status,
/// shows the connection state in the sidebar's footer, and restores layout and selection.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, SidebarDelegate,
    ShellActions, TerminalShell, BrowserShell
{
    @MainActor
    struct Configuration {
        var surfaces: ShellSurfaces = .builtIn
        /// nil disables autosave (snapshots and tests).
        var autosaveSuffix: String? = ""
        /// Shown before the connection state, for example "Mock (demo)".
        var sourceLabel: String?
    }

    private static let toolbarIdentifier = "BelloCodeMainToolbar"

    let workspace: WorkspaceController
    let sidebar: SidebarViewController
    let container: ThreadContainerViewController
    let split: MainSplitViewController
    let rightPanel: RightPanelViewController
    /// The window's content root: the split view under the header bar.
    let root: ShellRootViewController
    var header: ShellHeaderBar { root.header }
    /// ⌘K / ⌘P / ⇧⌘F (built with the window so the first opening is instant).
    let palette = PaletteController()
    private let configuration: Configuration
    private var titleLoop: ObservationLoop?
    private var connectionView: ConnectionStatusView { sidebar.connectionView }
    private var isRestoringLayout = false
    /// The window's terminals (drawer and "Terminal" tab), found through the drawer's host controller.
    private(set) var terminals: TerminalSurfaces?
    /// The window's "Changes" tab (M2-C; MainWindowController+Changes.swift).
    private(set) var changes: ChangesSurfaces?
    /// Git parity: the git actions models and open popovers (MainWindowController+Git.swift).
    let gitUI = GitUIState()
    /// The window's built-in browser ("Browser" tab).
    private(set) var browser: BrowserSurfaces?
    /// The window's Agents panel ("Agents" tab, M3-A; MainWindowController+Agents.swift).
    private(set) var agents: AgentsSurfaces?
    /// The window's "Merge Requests" tab (M3-B; MainWindowController+MergeRequests.swift).
    private(set) var mergeRequests: MergeRequestSurfaces?
    private(set) var autoAudit: AutoAuditSurfaces?

    init(workspace: WorkspaceController, configuration: Configuration = Configuration()) {
        self.workspace = workspace
        self.configuration = configuration
        let surfaces = configuration.surfaces
        sidebar = SidebarViewController(workspace: workspace)
        container = ThreadContainerViewController(workspace: workspace, surfaces: surfaces)
        rightPanel = RightPanelViewController(tabs: surfaces.rightPanelTabs, selectedID: workspace.state.rightPanelTab)
        let suffix = configuration.autosaveSuffix
        let content = ContentSplitViewController(
            thread: container, drawer: surfaces.terminalDrawer(), autosaveName: suffix.map { "BelloCodeContentSplit\($0)" })
        split = MainSplitViewController(
            sidebar: sidebar, content: content, panel: rightPanel, autosaveName: suffix.map { "BelloCodeMainSplit\($0)" })
        root = ShellRootViewController(split: split)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "BelloCode"
        // Title and subtitle are kept current (Window menu, Mission Control, VoiceOver) but not drawn: the thread
        // header shows them with the project and directory, and drawing both would repeat the title.
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 760, height: 460)
        window.isReleasedWhenClosed = false
        // A transparent title bar over full-size content: the header bar is the title bar. The toolbar stays empty;
        // it only gives the title bar its unified height, so the traffic lights sit centred in the top 52 pt.
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.backgroundColor = DS.Color.canvas
        window.contentViewController = root
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()
        if let suffix { window.setFrameAutosaveName("BelloCodeMainWindow\(suffix)") }
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        configureHeader()

        sidebar.delegate = self
        rightPanel.onTabChange = { [weak self] id in
            self?.workspace.updateLayout(rightPanelTab: id)
            self?.recordThreadPanel()
        }
        split.onLayoutChange = { [weak self] in
            self?.recordLayout()
            self?.root.layoutHeader()
            self?.updateHeaderToggles()
        }
        container.onDisplay = { [weak self] context in
            self?.header.setTitleView(self?.container.header)
            self?.updateTitle()
            self?.terminals?.display(context)
            self?.applyThreadPanel()
            self?.applyPendingReveal()
            self?.changes?.display(context)
            self?.browser?.display(context)
            self?.agents?.display(context)
            self?.autoAudit?.display(context)
            self?.attachAuto(context)
            context?.onShowAgents = { [weak self] in self?.showAgentsPanel() }
            self?.attachExtras(context)
        }
        restoreLayout()
        terminals = (content.drawerItem.viewController as? TerminalHostController)?.terminals
        terminals?.bind(engine: workspace.engine, shell: self)
        content.onLayoutChange = { [weak self] in
            self?.terminals?.recordDrawerState()
            self?.updateHeaderToggles()
        }
        changes = surfaces.changes
        changes?.bind(engine: workspace.engine, shell: self)
        browser = surfaces.browser
        browser?.bind(engine: workspace.engine, shell: self)
        terminals?.browser = browser
        agents = surfaces.agents
        agents?.bind(engine: workspace.engine, shell: self)
        mergeRequests = surfaces.mergeRequests
        mergeRequests?.showPanel = { [weak self] in self?.showMergeRequestsPanel() }
        mergeRequests?.bind(engine: workspace.engine)
        autoAudit = surfaces.autoAudit
        autoAudit?.bind(engine: workspace.engine)
        wireCreateMergeRequest()
        wireStartThreadFromIssue()
        titleLoop = ObservationLoop { [weak self] in self?.updateTitle() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { titleLoop?.cancel() }

    // MARK: - Layout restoration

    private func restoreLayout() {
        isRestoringLayout = true
        defer { isRestoringLayout = false }
        _ = split.view
        let state = workspace.state
        split.sidebarItem.isCollapsed = state.isSidebarCollapsed
        split.panelItem.isCollapsed = !state.isRightPanelVisible
        split.contentSplit.drawerItem.isCollapsed = !state.isTerminalVisible
    }

    private func recordLayout() {
        guard !isRestoringLayout else { return }
        workspace.updateLayout(
            sidebarCollapsed: split.sidebarItem.isCollapsed, rightPanelVisible: !split.panelItem.isCollapsed,
            terminalVisible: !split.contentSplit.drawerItem.isCollapsed)
        recordThreadPanel()
    }

    /// Remembers the right panel (shown, tab) for the displayed thread.
    private func recordThreadPanel() {
        guard !isRestoringLayout, let id = container.displayed?.threadID else { return }
        workspace.recordPanel(
            ThreadPanelState(isRightPanelVisible: !split.panelItem.isCollapsed, rightPanelTab: rightPanel.selectedID), for: id)
    }

    /// Shows the displayed thread's right panel as it was left there: instantly, without replaying transitions.
    private func applyThreadPanel() {
        guard let id = container.displayed?.threadID, let panel = workspace.panel(for: id) else { return }
        isRestoringLayout = true
        defer { isRestoringLayout = false }
        if let tab = panel.rightPanelTab, tab != rightPanel.selectedID { rightPanel.select(tab) }
        if split.panelItem.isCollapsed == panel.isRightPanelVisible {
            DS.Motion.withoutAnimation { split.panelItem.isCollapsed = !panel.isRightPanelVisible }
        }
    }

    /// The project of the thread or draft shown (Project Environment…).
    var currentProjectDirectory: String? {
        container.context.map { $0.directory.isEmpty ? $0.projectDirectory : $0.directory }
    }

    // MARK: - Header bar

    private func configureHeader() {
        let runtime = RuntimeStatusButton(service: workspace.engine.environments)
        header.runtimeView = runtime
        let menu = NSMenu(title: "Open")
        menu.addItem(withTitle: ShellCommand.revealInFinder.title, action: ShellCommand.revealInFinder.selector, keyEquivalent: "")
        menu.addItem(withTitle: "Open in Terminal", action: #selector(openProjectInTerminal(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: ShellCommand.copyPath.title, action: ShellCommand.copyPath.selector, keyEquivalent: "")
        header.openButton.popUpMenu = menu
        updateHeaderToggles()
    }

    /// The toggles' on state follows the panels (any route: menu, shortcut, divider drag).
    func updateHeaderToggles() {
        header.terminalToggle.isSelected = !split.contentSplit.drawerItem.isCollapsed
        header.panelToggle.isSelected = !split.panelItem.isCollapsed
        header.sidebarButton.setAccessibilityLabel(split.sidebarItem.isCollapsed ? "Show Sidebar" : "Hide Sidebar")
    }

    /// "Open" and "Commit n" act on the displayed thread's directory; hidden without one, Commit disabled outside a
    /// repository. Observed (called from the title loop), so the count follows the repository's status.
    private func updateHeaderActions() {
        guard let context = container.context else {
            rightPanel.setCount(nil, for: "changes")
            rightPanel.setCount(nil, for: "agents")
            header.openButton.isHidden = true
            header.commitButton.isHidden = true
            header.gitMenuButton.isHidden = true
            header.needsLayout = true
            return
        }
        let repository = workspace.engine.git.repository(for: context.directory.isEmpty ? context.projectDirectory : context.directory)
        let changed = repository.status?.files.count ?? 0
        let isRepository = repository.phase != .notRepository
        let hint = changed > 0 ? "\(changed)" : nil
        // Live counts in the right panel's tabs ("Changes 3", "Agents 2").
        rightPanel.setCount(changed, for: "changes")
        if let id = context.thread?.sessionID, let orchestration = workspace.engine.orchestration {
            _ = orchestration.structureRevision
            rightPanel.setCount(orchestration.graph.children[id]?.count, for: "agents")
        } else {
            rightPanel.setCount(nil, for: "agents")
        }
        if header.commitButton.shortcutHint != hint { header.commitButton.shortcutHint = hint }
        header.commitButton.accessibilityTitle = changed == 1 ? "Commit, 1 changed file" : "Commit, \(changed) changed files"
        header.commitButton.isEnabled = isRepository
        let hiddenChanged = header.openButton.isHidden || header.commitButton.isHidden != !isRepository
        header.openButton.isHidden = false
        header.commitButton.isHidden = !isRepository
        header.gitMenuButton.isHidden = !isRepository
        if updateGitHeader(repository) || hiddenChanged || hint != nil { header.needsLayout = true }
    }

    @objc func openProjectInTerminal(_ sender: Any?) {
        guard let directory = currentProjectDirectory, !directory.isEmpty,
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { return NSSound.beep() }
        NSWorkspace.shared.open([URL(fileURLWithPath: directory)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Header and menu route for Show/Hide Sidebar when no view in the split has focus.
    @objc func toggleSidebar(_ sender: Any?) { split.toggleSidebar(sender) }

    /// Header and menu route for Show/Hide Right Panel when no view in the split has focus.
    @objc func toggleInspector(_ sender: Any?) { split.toggleInspector(sender) }

    // MARK: - Title and connection

    private func updateTitle() {
        guard let window else { return }
        let root = workspace.engine.root
        connectionView.update(
            root.connection, source: configuration.sourceLabel, storage: workspace.engine.storageNotice, partial: root.syncGaps.message)
        updateHeaderActions()
        var title = "BelloCode"
        var subtitle = ""
        if let context = container.context {
            if let thread = context.thread {
                title = thread.session?.displayTitle ?? workspace.session(thread.sessionID)?.displayTitle ?? "Thread"
                let status = thread.status?.status ?? .idle
                subtitle = context.projectName + (status == .idle ? "" : " — \(StatusGlyph(status).label)")
            } else {
                title = "New Thread"
                subtitle = context.projectName
            }
        } else if root.projects.isEmpty {
            subtitle = "No projects"
        }
        // Attention in the subtitle (Window menu, Mission Control, VoiceOver): blockers, never colour alone.
        let blockers = root.attention.counts.dockBadge
        if blockers > 0 {
            let needs = blockers == 1 ? "1 needs you" : "\(blockers) need you"
            subtitle = subtitle.isEmpty ? needs : subtitle + " · " + needs
        }
        if window.title != title { window.title = title }
        if window.subtitle != subtitle { window.subtitle = subtitle }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        container.windowDidBecomeKey()
        changes?.refreshStatus()
    }

    func windowWillClose(_ notification: Notification) {
        workspace.saveNow()
        changes?.saveOptions()
        if let browser { Task { await browser.close() } }
    }

    /// One undo manager per window, owned by the workspace (text views share it, as AppKit intends).
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { workspace.undoManager }

    // MARK: - Command context

    /// The target of menu commands: the selected sidebar row when the sidebar has focus, else the displayed thread.
    var currentTarget: CommandTarget? {
        if window?.firstResponder === sidebar.outlineView, let node = sidebar.selectedNode { return sidebar.target(for: node) }
        return workspace.target(for: workspace.selection)
    }

    /// The threads a selection command acts on: `explicit` (a context menu), else the sidebar's selection while it
    /// has focus, else the target's thread.
    func threadTargets(explicit: [SessionID] = [], target: CommandTarget?) -> [SessionID] {
        if !explicit.isEmpty { return explicit }
        if window?.firstResponder === sidebar.outlineView {
            let selected = sidebar.selectedThreadIDs
            if !selected.isEmpty { return selected }
        }
        return target?.threadID.map { [$0] } ?? []
    }

    func commandContext(target: CommandTarget? = nil) -> CommandContext {
        var context = baseCommandContext(target: target)
        context.agents = agentsCommandState()
        context.gitLab = gitLabCommandState
        context.auto = autoCommandState()
        context.git = gitCommandState()
        return context
    }

    private func baseCommandContext(target: CommandTarget?) -> CommandContext {
        let target = target ?? currentTarget
        let root = workspace.engine.root
        let pinned = target.flatMap(workspace.projectDirectory(for:)).flatMap { workspace.projectItem(directory: $0)?.isPinned } ?? false
        return CommandContext(
            hasProjects: !root.projects.isEmpty, target: target, targetProjectPinned: pinned,
            textInputFocused: window?.firstResponder is NSText, attentionCount: root.attention.items.count,
            composerVisible: container.composerSurface != nil, composerHasText: container.composerSurface?.hasSendableText ?? false,
            composerRunning: container.composerController.map { $0.runState != .idle } ?? false,
            isTerminalVisible: !split.contentSplit.drawerItem.isCollapsed,
            hasUnconfirmedSend: container.context?.thread?.unconfirmedSends.contains { $0.state == .unknown } ?? false,
            availableRequestCommands: Set(RequestCommand.allCases.filter { container.requestStackController?.model?.canPerform($0) ?? false }),
            terminalAvailable: terminals?.hasContext ?? false, terminalSelected: terminals?.activeHasTerminal ?? false,
            terminalHasSelectedText: terminals?.activeHasSelection ?? false,
            terminalSplit: terminals?.terminals?.set.splitSecondary != nil,
            terminalInPanel: terminals?.activePlacement == .panel,
            availableTranscriptCommands: container.transcriptSurface?.availableCommands ?? [],
            changes: changesCommandState())
            .with(organisationOf: threadTargets(target: target), workspace: workspace, target: target,
                  terminalFocused: terminals?.focusIsInTerminal ?? false)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSidebar(_:)) || menuItem.action == #selector(toggleInspector(_:)) {
            return split.validateUserInterfaceItem(menuItem)
        }
        if menuItem.action == #selector(openProjectInTerminal(_:)) {
            return !(currentProjectDirectory ?? "").isEmpty
        }
        guard let action = menuItem.action, let command = ShellCommand.command(for: action) else { return true }
        let context = commandContext()
        // Snooze presets keep their submenu titles.
        if menuItem.menu?.title != "Snooze" || command == .wakeThread {
            menuItem.title = context.title(for: command)
        }
        if let checked = command.isChecked(in: context) { menuItem.state = checked ? .on : .off }
        return context.isEnabled(command)
    }

    // MARK: - SidebarDelegate

    func sidebar(_ sidebar: SidebarViewController, perform command: ShellCommand, on target: CommandTarget?, threads: [SessionID]) {
        perform(command, on: target, threads: threads)
    }

    /// Runs a command on an explicit target (context menus, sidebar keys, the palette) or the current one (menus,
    /// shortcuts). Selection commands act on `threads`, else on the sidebar's selection while it has focus.
    func perform(_ command: ShellCommand, on explicitTarget: CommandTarget? = nil, threads explicitThreads: [SessionID] = []) {
        let context = commandContext(target: explicitTarget)
        guard context.isEnabled(command) || explicitTarget != nil || !explicitThreads.isEmpty else { return NSSound.beep() }
        let target = context.target
        let threads = threadTargets(explicit: explicitThreads, target: target)
        if command.actsOnSelection, threads.isEmpty { return NSSound.beep() }
        switch command {
        case .newThread:
            workspace.newThread(in: target.flatMap(workspace.projectDirectory(for:)))
            focusComposerSoon()
        case .addProject:
            presentAddProjectPanel()
        case .renameThread:
            guard let id = target?.threadID else { return }
            if window?.firstResponder === sidebar.outlineView || workspace.selection?.threadID != id {
                sidebar.beginRename(id)
            } else {
                container.header?.beginEditingTitle()
            }
        case .archiveThread:
            workspace.archive(threads)
        case .deleteThread:
            // Deferred with Undo (5 s) instead of a confirmation: nothing reaches opencode until the toast expires.
            workspace.delete(threads)
        case .markUnread:
            workspace.markUnread(threads)
        case .togglePinThread:
            workspace.togglePin(threads)
        case .settleThread:
            workspace.toggleSettle(threads)
        case .snoozeLaterToday, .snoozeTomorrow, .snoozeNextWeek:
            if let preset = SnoozePreset(command: command) { workspace.snooze(threads, until: preset.date(from: Date())) }
        case .snoozeUntil:
            presentSnoozePicker(for: threads)
        case .wakeThread:
            workspace.wake(threads)
        case .toggleNeverAutoSettle:
            workspace.toggleNeverAutoSettle(threads)
        case .groupByProject:
            workspace.setGrouping(.byProject)
        case .showThreadsByState:
            workspace.setGrouping(.byState)
        case .filterSidebar:
            if split.sidebarItem.isCollapsed { split.setCollapsed(split.sidebarItem, false) }
            sidebar.focusFilter()
        case .moveProjectUp, .moveProjectDown:
            if let directory = target.flatMap(workspace.projectDirectory(for:)) {
                workspace.moveProject(directory: directory, by: command == .moveProjectUp ? -1 : 1)
            }
        case .commandPalette:
            presentPalette(.commands)
        case .quickOpen:
            presentPalette(.quickOpen)
        case .globalSearch:
            presentPalette(.messages)
        case .goBack:
            workspace.goBack()
        case .goForward:
            workspace.goForward()
        case .reopenClosedThread:
            workspace.reopenClosedThread()
        case .newWindow:
            NSApp.sendAction(command.selector, to: nil, from: nil)
        case .togglePinProject:
            if let directory = target.flatMap(workspace.projectDirectory(for:)) { workspace.togglePin(directory: directory) }
        case .removeProject:
            if let directory = target.flatMap(workspace.projectDirectory(for:)) { workspace.removeProject(directory: directory) }
        case .revealInFinder:
            if let directory = target?.directory {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: directory, directoryHint: .isDirectory)])
            }
        case .copyPath:
            if let directory = target?.directory {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(directory, forType: .string)
                workspace.undo.showNotice("Copied \((directory as NSString).abbreviatingWithTildeInPath)")
            }
        case .nextNeedsAttention:
            if workspace.selectNextNeedsAttention() == nil { NSSound.beep() }
        case .focusComposer:
            if let view = container.composerFocusView { window?.makeFirstResponder(view) }
        case .focusNextRegion:
            cycleFocus(forward: true)
        case .focusPreviousRegion:
            cycleFocus(forward: false)
        case .toggleTerminal:
            // Like VS Code's ⌃`: show and focus the terminal; hide it when it has focus or is already shown.
            let drawer = split.contentSplit.drawerItem
            if drawer.isCollapsed {
                setTerminalDrawer(visible: true, height: terminals?.terminals?.set.drawerHeight)
                focusTerminalSoon()
            } else {
                let hadFocus = terminals?.focusIsInTerminal ?? false
                split.setCollapsed(drawer, true)
                if hadFocus, let view = container.composerFocusView { window?.makeFirstResponder(view) }
            }
            recordLayout()
            terminals?.recordDrawerState()
        case .newTerminal:
            terminals?.newTerminal()
        case .closeTerminal:
            terminals?.closeTerminal()
        case .splitTerminal:
            terminals?.toggleSplit()
        case .nextTerminal:
            terminals?.selectNext()
        case .previousTerminal:
            terminals?.selectPrevious()
        case .clearTerminal:
            terminals?.clear()
        case .renameTerminal:
            terminals?.rename()
        case .restartTerminal:
            terminals?.restart()
        case .moveTerminal:
            if terminals?.activePlacement == .drawer, split.panelItem.isCollapsed {
                split.setCollapsed(split.panelItem, false)
                rightPanel.select("terminal")
            }
            terminals?.moveToOtherPlace()
        case .sendTerminalSelection:
            terminals?.sendSelectionToComposer()
        case .sendMessage:
            container.composerController?.composer.sendPrompt(nil) ?? container.composerSurface?.performSend()
        case .queueFollowUp:
            container.composerController?.composer.queuePrompt(nil)
        case .steerFollowUp:
            container.composerController?.composer.steerPrompt(nil)
        case .stopRun:
            guard let id = target?.threadID else { return }
            let model = workspace.threadModel(id)
            if model.isStatusUnknown {
                Task { await model.settleUnknownStatus() }
                return
            }
            if let composer = container.composerController, container.context?.thread?.sessionID == id, composer.runState == .running {
                composer.composer.stopAgent(nil)
            } else {
                Task { await workspace.threadModel(id).stop() }
            }
        case .retryUnconfirmed:
            guard let thread = container.context?.thread,
                  let send = thread.unconfirmedSends.first(where: { $0.state == .unknown }) else { return }
            Task { await thread.retryUnconfirmed(send.id) }
        case .chooseModel:
            container.composerController?.openModelPicker()
        case .permissionMode:
            container.composerController?.openPermissionMode()
        case .togglePlan:
            container.composerController?.togglePlan()
        case .allowOnce, .allowAlways, .denyRequest, .submitAnswer, .previousRequest, .nextRequest:
            if let request = command.requestCommand { container.requestStackController?.model?.perform(request) }
        case .findInThread, .findNext, .findPrevious, .useSelectionForFind, .copyMessage, .copyAsMarkdown, .copyCode, .jumpToLatest,
            .previousTurn, .nextTurn, .lastFailure:
            container.transcriptSurface?.perform(command)
        case .showSettings, .connectProvider, .showWelcome:
            // Answered by the app delegate (they reach it through the responder chain before this window).
            NSApp.sendAction(command.selector, to: nil, from: nil)
        case .showChanges, .nextChange, .previousChange, .nextChangedFile, .previousChangedFile, .addReviewComment, .openInEditor,
            .revertHunk, .revertFile, .revertTurn, .commitChanges, .createMergeRequest, .toggleDiffLayout,
            .toggleDiffWhitespace, .toggleDiffWrap, .chooseWorkspace, .chooseBranch, .removeWorktree:
            performChanges(command)
        case .pushBranch, .gitQuickAction, .showGitActions, .commitAndPush, .pullBranch, .pullRebase, .fetchRemote, .syncBranch, .publishToGitLab,
            .switchRemoteToHTTPS, .abortGitOperation, .restoreStashedChanges, .cloneFromGitLab, .newGitProject, .moveToNewWorktree, .editFromHere,
            .toggleAutoPull, .toggleCleanupOnSettle, .toggleCleanupOnArchive:
            performGit(command)
        case .showAgents, .nextAgent, .previousAgent, .openAgent, .followUpAgent, .stopAgentTree, .openParentThread:
            performAgents(command)
        case .showMergeRequests:
            showMergeRequestsPanel()
        // GitLab 2: the tab's commands (MainWindowController+GitLab.swift).
        case .reviewMergeRequest, .submitReview, .discardReviewDrafts, .closeReview, .nextReviewThread, .previousReviewThread, .replyToReviewThread,
            .toggleReviewThreadResolved, .addReviewThreadToAgent, .linkMergeRequest, .refreshMergeRequests, .toggleBabysit, .showFailingJobLog, .sendFailureToAgent,
            .retryFailedJob, .playManualJob, .openMergeRequestInGitLab, .unlinkMergeRequest, .approveMergeRequest, .mergeMergeRequest, .showIssues,
            .startThreadFromIssue, .linkIssueToThread, .showTodos, .openTodo, .markTodoDone:
            mergeRequests?.perform(command)
        case .showScheduledTasks:
            (NSApp.delegate as? AppDelegate)?.showScheduledTasks(nil)
        case .showContainers, .showEnvironment, .verifyIsolation, .showMCPServers, .showSecrets:
            NSApp.sendAction(command.selector, to: nil, from: nil)
        case .pruneContainerResources:
            NSApp.sendAction(command.selector, to: nil, from: nil)
        case .modeAsk, .modeAutoEdit, .modeAuto, .modeFullAccess, .showAutoAudit, .reviewRiskNotices, .resumeInterrupted:
            performAuto(command)
        }
    }

    // MARK: - ShellActions (responder chain)

    @objc func newThread(_ sender: Any?) { perform(.newThread) }
    @objc func addProject(_ sender: Any?) { perform(.addProject) }
    @objc func renameThread(_ sender: Any?) { perform(.renameThread) }
    @objc func archiveThread(_ sender: Any?) { perform(.archiveThread) }
    @objc func deleteThread(_ sender: Any?) { perform(.deleteThread) }
    @objc func markUnread(_ sender: Any?) { perform(.markUnread) }
    @objc func togglePinProject(_ sender: Any?) { perform(.togglePinProject) }
    @objc func removeProject(_ sender: Any?) { perform(.removeProject) }
    @objc func revealInFinder(_ sender: Any?) { perform(.revealInFinder) }
    @objc func copyPath(_ sender: Any?) { perform(.copyPath) }
    @objc func nextNeedsAttention(_ sender: Any?) { perform(.nextNeedsAttention) }
    @objc func focusComposer(_ sender: Any?) { perform(.focusComposer) }
    @objc func focusNextRegion(_ sender: Any?) { perform(.focusNextRegion) }
    @objc func focusPreviousRegion(_ sender: Any?) { perform(.focusPreviousRegion) }
    @objc func toggleTerminal(_ sender: Any?) { perform(.toggleTerminal) }
    @objc func sendPrompt(_ sender: Any?) { perform(.sendMessage) }
    @objc func queuePrompt(_ sender: Any?) { perform(.queueFollowUp) }
    @objc func steerPrompt(_ sender: Any?) { perform(.steerFollowUp) }
    @objc func stopAgent(_ sender: Any?) { perform(.stopRun) }
    @objc func retryUnconfirmedSend(_ sender: Any?) { perform(.retryUnconfirmed) }
    @objc func chooseModel(_ sender: Any?) { perform(.chooseModel) }
    @objc func choosePermissionMode(_ sender: Any?) { perform(.permissionMode) }
    @objc func togglePlanMode(_ sender: Any?) { perform(.togglePlan) }
    @objc func allowRequestOnce(_ sender: Any?) { perform(.allowOnce) }
    @objc func allowRequestAlways(_ sender: Any?) { perform(.allowAlways) }
    @objc func denyRequest(_ sender: Any?) { perform(.denyRequest) }
    @objc func submitRequestAnswer(_ sender: Any?) { perform(.submitAnswer) }
    @objc func showPreviousRequest(_ sender: Any?) { perform(.previousRequest) }
    @objc func showNextRequest(_ sender: Any?) { perform(.nextRequest) }
    @objc func newTerminal(_ sender: Any?) { perform(.newTerminal) }
    @objc func closeTerminal(_ sender: Any?) { perform(.closeTerminal) }
    @objc func splitTerminal(_ sender: Any?) { perform(.splitTerminal) }
    @objc func selectNextTerminal(_ sender: Any?) { perform(.nextTerminal) }
    @objc func selectPreviousTerminal(_ sender: Any?) { perform(.previousTerminal) }
    @objc func clearTerminal(_ sender: Any?) { perform(.clearTerminal) }
    @objc func renameTerminal(_ sender: Any?) { perform(.renameTerminal) }
    @objc func restartTerminal(_ sender: Any?) { perform(.restartTerminal) }
    @objc func moveTerminal(_ sender: Any?) { perform(.moveTerminal) }
    @objc func sendTerminalSelectionToComposer(_ sender: Any?) { perform(.sendTerminalSelection) }
    @objc func togglePinThread(_ sender: Any?) { perform(.togglePinThread) }
    @objc func settleThread(_ sender: Any?) { perform(.settleThread) }
    @objc func snoozeLaterToday(_ sender: Any?) { perform(.snoozeLaterToday) }
    @objc func snoozeTomorrow(_ sender: Any?) { perform(.snoozeTomorrow) }
    @objc func snoozeNextWeek(_ sender: Any?) { perform(.snoozeNextWeek) }
    @objc func snoozeUntil(_ sender: Any?) { perform(.snoozeUntil) }
    @objc func wakeThread(_ sender: Any?) { perform(.wakeThread) }
    @objc func toggleNeverAutoSettle(_ sender: Any?) { perform(.toggleNeverAutoSettle) }
    @objc func groupThreadsByProject(_ sender: Any?) { perform(.groupByProject) }
    @objc func showThreadsByState(_ sender: Any?) { perform(.showThreadsByState) }
    @objc func filterSidebar(_ sender: Any?) { perform(.filterSidebar) }
    @objc func moveProjectUp(_ sender: Any?) { perform(.moveProjectUp) }
    @objc func moveProjectDown(_ sender: Any?) { perform(.moveProjectDown) }
    @objc func showCommandPalette(_ sender: Any?) { perform(.commandPalette) }
    @objc func showQuickOpen(_ sender: Any?) { perform(.quickOpen) }
    @objc func showGlobalSearch(_ sender: Any?) { perform(.globalSearch) }
    @objc func goBackInHistory(_ sender: Any?) { perform(.goBack) }
    @objc func goForwardInHistory(_ sender: Any?) { perform(.goForward) }
    @objc func reopenClosedThread(_ sender: Any?) { perform(.reopenClosedThread) }

    // MARK: - BrowserShell

    var browserComposer: ComposerViewController? { container.composerController?.composer }

    func showBrowserPanel() {
        if split.panelItem.isCollapsed {
            split.setCollapsed(split.panelItem, false)
            recordLayout()
        }
        rightPanel.select("browser")
    }

    var isBrowserPanelShown: Bool { !split.panelItem.isCollapsed && rightPanel.selectedID == "browser" }

    // MARK: - TerminalShell

    var terminalComposer: ComposerViewController? { container.composerController?.composer }

    func terminalCreateThread() async -> SessionID? {
        await container.context?.createThread()?.sessionID
    }

    var isTerminalDrawerVisible: Bool { !split.contentSplit.drawerItem.isCollapsed }
    var terminalDrawerHeight: Double? { split.contentSplit.drawerHeight }

    func setTerminalDrawer(visible: Bool, height: Double?) {
        let drawer = split.contentSplit.drawerItem
        if drawer.isCollapsed == visible { split.setCollapsed(drawer, !visible) }
        if visible, let height { split.contentSplit.setDrawerHeight(height) }
        recordLayout()
    }

    /// The drawer was just shown; focus its terminal after layout.
    private func focusTerminalSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.terminals?.drawerFocusView else { return }
            self.window?.makeFirstResponder(view)
        }
    }
    @objc func findInTranscript(_ sender: Any?) { perform(.findInThread) }
    @objc func findNextInTranscript(_ sender: Any?) { perform(.findNext) }
    @objc func findPreviousInTranscript(_ sender: Any?) { perform(.findPrevious) }
    @objc func useSelectionForTranscriptFind(_ sender: Any?) { perform(.useSelectionForFind) }
    @objc func copyTranscriptMessage(_ sender: Any?) { perform(.copyMessage) }
    @objc func copyTranscriptMarkdown(_ sender: Any?) { perform(.copyAsMarkdown) }
    @objc func copyTranscriptCode(_ sender: Any?) { perform(.copyCode) }
    @objc func jumpToLatestOutput(_ sender: Any?) { perform(.jumpToLatest) }
    @objc func showPreviousTurn(_ sender: Any?) { perform(.previousTurn) }
    @objc func showNextTurn(_ sender: Any?) { perform(.nextTurn) }
    @objc func showLastFailure(_ sender: Any?) { perform(.lastFailure) }

    // MARK: - Search reveal

    /// Shows a search hit: selects its thread and reveals the message in the transcript (with the query found).
    func reveal(_ reveal: PendingReveal) {
        workspace.pendingReveal = reveal
        if workspace.selection == .thread(reveal.sessionID) {
            applyPendingReveal()
        } else {
            workspace.select(.thread(reveal.sessionID))
        }
    }

    private func applyPendingReveal() {
        guard let reveal = workspace.pendingReveal, container.displayed == .thread(reveal.sessionID),
              let surface = container.transcriptSurface
        else { return }
        workspace.pendingReveal = nil
        surface.reveal(messageID: reveal.messageID, query: reveal.query)
    }

    // MARK: - Helpers

    /// The composer is created on the next run-loop turn (the content area observes the selection); focus it then.
    func focusComposerSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.container.composerFocusView else { return }
            self.window?.makeFirstResponder(view)
        }
    }

    /// F6 / ⇧F6: sidebar → transcript → requests (when any are pending) → composer (regions that exist and are
    /// visible).
    func cycleFocus(forward: Bool) {
        guard let window else { return }
        var regions: [NSView] = []
        if !split.sidebarItem.isCollapsed { regions.append(sidebar.outlineView) }
        if let transcript = container.transcriptFocusView { regions.append(transcript) }
        if let requests = container.requestFocusView { regions.append(requests) }
        if let composer = container.composerFocusView { regions.append(composer) }
        if !split.contentSplit.drawerItem.isCollapsed, let terminal = terminals?.drawerFocusView { regions.append(terminal) }
        guard !regions.isEmpty else { return }
        let responder = window.firstResponder as? NSView
        let current = regions.firstIndex { region in responder.map { $0 === region || $0.isDescendant(of: region) } ?? false }
        let next = current.map { (forward ? $0 + 1 : $0 - 1 + regions.count) % regions.count } ?? 0
        window.makeFirstResponder(regions[next])
    }

    private func presentAddProjectPanel() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = "Add Project"
        panel.message = "Choose folders to work in."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                self?.workspace.addProjects(panel.urls)
                self?.focusComposerSoon()
            }
        }
    }

    /// "Snooze Until…": the picker beside the thread's sidebar row (or under the toolbar when the row is not shown).
    func presentSnoozePicker(for threads: [SessionID]) {
        guard let window, let content = window.contentView else { return }
        let title = threads.count == 1 ? (workspace.session(threads[0])?.displayTitle ?? "Thread") : "\(threads.count) threads"
        let onSnooze: (Date) -> Void = { [weak self] date in self?.workspace.snooze(threads, until: date) }
        let row = threads.first.map { sidebar.row(of: .thread($0)) } ?? -1
        if row >= 0, !split.sidebarItem.isCollapsed {
            let rect = sidebar.outlineView.rect(ofRow: row)
            SnoozePicker.show(title: "Snooze \(title)", relativeTo: rect, of: sidebar.outlineView, onSnooze: onSnooze)
        } else {
            let rect = NSRect(x: content.bounds.midX - 1, y: content.bounds.maxY - 60, width: 2, height: 2)
            SnoozePicker.show(title: "Snooze \(title)", relativeTo: rect, of: content, preferredEdge: .minY, onSnooze: onSnooze)
        }
    }

    /// Opens the palette in a mode (filled in by the palette package; see Palette/).
    func presentPalette(_ mode: PaletteMode) {
        palette.show(mode, in: self)
    }
}

/// "● Connected" in the sidebar's footer (visual-language.md §6 "Sidebar"): a 6 pt dot + the state's word in `label
/// text2`; never colour alone, never blanks content (content stays visible in every state). Offline and storage
/// problems use a glyph in the warning tone; the reason is in the tooltip and the accessibility label.
@MainActor
final class ConnectionStatusView: NSView {
    private(set) var text = ""
    private var tone: DS.Tone = .neutral
    private var symbolName: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var font: NSFont { DS.TextRole.label.font }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(14 + DSDraw.width(of: text, font: font)), height: DS.Size.controlSmall)
    }

    /// `storage`: a local-saving problem (`Engine.storageNotice`); it takes precedence, as unsaved drafts are at risk.
    /// `partial`: live, but some lists could not be read (their last-known state is shown and retried).
    func update(_ status: ConnectionStatus, source: String?, storage: (label: String, detail: String)? = nil, partial: String? = nil) {
        let newText: String
        if let storage {
            symbolName = "externaldrive.badge.exclamationmark"
            tone = .warning
            newText = [storage.label, status.label, source].compactMap { $0 }.joined(separator: " · ")
            toolTip = storage.detail
            setAccessibilityLabel("Connection: \(newText). \(storage.detail)")
        } else if status == .live, let partial {
            symbolName = "exclamationmark.arrow.triangle.2.circlepath"
            tone = .warning
            newText = ["Partly synced", source].compactMap { $0 }.joined(separator: " · ")
            toolTip = partial
            setAccessibilityLabel("Connection: \(newText). \(partial)")
        } else {
            (symbolName, tone) = switch status {
            case .live: (nil, .success)
            case .cached: ("clock", .neutral)
            case .connecting, .syncing: ("arrow.triangle.2.circlepath", .neutral)
            case .offline: ("bolt.horizontal.circle", .warning)
            case .stopped: ("stop.circle", .neutral)
            }
            // The state first: a long source label ("Mock (demo)") truncates, never the state.
            newText = [status.label, source].compactMap { $0 }.joined(separator: " · ")
            if case .offline(let reason) = status { toolTip = "Offline: \(reason). Cached content is shown." } else { toolTip = newText }
            setAccessibilityLabel("Connection: \(newText)")
        }
        if newText != text {
            text = newText
            invalidateIntrinsicContentSize()
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = DS.Color.tone(tone)
        let glyphColor = tone == .neutral ? DS.Color.text3 : (tone == .success ? colors.fill : colors.text)
        if let symbolName, let image = DSDraw.symbol(symbolName, pointSize: DS.Size.iconPointMeta + 1) {
            DSDraw.draw(template: image, in: NSRect(x: 0, y: 0, width: 10, height: bounds.height), color: glyphColor)
        } else {
            DSDraw.fill(NSRect(x: 2, y: (bounds.height - 6) / 2, width: 6, height: 6), radius: 3, color: glyphColor)
        }
        var rect = bounds
        rect.origin.x = 14
        rect.size.width -= 14
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: DS.Color.text2, .paragraphStyle: style])
        let height = ceil(font.ascender - font.descender + font.leading)
        attributed.draw(with: NSRect(x: rect.minX, y: (bounds.height - height) / 2, width: rect.width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
