import AppKit
import DesignSystem

/// A split view whose dividers are 1 pt `border` hairlines (visual-language.md §4: regions are separated by tone and
/// one hairline, never a system separator).
@MainActor
final class ChromeSplitView: NSSplitView {
    override var dividerColor: NSColor { DS.Color.border }
    override var dividerThickness: CGFloat { DS.Border.hairline }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The window's content root: the split view, with the 52 pt header bar laid over its top edge.
///
/// The title bar is transparent and the window has an empty unified toolbar, so the traffic lights sit centred in the
/// top 52 pt of the sidebar (visual-language.md §6 "Thread header"). The header bar spans from the sidebar's divider
/// to the window's right edge (over the content column and the right panel, as in the mock); over the sidebar it is
/// transparent and only carries the sidebar and new-thread buttons. Every region below reserves `DS.Size.header`.
@MainActor
final class ShellRootViewController: NSViewController {
    let split: MainSplitViewController
    let header = ShellHeaderBar()

    init(split: MainSplitViewController) {
        self.split = split
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        addChild(split)
        split.view.frame = root.bounds
        split.view.autoresizingMask = [.width, .height]
        root.addSubview(split.view)
        root.addSubview(header)
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutHeader()
    }

    /// Places the header over the top edge and tells it where the sidebar ends (call after any split change).
    func layoutHeader() {
        let bounds = view.bounds
        let frame = NSRect(x: 0, y: bounds.height - DS.Size.header, width: bounds.width, height: DS.Size.header)
        if header.frame != frame { header.frame = frame }
        let sidebar = split.sidebarItem
        let width: CGFloat? = sidebar.isCollapsed ? nil : sidebar.viewController.view.frame.width
        let fullScreen = view.window?.styleMask.contains(.fullScreen) ?? false
        if header.sidebarWidth != width || header.isFullScreen != fullScreen {
            header.sidebarWidth = width
            header.isFullScreen = fullScreen
            header.needsLayout = true
            header.needsDisplay = true
        }
    }
}

/// The 52 pt bar at the top of the window (visual-language.md §6 "Thread header"): sidebar and new-thread icon
/// buttons beside the traffic lights, then the thread's title and crumbs (`ThreadHeaderView`), then "Open ⌄" and
/// "Commit n" outline buttons, a divider and the terminal and right-panel toggles.
///
/// Every button sends its action up the responder chain (nil target), so menus, shortcuts and the bar agree and
/// validation is shared. A click on the bar's empty area drags the window; a double-click zooms or minimises as the
/// user's "double-click a window's title bar" setting says.
@MainActor
final class ShellHeaderBar: NSView {
    /// The sidebar's width when it is shown (the bar is transparent over it), nil when collapsed.
    var sidebarWidth: CGFloat?
    /// Full screen hides the traffic lights, so the collapsed-sidebar buttons move to the edge.
    var isFullScreen = false

