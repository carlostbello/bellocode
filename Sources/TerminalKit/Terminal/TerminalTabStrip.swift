import AppKit
import DesignSystem
import Engine

@MainActor
protocol TerminalTabStripDelegate: AnyObject {
    func tabStrip(_ strip: TerminalTabStrip, select id: String)
    func tabStrip(_ strip: TerminalTabStrip, close id: String)
    func tabStrip(_ strip: TerminalTabStrip, rename id: String, to title: String?)
    func tabStrip(_ strip: TerminalTabStrip, move id: String, to index: Int)
    func tabStrip(_ strip: TerminalTabStrip, split id: String)
    func tabStrip(_ strip: TerminalTabStrip, unsplit id: String)
    func tabStrip(_ strip: TerminalTabStrip, moveToOtherPlace id: String)
    func tabStrip(_ strip: TerminalTabStrip, restart id: String)
    func tabStripNewTerminal(_ strip: TerminalTabStrip)
}

/// Compact terminal tabs: title, run state as glyph + text ("exited (1)"), a close button on hover or selection.
/// Click selects, double-click renames in place, drag reorders, right-click offers Rename, Split, Move, Restart and
/// Close. Tabs are keyed by the server's PTY ID and reused across updates (AGENTS.md rule 1).
@MainActor
final class TerminalTabStrip: NSView {
    weak var delegate: (any TerminalTabStripDelegate)?
    var placement: TerminalPlacement = .drawer
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var tabs: [String: TerminalTabView] = [:]
    private var order: [String] = []
    private let creatingTab = TerminalTabView(id: "")
    private var dragging: (id: String, startX: CGFloat, moved: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let fill = document.widthAnchor.constraint(equalTo: stack.widthAnchor)
        let preferred = widthAnchor.constraint(equalTo: stack.widthAnchor)
        preferred.priority = .defaultLow
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            document.heightAnchor.constraint(equalTo: scroll.heightAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor), fill, preferred,
        ])
        creatingTab.showCreating()
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Terminals")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(records: [TerminalRecord], selectedID: String?, splitID: String?, creating: Int) {
        let ids = records.map(\.id)
        for (id, tab) in tabs where !ids.contains(id) {
            tab.removeFromSuperview()
            tabs[id] = nil
        }
        for record in records {
            let tab = tabs[record.id] ?? makeTab(record.id)
            tab.update(record: record, isSelected: record.id == selectedID, isSplit: record.id == splitID)
        }
        if ids != order || stack.arrangedSubviews.count != ids.count + (creating > 0 ? 1 : 0) {
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view) }
            for id in ids { if let tab = tabs[id] { stack.addArrangedSubview(tab) } }
            if creating > 0 { stack.addArrangedSubview(creatingTab) }
            order = ids
        }
        if let selectedID, let tab = tabs[selectedID] { tab.scrollToVisible(tab.bounds) }
        setAccessibilityChildren(stack.arrangedSubviews)
    }

    private func makeTab(_ id: String) -> TerminalTabView {
        let tab = TerminalTabView(id: id)
        tab.strip = self
        tabs[id] = tab
        return tab
    }

    func beginRename(_ id: String) { tabs[id]?.beginRename() }

    // MARK: Tab events

    func tabClicked(_ tab: TerminalTabView) { delegate?.tabStrip(self, select: tab.id) }
    func tabClosed(_ tab: TerminalTabView) { delegate?.tabStrip(self, close: tab.id) }
    func tab(_ tab: TerminalTabView, renamedTo title: String?) { delegate?.tabStrip(self, rename: tab.id, to: title) }

    func tabDragBegan(_ tab: TerminalTabView, at x: CGFloat) { dragging = (tab.id, x, false) }

    func tabDragged(_ tab: TerminalTabView, to x: CGFloat) {
        guard var drag = dragging, drag.id == tab.id else { return }
        if abs(x - drag.startX) > 4 { drag.moved = true }
        dragging = drag
        guard drag.moved else { return }
        tab.alphaValue = 0.6
        let target = index(at: x)
        if let current = order.firstIndex(of: tab.id), target != current {
            var reordered = order
            reordered.remove(at: current)
            reordered.insert(tab.id, at: min(target, reordered.count))
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view) }
            for id in reordered { if let tab = tabs[id] { stack.addArrangedSubview(tab) } }
            order = reordered
        }
    }

    /// Returns whether the gesture was a drag (not a click).
    func tabDragEnded(_ tab: TerminalTabView) -> Bool {
        defer { dragging = nil }
        tab.alphaValue = 1
        guard let drag = dragging, drag.moved, let index = order.firstIndex(of: tab.id) else { return false }
        delegate?.tabStrip(self, move: tab.id, to: index)
        return true
    }

    private func index(at x: CGFloat) -> Int {
        let point = stack.convert(NSPoint(x: x, y: 0), from: nil)
        for (index, id) in order.enumerated() {
            guard let tab = tabs[id] else { continue }
            if point.x < tab.frame.midX { return index }
        }
        return max(0, order.count - 1)
    }

    func menu(for tab: TerminalTabView) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ handler: @escaping () -> Void) {
            menu.addItem(ClosureMenuItem(title: title, handler: handler))
        }
        let id = tab.id
        add("Rename…") { [weak tab] in tab?.beginRename() }
        if placement == .drawer {
            if tab.isSplit {
                add("Unsplit") { [weak self] in self.map { $0.delegate?.tabStrip($0, unsplit: id) } }
            } else {
                add("Split Beside") { [weak self] in self.map { $0.delegate?.tabStrip($0, split: id) } }
            }
        }
        add(placement == .drawer ? "Move to Right Panel" : "Move to Drawer") { [weak self] in
            self.map { $0.delegate?.tabStrip($0, moveToOtherPlace: id) }
        }
        menu.addItem(.separator())
        add(tab.isRunning ? "Restart" : "Restart Terminal") { [weak self] in self.map { $0.delegate?.tabStrip($0, restart: id) } }
        add("Close Terminal") { [weak self] in self.map { $0.delegate?.tabStrip($0, close: id) } }
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "New Terminal") { [weak self] in self.map { $0.delegate?.tabStripNewTerminal($0) } })
        return menu
    }
}

