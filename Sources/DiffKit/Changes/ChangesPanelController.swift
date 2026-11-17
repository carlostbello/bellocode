import AppKit
import BelloCore
import DesignSystem
import Engine
import Observation

/// What the Changes panel asks of the window it lives in.
@MainActor
public protocol ChangesPanelHost: AnyObject {
    /// A review comment to put into the thread's composer as context.
    func changesPanel(_ panel: ChangesPanelController, addComment comment: DiffReviewComment)
    /// A completed change to offer as Undo (Edit menu and toast).
    func changesPanel(_ panel: ChangesPanelController, didChange change: ReversibleChange)
    /// A short notice (toast) such as "Pushed feature/login".
    func changesPanel(_ panel: ChangesPanelController, notice: String)
}

/// The right panel's "Changes" tab: scope switcher (this turn / branch vs base / uncommitted / one commit), a status
/// line naming the branch, workspace and base, the changed-files tree with status and line counts, the diff, and for
/// uncommitted changes stage toggles, a commit field, Push and Open Pull Request.
///
/// Mounting: `ChangesPanelController(model:)`; replace the model with `display(_:)` when the thread changes. Previous
/// content stays visible (marked stale) while a scope reloads.
@MainActor
public final class ChangesPanelController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate,
    DiffViewControllerDelegate, NSMenuItemValidation
{
    public weak var host: (any ChangesPanelHost)?
    public private(set) var model: ChangesModel?
    public let diff = DiffViewController()
    /// Saved per thread by the owner (layout, whitespace, wrap).
    public var options: DiffViewOptions {
        get { diff.options }
        set {
            diff.options = newValue
            syncOptionControls()
        }
    }

    private let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let detailPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let layoutControl = NSSegmentedControl()
    private let optionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let refreshButton = NSButton()
    private let statusLine = NSTextField(labelWithString: "")
    private let messageLine = NSTextField(wrappingLabelWithString: "")
    private let outline = NSOutlineView()
    private let outlineScroll = NSScrollView()
    private let split = NSSplitView()
    private let footer = NSStackView()
    private let commitField = NSTextField()
    private let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    private let pushButton = NSButton(title: "Push", target: nil, action: nil)
    private let pullRequestButton = NSButton(title: "Open Pull Request", target: nil, action: nil)
    private var tree: [FileTreeNode] = []
    private var footerCollapse: NSLayoutConstraint?
    private var loop: ObservationLoop?
    private var syncingSelection = false
    private var shownDiffFiles: [DiffFile] = []

    public init(model: ChangesModel? = nil) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        loop?.cancel()
        model?.repository.endWatching()
    }

    // MARK: View

    public override func loadView() {
        let container = NSView()
        container.setAccessibilityLabel("Changes")
        configureHeader()
        configureOutline()
        configureFooter()
        diff.delegate = self
        diff.onVisibleFileChange = { [weak self] path in self?.selectInTree(path) }
        addChild(diff)
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(outlineScroll)
        split.addArrangedSubview(diff.view)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(250), forSubviewAt: 1)
        outlineScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true

        let scopeRow = NSStackView(views: [scopePopup, detailPopup, NSView(), layoutControl, optionsButton, refreshButton])
        scopeRow.spacing = DS.Spacing.s
        detailPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [scopeRow, statusLine, messageLine])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = DS.Spacing.xs
        header.edgeInsets = NSEdgeInsets(top: DS.Spacing.s, left: DS.Spacing.m, bottom: DS.Spacing.s, right: DS.Spacing.m)
        scopeRow.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -2 * DS.Spacing.m).isActive = true
        messageLine.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -2 * DS.Spacing.m).isActive = true
        let separator = NSBox()
        separator.boxType = .separator
        for view in [header, separator, split, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.topAnchor.constraint(equalTo: separator.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.topAnchor.constraint(equalTo: split.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        header.setHuggingPriority(.required, for: .vertical)
        // The files list and diff take every point the header and footer do not need.
        split.setContentHuggingPriority(.init(1), for: .vertical)
        let fill = split.heightAnchor.constraint(equalTo: container.heightAnchor)
        fill.priority = .init(300)
        fill.isActive = true
        // A hidden footer takes no height.
        footerCollapse = footer.heightAnchor.constraint(equalToConstant: 0)
        view = container
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        if let model { bind(model) } else { render() }
    }

    private var placedDivider = false

    public override func viewDidLayout() {
        super.viewDidLayout()
        placeDividerIfNeeded()
        outline.sizeLastColumnToFit()
    }

    /// The files list takes about a quarter of the height (90–220 pt) the first time there is room.
    private func placeDividerIfNeeded() {
        guard !placedDivider, split.bounds.height > 200 else { return }
        placedDivider = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.split.setPosition(max(90, min(220, self.split.bounds.height * 0.26)), ofDividerAt: 0)
        }
    }

    private func configureHeader() {
        for (title, scope) in [("This Turn", 0), ("Branch", 1), ("Uncommitted", 2), ("Commit", 3)] {
            scopePopup.addItem(withTitle: title)
            scopePopup.lastItem?.tag = scope
        }
        scopePopup.controlSize = .small
        scopePopup.autoenablesItems = false
        scopePopup.font = DS.Typography.current.caption
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged(_:))
        scopePopup.setAccessibilityLabel("Changes scope")
        scopePopup.toolTip = "Which changes to show"
        detailPopup.controlSize = .small
        detailPopup.font = DS.Typography.current.caption
        detailPopup.target = self
        detailPopup.action = #selector(detailChanged(_:))
        detailPopup.setAccessibilityLabel("Turn or commit")
        layoutControl.segmentCount = 2
        layoutControl.setImage(NSImage(systemSymbolName: "rectangle.grid.1x2", accessibilityDescription: "Unified"), forSegment: 0)
        layoutControl.setImage(NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Side by Side"), forSegment: 1)
        layoutControl.setToolTip("Unified", forSegment: 0)
        layoutControl.setToolTip("Side by Side", forSegment: 1)
        layoutControl.controlSize = .small
        layoutControl.trackingMode = .selectOne
        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged(_:))
        layoutControl.setAccessibilityLabel("Diff layout")
        optionsButton.controlSize = .small
        optionsButton.bezelStyle = .accessoryBarAction
        optionsButton.addItem(withTitle: "")
        optionsButton.lastItem?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Diff options")
        for (title, action) in [("Ignore Whitespace", #selector(toggleWhitespace(_:))), ("Wrap Lines", #selector(toggleWrap(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            optionsButton.menu?.addItem(item)
        }
        optionsButton.setAccessibilityLabel("Diff options")
        optionsButton.toolTip = "Diff options"
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.bezelStyle = .accessoryBarAction
        refreshButton.controlSize = .small
        refreshButton.target = self
        refreshButton.action = #selector(refresh(_:))
        refreshButton.toolTip = "Refresh"
        statusLine.font = DS.Typography.current.caption
        statusLine.textColor = DS.Palette.secondaryText
        statusLine.lineBreakMode = .byTruncatingMiddle
        statusLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageLine.font = DS.Typography.current.caption
        messageLine.isHidden = true
        syncOptionControls()
    }

    private func configureOutline() {
        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        column.width = 300
        outline.addTableColumn(column)
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = DS.Spacing.sidebarRowHeight - 2
        outline.style = .plain
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openSelected(_:))
        outline.allowsMultipleSelection = true
        outline.setAccessibilityLabel("Changed files")
        outline.menu = NSMenu()
        outline.menu?.delegate = menuDelegate
        menuDelegate.owner = self
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.drawsBackground = false
    }

    private let menuDelegate = FileMenuDelegate()

    private func configureFooter() {
        commitField.placeholderString = "Commit message (⌘↩ to commit)"
        commitField.font = DS.Typography.current.body
        commitField.delegate = self
        commitField.setAccessibilityLabel("Commit message")
        commitField.lineBreakMode = .byTruncatingTail
        for (button, action) in [(commitButton, #selector(commit(_:))), (pushButton, #selector(push(_:))), (pullRequestButton, #selector(openPullRequest(_:)))] {
            button.target = self
            button.action = action
            button.controlSize = .small
            button.bezelStyle = .push
        }
        commitButton.toolTip = "Commit the staged changes (⌘↩ in the message field)"
        pushButton.toolTip = "Push the current branch (publishes it when it has no upstream)"
        pullRequestButton.toolTip = "Open GitHub’s compare page in the browser"
        let buttons = NSStackView(views: [commitButton, NSView(), pushButton, pullRequestButton])
        buttons.spacing = DS.Spacing.s
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = DS.Spacing.s
        footer.edgeInsets = NSEdgeInsets(top: DS.Spacing.s, left: DS.Spacing.m, bottom: DS.Spacing.s, right: DS.Spacing.m)
        footer.addArrangedSubview(commitField)
        footer.addArrangedSubview(buttons)
        commitField.widthAnchor.constraint(equalTo: footer.widthAnchor, constant: -2 * DS.Spacing.m).isActive = true
        buttons.widthAnchor.constraint(equalTo: footer.widthAnchor, constant: -2 * DS.Spacing.m).isActive = true
        footer.wantsLayer = true
        footer.setHuggingPriority(.required, for: .vertical)
        footer.isHidden = true
    }

    // MARK: Binding

    /// Shows another thread's (or draft's) changes. The previous model's watcher stops.
    public func display(_ model: ChangesModel?) {
        guard model !== self.model else { return }
        self.model?.repository.endWatching()
        loop?.cancel()
        self.model = model
        guard isViewLoaded else { return }
        if let model { bind(model) } else {
            shownDiffFiles = []
            diff.display([])
            render()
        }
    }

    private func bind(_ model: ChangesModel) {
        model.repository.beginWatching()
        if model.loadedAt == nil { model.load() }
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    private func render() {
        guard let model else {
            statusLine.stringValue = ""
            showMessage("Select a thread to see its changes.", isError: false)
            tree = []
            outline.reloadData()
            footer.isHidden = true
            footerCollapse?.isActive = true
            diff.emptyText = "No thread selected"
            return
        }
        model.reloadIfRepositoryChanged()
        _ = model.repository.status
        syncScopeControls(model)
        statusLine.stringValue = statusText(model)
        statusLine.toolTip = model.directory
        let repositoryPhase = model.repository.phase
        if repositoryPhase == .notRepository, model.scope != .turn(nil), !isTurn(model.scope) {
            showMessage("This folder is not a git repository. Turn changes are still shown under This Turn.", isError: false)
        } else if let error = model.actionError {
            showMessage(error, isError: true)
        } else if case .failed(let message) = model.phase {
            showMessage(message + (model.loadedAt == nil ? "" : " Showing the last loaded changes."), isError: true)
        } else if model.isStale {
            showMessage("Updating…", isError: false)
        } else if model.phase == .loading, model.loadedAt == nil {
            showMessage("Loading changes…", isError: false)
        } else if let busy = model.busy {
            showMessage(busy, isError: false)
        } else {
            messageLine.isHidden = true
        }
        let files = model.files
        let diffFiles = model.diffFiles
        if diffFiles != shownDiffFiles {
            let keep = !shownDiffFiles.isEmpty
            shownDiffFiles = diffFiles
            tree = FileTree.build(files)
            outline.reloadData()
            outline.expandItem(nil, expandChildren: true)
            diff.display(diffFiles, revertable: model.revertablePaths, keepPosition: keep)
        } else if files.map(\.staged) != treeStagedState {
            tree = FileTree.build(files)
            outline.reloadData()
            outline.expandItem(nil, expandChildren: true)
        }
        treeStagedState = files.map(\.staged)
        diff.emptyText = emptyText(model)
        let uncommitted = model.scope == .uncommitted
        footer.isHidden = !uncommitted || model.repository.phase == .notRepository
        footerCollapse?.isActive = footer.isHidden
        commitButton.isEnabled = model.canCommit
        pushButton.isEnabled = model.busy == nil && model.repository.status?.branch != nil
        pullRequestButton.isEnabled = model.repository.status?.branch != nil
        if commitField.stringValue != model.commitMessage, commitField.currentEditor() == nil { commitField.stringValue = model.commitMessage }
    }

    private var treeStagedState: [GitChangeKind?] = []

    private func isTurn(_ scope: ChangesScope) -> Bool { if case .turn = scope { true } else { false } }

    private func showMessage(_ text: String, isError: Bool) {
        messageLine.isHidden = false
        messageLine.stringValue = (isError ? "⚠︎ " : "") + text
        messageLine.textColor = isError ? DS.Palette.failure : DS.Palette.secondaryText
    }

    private func emptyText(_ model: ChangesModel) -> String {
        if model.phase == .loading, model.loadedAt == nil { return "Loading changes…" }
        switch model.scope {
        case .turn: return model.sessionID == nil ? "Send a message: each turn’s changes appear here." : "No file changes in this turn."
        case .branch: return "No changes on this branch since \(model.baseBranch ?? "its base")."
        case .uncommitted: return "No uncommitted changes."
        case .commit: return model.commits.isEmpty ? "No commits." : "This commit changes no files."
        }
    }

    /// "⎇ feature/login · Worktree · vs main · 3 files · +40 −12 · ↑2 ↓0".
    func statusText(_ model: ChangesModel) -> String {
        var parts: [String] = []
        let status = model.repository.status
        if let branch = status?.branch {
            parts.append("⎇ " + branch)
        } else if let head = status?.head {
            parts.append("Detached at \(head.prefix(8))")
        }
        if model.repository.phase != .notRepository { parts.append(model.repository.workspaceKind.label) }
        if model.scope == .branch { parts.append("vs \(model.baseBranch ?? "base")") }
        parts.append(model.summary)
        if let status {
            if status.ahead > 0 || status.behind > 0 { parts.append("↑\(status.ahead) ↓\(status.behind)") }
            if status.upstream == nil, status.branch != nil { parts.append("not published") }
        }
        return parts.joined(separator: " · ")
    }

    private func syncScopeControls(_ model: ChangesModel) {
        let tag: Int = switch model.scope {
        case .turn: 0
        case .branch: 1
        case .uncommitted: 2
        case .commit: 3
        }
        scopePopup.selectItem(withTag: tag)
        scopePopup.menu?.item(withTag: 0)?.isEnabled = model.sessionID != nil
        scopePopup.menu?.item(withTag: 1)?.title = "Branch vs \(model.baseBranch ?? "base")"
        detailPopup.removeAllItems()
        switch model.scope {
        case .turn(let selected):
            let turns = model.turns()
            detailPopup.isHidden = turns.isEmpty
            for turn in turns.reversed() {
                detailPopup.addItem(withTitle: "Turn \(turn.index + 1): \(turn.title)")
                detailPopup.lastItem?.representedObject = turn.id.rawValue
            }
            if let selected, let index = detailPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selected.rawValue }) {
                detailPopup.selectItem(at: index)
            } else {
                detailPopup.selectItem(at: 0)
            }
        case .commit(let hash):
            detailPopup.isHidden = model.commits.isEmpty
            for commit in model.commits {
                detailPopup.addItem(withTitle: "\(commit.shortHash) \(commit.subject)")
                detailPopup.lastItem?.representedObject = commit.hash
            }
            if let index = detailPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == hash }) { detailPopup.selectItem(at: index) }
        default:
            detailPopup.isHidden = true
        }
    }

    private func syncOptionControls() {
        layoutControl.selectedSegment = diff.options.layout == .unified ? 0 : 1
        optionsButton.menu?.items.first { $0.action == #selector(toggleWhitespace(_:)) }?.state = diff.options.ignoreWhitespace ? .on : .off
        optionsButton.menu?.items.first { $0.action == #selector(toggleWrap(_:)) }?.state = diff.options.wraps ? .on : .off
    }

    /// Prints the panel's frames (DiffDemo diagnostics).
    public func debugDump() {
        print("split", split.frame, split.subviews.map(\.frame), "outline rows", outline.numberOfRows, "tree", tree.count,
              "diff rows", diff.rowCount, "files", model?.files.count ?? -1, "phase", String(describing: model?.phase))
    }

    // MARK: Header actions

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
        guard let model else { return }
        switch sender.selectedTag() {
        case 0: model.setScope(.turn(nil))
        case 1: model.setScope(.branch)
        case 2: model.setScope(.uncommitted)
        default:
            let first = model.commits.first?.hash ?? "HEAD"
            model.setScope(.commit(first))
        }
    }

    @objc private func detailChanged(_ sender: NSPopUpButton) {
        guard let model, let value = sender.selectedItem?.representedObject as? String else { return }
        switch model.scope {
        case .turn: model.setScope(.turn(sender.indexOfSelectedItem == 0 ? nil : MessageID(value)))
        case .commit: model.setScope(.commit(value))
        default: break
        }
    }

    @objc private func layoutChanged(_ sender: NSSegmentedControl) { setLayout(sender.selectedSegment == 0 ? .unified : .split) }
    @objc public func toggleWhitespace(_ sender: Any?) { options.ignoreWhitespace.toggle() }
    @objc public func toggleWrap(_ sender: Any?) { options.wraps.toggle() }
    @objc public func refresh(_ sender: Any?) {
        model?.repository.refresh()
        model?.load()
    }

    public func setLayout(_ layout: DiffLayout) { options.layout = layout }
    public func setScope(_ scope: ChangesScope) { model?.setScope(scope) }

    // MARK: Footer actions

    @objc private func commit(_ sender: Any?) {
        guard let model else { return }
        model.commitMessage = commitField.stringValue
        if model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commitField.stringValue = model.suggestedCommitMessage()
            model.commitMessage = commitField.stringValue
            view.window?.makeFirstResponder(commitField)
            return
        }
        Task {
            if await model.commit() {
                commitField.stringValue = ""
                host?.changesPanel(self, notice: "Committed to \(model.repository.status?.branch ?? "HEAD")")
            }
        }
    }

    @objc public func push(_ sender: Any?) {
        guard let model else { return }
        Task {
            if await model.push() { host?.changesPanel(self, notice: "Pushed \(model.repository.status?.branch ?? "the branch")") }
        }
    }

    @objc public func openPullRequest(_ sender: Any?) {
        guard let model else { return }
        Task {
            if let url = await model.pullRequestURL() {
                NSWorkspace.shared.open(url)
            } else {
                host?.changesPanel(self, notice: "Open Pull Request needs a GitHub remote named origin.")
            }
        }
    }

    public func controlTextDidChange(_ notification: Notification) {
        model?.commitMessage = commitField.stringValue
        commitButton.isEnabled = model?.canCommit ?? false
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === commitField, selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            commit(nil)
            return true
        }
        return false
    }

    /// Focuses the commit message (menu: Commit…).
    public func beginCommit() {
        if model?.scope != .uncommitted { model?.setScope(.uncommitted) }
        view.window?.makeFirstResponder(commitField)
    }

    // MARK: Files

    public func outlineView(_ outline: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FileTreeNode)?.children.count ?? tree.count
    }

    public func outlineView(_ outline: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FileTreeNode)?.children[index] ?? tree[index]
    }

    public func outlineView(_ outline: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileTreeNode)?.isFolder ?? false }

    public func outlineView(_ outline: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }
        let cell = outline.makeView(withIdentifier: FileRowView.identifier, owner: nil) as? FileRowView ?? FileRowView()
        cell.configure(node, showsStage: model?.scope == .uncommitted) { [weak self] staged in
            guard let self, let model = self.model else { return }
            Task { await model.setStaged(node.files.map(\.path), staged: staged) }
        }
        return cell
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, let node = outline.item(atRow: outline.selectedRow) as? FileTreeNode else { return }
        if let file = node.file { diff.scroll(toFile: file.path) } else if let first = node.files.first { diff.scroll(toFile: first.path) }
    }

    private func selectInTree(_ path: String?) {
        guard let path else { return }
        for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? FileTreeNode)?.file?.path == path {
            if outline.selectedRow != row {
                syncingSelection = true
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                syncingSelection = false
            }
            return
        }
    }

    /// The files the context menu or a menu command acts on: the clicked row, else the selection, else the file in
    /// view.
    var targetFiles: [ChangedFile] {
        let clicked = outline.clickedRow
        if clicked >= 0, let node = outline.item(atRow: clicked) as? FileTreeNode {
            return outline.selectedRowIndexes.contains(clicked)
                ? outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileTreeNode }.flatMap(\.files)
                : node.files
        }
        let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileTreeNode }.flatMap(\.files)
        if !selected.isEmpty { return selected }
        if let path = diff.visibleFilePath, let file = model?.files.first(where: { $0.path == path }) { return [file] }
        return []
    }

    func url(for file: ChangedFile) -> URL? {
        guard let model else { return nil }
        return URL(filePath: model.directory).appending(path: file.path)
    }

    @objc public func openSelected(_ sender: Any?) {
        for file in targetFiles.prefix(10) { if let url = url(for: file) { EditorLauncher.open(url) } }
    }

    @objc public func revealSelected(_ sender: Any?) {
        let urls = targetFiles.compactMap(url(for:)).filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { return NSSound.beep() }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc public func copySelectedPaths(_ sender: Any?) {
        let paths = targetFiles.compactMap { url(for: $0)?.path }
        guard !paths.isEmpty else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func copyRelativePaths(_ sender: Any?) {
        let paths = targetFiles.map(\.path)
        guard !paths.isEmpty else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func openWith(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        EditorLauncher.preferredEditorID = id
        openSelected(sender)
    }

    @objc func stageSelected(_ sender: Any?) {
        guard let model else { return }
        let paths = targetFiles.map(\.path)
        Task { await model.setStaged(paths, staged: true) }
    }

    @objc func unstageSelected(_ sender: Any?) {
        guard let model else { return }
        let paths = targetFiles.map(\.path)
        Task { await model.setStaged(paths, staged: false) }
    }

    /// Reverts the target file(s) in the current scope (the menu title states the exact scope). Reversible: Undo
    /// restores the exact bytes.
    @objc public func revertSelectedFiles(_ sender: Any?) {
        guard let model else { return }
        let paths = targetFiles.map(\.path)
        guard !paths.isEmpty else { return NSSound.beep() }
        Task {
            for path in paths {
                do {
                    try await model.revertFile(path)
                } catch {
                    model.actionError = Self.message(error)
                    return
                }
            }
        }
    }

    /// Reverts the diff's current hunk (menu: Revert Hunk).
    @objc public func revertCurrentHunk(_ sender: Any?) {
        guard let (file, hunk) = diff.currentHunk, model?.revertablePaths.contains(file.path) == true else { return NSSound.beep() }
        diffViewController(diff, revertHunk: hunk, in: file)
    }

    /// Reverts the whole turn shown (or the newest), checking first for edits made after it.
    @objc public func revertTurn(_ sender: Any?) {
        guard let model, let window = view.window else { return }
        let turnID: MessageID? = {
            if case .turn(let id) = model.scope, let id { return id }
            return model.turns().last?.id
        }()
        guard let turnID else { return NSSound.beep() }
        Task {
            do {
                let plan = try await model.planTurnRevert(turnID)
                guard !plan.files.isEmpty else {
                    host?.changesPanel(self, notice: "This turn changed no files.")
                    return
                }
                if plan.editedSince.isEmpty {
                    try await model.performTurnRevert(plan, agentChangesOnly: false)
                    return
                }
                let alert = NSAlert()
                alert.messageText = "Files were edited after this turn"
                let names = plan.editedSince.prefix(6).map { "• " + $0 }.joined(separator: "\n")
                alert.informativeText = """
                    These files changed since the agent edited them:
                    \(names)\(plan.editedSince.count > 6 ? "\n…and \(plan.editedSince.count - 6) more" : "")

                    “Revert Agent Changes” undoes only the turn’s own edits and keeps the later ones. “Restore Files” \
                    puts every file back as it was before the turn, replacing the later edits. Both can be undone.
                    """
                alert.addButton(withTitle: "Revert Agent Changes")
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Restore Files")
                alert.buttons.last?.hasDestructiveAction = true
                let response = await alert.beginSheetModal(for: window)
                switch response {
                case .alertFirstButtonReturn: try await model.performTurnRevert(plan, agentChangesOnly: true)
                case .alertThirdButtonReturn: try await model.performTurnRevert(plan, agentChangesOnly: false)
                default: return
                }
            } catch {
                model.actionError = Self.message(error)
            }
        }
    }

    static func message(_ error: any Error) -> String {
        if let error = error as? WorkingCopyError { return error.userMessage }
        if let error = error as? GitError { return error.userMessage }
        return ChangesModel.describe(error)
    }

    // MARK: DiffViewControllerDelegate

    public func diffViewController(_ controller: DiffViewController, revertHunk hunkIndex: Int, in file: DiffFile) {
        guard let model else { return }
        Task {
            do {
                try await model.revertHunk(hunkIndex, in: file)
                model.actionError = nil
            } catch {
                model.actionError = Self.message(error)
            }
        }
    }

    public func diffViewController(_ controller: DiffViewController, addComment comment: DiffReviewComment) {
        host?.changesPanel(self, addComment: comment)
    }

    public func diffViewController(_ controller: DiffViewController, open file: DiffFile, line: Int?) {
        guard let model else { return }
        EditorLauncher.open(URL(filePath: model.directory).appending(path: file.path), line: line)
    }

    // MARK: Menu validation

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let files = targetFiles
        switch menuItem.action {
        case #selector(stageSelected(_:)): return model?.scope == .uncommitted && files.contains { $0.unstaged != nil }
        case #selector(unstageSelected(_:)): return model?.scope == .uncommitted && files.contains { $0.staged != nil }
        case #selector(revertSelectedFiles(_:)):
            guard let model, let first = files.first, let title = model.revertTitle(for: first.path) else { return false }
            menuItem.title = files.count == 1 ? title + "…" : "Revert \(files.count) Files (\(model.scope.title))"
            return true
        case #selector(openSelected(_:)), #selector(revealSelected(_:)), #selector(copySelectedPaths(_:)), #selector(copyRelativePaths(_:)), #selector(openWith(_:)):
            return !files.isEmpty
        default: return true
        }
    }

    /// Builds the file context menu (also used by the app's Changes menu items).
    func buildFileMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        add("Open in Editor", #selector(openSelected(_:)))
        let openWith = NSMenu()
        for editor in EditorLauncher.available {
            let item = openWith.addItem(withTitle: editor.name, action: #selector(self.openWith(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = editor.id
            item.state = editor.id == EditorLauncher.preferredEditorID ? .on : .off
        }
        let openWithItem = menu.addItem(withTitle: "Open With", action: nil, keyEquivalent: "")
        openWithItem.submenu = openWith
        add("Reveal in Finder", #selector(revealSelected(_:)))
        add("Copy Path", #selector(copySelectedPaths(_:)))
        add("Copy Relative Path", #selector(copyRelativePaths(_:)))
        if model?.scope == .uncommitted {
            menu.addItem(.separator())
            add("Stage", #selector(stageSelected(_:)))
            add("Unstage", #selector(unstageSelected(_:)))
        }
        if model.map({ if case .commit = $0.scope { false } else { true } }) ?? false {
            menu.addItem(.separator())
            add("Revert…", #selector(revertSelectedFiles(_:)))
        }
    }
}

/// Builds the files' context menu when it opens (titles depend on the clicked file and scope).
@MainActor
final class FileMenuDelegate: NSObject, NSMenuDelegate {
    weak var owner: ChangesPanelController?
    func menuNeedsUpdate(_ menu: NSMenu) { owner?.buildFileMenu(menu) }
}

/// One row of the changed-files tree: stage checkbox (uncommitted scope), status letter (with the word for
/// VoiceOver and the tooltip), name, folder, and +/− counts.
@MainActor
final class FileRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ChangedFileRow")
    private let stage = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let badge = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let counts = NSTextField(labelWithString: "")
    private var onStage: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        badge.font = .monospacedSystemFont(ofSize: DS.Typography.current.baseSize - 2, weight: .bold)
        badge.alignment = .center
        name.font = DS.Typography.current.body
        name.lineBreakMode = .byTruncatingMiddle
        counts.font = .monospacedDigitSystemFont(ofSize: DS.Typography.current.baseSize - 2, weight: .regular)
        stage.controlSize = .small
        stage.target = self
        stage.action = #selector(toggled(_:))
        let stack = NSStackView(views: [stage, badge, name, NSView(), counts])
        stack.spacing = DS.Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = name
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ node: FileTreeNode, showsStage: Bool, onStage: @escaping (Bool) -> Void) {
        self.onStage = onStage
        name.stringValue = node.name
        if let file = node.file {
            badge.isHidden = false
            badge.stringValue = file.statusLetter
            badge.textColor = switch file.statusLetter {
            case "A", "?": DS.Palette.success
            case "D": DS.Palette.failure
            default: NSColor.controlAccentColor
            }
            badge.toolTip = file.statusWord
            let attributed = NSMutableAttributedString()
            if file.isBinary {
                attributed.append(NSAttributedString(string: "binary", attributes: [.foregroundColor: DS.Palette.secondaryText]))
            } else {
                if file.additions > 0 { attributed.append(NSAttributedString(string: "+\(file.additions)", attributes: [.foregroundColor: NSColor.systemGreen])) }
                if file.deletions > 0 {
                    attributed.append(NSAttributedString(string: (attributed.length > 0 ? " " : "") + "−\(file.deletions)", attributes: [.foregroundColor: NSColor.systemRed]))
                }
            }
            counts.attributedStringValue = attributed
            name.font = DS.Typography.current.body
            name.textColor = file.status == .deleted ? DS.Palette.secondaryText : DS.Palette.text
            toolTip = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
            stage.isHidden = !showsStage
            stage.state = file.staged != nil ? (file.unstaged != nil ? .mixed : .on) : .off
            stage.allowsMixedState = true
            stage.setAccessibilityLabel("Staged")
            setAccessibilityLabel("\(file.path), \(file.statusWord), \(file.additions) added, \(file.deletions) removed\(showsStage ? (file.staged != nil ? ", staged" : ", not staged") : "")")
        } else {
            badge.isHidden = true
            counts.stringValue = ""
            name.font = DS.Typography.current.bodyEmphasized
            name.textColor = DS.Palette.secondaryText
            stage.isHidden = !showsStage
            let files = node.files
            let staged = files.filter { $0.staged != nil }.count
            stage.state = staged == 0 ? .off : staged == files.count ? .on : .mixed
            toolTip = node.path
            setAccessibilityLabel("Folder \(node.path), \(files.count) files")
        }
    }

    @objc private func toggled(_ sender: NSButton) {
        onStage?(sender.state != .off)
    }
}

/// Re-runs `body` whenever observed state it read changes (the shell's pattern, local to DiffKit).
@MainActor
final class ObservationLoop {
    private var active = true
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
        run()
    }

    func cancel() { active = false }

    private func run() {
        guard active else { return }
        withObservationTracking { body() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.run() }
        }
    }
}
