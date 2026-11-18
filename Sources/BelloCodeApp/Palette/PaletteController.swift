import AppKit
import BelloCore
import DesignSystem
import Engine
import os

/// The palette's window: a borderless floating panel that can become key (so the field types), with no open/close
/// animation (instant), closed when it loses key status.
@MainActor
final class PalettePanel: NSPanel {
    var onCommandReturn: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘↩: open in the background.
        if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// ⌘K command palette, ⌘P quick open and ⇧⌘F message search: one keyboard-first panel per window.
///
/// Local results (commands, threads, projects) come from the cache, prepared once per opening and ranked on every
/// keystroke on the main actor (well under a frame for 2,000 threads; measured in tests). Files and messages come
/// from the server's file search and the engine's FTS index off the main actor, debounced; earlier results stay
/// (filtered locally) until newer ones arrive, so the list never flickers, and nothing shows a spinner. Return opens,
/// ⌘↩ opens in the background (a new window behind, the file without switching apps, an action without closing),
/// Escape closes and returns focus to where it was.
@MainActor
final class PaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    enum Row: Equatable {
        case header(String)
        case item(PaletteItem)
    }

    let panel: PalettePanel
    let field = NSTextField()
    let table = NSTableView()
    private let scrollView = NSScrollView()
    /// The scope pill at the input's trailing edge ("All", "Threads", "Messages").
    private let modeLabel = DSPill("All")
    /// Key-cap hints, or a status / reason when there is one.
    let footer = PaletteFooterView()
    private let background = DSGlassView(surface: .popover, radius: DS.Radius.xl)
    /// Dims the window behind the palette (instant; removed on close).
    private let scrim = PaletteScrimView()
    private weak var window: MainWindowController?
    private(set) var mode: PaletteMode = .commands
    private var sources = PaletteSources()
    private(set) var rows: [Row] = []
    private var selectedRow = -1
    private var fileTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var messageGroups: [ThreadSearchGroup] = []
    private var messageQuery = ""
    private var fileQueryDirectory: String?
    private var previousResponder: NSResponder?
    private weak var previousWindow: NSWindow?
    private var status: String?
    /// Measured: show() to results on screen, and the last keystroke to results (milliseconds).
    private(set) var lastOpenMilliseconds = 0.0
    private(set) var lastQueryMilliseconds = 0.0
    /// Work counters (tests assert on these, not on timings): source snapshots built (once per open, never per
    /// keystroke) and items listed by the last local refresh.
    private(set) var sourceBuilds = 0
    private(set) var lastRankedItems = 0

    static let width: CGFloat = DS.Size.paletteWidth
    static let maxListHeight: CGFloat = 380
    static let fieldHeight: CGFloat = DS.Size.paletteInput
    static let footerHeight: CGFloat = DS.Size.paletteFooter

