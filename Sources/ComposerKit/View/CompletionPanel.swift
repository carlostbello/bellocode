import AppKit

/// A borderless child panel that never takes key status, so the text view keeps focus and its keys; the composer
/// forwards arrows, Return, Tab and Escape. Rows are reused by the table.
@MainActor
final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CompletionListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var style: ComposerStyle
    var onAccept: ((Int) -> Void)?
    private(set) var items: [CompletionItem] = []
    private(set) var message: String?
    private let table = ClickThroughTableView()
    private let scroll = NSScrollView()

    init(style: ComposerStyle) {
        self.style = style
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = style.completionRowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        table.setAccessibilityLabel("Suggestions")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Rows to show, or a single status `message` ("Searching…", "No matches").
    func show(_ items: [CompletionItem], selected: Int, message: String?) {
        let idsChanged = items.map(\.id) != self.items.map(\.id) || message != self.message
        self.items = items
        self.message = message
        if idsChanged { table.reloadData() }
        if items.indices.contains(selected) {
            table.selectRowIndexes([selected], byExtendingSelection: false)
            table.scrollRowToVisible(selected)
        } else {
            table.deselectAll(nil)
        }
    }

    var preferredHeight: CGFloat {
        let rows = max(1, min(items.isEmpty ? 1 : items.count, style.completionMaxVisibleRows))
        return CGFloat(rows) * style.completionRowHeight + 8
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        style.popoverBackgroundColor.setFill()
        path.fill()
        (style.increasedContrast ? NSColor.labelColor.withAlphaComponent(0.6) : style.borderColor).setStroke()
        path.lineWidth = style.borderWidth
        path.stroke()
    }

    @objc private func clicked() {
        let row = table.clickedRow
        if items.indices.contains(row) { onAccept?(row) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.isEmpty ? (message == nil ? 0 : 1) : items.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !items.isEmpty }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = CompletionRowView()
        rowView.selectionColor = style.selectionRowColor
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: CompletionCellView.identifier, owner: nil) as? CompletionCellView)
            ?? CompletionCellView(style: style)
        if items.isEmpty {
            cell.configureMessage(message ?? "")
        } else {
            cell.configure(items[row])
        }
        return cell
    }
}

/// Accepts the first click although its window is never key.
final class ClickThroughTableView: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class CompletionRowView: NSTableRowView {
    var selectionColor: NSColor = .selectedContentBackgroundColor
    // The panel is never key; draw the selection as active anyway.
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        selectionColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

final class CompletionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CompletionCell")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init(style: ComposerStyle) {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.lineBreakMode = .byTruncatingHead
        subtitle.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        for view in [icon, title, subtitle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            subtitle.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        subtitle.textColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        icon.contentTintColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    func configure(_ item: CompletionItem) {
        icon.image = item.symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = false
        title.stringValue = item.title
        subtitle.stringValue = item.subtitle ?? ""
        setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        applyColors()
    }

    func configureMessage(_ message: String) {
        icon.image = nil
        title.stringValue = message
        subtitle.stringValue = ""
        title.textColor = .secondaryLabelColor
    }
}
