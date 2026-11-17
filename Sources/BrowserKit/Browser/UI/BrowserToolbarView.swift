import AppKit
import DesignSystem

/// The address field: shows the page URL, completes inline from history as you type (the completed part is selected,
/// so typing on replaces it), lists suggestions under the field (↑/↓ to move, Return to open, Escape to restore the
/// page URL). Plain words search.
@MainActor
final class BrowserAddressField: DSBareTextField, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    /// Suggestions for typed text (from history).
    var suggestionsProvider: ((String) -> [BrowserHistory.Entry])?
    var completionProvider: ((String) -> String?)?
    private var shownURL = ""
    private var lastTyped = ""
    private var isDeleting = false
    private let suggestions = SuggestionsPanel()

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
        lineBreakMode = .byTruncatingTail
        usesSingleLineMode = true
        cell?.isScrollable = true
        setAccessibilityLabel("Address and search")
        suggestions.onChoose = { [weak self] url in
            guard let self else { return }
            self.stringValue = url
            self.suggestions.close()
            self.onSubmit?(url)
            self.window?.makeFirstResponder(nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isEditing: Bool { currentEditor() != nil }

    /// Shows the page's URL unless the person is typing.
    func show(_ url: String) {
        shownURL = url
        if !isEditing { stringValue = url }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) } }
        return accepted
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let editor = currentEditor() else { return }
        let text = editor.string
        let selection = editor.selectedRange
        // Only complete when the caret is at the end of what was typed and the person did not just delete.
        var typed = text
        if selection.length > 0, selection.location + selection.length == (text as NSString).length {
            typed = (text as NSString).substring(to: selection.location)
        }
        defer { lastTyped = typed }
        if !isDeleting, typed.count > lastTyped.count, selection.location + selection.length == (text as NSString).length,
           let rest = completionProvider?(typed), !rest.isEmpty {
            editor.string = typed + rest
            editor.selectedRange = NSRange(location: (typed as NSString).length, length: (rest as NSString).length)
        }
        isDeleting = false
        let entries = suggestionsProvider?(typed) ?? []
        if entries.isEmpty || typed.isEmpty { suggestions.close() } else { suggestions.show(entries, below: self) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
            isDeleting = true
            return false
        case #selector(NSResponder.moveDown(_:)):
            guard suggestions.isVisible else { return false }
            suggestions.move(1)
            if let url = suggestions.highlightedURL { textView.string = url }
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard suggestions.isVisible else { return false }
            suggestions.move(-1)
            if let url = suggestions.highlightedURL { textView.string = url }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            let text = textView.string
            suggestions.close()
            onSubmit?(text)
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            suggestions.close()
            stringValue = shownURL
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        suggestions.close()
        lastTyped = ""
        if stringValue.isEmpty || stringValue != shownURL { stringValue = shownURL }
    }
}

/// The suggestion list under the address field: a borderless child window, never key, so typing stays in the field.
@MainActor
final class SuggestionsPanel {
    var onChoose: ((String) -> Void)?
    private var window: NSPanel?
    private var rows: [BrowserHistory.Entry] = []
    private var highlighted: Int?
    private let stack = NSStackView()

    var isVisible: Bool { window?.isVisible == true }
    var highlightedURL: String? { highlighted.flatMap { rows.indices.contains($0) ? rows[$0].url : nil } }

    func show(_ entries: [BrowserHistory.Entry], below field: NSView) {
        guard let parent = field.window else { return }
        rows = Array(entries.prefix(6))
        highlighted = nil
        let panel = window ?? makeWindow()
        window = panel
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for (index, entry) in rows.enumerated() {
            let row = SuggestionRow(entry: entry)
            row.onClick = { [weak self] in self?.onChoose?(entry.url) }
            row.isHighlighted = index == highlighted
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        }
        let frame = field.convert(field.bounds, to: nil)
        let screen = parent.convertToScreen(frame)
        let height = CGFloat(rows.count) * SuggestionRow.height + 8
        panel.setFrame(NSRect(x: screen.minX, y: screen.minY - height - 2, width: max(screen.width, 320), height: height), display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func move(_ offset: Int) {
        guard !rows.isEmpty else { return }
        highlighted = ((highlighted ?? (offset > 0 ? -1 : rows.count)) + offset + rows.count) % rows.count
        for (index, view) in stack.arrangedSubviews.enumerated() { (view as? SuggestionRow)?.isHighlighted = index == highlighted }
    }

    func close() {
        guard let window else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.animationBehavior = .none
        // The menu recipe: popover glass, r.lg, borderStrong ring, padding 4 (§6 "Menus, popovers").
        let glass = DSGlassView(surface: .popover, radius: DS.Radius.lg)
        glass.showsShadow = false
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor), stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
        ])
        panel.contentView = glass
        return panel
    }
}

/// A suggestion: title `body`, URL `meta text3`, 36 high, `r.sm`; highlighted = `fillHover` (never the accent).
@MainActor
private final class SuggestionRow: NSView {
    static let height: CGFloat = 36
    var onClick: (() -> Void)?
    var isHighlighted = false { didSet { needsDisplay = true } }
    private let title = NSTextField(labelWithString: "")
    private let url = NSTextField(labelWithString: "")