    override init() {
        panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200), styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        build()
    }

    var isVisible: Bool { panel.isVisible }

    private func build() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.onCommandReturn = { [weak self] in self?.activateSelection(background: true) }
        panel.setAccessibilityLabel("Command palette")

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: DS.Typography.current.baseSize + 2)
        field.textColor = DS.Color.text
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Search")
        field.translatesAutoresizingMaskIntoConstraints = false

        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        modeLabel.setContentHuggingPriority(.required, for: .horizontal)
        modeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.floatsGroupRows = false
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        // Neutral highlight drawn by `PaletteRowView` (never the accent).
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.refusesFirstResponder = true
        table.setAccessibilityLabel("Results")
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: DS.Space.s4, left: 0, bottom: DS.Space.s6, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        DSScroller.install(on: scrollView)

        footer.translatesAutoresizingMaskIntoConstraints = false

        let separator = DSDivider()
        separator.translatesAutoresizingMaskIntoConstraints = false
        let icon = ProjectIcon()
        icon.symbolName = "magnifyingglass"
        icon.tint = DS.Color.text3
        icon.translatesAutoresizingMaskIntoConstraints = false

        let content = background.contentView
        for subview in [icon, field, modeLabel, separator, scrollView, footer] as [NSView] { content.addSubview(subview) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DS.Space.s16),
            icon.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight / 2),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: DS.Space.s10),
            field.trailingAnchor.constraint(equalTo: modeLabel.leadingAnchor, constant: -DS.Space.s8),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            modeLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -DS.Space.s16),
            modeLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            separator.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: DS.Border.hairline),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
        ])
        background.showsShadow = false
        panel.contentView = background
    }

    // MARK: - Showing

    /// Opens (or switches the mode of) the palette over `window`, with `query` typed.
    func show(_ mode: PaletteMode, in window: MainWindowController, query: String = "") {
        let start = ContinuousClock.now
        let signpost = ShellSignposts.palette.beginInterval("paletteOpen")
        defer { ShellSignposts.palette.endInterval("paletteOpen", signpost) }
        if !panel.isVisible {
            previousWindow = window.window
            previousResponder = window.window?.firstResponder
        }
        self.window = window
        self.mode = mode
        sources = PaletteSourceBuilder.build(window: window)
        sourceBuilds += 1
        messageGroups = []
        messageQuery = ""
        status = nil
        fileQueryDirectory = currentDirectory
        field.placeholderString = mode.placeholder
        field.stringValue = query
        refresh(selectFirst: true)
        position(over: window.window)
        let host = window.root.view
        if scrim.superview !== host {
            scrim.frame = host.bounds
            scrim.autoresizingMask = [.width, .height]
            host.addSubview(scrim)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (query as NSString).length, length: 0)
        lastOpenMilliseconds = Self.milliseconds(since: start)
    }

    /// Closes the palette; with `restoreFocus`, the window and view that had focus get it back.
    func hide(restoreFocus: Bool = true) {
        guard panel.isVisible else { return }
        fileTask?.cancel()
        messageTask?.cancel()
        panel.orderOut(nil)
        scrim.removeFromSuperview()
        if restoreFocus, let previousWindow {
            previousWindow.makeKeyAndOrderFront(nil)
            if let previousResponder, previousResponder.isInResponderChain(of: previousWindow) {
                previousWindow.makeFirstResponder(previousResponder)
            }
        }
        previousResponder = nil
    }

    /// Re-centres over the window (after it moved or resized).
    func reposition() { position(over: window?.window) }

    private func position(over window: NSWindow?) {
        let height = panelHeight()
        guard let frame = window?.frame ?? NSScreen.main?.visibleFrame else { return }
        let x = frame.midX - Self.width / 2
        let y = frame.maxY - DS.Size.paletteTop - height
        panel.setFrame(NSRect(x: x, y: y, width: Self.width, height: height), display: true, animate: false)
    }

    private func panelHeight() -> CGFloat {
        let list = rows.indices.reduce(CGFloat(0)) { $0 + rowHeight($1) }
        return Self.fieldHeight + DS.Border.hairline + min(max(list, 36), Self.maxListHeight) + DS.Space.s10 + Self.footerHeight
    }

    private var currentDirectory: String? {
        guard let window else { return nil }
        return window.container.context?.projectDirectory
            ?? window.workspace.target(for: window.workspace.selection).flatMap(window.workspace.projectDirectory(for:))
            ?? window.workspace.engine.root.projects.first?.directory
    }

    // MARK: - Query

    /// Sets the query as if typed (tests, measurements).
    func setQuery(_ text: String) {
        field.stringValue = text
        queryChanged()
    }

    func controlTextDidChange(_ notification: Notification) { queryChanged() }

    private func queryChanged() {
        let start = ContinuousClock.now
        let signpost = ShellSignposts.palette.beginInterval("paletteQuery")
        refresh(selectFirst: false)
        ShellSignposts.palette.endInterval("paletteQuery", signpost)
        lastQueryMilliseconds = Self.milliseconds(since: start)
        position(over: window?.window)
    }

    var query: PaletteQuery { PaletteQuery.parse(field.stringValue, mode: mode) }

    /// Recomputes rows from local sources (synchronous) and schedules server searches.
    private func refresh(selectFirst: Bool) {
        guard let window else { return }
        let query = self.query
        let previousSelection = selectedItem?.id
        let sections: [PaletteSection]
        if mode == .messages {
            sections = messageSections(for: query.text)
            scheduleMessageSearch(query.text)
        } else {
            sections = PaletteSearch.results(
                query, mode: mode, sources: sources, frecency: window.workspace.engine.frecency.index, now: .now)
            if (mode == .quickOpen && query.scope == .all) || query.scope == .files { scheduleFileSearch(query.text) }
        }
        rows = sections.flatMap { [Row.header($0.title)] + $0.items.map(Row.item) }
        lastRankedItems = sections.reduce(0) { $0 + $1.items.count }
        modeLabel.title = mode == .messages ? "Messages" : (query.scope == .all ? "All" : query.scope.title)
        table.reloadData()
        // Keep the selected item while typing when it is still listed; else the first enabled one.
        let keep = selectFirst ? nil : previousSelection.flatMap { id in rows.firstIndex { if case .item(let item) = $0 { item.id == id } else { false } } }
        select(keep ?? firstSelectableRow())
        updateFooter()
    }

    private func firstSelectableRow() -> Int {
        rows.firstIndex { if case .item(let item) = $0 { item.isEnabled } else { false } }
            ?? rows.firstIndex { if case .item = $0 { true } else { false } } ?? -1
    }

    private func messageSections(for text: String) -> [PaletteSection] {
        guard let window else { return [] }
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return PaletteSearch.emptyResults(.threads, mode: .quickOpen, sources: sources, frecency: window.workspace.engine.frecency.index, now: .now)
                .map { PaletteSection(title: $0.title == "Recent" ? "Recent Threads" : $0.title, items: Array($0.items.prefix(8))) }
        }
        let names = Dictionary((window.workspace.engine.root.projects).map { ($0.directory, $0.name) }, uniquingKeysWith: { a, _ in a })
        return PaletteSearch.messageSections(
            messageGroups, projectName: { directory in names[directory] ?? WorkspaceController.name(of: directory) }, now: Date())
    }

    private func scheduleFileSearch(_ text: String) {
        fileTask?.cancel()
        guard let window, let directory = currentDirectory, !text.isEmpty else { return }
        let engine = window.workspace.engine
        fileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            do {
                let paths = try await engine.findFiles(directory: directory, query: text, limit: 40)
                guard !Task.isCancelled, let self, self.panel.isVisible, self.query.text == text else { return }
                self.sources.files = PaletteSourceBuilder.fileItems(paths, directory: directory)
                self.status = nil
                self.refresh(selectFirst: false)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.status = "Files are unavailable: \((error as? EngineError)?.userMessage ?? "the server did not answer")"
                self.updateFooter()
            }
        }
    }

    private func scheduleMessageSearch(_ text: String) {
        messageTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let window, !trimmed.isEmpty, trimmed != messageQuery else { return }
        let engine = window.workspace.engine
        status = "Searching…"
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let groups = (try? await engine.searchMessages(trimmed)) ?? []
            guard !Task.isCancelled, let self, self.panel.isVisible, self.query.text.trimmingCharacters(in: .whitespaces) == trimmed else { return }
            let hidden = self.window?.workspace.hiddenThreads ?? []
            self.messageGroups = groups.filter { !hidden.contains($0.sessionID) }
            self.messageQuery = trimmed
            self.status = groups.isEmpty ? "No messages match “\(trimmed)”" : nil
            self.refresh(selectFirst: true)
            self.position(over: self.window?.window)
        }
    }

    /// Waits for pending server searches (tests).
    func settleSearches() async {
        await fileTask?.value
        await messageTask?.value
    }

    private func updateFooter() {
        var parts: [String] = []
        if let status { parts.append(status) }
        if let item = selectedItem, let reason = item.disabledReason { parts.append(reason) }
        let hints: [(String, String)] = switch selectedItem?.kind {
        case .command: [("↑↓", "Navigate"), ("↩", "Run"), ("⌘↩", "Run and keep open")]
        case .file: [("↑↓", "Navigate"), ("↩", "Open"), ("⌘↩", "Open in background")]
        case .thread, .project, .message: [("↑↓", "Navigate"), ("↩", "Open"), ("⌘↩", "Open in new window")]
        case .todo: [("↑↓", "Navigate"), ("↩", "Open")]
        case nil: mode == .commands ? [(">", "Actions"), ("@", "Threads"), ("#", "Projects"), ("/", "Files"), ("+", "To-dos")] : []
        }
        if parts.isEmpty, mode == .quickOpen, let directory = currentDirectory, query.scope != .threads, query.scope != .projects {
            parts.append("Files in \(WorkspaceController.name(of: directory))")
        }
        footer.update(message: parts.joined(separator: "   "), hints: parts.isEmpty || selectedItem?.disabledReason == nil ? hints : [])
    }

    // MARK: - Selection and activation

    var selectedItem: PaletteItem? {
        guard rows.indices.contains(selectedRow), case .item(let item) = rows[selectedRow] else { return nil }
        return item
    }

    private func select(_ row: Int) {
        selectedRow = row
        if row >= 0 {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        updateFooter()
        if let item = selectedItem {
            NSAccessibility.post(
                element: field, notification: .announcementRequested,
                userInfo: [.announcement: item.title + (item.disabledReason.map { ", unavailable: \($0)" } ?? ""), .priority: NSAccessibilityPriorityLevel.low.rawValue])
        }
    }

    func moveSelection(by step: Int) {
        guard !rows.isEmpty else { return }
        var row = selectedRow
        for _ in 0..<rows.count {
            row = (row + step + rows.count) % rows.count
            if case .item = rows[row] { break }
        }
        select(row)
    }

    @objc private func clicked(_ sender: Any?) {
        let row = table.clickedRow
        guard rows.indices.contains(row), case .item = rows[row] else { return }
        select(row)
        activateSelection(background: NSEvent.modifierFlags.contains(.command))
    }

    /// Opens the selected item (Return), or opens it in the background (⌘↩).
    func activateSelection(background: Bool = false) {
        guard let item = selectedItem, let window else { return NSSound.beep() }
        guard item.isEnabled else {
            NSSound.beep()
            updateFooter()
            return
        }
        let workspace = window.workspace
        workspace.engine.frecency.record(item.id, query: query.text)
        switch item.payload {
        case .command(let command):
            if background {
                window.perform(command)
                sources = PaletteSourceBuilder.build(window: window)
                refresh(selectFirst: false)
            } else {
                hide()
                window.perform(command)
            }
        case .thread(let id):
            if background {
                (NSApp.delegate as? AppDelegate)?.openWindow(selection: .thread(id), background: true)
            } else {
                hide()
                workspace.select(.thread(id))
            }
        case .project(let directory, let archived):
            if archived { Task { await workspace.engine.addProject(directory: directory) } }
            if background {
                (NSApp.delegate as? AppDelegate)?.openWindow(selection: .draft(directory: directory), background: true)
            } else {
                hide()
                workspace.select(.draft(directory: directory))
                window.focusComposerSoon()
            }
        case .file(let directory, let path):
            let url = URL(filePath: directory).appending(path: path)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = !background
            if !background { hide(restoreFocus: false) }
            NSWorkspace.shared.open(url, configuration: configuration)
        case .todo(let instance, let id):
            hide()
            window.openTodo(instance: instance, id: id)
        case .message(_, let session, let message):
            let reveal = PendingReveal(sessionID: session, messageID: message, query: query.text)
            if background {
                (NSApp.delegate as? AppDelegate)?.openWindow(selection: .thread(session), background: true, reveal: reveal)
            } else {
                hide()
                window.reveal(reveal)
            }
        }
    }

    // MARK: - NSTextFieldDelegate (keys while typing)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): moveSelection(by: 8)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): moveSelection(by: -8)
        case #selector(NSResponder.insertNewline(_:)): activateSelection(background: false)
        case #selector(NSResponder.cancelOperation(_:)):
            if !field.stringValue.isEmpty, mode != .commands || field.stringValue != ">" {
                setQuery("")
            } else {
                hide()
            }
        default: return false
        }
        return true
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere closes it; focus goes where the click went.
        if panel.isVisible { hide(restoreFocus: false) }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight(row) }

    private func rowHeight(_ row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 0 }
        switch rows[row] {
        case .header: return 28
        case .item: return DS.Size.paletteRow
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow != selectedRow, table.selectedRow >= 0 {
            selectedRow = table.selectedRow
            updateFooter()
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = tableView.makeView(withIdentifier: PaletteHeaderCell.identifier, owner: nil) as? PaletteHeaderCell ?? PaletteHeaderCell()
            cell.label.stringValue = title
            return cell
        case .item(let item):
            let cell = tableView.makeView(withIdentifier: PaletteItemCell.identifier, owner: nil) as? PaletteItemCell ?? PaletteItemCell()
            cell.configure(item)
            return cell
        }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }
}

