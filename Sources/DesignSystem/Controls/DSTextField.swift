import AppKit

/// A text field without the stock bezel (visual-language.md §6 "Inputs"): 28 high, `r.md`, `canvas` fill, `borderStrong`
/// ring; focused = 1 pt accent ring + 3 pt `focusHalo`. `.search` style: `fillSubtle` (dark, + `border` ring) or
/// `#F4F4F5` (light) fill, a leading `magnifyingglass`, and an optional trailing key cap ("⌘K").
///
/// The editable control is `field` (a borderless `NSTextField`): set its delegate, target/action, string value and
/// placeholder there. Editing, IME, undo and the field editor are AppKit's own (engineering rule 14). The halo is drawn
/// inside the view's bounds, so leave 3 pt around the 28 pt field (or set `showsHalo = false`).
@MainActor
public final class DSTextField: NSView {
    public enum Style: Sendable { case standard, search }

    public let style: Style
    public let field: NSTextField
    public var placeholder: String { didSet { applyPlaceholder() } }
    /// A trailing key cap, for example "⌘K".
    public var shortcutHint: String? { didSet { kbd.keys = shortcutHint ?? ""; kbd.isHidden = shortcutHint == nil; needsLayout = true } }
    public var showsHalo = true { didSet { needsDisplay = true } }
    public private(set) var isFocused = false { didSet { if isFocused != oldValue { needsDisplay = true } } }

    private let kbd = DSKbd("")
    private let haloInset: CGFloat = DS.Border.fieldFocusHalo

    public init(style: Style = .standard, placeholder: String = "") {
        self.style = style
        self.placeholder = placeholder
        field = DSInnerTextField()
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = DS.TextRole.body.font
        field.textColor = DS.Color.text
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        (field as? DSInnerTextField)?.onFocusChange = { [weak self] focused in self?.isFocused = focused }
        addSubview(field)
        kbd.isHidden = true
        addSubview(kbd)
        field.setAccessibilityLabel(placeholder)
        applyPlaceholder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: DS.Size.control + (showsHalo ? haloInset * 2 : 0))
    }

    public var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    private var fieldRect: NSRect { showsHalo ? bounds.insetBy(dx: haloInset, dy: haloInset) : bounds }

    public override func layout() {
        super.layout()
        let rect = fieldRect
        let leading: CGFloat = style == .search ? 30 : 9
        var trailing: CGFloat = 8
        if !kbd.isHidden {
            let size = kbd.intrinsicContentSize
            kbd.frame = NSRect(x: rect.maxX - 5 - size.width, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            trailing += size.width + 4
        }
        let lineHeight = ceil((field.font?.ascender ?? 12) - (field.font?.descender ?? -4)) + 2
        field.frame = NSRect(x: rect.minX + leading, y: rect.midY - lineHeight / 2, width: rect.width - leading - trailing, height: lineHeight)
    }

    private func applyPlaceholder() {
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder, attributes: [.font: DS.TextRole.body.font, .foregroundColor: DS.Color.placeholder])
    }

    /// Forces the focused look (gallery and tests).
    public func setDisplayFocused(_ focused: Bool) { isFocused = focused }

    public override func draw(_ dirtyRect: NSRect) {
        let rect = fieldRect
        let radius = DS.Radius.md
        let dark = DS.Variant(effectiveAppearance).isDark
        if isFocused, showsHalo {
            DSDraw.ring(rect.insetBy(dx: -haloInset, dy: -haloInset), radius: radius + haloInset, color: DS.Color.focusHalo, width: haloInset)
        }
        switch style {
        case .standard:
            DSDraw.fill(rect, radius: radius, color: DS.Color.canvas)
            DSDraw.ring(rect, radius: radius, color: isFocused ? DS.Color.focusRing : DS.Color.borderStrong)
        case .search:
            DSDraw.fill(rect, radius: radius, color: dark ? DS.Color.fillSubtle : DS.Color.fillHover)
            if dark || isFocused { DSDraw.ring(rect, radius: radius, color: isFocused ? DS.Color.focusRing : DS.Color.border) }
            if let image = DSDraw.symbol("magnifyingglass", pointSize: DS.Size.iconPointRow) {
                DSDraw.draw(template: image, in: NSRect(x: rect.minX + 7, y: rect.minY, width: 16, height: rect.height), color: DS.Color.text3)
            }
        }
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPlaceholder()
    }
}

/// Reports focus to its container: becomes first responder (field editor takes over) until editing ends.
@MainActor
final class DSInnerTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}
