import AppKit
import BelloCore
import DesignSystem
import Engine
import os

/// What the sidebar asks of its window: run a command on an explicit target (context menus, keys, the row button).
@MainActor
protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, perform command: ShellCommand, on target: CommandTarget?)
}

/// Outline row objects. NSOutlineView tracks items by pointer, so one object per identity is reused across updates.
final class SidebarItem: NSObject {
    let id: SidebarNodeID
    var children: [SidebarItem] = []
    init(id: SidebarNodeID) { self.id = id }
}

/// The sidebar: "Needs you" (from `engine.root.attention`), then projects with their threads.
///
/// AppKit `NSOutlineView` (source list) for density, keyboard and drag correctness. Structure comes from
/// `SidebarTree.build` and is applied as an identity diff (no animation, no reshuffle, no reload while agents work);
/// row content updates through each cell's own observation. Selection is applied to the workspace at once and the
/// content area shows cached content (never a blank pane).
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
    NSTextFieldDelegate
{
    private let workspace: WorkspaceController
    weak var delegate: (any SidebarDelegate)?

    let outlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()
    private let emptyState = EmptyStateView(
        symbolName: "folder.badge.plus", title: "No Projects",
        detail: "Add a folder to start a thread, or drop one here.", actionTitle: "Add Project…",
        action: #selector(MainWindowController.addProject(_:)))
    private let toast = UndoToastView()
    private let addButton = NSButton()

    private var roots: [SidebarNode] = []
    private var rootItems: [SidebarItem] = []
    private var items: [SidebarNodeID: SidebarItem] = [:]
    private var structureLoop: ObservationLoop?
    private var selectionLoop: ObservationLoop?
    private var isApplyingSelection = false
    private var isApplyingStructure = false
    private var clock: Timer?
    private var renamingID: SessionID?
    private var renameOriginal = ""

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
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = DS.Spacing.sidebarRowHeight
        outlineView.indentationPerLevel = DS.Spacing.sidebarIndent
        outlineView.floatsGroupRows = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.allowsEmptySelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
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
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addButton.title = "Add Project"
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.isBordered = false
        addButton.font = DS.Typography.current.caption
        addButton.contentTintColor = DS.Palette.secondaryText
        addButton.action = #selector(MainWindowController.addProject(_:))
        addButton.toolTip = "Add Project… (⇧⌘O)"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.undoButton.target = self
        toast.undoButton.action = #selector(undoFromToast(_:))

        let container = SidebarDropView()
        container.onDrop = { [weak self] urls in self?.addProjects(urls) ?? false }
        for subview in [scrollView, emptyState, addButton, toast] { container.addSubview(subview) }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -DS.Spacing.xs),
            addButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: DS.Spacing.l),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -DS.Spacing.m),
            emptyState.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: container.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: addButton.topAnchor),
            toast.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: DS.Spacing.m),
            toast.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -DS.Spacing.m),
            toast.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -DS.Spacing.m),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        structureLoop = ObservationLoop { [weak self] in self?.updateStructure() }
        selectionLoop = ObservationLoop { [weak self] in self?.applySelection(self?.workspace.selection) }
        workspace.undo.onToastChange = { [weak self] entry in self?.showToast(entry) }
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibleRows() }
        }
    }

    isolated deinit {
        structureLoop?.cancel()
        selectionLoop?.cancel()
        clock?.invalidate()
    }

    // MARK: - Structure

    /// Reads engine state (observed) and applies the new tree as an identity diff.
    private func updateStructure() {
        let signpost = ShellSignposts.sidebar.beginInterval("sidebarStructure")
        defer { ShellSignposts.sidebar.endInterval("sidebarStructure", signpost) }
        let root = workspace.engine.root
        var input = SidebarTree.Input(attention: root.attention.items.map(\.sessionID))
        input.projects = root.projects.map { item in
            SidebarTree.Project(directory: item.directory, threadIDs: workspace.projectModel(item)?.sessionIDs ?? [])
        }
        let newRoots = SidebarTree.build(input)
        emptyState.isHidden = !root.projects.isEmpty
        scrollView.isHidden = root.projects.isEmpty && root.attention.items.isEmpty
        guard newRoots != roots else { return }
        apply(newRoots)
    }

    private func apply(_ newRoots: [SidebarNode]) {
        isApplyingStructure = true
        defer { isApplyingStructure = false }
        let oldParents = SidebarTree.parents(roots)
        let newParents = SidebarTree.parents(newRoots)
        let moved = oldParents.contains { id, parent in newParents[id].map { $0 != parent } ?? false }
        let firstLoad = roots.isEmpty
        let previous = roots
        roots = newRoots
        // Release items that are gone.
        let alive = Set(newParents.keys)
        items = items.filter { alive.contains($0.key) }
        if moved || firstLoad {
            rootItems = newRoots.map(materialize)
            outlineView.reloadData()
            expandDefaults(rootItems)
        } else {
            outlineView.beginUpdates()
            update(parent: nil, old: previous, new: newRoots)
            outlineView.endUpdates()
        }
        if let header = items[.needsYouHeader] {
            let row = outlineView.row(forItem: header)
            if row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarTextCell {
                cell.badge.count = header.children.count
            }
        }
        applySelection(workspace.selection)
    }

    /// Builds (or reuses) items for a subtree.
    private func materialize(_ node: SidebarNode) -> SidebarItem {
        let item = items[node.id] ?? SidebarItem(id: node.id)
        items[node.id] = item
        item.children = node.children.map(materialize)
        return item
    }

    private func update(parent: SidebarItem?, old: [SidebarNode], new: [SidebarNode]) {
        let difference = new.map(\.id).difference(from: old.map(\.id))
        let newItems = new.map { node -> SidebarItem in
            if let existing = items[node.id], old.contains(where: { $0.id == node.id }) { return existing }
            return materialize(node)
        }
        if let parent { parent.children = newItems } else { rootItems = newItems }
        let removals = difference.removals.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { offset } else { nil }
        }.sorted(by: >)
        let insertions = difference.insertions.compactMap { change -> Int? in
            if case .insert(let offset, _, _) = change { offset } else { nil }
        }.sorted()
        for offset in removals { outlineView.removeItems(at: IndexSet(integer: offset), inParent: parent, withAnimation: []) }
        for offset in insertions { outlineView.insertItems(at: IndexSet(integer: offset), inParent: parent, withAnimation: []) }
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for node in new {
            guard let item = items[node.id] else { continue }
            if let previous = oldByID[node.id] {
                update(parent: item, old: previous.children, new: node.children)
            } else {
                expandDefaults([item])
            }
        }
    }

    /// Expands groups and projects unless the user collapsed them.
    private func expandDefaults(_ items: [SidebarItem]) {
        for item in items {
            switch item.id {
            case .needsYouHeader:
                if !workspace.state.isNeedsYouCollapsed { outlineView.expandItem(item) }
            case .projectsHeader:
                outlineView.expandItem(item)
                expandDefaults(item.children)
            case .project(let directory):
                if !workspace.state.collapsedProjects.contains(directory) { outlineView.expandItem(item) }
            default:
                break
            }
        }
    }

    // MARK: - Selection

    private func applySelection(_ selection: ShellSelection?) {
        let current = outlineView.selectedRow >= 0 ? (outlineView.item(atRow: outlineView.selectedRow) as? SidebarItem)?.id : nil
        // Keep a "Needs you" row selected when it already shows the selected thread.
        if let current, Self.selection(for: current) == selection, selection != nil { return }
        guard let target = SidebarTree.node(for: selection, in: roots), let item = items[target] else {
            if selection == nil, outlineView.selectedRow >= 0 { setSelectedRow(-1) }
            return
        }
        if let parentID = SidebarTree.parents(roots)[target] ?? nil, let parent = items[parentID], !outlineView.isItemExpanded(parent) {
            outlineView.expandItem(parent)
        }
        let row = outlineView.row(forItem: item)
        guard row >= 0, row != outlineView.selectedRow else { return }
        setSelectedRow(row)
        outlineView.scrollRowToVisible(row)
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
        case .needsYouHeader, .projectsHeader: nil
        }
    }

    /// The command target for a row.
    func target(for node: SidebarNodeID) -> CommandTarget? {
        switch node {
        case .attention(let id), .thread(let id):
            return workspace.target(for: .thread(id))
        case .project(let directory), .emptyProject(let directory):
            return .project(directory: directory, isPinned: workspace.projectItem(directory: directory)?.isPinned ?? false)
        case .needsYouHeader, .projectsHeader:
            return nil
        }
    }

    var selectedNode: SidebarNodeID? {
        outlineView.selectedRow >= 0 ? (outlineView.item(atRow: outlineView.selectedRow) as? SidebarItem)?.id : nil
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

    // Folder drops anywhere on the list add projects.
    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard !Self.directories(in: info.draggingPasteboard).isEmpty else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        addProjects(Self.directories(in: info.draggingPasteboard))
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
        !((item as? SidebarItem)?.id.isGroup ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        ((item as? SidebarItem)?.id.isGroup ?? false) ? 26 : DS.Spacing.sidebarRowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        switch item.id {
        case .needsYouHeader, .projectsHeader:
            let cell = outlineView.makeView(withIdentifier: SidebarTextCell.headerIdentifier, owner: nil) as? SidebarTextCell
                ?? SidebarTextCell(identifier: SidebarTextCell.headerIdentifier)
            let isNeedsYou = item.id == .needsYouHeader
            cell.label.stringValue = isNeedsYou ? "Needs You" : "Projects"
            cell.badge.count = isNeedsYou ? item.children.count : 0
            return cell
        case .emptyProject:
            let cell = outlineView.makeView(withIdentifier: SidebarTextCell.placeholderIdentifier, owner: nil) as? SidebarTextCell
                ?? SidebarTextCell(identifier: SidebarTextCell.placeholderIdentifier)
            cell.label.stringValue = "No threads yet"
            return cell
        case .project(let directory):
            let cell = outlineView.makeView(withIdentifier: ProjectCell.identifier, owner: nil) as? ProjectCell ?? {
                let cell = ProjectCell(frame: .zero)
                cell.identifier = ProjectCell.identifier
                cell.accessoryButton.target = self
                cell.accessoryButton.action = #selector(newThreadFromRowButton(_:))
                return cell
            }()
            cell.bind(directory, workspace: workspace)
            cell.isCollapsed = !outlineView.isItemExpanded(item)
            cell.isSelectedRow = outlineView.row(forItem: item) == outlineView.selectedRow && outlineView.selectedRow >= 0
            return cell
        case .thread(let id), .attention(let id):
            let isAttention = { if case .attention = item.id { true } else { false } }()
            let identifier = isAttention ? ThreadCell.attentionIdentifier : ThreadCell.identifier
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? ThreadCell ?? {
                let cell = ThreadCell(frame: .zero)
                cell.identifier = identifier
                cell.title.delegate = self
                return cell
            }()
            cell.bind(id, workspace: workspace, showsProject: isAttention)
            return cell
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateSelectedProjectAccessory()
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
        if row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ProjectCell {
            cell.isCollapsed = collapsed
        }
        guard !isApplyingStructure else { return }
        switch item.id {
        case .project(let directory): workspace.setCollapsed(directory, collapsed)
        case .needsYouHeader: workspace.setNeedsYouCollapsed(collapsed)
        default: break
        }
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

    @objc private func newThreadFromRowButton(_ sender: NSButton) {
        let row = outlineView.row(for: sender)
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem, case .project(let directory) = item.id else { return }
        delegate?.sidebar(self, perform: .newThread, on: .project(directory: directory, isPinned: false))
    }

    /// Return renames a thread (as in Finder) or toggles a project; Delete archives a thread or removes a project
    /// (both undoable).
    private func handleKey(_ key: SidebarOutlineView.Key) -> Bool {
        guard let node = selectedNode else { return false }
        switch (key, node) {
        case (.returnKey, .thread(let id)), (.returnKey, .attention(let id)):
            beginRename(id)
            return true
        case (.returnKey, .project), (.returnKey, .emptyProject):
            guard let item = items[node] else { return false }
            if outlineView.isItemExpanded(item) { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
            return true
        case (.delete, .thread), (.delete, .attention):
            delegate?.sidebar(self, perform: .archiveThread, on: target(for: node))
            return true
        case (.delete, .project):
            delegate?.sidebar(self, perform: .removeProject, on: target(for: node))
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            (control as? NSTextField)?.stringValue = renameOriginal
            renamingID = nil
            view.window?.makeFirstResponder(outlineView)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let node = (outlineView.item(atRow: row) as? SidebarItem)?.id, let target = target(for: node) else { return }
        let commands: [ShellCommand?] = switch node {
        case .thread, .attention:
            [.newThread, nil, .renameThread, .markUnread, .archiveThread, .deleteThread, nil, .revealInFinder, .copyPath]
        case .project, .emptyProject:
            [.newThread, nil, .togglePinProject, .removeProject, nil, .revealInFinder, .copyPath]
        case .needsYouHeader, .projectsHeader:
            []
        }
        let pinned = workspace.projectDirectory(for: target).flatMap { workspace.projectItem(directory: $0)?.isPinned } ?? false
        let context = CommandContext(hasProjects: true, target: target, targetProjectPinned: pinned)
        for command in commands {
            guard let command else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: context.title(for: command), action: #selector(contextCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ContextCommand(command: command, node: node)
            item.isEnabled = context.isEnabled(command)
            menu.addItem(item)
        }
    }

    private final class ContextCommand: NSObject {
        let command: ShellCommand
        let node: SidebarNodeID
        init(command: ShellCommand, node: SidebarNodeID) {
            self.command = command
            self.node = node
        }
    }

    @objc private func contextCommand(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? ContextCommand else { return }
        if context.command == .renameThread, let id = context.node.sessionID {
            beginRename(id)
            return
        }
        delegate?.sidebar(self, perform: context.command, on: target(for: context.node))
    }

    // MARK: - Toast and clock

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

    /// Focus the list (region cycling).
    func focus() { view.window?.makeFirstResponder(outlineView) }
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

/// The sidebar's background view; accepts folder drops on the empty state (the outline view handles its own).
@MainActor
final class SidebarDropView: NSView {
    var onDrop: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
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
}
