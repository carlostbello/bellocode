import AppKit

/// One item of a tab bar or segmented control.
public struct DSChoiceItem: Hashable, Sendable, Identifiable {
    /// Stable identity (never an index; engineering rule 1).
    public var id: String
    public var title: String
    public var symbolName: String?
    /// A trailing count (`meta` `text3`), hidden when nil.
    public var count: Int?
    /// Icon-only segments name themselves here for VoiceOver.
    public var accessibilityLabel: String?

    public init(id: String, title: String, symbolName: String? = nil, count: Int? = nil, accessibilityLabel: String? = nil) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.count = count
        self.accessibilityLabel = accessibilityLabel
    }
}

/// A row of mutually exclusive choices, in two looks (visual-language.md §6 "Right panel"):
/// - `.tabs` (`DSTabBar`): ghost pills 26 high, padding 7, `labelEmph`, 14 pt glyph, count `meta text3`; selected =
///   `fillHover` + `border` ring (light: white + ring + a 1 pt shadow). Replaces `NSSegmentedControl` panel tabs.
/// - `.segmented` (`DSSegmented`): a `fillSubtle` track with 20 high thumbs in `rowActive` (light: white + ring).
///
/// Keyboard: each choice is a focusable control; ←/→ move and select. Accessibility: a tab group / radio group whose
/// children are radio buttons with value 1 when selected.
@MainActor
open class DSChoiceBar: NSView {
    public enum Style: Sendable { case tabs, segmented }

    public let style: Style
    public private(set) var items: [DSChoiceItem] = []
    public var selectedID: String? { didSet { syncSelection() } }
    /// Called when the user picks a choice (not when `selectedID` is set in code).
    public var onSelect: ((String) -> Void)?
    public var target: AnyObject?
    public var action: Selector?

    private var buttons: [DSChoiceButton] = []

    public init(style: Style, items: [DSChoiceItem] = [], selectedID: String? = nil) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(style == .tabs ? .tabGroup : .radioGroup)
        setItems(items)
        self.selectedID = selectedID ?? items.first?.id
        syncSelection()
    }

    @available(*, unavailable)
    required public init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public func setItems(_ newItems: [DSChoiceItem]) {
        items = newItems
        buttons.forEach { $0.removeFromSuperview() }
        buttons = newItems.map { item in
            let button = DSChoiceButton(item: item, style: style)
            button.target = self
            button.action = #selector(choose(_:))
            addSubview(button)
            return button
        }
        setAccessibilityChildren(buttons)
        if let selectedID, !newItems.contains(where: { $0.id == selectedID }) { self.selectedID = newItems.first?.id }
        syncSelection()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Updates one item's count or title without rebuilding (live counts).
    public func update(_ item: DSChoiceItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        buttons[index].item = item
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    public var choiceButtons: [DSChoiceButton] { buttons }

    private var inset: CGFloat { style == .segmented ? 2 : 0 }
    private var gap: CGFloat { style == .segmented ? 0 : 2 }
    private var height: CGFloat { style == .segmented ? 24 : DS.Size.tab }

    public override var intrinsicContentSize: NSSize {
        let widths = buttons.map(\.intrinsicContentSize.width)
        return NSSize(width: widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1)) + inset * 2, height: height)
    }

    public override func layout() {
        super.layout()
        var x = inset
        for button in buttons {
            let width = button.intrinsicContentSize.width
            button.frame = NSRect(x: x, y: inset, width: width, height: bounds.height - inset * 2)
            x += width + gap
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard style == .segmented else { return }
        DSDraw.fill(bounds, radius: DS.Radius.md, color: DS.Color.fillSubtle)
        if !DS.Variant(effectiveAppearance).isDark { DSDraw.ring(bounds, radius: DS.Radius.md, color: DS.Color.border) }
    }

    @objc private func choose(_ sender: DSChoiceButton) {
        select(sender.item.id, byUser: true)
    }

    /// Selects and, when `byUser`, reports the choice.
    public func select(_ id: String, byUser: Bool) {
        guard items.contains(where: { $0.id == id }) else { return }
        selectedID = id
        if byUser {
            onSelect?(id)
            if let action { NSApp.sendAction(action, to: target, from: self) }
        }
    }

    /// Moves the selection by `delta` (←/→), wrapping, and focuses the new choice if focus was in the bar.
    func move(from button: DSChoiceButton, by delta: Int) {
        guard let index = buttons.firstIndex(of: button), !buttons.isEmpty else { return }
        let next = buttons[(index + delta + buttons.count) % buttons.count]
        select(next.item.id, byUser: true)
        window?.makeFirstResponder(next)
    }

    private func syncSelection() {
        for button in buttons { button.isSelected = button.item.id == selectedID }
        setAccessibilityValue(items.first { $0.id == selectedID }?.title)
    }
}

/// The tab-pill look of `DSChoiceBar`.
@MainActor
public final class DSTabBar: DSChoiceBar {
    public init(items: [DSChoiceItem] = [], selectedID: String? = nil) { super.init(style: .tabs, items: items, selectedID: selectedID) }
    @available(*, unavailable)
    required public init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The segmented-track look of `DSChoiceBar` (layout toggle, reasoning effort).
@MainActor
public final class DSSegmented: DSChoiceBar {
    public init(items: [DSChoiceItem] = [], selectedID: String? = nil) { super.init(style: .segmented, items: items, selectedID: selectedID) }
    @available(*, unavailable)
    required public init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// One choice of a `DSChoiceBar`.
@MainActor
public final class DSChoiceButton: DSControl {
    public var item: DSChoiceItem { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; updateAccessibility() } }
    let style: DSChoiceBar.Style

