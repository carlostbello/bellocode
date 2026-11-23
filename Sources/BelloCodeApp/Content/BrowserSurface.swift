import AppKit
import BelloCore
import BrowserKit
import ComposerKit
import DesignSystem
import Engine

/// What the browser surface needs from the window: the composer for picked elements, and showing the browser tab.
@MainActor
protocol BrowserShell: AnyObject {
    var browserComposer: ComposerViewController? { get }
    /// Shows the right panel on its "Browser" tab.
    func showBrowserPanel()
    var isBrowserPanelShown: Bool { get }
}

/// The window's built-in browser (BrowserKit): the "Browser" right-panel tab, following the displayed thread. Created
/// by `ShellSurfaces.builtIn` (Seams.swift) and bound to the window by `MainWindowController`.
///
/// - A thread's browser set (and its agent attachment) exists once the person shows the browser for that thread or
///   opens a link in it; showing another thread swaps sets instantly.
/// - Terminal links open here (⇧-click, or the setting, picks the default browser); dev-server URLs in terminal or
///   agent output are offered, never opened unasked.
/// - Picked elements go to the thread's composer as a text block plus the element's image.
@MainActor
final class BrowserSurfaces {
    let services: AppServices
    private(set) var workspace: BrowserWorkspace?
    private(set) var pane: BrowserPaneController?
    private let host = BrowserHostController()
    private weak var shell: (any BrowserShell)?
    private(set) var context: ThreadSurfaceContext?
    private var outputLoop: ObservationLoop?
    private var scanned: [MessageID: Int] = [:]

    init(services: AppServices) {
        self.services = services
        host.owner = self
    }

    func makePanelController() -> NSViewController { host }

    /// Binds to a window's engine. Idempotent.
    func bind(engine: Engine, shell: any BrowserShell) {
        self.shell = shell
        guard workspace == nil else { return }
        let workspace = BrowserWorkspace(engine: engine, isolatedProfiles: services.settings.isEphemeral)
        workspace.onRequestShow = { [weak self] set in
            guard let self, set.sessionID == self.context?.thread?.sessionID else { return }
            self.shell?.showBrowserPanel()
        }
        workspace.onPick = { [weak self] pick, _ in self?.insert(pick) }
        self.workspace = workspace
        let pane = BrowserPaneController(workspace: workspace)
        self.pane = pane
        host.mount(pane)
        display(context)
    }

    func close() async {
        outputLoop?.cancel()
        await workspace?.close()
    }

    // MARK: Following the displayed thread

    func display(_ context: ThreadSurfaceContext?) {
        self.context = context
        observeAgentOutput()
        guard let workspace, let pane else { return }
        guard let context else {
            pane.display(nil, context: nil)
            return
        }
        let paneContext = BrowserPaneContext(
            projectName: context.projectName, threadTitle: context.thread?.session?.displayTitle,
            sessionID: context.thread?.sessionID, projectDirectory: context.projectDirectory)
        guard let sessionID = context.thread?.sessionID else {
            pane.display(nil, context: paneContext)
            return
        }
        // A set is created (and attached) when the browser is on screen or already exists for the thread.
        let set = (shell?.isBrowserPanelShown ?? false)
            ? workspace.set(for: sessionID, projectDirectory: context.projectDirectory) : workspace.existingSet(for: sessionID)
        pane.display(set, context: paneContext)
    }

    /// The Browser tab appeared: make sure the displayed thread has its set.
    func panelShown() { display(context) }

    // MARK: Links and offers

