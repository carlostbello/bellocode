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
        // Window resizes go to the content, never the side panels (they stay as the user set them; restored by
        // autosave). Above the content column's width preference (255) and below the window's own size (500), so a
        // surface can neither move a divider nor resize the window.
        sidebarItem.holdingPriority = Self.sideHoldingPriority
        contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 420
        panelItem = NSSplitViewItem(inspectorWithViewController: panel)
        panelItem.minimumThickness = 280
        panelItem.maximumThickness = 760
        panelItem.canCollapse = true
        panelItem.holdingPriority = Self.sideHoldingPriority
        panelItem.isCollapsed = true
        self.autosaveName = autosaveName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin
        // The first-launch widths: split items start at their view's frame size, and the side panels hold it.
        sidebarItem.viewController.view.setFrameSize(NSSize(width: Self.defaultSidebarWidth, height: 600))
        panelItem.viewController.view.setFrameSize(NSSize(width: 340, height: 600))
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(panelItem)
        let hasSavedLayout = autosaveName.map { UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \($0)") != nil } ?? false
        if let autosaveName { splitView.autosaveName = autosaveName }
        if !hasSavedLayout { needsDefaultWidths = true }
    }

    private var needsDefaultWidths = false
    static let defaultSidebarWidth: CGFloat = 260
    static let sideHoldingPriority = NSLayoutConstraint.Priority(270)

    override func viewDidAppear() {
        super.viewDidAppear()
        applyDefaultWidthsIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if needsDefaultWidths, view.window?.isVisible == true { applyDefaultWidthsIfNeeded() }
    }

    /// First launch (no autosaved layout): a 260 pt sidebar and a 340 pt panel.
    func applyDefaultWidthsIfNeeded() {
        guard needsDefaultWidths, splitView.bounds.width > 400 else { return }
        needsDefaultWidths = false
        splitView.setPosition(Self.defaultSidebarWidth, ofDividerAt: 0)
        if !panelItem.isCollapsed { splitView.setPosition(splitView.bounds.width - 340, ofDividerAt: 1) }
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

/// The right panel: tabs from `ShellSurfaces.rightPanelTabs` under a segmented control. Tab content is created on
/// first selection. Laid out against the safe area so nothing sits under the unified toolbar.
@MainActor
final class RightPanelViewController: NSViewController {
    private let tabs: [RightPanelTab]
    private let segments = NSSegmentedControl()
    private let host = NSView()
    private var built: [String: NSViewController] = [:]
    private(set) var selectedID: String?
    var onTabChange: ((String) -> Void)?

    init(tabs: [RightPanelTab], selectedID: String?) {
        self.tabs = tabs
        self.selectedID = tabs.contains { $0.id == selectedID } ? selectedID : tabs.first?.id
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = NSView()
        segments.segmentCount = tabs.count
        segments.trackingMode = .selectOne
        segments.controlSize = .small
        segments.segmentStyle = .automatic
        for (index, tab) in tabs.enumerated() {
            segments.setLabel(tab.title, forSegment: index)
            segments.setImage(NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: nil), forSegment: index)
            segments.setImageScaling(.scaleProportionallyDown, forSegment: index)
        }
        segments.target = self
        segments.action = #selector(segmentChanged(_:))
        segments.setAccessibilityLabel("Panel tabs")
        segments.translatesAutoresizingMaskIntoConstraints = false
        host.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(segments)
        container.addSubview(separator)
        container.addSubview(host)
        NSLayoutConstraint.activate([
            segments.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: DS.Spacing.m),
            segments.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            segments.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: DS.Spacing.m),
            separator.topAnchor.constraint(equalTo: segments.bottomAnchor, constant: DS.Spacing.m),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
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

    /// Shows a tab by ID (creating its view controller once).
    func select(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        segments.selectedSegment = index
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
        if selectedID != id {
            selectedID = id
            onTabChange?(id)
        }
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0, sender.selectedSegment < tabs.count else { return }
        select(tabs[sender.selectedSegment].id)
    }
}