/// One tab.
@MainActor
final class TerminalTabView: NSView, NSTextFieldDelegate {
    let id: String
    weak var strip: TerminalTabStrip?
    private let glyph = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var editor: NSTextField?
    private(set) var isSelected = false
    private(set) var isSplit = false
    private(set) var isRunning = true
    private var isHovered = false
    private var mouseDownPoint: NSPoint?

    init(id: String) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.medium
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        state.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        state.textColor = .secondaryLabelColor
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Terminal")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.toolTip = "Close Terminal"
        let stack = NSStackView(views: [glyph, title, state, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 72), widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            closeButton.widthAnchor.constraint(equalToConstant: 16), closeButton.heightAnchor.constraint(equalToConstant: 16),
            glyph.widthAnchor.constraint(equalToConstant: 12),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(record: TerminalRecord, isSelected: Bool, isSplit: Bool) {
        self.isSelected = isSelected
        self.isSplit = isSplit
        isRunning = record.state.isRunning
        if editor == nil { title.stringValue = record.displayTitle }
        title.textColor = isSelected ? .labelColor : .secondaryLabelColor
        let symbol: String
        if !record.state.isRunning {
            symbol = "stop.circle"
            state.stringValue = record.state.label.map { text in
                if case .ended = record.state { return "ended" }
                return text
            } ?? ""
        } else {
            symbol = isSplit ? "rectangle.split.2x1" : "terminal"
            state.stringValue = ""
        }
        state.isHidden = state.stringValue.isEmpty
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        glyph.contentTintColor = record.state.isRunning ? .secondaryLabelColor : .tertiaryLabelColor
        toolTip = [record.displayTitle, (record.currentDirectory as NSString).abbreviatingWithTildeInPath, record.state.label]
            .compactMap { $0 }.joined(separator: "\n")
        setAccessibilityLabel([record.displayTitle, record.state.label].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityValue(isSelected ? 1 : 0)
        updateChrome()
    }

    func showCreating() {
        title.stringValue = "Starting…"
        title.textColor = .tertiaryLabelColor
        glyph.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        glyph.contentTintColor = .tertiaryLabelColor
        state.isHidden = true
        closeButton.isHidden = true
        setAccessibilityLabel("Starting terminal")
    }

    private func updateChrome() {
        closeButton.isHidden = id.isEmpty || !(isSelected || isHovered)
        needsDisplay = true
        needsLayout = true
        layer?.backgroundColor = isSelected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).cgColor
            : (isHovered ? NSColor.quaternaryLabelColor.cgColor : NSColor.clear.cgColor)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChrome()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateChrome()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateChrome()
    }

    override func mouseDown(with event: NSEvent) {
        guard !id.isEmpty else { return }
        if event.clickCount == 2 {
            beginRename()
            return
        }
        strip?.tabDragBegan(self, at: event.locationInWindow.x)
    }

    override func mouseDragged(with event: NSEvent) {
        strip?.tabDragged(self, to: event.locationInWindow.x)
    }

    override func mouseUp(with event: NSEvent) {
        guard !id.isEmpty, event.clickCount < 2 else { return }
        if strip?.tabDragEnded(self) == false { strip?.tabClicked(self) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        id.isEmpty ? nil : strip?.menu(for: self)
    }

    override func accessibilityPerformPress() -> Bool {
        strip?.tabClicked(self)
        return true
    }

    @objc private func closePressed() { strip?.tabClosed(self) }

    // MARK: Rename in place

    func beginRename() {
        guard editor == nil else { return }
        let field = NSTextField(string: title.stringValue)
        field.font = title.font
        field.isBordered = true
        field.focusRingType = .default
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: title.leadingAnchor, constant: -2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        editor = field
        title.alphaValue = 0
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endRename(commit: Bool) {
        guard let field = editor else { return }
        editor = nil
        let value = field.stringValue
        field.removeFromSuperview()
        title.alphaValue = 1
        if commit {
            title.stringValue = value.isEmpty ? title.stringValue : value
            strip?.tab(self, renamedTo: value)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endRename(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endRename(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) { endRename(commit: true) }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
