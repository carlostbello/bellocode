import AppKit
import DesignSystem

/// The window's regions: sidebar | content (thread over a bottom terminal drawer) | right panel (inspector).
///
/// Panels open and close instantly by default (AGENTS.md rule 17); `DS.Motion.panelDuration` can add an animation,
/// which Reduce Motion removes. Divider positions and collapse state are saved with AppKit autosave; visibility is
/// also recorded in `ShellState` and re-applied at launch, so restoration does not depend on autosave timing.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    let sidebarItem: NSSplitViewItem
    let contentItem: NSSplitViewItem
    let panelItem: NSSplitViewItem
    let contentSplit: ContentSplitViewController
    private let autosaveName: String?
    /// Called after a panel is shown or hidden by any route (menu, toolbar, divider drag).
    var onLayoutChange: (() -> Void)?

    init(sidebar: NSViewController, content: ContentSplitViewController, panel: NSViewController, autosaveName: String?) {
        contentSplit = content
        // Plain items, not the sidebar / inspector behaviours: those bring the system's sidebar material (a floating
        // glass panel on current macOS), and the visual language wants solid regions split by one hairline.
        sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = DS.Size.sidebarMinWidth
        sidebarItem.maximumThickness = DS.Size.sidebarMaxWidth
        sidebarItem.canCollapse = true
        // Window resizes go to the content, never the side panels (they stay as the user set them; restored by
        // autosave). Above the content column's width preference (255) and below the window's own size (500), so a
        // surface can neither move a divider nor resize the window.
        sidebarItem.holdingPriority = Self.sideHoldingPriority
        contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 420
        panelItem = NSSplitViewItem(viewController: panel)
        panelItem.minimumThickness = DS.Size.rightPanelMinWidth
        panelItem.maximumThickness = 760
        panelItem.canCollapse = true
        panelItem.holdingPriority = Self.sideHoldingPriority
        panelItem.isCollapsed = true
        self.autosaveName = autosaveName
        super.init(nibName: nil, bundle: nil)
        splitView = ChromeSplitView()
        splitView.isVertical = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin
        // The first-launch widths: split items start at their view's frame size, and the side panels hold it.
        sidebarItem.viewController.view.setFrameSize(NSSize(width: Self.defaultSidebarWidth, height: 600))
        panelItem.viewController.view.setFrameSize(NSSize(width: Self.defaultPanelWidth, height: 600))
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(panelItem)
        let hasSavedLayout = autosaveName.map { UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \($0)") != nil } ?? false
        if let autosaveName { splitView.autosaveName = autosaveName }
        if !hasSavedLayout { needsDefaultWidths = true }
    }

    private var needsDefaultWidths = false
    static let defaultSidebarWidth: CGFloat = DS.Size.sidebarWidth
    static let defaultPanelWidth: CGFloat = DS.Size.rightPanelWidth
    static let sideHoldingPriority = NSLayoutConstraint.Priority(270)

    override func viewDidAppear() {
        super.viewDidAppear()
        applyDefaultWidthsIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if needsDefaultWidths, view.window?.isVisible == true { applyDefaultWidthsIfNeeded() }
    }

    /// First launch (no autosaved layout): the spec's 264 pt sidebar and 416 pt panel.
    func applyDefaultWidthsIfNeeded() {
        guard needsDefaultWidths, splitView.bounds.width > 400 else { return }
        needsDefaultWidths = false
        splitView.setPosition(Self.defaultSidebarWidth, ofDividerAt: 0)
        if !panelItem.isCollapsed { splitView.setPosition(splitView.bounds.width - Self.defaultPanelWidth, ofDividerAt: 1) }
    }

    /// Sets a panel's collapsed state, instantly unless a panel duration is configured (and Reduce Motion is off).
    func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool) {
        guard item.isCollapsed != collapsed else { return }
        let duration = DS.Motion.effectivePanelDuration
        if duration > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                item.animator().isCollapsed = collapsed
            }
        } else {
            item.isCollapsed = collapsed
        }
        onLayoutChange?()
    }

    override func toggleSidebar(_ sender: Any?) { setCollapsed(sidebarItem, !sidebarItem.isCollapsed) }

    override func toggleInspector(_ sender: Any?) { setCollapsed(panelItem, !panelItem.isCollapsed) }

    /// The plain split items have no sidebar / inspector behaviour, so the toggles are validated (and retitled) here.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(toggleSidebar(_:)):
            (item as? NSMenuItem)?.title = sidebarItem.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
            return true
        case #selector(toggleInspector(_:)):
            (item as? NSMenuItem)?.title = panelItem.isCollapsed ? "Show Right Panel" : "Hide Right Panel"
            return true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        onLayoutChange?()
    }
}

/// The content column: the thread on top, the terminal drawer below (collapsed by default).
@MainActor
final class ContentSplitViewController: NSSplitViewController {
    let threadItem: NSSplitViewItem
    let drawerItem: NSSplitViewItem
    private let autosaveName: String?
    /// Called after the drawer is resized or collapsed by any route (divider drag, command).
    var onLayoutChange: (() -> Void)?

    init(thread: NSViewController, drawer: NSViewController, autosaveName: String?) {
        threadItem = NSSplitViewItem(viewController: thread)
        threadItem.minimumThickness = 240
        drawerItem = NSSplitViewItem(viewController: drawer)
        drawerItem.minimumThickness = 120
        drawerItem.canCollapse = true
        drawerItem.isCollapsed = true
        drawerItem.holdingPriority = .defaultLow + 10
        self.autosaveName = autosaveName
        super.init(nibName: nil, bundle: nil)
        splitView = ChromeSplitView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        addSplitViewItem(threadItem)
        addSplitViewItem(drawerItem)
        if let autosaveName { splitView.autosaveName = autosaveName }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        onLayoutChange?()
    }

