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
    private let modeLabel = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let background = NSVisualEffectView()
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

    static let width: CGFloat = 640
    static let maxListHeight: CGFloat = 380
    static let fieldHeight: CGFloat = 50
    static let footerHeight: CGFloat = 26

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

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Search")
        field.translatesAutoresizingMaskIntoConstraints = false

        modeLabel.font = DS.Typography.current.captionEmphasized
        modeLabel.textColor = DS.Palette.secondaryText
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        modeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.floatsGroupRows = false
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
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
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        footer.font = DS.Typography.current.caption
        footer.textColor = DS.Palette.tertiaryText
        footer.lineBreakMode = .byTruncatingTail
        footer.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.contentTintColor = DS.Palette.secondaryText
        icon.translatesAutoresizingMaskIntoConstraints = false

        for subview in [icon, field, modeLabel, separator, scrollView, footer] { background.addSubview(subview) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: background.topAnchor, constant: Self.fieldHeight / 2),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: modeLabel.leadingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            modeLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            modeLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            separator.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.fieldHeight),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -2),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
            footer.heightAnchor.constraint(equalToConstant: 16),
        ])
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
        messageGroups = []
        messageQuery = ""
        status = nil
        fileQueryDirectory = currentDirectory
        field.placeholderString = mode.placeholder
        field.stringValue = query
        refresh(selectFirst: true)
        position(over: window.window)
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
        let y = frame.maxY - 86 - height
        panel.setFrame(NSRect(x: x, y: y, width: Self.width, height: height), display: true, animate: false)
    }

    private func panelHeight() -> CGFloat {
        let list = rows.indices.reduce(CGFloat(0)) { $0 + rowHeight($1) }
        return Self.fieldHeight + min(max(list, 36), Self.maxListHeight) + Self.footerHeight + 4
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
        modeLabel.stringValue = mode == .messages ? "Messages" : (query.scope == .all ? (mode == .commands ? "Commands" : "Quick Open") : query.scope.title)
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
        let hints: String = switch selectedItem?.kind {
        case .command: "↩ Run · ⌘↩ Run and keep open · esc Close"
        case .file: "↩ Open · ⌘↩ Open in background · esc Close"
        case .thread, .project, .message: "↩ Open · ⌘↩ Open in new window · esc Close"
        case nil: mode == .commands ? "> actions · @ threads · # projects · / files" : "esc Close"
        }
        if parts.isEmpty, mode == .quickOpen, let directory = currentDirectory, query.scope != .threads, query.scope != .projects {
            parts.append("Files in \(WorkspaceController.name(of: directory))")
        }
        footer.stringValue = (parts + [hints]).joined(separator: "   ")
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
        case .header: return 24
        case .item(let item): return item.kind == .message ? 30 : 32
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

/// Selected rows draw emphasized (the field keeps focus, so the table never becomes first responder).
@MainActor
final class PaletteRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    /// Section headers draw no band (the palette's material shows through).
    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }
}

@MainActor
final class PaletteHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("paletteHeader")
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = DS.Typography.current.sectionHeader
        label.textColor = DS.Palette.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
final class PaletteItemCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("paletteItem")
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let trailing = NSTextField(labelWithString: "")
    private var item: PaletteItem?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if let item { configure(item) } }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.cell?.wraps = false
        title.cell?.usesSingleLineMode = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.maximumNumberOfLines = 1
        subtitle.cell?.wraps = false
        subtitle.font = DS.Typography.current.caption
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        trailing.font = DS.Typography.current.caption
        trailing.alignment = .right
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [icon, title, subtitle, NSView(), trailing])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
        ])
        textField = title
        imageView = icon
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ item: PaletteItem) {
        self.item = item
        let selected = backgroundStyle == .emphasized
        let primary: NSColor = selected ? .alternateSelectedControlTextColor : (item.isEnabled ? DS.Palette.text : DS.Palette.tertiaryText)
        let secondary: NSColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8) : DS.Palette.secondaryText
        icon.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil)
        icon.contentTintColor = selected ? .alternateSelectedControlTextColor : DS.Palette.secondaryText
        let font = DS.Typography.current.body
        if let snippet = item.snippet {
            title.attributedStringValue = MatchHighlight.attributed(
                snippet.text, positions: snippet.highlights.flatMap { Array($0) }, font: font, color: selected ? primary : DS.Palette.secondaryText,
                highlightColor: primary)
        } else {
            title.attributedStringValue = MatchHighlight.attributed(item.title, positions: item.titleMatches, font: font, color: primary)
        }
        subtitle.stringValue = item.subtitle ?? ""
        // A search hit's date never gives way to its snippet.
        subtitle.setContentCompressionResistancePriority(item.kind == .message ? .required : .defaultLow - 1, for: .horizontal)
        subtitle.textColor = secondary
        subtitle.isHidden = item.subtitle == nil
        trailing.stringValue = item.disabledReason == nil ? (item.shortcut ?? "") : "Unavailable"
        trailing.textColor = selected ? secondary : DS.Palette.tertiaryText
        var label = item.title
        if let subtitle = item.subtitle { label += ", \(subtitle)" }
        if let shortcut = item.shortcut, !shortcut.isEmpty { label += ", \(shortcut)" }
        if let reason = item.disabledReason { label += ", unavailable: \(reason)" }
        setAccessibilityLabel(label)
    }
}
