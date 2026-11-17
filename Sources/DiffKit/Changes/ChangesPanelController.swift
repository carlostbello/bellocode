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
/// uncommitted changes stage toggles, a commit field, Push and Create Merge Request (GitLab).
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

    private let scopeSelect = DSSelectButton(title: "This turn", chevron: .upDown, size: .small)
    private let scopeMenu = NSMenu()
    private let detailSelect = DSSelectButton(title: "", chevron: .upDown, size: .small)
    private let detailMenu = NSMenu()
    /// "3 files · +42 −9" in `label`, the counts in the semantic colours.
    private let summaryLabel = NSTextField(labelWithString: "")
    private let layoutControl = DSSegmented(items: [
        DSChoiceItem(id: DiffLayout.unified.rawValue, title: "", symbolName: "rectangle.split.1x2", accessibilityLabel: "Unified"),
        DSChoiceItem(id: DiffLayout.split.rawValue, title: "", symbolName: "rectangle.split.2x1", accessibilityLabel: "Side by Side"),
    ])
    private let optionsButton = DSSelectButton(title: "", symbolName: "ellipsis", chevron: .none, size: .small)
    private let optionsMenu = NSMenu()
    private let refreshButton = DSButton(icon: "arrow.clockwise", accessibilityTitle: "Refresh", size: .small)
    /// Branch, workspace and base (`meta text3`): where these changes live (UX rule 6).
    private let statusLine = NSTextField(labelWithString: "")
    private let messageLine = NSTextField(wrappingLabelWithString: "")
    private let outline = NSOutlineView()
    private let outlineScroll = NSScrollView()
    private let split = HairlineSplitView()
    private let footer = NSStackView()
    private let commitInput = DSTextField(placeholder: "Commit message")
    private var commitField: NSTextField { commitInput.field }
    private let commitButton = DSButton(title: "Commit", variant: .primary, size: .small, shortcutHint: "⌘↩")
    private let pushButton = DSButton(title: "Push", variant: .outline, size: .small, symbolName: "arrow.up")
    private let mergeRequestButton = DSButton(title: "Merge Request", variant: .ghost, size: .small, symbolName: "arrow.triangle.pull")
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
        let container = CanvasView()
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

        // The 36 pt toolbar (§6 "Right panel"): scope and turn selects, the summary, layout toggle, overflow, refresh.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let scopeRow = NSStackView(views: [scopeSelect, detailSelect, summaryLabel, spacer, layoutControl, optionsButton, refreshButton])
        scopeRow.spacing = DS.Space.s4
        scopeRow.alignment = .centerY
        scopeRow.setCustomSpacing(DS.Space.s8, after: detailSelect)
        scopeRow.setCustomSpacing(DS.Space.s8, after: scopeSelect)
        scopeRow.setCustomSpacing(DS.Space.s8, after: layoutControl)
        scopeRow.heightAnchor.constraint(equalToConstant: DS.Size.toolbar).isActive = true
        detailSelect.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let header = NSStackView(views: [scopeRow, statusLine, messageLine])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 0
        header.edgeInsets = NSEdgeInsets(top: 0, left: DS.Space.s8, bottom: DS.Space.s6, right: DS.Space.s8)
        scopeRow.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -2 * DS.Space.s8).isActive = true
        statusLine.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor, constant: -2 * DS.Space.s16).isActive = true
        messageLine.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -2 * DS.Space.s16).isActive = true
        header.setCustomSpacing(DS.Space.s4, after: statusLine)
        for line in [statusLine, messageLine] {
            // Text aligned with the select's title.
            line.translatesAutoresizingMaskIntoConstraints = false
        }
        let separator = DSDivider()
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
            separator.heightAnchor.constraint(equalToConstant: DS.Border.hairline),
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
        for (title, scope) in [("This turn", 0), ("Branch", 1), ("Uncommitted", 2), ("Commit", 3)] {
            let item = scopeMenu.addItem(withTitle: title, action: #selector(scopeChanged(_:)), keyEquivalent: "")
            item.tag = scope
            item.target = self
        }
        scopeMenu.autoenablesItems = false
        scopeSelect.popUpMenu = scopeMenu
        scopeSelect.isMuted = false
        scopeSelect.setAccessibilityLabel("Changes scope")
        scopeSelect.toolTip = "Which changes to show"
        detailMenu.autoenablesItems = false
        detailSelect.popUpMenu = detailMenu
        detailSelect.setAccessibilityLabel("Turn or commit")
        summaryLabel.font = DS.TextRole.label.font
        summaryLabel.textColor = DS.Color.text2
        summaryLabel.lineBreakMode = .byTruncatingTail
        layoutControl.onSelect = { [weak self] id in self?.setLayout(DiffLayout(rawValue: id) ?? .unified) }
        layoutControl.setAccessibilityLabel("Diff layout")
        for (title, action) in [("Ignore Whitespace", #selector(toggleWhitespace(_:))), ("Wrap Lines", #selector(toggleWrap(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            optionsMenu.addItem(item)
        }
        optionsButton.popUpMenu = optionsMenu
        optionsButton.accessibilityTitle = "Diff options"
        optionsButton.setAccessibilityLabel("Diff options")
        optionsButton.toolTip = "Diff options"
        refreshButton.target = self
        refreshButton.action = #selector(refresh(_:))
        refreshButton.toolTip = "Refresh"
        statusLine.font = DS.TextRole.meta.font
        statusLine.textColor = DS.Color.text3
        statusLine.lineBreakMode = .byTruncatingMiddle
        statusLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageLine.font = DS.TextRole.label.font
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
        outline.rowHeight = DS.Size.fileRow
        outline.style = .plain
        outline.selectionHighlightStyle = .none
        outline.backgroundColor = .clear
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = 0
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
        DSScroller.install(on: outlineScroll)
    }

    private let menuDelegate = FileMenuDelegate()

    private func configureFooter() {
        commitInput.placeholder = "Commit message"
        commitField.delegate = self
        commitField.setAccessibilityLabel("Commit message")
        commitField.lineBreakMode = .byTruncatingTail
        for (button, action) in [(commitButton, #selector(commit(_:))), (pushButton, #selector(push(_:))), (mergeRequestButton, #selector(createMergeRequest(_:)))] {
            button.target = self
            button.action = action
        }
        mergeRequestButton.accessibilityTitle = "Create Merge Request"
        commitButton.toolTip = "Commit the staged changes (⌘↩ in the message field)"
        pushButton.toolTip = "Push the current branch (publishes it when it has no upstream)"
        mergeRequestButton.toolTip = "Open GitLab’s new merge request page for this branch in the browser"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [mergeRequestButton, spacer, pushButton, commitButton])
        buttons.spacing = DS.Space.s8
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = DS.Space.s8
        footer.edgeInsets = NSEdgeInsets(top: DS.Space.s10, left: DS.Space.s12, bottom: DS.Space.s10, right: DS.Space.s12)
        footer.addArrangedSubview(commitInput)
        footer.addArrangedSubview(buttons)
        commitInput.widthAnchor.constraint(equalTo: footer.widthAnchor, constant: -2 * DS.Space.s12).isActive = true
        buttons.widthAnchor.constraint(equalTo: footer.widthAnchor, constant: -2 * DS.Space.s12).isActive = true
        footer.setHuggingPriority(.required, for: .vertical)
        footer.isHidden = true
        let rule = DSDivider()
        rule.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(rule)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: footer.topAnchor),
            rule.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: DS.Border.hairline),
        ])
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
            summaryLabel.stringValue = ""
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
        summaryLabel.attributedStringValue = summaryText(model)
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
            tree = FileTree.flat(files)
            outline.reloadData()
            outline.expandItem(nil, expandChildren: true)
            diff.display(diffFiles, revertable: model.revertablePaths, keepPosition: keep)
        } else if files.map(\.staged) != treeStagedState {
            tree = FileTree.flat(files)
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
        mergeRequestButton.isEnabled = model.repository.status?.branch != nil
        if commitField.stringValue != model.commitMessage, commitField.currentEditor() == nil { commitField.stringValue = model.commitMessage }
    }

    private var treeStagedState: [GitChangeKind?] = []

    private func isTurn(_ scope: ChangesScope) -> Bool { if case .turn = scope { true } else { false } }

    private func showMessage(_ text: String, isError: Bool) {
        messageLine.isHidden = false
        // Errors carry a word as well as the colour ("Failed:"), never colour only.
        messageLine.stringValue = (isError ? "Failed: " : "") + text
        messageLine.textColor = isError ? DS.Color.dangerText : DS.Color.text3
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

    /// "3 files · +42 −9" with the counts in `successText` / `dangerText`.
    func summaryText(_ model: ChangesModel) -> NSAttributedString {
        let font = DS.TextRole.label.font(base: DS.Typography.current.baseSize, monospacedDigits: true)
        let files = model.files
        guard !files.isEmpty else { return NSAttributedString(string: "No changes", attributes: [.font: font, .foregroundColor: DS.Color.text3]) }
        let text = NSMutableAttributedString(
            string: "\(files.count) file\(files.count == 1 ? "" : "s") · ", attributes: [.font: font, .foregroundColor: DS.Color.text2])
        text.append(NSAttributedString(string: "+\(model.totalAdditions)", attributes: [.font: font, .foregroundColor: DS.Color.successText]))
        text.append(NSAttributedString(string: " −\(model.totalDeletions)", attributes: [.font: font, .foregroundColor: DS.Color.dangerText]))
        return text
    }

    /// "⎇ feature/login · Worktree · vs main · ↑2 ↓0" (the file count and stat are in the toolbar).
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
        scopeMenu.item(withTag: 0)?.isEnabled = model.sessionID != nil
        scopeMenu.item(withTag: 1)?.title = "Branch vs \(model.baseBranch ?? "base")"
        for item in scopeMenu.items { item.state = item.tag == tag ? .on : .off }
        scopeSelect.title = scopeMenu.item(withTag: tag)?.title ?? ""
        detailMenu.removeAllItems()
        var selectedTitle: String?
        func add(_ title: String, value: String, selected: Bool) {
            let item = detailMenu.addItem(withTitle: title, action: #selector(detailChanged(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = selected ? .on : .off
            if selected { selectedTitle = title }
        }
        switch model.scope {
        case .turn(let selected):
            let turns = Array(model.turns().reversed())
            detailSelect.isHidden = turns.isEmpty
            for (index, turn) in turns.enumerated() {
                add("Turn \(turn.index + 1): \(turn.title)", value: turn.id.rawValue, selected: selected.map { $0 == turn.id } ?? (index == 0))
            }
            detailMenu.items.first?.tag = 1  // the newest turn: "follow the latest"
        case .commit(let hash):
            detailSelect.isHidden = model.commits.isEmpty
            for commit in model.commits { add("\(commit.shortHash) \(commit.subject)", value: commit.hash, selected: commit.hash == hash) }
        default:
            detailSelect.isHidden = true
        }
        let shown = selectedTitle ?? detailMenu.items.first?.title ?? ""
        if detailSelect.title != shown {
            detailSelect.title = shown
            detailSelect.toolTip = shown
        }
    }

    private func syncOptionControls() {
        layoutControl.selectedID = diff.options.layout.rawValue
        optionsMenu.items.first { $0.action == #selector(toggleWhitespace(_:)) }?.state = diff.options.ignoreWhitespace ? .on : .off
        optionsMenu.items.first { $0.action == #selector(toggleWrap(_:)) }?.state = diff.options.wraps ? .on : .off
    }

    /// Prints the panel's frames (DiffDemo diagnostics).
    public func debugDump() {
        print("split", split.frame, split.subviews.map(\.frame), "outline rows", outline.numberOfRows, "tree", tree.count,
              "diff rows", diff.rowCount, "files", model?.files.count ?? -1, "phase", String(describing: model?.phase))
    }

    // MARK: Header actions

    @objc private func scopeChanged(_ sender: NSMenuItem) {
        guard let model else { return }
        switch sender.tag {
        case 0: model.setScope(.turn(nil))
        case 1: model.setScope(.branch)
        case 2: model.setScope(.uncommitted)
        default:
            let first = model.commits.first?.hash ?? "HEAD"
            model.setScope(.commit(first))
        }
    }

    @objc private func detailChanged(_ sender: NSMenuItem) {
        guard let model, let value = sender.representedObject as? String else { return }
        switch model.scope {
        case .turn: model.setScope(.turn(sender.tag == 1 ? nil : MessageID(value)))
        case .commit: model.setScope(.commit(value))
        default: break
        }
    }

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

    @objc public func createMergeRequest(_ sender: Any?) {
        guard let model else { return }
        Task {
            if let url = await model.newMergeRequestURL() {
                NSWorkspace.shared.open(url)
            } else {
                host?.changesPanel(self, notice: "Create Merge Request needs an origin remote on a GitLab instance added in Settings ▸ GitLab.")
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

    public func outlineView(_ outline: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = DSTableRowView()
        row.horizontalInset = DS.Space.s4
        return row
    }

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
    public var targetFiles: [ChangedFile] {
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

/// One 26 pt row of the changed-files list (visual-language.md §6 "Right panel"): stage checkbox (uncommitted scope),
/// the 14 pt M/A/D badge (the word for VoiceOver and the tooltip), the name in `label`, its folder in `text3`, and the
/// +/− counts right-aligned in `successText` / `dangerText`. Selection and hover are the row recipe (`DSTableRowView`).
@MainActor
final class FileRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ChangedFileRow")
    private let stage = DSToggle(kind: .checkbox)
    private let badge = FileStatusBadge()
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")
    private let counts = NSTextField(labelWithString: "")
    private var onStage: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.font = DS.TextRole.label.font
        name.textColor = DS.Color.text
        name.lineBreakMode = .byTruncatingMiddle
        folder.font = DS.TextRole.label.font
        folder.textColor = DS.Color.text3
        folder.lineBreakMode = .byTruncatingHead
        counts.font = DS.TextRole.label.font(base: DS.Typography.current.baseSize, monospacedDigits: true)
        stage.target = self
        stage.action = #selector(toggled(_:))
        stage.setAccessibilityLabel("Staged")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [stage, badge, name, folder, spacer, counts])
        stack.spacing = DS.Space.s8
        stack.setCustomSpacing(DS.Space.s6, after: name)
        stack.alignment = .centerY
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = name
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folder.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.s12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.s12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ node: FileTreeNode, showsStage: Bool, onStage: @escaping (Bool) -> Void) {
        self.onStage = onStage
        name.stringValue = node.name
        stage.isHidden = !showsStage
        guard let file = node.file else {
            badge.isHidden = true
            counts.stringValue = ""
            folder.stringValue = ""
            name.textColor = DS.Color.text2
            let files = node.files
            let staged = files.filter { $0.staged != nil }.count
            stage.isOn = staged == files.count && staged > 0
            stage.isMixed = staged > 0 && staged < files.count
            toolTip = node.path
            setAccessibilityLabel("Folder \(node.path), \(files.count) files")
            return
        }
        badge.isHidden = false
        badge.letter = file.statusLetter
        badge.toolTip = file.statusWord
        let directory = (file.path as NSString).deletingLastPathComponent
        folder.stringValue = directory
        folder.isHidden = directory.isEmpty
        let attributed = NSMutableAttributedString()
        if file.isBinary {
            attributed.append(NSAttributedString(string: "binary", attributes: [.foregroundColor: DS.Color.text3]))
        } else {
            if file.additions > 0 { attributed.append(NSAttributedString(string: "+\(file.additions)", attributes: [.foregroundColor: DS.Color.successText])) }
            if file.deletions > 0 {
                attributed.append(NSAttributedString(string: (attributed.length > 0 ? " " : "") + "−\(file.deletions)", attributes: [.foregroundColor: DS.Color.dangerText]))
            }
        }
        counts.attributedStringValue = attributed
        name.textColor = file.status == .deleted ? DS.Color.text3 : DS.Color.text
        toolTip = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
        stage.isOn = file.staged != nil
        stage.isMixed = file.staged != nil && file.unstaged != nil
        setAccessibilityLabel("\(file.path), \(file.statusWord), \(file.additions) added, \(file.deletions) removed\(showsStage ? (file.staged != nil ? ", staged" : ", not staged") : "")")
    }

    @objc private func toggled(_ sender: DSToggle) {
        onStage?(sender.isOn)
    }
}

/// The 14 pt M/A/D badge: r 3, the status colour at 14 % with the letter in mono 9 bold (`successText` added,
/// `dangerText` deleted, `diffModifiedIcon` otherwise). The row's label carries the word.
@MainActor
final class FileStatusBadge: NSView {
    var letter = "M" { didSet { if letter != oldValue { needsDisplay = true } } }

    override var intrinsicContentSize: NSSize { NSSize(width: DS.Size.statusGlyph, height: DS.Size.statusGlyph) }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = switch letter {
        case "A", "?": DS.Color.successText
        case "D": DS.Color.dangerText
        default: DS.Color.diffModifiedIcon
        }
        let box = NSRect(x: 0, y: (bounds.height - 14) / 2, width: 14, height: 14)
        DSDraw.fill(box, radius: 3, color: color.withAlphaComponent(0.14 * color.alphaComponent / max(color.alphaComponent, 0.01)))
        DSDraw.text(letter, in: box, font: .monospacedSystemFont(ofSize: 9, weight: .bold), color: color, alignment: .center)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The panel's solid `canvas` (docked surfaces are solid, visual-language.md §4).
@MainActor
final class CanvasView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        DS.Color.canvas.setFill()
        dirtyRect.fill()
    }
}

/// A vertical split whose divider is a `border` hairline (not the system's grey).
@MainActor
final class HairlineSplitView: NSSplitView {
    override var dividerColor: NSColor { DS.Color.border }
    override var dividerThickness: CGFloat { 1 }
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