    /// Opens a link in the displayed thread's browser. False when there is no thread (the caller opens it elsewhere).
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let workspace, let context, let sessionID = context.thread?.sessionID, BrowserAddress.isWebScheme(url) else { return false }
        if let environments = workspace.engine?.environments, environments.isEnabled {
            // M6-A: a dev server in the project's container is reached through a loopback-only forward on demand.
            let directory = context.directory.isEmpty ? context.projectDirectory : context.directory
            Task { [weak workspace] in
                let mapped = await environments.browserURL(for: url, directory: directory) ?? url
                workspace?.open(mapped, in: sessionID, projectDirectory: context.projectDirectory)
            }
            shell?.showBrowserPanel()
            display(context)
            return true
        }
        workspace.open(url, in: sessionID, projectDirectory: context.projectDirectory)
        shell?.showBrowserPanel()
        display(context)
        return true
    }

    /// Terminal output: offer dev-server URLs to the displayed thread.
    func terminalPrinted(_ text: String) {
        guard services.settings.offersDevServers, let sessionID = context?.thread?.sessionID else { return }
        for url in BrowserAddress.devServerURLs(in: text).suffix(1) { offer(url, for: sessionID) }
    }

    /// Offers a dev server; in a containerised project the offer carries the loopback forward's URL (M6-A).
    private func offer(_ url: URL, for sessionID: SessionID) {
        guard let workspace, let environments = workspace.engine?.environments, environments.isEnabled, let context else {
            workspace?.offerDevServer(url, for: sessionID)
            return
        }
        let directory = context.directory.isEmpty ? context.projectDirectory : context.directory
        Task { [weak workspace] in
            let mapped = await environments.browserURL(for: url, directory: directory) ?? url
            workspace?.offerDevServer(mapped, for: sessionID)
        }
    }

    /// Agent output (tool results and text of the newest messages) can name a dev server too.
    private func observeAgentOutput() {
        outputLoop?.cancel()
        guard let thread = context?.thread else { return }
        outputLoop = ObservationLoop { [weak self, weak thread] in
            guard let self, let thread else { return }
            for id in thread.messageIDs.suffix(3) {
                guard let model = thread.message(id) else { continue }
                let revision = model.revision
                guard self.scanned[id] != revision else { continue }
                self.scanned[id] = revision
                if self.scanned.count > 200 { self.scanned.removeAll() }
                guard !model.message.isStreaming else { continue }
                self.scan(model.message, sessionID: thread.sessionID)
            }
        }
    }

    private func scan(_ message: Message, sessionID: SessionID) {
        guard services.settings.offersDevServers else { return }
        var text = ""
        if case .shell(let info) = message.kind { text += info.output ?? "" }
        for part in message.parts {
            switch part.content {
            case .text(let value): text += value + "\n"
            case .tool(let call):
                for output in call.output { if case .text(let value) = output { text += value.suffix(8_192) + "\n" } }
            default: break
            }
        }
        if let url = BrowserAddress.devServerURLs(in: text).last { offer(url, for: sessionID) }
    }

    // MARK: Picked elements

    private func insert(_ pick: BrowserPick) {
        guard let composer = shell?.browserComposer else { return NSSound.beep() }
        let host = URL(string: pick.url)?.host() ?? "page"
        var attachments: [ComposerAttachment] = [.text(pick.contextText, name: "Element <\(pick.tag)> on \(host).txt")]
        if let image = pick.image { attachments.append(.image(image, type: .png, name: "Element <\(pick.tag)> on \(host).png")) }
        let rejected = composer.add(attachments: attachments, actionName: "Add Picked Element")
        if rejected.isEmpty { composer.focus() }
    }

    // MARK: Commands (the Browser menu)

    func canPerform(_ command: BrowserPaneCommand) -> Bool {
        guard let pane, context?.thread != nil else { return false }
        if command == .newTab || command == .newPrivateTab { return pane.set != nil || context?.thread != nil }
        return pane.canPerform(command)
    }

    func perform(_ command: BrowserPaneCommand) {
        if pane?.set == nil, command == .newTab || command == .newPrivateTab {
            shell?.showBrowserPanel()
            display(context)
        }
        if command == .openLocation || command == .findInPage || command == .pickElement { shell?.showBrowserPanel() }
        pane?.perform(command)
    }

    func setViewport(_ preset: ViewportPreset?) { pane?.setViewport(preset) }

    var isPanelShown: Bool { shell?.isBrowserPanelShown ?? false }

    var focusIsInBrowser: Bool {
        guard let view = pane?.view, let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }
}

