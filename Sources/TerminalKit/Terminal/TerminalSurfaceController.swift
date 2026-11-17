import AppKit
import DesignSystem
import Engine
import OpenCodeKit

/// The terminals of one thread in one place: the bottom drawer (tabs, side-by-side split) or a right-panel tab
/// (tabs). Shows an empty state with a single "New Terminal" action, a "Starting…" tab while the server creates one,
/// failures inline, and every terminal of the displayed thread attached (so exits are seen with their codes) while
/// other threads' terminals are detached but cached.
///
/// Threading: `@MainActor`. Re-renders from `ThreadTerminals` observation; `display` is idempotent.
@MainActor
public final class TerminalSurfaceController: NSViewController {
    public let placement: TerminalPlacement
    public private(set) var terminals: ThreadTerminals?
    public private(set) var directory: String?
    /// The surface shows a draft: no thread yet, "New Terminal" creates it (through the delegate).
    public private(set) var isDraft = false
    /// Called after the user changes the selection, split or tabs (the host may persist layout or refocus).
    public var onChange: (() -> Void)?

    private unowned let workspace: TerminalWorkspace
    private let tabStrip = TerminalTabStrip()
    private let newButton = DSButton(icon: "plus", accessibilityTitle: "New Terminal", size: .small)
    private let splitButton = DSButton(icon: "rectangle.split.2x1", accessibilityTitle: "Split Terminal", size: .small)
    private let messageLine = NSTextField(labelWithString: "")
    private let messageBar = NSStackView()
    private let content = NSView()
    private let splitView = TerminalSplitView()
    private let emptyState = TerminalEmptyState()
    private var observation: TerminalObservation?
    private var mounted: [TerminalPaneController] = []
    private var attached: Set<String> = []
    private var isCreatingThread = false
    private var messageBarCollapsed: NSLayoutConstraint?

    init(placement: TerminalPlacement, workspace: TerminalWorkspace) {
        self.placement = placement
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        observation?.cancel()
    }

    /// IDs of the terminals whose emulators are in this surface's view.
    var mountedIDs: [String] { mounted.map(\.terminalID) }

    // MARK: View

