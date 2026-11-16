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
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.preferredThicknessFraction = 0.2
        contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 420
        panelItem = NSSplitViewItem(inspectorWithViewController: panel)
        panelItem.minimumThickness = 280
        panelItem.maximumThickness = 760
        panelItem.canCollapse = true
        panelItem.isCollapsed = true
        self.autosaveName = autosaveName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(panelItem)
        if let autosaveName { splitView.autosaveName = autosaveName }
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
}

/// The right panel: tabs from `ShellSurfaces.rightPanelTabs`, segmented control on top.
@MainActor
final class RightPanelViewController: NSTabViewController {
    private let tabs: [RightPanelTab]
    var onTabChange: ((String) -> Void)?

    init(tabs: [RightPanelTab], selectedID: String?) {
        self.tabs = tabs
        super.init(nibName: nil, bundle: nil)
        tabStyle = .segmentedControlOnTop
        for tab in tabs {
            let item = NSTabViewItem(viewController: tab.make())
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
            item.identifier = tab.id
            addTabViewItem(item)
        }
        if let selectedID, let index = tabs.firstIndex(where: { $0.id == selectedID }) { selectedTabViewItemIndex = index }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String { onTabChange?(id) }
    }
}
