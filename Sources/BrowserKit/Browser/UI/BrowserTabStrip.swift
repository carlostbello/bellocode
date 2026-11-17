import AppKit
import DesignSystem

@MainActor
protocol BrowserTabStripDelegate: AnyObject {
    func tabStrip(_ strip: BrowserTabStrip, select id: String)
    func tabStrip(_ strip: BrowserTabStrip, close id: String)
    func tabStrip(_ strip: BrowserTabStrip, move id: String, to index: Int)
    func tabStrip(_ strip: BrowserTabStrip, menuFor id: String) -> NSMenu
    func tabStripNewTab(_ strip: BrowserTabStrip)
}

/// Compact browser tabs: favicon, title, ownership marker (agent / shared / private, each with a symbol and a tooltip,
/// never colour alone), a close button on hover or selection. Click selects, drag reorders, middle-click closes,
/// right-click offers Share with Agent, Duplicate, Close Others, Open in Default Browser. Tabs are keyed by the tab's
/// stable ID and reused across updates (AGENTS.md rule 1).
@MainActor
final class BrowserTabStrip: NSView {
    weak var delegate: (any BrowserTabStripDelegate)?
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let newButton = DSButton(icon: "plus", accessibilityTitle: "New Tab", size: .small)
    private var views: [String: BrowserTabView] = [:]
    private var order: [String] = []
    private var dragging: (id: String, startX: CGFloat, moved: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: DS.Space.s6, bottom: 4, right: DS.Space.s4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = BrowserFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        newButton.toolTip = "New Tab (⌥⌘T)"
        newButton.target = self
        newButton.action = #selector(newTab)
        newButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(newButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: newButton.leadingAnchor, constant: -DS.Space.s2),
            newButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.s6),
            newButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor), document.heightAnchor.constraint(equalTo: scroll.heightAnchor),
            document.widthAnchor.constraint(equalTo: stack.widthAnchor),
            heightAnchor.constraint(equalToConstant: DS.Size.terminalTabStrip),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Browser tabs")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ tabs: [BrowserTab], selectedID: String?, availableWidth: CGFloat) {
        let ids = tabs.map(\.id)
        for (id, view) in views where !ids.contains(id) {
            view.removeFromSuperview()
            views[id] = nil
        }
        // Tabs shrink to share the strip, between 72 and 220 points.
        let width = min(220, max(72, (availableWidth - 40) / CGFloat(max(tabs.count, 1)) - 2))
        for tab in tabs {
            let view = views[tab.id] ?? makeView(tab.id)
            view.update(tab, isSelected: tab.id == selectedID, width: width)
        }
        if ids != order || stack.arrangedSubviews.count != ids.count {
            for view in stack.arrangedSubviews { view.removeFromSuperview() }
            for id in ids { if let view = views[id] { stack.addArrangedSubview(view) } }
            order = ids
        }
        if let selectedID, let view = views[selectedID] { view.scrollToVisible(view.bounds) }
    }

    private func makeView(_ id: String) -> BrowserTabView {
        let view = BrowserTabView(id: id)
        view.onSelect = { [weak self] in self.map { $0.delegate?.tabStrip($0, select: id) } }
        view.onClose = { [weak self] in self.map { $0.delegate?.tabStrip($0, close: id) } }
        view.menuProvider = { [weak self] in self.flatMap { $0.delegate?.tabStrip($0, menuFor: id) } }
        view.onDrag = { [weak self] phase, x in self?.drag(id, phase: phase, x: x) }
        views[id] = view
        return view
    }

    @objc private func newTab() { delegate?.tabStripNewTab(self) }

    private func drag(_ id: String, phase: BrowserTabView.DragPhase, x: CGFloat) {
        switch phase {
        case .began:
            dragging = (id, x, false)
        case .moved:
            guard var drag = dragging, drag.id == id else { return }
            if abs(x - drag.startX) > 6 { drag.moved = true }
            dragging = drag
            guard drag.moved, let current = order.firstIndex(of: id) else { return }
            let location = stack.convert(NSPoint(x: x, y: 0), from: nil).x
            // The new index is the number of other tabs whose centre is left of the pointer.
            let destination = order.filter { $0 != id }.filter { (views[$0]?.frame.midX ?? 0) < location }.count
            if destination != current { delegate?.tabStrip(self, move: id, to: destination) }
        case .ended:
            dragging = nil
        }
    }
}