    /// The drawer's height while it is shown.
    var drawerHeight: Double? {
        drawerItem.isCollapsed ? nil : Double(drawerItem.viewController.view.frame.height)
    }

    /// Sets the drawer's height (instant; clamped so the thread keeps its minimum).
    func setDrawerHeight(_ height: Double) {
        guard !drawerItem.isCollapsed, splitView.bounds.height > 0 else { return }
        let maximum = splitView.bounds.height - threadItem.minimumThickness - splitView.dividerThickness
        let clamped = min(max(CGFloat(height), drawerItem.minimumThickness), max(drawerItem.minimumThickness, maximum))
        splitView.setPosition(splitView.bounds.height - clamped - splitView.dividerThickness, ofDividerAt: 0)
    }
}

/// The right panel: a 40 pt pill tab bar (`DSTabBar`, visual-language.md §6 "Right panel") over the selected tab's
/// content, below the window's 52 pt header bar. Tab content is created on first selection. Tabs that do not fit drop
/// their titles from the end (icon only, the title stays their accessibility label); the selected tab keeps its title.
@MainActor
final class RightPanelViewController: NSViewController {
    private let tabs: [RightPanelTab]
    let tabBar = DSTabBar()
    private let host = NSView()
    private var built: [String: NSViewController] = [:]
    private(set) var selectedID: String?
    /// Live counts shown after a tab's title ("Changes 3", "Agents 2"); nil hides the count.
    private var counts: [String: Int] = [:]
    private var compactIDs: Set<String> = []
    var onTabChange: ((String) -> Void)?

    init(tabs: [RightPanelTab], selectedID: String?) {
        self.tabs = tabs
        self.selectedID = tabs.contains { $0.id == selectedID } ? selectedID : tabs.first?.id
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = PanelBackgroundView()
        tabBar.setItems(items())
        tabBar.selectedID = selectedID
        tabBar.onSelect = { [weak self] id in self?.select(id) }
        tabBar.setAccessibilityLabel("Panel tabs")
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        host.translatesAutoresizingMaskIntoConstraints = false
        let separator = DSDivider()
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabBar)
        container.addSubview(separator)
        container.addSubview(host)
        let barTop = DS.Size.header + (DS.Size.tabBar - DS.Size.tab) / 2
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: container.topAnchor, constant: barTop),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: DS.Space.s8),
            tabBar.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -DS.Space.s8),
            tabBar.heightAnchor.constraint(equalToConstant: DS.Size.tab),
            separator.topAnchor.constraint(equalTo: container.topAnchor, constant: DS.Size.header + DS.Size.tabBar),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: DS.Border.hairline),
            host.topAnchor.constraint(equalTo: separator.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let selectedID { select(selectedID) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitTabs()
    }

    private func items() -> [DSChoiceItem] {
        tabs.map { tab in
            let compact = compactIDs.contains(tab.id) && tab.id != selectedID
            return DSChoiceItem(
                id: tab.id, title: compact ? "" : tab.title, symbolName: tab.symbolName, count: compact ? nil : counts[tab.id],
                accessibilityLabel: tab.title)
        }
    }

    /// Drops titles from the last tabs until the bar fits the panel (and gives them back when it widens).
    private func fitTabs() {
        let available = view.bounds.width - DS.Space.s8 * 2
        guard available > 0 else { return }
        var compact: Set<String> = []
        func width(_ compact: Set<String>) -> CGFloat {
            tabs.reduce(CGFloat(0)) { sum, tab in
                let isCompact = compact.contains(tab.id) && tab.id != selectedID
                var w: CGFloat = 14 + 14
                if !isCompact {
                    w += DSDraw.width(of: tab.title, font: DS.TextRole.labelEmph.font) + 5
                    if let count = counts[tab.id] { w += 5 + DSDraw.width(of: "\(count)", font: DS.TextRole.meta.font) }
                }
                return sum + ceil(w) + 2
            }
        }
        for tab in tabs.reversed() where width(compact) > available {
            if tab.id != selectedID { compact.insert(tab.id) }
        }
        guard compact != compactIDs else { return }
        compactIDs = compact
        tabBar.setItems(items())
        tabBar.selectedID = selectedID
    }

    /// Sets a tab's count ("Changes 3"); nil or 0 hides it.
    func setCount(_ count: Int?, for id: String) {
        let value = count.flatMap { $0 > 0 ? $0 : nil }
        guard counts[id] != value, let tab = tabs.first(where: { $0.id == id }) else { return }
        counts[id] = value
        if !compactIDs.contains(id) || id == selectedID {
            tabBar.update(DSChoiceItem(id: id, title: tab.title, symbolName: tab.symbolName, count: value, accessibilityLabel: tab.title))
        }
        view.needsLayout = true
    }

    /// Shows a tab by ID (creating its view controller once).
    func select(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let changed = selectedID != id
        let titlesChange = changed && (compactIDs.contains(id) || compactIDs.contains(selectedID ?? ""))
        selectedID = id
        if titlesChange {
            // The selected tab always shows its title; the bar re-fits on the next layout.
            tabBar.setItems(items())
            view.needsLayout = true
        }
        tabBar.selectedID = id
        for child in children { child.view.removeFromSuperview() }
        let controller = built[id] ?? {
            let controller = tabs[index].make()
            built[id] = controller
            addChild(controller)
            return controller
        }()
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        if changed { onTabChange?(id) }
    }
}

/// A view that paints the `canvas` token (the right panel and other docked regions are solid canvas).
@MainActor
final class PanelBackgroundView: NSView {
    var color: NSColor = DS.Color.canvas { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