    init(item: DSChoiceItem, style: DSChoiceBar.Style) {
        self.item = item
        self.style = style
        super.init(frame: .zero)
        setAccessibilityRole(.radioButton)
        if style == .tabs { setAccessibilitySubrole(.tabButtonSubrole) }
        updateAccessibility()
    }

    private var labelFont: NSFont { DS.TextRole.labelEmph.font }
    private var padding: CGFloat { style == .tabs ? 7 : (item.title.isEmpty ? 6 : 8) }

    public override var intrinsicContentSize: NSSize {
        var width = padding * 2
        if item.symbolName != nil { width += 14 }
        if !item.title.isEmpty { width += DSDraw.width(of: item.title, font: labelFont) + (item.symbolName != nil ? 5 : 0) }
        if let count = item.count { width += 5 + DSDraw.width(of: "\(count)", font: DS.TextRole.meta.font(base: DS.Typography.current.baseSize, monospacedDigits: true)) }
        return NSSize(width: ceil(width), height: style == .tabs ? DS.Size.tab : 20)
    }

    private func updateAccessibility() {
        let label = item.title.isEmpty ? (item.accessibilityLabel ?? item.id) : item.title
        setAccessibilityLabel(item.count.map { "\(label), \($0)" } ?? label)
        setAccessibilityValue(isSelected ? 1 : 0)
    }

    public override func controlStateDidChange(from old: DSControlState) {
        if old.isSelected != controlState.isSelected { setAccessibilityValue(isSelected ? 1 : 0) }
    }

    public override func activate() {
        super.activate()
    }

    public override func handleKey(_ event: NSEvent) -> Bool {
        guard let bar = superview as? DSChoiceBar else { return super.handleKey(event) }
        switch event.keyCode {
        case 123: bar.move(from: self, by: -1); return true
        case 124: bar.move(from: self, by: 1); return true
        default: return super.handleKey(event)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let dark = DS.Variant(effectiveAppearance).isDark
        let radius = style == .tabs ? DS.Radius.md : DS.Radius.sm
        let state = controlState
        let active = state.phase == .hover || state.phase == .pressed
        switch style {
        case .tabs:
            if state.isSelected {
                if dark {
                    DSDraw.fill(rect, radius: radius, color: DS.Color.fillHover)
                } else {
                    NSGraphicsContext.saveGraphicsState()
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.04)
                    shadow.shadowOffset = NSSize(width: 0, height: -1)
                    shadow.shadowBlurRadius = 2
                    shadow.set()
                    DSDraw.fill(rect.insetBy(dx: 0, dy: 1), radius: radius, color: DS.Color.raised)
                    NSGraphicsContext.restoreGraphicsState()
                    DSDraw.fill(rect, radius: radius, color: DS.Color.raised)
                }
                DSDraw.ring(rect, radius: radius, color: DS.Color.border)
            } else if active {
                DSDraw.fill(rect, radius: radius, color: DS.Color.fillHover)
            }
        case .segmented:
            if state.isSelected {
                DSDraw.fill(rect, radius: radius, color: DS.Color.rowActive)
                DSDraw.ring(rect, radius: radius, color: dark ? DS.Color.border : DS.Color.rowRing)
            } else if active {
                DSDraw.fill(rect, radius: radius, color: DS.Color.fillHover)
            }
        }
        let emphasised = state.isSelected || active
        let textColor = emphasised ? DS.Color.text : DS.Color.text2
        let iconColor = emphasised ? DS.Color.text : DS.Color.icon
        var x = rect.minX + padding
        if item.title.isEmpty, let name = item.symbolName, let image = DSDraw.symbol(name, pointSize: DS.Size.iconPointRow) {
            DSDraw.draw(template: image, in: rect, color: iconColor)
        } else {
            if let name = item.symbolName, let image = DSDraw.symbol(name, pointSize: DS.Size.iconPointRow) {
                DSDraw.draw(template: image, in: NSRect(x: x, y: rect.minY, width: 14, height: rect.height), color: iconColor)
                x += 14 + 5
            }
            let titleWidth = DSDraw.width(of: item.title, font: labelFont)
            DSDraw.text(item.title, in: NSRect(x: x, y: rect.minY, width: titleWidth + 1, height: rect.height), font: labelFont, color: textColor)
            x += titleWidth + 5
            if let count = item.count {
                let countFont = DS.TextRole.meta.font(base: DS.Typography.current.baseSize, monospacedDigits: true)
                DSDraw.text("\(count)", in: NSRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height), font: countFont, color: DS.Color.text3)
            }
        }
        drawFocusRingIfNeeded(in: rect, radius: radius)
    }
}

extension NSAccessibility.Subrole {
    /// AppKit's tab subrole string ("AXTabButton").
    static let tabButtonSubrole = NSAccessibility.Subrole(rawValue: "AXTabButton")
}
