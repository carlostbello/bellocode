import AppKit

// Menus, pickers and popover lists (visual-language.md §6 "Menus, popovers, model picker"): a glass panel (radius 10,
// `borderStrong` ring, padding 4) with 28 pt rows (`r.sm`, `fillHover` highlight, never accent), group headers (26 pt,
// `metaEmph` `text3`, right-aligned status), 1 px separators inset 8, a leading check slot (accent), trailing metadata
// and optional `Connect…` links. Plain context menus stay native `NSMenu`.

/// One entry of a DesignSystem menu. Identity is the caller's stable `id` (engineering rule 1).
public enum DSMenuEntry: Hashable, Sendable, Identifiable {
    case header(id: String, title: String, trailing: String? = nil)
    case row(DSMenuRow)
    case separator(id: String)

    public var id: String {
        switch self {
        case .header(let id, _, _), .separator(let id): id
        case .row(let row): row.id
        }
    }
}

public struct DSMenuRow: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var symbolName: String?
    /// Trailing metadata (`meta` `text3`), e.g. "200K  $3 / $15".
    public var trailing: String?
    /// Colours `trailingEmphasis` (e.g. "Free" in `successText`).
    public var trailingEmphasis: String?
    public var trailingTone: DS.Tone = .success
    /// A trailing link in `infoText` ("Connect…"), chosen like the row.
    public var link: String?
    public var shortcut: String?
    /// Shows the accent check in the leading slot.
    public var isChecked = false
    public var isEnabled = true
    /// Recedes to `text3` (unconnected providers).
    public var recedes = false
    /// Reserve the check slot even when unchecked (lists with a selection).
    public var reservesCheckSlot = true
    /// Reserve the 14 pt icon slot when `symbolName` is nil, so titles align with rows that have one (palette).
    public var reservesIconSlot = false

    public init(
        id: String, title: String, symbolName: String? = nil, trailing: String? = nil, trailingEmphasis: String? = nil,
        link: String? = nil, shortcut: String? = nil, isChecked: Bool = false, isEnabled: Bool = true, recedes: Bool = false,
        reservesCheckSlot: Bool = true, reservesIconSlot: Bool = false
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.trailing = trailing
        self.trailingEmphasis = trailingEmphasis
        self.link = link
        self.shortcut = shortcut
        self.isChecked = isChecked
        self.isEnabled = isEnabled
        self.recedes = recedes
        self.reservesCheckSlot = reservesCheckSlot
        self.reservesIconSlot = reservesIconSlot
    }
}

/// The list inside a menu panel: lays out headers, rows and separators; mouse hover and ↑/↓ move one highlight;
/// Return or a click chooses. Embeddable on its own (pickers that add a search field above it, the gallery).
@MainActor
public final class DSMenuListView: NSView {
    public private(set) var entries: [DSMenuEntry] = []
    public private(set) var highlightedID: String? { didSet { syncHighlight() } }
    public var onChoose: ((String) -> Void)?
    public static let padding: CGFloat = 4
    /// Menus use `fillHover`; the command palette uses `highlight` (text 9 % / 6 %) with `r.md` and 34 pt rows.
    public enum Look: Sendable { case menu, palette }
    public var look: Look = .menu { didSet { setEntries(entries) } }

    private var entryViews: [NSView] = []