    let sidebarButton = DSButton(icon: "sidebar.left", accessibilityTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)))
    let newThreadButton = DSButton(icon: "square.and.pencil", accessibilityTitle: "New Thread", action: ShellCommand.newThread.selector)
    let openButton = DSSelectButton(title: "Open", symbolName: "arrow.up.forward.square", chevron: .down, size: .small)
    let commitButton = DSButton(title: "Commit", variant: .outline, size: .small, symbolName: "arrow.triangle.branch", action: ShellCommand.gitQuickAction.selector)
    /// Git parity: the git actions popover beside the quick action (T3 Code GitActionsControl's menu trigger).
    let gitMenuButton = DSButton(icon: "chevron.down", accessibilityTitle: "Git Actions", action: ShellCommand.showGitActions.selector)
    let terminalToggle = DSButton(icon: "apple.terminal", accessibilityTitle: "Toggle Terminal", action: ShellCommand.toggleTerminal.selector)
    let panelToggle = DSButton(icon: "sidebar.right", accessibilityTitle: "Toggle Right Panel", action: #selector(NSSplitViewController.toggleInspector(_:)))
    /// The containers runtime state (M6-A), hidden while container execution is off.
    var runtimeView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let runtimeView { addSubview(runtimeView) }
            needsLayout = true
        }
    }
    private let divider = DSDivider(vertical: true)
    /// The thread's title and crumbs (owned by the content area; nil for the empty states).
    private(set) var titleView: NSView?

    /// Room left for the traffic lights (close, minimise, zoom at x 19…71 with the unified title bar).
    static let trafficLightWidth: CGFloat = 78
    /// Inset of the title from the sidebar's divider (the mock's 20 pt).
    static let titleInset: CGFloat = 20
    static let edgeInset: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        sidebarButton.toolTip = "Show or Hide Sidebar (⌃⌘S)"
        newThreadButton.toolTip = "New Thread (⌘N)"
        openButton.variant = .outline
        openButton.isMuted = false
        openButton.toolTip = "Open the project in Finder or an editor"
        openButton.setAccessibilityLabel("Open")
        commitButton.toolTip = "Run the suggested git action (⌃⌘↩)"
        gitMenuButton.toolTip = "Git Actions (⌃⌘G)"
        terminalToggle.isToggle = true
        terminalToggle.toolTip = "Show or Hide Terminal (⌃`)"
        panelToggle.isToggle = true
        panelToggle.toolTip = "Show or Hide Right Panel (⌥⌘I)"
        for view in [sidebarButton, newThreadButton, openButton, commitButton, gitMenuButton, divider, terminalToggle, panelToggle] as [NSView] {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Window toolbar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Shows a thread's title view (or nothing); the previous one is removed.
    func setTitleView(_ view: NSView?) {
        guard view !== titleView else { return }
        titleView?.removeFromSuperview()
        titleView = view
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view, positioned: .below, relativeTo: openButton)
        }
        needsLayout = true
    }

    /// Where the bar's own background starts (the sidebar's divider, or 0 when the sidebar is collapsed).
    var contentMinX: CGFloat { sidebarWidth.map { $0 + DS.Border.hairline } ?? 0 }

    override func layout() {
        super.layout()
        let height = bounds.height
        func place(_ view: NSView, x: CGFloat, width: CGFloat? = nil) {
            let size = view.fittingSize
            let w = width ?? size.width
            view.frame = NSRect(x: x, y: ((height - size.height) / 2).rounded(), width: w, height: size.height)
        }
        // Leading: the sidebar's two icon buttons, right-aligned in the sidebar, or after the traffic lights.
        let icon = DS.Size.control
        let gap: CGFloat = 3
        let leadingX: CGFloat
        if let sidebarWidth {
            leadingX = sidebarWidth - DS.Space.s8 - icon * 2 - gap
        } else {
            leadingX = isFullScreen ? DS.Space.s8 : Self.trafficLightWidth
        }
        place(sidebarButton, x: leadingX)
        place(newThreadButton, x: leadingX + icon + gap)
        // Trailing, right to left: panel toggle, terminal toggle, divider, Commit, Open, runtime status.
        var x = bounds.width - Self.edgeInset
        x -= icon
        place(panelToggle, x: x)
        x -= icon + DS.Space.s4
        place(terminalToggle, x: x)
        x -= DS.Space.s8 + DS.Border.hairline
        divider.frame = NSRect(x: x, y: (height - 16) / 2, width: DS.Border.hairline, height: 16)
        x -= DS.Space.s8
        for view in [gitMenuButton, commitButton, openButton] as [NSView] where !view.isHidden {
            let width = view.fittingSize.width
            x -= width
            place(view, x: x)
            x -= DS.Space.s8
        }
        if let runtimeView, !runtimeView.isHidden {
            let width = runtimeView.fittingSize.width
            x -= width
            place(runtimeView, x: x)
            x -= DS.Space.s8
        }
        // The title fills what is left.
        let titleX = sidebarWidth == nil
            ? newThreadButton.frame.maxX + DS.Space.s12
            : contentMinX + Self.titleInset
        if let titleView {
            let width = max(0, x - DS.Space.s4 - titleX)
            let fitting = titleView.fittingSize
            titleView.frame = NSRect(x: titleX, y: ((height - fitting.height) / 2).rounded(), width: width, height: fitting.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let minX = contentMinX
        let rect = NSRect(x: minX, y: 0, width: bounds.width - minX, height: bounds.height)
        DS.Color.canvas.setFill()
        rect.fill(using: .sourceOver)
        DS.Color.border.setFill()
        NSRect(x: minX, y: bounds.height - DS.Border.hairline, width: rect.width, height: DS.Border.hairline).fill(using: .sourceOver)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Window dragging

    /// Clicks on the bar's empty area (and over the sidebar's top strip) move the window like a title bar.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            Self.performTitleBarDoubleClick(window)
            return
        }
        window.performDrag(with: event)
    }

    /// The system's "double-click a window's title bar to" setting: zoom (default), minimise or nothing.
    static func performTitleBarDoubleClick(_ window: NSWindow) {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        switch action {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}