/// The right-panel tab's view controller. Exists before the window binds the browser, then embeds the pane.
@MainActor
final class BrowserHostController: NSViewController {
    weak var owner: BrowserSurfaces?
    private var pane: BrowserPaneController?
    private let placeholder = NSHostingPlaceholder()

    override func loadView() {
        let container = NSView()
        container.setAccessibilityLabel("Browser")
        view = container
        if let pane { embed(pane) } else { pin(placeholder) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        owner?.panelShown()
    }

    func mount(_ pane: BrowserPaneController) {
        self.pane = pane
        guard isViewLoaded else { return }
        placeholder.removeFromSuperview()
        embed(pane)
    }

    private func embed(_ pane: BrowserPaneController) {
        addChild(pane)
        pin(pane.view)
    }

    private func pin(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.topAnchor), child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor), child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

/// The Browser menu. Its items target the router, which forwards to the key window's browser, so they work wherever
/// focus is (the page sees keys first; text fields keep theirs). ⌘F/⌘G find in the page while the browser has focus
/// (BrowserPaneView answers the shell's Find selectors).
@MainActor
enum BrowserMenu {
    struct Item {
        var title: String
        var command: BrowserPaneCommand
        var key: String
        var modifiers: NSEvent.ModifierFlags
    }

    static let items: [[Item]] = [
        [
            Item(title: "New Browser Tab", command: .newTab, key: "t", modifiers: [.command, .control]),
            Item(title: "New Private Tab", command: .newPrivateTab, key: "t", modifiers: [.command, .control, .shift]),
            Item(title: "Reopen Closed Tab", command: .reopenClosedTab, key: "t", modifiers: [.command, .control, .option]),
            Item(title: "Close Browser Tab", command: .closeTab, key: "w", modifiers: [.command, .control]),
            Item(title: "Show Next Browser Tab", command: .nextTab, key: "\t", modifiers: [.control]),
            Item(title: "Show Previous Browser Tab", command: .previousTab, key: "\t", modifiers: [.control, .shift]),
        ],
        [
            Item(title: "Open Location…", command: .openLocation, key: "l", modifiers: [.command]),
            Item(title: "Back", command: .back, key: "[", modifiers: [.command, .control]),
            Item(title: "Forward", command: .forward, key: "]", modifiers: [.command, .control]),
            Item(title: "Reload Page", command: .reload, key: "r", modifiers: [.command]),
            Item(title: "Reload Page from Origin", command: .reloadFromOrigin, key: "r", modifiers: [.command, .shift]),
            Item(title: "Stop Loading", command: .stopLoading, key: "", modifiers: []),
        ],
        [
            Item(title: "Zoom In", command: .zoomIn, key: "=", modifiers: [.command]),
            Item(title: "Zoom Out", command: .zoomOut, key: "-", modifiers: [.command]),
            Item(title: "Actual Size", command: .actualSize, key: "0", modifiers: [.command]),
            Item(title: "Find in Page…", command: .findInPage, key: "", modifiers: []),
        ],
        [
            Item(title: "Pick Element for Composer", command: .pickElement, key: "c", modifiers: [.command, .shift]),
            Item(title: "Share Tab with Agent", command: .shareTab, key: "", modifiers: []),
            Item(title: "Stop Agent in Browser", command: .stopAgent, key: "", modifiers: []),
            Item(title: "Take Over Tab", command: .takeOver, key: "", modifiers: []),
            Item(title: "Resume Agent", command: .resumeAgent, key: "", modifiers: []),
            Item(title: "Let Agent Control Browser", command: .toggleAgentControl, key: "", modifiers: []),
            Item(title: "Reconnect Agent", command: .reconnectAgent, key: "", modifiers: []),
        ],
        [
            Item(title: "Open in Default Browser", command: .openInDefaultBrowser, key: "", modifiers: []),
            Item(title: "Allow Web Inspector", command: .toggleWebInspector, key: "", modifiers: []),
            Item(title: "Clear Site Data for This Project…", command: .clearSiteData, key: "", modifiers: []),
        ],
    ]

