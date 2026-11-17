import AppKit
import BelloCore
import ComposerKit
import DesignSystem
import Engine
import TerminalKit

/// What the terminal surfaces need from the window: the composer to put terminal text into, a thread for a draft,
/// and control of the bottom drawer (per-thread visibility and height).
@MainActor
protocol TerminalShell: AnyObject {
    /// The displayed thread's composer, if one is mounted.
    var terminalComposer: ComposerViewController? { get }
    /// Creates the displayed draft's thread (as its first send would) and returns its session.
    func terminalCreateThread() async -> SessionID?
    var isTerminalDrawerVisible: Bool { get }
    var terminalDrawerHeight: Double? { get }
    /// Shows or hides the drawer (instantly) and applies a saved height.
    func setTerminalDrawer(visible: Bool, height: Double?)
}

/// The window's terminals: one `TerminalWorkspace` (emulator cache) with a drawer surface and a right-panel surface,
/// both following the displayed thread. Created by `ShellSurfaces.builtIn` (Seams.swift) and bound to the window
/// by `MainWindowController.bindTerminals()`; before that (and in tests without an engine) it shows "No thread
/// selected".
///
/// Per-thread state lives in `Engine.terminals` (records, layout, drawer height); switching threads swaps sets
/// instantly and detaches the old thread's sockets without touching its PTYs.
@MainActor
final class TerminalSurfaces: TerminalWorkspaceDelegate {
    let services: AppServices
    private(set) var workspace: TerminalWorkspace?
    private(set) var drawer: TerminalSurfaceController?
    private(set) var panel: TerminalSurfaceController?
    private let drawerHost = TerminalHostController(placement: .drawer)
    private let panelHost = TerminalHostController(placement: .panel)
    private weak var shell: (any TerminalShell)?
    private var engine: Engine?
    private(set) var context: ThreadSurfaceContext?
    private(set) var terminals: ThreadTerminals?
    private var settingsLoop: ObservationLoop?
    /// While applying a thread's saved drawer state, layout callbacks are not recorded as user changes.
    private var isApplyingThreadLayout = false

    init(services: AppServices) {
        self.services = services
        drawerHost.owner = self
        panelHost.owner = self
    }

    func makeDrawerController() -> NSViewController { drawerHost }
    func makePanelController() -> NSViewController { panelHost }

    /// Binds to a window's engine and shell. Idempotent.
    func bind(engine: Engine, shell: any TerminalShell) {
        self.shell = shell
        guard self.engine == nil else { return }
        self.engine = engine
        TerminalPaneView.reservedShortcuts = ShellCommand.allCases.filter(\.isKeptWhileTerminalFocused).map(\.shortcut)
        let workspace = TerminalWorkspace(service: engine.terminals, preferences: services.settings.terminalPreferences)
        workspace.delegate = self
        self.workspace = workspace
        let drawer = workspace.makeSurface(.drawer)
        let panel = workspace.makeSurface(.panel)
        drawer.onChange = { [weak self] in self?.recordDrawerState() }
        self.drawer = drawer
        self.panel = panel
        drawerHost.mount(drawer)
        panelHost.mount(panel)
        settingsLoop = ObservationLoop { [weak self] in
            guard let self else { return }
            let preferences = self.services.settings.terminalPreferences
            if self.workspace?.preferences != preferences { self.workspace?.preferences = preferences }
        }
        display(context)
    }

    /// Detaches every emulator (window closing). PTYs keep running on the server.
    func close() {
        settingsLoop?.cancel()
        workspace?.close()
    }

    // MARK: Following the displayed thread

    /// Shows the terminals of the displayed thread (or the draft's project, or nothing) and applies the thread's
    /// saved drawer state.
    func display(_ context: ThreadSurfaceContext?) {
        self.context = context
        guard let engine, let drawer, let panel else { return }
        let directory = context.map { $0.directory.isEmpty ? $0.projectDirectory : $0.directory }
        let terminals = context?.thread.map { engine.terminals.terminals(for: $0.sessionID) }
        self.terminals = terminals
        let isDraft = context?.isDraft ?? false
        drawer.display(terminals, directory: directory, isDraft: isDraft)
        panel.display(terminals, directory: directory, isDraft: isDraft)
        guard let terminals else { return }
        Task { [weak self] in
            await terminals.waitUntilLoaded()
            guard let self, self.terminals === terminals, let open = terminals.set.isDrawerOpen else { return }
            self.isApplyingThreadLayout = true
            self.shell?.setTerminalDrawer(visible: open, height: terminals.set.drawerHeight)
            self.isApplyingThreadLayout = false
        }
    }

    /// The drawer was shown, hidden or resized: remember it for the displayed thread.
    func recordDrawerState() {
        guard !isApplyingThreadLayout, let shell, let terminals else { return }
        terminals.setDrawer(open: shell.isTerminalDrawerVisible, height: shell.isTerminalDrawerVisible ? shell.terminalDrawerHeight : nil)
    }

    // MARK: Commands

