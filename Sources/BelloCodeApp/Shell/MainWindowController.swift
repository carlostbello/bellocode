import AgentUI
import AppKit
import BelloCore
import ComposerKit
import DesignSystem
import Engine
import TerminalKit
import UniformTypeIdentifiers

/// The main window: unified toolbar over sidebar | thread (+ terminal drawer) | right panel.
///
/// It is the responder-chain endpoint for every `ShellActions` command (menu and toolbar items have a nil target),
/// validates them through `CommandContext`, keeps the window title/subtitle on project / thread / status, shows the
/// connection state unobtrusively, and restores layout and selection.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
    NSToolbarItemValidation, SidebarDelegate, ShellActions, TerminalShell
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
    private static let newThreadItem = NSToolbarItem.Identifier("newThread")
    private static let connectionItem = NSToolbarItem.Identifier("connection")
    private static let terminalItem = NSToolbarItem.Identifier("toggleTerminal")

    let workspace: WorkspaceController
    let sidebar: SidebarViewController
    let container: ThreadContainerViewController
    let split: MainSplitViewController
    let rightPanel: RightPanelViewController
    private let configuration: Configuration
    private var titleLoop: ObservationLoop?
    private let connectionView = ConnectionStatusView()
    private var isRestoringLayout = false
    /// The window's terminals (drawer and "Terminal" tab), found through the drawer's host controller.
    private(set) var terminals: TerminalSurfaces?
    /// The window's "Changes" tab (M2-C; MainWindowController+Changes.swift).
    private(set) var changes: ChangesSurfaces?

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
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.tabbingMode = .disallowed
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()
        if let suffix { window.setFrameAutosaveName("BelloCodeMainWindow\(suffix)") }
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = suffix != nil
        window.toolbar = toolbar

        sidebar.delegate = self
        rightPanel.onTabChange = { [weak self] id in self?.workspace.updateLayout(rightPanelTab: id) }
        split.onLayoutChange = { [weak self] in self?.recordLayout() }
        container.onDisplay = { [weak self] context in
            self?.updateTitle()
            self?.terminals?.display(context)
            self?.changes?.display(context)
        }
        restoreLayout()
        terminals = (content.drawerItem.viewController as? TerminalHostController)?.terminals
        terminals?.bind(engine: workspace.engine, shell: self)
        content.onLayoutChange = { [weak self] in self?.terminals?.recordDrawerState() }
        changes = surfaces.changes
        changes?.bind(engine: workspace.engine, shell: self)
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
    }

    // MARK: - Title and connection

    private func updateTitle() {
        guard let window else { return }
        let root = workspace.engine.root
        connectionView.update(root.connection, source: configuration.sourceLabel, storage: workspace.engine.storageNotice)
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
        if window.title != title { window.title = title }
        if window.subtitle != subtitle { window.subtitle = subtitle }
        NSApp.dockTile.badgeLabel = root.attention.counts.dockBadge > 0 ? "\(root.attention.counts.dockBadge)" : nil
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        container.windowDidBecomeKey()
        changes?.refreshStatus()
    }

    func windowWillClose(_ notification: Notification) {
        workspace.saveNow()
        changes?.saveOptions()
    }

    /// One undo manager per window, owned by the workspace (text views share it, as AppKit intends).
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { workspace.undoManager }

    // MARK: - Command context

    /// The target of menu commands: the selected sidebar row when the sidebar has focus, else the displayed thread.
    var currentTarget: CommandTarget? {
        if window?.firstResponder === sidebar.outlineView, let node = sidebar.selectedNode { return sidebar.target(for: node) }
        return workspace.target(for: workspace.selection)
    }

    func commandContext(target: CommandTarget? = nil) -> CommandContext {
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
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action, let command = ShellCommand.command(for: action) else { return true }
        let context = commandContext()
        menuItem.title = context.title(for: command)
        return context.isEnabled(command)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let action = item.action, let command = ShellCommand.command(for: action) else { return true }
        return commandContext().isEnabled(command)
    }

    // MARK: - SidebarDelegate

    func sidebar(_ sidebar: SidebarViewController, perform command: ShellCommand, on target: CommandTarget?) {
        perform(command, on: target)
    }

    /// Runs a command on an explicit target (context menus, sidebar keys) or the current one (menus, shortcuts).
    func perform(_ command: ShellCommand, on explicitTarget: CommandTarget? = nil) {
        let context = commandContext(target: explicitTarget)
        guard context.isEnabled(command) || explicitTarget != nil else { return NSSound.beep() }
        let target = context.target
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
            if let id = target?.threadID { workspace.archive(id) }
        case .deleteThread:
            if let id = target?.threadID { confirmDelete(id) }
        case .markUnread:
            if let id = target?.threadID { workspace.markUnread(id) }
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
            .revertHunk, .revertFile, .revertTurn, .commitChanges, .pushBranch, .openPullRequest, .toggleDiffLayout,
            .toggleDiffWhitespace, .toggleDiffWrap, .chooseWorkspace, .chooseBranch, .removeWorktree:
            performChanges(command)
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

    /// Delete cannot be undone on the server, so it is the one confirmation (scoped; Archive is the undoable route).
    private func confirmDelete(_ id: SessionID) {
        guard let window else { return }
        let title = workspace.session(id)?.displayTitle ?? "this thread"
        let alert = NSAlert()
        alert.messageText = "Delete “\(title)”?"
        alert.informativeText = "The thread and its messages are deleted from opencode. This cannot be undone. Archive keeps it and can be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.workspace.delete(id) }
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, .sidebarTrackingSeparator, Self.newThreadItem, .flexibleSpace, Self.connectionItem,
            Self.terminalItem, .inspectorTrackingSeparator, .toggleInspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.newThreadItem:
            return ToolbarButton.make(
                itemIdentifier, label: "New Thread", symbolName: "square.and.pencil", action: ShellCommand.newThread.selector,
                toolTip: "New Thread (⌘N)")
        case Self.terminalItem:
            return ToolbarButton.make(
                itemIdentifier, label: "Terminal", symbolName: "terminal", action: ShellCommand.toggleTerminal.selector,
                toolTip: "Show or Hide Terminal (⌃`)")
        case Self.connectionItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Connection"
            item.paletteLabel = "Connection"
            item.view = connectionView
            item.visibilityPriority = .low
            return item
        default:
            return nil
        }
    }
}