    static func make() -> NSMenu {
        let menu = NSMenu(title: "Browser")
        let show = NSMenuItem(title: "Show Browser", action: #selector(BrowserMenuRouter.showBrowser(_:)), keyEquivalent: "b")
        show.keyEquivalentModifierMask = [.command, .control]
        show.target = BrowserMenuRouter.shared
        menu.addItem(show)
        menu.addItem(.separator())
        for (index, group) in items.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for item in group {
                let entry = NSMenuItem(title: item.title, action: #selector(BrowserMenuRouter.perform(_:)), keyEquivalent: item.key)
                entry.keyEquivalentModifierMask = item.modifiers
                entry.representedObject = item.command.rawValue
                entry.target = BrowserMenuRouter.shared
                menu.addItem(entry)
            }
            if index == 2 {
                let responsive = NSMenu(title: "Responsive Size")
                let fill = NSMenuItem(title: "Fill Pane", action: #selector(BrowserMenuRouter.setViewport(_:)), keyEquivalent: "")
                fill.tag = -1
                fill.target = BrowserMenuRouter.shared
                responsive.addItem(fill)
                for (presetIndex, preset) in ViewportPreset.presets.enumerated() {
                    let entry = NSMenuItem(title: "\(preset.name)  \(preset.width) × \(preset.height)", action: #selector(BrowserMenuRouter.setViewport(_:)), keyEquivalent: "")
                    entry.tag = presetIndex
                    entry.target = BrowserMenuRouter.shared
                    responsive.addItem(entry)
                }
                let custom = NSMenuItem(title: "Custom Size…", action: #selector(BrowserMenuRouter.perform(_:)), keyEquivalent: "")
                custom.representedObject = BrowserPaneCommand.responsiveCustom.rawValue
                custom.target = BrowserMenuRouter.shared
                responsive.addItem(custom)
                let responsiveItem = NSMenuItem(title: "Responsive Size", action: nil, keyEquivalent: "")
                responsiveItem.submenu = responsive
                menu.addItem(responsiveItem)
                let appearance = NSMenu(title: "Page Appearance")
                for (title, command) in [("Match BelloCode", BrowserPaneCommand.appearanceSystem), ("Light", .appearanceLight), ("Dark", .appearanceDark)] {
                    let entry = NSMenuItem(title: title, action: #selector(BrowserMenuRouter.perform(_:)), keyEquivalent: "")
                    entry.representedObject = command.rawValue
                    entry.target = BrowserMenuRouter.shared
                    appearance.addItem(entry)
                }
                let appearanceItem = NSMenuItem(title: "Page Appearance", action: nil, keyEquivalent: "")
                appearanceItem.submenu = appearance
                menu.addItem(appearanceItem)
            }
        }
        // The shared Chromium (Content/SharedChromeSurface.swift).
        SharedChromeMenu.append(to: menu)
        return menu
    }

    /// Shortcuts that also mean something to a text field, the terminal or a page (⌘L, ⌘R, ⇧⌘R, ⌘=, ⌘-, ⌘0, ⇧⌘C,
    /// ⌃⇥, ⌃⇧⇥): typed, they reach the browser only while it is shown and has focus, and otherwise stay with the focused
    /// view (NV05). The explicit ⌃⌘ browser shortcuts stay global; every item still works from the menu itself.
    static let focusScoped: Set<BrowserPaneCommand> = Set(
        items.flatMap { $0 }.filter { !$0.key.isEmpty && !$0.modifiers.isSuperset(of: [.command, .control]) }.map(\.command))

    static func allowsShortcut(_ command: BrowserPaneCommand, fromKeyboard: Bool, browserShown: Bool, focusInBrowser: Bool) -> Bool {
        guard fromKeyboard, focusScoped.contains(command) else { return true }
        return browserShown && focusInBrowser
    }

    /// Every shortcut the Browser menu uses ("key-modifiers"), for the uniqueness test.
    static var shortcuts: [String] {
        (items.flatMap { $0 }.filter { !$0.key.isEmpty }.map { "\($0.key)-\($0.modifiers.rawValue)" })
            + ["b-\(NSEvent.ModifierFlags([.command, .control]).rawValue)", "b-\(NSEvent.ModifierFlags([.command, .control, .option]).rawValue)"]
    }
}

/// Forwards Browser menu items to the key (or main) window's browser and validates them.
@MainActor
final class BrowserMenuRouter: NSObject, NSMenuItemValidation {
    static let shared = BrowserMenuRouter()

    private var surfaces: BrowserSurfaces? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        return ((window?.windowController ?? NSApp.mainWindow?.windowController) as? MainWindowController)?.browser
    }

    @objc func showBrowser(_ sender: Any?) {
        guard let controller = (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? MainWindowController else { return }
        controller.showBrowserPanel()
    }

    @objc func perform(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = BrowserPaneCommand(rawValue: raw) else { return }
        surfaces?.perform(command)
    }

    @objc func setViewport(_ sender: NSMenuItem) {
        surfaces?.setViewport(sender.tag < 0 ? nil : ViewportPreset.presets[sender.tag])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validate(menuItem, surfaces: surfaces, event: NSApp.currentEvent)
    }

    /// `event`: what is being handled now; a key-down means the item is matched as a key equivalent, not chosen in the
    /// menu. A disabled match is not consumed, so the focused view gets the key.
    func validate(_ menuItem: NSMenuItem, surfaces: BrowserSurfaces?, event: NSEvent?) -> Bool {
        if menuItem.action == #selector(showBrowser(_:)) { return surfaces != nil }
        if menuItem.action == #selector(setViewport(_:)) {
            let current = surfaces?.pane?.selectedTab?.viewport
            menuItem.state = (menuItem.tag < 0 ? current == nil : current == ViewportPreset.presets[menuItem.tag]) ? .on : .off
            return surfaces?.canPerform(.responsiveOff) ?? false
        }
        guard let raw = menuItem.representedObject as? String, let command = BrowserPaneCommand(rawValue: raw), let surfaces else { return false }
        switch command {
        case .toggleAgentControl:
            let enabled = surfaces.pane?.set?.sessionID.flatMap { surfaces.workspace?.engine?.browser.isControlEnabled($0) } ?? false
            menuItem.state = enabled ? .on : .off
        case .shareTab:
            menuItem.title = surfaces.pane?.selectedTab?.isShared == true ? "Stop Sharing Tab with Agent" : "Share Tab with Agent"
        case .toggleWebInspector:
            menuItem.state = surfaces.workspace?.isWebInspectorEnabled == true ? .on : .off
        case .appearanceSystem, .appearanceLight, .appearanceDark:
            let current = surfaces.pane?.selectedTab?.appearance
            menuItem.state = (command == .appearanceSystem && current == .system) || (command == .appearanceLight && current == .light)
                || (command == .appearanceDark && current == .dark) ? .on : .off
        default:
            break
        }
        let fromKeyboard = event?.type == .keyDown
        guard BrowserMenu.allowsShortcut(command, fromKeyboard: fromKeyboard, browserShown: surfaces.isPanelShown,
                                         focusInBrowser: surfaces.focusIsInBrowser)
        else { return false }
        return surfaces.canPerform(command)
    }
}
