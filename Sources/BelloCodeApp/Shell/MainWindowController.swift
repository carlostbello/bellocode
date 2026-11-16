import AppKit
import BelloCore
import DesignSystem
import Engine
import UniformTypeIdentifiers

/// The main window: unified toolbar over sidebar | thread (+ terminal drawer) | right panel.
///
/// It is the responder-chain endpoint for every `ShellActions` command (menu and toolbar items have a nil target),
/// validates them through `CommandContext`, keeps the window title/subtitle on project / thread / status, shows the
/// connection state unobtrusively, and restores layout and selection.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
    NSToolbarItemValidation, SidebarDelegate, ShellActions
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
        container.onDisplay = { [weak self] _ in self?.updateTitle() }
        restoreLayout()
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
        connectionView.update(root.connection, source: configuration.sourceLabel)
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

    func windowDidBecomeKey(_ notification: Notification) { container.windowDidBecomeKey() }

    func windowWillClose(_ notification: Notification) { workspace.saveNow() }

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
            isTerminalVisible: !split.contentSplit.drawerItem.isCollapsed)
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
            split.setCollapsed(split.contentSplit.drawerItem, !split.contentSplit.drawerItem.isCollapsed)
            recordLayout()
        case .sendMessage:
            container.composerSurface?.performSend()
        case .stopRun:
            if let id = target?.threadID { Task { await workspace.threadModel(id).stop() } }
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
    @objc func sendMessage(_ sender: Any?) { perform(.sendMessage) }
    @objc func stopRun(_ sender: Any?) { perform(.stopRun) }

    // MARK: - Helpers

    /// The composer is created on the next run-loop turn (the content area observes the selection); focus it then.
    func focusComposerSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.container.composerFocusView else { return }
            self.window?.makeFirstResponder(view)
        }
    }

    /// F6 / ⇧F6: sidebar → transcript → composer (regions that exist and are visible).
    private func cycleFocus(forward: Bool) {
        guard let window else { return }
        var regions: [NSView] = []
        if !split.sidebarItem.isCollapsed { regions.append(sidebar.outlineView) }
        if let transcript = container.transcriptFocusView { regions.append(transcript) }
        if let composer = container.composerFocusView { regions.append(composer) }
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

    func update(_ status: ConnectionStatus, source: String?) {
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