    public init(entries: [DSMenuEntry] = []) {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        setEntries(entries)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public func setEntries(_ newEntries: [DSMenuEntry]) {
        entries = newEntries
        entryViews.forEach { $0.removeFromSuperview() }
        entryViews = newEntries.map { entry -> NSView in
            switch entry {
            case .header(_, let title, let trailing): DSMenuHeaderView(title: title, trailing: trailing)
            case .separator: DSMenuSeparatorView()
            case .row(let row):
                {
                    let view = DSMenuRowView(row: row)
                    if look == .palette {
                        view.highlightColor = DS.Color.highlight
                        view.highlightRadius = DS.Radius.md
                    }
                    return view
                }()
            }
        }
        entryViews.forEach(addSubview)
        setAccessibilityChildren(entryViews.filter { $0 is DSMenuRowView })
        if let highlightedID, !rows.contains(where: { $0.id == highlightedID && $0.isEnabled }) { self.highlightedID = nil }
        syncHighlight()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private var rows: [DSMenuRow] {
        entries.compactMap { if case .row(let row) = $0 { row } else { nil } }
    }

    func height(of entry: DSMenuEntry) -> CGFloat {
        switch entry {
        case .header: look == .palette ? 28 : DS.Size.menuGroupHeader
        case .separator: 9
        case .row: look == .palette ? DS.Size.paletteRow : DS.Size.menuRow + 2
        }
    }

    public override var intrinsicContentSize: NSSize {
        let height = entries.map(height(of:)).reduce(0, +) + Self.padding * 2
        let width = entryViews.compactMap { ($0 as? DSMenuRowView)?.preferredWidth }.max() ?? 200
        return NSSize(width: max(200, width + Self.padding * 2), height: height)
    }

    public override func layout() {
        super.layout()
        var y = Self.padding
        for (entry, view) in zip(entries, entryViews) {
            let height = height(of: entry)
            view.frame = NSRect(x: Self.padding, y: y, width: bounds.width - Self.padding * 2, height: height)
            y += height
        }
    }

    // MARK: Highlight and choice

    public func highlight(_ id: String?) { highlightedID = id }

    /// Moves the highlight to the next enabled row (wrapping). Returns the new id.
    @discardableResult
    public func moveHighlight(by delta: Int) -> String? {
        let enabled = rows.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }
        let index = enabled.firstIndex { $0.id == highlightedID }
        let next: Int
        if let index {
            next = (index + delta + enabled.count) % enabled.count
        } else {
            next = delta >= 0 ? 0 : enabled.count - 1
        }
        highlightedID = enabled[next].id
        return highlightedID
    }

    public func chooseHighlighted() {
        guard let highlightedID, rows.contains(where: { $0.id == highlightedID && $0.isEnabled }) else { return }
        onChoose?(highlightedID)
    }

    private func syncHighlight() {
        for view in entryViews {
            guard let rowView = view as? DSMenuRowView else { continue }
            rowView.isHighlighted = rowView.row.id == highlightedID
        }
    }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: moveHighlight(by: 1)
        case 126: moveHighlight(by: -1)
        case 36, 76: chooseHighlighted()
        default: super.keyDown(with: event)
        }
    }

    public override var acceptsFirstResponder: Bool { true }

    // MARK: Mouse

    private var trackingArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func rowView(at event: NSEvent) -> DSMenuRowView? {
        let point = convert(event.locationInWindow, from: nil)
        return entryViews.first { $0.frame.contains(point) } as? DSMenuRowView
    }

    public override func mouseMoved(with event: NSEvent) {
        if let row = rowView(at: event), row.row.isEnabled { highlightedID = row.row.id }
    }

    public override func mouseExited(with event: NSEvent) { highlightedID = nil }

    public override func mouseDown(with event: NSEvent) {}

    public override func mouseUp(with event: NSEvent) {
        guard let row = rowView(at: event), row.row.isEnabled else { return }
        onChoose?(row.row.id)
    }
}

/// A 28 pt menu row.
@MainActor
public final class DSMenuRowView: NSView {
    public let row: DSMenuRow
    public var isHighlighted = false { didSet { if isHighlighted != oldValue { needsDisplay = true; setAccessibilitySelected(isHighlighted) } } }
    var highlightColor: NSColor = DS.Color.fillHover
    var highlightRadius: CGFloat = DS.Radius.sm