    public override func loadView() {
        let container = SurfaceBackgroundView()
        let header = NSView()
        let separator = DSDivider()
        separator.heightAnchor.constraint(equalToConstant: DS.Border.hairline).isActive = true
        configure(newButton, symbol: "plus", label: "New Terminal", toolTip: "New Terminal (⌘T)", action: #selector(newTerminalPressed))
        configure(splitButton, symbol: "rectangle.split.2x1", label: "Split Terminal", toolTip: "Split Terminal (⌘D)", action: #selector(splitPressed))
        splitButton.isHidden = placement != .drawer
        messageLine.font = DS.TextRole.label.font
        messageLine.textColor = DS.Color.text2
        messageLine.lineBreakMode = .byTruncatingTail
        let messageIcon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage())
        messageIcon.symbolConfiguration = .init(pointSize: DS.Size.iconPointRow, weight: .regular)
        messageIcon.contentTintColor = DS.Color.warningText
        messageBar.setViews([messageIcon, messageLine], in: .leading)
        messageBar.orientation = .horizontal
        messageBar.alignment = .centerY
        messageBar.spacing = DS.Space.s6
        messageBar.edgeInsets = NSEdgeInsets(top: 4, left: DS.Space.s12, bottom: 4, right: DS.Space.s12)
        messageBar.isHidden = true
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        emptyState.onNewTerminal = { [weak self] in self?.newTerminal() }
        tabStrip.placement = placement
        tabStrip.delegate = self

        let buttons = NSStackView(views: [splitButton, newButton])
        buttons.orientation = .horizontal
        buttons.spacing = DS.Space.s2
        for view in [tabStrip, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        for view in [header, separator, messageBar, content] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        for view in [splitView, emptyState] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        // The message line takes no space unless there is a message.
        messageBarCollapsed = messageBar.heightAnchor.constraint(equalToConstant: 0)
        messageBarCollapsed?.isActive = true
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: DS.Size.terminalTabStrip),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            messageBar.topAnchor.constraint(equalTo: separator.bottomAnchor),
            messageBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            messageBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: messageBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: DS.Space.s6),
            tabStrip.topAnchor.constraint(equalTo: header.topAnchor),
            tabStrip.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            tabStrip.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -DS.Space.s4),
            buttons.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -DS.Space.s6),
            buttons.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            splitView.topAnchor.constraint(equalTo: content.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyState.topAnchor.constraint(equalTo: content.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        container.setAccessibilityElement(false)
        container.setAccessibilityLabel(placement == .drawer ? "Terminal drawer" : "Terminal panel")
        view = container
        observation = TerminalObservation { [weak self] in self?.render() }
    }

    private func configure(_ button: DSButton, symbol: String, label: String, toolTip: String, action: Selector) {
        button.toolTip = toolTip
        button.target = self
        button.action = action
    }

    // MARK: Display

    /// Shows a thread's terminals (nil: no thread). `directory` is where new terminals start (the thread's directory
    /// or worktree). `isDraft`: the selection is a new-thread draft; "New Terminal" creates the thread first.
    public func display(_ terminals: ThreadTerminals?, directory: String?, isDraft: Bool = false) {
        self.directory = directory
        self.isDraft = isDraft
        guard terminals !== self.terminals else {
            render()
            return
        }
        for id in attached { workspace.existingPane(id)?.detach() }
        attached.removeAll()
        unmountAll()
        self.terminals = terminals
        _ = view
        // Track the new thread's model (the previous tracking read the old one).
        observation?.cancel()
        observation = TerminalObservation { [weak self] in self?.render() }
    }

    /// Rebuilds after a terminal was replaced (restart) or closed.
    func reload() {
        observation?.cancel()
        observation = TerminalObservation { [weak self] in self?.render() }
    }

    private func render() {
        guard isViewLoaded else { return }
        let signpost = TerminalKitSignposts.ui.beginInterval("render")
        defer { TerminalKitSignposts.ui.endInterval("render", signpost) }
        let records = terminals?.records(in: placement) ?? []
        let selectedID = terminals?.selected(in: placement) ?? records.first?.id
        let splitID = placement == .drawer ? terminals?.set.splitSecondary : nil
        let creating = (terminals?.creatingCount ?? 0) + (isCreatingThread ? 1 : 0)
        tabStrip.update(records: records, selectedID: selectedID, splitID: splitID, creating: creating)
        splitButton.isSelected = splitID != nil
        splitButton.isEnabled = !records.isEmpty
        newButton.isEnabled = directory != nil

        if let message = terminals?.lastError?.userMessage {
            messageLine.stringValue = message
            messageBar.isHidden = false
            messageBarCollapsed?.isActive = false
        } else if terminals?.isStale == true, !records.isEmpty {
            messageLine.stringValue = "opencode is not reachable: terminals reconnect when it is back."
            messageBar.isHidden = false
            messageBarCollapsed?.isActive = false
        } else {
            messageBar.isHidden = true
            messageBarCollapsed?.isActive = true
        }

        // Every running terminal of the displayed thread stays attached (its exit code is only on the socket).
        if let terminals {
            let running = records.filter { $0.state.isRunning }
            for record in running where !attached.contains(record.id) {
                workspace.pane(for: record, in: terminals).attach()
                attached.insert(record.id)
            }
            let ids = Set(records.map(\.id))
            for id in attached where !ids.contains(id) { workspace.existingPane(id)?.detach() }
            attached.formIntersection(running.map(\.id))
        }

        var wanted: [TerminalPaneController] = []
        if let terminals, let selectedID, let record = terminals.record(selectedID), record.placement == placement {
            wanted.append(workspace.pane(for: record, in: terminals))
            if let splitID, splitID != selectedID, let second = terminals.record(splitID), second.placement == placement {
                wanted.append(workspace.pane(for: second, in: terminals))
            }
        }
        mount(wanted)

        emptyState.isHidden = !wanted.isEmpty
        splitView.isHidden = wanted.isEmpty
        if wanted.isEmpty {
            if directory == nil {
                emptyState.show(title: "No thread selected", detail: "Select a thread to see its terminals.", action: nil)
            } else if creating > 0 {
                emptyState.show(title: "Starting terminal…", detail: directory.map(Self.abbreviate), action: nil)
            } else if isDraft || terminals == nil {
                emptyState.show(
                    title: "No terminals yet", detail: "Terminals belong to a thread. New Terminal starts this thread.",
                    action: "New Terminal")
            } else {
                emptyState.show(
                    title: "No terminals in this thread", detail: directory.map { "Opens in \(Self.abbreviate($0))" },
                    action: "New Terminal")
            }
        }
    }

    private static func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private func mount(_ panes: [TerminalPaneController]) {
        guard panes.map(\.terminalID) != mounted.map(\.terminalID) || panes.contains(where: { $0.view.superview !== splitView }) else {
            return
        }
        let focusWasInside = view.window.map { window in
            mounted.contains { pane in (window.firstResponder as? NSView)?.isDescendant(of: pane.view) == true }
        } ?? false
        unmountAll()
        for pane in panes {
            if pane.parent != nil { pane.removeFromParent() }
            pane.view.removeFromSuperview()
            addChild(pane)
            splitView.addArrangedSubview(pane.view)
        }
        mounted = panes
        splitView.needsEqualWidths = true
        splitView.needsLayout = true
        for pane in panes { pane.sendSizeIfVisible() }
        if focusWasInside { panes.first?.focus() }
    }

    private func unmountAll() {
        for pane in mounted where pane.parent === self {
            pane.view.removeFromSuperview()
            pane.removeFromParent()
        }
        mounted.removeAll()
    }

    // MARK: Focus and selection

    /// The pane with keyboard focus, else the selected one.
    public var activePane: TerminalPaneController? {
        if let responder = view.window?.firstResponder as? NSView,
            let focused = mounted.first(where: { responder.isDescendant(of: $0.view) })
        {
            return focused
        }
        return mounted.first
    }

    /// The view to focus for this surface (the selected terminal).
    public var preferredFocusView: NSView? { activePane?.terminalView }

    /// Whether keyboard focus is in one of this surface's terminals.
    public var containsFocus: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    public var selectedRecord: TerminalRecord? { activePane?.record }
    public var hasTerminals: Bool { !(terminals?.records(in: placement).isEmpty ?? true) }

    public func focus() { activePane?.focus() }

    // MARK: Commands

    /// Starts a terminal in the thread's directory (creating the thread first for a draft) and focuses it.
    public func newTerminal() {
        guard let directory else { return NSSound.beep() }
        let size = estimatedSize()
        Task {
            var terminals = self.terminals
            if terminals == nil || isDraft {
                isCreatingThread = true
                render()
                terminals = await workspace.delegate?.terminalWorkspaceNeedsThread(workspace)
                isCreatingThread = false
                guard let terminals else { return render() }
                display(terminals, directory: self.directory ?? directory, isDraft: false)
            }
            guard let terminals else { return }
            if let record = await terminals.create(directory: self.directory ?? directory, placement: placement, size: size) {
                render()
                workspace.existingPane(record.id)?.focus()
                onChange?()
            }
        }
    }

    public func closeSelected() {
        guard let terminals, let id = activePane?.terminalID else { return NSSound.beep() }
        Task { await workspace.close(id, in: terminals) }
        onChange?()
    }

    public func selectAdjacent(_ offset: Int) {
        guard let terminals else { return }
        terminals.selectAdjacent(offset, in: placement)
        render()
        focus()
    }

    /// Splits the drawer side by side (with the next terminal, or a new one), or un-splits it.
    public func toggleSplit() {
        guard placement == .drawer, let terminals else { return }
        if terminals.set.splitSecondary != nil {
            terminals.setSplit(nil)
            render()
            return
        }
        let records = terminals.records(in: .drawer)
        let selected = terminals.selected(in: .drawer)
        if let other = records.first(where: { $0.id != selected }) {
            terminals.setSplit(other.id)
            render()
        } else if let directory {
            let size = estimatedSize(halfWidth: true)
            Task {
                let previous = terminals.selected(in: .drawer)
                guard let record = await terminals.create(directory: directory, placement: .drawer, size: size) else { return }
                if let previous {
                    terminals.select(previous, in: .drawer)
                    terminals.setSplit(record.id)
                }
                render()
                workspace.existingPane(record.id)?.focus()
            }
        }
        onChange?()
    }

    public func clearSelected() { activePane?.clear() }
    public func showFind() { activePane?.showFind(useSelection: false) }
    public func sendSelectionToComposer() { activePane?.sendSelectionToComposer() }
    public var selectedText: String? { activePane?.selectedText }

    public func renameSelected() {
        guard let id = activePane?.terminalID else { return }
        tabStrip.beginRename(id)
    }

    public func restartSelected() {
        guard let pane = activePane else { return }
        pane.restart()
    }

    /// Moves the selected terminal to the other place (drawer ⇄ right panel).
    public func moveSelectedToOtherPlace() {
        guard let terminals, let id = activePane?.terminalID else { return }
        move(id, in: terminals)
    }

    private func move(_ id: String, in terminals: ThreadTerminals) {
        let target: TerminalPlacement = placement == .drawer ? .panel : .drawer
        if let pane = workspace.existingPane(id), pane.parent === self {
            pane.view.removeFromSuperview()
            pane.removeFromParent()
            mounted.removeAll { $0 === pane }
        }
        terminals.setPlacement(id, target)
        render()
        onChange?()
    }

    /// The grid a new terminal will get in this surface (corrected after layout by a resize).
    private func estimatedSize(halfWidth: Bool = false) -> PTYSize? {
        let bounds = content.bounds
        guard bounds.width > 40, bounds.height > 20 else { return nil }
        let font = workspace.preferences.font
        let cellWidth = max(1, ("W" as NSString).size(withAttributes: [.font: font]).width)
        let cellHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        let width = (halfWidth ? bounds.width / 2 : bounds.width) - 6
        return PTYSize(cols: max(2, Int(width / cellWidth)), rows: max(1, Int(bounds.height / cellHeight)))
    }

    @objc private func newTerminalPressed() { newTerminal() }
    @objc private func splitPressed() { toggleSplit() }
}