/// "● Connected" in the toolbar: glyph + text, secondary colour; never blanks content (content stays visible in
/// every state). Offline shows the reason in the tooltip.
@MainActor
final class ConnectionStatusView: NSStackView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.font = DS.Typography.current.caption
        label.textColor = DS.Palette.secondaryText
        spacing = DS.Spacing.xs
        addArrangedSubview(icon)
        addArrangedSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `storage`: a local-saving problem (`Engine.storageNotice`); it takes precedence, as unsaved drafts are at risk.
    func update(_ status: ConnectionStatus, source: String?, storage: (label: String, detail: String)? = nil) {
        if let storage {
            icon.image = NSImage(systemSymbolName: "externaldrive.badge.exclamationmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [DS.Palette.attention])))
            let text = [source, storage.label, status.label].compactMap { $0 }.joined(separator: " · ")
            label.stringValue = text
            toolTip = storage.detail
            setAccessibilityLabel("Connection: \(text). \(storage.detail)")
            return
        }
        let (symbol, tint): (String, NSColor) = switch status {
        case .live: ("circle.fill", DS.Palette.success)
        case .cached: ("clock", DS.Palette.neutral)
        case .connecting, .syncing: ("arrow.triangle.2.circlepath", DS.Palette.neutral)
        case .offline: ("bolt.horizontal.circle", DS.Palette.attention)
        case .stopped: ("stop.circle", DS.Palette.neutral)
        }
        let size: CGFloat = status == .live ? 7 : 11
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold).applying(.init(paletteColors: [tint])))
        let text = [source, status.label].compactMap { $0 }.joined(separator: " · ")
        label.stringValue = text
        if case .offline(let reason) = status { toolTip = "Offline: \(reason). Cached content is shown." } else { toolTip = text }
        setAccessibilityLabel("Connection: \(text)")
    }
}