    init(entry: BrowserHistory.Entry) {
        super.init(frame: .zero)
        title.stringValue = entry.title.isEmpty ? entry.url : entry.title
        title.font = DS.TextRole.body.font
        title.textColor = DS.Color.text
        url.stringValue = entry.url
        url.font = DS.TextRole.meta.font
        url.textColor = DS.Color.text3
        for label in [title, url] {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 3), title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            url.topAnchor.constraint(equalTo: title.bottomAnchor), url.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            url.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(title.stringValue), \(entry.url)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted { DSDraw.fill(bounds, radius: DS.Radius.sm, color: DS.Color.fillHover) }
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// The browser's one 36 pt toolbar (§6, restyle step 7): back, forward and reload/stop as ghost icon buttons, the URL
/// field (`DSTextField`, search fill, security glyph leading), and the page tools as ghost icon buttons whose "on" state
/// is the toggle look (`fillHover`), never the accent. A 2 pt accent progress line runs along the bottom while loading.
@MainActor
final class BrowserToolbarView: NSView {
    let back = BrowserToolbarView.button("chevron.left", "Back (⌃⌘[)")
    let forward = BrowserToolbarView.button("chevron.right", "Forward (⌃⌘])")
    let reload = BrowserToolbarView.button("arrow.clockwise", "Reload (⌘R)")
    let address = BrowserAddressField()
    private(set) lazy var addressBox = DSTextField(style: .search, placeholder: "Search or enter address", field: address)
    let viewport = BrowserToolbarView.button("rectangle.portrait.on.rectangle.portrait", "Responsive Size")
    let appearanceButton = BrowserToolbarView.button("circle.lefthalf.filled", "Page Appearance")
    let pick = BrowserToolbarView.button("scope", "Pick Element (⇧⌘C)")
    let share = BrowserToolbarView.button("person.2", "Share Tab with Agent")
    let more = BrowserToolbarView.button("ellipsis", "More")
    private let progress = NSView()
    private var progressWidth: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        addressBox.showsHalo = false
        address.setAccessibilityLabel("Address and search")
        let leading = NSStackView(views: [back, forward, reload])
        leading.spacing = 0
        let trailing = NSStackView(views: [viewport, appearanceButton, pick, share, more])
        trailing.spacing = 0
        progress.wantsLayer = true
        for view in [leading, addressBox, trailing, progress] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        progressWidth = progress.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DS.Size.toolbar),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.s6), leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            addressBox.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: DS.Space.s6),
            addressBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            addressBox.heightAnchor.constraint(equalToConstant: DS.Size.controlSmall + 4),
            addressBox.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -DS.Space.s6),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.s6), trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor), progress.bottomAnchor.constraint(equalTo: bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2), progressWidth,
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateLayer() {
        super.updateLayer()
        progress.layer?.backgroundColor = DS.Color.accent.cgColor
    }
    override var wantsUpdateLayer: Bool { true }

    static func button(_ symbol: String, _ help: String) -> DSButton {
        let name = help.components(separatedBy: " (").first ?? help
        let button = DSButton(icon: symbol, accessibilityTitle: name, size: .small)
        button.toolTip = help
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Narrow panes keep the address field usable: secondary tools move to the More and Browser menus.
    override func layout() {
        super.layout()
        let width = bounds.width
        viewport.isHidden = width < 560
        appearanceButton.isHidden = width < 560
        share.isHidden = width < 460
        pick.isHidden = width < 400
    }

    func update(tab: BrowserTab?, picking: Bool) {
        back.isEnabled = tab?.canGoBack ?? false
        forward.isEnabled = tab?.canGoForward ?? false
        reload.isEnabled = tab != nil
        let loading = tab?.isLoading == true && tab?.isLive == true
        reload.symbolName = loading ? "xmark" : "arrow.clockwise"
        reload.toolTip = loading ? "Stop Loading (⌘.)" : "Reload (⌘R)"
        reload.accessibilityTitle = loading ? "Stop" : "Reload"
        address.show(BrowserAddress.display(tab?.url ?? tab?.pendingURL))
        address.isEnabled = true
        let url = tab?.url ?? tab?.pendingURL
        let (symbol, help): (String, String) = switch url?.scheme {
        case "https": ("lock", "Secure connection (HTTPS)")
        case "http" where url.map { BrowserAddress.isLocal($0.host() ?? "") } == true: ("laptopcomputer", "Local server on this Mac")
        case "http": ("exclamationmark.triangle", "Not secure (HTTP)")
        default: ("magnifyingglass", "Search or enter address")
        }
        addressBox.leadingSymbolName = tab?.isPrivate == true ? "eye.slash" : symbol
        // "Not secure" is the one warning here: glyph + tooltip word, warning tint as the third cue.
        addressBox.leadingSymbolTint = symbol == "exclamationmark.triangle" && tab?.isPrivate != true ? DS.Color.warningText : DS.Color.text3
        addressBox.toolTip = tab?.isPrivate == true ? "Private tab: nothing is saved and the agent never sees it" : help
        pick.isSelected = picking
        pick.isEnabled = tab?.isLive == true
        let shared = tab?.isShared == true
        share.symbolName = shared ? "person.2.fill" : "person.2"
        share.isSelected = shared
        share.toolTip = tab?.isPrivate == true ? "Private tabs are never shared" : (shared ? "Shared with this thread's agent: click to stop sharing" : "Share this tab with this thread's agent")
        share.accessibilityTitle = shared ? "Stop Sharing Tab with Agent" : "Share Tab with Agent"
        share.isEnabled = tab != nil && tab?.isPrivate == false
        viewport.isSelected = tab?.viewport != nil
        appearanceButton.isSelected = (tab?.appearance ?? .system) != .system
        let fraction = loading ? max(0.08, tab?.progress ?? 0) : 0
        progress.isHidden = !loading
        progressWidth.constant = bounds.width * fraction
        needsDisplay = true
    }
}