    init(row: DSMenuRow) {
        self.row = row
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel([row.title, row.trailing, row.trailingEmphasis, row.link].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityValue(row.isChecked ? "selected" : nil)
        setAccessibilityEnabled(row.isEnabled)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    private var leadingSlot: CGFloat { (row.reservesCheckSlot || row.isChecked ? 22 : 8) + (row.symbolName != nil || row.reservesIconSlot ? 22 : 0) }

    private var trailingText: String { [row.trailing, row.trailingEmphasis].compactMap { $0 }.joined(separator: "  ") }

    var preferredWidth: CGFloat {
        let body = DS.TextRole.body.font
        let meta = DS.TextRole.meta.font
        var width = leadingSlot + DSDraw.width(of: row.title, font: body) + 10
        if !trailingText.isEmpty { width += 24 + DSDraw.width(of: trailingText, font: meta) }
        if let link = row.link { width += 24 + DSDraw.width(of: link, font: meta) }
        if let shortcut = row.shortcut { width += 30 + DSDraw.width(of: shortcut, font: DS.TextRole.metaEmph.font) }
        return ceil(width)
    }

    public override func accessibilityPerformPress() -> Bool {
        guard row.isEnabled, let list = superview as? DSMenuListView else { return false }
        list.onChoose?(row.id)
        return true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 1)
        if isHighlighted { DSDraw.fill(rect, radius: highlightRadius, color: highlightColor) }
        let titleColor: NSColor = !row.isEnabled ? DS.Color.text4 : (row.recedes ? DS.Color.text3 : DS.Color.text)
        var x: CGFloat = 8
        if row.isChecked, let check = DSDraw.symbol("checkmark", pointSize: 11, weight: .semibold) {
            DSDraw.draw(template: check, in: NSRect(x: 4, y: rect.minY, width: 14, height: rect.height), color: DS.Color.accent)
        }
        if row.reservesCheckSlot || row.isChecked { x = 22 }
        if let symbol = row.symbolName, let image = DSDraw.symbol(symbol, pointSize: DS.Size.iconPointRow) {
            DSDraw.draw(template: image, in: NSRect(x: x, y: rect.minY, width: 14, height: rect.height), color: DS.Color.icon)
            x += 22
        } else if row.reservesIconSlot {
            x += 22
        }
        let meta = DS.TextRole.meta.font(base: DS.Typography.current.baseSize, monospacedDigits: true)
        var right = rect.maxX - 8
        if let link = row.link {
            let w = DSDraw.width(of: link, font: meta)
            DSDraw.text(link, in: NSRect(x: right - w, y: rect.minY, width: w + 1, height: rect.height), font: meta, color: DS.Color.infoText)
            right -= w + 12
        }
        if let shortcut = row.shortcut {
            let font = DS.TextRole.metaEmph.font
            let w = max(DS.Size.kbd, DSDraw.width(of: shortcut, font: font, kern: 0.5) + 10)
            let cap = NSRect(x: right - w + 2, y: rect.midY - DS.Size.kbd / 2, width: w, height: DS.Size.kbd)
            DSDraw.fill(cap, radius: DS.Radius.xs, color: DS.Color.kbdFill)
            DSDraw.text(shortcut, in: cap, font: font, color: DS.Color.text2, alignment: .center, kern: 0.5)
            right -= w + 10
        }
        if let emphasis = row.trailingEmphasis {
            let w = DSDraw.width(of: emphasis, font: meta)
            DSDraw.text(emphasis, in: NSRect(x: right - w, y: rect.minY, width: w + 1, height: rect.height), font: meta, color: DS.Color.tone(row.trailingTone).text)
            right -= w + 8
        }
        if let trailing = row.trailing {
            let w = DSDraw.width(of: trailing, font: meta)
            DSDraw.text(trailing, in: NSRect(x: right - w, y: rect.minY, width: w + 1, height: rect.height), font: meta, color: DS.Color.text3)
            right -= w + 12
        }
        DSDraw.text(row.title, in: NSRect(x: x, y: rect.minY, width: max(0, right - x), height: rect.height), font: DS.TextRole.body.font, color: titleColor)
    }
}

@MainActor
final class DSMenuHeaderView: NSView {
    let title: String
    let trailing: String?

    init(title: String, trailing: String?) {
        self.title = title
        self.trailing = trailing
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let font = DS.TextRole.metaEmph.font
        DSDraw.text(title, in: NSRect(x: 8, y: 2, width: bounds.width - 16, height: bounds.height - 2), font: font, color: DS.Color.text3, kern: 0.06)
        if let trailing {
            DSDraw.text(
                trailing, in: NSRect(x: 8, y: 2, width: bounds.width - 16, height: bounds.height - 2), font: DS.TextRole.meta.font,
                color: DS.Color.text3, alignment: .right)
        }
    }
}

@MainActor
final class DSMenuSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        DS.Color.border.setFill()
        NSRect(x: 8, y: floor(bounds.midY), width: bounds.width - 16, height: 1).fill()
    }
}

// MARK: - Panel

/// A floating glass panel holding a `DSMenuListView` (or any content view): positioned under (or above) an anchor
/// view, child of the anchor's window, key while open so ↑/↓/Return/Esc work, closed on choice, Esc or losing key.
/// Opens with a 120 ms fade + 0.98→1 scale (fade only under Reduce Motion); closes with an 80 ms fade.
@MainActor
public final class DSMenuPanel: NSPanel {
    public let glass = DSGlassView(surface: .popover)
    public let list: DSMenuListView
    public var onChoose: ((String) -> Void)?
    public var onClose: (() -> Void)?
    public var maximumHeight: CGFloat = 420

    private let scrollView = NSScrollView()
    private var resignObserver: (any NSObjectProtocol)?
    private var closing = false
    private var dismissGeneration = 0
    private var dismissFallback: Task<Void, Never>?

