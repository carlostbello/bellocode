import AppKit
import BelloCore
import DesignSystem
import Engine
import os

/// What the sidebar asks of its window: run a command on an explicit target (context menus, keys, the row button),
/// for one or several threads.
@MainActor
protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, perform command: ShellCommand, on target: CommandTarget?, threads: [SessionID])
}

/// Outline row objects. NSOutlineView tracks items by pointer, so one object per identity is reused across updates.
final class SidebarItem: NSObject {
    let id: SidebarNodeID
    var children: [SidebarItem] = []
    init(id: SidebarNodeID) { self.id = id }
}

extension NSPasteboard.PasteboardType {
    /// Internal drags (never leave the app): thread session IDs and project directories.
    static let sidebarThread = NSPasteboard.PasteboardType("com.bellocode.sidebar.thread")
    static let sidebarProject = NSPasteboard.PasteboardType("com.bellocode.sidebar.project")
}

/// The sidebar: a filter field, "Needs you" (from `engine.root.attention`), then projects with their sections
/// (Pinned, Active, Working, Snoozed, Settled), or one list of sections when grouped by state.
///
/// AppKit `NSOutlineView` (source list) for density, keyboard and drag correctness. Structure comes from
/// `SidebarTree.build` and is applied as an identity diff: only rows that change section are removed and inserted
/// (animated when the user moved them from a menu, never for engine updates or after a drop, never under Reduce
/// Motion); row content updates through each cell's own observation. Selection is applied to the workspace at once and
/// the content area shows cached content (never a blank pane). Multi-selection with ⇧/⌘-click and ⇧-arrows; actions
/// apply to every selected thread.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
    NSTextFieldDelegate
{
    let workspace: WorkspaceController
    weak var delegate: (any SidebarDelegate)?

    let outlineView = SidebarOutlineView()
    /// The search field (filters threads by title or project; ⌥⌘F). `filterField` is its editable text field.
    let filterBox = DSTextField(style: .search, placeholder: "Search")
    var filterField: NSTextField { filterBox.field }
    private let optionsButton = DSButton(icon: "line.3.horizontal.decrease", accessibilityTitle: "Sidebar options", size: .small)
    let scrollView = NSScrollView()
    private let emptyState = EmptyStateView(
        symbolName: "folder.badge.plus", title: "No projects",
        detail: "Add a folder to start a thread, or drop one here.", actionTitle: "Add project…",
        action: #selector(MainWindowController.addProject(_:)))
    let toast = UndoToastView()
    let dropBadge = DropBadgeView()
    /// Places the badge beside the insertion point.
    private lazy var dropBadgeCenter = dropBadge.centerYAnchor.constraint(equalTo: scrollView.topAnchor, constant: 40)
    /// The footer (44): "Add project", the connection state and Settings.
    private let addButton = DSButton(title: "Add project", variant: .ghost, size: .small, symbolName: "plus", action: #selector(MainWindowController.addProject(_:)))
    let connectionView = ConnectionStatusView()
    private let settingsButton = DSButton(icon: "gearshape", accessibilityTitle: "Settings", size: .small, action: #selector(AppDelegate.showSettings(_:)))

    private(set) var roots: [SidebarNode] = []
    /// Parent of every node in `roots` (computed once per structure change).
    private var parentMap: [SidebarNodeID: SidebarNodeID?] = [:]
    private var rootItems: [SidebarItem] = []
    private var items: [SidebarNodeID: SidebarItem] = [:]
    private var structureLoop: ObservationLoop?
    private var selectionLoop: ObservationLoop?
    private var isApplyingSelection = false
    private var isApplyingStructure = false
    /// Refreshes relative times on ContinuousClock (run-loop timers may not fire in an idle process, macOS 27).
    private var clock: ContinuousTicker?
    private var renamingID: SessionID?
    private var renameOriginal = ""
    private var draggedThreads: [SessionID] = []
    private var draggedProject: String?
    private var lastDrop: SidebarDrop.Outcome?
    private var restoredScroll = false
    private var scrollSaveTask: Task<Void, Never>?
    private var forcedPreview: (section: SidebarNodeID, index: Int)?
    /// Counts of each section, for header labels.
    private var sectionCounts: [SidebarNodeID: Int] = [:]
    /// Last structure build time (measurements).
    private(set) var lastStructureMilliseconds = 0.0
    /// The part of it spent reading engine state and deriving sections.
    private(set) var lastInputMilliseconds = 0.0
    /// Work counters (tests assert on these, not on timings): full reloads of the outline, row insertions and removals
    /// in the last structure change, and cells configured since launch.
    private(set) var fullReloads = 0
    private(set) var lastRowEdits = 0
    private(set) var cellsConfigured = 0

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        // Plain style, no system selection: `SidebarRowBackground` draws the neutral row recipe (visual-language.md
        // §6), cells indent themselves (children by 22 with a guide line), and disclosure is the cells' own chevrons.
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .none
        outlineView.backgroundColor = .clear
        outlineView.intercellSpacing = .zero
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = DS.Size.sidebarRow
        outlineView.indentationPerLevel = 0
        outlineView.indentationMarkerFollowsCell = false
        outlineView.floatsGroupRows = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        outlineView.registerForDraggedTypes([.fileURL, .sidebarThread, .sidebarProject])
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        // Rows slide aside to show the insertion gap; a plain line under Reduce Motion.
        outlineView.draggingDestinationFeedbackStyle = DS.Motion.reduceMotion ? .regular : .gap
        outlineView.setAccessibilityLabel("Projects and threads")
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        outlineView.onHoverChange = { [weak self] old, new in self?.hoverChanged(from: old, to: new) }
        outlineView.onKey = { [weak self] key in self?.handleKey(key) ?? false }

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: DS.Space.s4, left: 0, bottom: DS.Space.s8, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        DSScroller.install(on: scrollView)

        filterBox.shortcutHint = "⌥⌘F"
        filterBox.showsHalo = false
        filterField.delegate = self
        filterField.setAccessibilityLabel("Filter threads")
        filterBox.toolTip = "Filter threads by title or project (⌥⌘F)"
        filterBox.translatesAutoresizingMaskIntoConstraints = false

        optionsButton.isMuted = true
        optionsButton.target = self
        optionsButton.action = #selector(showOptions(_:))
        optionsButton.toolTip = "Group threads, auto-settle"
        optionsButton.translatesAutoresizingMaskIntoConstraints = false

        addButton.isMuted = true
        addButton.toolTip = "Add Project… (⇧⌘O)"
        settingsButton.toolTip = "Settings (⌘,)"
        let footerDivider = DSDivider()
        for view in [addButton, connectionView, settingsButton, footerDivider] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.undoButton.target = self
        toast.undoButton.action = #selector(undoFromToast(_:))
        dropBadge.translatesAutoresizingMaskIntoConstraints = false

        let container = SidebarDropView()
        container.onDrop = { [weak self] urls in self?.addProjects(urls) ?? false }
        for subview in [filterBox, optionsButton, scrollView, emptyState, footerDivider, addButton, connectionView, settingsButton, toast, dropBadge] {
            container.addSubview(subview)
        }
        let inset = DS.Size.sidebarRowInset
        NSLayoutConstraint.activate([
            // The window's header bar covers the top 52 pt (traffic lights, sidebar and new-thread buttons).
            filterBox.topAnchor.constraint(equalTo: container.topAnchor, constant: DS.Size.header),
            filterBox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            filterBox.trailingAnchor.constraint(equalTo: optionsButton.leadingAnchor, constant: -DS.Space.s4),
            filterBox.heightAnchor.constraint(equalToConstant: DS.Size.control),
            optionsButton.centerYAnchor.constraint(equalTo: filterBox.centerYAnchor),
            optionsButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            scrollView.topAnchor.constraint(equalTo: filterBox.bottomAnchor, constant: DS.Space.s8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerDivider.heightAnchor.constraint(equalToConstant: DS.Border.hairline),
            footerDivider.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -DS.Size.sidebarFooter),
            addButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            addButton.centerYAnchor.constraint(equalTo: container.bottomAnchor, constant: -DS.Size.sidebarFooter / 2),
            settingsButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            settingsButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            connectionView.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -DS.Space.s6),
            connectionView.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            connectionView.leadingAnchor.constraint(greaterThanOrEqualTo: addButton.trailingAnchor, constant: DS.Space.s8),
            emptyState.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: filterBox.bottomAnchor),
            emptyState.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            toast.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            toast.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            toast.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -inset),
            dropBadge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -DS.Space.s12),
            dropBadge.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: DS.Space.s16),
            dropBadgeCenter,
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        structureLoop = ObservationLoop { [weak self] in self?.updateStructure() }
        selectionLoop = ObservationLoop { [weak self] in
            self?.applySelection(self?.workspace.selection)
            self?.updateActiveRows()
        }
        workspace.undo.onToastChange = { [weak self] entry in self?.showToast(entry) }
        clock = ContinuousTicker(every: .seconds(30), tolerance: .seconds(1)) { [weak self] in self?.refreshVisibleRows() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    isolated deinit {
        structureLoop?.cancel()
        selectionLoop?.cancel()
        clock?.stop()
        scrollSaveTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Structure

    /// Section input for a thread from its row (observed: status and session changes re-derive the sections).
    static func sectionInput(_ row: SessionRowModel, organisation: ThreadOrganisation?) -> ThreadSectionInput {
        let session = row.session
        return ThreadSectionInput(
            sessionID: row.id, created: session.created, busySince: session.busySince, idleAt: session.idleAt,
            seenAt: session.viewedAt, status: row.status?.status ?? (session.isRunning ? .running : .idle),
            statusSince: row.status?.since, organisation: organisation ?? .none)
    }

    /// The tree input from engine and workspace state (observed).
    func makeInput(now: Timestamp = .now) -> SidebarTree.Input {
        let root = workspace.engine.root
        let organisation = root.organisation
        let hidden = workspace.hiddenThreads
        var projects = root.projects.map { item -> SidebarTree.Project in
            guard let model = workspace.projectModel(item) else { return SidebarTree.Project(directory: item.directory) }
            let inputs = model.sessionIDs.compactMap { id -> ThreadSectionInput? in
                guard !hidden.contains(id), let row = model.row(id) else { return nil }
                return Self.sectionInput(row, organisation: organisation[id])
            }
            return SidebarTree.Project(directory: item.directory, sections: ThreadSections.derive(inputs, now: now))
        }
        let filter = workspace.filterText.trimmingCharacters(in: .whitespaces)
        var attention = root.attention.items.map(\.sessionID).filter { !hidden.contains($0) }
        // Full-access risk notices to review (docs/features/auto-mode.md): after the blocking items, never counted as
        // approvals; the row says "Review".
        let blocking = Set(attention)
        attention += (workspace.engine.auto?.threadsToReview ?? []).filter { !blocking.contains($0) && !hidden.contains($0) }
        if !filter.isEmpty {
            let names = Dictionary(root.projects.map { ($0.directory, $0.name) }, uniquingKeysWith: { a, _ in a })
            projects = SidebarFilter.apply(
                filter, projects: projects, projectName: { names[$0] ?? "" },
                title: { [workspace] in workspace.session($0)?.displayTitle ?? "" })
            let visible = Set(projects.flatMap { $0.sections.values.flatMap { $0 } })
            attention = attention.filter(visible.contains)
        }
        var input = SidebarTree.Input(attention: attention, projects: projects, grouping: workspace.grouping, isFiltering: !filter.isEmpty)
        (input.lineage, input.nestedUnder) = Self.lineageInput(workspace.engine.orchestration, hidden: hidden)
        return input
    }

    /// Children and fan-out groups to nest (docs/features/orchestration.md). Reads `structureRevision` so the tree
    /// is rebuilt when a link appears or goes, never when a child only changes state.
    static func lineageInput(_ orchestration: OrchestrationService?, hidden: Set<SessionID>) -> ([SessionID: [SessionID]], [SessionID: SessionID]) {
        guard let orchestration else { return ([:], [:]) }
        _ = orchestration.structureRevision
        var lineage: [SessionID: [SessionID]] = [:]
        var nestedUnder: [SessionID: SessionID] = [:]
        for (parent, children) in orchestration.graph.children {
            let visible = children.filter { !hidden.contains($0) && orchestration.graph.sessions[$0]?.isArchived == false }
            if !visible.isEmpty { lineage[parent] = visible }
        }
        let created = orchestration.graph.nodes.values.filter {
            $0.kind == .created && $0.parentID == nil && !hidden.contains($0.id) && orchestration.graph.sessions[$0.id]?.isArchived == false
        }
        for node in created.sorted(by: { $0.created < $1.created }) {
            guard let creator = node.createdBy, orchestration.graph.sessions[creator] != nil, creator != node.id else { continue }
            nestedUnder[node.id] = creator
            lineage[creator, default: []].append(node.id)
        }
        return (lineage, nestedUnder)
    }

    /// Reads engine state (observed) and applies the new tree as an identity diff.
    private func updateStructure() {
        let signpost = ShellSignposts.sidebar.beginInterval("sidebarStructure")
        defer { ShellSignposts.sidebar.endInterval("sidebarStructure", signpost) }
        let start = ContinuousClock.now
        let root = workspace.engine.root
        let input = makeInput()
        let built = ContinuousClock.now
        var newRoots = SidebarTree.build(input)
        if let forcedPreview { newRoots = Self.insertingGap(into: newRoots, section: forcedPreview.section, at: forcedPreview.index) }
        emptyState.isHidden = !root.projects.isEmpty
        scrollView.isHidden = root.projects.isEmpty && root.attention.items.isEmpty
        filterBox.isHidden = root.projects.isEmpty
        optionsButton.isHidden = root.projects.isEmpty
        if newRoots != roots { apply(newRoots) }
        lastInputMilliseconds = PaletteController.milliseconds(since: start) - PaletteController.milliseconds(since: built)
        lastStructureMilliseconds = PaletteController.milliseconds(since: start)
    }

    private func apply(_ newRoots: [SidebarNode]) {
        isApplyingStructure = true
        defer { isApplyingStructure = false }
        let animate = workspace.animatesNextStructureChange && !DS.Motion.reduceMotion && !roots.isEmpty
        workspace.animatesNextStructureChange = false
        let firstLoad = roots.isEmpty
        let update = SidebarTree.update(from: roots, to: newRoots)
        roots = newRoots
        parentMap = SidebarTree.parents(newRoots)
        let previousItems = items
        items = [:]
        rootItems = newRoots.map { materialize($0, reuse: previousItems) }
        sectionCounts = [:]
        countSections(newRoots)
        lastRowEdits = firstLoad ? 0 : update.removals.count + update.insertions.count
        if firstLoad {
            fullReloads += 1
            outlineView.reloadData()
            expandDefaults(rootItems)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animate ? 0.18 : 0
                context.allowsImplicitAnimation = false
                outlineView.beginUpdates()
                for removal in update.removals {
                    outlineView.removeItems(
                        at: IndexSet(integer: removal.index), inParent: removal.parent.flatMap { previousItems[$0] },
                        withAnimation: animate ? .slideUp : [])
                }
                for insertion in update.insertions {
                    outlineView.insertItems(
                        at: IndexSet(integer: insertion.index), inParent: insertion.parent.flatMap { items[$0] },
                        withAnimation: animate ? .slideDown : [])
                }
                outlineView.endUpdates()
            }
            expandDefaults(update.inserted.compactMap { items[$0] })
        }
        refreshHeaders()
        applySelection(workspace.selection)
        if !restoredScroll, !newRoots.isEmpty { restoreScroll() }
    }

    /// Builds (or reuses) items for a subtree.
    private func materialize(_ node: SidebarNode, reuse: [SidebarNodeID: SidebarItem]) -> SidebarItem {
        let item = reuse[node.id] ?? SidebarItem(id: node.id)
        items[node.id] = item
        item.children = node.children.map { materialize($0, reuse: reuse) }
        return item
    }

    private func countSections(_ nodes: [SidebarNode]) {
        for node in nodes {
            if node.id.section != nil || node.id == .needsYouHeader {
                sectionCounts[node.id] = node.children.count { $0.id != .dropGap }
            }
            countSections(node.children)
        }
    }

    /// Expands groups, projects and sections unless the user collapsed them (everything while filtering).
    /// Expands a thread row that has nested children or fan-out threads (snapshots; the person uses the disclosure).
    func expandThread(_ id: SessionID) {
        guard let item = items[.thread(id)] else { return }
        outlineView.expandItem(item)
    }

    private func expandDefaults(_ items: [SidebarItem]) {
        let filtering = !workspace.filterText.isEmpty
        let state = workspace.state
        for item in items {
            switch item.id {
            case .needsYouHeader:
                if filtering || !state.isNeedsYouCollapsed { outlineView.expandItem(item) }
            case .projectsHeader:
                outlineView.expandItem(item)
                expandDefaults(item.children)
            case .project(let directory):
                if filtering || !state.collapsedProjects.contains(directory) {
                    outlineView.expandItem(item)
                    expandDefaults(item.children)
                }
            case .section(let scope, let section):
                if filtering || state.isSectionExpanded(scope: scope, section) { outlineView.expandItem(item) }
            default:
                break
            }
        }
    }

    private func refreshHeaders() {
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let item = outlineView.item(atRow: row) as? SidebarItem else { return }
            if let cell = rowView.view(atColumn: 0) as? SidebarSectionCell {
                cell.configure(item.id, count: sectionCounts[item.id] ?? 0, expanded: outlineView.isItemExpanded(item))
            }
            if let cell = rowView.view(atColumn: 0) as? SidebarTextCell, item.id == .needsYouHeader {
                cell.badge.count = sectionCounts[item.id] ?? 0
            }
        }
    }

    // MARK: - Selection

    private func applySelection(_ selection: ShellSelection?) {
        // Keep a multi-selection (or a "Needs you" row) that already includes the displayed thread.
        let selectedIDs = outlineView.selectedRowIndexes.compactMap { (outlineView.item(atRow: $0) as? SidebarItem)?.id }
        if let selection, selectedIDs.contains(where: { Self.selection(for: $0) == selection }) { return }
        guard let target = node(for: selection), let item = items[target] else {
            if selection == nil, outlineView.selectedRow >= 0 { setSelectedRow(-1) }
            return
        }
        var parentID = parentMap[target] ?? nil
        var chain: [SidebarItem] = []
        while let id = parentID, let parent = items[id] {
            chain.insert(parent, at: 0)
            parentID = parentMap[id] ?? nil
        }
        // Reveal the row (a collapsed section or project opens; Settled stays collapsed only if nothing in it is shown).
        for parent in chain where !outlineView.isItemExpanded(parent) { outlineView.expandItem(parent) }
        let row = outlineView.row(forItem: item)
        guard row >= 0, row != outlineView.selectedRow || outlineView.numberOfSelectedRows > 1 else { return }
        setSelectedRow(row)
        outlineView.scrollRowToVisible(row)
    }

    /// The row for a selection (by identity; see `SidebarTree.node(for:in:)`).
    private func node(for selection: ShellSelection?) -> SidebarNodeID? {
        switch selection {
        case .thread(let id): items[.thread(id)] != nil ? .thread(id) : (items[.attention(id)] != nil ? .attention(id) : nil)
        case .draft(let directory): items[.project(directory)] != nil ? .project(directory) : nil
        case nil: nil
        }
    }

    private func setSelectedRow(_ row: Int) {
        isApplyingSelection = true
        defer { isApplyingSelection = false }
        if row < 0 {
            outlineView.deselectAll(nil)
        } else {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateSelectedProjectAccessory()
    }

    static func selection(for node: SidebarNodeID) -> ShellSelection? {
        switch node {
        case .attention(let id), .thread(let id): .thread(id)
        case .project(let directory), .emptyProject(let directory): .draft(directory: directory)
        case .needsYouHeader, .projectsHeader, .section, .noResults, .dropGap: nil
        }
    }

    /// The command target for a row.
    func target(for node: SidebarNodeID) -> CommandTarget? {
        switch node {
        case .attention(let id), .thread(let id):
            return workspace.target(for: .thread(id))
        case .project(let directory), .emptyProject(let directory):
            return .project(directory: directory, isPinned: workspace.projectItem(directory: directory)?.isPinned ?? false)
        case .needsYouHeader, .projectsHeader, .section, .noResults, .dropGap:
            return nil
        }
    }

    var selectedNode: SidebarNodeID? {
        outlineView.selectedRow >= 0 ? (outlineView.item(atRow: outlineView.selectedRow) as? SidebarItem)?.id : nil
    }

    /// The selected threads, top to bottom, each once (a thread can be selected in "Needs you" and its section).
    var selectedThreadIDs: [SessionID] {
        var seen = Set<SessionID>()
        return outlineView.selectedRowIndexes.compactMap { (outlineView.item(atRow: $0) as? SidebarItem)?.id.sessionID }
            .filter { seen.insert($0).inserted }
    }

    /// Selects rows for threads (tests and snapshots; the user does this with ⇧/⌘-click).
    func selectThreads(_ ids: [SessionID]) {
        let rows = IndexSet(ids.compactMap { id in items[.thread(id)].map { outlineView.row(forItem: $0) } }.filter { $0 >= 0 })
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarItem)?.children.count ?? rootItems.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarItem)?.children[index] ?? rootItems[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarItem)?.children.isEmpty ?? true)
    }

    // MARK: Drag source

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let item = item as? SidebarItem, workspace.filterText.isEmpty else { return nil }
        switch item.id {
        case .thread(let id):
            // Nested rows (children, fan-out threads) follow their parent; they are not dragged on their own.
            if case .thread = parentMap[item.id] ?? nil { return nil }
            let writer = NSPasteboardItem()
            writer.setString(id.rawValue, forType: .sidebarThread)
            writer.setString(workspace.session(id)?.displayTitle ?? "", forType: .string)
            return writer
        case .project(let directory):
            let writer = NSPasteboardItem()
            writer.setString(directory, forType: .sidebarProject)
            return writer
        default:
            return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        let ids = draggedItems.compactMap { ($0 as? SidebarItem)?.id }
        draggedThreads = ids.compactMap { if case .thread(let id) = $0 { id } else { nil } }
        draggedProject = ids.lazy.compactMap { if case .project(let directory) = $0 { directory } else { nil } }.first
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedThreads = []
        draggedProject = nil
        lastDrop = nil
        dropBadge.hide()
    }

    // MARK: Drop

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        if pasteboard.types?.contains(.sidebarThread) == true, !draggedThreads.isEmpty {
            guard let (section, index) = threadDropTarget(proposedItem: item as? SidebarItem, index: index) else {
                showBadge(.forbidden(item == nil ? "Drop onto a section" : "Drop into a section of the thread’s project"))
                return []
            }
            outlineView.setDropItem(section, dropChildIndex: index)
            let outcome = resolveDrop(section: section.id, index: index)
            showBadge(outcome, near: insertionRow(section: section, index: index))
            return outcome.isAllowed ? .move : []
        }
        if pasteboard.types?.contains(.sidebarProject) == true, let dragged = draggedProject {
            guard let header = items[.projectsHeader], (item as? SidebarItem) === header, index != NSOutlineViewDropOnItemIndex else {
                return []
            }
            let pinned = workspace.projectItem(directory: dragged)?.isPinned ?? false
            let projects = workspace.engine.root.projects
            let boundary = projects.filter(\.isPinned).count
            if pinned ? index > boundary : index < boundary {
                showBadge(.forbidden(pinned ? "Pinned projects stay at the top" : "Unpin a project to move it below"))
                return []
            }
            dropBadge.hide()
            return .move
        }
        guard !Self.directories(in: pasteboard).isEmpty else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        defer { dropBadge.hide() }
        if !draggedThreads.isEmpty, let section = item as? SidebarItem, section.id.section != nil {
            return performDrop(section: section.id, index: index == NSOutlineViewDropOnItemIndex ? 0 : index)
        }
        if let dragged = draggedProject {
            let projects = workspace.engine.root.projects.map(\.directory)
            guard let from = projects.firstIndex(of: dragged) else { return false }
            let target = index > from ? index - 1 : index
            guard target != from else { return true }
            let engine = workspace.engine
            let name = workspace.projectItem(directory: dragged)?.name ?? "project"
            workspace.undo.perform(
                ReversibleAction(
                    name: "Move Project", message: "Moved \(name)",
                    apply: { Task { await engine.moveProject(directory: dragged, to: target) } },
                    revert: { Task { await engine.moveProject(directory: dragged, to: from) } }))
            return true
        }
        return addProjects(Self.directories(in: info.draggingPasteboard))
    }

    /// Maps a proposed drop to a section item and an index in it.
    private func threadDropTarget(proposedItem item: SidebarItem?, index: Int) -> (SidebarItem, Int)? {
        guard let item else { return nil }
        switch item.id {
        case .section:
            return (item, index == NSOutlineViewDropOnItemIndex ? 0 : index)
        case .thread:
            guard let parentID = parentMap[item.id] ?? nil, let parent = items[parentID],
                  let position = parent.children.firstIndex(where: { $0 === item })
            else { return nil }
            return (parent, position)
        case .project(let directory), .emptyProject(let directory):
            // Onto a project: its Active section (top).
            guard let active = items[.section(scope: directory, .active)] else { return nil }
            return (active, 0)
        default:
            return nil
        }
    }

    /// The outcome of dropping the dragged threads into `section` before `index`.
    func resolveDrop(section: SidebarNodeID, index: Int, threads: [SessionID]? = nil, now: Timestamp = .now) -> SidebarDrop.Outcome {
        guard case .section(let scope, let target) = section else { return .forbidden("Drop onto a section") }
        let threads = threads ?? draggedThreads
        let rows = items[section]?.children.compactMap(\.id.sessionID) ?? []
        var projectOf: [SessionID: String] = [:]
        var organisation: [SessionID: ThreadOrganisation] = [:]
        var keys: [SessionID: Double] = [:]
        for id in Set(threads + rows) {
            if let session = workspace.session(id) {
                projectOf[id] = workspace.projectItem(for: session)?.directory ?? session.directory
                let org = workspace.engine.organisation(of: id)
                organisation[id] = org
                keys[id] = org.sortKey ?? session.created.milliseconds
            }
        }
        let proposal = SidebarDrop.Proposal(
            threads: threads, projectOf: projectOf, organisation: organisation, targetProject: scope, targetSection: target,
            index: index, sectionRows: rows, sortKeys: keys, now: now)
        return SidebarDrop.resolve(proposal, snoozeUntil: Timestamp(SnoozePreset.tomorrow.date(from: now.date)))
    }

    /// Applies a drop (no animation: the outline view's gap already showed the result).
    @discardableResult
    func performDrop(section: SidebarNodeID, index: Int, threads: [SessionID]? = nil) -> Bool {
        let threads = threads ?? draggedThreads
        let outcome = resolveDrop(section: section, index: index, threads: threads)
        guard case .move(let changes, let badge) = outcome else { return false }
        guard !changes.isEmpty else { return true }
        let previous = Dictionary(uniqueKeysWithValues: changes.keys.map { ($0, workspace.engine.organisation(of: $0)) })
        let verb: String = switch badge {
        case "Pin": "Pinned"
        case "Unpin": "Unpinned"
        case "Settle": "Settled"
        case "Un-settle": "Un-settled"
        case "Wake": "Woke"
        default: badge.hasPrefix("Snooze") ? "Snoozed" : "Moved"
        }
        workspace.apply(
            next: changes, previous: previous, name: badge.hasPrefix("Snooze") ? "Snooze" : badge,
            message: "\(verb) \(workspace.describe(threads))", animated: false)
        return true
    }

    private func showBadge(_ outcome: SidebarDrop.Outcome, near row: Int? = nil, centred: Bool = false) {
        if let row, row >= 0 {
            let rect = outlineView.rect(ofRow: row)
            let point = scrollView.convert(NSPoint(x: 0, y: centred ? rect.midY : rect.minY), from: outlineView)
            // Above the insertion line, inside the visible list.
            let y = min(max(point.y, 14), scrollView.bounds.height - 14)
            dropBadgeCenter.constant = scrollView.isFlipped ? y : scrollView.bounds.height - y
        }
        guard outcome != lastDrop else { return }
        lastDrop = outcome
        dropBadge.show(outcome.badge, allowed: outcome.isAllowed)
    }

    /// The outline row where a drop into `section` before `index` would land.
    private func insertionRow(section: SidebarItem, index: Int) -> Int {
        if index < section.children.count { return outlineView.row(forItem: section.children[index]) }
        if let last = section.children.last { return outlineView.row(forItem: last) + 1 }
        return outlineView.row(forItem: section) + 1
    }

    /// Shows the insertion gap and badge for a drop without a real drag (snapshots; a real drag uses the outline view's
    /// own gap). Pass nil to clear.
    func showDropPreview(threads: [SessionID], section: SidebarNodeID?, index: Int = 0) {
        if let section {
            forcedPreview = (section, index)
            draggedThreads = threads
            updateStructure()
            let row = items[.dropGap].map(outlineView.row(forItem:)) ?? items[section].map { outlineView.row(forItem: $0) + 1 } ?? -1
            if row >= 0 { outlineView.scrollRowToVisible(row) }
            view.layoutSubtreeIfNeeded()
            showBadge(resolveDrop(section: section, index: index, threads: threads), near: row >= 0 ? row : nil, centred: true)
        } else {
            forcedPreview = nil
            draggedThreads = []
            lastDrop = nil
            dropBadge.hide()
            updateStructure()
        }
    }

    private static func insertingGap(into nodes: [SidebarNode], section: SidebarNodeID, at index: Int) -> [SidebarNode] {
        nodes.map { node in
            var copy = node
            if node.id == section {
                copy.children.insert(SidebarNode(id: .dropGap), at: max(0, min(index, node.children.count)))
            } else {
                copy.children = insertingGap(into: node.children, section: section, at: index)
            }
            return copy
        }
    }

    static func directories(in pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    @discardableResult
    private func addProjects(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        workspace.addProjects(urls)
        return true
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarItem)?.id.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let id = (item as? SidebarItem)?.id else { return false }
        return Self.selection(for: id) != nil
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let id = (item as? SidebarItem)?.id else { return DS.Size.sidebarRow }
        switch id {
        case .needsYouHeader: return DS.Size.sidebarRow
        // The gap between "Needs you" and the projects (there is no "Projects" label, as in the mock).
        case .projectsHeader: return DS.Space.s8
        case .attention: return DS.Size.sidebarRowTwoLine
        case .project: return DS.Size.sidebarProjectRow
        case .section(nil, _): return DS.Size.sidebarRow
        case .section: return DS.Size.sidebarGroupLabel
        default: return DS.Size.sidebarRow
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = outlineView.makeView(withIdentifier: SidebarRowBackground.identifier, owner: nil) as? SidebarRowBackground ?? {
            let row = SidebarRowBackground()
            row.identifier = SidebarRowBackground.identifier
            return row
        }()
        let id = (item as? SidebarItem)?.id
        row.tracksHover = id.map { Self.selection(for: $0) != nil } ?? false
        row.updateTrackingAreas()
        row.isActive = id != nil && id == node(for: workspace.selection)
        return row
    }

    /// Marks the row of the displayed thread (or draft) as the active one (`rowActive`), others plain or selected.
    func updateActiveRows() {
        let active = node(for: workspace.selection)
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? SidebarRowBackground else { return }
            rowView.isActive = active != nil && (outlineView.item(atRow: row) as? SidebarItem)?.id == active
        }
    }

    /// Nesting depth of a thread row below its top-level thread (child threads indent with a guide line).
    private func threadDepth(_ id: SidebarNodeID) -> Int {
        var depth = 0
        var parent = parentMap[id] ?? nil
        while let current = parent, case .thread = current {
            depth += 1
            parent = parentMap[current] ?? nil
        }
        return depth
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        cellsConfigured += 1
        switch item.id {
        case .needsYouHeader, .projectsHeader:
            let cell = outlineView.makeView(withIdentifier: SidebarTextCell.headerIdentifier, owner: nil) as? SidebarTextCell
                ?? SidebarTextCell(identifier: SidebarTextCell.headerIdentifier)
            let isNeedsYou = item.id == .needsYouHeader
            cell.label.stringValue = isNeedsYou ? "Needs you" : ""
            cell.needsLayout = true
            cell.label.isHidden = !isNeedsYou
            cell.badge.count = isNeedsYou ? item.children.count : 0
            cell.setAccessibilityElement(isNeedsYou)
            return cell
        case .section:
            let cell = outlineView.makeView(withIdentifier: SidebarSectionCell.identifier, owner: nil) as? SidebarSectionCell
                ?? SidebarSectionCell()
            cell.configure(item.id, count: item.children.count { $0.id != .dropGap }, expanded: outlineView.isItemExpanded(item))
            return cell
        case .emptyProject, .noResults:
            let cell = outlineView.makeView(withIdentifier: SidebarTextCell.placeholderIdentifier, owner: nil) as? SidebarTextCell
                ?? SidebarTextCell(identifier: SidebarTextCell.placeholderIdentifier)
            cell.label.stringValue = item.id == .noResults ? "No threads match “\(workspace.filterText)”" : "No threads yet"
            cell.labelX = item.id == .noResults ? SidebarMetrics.glyphX : SidebarMetrics.titleX
            cell.needsLayout = true
            return cell
        case .dropGap:
            let cell = outlineView.makeView(withIdentifier: DropGapCell.identifier, owner: nil) as? DropGapCell ?? DropGapCell()
            return cell
        case .project(let directory):
            let cell = outlineView.makeView(withIdentifier: ProjectCell.identifier, owner: nil) as? ProjectCell ?? {
                let cell = ProjectCell(frame: .zero)
                cell.identifier = ProjectCell.identifier
                cell.accessoryButton.target = self
                cell.accessoryButton.action = #selector(newThreadFromRowButton(_:))
                cell.disclosure.target = self
                cell.disclosure.action = #selector(disclosureClicked(_:))
                return cell
            }()
            cell.bind(directory, workspace: workspace)
            cell.isCollapsed = !outlineView.isItemExpanded(item)
            cell.isSelectedRow = outlineView.row(forItem: item) == outlineView.selectedRow && outlineView.selectedRow >= 0
            return cell
        case .thread(let id), .attention(let id):
            let isAttention = { if case .attention = item.id { true } else { false } }()
            let showsProject = isAttention || workspace.grouping == .byState
            let identifier = isAttention ? ThreadCell.attentionIdentifier : ThreadCell.identifier
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? ThreadCell ?? {
                let cell = ThreadCell(frame: .zero)
                cell.identifier = identifier
                cell.title.delegate = self
                cell.disclosure.target = self
                cell.disclosure.action = #selector(disclosureClicked(_:))
                return cell
            }()
            cell.depth = isAttention ? 0 : threadDepth(item.id)
            cell.recedes = { if case .section(_, .settled) = parentMap[item.id] ?? nil { true } else { false } }()
            cell.hasChildren = !item.children.isEmpty
            cell.isExpanded = outlineView.isItemExpanded(item)
            cell.bind(id, workspace: workspace, showsProject: showsProject, twoLine: isAttention)
            return cell
        }
    }

    /// A click on a group or section label toggles it (they are not selectable).
    @objc private func rowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        switch item.id {
        case .needsYouHeader, .section:
            if outlineView.isItemExpanded(item) { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
        default:
            break
        }
    }

    /// The chevron of a project or of a thread with nested children.
    @objc private func disclosureClicked(_ sender: NSView) {
        let row = outlineView.row(for: sender)
        guard row >= 0, let item = outlineView.item(atRow: row) else { return }
        if outlineView.isItemExpanded(item) { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateSelectedProjectAccessory()
        defer { updateActiveRows() }
        guard !isApplyingSelection, !isApplyingStructure, let node = selectedNode, let selection = Self.selection(for: node) else { return }
        let signpost = ShellSignposts.sidebar.beginInterval("selectThread")
        workspace.select(selection)
        ShellSignposts.sidebar.endInterval("selectThread", signpost)
    }

    func outlineViewItemDidExpand(_ notification: Notification) { expansionChanged(notification, collapsed: false) }
    func outlineViewItemDidCollapse(_ notification: Notification) { expansionChanged(notification, collapsed: true) }

    private func expansionChanged(_ notification: Notification, collapsed: Bool) {
        guard let item = notification.userInfo?["NSObject"] as? SidebarItem else { return }
        let row = outlineView.row(forItem: item)
        if row >= 0 {
            switch outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) {
            case let cell as ProjectCell: cell.isCollapsed = collapsed
            case let cell as ThreadCell: cell.isExpanded = !collapsed
            case let cell as SidebarSectionCell: cell.isExpanded = !collapsed
            default: break
            }
        }
        guard !isApplyingStructure, workspace.filterText.isEmpty else { return }
        switch item.id {
        case .project(let directory): workspace.setCollapsed(directory, collapsed)
        case .needsYouHeader: workspace.setNeedsYouCollapsed(collapsed)
        case .section(let scope, let section): workspace.mutateState { $0.setSectionExpanded(scope: scope, section, !collapsed) }
        default: break
        }
    }

    /// Expands or collapses a section (keyboard, tests).
    func setSection(_ id: SidebarNodeID, expanded: Bool) {
        guard let item = items[id] else { return }
        if expanded { outlineView.expandItem(item) } else { outlineView.collapseItem(item) }
    }

    func isExpanded(_ id: SidebarNodeID) -> Bool { items[id].map(outlineView.isItemExpanded) ?? false }

    /// The row of a node (tests, snapshots).
    func row(of id: SidebarNodeID) -> Int { items[id].map(outlineView.row(forItem:)) ?? -1 }

    // MARK: - Filter

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === filterField else { return }
        guard workspace.filterText != filterField.stringValue else { return }
        workspace.filterText = filterField.stringValue
    }

    /// Focuses the filter field (⌥⌘F).
    func focusFilter() {
        view.window?.makeFirstResponder(filterField)
        filterField.currentEditor()?.selectAll(nil)
    }

    func setFilter(_ text: String) {
        filterField.stringValue = text
        workspace.filterText = text
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === filterField {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                setFilter("")
                view.window?.makeFirstResponder(outlineView)
                return true
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
                view.window?.makeFirstResponder(outlineView)
                if let first = (0..<outlineView.numberOfRows).first(where: { row in
                    (outlineView.item(atRow: row) as? SidebarItem).map { Self.selection(for: $0.id) != nil } ?? false
                }) {
                    outlineView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
                }
                return true
            default:
                return false
            }
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            (control as? NSTextField)?.stringValue = renameOriginal
            renamingID = nil
            view.window?.makeFirstResponder(outlineView)
            return true
        }
        return false
    }

    @objc private func showOptions(_ sender: NSView) {
        makeOptionsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func makeOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        for command in [ShellCommand.groupByProject, .showThreadsByState] {
            let item = NSMenuItem(title: command.title, action: command.selector, keyEquivalent: "")
            item.state = (command == .groupByProject) == (workspace.grouping == .byProject) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Auto-Settle Settings…", action: #selector(openThreadSettings(_:)), keyEquivalent: ""))
        menu.items.last?.target = self
        return menu
    }

    @objc private func openThreadSettings(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openSettings(pane: "threads")
    }

    // MARK: - Hover, keys, row button

    private func hoverChanged(from old: Int, to new: Int) {
        for (row, hovered) in [(old, false), (new, true)] where row >= 0 && row < outlineView.numberOfRows {
            (outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ProjectCell)?.isHovered = hovered
        }
    }

    private func updateSelectedProjectAccessory() {
        outlineView.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? ProjectCell)?.isSelectedRow = row == outlineView.selectedRow
        }
    }

    @objc private func newThreadFromRowButton(_ sender: NSView) {
        let row = outlineView.row(for: sender)
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem, case .project(let directory) = item.id else { return }
        delegate?.sidebar(self, perform: .newThread, on: .project(directory: directory, isPinned: false), threads: [])
    }

    /// Return renames a thread (as in Finder) or toggles a project or section; Delete archives the selected threads or
    /// removes a project (all undoable).
    private func handleKey(_ key: SidebarOutlineView.Key) -> Bool {
        guard let node = selectedNode else { return false }
        let threads = selectedThreadIDs
        switch (key, node) {
        case (.returnKey, .thread(let id)), (.returnKey, .attention(let id)):
            guard threads.count <= 1 else { return false }
            beginRename(id)
            return true
        case (.returnKey, .project), (.returnKey, .emptyProject):
            guard let item = items[node] else { return false }
            if outlineView.isItemExpanded(item) { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
            return true
        case (.delete, .thread), (.delete, .attention):
            delegate?.sidebar(self, perform: .archiveThread, on: target(for: node), threads: threads)
            return true
        case (.delete, .project):
            delegate?.sidebar(self, perform: .removeProject, on: target(for: node), threads: [])
            return true
        default:
            return false
        }
    }

    // MARK: - Inline rename

    /// Starts editing a thread's title in place (Return commits, Escape cancels).
    func beginRename(_ id: SessionID) {
        let node: SidebarNodeID = items[.thread(id)] != nil ? .thread(id) : .attention(id)
        guard let item = items[node] else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ThreadCell else { return }
        renamingID = id
        renameOriginal = cell.title.stringValue
        cell.title.isEditable = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.editColumn(0, row: row, with: nil, select: true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field !== filterField else { return }
        field.isEditable = false
        guard let id = renamingID else { return }
        renamingID = nil
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == renameOriginal {
            field.stringValue = renameOriginal
        } else {
            workspace.rename(id, to: title)
        }
        view.window?.makeFirstResponder(outlineView)
    }

    // MARK: - Context menu

    /// The threads a context menu acts on: the selection when the clicked row is part of it, else the clicked row.
    private func contextThreads(clickedRow row: Int, node: SidebarNodeID) -> [SessionID] {
        guard let id = node.sessionID else { return [] }
        if outlineView.selectedRowIndexes.contains(row), outlineView.numberOfSelectedRows > 1 { return selectedThreadIDs }
        return [id]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let node = (outlineView.item(atRow: row) as? SidebarItem)?.id else { return }
        if case .section(let scope, let section) = node {
            sectionMenu(menu, scope: scope, section: section)
            return
        }
        guard let target = target(for: node) else { return }
        let threads = contextThreads(clickedRow: row, node: node)
        let commands: [ShellCommand?] = switch node {
        case .thread, .attention:
            [
                .newThread, nil, .togglePinThread, .settleThread, nil, .renameThread, .markUnread, .toggleNeverAutoSettle,
                nil, .archiveThread, .deleteThread, nil, .revealInFinder, .copyPath,
            ]
        case .project, .emptyProject:
            [.newThread, nil, .togglePinProject, .moveProjectUp, .moveProjectDown, .removeProject, nil, .revealInFinder, .copyPath]
        default:
            []
        }
        let context = menuContext(target: target, threads: threads)
        for command in commands {
            guard let command else {
                menu.addItem(.separator())
                continue
            }
            menu.addItem(contextItem(command, context: context, node: node, threads: threads))
            if command == .settleThread {
                let snooze = NSMenu(title: "Snooze")
                for preset in [ShellCommand.snoozeLaterToday, .snoozeTomorrow, .snoozeNextWeek, .snoozeUntil] {
                    let item = contextItem(preset, context: context, node: node, threads: threads)
                    item.title = preset == .snoozeUntil ? "Custom…" : SnoozePreset.title(for: preset)
                    snooze.addItem(item)
                }
                if context.targetsSnoozed {
                    snooze.addItem(.separator())
                    snooze.addItem(contextItem(.wakeThread, context: context, node: node, threads: threads))
                }
                let parent = NSMenuItem(title: threads.count > 1 ? "Snooze \(threads.count) Threads" : "Snooze", action: nil, keyEquivalent: "")
                parent.submenu = snooze
                menu.addItem(parent)
            }
        }
    }

    private func sectionMenu(_ menu: NSMenu, scope: String?, section: ThreadSection) {
        guard let item = items[.section(scope: scope, section)] else { return }
        let ids = item.children.compactMap(\.id.sessionID)
        let expanded = outlineView.isItemExpanded(item)
        let toggle = NSMenuItem(title: expanded ? "Collapse \(section.title)" : "Expand \(section.title)", action: #selector(toggleSectionFromMenu(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.representedObject = item
        menu.addItem(toggle)
        if section == .active || section == .working, !ids.isEmpty {
            let settleAll = NSMenuItem(title: "Settle All \(section.title) (\(ids.count))", action: #selector(contextCommand(_:)), keyEquivalent: "")
            settleAll.target = self
            settleAll.representedObject = ContextCommand(command: .settleThread, node: .section(scope: scope, section), threads: ids)
            menu.addItem(settleAll)
        }
        if section == .snoozed, !ids.isEmpty {
            let wakeAll = NSMenuItem(title: "Wake All (\(ids.count))", action: #selector(contextCommand(_:)), keyEquivalent: "")
            wakeAll.target = self
            wakeAll.representedObject = ContextCommand(command: .wakeThread, node: .section(scope: scope, section), threads: ids)
            menu.addItem(wakeAll)
        }
    }

    @objc private func toggleSectionFromMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem else { return }
        if outlineView.isItemExpanded(item) { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
    }

    private func menuContext(target: CommandTarget, threads: [SessionID]) -> CommandContext {
        let pinned = workspace.projectDirectory(for: target).flatMap { workspace.projectItem(directory: $0)?.isPinned } ?? false
        var context = CommandContext(hasProjects: true, target: target, targetProjectPinned: pinned)
        context.selectedThreadCount = threads.count
        let organisations = threads.map { workspace.engine.organisation(of: $0) }
        context.targetsPinned = !organisations.isEmpty && organisations.allSatisfy(\.pinned)
        context.targetsSettled = !organisations.isEmpty && organisations.allSatisfy(\.settled)
        context.targetsSnoozed = organisations.contains(where: \.isSnoozed)
        context.targetsNeverAutoSettle = !organisations.isEmpty && organisations.allSatisfy(\.neverAutoSettle)
        if case .project(let directory, _) = target {
            let projects = workspace.engine.root.projects
            if let index = projects.firstIndex(where: { $0.directory == directory }) {
                context.projectCanMoveUp = index > 0 && projects[index - 1].isPinned == projects[index].isPinned
                context.projectCanMoveDown = index + 1 < projects.count && projects[index + 1].isPinned == projects[index].isPinned
            }
        }
        return context
    }

    private func contextItem(_ command: ShellCommand, context: CommandContext, node: SidebarNodeID, threads: [SessionID]) -> NSMenuItem {
        let item = NSMenuItem(title: context.title(for: command), action: #selector(contextCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ContextCommand(command: command, node: node, threads: threads)
        item.isEnabled = context.isEnabled(command)
        if let checked = command.isChecked(in: context) { item.state = checked ? .on : .off }
        return item
    }

    private final class ContextCommand: NSObject {
        let command: ShellCommand
        let node: SidebarNodeID
        let threads: [SessionID]
        init(command: ShellCommand, node: SidebarNodeID, threads: [SessionID]) {
            self.command = command
            self.node = node
            self.threads = threads
        }
    }

    @objc private func contextCommand(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? ContextCommand else { return }
        if context.command == .renameThread, let id = context.node.sessionID {
            beginRename(id)
            return
        }
        delegate?.sidebar(self, perform: context.command, on: target(for: context.node), threads: context.threads)
    }

    // MARK: - Toast, clock, scroll restoration

    private func showToast(_ entry: ToastQueue.Entry?) {
        guard let entry else {
            toast.hide()
            return
        }
        toast.undoButton.isHidden = entry.token == nil
        toast.show(entry.message)
    }

    @objc private func undoFromToast(_ sender: Any?) { workspace.undo.undoFromToast() }

    private func refreshVisibleRows() {
        outlineView.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? ThreadCell)?.render()
        }
    }

    @objc private func scrolled(_ notification: Notification) {
        guard restoredScroll else { return }
        scrollSaveTask?.cancel()
        scrollSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            let (key, offset) = self.topRow()
            self.workspace.mutateState {
                $0.sidebarTopRow = key
                $0.sidebarTopOffset = offset
            }
        }
    }

    /// The row at the top of the viewport and how far it is scrolled past.
    func topRow() -> (String?, Double) {
        let visible = scrollView.contentView.bounds
        let row = outlineView.row(at: NSPoint(x: 1, y: visible.minY + 1))
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return (nil, 0) }
        return (item.id.restorationKey, Double(visible.minY - outlineView.rect(ofRow: row).minY))
    }

    private func restoreScroll() {
        restoredScroll = true
        guard let key = workspace.state.sidebarTopRow,
              let item = items.values.first(where: { $0.id.restorationKey == key })
        else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.layoutSubtreeIfNeeded()
        let y = outlineView.rect(ofRow: row).minY + CGFloat(workspace.state.sidebarTopOffset)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Focus the list (region cycling).
    func focus() { view.window?.makeFirstResponder(outlineView) }
}

extension SnoozePreset {
    /// The menu title of a snooze command's preset.
    static func title(for command: ShellCommand) -> String {
        switch command {
        case .snoozeLaterToday: SnoozePreset.laterToday.title
        case .snoozeTomorrow: SnoozePreset.tomorrow.title
        case .snoozeNextWeek: SnoozePreset.nextWeek.title
        default: command.title
        }
    }

    init?(command: ShellCommand) {
        switch command {
        case .snoozeLaterToday: self = .laterToday
        case .snoozeTomorrow: self = .tomorrow
        case .snoozeNextWeek: self = .nextWeek
        default: return nil
        }
    }
}

/// The outline view: reports hover (for the project row's New Thread button) and Return/Delete.
@MainActor
final class SidebarOutlineView: NSOutlineView {
    enum Key { case returnKey, delete }
    var onHoverChange: ((Int, Int) -> Void)?
    var onKey: ((Key) -> Bool)?
    private var hoveredRow = -1
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHovered(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(-1)
    }

    private func setHovered(_ row: Int) {
        guard row != hoveredRow else { return }
        let old = hoveredRow
        hoveredRow = row
        onHoverChange?(old, row)
    }

    /// No native disclosure triangles: projects and parent threads draw their own chevrons, sections toggle on click.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    /// Cells span the full row (they indent themselves).
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        let rowRect = rect(ofRow: row)
        return NSRect(x: rowRect.minX, y: frame.minY, width: rowRect.width, height: frame.height)
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain {
            switch event.keyCode {
            case 36, 76: if onKey?(.returnKey) == true { return }
            case 51, 117: if onKey?(.delete) == true { return }
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

/// The sidebar's background view (solid `sidebar` token); accepts folder drops on the empty state (the outline view
/// handles its own).
@MainActor
final class SidebarDropView: NSView {
    var onDrop: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.fileURL])
    }

    override func draw(_ dirtyRect: NSRect) {
        DS.Color.sidebar.setFill()
        dirtyRect.fill(using: .sourceOver)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        SidebarViewController.directories(in: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDrop?(SidebarViewController.directories(in: sender.draggingPasteboard)) ?? false
    }
}

/// Signposts for the shell (AGENTS.md rule 20). Never logs content.
enum ShellSignposts {
    static let sidebar = OSSignposter(subsystem: "com.bellocode.app", category: "Sidebar")
    static let content = OSSignposter(subsystem: "com.bellocode.app", category: "Content")
    static let palette = OSSignposter(subsystem: "com.bellocode.app", category: "Palette")
}
