import AppKit

/// The interaction state every DesignSystem control draws from (visual-language.md §6: rest, hover, pressed,
/// selected, disabled, focused). A plain value so recipes are pure functions and unit-testable.
public struct DSControlState: Hashable, Sendable {
    public var isEnabled = true
    public var isHovered = false
    public var isPressed = false
    public var isSelected = false
    /// Keyboard focus (drawn as a 2 pt inset accent ring). Never set by a mouse click.
    public var isFocused = false

    public init(isEnabled: Bool = true, isHovered: Bool = false, isPressed: Bool = false, isSelected: Bool = false, isFocused: Bool = false) {
        self.isEnabled = isEnabled
        self.isHovered = isHovered
        self.isPressed = isPressed
        self.isSelected = isSelected
        self.isFocused = isFocused
    }

    /// The dominant visual state: disabled, then pressed, then hover, then rest. Selection and focus layer on top.
    public enum Phase: Hashable, Sendable { case rest, hover, pressed, disabled }

    public var phase: Phase {
        if !isEnabled { return .disabled }
        if isPressed { return .pressed }
        if isHovered { return .hover }
        return .rest
    }

    /// Disabled controls draw at 64 % opacity.
    public static let disabledOpacity: CGFloat = 0.64
}

/// Base class for custom-drawn controls: layer-backed, no cell, no bezel. Tracks hover (tracking area), press (mouse
/// down inside, cancelled by dragging out), keyboard focus (only under Full Keyboard Access, like `NSButton`, so a click
/// never steals focus from the composer or terminal), Space/Return activation and the accessibility press action.
///
/// Subclasses draw in `draw(_:)` from `controlState` and the `DS.Color` tokens; AppKit makes the view's appearance
/// current while drawing, so dynamic colours resolve correctly in light, dark and Increase Contrast.
@MainActor
open class DSControl: NSControl {
    /// Who may take keyboard focus. `.fullKeyboardAccess` (default) mirrors `NSButton`; tests and galleries use `.always`.
    public enum FocusPolicy: Sendable { case fullKeyboardAccess, always, never }
    public static var focusPolicy: FocusPolicy = .fullKeyboardAccess

    public private(set) var controlState = DSControlState() {
        didSet {
            guard controlState != oldValue else { return }
            if controlState.isPressed != oldValue.isPressed { applyPressScale(controlState.isPressed) }
            needsDisplay = true
            controlStateDidChange(from: oldValue)
        }
    }

    /// Selected / on (toggle buttons, tabs, checkboxes). Subclasses map their value onto this.
    open var isSelected: Bool {
        get { controlState.isSelected }
        set { controlState.isSelected = newValue }
    }

    /// Whether pressing scales the control to 0.97 (buttons only; never under Reduce Motion).
    open var scalesWhenPressed: Bool { false }

    /// Forces a display state (galleries and snapshot tests only; real events overwrite it).
    public func setDisplayState(hovered: Bool = false, pressed: Bool = false, focused: Bool = false) {
        controlState.isHovered = hovered
        controlState.isPressed = pressed
        controlState.isFocused = focused
    }

    private var hoverArea: NSTrackingArea?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    open override var isFlipped: Bool { true }
    open override var wantsUpdateLayer: Bool { false }

    open override var isEnabled: Bool {
        didSet {
            controlState.isEnabled = isEnabled
            if !isEnabled { controlState.isPressed = false }
            alphaValue = isEnabled ? 1 : DSControlState.disabledOpacity
            setAccessibilityEnabled(isEnabled)
        }
    }