extension TerminalSurfaceController: TerminalTabStripDelegate {
    func tabStrip(_ strip: TerminalTabStrip, select id: String) {
        terminals?.select(id, in: placement)
        render()
        workspace.existingPane(id)?.focus()
        onChange?()
    }

    func tabStrip(_ strip: TerminalTabStrip, close id: String) {
        guard let terminals else { return }
        Task { await workspace.close(id, in: terminals) }
        onChange?()
    }

    func tabStrip(_ strip: TerminalTabStrip, rename id: String, to title: String?) {
        guard let terminals else { return }
        Task { await terminals.rename(id, to: title) }
    }

    func tabStrip(_ strip: TerminalTabStrip, move id: String, to index: Int) {
        terminals?.move(id, to: index)
        render()
        onChange?()
    }

    func tabStrip(_ strip: TerminalTabStrip, split id: String) {
        guard let terminals else { return }
        if terminals.selected(in: .drawer) == id { toggleSplit() } else { terminals.setSplit(id) }
        render()
        onChange?()
    }

    func tabStrip(_ strip: TerminalTabStrip, unsplit id: String) {
        terminals?.setSplit(nil)
        render()
        onChange?()
    }

    func tabStrip(_ strip: TerminalTabStrip, moveToOtherPlace id: String) {
        guard let terminals else { return }
        move(id, in: terminals)
    }

