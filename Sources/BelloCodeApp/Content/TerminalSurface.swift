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
    /// The window's built-in browser, for terminal links and dev-server offers.
    weak var browser: BrowserSurfaces?
    /// While applying a thread's saved drawer state, layout callbacks are not recorded as user changes.
    private var isApplyingThreadLayout = false

    init(services: AppServices) {
        self.services = services
        drawerHost.owner = self
        panelHost.owner = self
    }

    /// The strip above a terminal surface: the blocked banner, or "Container · image" when terminals run there.
    func makeEnvironmentStrip() -> NSView? {
        guard let engine, engine.environments.isEnabled else { return nil }
        let strip = TerminalEnvironmentStrip(engine: engine) { [weak self] in
            self?.context.map { $0.directory.isEmpty ? $0.projectDirectory : $0.directory }
        }
        environmentStrips.add(strip)
        return strip
    }
    private let environmentStrips = NSHashTable<TerminalEnvironmentStrip>.weakObjects()

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
        isClosed = true
        settingsLoop?.cancel()
        workspace?.close()
    }
    /// The window closed and its emulators were detached.
    private(set) var isClosed = false

    // MARK: Following the displayed thread

    /// Shows the terminals of the displayed thread (or the draft's project, or nothing) and applies the thread's
    /// saved drawer state.
    func display(_ context: ThreadSurfaceContext?) {
        self.context = context
        for strip in environmentStrips.allObjects { strip.refresh() }
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

    /// A terminal tab with a shell in one of the project's service containers (`bellocode-exec --service`).
    func newServiceTerminal(service: String, projectDirectory: String) {
        if shell?.isTerminalDrawerVisible == false { shell?.setTerminalDrawer(visible: true, height: terminals?.set.drawerHeight) }
        drawer?.newTerminal(extraArgs: ["--service", service, "--project", projectDirectory], title: "Service: \(service)")
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
        // The built-in browser by default (Settings ▸ Browser); ⇧ while clicking picks the other one. Anything that is
        // not an http(s) URL goes through SwiftTerm's checks to the system.
        let builtIn = services.settings.terminalLinksOpenInBuiltInBrowser != (NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
        if builtIn, let url = URL(string: link.text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), browser?.open(url) == true { return }
        link.openInDefaultBrowser()
    }

    func terminalWorkspace(_ workspace: TerminalWorkspace, screenText: String) {
        browser?.terminalPrinted(screenText)
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
        guard let strip = owner?.makeEnvironmentStrip() else {
            pin(surface.view)
            return
        }
        // Containerised execution (M6-A): where the terminal runs, or why it cannot, above the terminals.
        // The surface paints its background with the dirty rect, which (clipsToBounds being off by default) can cover
        // a sibling above it.
        surface.view.clipsToBounds = true
        let stack = NSStackView(views: [strip, surface.view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.detachesHiddenViews = true
        for view in [strip, surface.view] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        pin(stack)
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
        label.font = DS.TextRole.label.font
        label.textColor = DS.Color.text3
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