    /// Hook for subclasses (accessibility value, child layout).
    open func controlStateDidChange(from old: DSControlState) {}

    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Hover

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    open override func mouseEntered(with event: NSEvent) { controlState.isHovered = true }
    open override func mouseExited(with event: NSEvent) { controlState.isHovered = false }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { controlState.isHovered = false; controlState.isPressed = false }
    }

    // MARK: Press

    open override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        controlState.isPressed = true
    }

    open override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        controlState.isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    open override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        controlState.isPressed = false
        if inside { activate() }
    }

    /// Performs the control's action: toggles or selects in subclasses, then sends the action.
    open func activate() {
        sendAction(action, to: target)
    }

    open override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        activate()
    }

    open override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        activate()
        return true
    }

    private func applyPressScale(_ pressed: Bool) {
        guard scalesWhenPressed, let layer else { return }
        let scale = pressed ? DS.Motion.effectivePressScale : 1
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
        let animate = !pressed && !DS.Motion.reduceMotion
        CATransaction.begin()
        if animate {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = layer.presentation()?.transform ?? layer.transform
            animation.toValue = transform
            animation.duration = DS.Motion.pressReleaseDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "dsPress")
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.transform = transform
        CATransaction.commit()
    }

    // MARK: Keyboard

    open override var acceptsFirstResponder: Bool {
        guard isEnabled else { return false }
        switch Self.focusPolicy {
        case .always: return true
        case .never: return false
        case .fullKeyboardAccess: return NSApp?.isFullKeyboardAccessEnabled ?? false
        }
    }

    open override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }
    open override var needsPanelToBecomeKey: Bool { false }

    open override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { controlState.isFocused = true }
        return accepted
    }

    open override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { controlState.isFocused = false }
        return resigned
    }

    open override func keyDown(with event: NSEvent) {
        if handleKey(event) { return }
        super.keyDown(with: event)
    }

    /// Space and Return activate. Subclasses add arrow keys.
    open func handleKey(_ event: NSEvent) -> Bool {
        guard isEnabled, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\u{3}":
            activate()
            return true
        default:
            return false
        }
    }

    // MARK: Drawing helpers

    /// Draws the 2 pt inset keyboard focus ring when focused.
    public func drawFocusRingIfNeeded(in rect: NSRect, radius: CGFloat) {
        guard controlState.isFocused else { return }
        DS.Color.focusRing.setStroke()
        let inset = DS.Border.focusRing / 2
        let path = DS.Radius.path(rect.insetBy(dx: inset, dy: inset), radius: max(0, radius - inset))
        path.lineWidth = DS.Border.focusRing
        path.stroke()
    }
}

// MARK: - Drawing primitives

@MainActor
public enum DSDraw {
    /// Fills a continuous rounded rect.
    public static func fill(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill()
        DS.Radius.path(rect, radius: radius).fill()
    }

    /// Strokes a hairline ring inside `rect`.
    public static func ring(_ rect: NSRect, radius: CGFloat, color: NSColor, width: CGFloat = DS.Border.hairline) {
        color.setStroke()
        let inset = width / 2
        let path = DS.Radius.path(rect.insetBy(dx: inset, dy: inset), radius: max(0, radius - inset))
        path.lineWidth = width
        path.stroke()
    }

    /// A 1 pt inner highlight along the top edge (filled buttons, composer, popovers).
    public static func topHighlight(_ rect: NSRect, radius: CGFloat, color: NSColor, flipped: Bool = true) {
        NSGraphicsContext.saveGraphicsState()
        DS.Radius.path(rect, radius: radius).addClip()
        color.setFill()
        let y = flipped ? rect.minY : rect.maxY - 1
        NSRect(x: rect.minX, y: y, width: rect.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A tinted SF Symbol, cached per (name, size, weight). The tint resolves at draw time, so one cached image serves
    /// light and dark. Bounded cache (engineering rule 5).
    public static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular, scale: NSImage.SymbolScale = .medium) -> NSImage? {
        let key = SymbolKey(name: name, pointSize: pointSize, weight: weight.rawValue, scale: scale.rawValue)
        if let cached = symbolCache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: scale)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        image.isTemplate = true
        if symbolCache.count > 256 { symbolCache.removeAll() }
        symbolCache[key] = image
        return image
    }

    /// Draws a template image centred in `rect`, filled with `color`.
    public static func draw(template image: NSImage, in rect: NSRect, color: NSColor) {
        let size = image.size
        let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height).integralCentered
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(in: target, auxiliaryInfo: nil)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        color.setFill()
        target.fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Draws a string vertically centred in `rect`, truncating at the tail.
    @discardableResult
    public static func text(_ string: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left, kern: CGFloat = 0) -> NSRect {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph, .kern: kern]
        let height = ceil(font.ascender - font.descender)
        let textRect = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        (string as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        return textRect
    }

    public static func width(of string: String, font: NSFont, kern: CGFloat = 0) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font, .kern: kern]).width)
    }

    private struct SymbolKey: Hashable {
        let name: String
        let pointSize: CGFloat
        let weight: CGFloat
        let scale: Int
    }

    private static var symbolCache: [SymbolKey: NSImage] = [:]
}

extension NSRect {
    /// Rounds the origin to whole points so glyphs stay crisp.
    fileprivate var integralCentered: NSRect { NSRect(x: origin.x.rounded(), y: origin.y.rounded(), width: width, height: height) }
}