    public init(entries: [DSMenuEntry]) {
        list = DSMenuListView(entries: entries)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        glass.showsShadow = false
        contentView = glass
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = list
        DSScroller.install(on: scrollView)
        scrollView.frame = glass.contentView.bounds
        scrollView.autoresizingMask = [.width, .height]
        glass.contentView.addSubview(scrollView)
        list.onChoose = { [weak self] id in self?.choose(id) }
        setAccessibilityRole(.menu)
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    /// The panel's size for its entries at `width` (nil = the list's preferred width).
    public func preferredSize(width: CGFloat? = nil) -> NSSize {
        let size = list.intrinsicContentSize
        return NSSize(width: max(width ?? 0, size.width), height: min(size.height, maximumHeight))
    }

    /// Shows the panel under `anchor` (above it when there is no room), left-aligned, at least `minWidth` wide.
    public func show(below anchor: NSView, minWidth: CGFloat? = nil, gap: CGFloat = 4) {
        guard let parent = anchor.window else { return }
        let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let size = preferredSize(width: minWidth ?? anchorRect.width)
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .infinite
        var origin = NSPoint(x: anchorRect.minX, y: anchorRect.minY - gap - size.height)
        if origin.y < screen.minY { origin.y = anchorRect.maxY + gap }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        present(frame: NSRect(origin: origin, size: size), parent: parent)
    }

    /// Shows at an explicit screen frame (palette-style placement).
    public func present(frame: NSRect, parent: NSWindow) {
        setFrame(frame, display: false)
        list.frame = NSRect(x: 0, y: 0, width: frame.width, height: list.intrinsicContentSize.height)
        parent.addChildWindow(self, ordered: .above)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        makeFirstResponder(list)
        if list.highlightedID == nil {
            let checked = list.entries.compactMap { entry -> String? in
                if case .row(let row) = entry, row.isChecked { row.id } else { nil }
            }.first
            if let checked { list.highlight(checked) } else { list.moveHighlight(by: 1) }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        animateIn()
        NSAccessibility.post(element: self, notification: .created)
    }

    private func animateIn() {
        let reduce = DS.Motion.reduceMotion
        if !reduce, let layer = glass.layer {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = DS.Motion.popInScale
            scale.toValue = 1
            scale.duration = DS.Motion.popInDuration
            scale.timingFunction = DS.Motion.drawerTiming
            layer.add(scale, forKey: "dsPopIn")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.popInDuration
            context.timingFunction = DS.Motion.drawerTiming
            animator().alphaValue = 1
        }
    }

    public override func cancelOperation(_ sender: Any?) { dismiss() }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss(); return }
        list.keyDown(with: event)
    }

    private func choose(_ id: String) {
        onChoose?(id)
        dismiss()
    }

    /// Closes with an 80 ms fade and returns key status to the parent window. The close runs from the fade's completion
    /// or, if that never arrives (animation completions were seen to stall while the app is otherwise idle on macOS
    /// 27), from a ContinuousClock fallback shortly after; whichever comes first, once.
    public func dismiss() {
        guard !closing else { return }
        closing = true
        dismissGeneration &+= 1
        let generation = dismissGeneration
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        let parent = parent
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, self.closing, self.dismissGeneration == generation else { return }
            self.dismissFallback?.cancel()
            self.dismissFallback = nil
            parent?.removeChildWindow(self)
            self.orderOut(nil)
            self.closing = false
            if parent?.isVisible == true { parent?.makeKey() }
            self.onClose?()
        }
        dismissFallback = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(DS.Motion.popOutDuration) + .milliseconds(250), clock: .continuous) } catch { return }
            finish()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DS.Motion.popOutDuration
            animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { finish() }
        })
    }
}

// MARK: - Select button

/// A picker trigger (replaces `NSPopUpButton`'s look): ghost button with the current value, an optional leading glyph
/// and a trailing chevron (`chevron.down` for composer controls, `chevron.up.chevron.down` for selects). Opens a native
/// `NSMenu` (`popUpMenu`) or calls `onOpen` so the owner can show a `DSMenuPanel`. Open = `fillHover` + `text`.
/// Accessibility: pop-up button; value = title. Space, Return and ↓ open it.
@MainActor
public final class DSSelectButton: DSButton {
    public enum Chevron: Sendable { case down, upDown, none }

    /// A native menu to pop up (plain lists). Its checked item is not managed here.
    public var popUpMenu: NSMenu?
    /// Called to open a custom panel instead of `popUpMenu`.
    public var onOpen: ((DSSelectButton) -> Void)?
    public var chevron: Chevron { didSet { applyChevron() } }
    /// While a menu or panel is open (draws the open look).
    public var isOpen: Bool {
        get { isSelected }
        set { isSelected = newValue; setAccessibilityExpanded(newValue) }
    }

    public init(title: String, symbolName: String? = nil, chevron: Chevron = .upDown, size: Size = .regular) {
        self.chevron = chevron
        super.init(title: title, variant: .ghost, size: size, symbolName: symbolName)
        isMuted = true
        setAccessibilityRole(.popUpButton)
        setAccessibilityValue(title)
        applyChevron()
    }

    public override var title: String { didSet { setAccessibilityRole(.popUpButton); setAccessibilityValue(title) } }

    private func applyChevron() {
        trailingSymbolName = switch chevron {
        case .down: "chevron.down"
        case .upDown: "chevron.up.chevron.down"
        case .none: nil
        }
    }

    public override func activate() {
        if let onOpen {
            isOpen = true
            onOpen(self)
            return
        }
        guard let popUpMenu else { super.activate(); return }
        isOpen = true
        popUpMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        isOpen = false
        controlStateDidChange(from: controlState)
    }

    public override func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 125, isEnabled { activate(); return true }
        return super.handleKey(event)
    }
}