    /// The surface commands act on: the one with keyboard focus, else the drawer (the panel when only it has
    /// terminals and the drawer is hidden).
    var activeSurface: TerminalSurfaceController? {
        if let panel, panel.containsFocus { return panel }
        if let drawer, drawer.containsFocus { return drawer }
        if let drawer, shell?.isTerminalDrawerVisible == true || panel?.hasTerminals != true { return drawer }
        return panel ?? drawer
    }

    var hasContext: Bool { context != nil && engine != nil }
    var activeHasTerminal: Bool { activeSurface?.selectedRecord != nil }
    var activeIsRunning: Bool { activeSurface?.selectedRecord?.state.isRunning == true }
    var activeHasSelection: Bool { activeSurface?.selectedText != nil }
    var focusIsInTerminal: Bool { (drawer?.containsFocus ?? false) || (panel?.containsFocus ?? false) }
    var activePlacement: TerminalPlacement? { activeSurface?.placement }

    func newTerminal() {
        if shell?.isTerminalDrawerVisible == false, !(panel?.containsFocus ?? false) {
            shell?.setTerminalDrawer(visible: true, height: terminals?.set.drawerHeight)
        }
        (panel?.containsFocus == true ? panel : drawer)?.newTerminal()
    }

    func closeTerminal() { activeSurface?.closeSelected() }
    func selectNext() { activeSurface?.selectAdjacent(1) }
    func selectPrevious() { activeSurface?.selectAdjacent(-1) }
    func clear() { activeSurface?.clearSelected() }
    func rename() { activeSurface?.renameSelected() }
    func restart() { activeSurface?.restartSelected() }
    func moveToOtherPlace() { activeSurface?.moveSelectedToOtherPlace() }
    func sendSelectionToComposer() { activeSurface?.sendSelectionToComposer() }

    func toggleSplit() {
        if shell?.isTerminalDrawerVisible == false { shell?.setTerminalDrawer(visible: true, height: terminals?.set.drawerHeight) }
        drawer?.toggleSplit()
    }

    /// Focuses the drawer's selected terminal (after showing the drawer).
    func focusDrawer() { drawer?.focus() }

    var drawerFocusView: NSView? { drawer?.preferredFocusView }

    // MARK: TerminalWorkspaceDelegate

    func terminalWorkspace(_ workspace: TerminalWorkspace, open link: TerminalLink) {
        // The built-in browser (BrowserKit) takes these later; for now the default browser, after SwiftTerm's checks.
        link.openInDefaultBrowser()
    }

    /// Puts the selection into the composer as a pasted text block (a chip). ComposerKit has no terminal-excerpt
    /// attachment yet; the block is named after the terminal so the agent knows where it came from.
    func terminalWorkspace(_ workspace: TerminalWorkspace, sendToComposer text: String, from record: TerminalRecord) {
        guard let composer = shell?.terminalComposer else { return NSSound.beep() }
        let lines = text.reduce(into: 1) { count, character in if character.isNewline { count += 1 } }
        let name = "Terminal \(record.displayTitle) (\(lines) line\(lines == 1 ? "" : "s")).txt"
        let rejected = composer.add(attachments: [.text(text, name: name)], actionName: "Add Terminal Output")
        if rejected.isEmpty { composer.focus() }
    }

    func terminalWorkspaceNeedsThread(_ workspace: TerminalWorkspace) async -> ThreadTerminals? {
        guard let engine, let sessionID = await shell?.terminalCreateThread() else { return nil }
        return engine.terminals.terminals(for: sessionID)
    }

    func terminalWorkspace(_ workspace: TerminalWorkspace, didChange preferences: TerminalPreferences) {
        services.settings.terminalPreferences = preferences
    }
}

/// The view controller the shell mounts for the drawer or the right-panel tab. It exists before the window binds
/// the terminals (the shell builds its layout first) and embeds the real surface once bound.
@MainActor
final class TerminalHostController: NSViewController, FocusableSurface {
    let placement: TerminalPlacement
    weak var owner: TerminalSurfaces?
    private var surface: TerminalSurfaceController?
    private let placeholder = NSHostingPlaceholder()

    init(placement: TerminalPlacement) {
        self.placement = placement
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The terminals of this window (the drawer controller is how the window finds them).
    var terminals: TerminalSurfaces? { owner }

    override func loadView() {
        let container = NSView()
        container.setAccessibilityLabel(placement == .drawer ? "Terminal drawer" : "Terminal")
        view = container
        if let surface { embed(surface) } else { embedPlaceholder() }
    }

    func mount(_ surface: TerminalSurfaceController) {
        self.surface = surface
        guard isViewLoaded else { return }
        placeholder.removeFromSuperview()
        embed(surface)
    }

    private func embed(_ surface: TerminalSurfaceController) {
        addChild(surface)
        pin(surface.view)
    }

    private func embedPlaceholder() {
        pin(placeholder)
    }

    private func pin(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.topAnchor), child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor), child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    var preferredFocusView: NSView? { surface?.preferredFocusView }
}

/// "No thread selected" before the terminals are bound (tests, the first layout pass).
@MainActor
final class NSHostingPlaceholder: NSView {
    private let label = NSTextField(labelWithString: "Select a thread to see its terminals.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = DS.Typography.current.caption
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