extension NSResponder {
    /// Whether this responder is still in `window` (a view that was removed is not).
    @MainActor func isInResponderChain(of window: NSWindow) -> Bool {
        if self === window { return true }
        if let view = self as? NSView { return view.window === window }
        return true
    }
}

/// A palette row's background: the neutral highlight (`highlight`: `text` 9 % dark / 6 % light), `r.md`, inset 6
/// from the panel's edges. Never the accent colour (visual-language.md §6 "Command palette").
@MainActor
final class PaletteRowView: NSTableRowView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isSelected: Bool { didSet { if isSelected != oldValue { needsDisplay = true } } }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        DSDraw.fill(bounds.insetBy(dx: DS.Space.s6, dy: 0), radius: DS.Radius.md, color: DS.Color.highlight)
    }

    /// Row content stays `text` on the neutral highlight.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// A group label ("Threads", "Files", "Actions"): `meta` medium `text3`, 28 high.
@MainActor
final class PaletteHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("paletteHeader")
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = DS.TextRole.metaEmph.font
        label.textColor = DS.Color.text3
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.s16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Space.s16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DS.Space.s6),
        ])
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A result row (34), drawn in one pass: 14 pt glyph `icon`, title `body` (match ranges `text` semibold, the rest
/// `text2` while a query matches), subtitle `label text3`, and at the trailing edge the shortcut as key caps (or
/// "Unavailable" in `text4`). Accessibility: one label with title, subtitle, shortcut and the unavailable reason.
@MainActor
final class PaletteItemCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("paletteItem")
    private(set) var item: PaletteItem?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(_ item: PaletteItem) {
        self.item = item
        var label = item.title
        if let subtitle = item.subtitle { label += ", \(subtitle)" }
        if let shortcut = item.shortcut, !shortcut.isEmpty { label += ", \(shortcut)" }
        if let reason = item.disabledReason { label += ", unavailable: \(reason)" }
        setAccessibilityLabel(label)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    /// The title with its matched characters in `text` semibold (the rest `text2` while a query matches).
    static func titleString(_ item: PaletteItem) -> NSAttributedString {
        let font = DS.TextRole.body.font
        let bold = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        if let snippet = item.snippet {
            return MatchHighlight.attributed(
                snippet.text, positions: snippet.highlights.flatMap { Array($0) }, font: font, color: DS.Color.text2,
                highlightColor: DS.Color.text, highlightFont: bold)
        }
        guard item.isEnabled else {
            return NSAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: DS.Color.text3])
        }
        if item.titleMatches.isEmpty {
            return NSAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: DS.Color.text])
        }
        return MatchHighlight.attributed(item.title, positions: item.titleMatches, font: font, color: DS.Color.text2, highlightColor: DS.Color.text, highlightFont: bold)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let inset = DS.Space.s6 + DS.Space.s10
        if let image = DSDraw.symbol(item.symbolName, pointSize: DS.Size.iconPointRow) {
            DSDraw.draw(template: image, in: NSRect(x: inset, y: 0, width: 16, height: bounds.height), color: DS.Color.icon)
        }
        var right = bounds.width - inset
        if item.disabledReason != nil {
            let font = DS.TextRole.meta.font
            let width = ceil(DSDraw.width(of: "Unavailable", font: font)) + 1
            DSDraw.text("Unavailable", in: NSRect(x: right - width, y: 0, width: width, height: bounds.height), font: font, color: DS.Color.text4)
            right -= width + DS.Space.s12
        } else if let shortcut = item.shortcut, !shortcut.isEmpty {
            let width = PaletteKeyCaps.width(shortcut)
            PaletteKeyCaps.draw(shortcut, at: NSPoint(x: right - width, y: (bounds.height - DS.Size.kbd) / 2))
            right -= width + DS.Space.s12
        }
        let titleX = inset + 16 + DS.Space.s10
        let title = Self.titleString(item)
        let titleWidth = min(ceil(title.size().width) + 1, right - titleX)
        let lineHeight = ceil(DS.TextRole.body.font.ascender - DS.TextRole.body.font.descender)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let titleText = NSMutableAttributedString(attributedString: title)
        titleText.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: titleText.length))
        titleText.draw(with: NSRect(x: titleX, y: (bounds.height - lineHeight) / 2, width: max(0, titleWidth), height: lineHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            let x = titleX + titleWidth + DS.Space.s8
            let font = DS.TextRole.label.font
            let subStyle = NSMutableParagraphStyle()
            subStyle.lineBreakMode = .byTruncatingMiddle
            let height = ceil(font.ascender - font.descender)
            NSAttributedString(string: subtitle, attributes: [.font: font, .foregroundColor: DS.Color.text3, .paragraphStyle: subStyle])
                .draw(with: NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, right - x), height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Key caps drawn inline ("⇧⌘D" as one cap, as in the mock): 18 high, `r.xs`, `kbdFill`, `metaEmph text2`.
@MainActor
enum PaletteKeyCaps {
    static var font: NSFont { DS.TextRole.metaEmph.font }

    static func width(_ keys: String) -> CGFloat {
        max(DS.Size.kbd, ceil(DSDraw.width(of: keys, font: font)) + 10)
    }

    @discardableResult
    static func draw(_ keys: String, at origin: NSPoint) -> CGFloat {
        let width = width(keys)
        let rect = NSRect(x: origin.x, y: origin.y, width: width, height: DS.Size.kbd)
        DSDraw.fill(rect, radius: DS.Radius.xs, color: DS.Color.kbdFill)
        DSDraw.text(keys, in: rect, font: font, color: DS.Color.text2, alignment: .center)
        return width
    }
}

/// The palette's footer (38): `text` 2.5 % fill, a `border` top line, and key-cap hints ("↑↓ Navigate  ↩ Open …
/// esc Close"); a status or the selected command's unavailable reason replaces the hints' left part.
@MainActor
final class PaletteFooterView: NSView {
    private(set) var message = ""
    private(set) var hints: [(String, String)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The footer's text as one string (VoiceOver, tests).
    var stringValue: String {
        ([message].filter { !$0.isEmpty } + hints.map { "\($0.0) \($0.1)" } + ["esc Close"]).joined(separator: "   ")
    }

    func update(message: String, hints: [(String, String)]) {
        self.message = message
        self.hints = hints
        setAccessibilityLabel(stringValue)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = DS.Variant(effectiveAppearance).isDark
        DS.Color.text.withAlphaComponent(dark ? 0.025 : 0.02).setFill()
        bounds.fill(using: .sourceOver)
        DS.Color.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: DS.Border.hairline).fill(using: .sourceOver)
        let label = DS.TextRole.label.font
        let capY = (bounds.height - DS.Size.kbd) / 2
        var x = DS.Space.s16
        if !message.isEmpty {
            let width = min(ceil(DSDraw.width(of: message, font: label)) + 1, bounds.width - 120)
            DSDraw.text(message, in: NSRect(x: x, y: 0, width: width, height: bounds.height), font: label, color: DS.Color.text2)
            x += width + DS.Space.s16
        }
        for (keys, title) in hints {
            let titleWidth = ceil(DSDraw.width(of: title, font: label)) + 1
            guard x + PaletteKeyCaps.width(keys) + DS.Space.s6 + titleWidth < bounds.width - 90 else { break }
            x += PaletteKeyCaps.draw(keys, at: NSPoint(x: x, y: capY)) + DS.Space.s6
            DSDraw.text(title, in: NSRect(x: x, y: 0, width: titleWidth, height: bounds.height), font: label, color: DS.Color.text2)
            x += titleWidth + DS.Space.s16
        }
        let closeWidth = ceil(DSDraw.width(of: "Close", font: label)) + 1
        let right = bounds.width - DS.Space.s16
        DSDraw.text("Close", in: NSRect(x: right - closeWidth, y: 0, width: closeWidth, height: bounds.height), font: label, color: DS.Color.text2)
        PaletteKeyCaps.draw("esc", at: NSPoint(x: right - closeWidth - DS.Space.s6 - PaletteKeyCaps.width("esc"), y: capY))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Dims the main window while the palette is open (`scrim`: canvas 64 % dark / 60 % light). Instant, no blur (an
/// effect view per opening would cost the "instant open" budget); clicks fall through to close the palette.
@MainActor
final class PaletteScrimView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        DS.Color.scrim.setFill()
        dirtyRect.fill(using: .sourceOver)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