    func tabStrip(_ strip: TerminalTabStrip, restart id: String) {
        guard let terminals else { return }
        Task { await workspace.restart(id, in: terminals, size: estimatedSize()) }
    }

    func tabStripNewTerminal(_ strip: TerminalTabStrip) { newTerminal() }
}

/// "No terminals in this thread" with one "New Terminal" action: the DS empty-state recipe (32 pt glyph `text4`,
/// `body` title, `label text2` hint, one outline button).
@MainActor
final class TerminalEmptyState: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let button = DSButton(title: "New Terminal", variant: .outline, size: .small, shortcutHint: "⌘T")
    var onNewTerminal: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
        icon.contentTintColor = DS.Color.text4
        title.font = DS.TextRole.bodyEmph.font
        title.textColor = DS.Color.text
        detail.font = DS.TextRole.label.font
        detail.textColor = DS.Color.text2
        detail.alignment = .center
        detail.maximumNumberOfLines = 2
        button.target = self
        button.action = #selector(pressed)
        button.toolTip = "New Terminal (⌘T)"
        let stack = NSStackView(views: [icon, title, detail, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = DS.Space.s6
        stack.setCustomSpacing(DS.Space.s10, after: icon)
        stack.setCustomSpacing(DS.Space.s14, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: DS.Space.s24),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(title: String, detail: String?, action: String?) {
        self.title.stringValue = title
        self.detail.stringValue = detail ?? ""
        self.detail.isHidden = detail == nil
        button.isHidden = action == nil
        if let action {
            button.title = action
            button.shortcutHint = action == "New Terminal" ? "⌘T" : nil
        }
    }

    @objc private func pressed() { onNewTerminal?() }
}

/// The surface's root view: the solid `canvas` (the terminal is a docked surface, visual-language.md §4), so the
/// drawer, its tab strip and the emulator read as one region; snapshots taken with `cacheDisplay` include it.
@MainActor
final class SurfaceBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        DS.Color.canvas.setFill()
        dirtyRect.fill()
    }
}

/// Side-by-side panes. After the panes change it fits them to its width in equal parts on its next layout (a pane
/// moved from another surface keeps its old frame until then); later divider drags are the user's.
@MainActor
final class TerminalSplitView: NSSplitView {
    var needsEqualWidths = false
    override var dividerColor: NSColor { DS.Color.border }

    override func layout() {
        super.layout()
        guard needsEqualWidths, bounds.width > 0 else { return }
        needsEqualWidths = false
        let count = arrangedSubviews.count
        guard count > 0 else { return }
        let available = bounds.width - dividerThickness * CGFloat(count - 1)
        var x: CGFloat = 0
        for view in arrangedSubviews {
            let width = (available / CGFloat(count)).rounded()
            view.frame = NSRect(x: x, y: 0, width: view === arrangedSubviews.last ? bounds.width - x : width, height: bounds.height)
            x += width + dividerThickness
        }
        adjustSubviews()
    }
}