/// One tab in the strip.
@MainActor
final class BrowserTabView: NSView {
    enum DragPhase { case began, moved, ended }

    let id: String
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDrag: ((DragPhase, CGFloat) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private let icon = NSImageView()
    private let marker = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let close = DSButton(icon: "xmark", accessibilityTitle: "Close Tab", size: .small)
    private let spinner = DSSpinner()
    private var width: NSLayoutConstraint!
    private var isSelected = false
    private var hovering = false

    init(id: String) {
        self.id = id
        super.init(frame: .zero)
        title.font = DS.TextRole.labelEmph.font
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.imageScaling = .scaleProportionallyDown
        marker.imageScaling = .scaleProportionallyDown
        close.target = self
        close.action = #selector(closeTab)
        close.toolTip = "Close Tab (⌥⌘W)"
        spinner.isHidden = true
        for view in [icon, marker, title, close, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        width = widthAnchor.constraint(equalToConstant: 160)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DS.Size.controlSmall), width,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.s8), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14), spinner.heightAnchor.constraint(equalToConstant: 14),
            marker.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: DS.Space.s4), marker.centerYAnchor.constraint(equalTo: centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 12), marker.heightAnchor.constraint(equalToConstant: 12),
            title.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: DS.Space.s2), title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -DS.Space.s2),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.s2), close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: DS.Size.micro), close.heightAnchor.constraint(equalToConstant: DS.Size.micro),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ tab: BrowserTab, isSelected: Bool, width: CGFloat) {
        self.isSelected = isSelected
        self.width.constant = width
        title.stringValue = tab.displayTitle
        title.textColor = isSelected ? DS.Color.text : DS.Color.text2
        let loading = tab.isLoading && tab.isLive
        spinner.isHidden = !loading
        spinner.isAnimating = loading
        icon.isHidden = loading
        icon.image = tab.favicon ?? NSImage(systemSymbolName: tab.isPrivate ? "eye.slash" : "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: DS.Size.iconPointRow, weight: .regular))
        icon.contentTintColor = tab.favicon == nil ? DS.Color.icon : nil
        // Ownership marker: agent-driven, agent tab, shared, private. Symbol plus tooltip; never colour alone.
        let (symbol, tint, help): (String?, NSColor, String) =
            if tab.isPrivate { ("lock", DS.Color.text3, "Private tab: never shared with the agent; nothing is saved") }
            else if tab.agentActivity != nil { ("cursorarrow.motionlines", DS.Color.infoText, "The agent is using this tab") }
            else if tab.isAgentPaused { ("pause.circle", DS.Color.warningText, "You took over: the agent is paused on this tab") }
            else if tab.owner == .agent { ("sparkle", DS.Color.infoText, "Opened by the agent (shared with this thread's agent)") }
            else if tab.isShared { ("person.2", DS.Color.text3, "Shared with this thread's agent") }
            else { (nil, DS.Color.text3, "Not shared with the agent") }
        marker.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: help) }?
            .withSymbolConfiguration(.init(pointSize: DS.Size.iconPointMeta, weight: .regular))
        marker.contentTintColor = tint
        marker.isHidden = symbol == nil
        let url = BrowserAddress.display(tab.url ?? tab.pendingURL)
        toolTip = [tab.displayTitle, url, help].filter { !$0.isEmpty }.joined(separator: "\n")
        setAccessibilityLabel("\(tab.displayTitle), \(help)\(loading ? ", loading" : "")")
        setAccessibilityValue(isSelected ? "selected" : "")
        refreshAppearance()
    }

    /// Ghost tabs (§6, restyle step 7): selected and hover = `fillHover`, `r.md`; the close glyph shows on hover or
    /// selection without changing the tab's width.
    private func refreshAppearance() {
        needsDisplay = true
        close.isHidden = !(isSelected || hovering)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || hovering else { return }
        DSDraw.fill(bounds, radius: DS.Radius.md, color: DS.Color.fillHover)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        onDrag?(.began, event.locationInWindow.x)
    }

    override func mouseDragged(with event: NSEvent) { onDrag?(.moved, event.locationInWindow.x) }
    override func mouseUp(with event: NSEvent) { onDrag?(.ended, event.locationInWindow.x) }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    @objc private func closeTab() { onClose?() }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }
}

final class BrowserFlippedView: NSView {
    override nonisolated var isFlipped: Bool { true }
}
