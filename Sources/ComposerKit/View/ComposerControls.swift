import AppKit
import DesignSystem

/// The primary button (visual-language.md §6 "Composer"): a 30 pt `accent` circle with a white `arrow.up` when idle
/// (disabled: `disabledFill` with a `text2` arrow); a labelled accent capsule ("Queue", "Steer") while the agent runs
/// and the draft has text; an outline capsule with a red 8 pt square and "Stop" ("Stopping…") when it stops the agent.
/// The action is never conveyed by colour or icon alone. Drawn in `draw(_:)`, so snapshots and Increase Contrast render
/// it faithfully.
@MainActor
final class ComposerSendButton: NSButton {
    enum Appearance: Equatable {
        case send(enabled: Bool)
        case followUp(ComposerDelivery)
        case stop
        case stopping
    }

    var style = ComposerStyle() { didSet { needsDisplay = true } }
    var appearanceState: Appearance = .send(enabled: false) {
        didSet {
            guard appearanceState != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .noImage
        setButtonType(.momentaryChange)
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private var isStop: Bool { appearanceState == .stop || appearanceState == .stopping }

    private var label: String? {
        switch appearanceState {
        case .send: nil
        case .followUp(let delivery): delivery.title
        case .stop: "Stop"
        case .stopping: "Stopping…"
        }
    }

    private var symbolName: String? {
        switch appearanceState {
        case .send: "arrow.up"
        case .followUp(.steer): "arrow.turn.down.right"
        case .followUp: "text.badge.plus"
        case .stop, .stopping: nil
        }
    }

    private var labelFont: NSFont { isStop ? DS.TextRole.bodyEmph.font : DS.TextRole.labelEmph.font }

    private var height: CGFloat { isStop ? DS.Size.control : DS.Size.send }

    private static let iconGap: CGFloat = 6
    private static let sidePadding: CGFloat = 12
    private static let stopSquare: CGFloat = 8

    override var intrinsicContentSize: NSSize {
        guard let label else { return NSSize(width: height, height: height) }
        let width = DSDraw.width(of: label, font: labelFont)
        let icon: CGFloat = isStop ? Self.stopSquare : (symbolName == nil ? 0 : 14)
        return NSSize(width: ceil(width + icon + Self.iconGap + Self.sidePadding * 2), height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private var foreground: NSColor {
        switch appearanceState {
        case .send(let enabled): enabled ? DS.Color.onAccent : DS.Color.text2
        case .followUp: DS.Color.onAccent
        case .stop: DS.Color.text
        case .stopping: DS.Color.text2
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
        let radius = height / 2
        switch appearanceState {
        case .send(let enabled) where !enabled:
            DSDraw.fill(rect, radius: radius, color: DS.Color.disabledFill)
        case .send, .followUp:
            let fill = isHighlighted || isHovered ? DS.Color.accentHover : DS.Color.accent
            DSDraw.fill(rect, radius: radius, color: fill)
            DSDraw.topHighlight(rect, radius: radius, color: (isHighlighted ? DS.Shadow.buttonPressedShade : DS.Shadow.buttonHighlight).nsColor)
        case .stop, .stopping:
            let fill = isHighlighted || isHovered ? DSButtonColors.outlineHover : DSButtonColors.outlineFill
            DSDraw.fill(rect, radius: radius, color: fill)
            DSDraw.ring(rect, radius: radius, color: DS.Color.borderStrong)
        }
        var x = rect.minX + Self.sidePadding
        if isStop {
            let square = NSRect(x: x, y: rect.midY - Self.stopSquare / 2, width: Self.stopSquare, height: Self.stopSquare)
            DSDraw.fill(square, radius: 2, color: appearanceState == .stopping ? DS.Color.text4 : DS.Color.danger)
            x = square.maxX + Self.iconGap
        } else if let name = symbolName {
            let weight: NSFont.Weight = label == nil ? .semibold : .medium
            if let image = DSDraw.symbol(name, pointSize: label == nil ? 14 : 12, weight: weight) {
                let box = label == nil ? rect : NSRect(x: x, y: rect.minY, width: 14, height: rect.height)
                DSDraw.draw(template: image, in: box, color: foreground)
                x += 14 + Self.iconGap
            }
        }
        if let label {
            DSDraw.text(label, in: NSRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height), font: labelFont, color: foreground)
        }
        if window?.firstResponder === self, NSApp.isFullKeyboardAccessEnabled {
            DSDraw.ring(rect.insetBy(dx: 1, dy: 1), radius: radius - 1, color: DS.Color.focusRing, width: DS.Border.focusRing)
        }
    }
}

/// The inline error line: triangle `dangerText`, message `label` `text`, a ghost dismiss. Text plus icon, never colour
/// alone.
@MainActor
final class ComposerErrorView: NSView {
    let label = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private let dismiss = DSButton(icon: "xmark", accessibilityTitle: "Dismiss error", size: .small)
    var onDismiss: (() -> Void)?

    init(style: ComposerStyle) {
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Error")
        icon.contentTintColor = DS.Color.dangerText
        icon.symbolConfiguration = .init(pointSize: DS.Size.iconPointRow, weight: .regular)
        label.font = DS.TextRole.label.font
        label.textColor = DS.Color.text
        label.isSelectable = true
        label.maximumNumberOfLines = 3
        dismiss.toolTip = "Dismiss"
        dismiss.target = self
        dismiss.action = #selector(dismissPressed)
        for view in [icon, label, dismiss] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            dismiss.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            dismiss.trailingAnchor.constraint(equalTo: trailingAnchor),
            dismiss.topAnchor.constraint(equalTo: topAnchor),
            dismiss.widthAnchor.constraint(equalToConstant: DS.Size.micro),
            dismiss.heightAnchor.constraint(equalToConstant: DS.Size.micro),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ message: String) {
        label.stringValue = message
        setAccessibilityLabel("Error: \(message)")
    }

    @objc private func dismissPressed() { onDismiss?() }
}

/// The composer container: the composer glass surface (`raised` 80 % over the within-window material; solid `raised`
/// under Reduce Transparency and in snapshots), `r.xl`, `composerOutline` ring with the dark inner highlight and
/// `shadow.composer`. Focus: the outline strengthens to `borderStrong` (accent under Increase Contrast); the caret
/// carries focus, so there is no accent halo around the whole card. Content goes in `contentView`.
@MainActor
final class ComposerCardView: NSView {
    var style: ComposerStyle { didSet { glass.radius = style.cornerRadius; ring.needsDisplay = true } }
    var isFocused = false {
        didSet { if isFocused != oldValue { ring.isFocused = isFocused } }
    }
    let glass = DSGlassView(surface: .composer)
    var contentView: NSView { glass.contentView }
    private let ring = FocusRingView()

    init(style: ComposerStyle) {
        self.style = style
        super.init(frame: .zero)
        glass.radius = style.cornerRadius
        for view in [glass, ring] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        ring.card = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // Keep the focus ring above anything added later.
        if subview !== ring, ring.superview === self { addSubview(ring, positioned: .above, relativeTo: nil) }
    }

    /// The focus outline, drawn above the content (it never takes clicks).
    private final class FocusRingView: NSView {
        weak var card: ComposerCardView?
        var isFocused = false { didSet { needsDisplay = true } }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard isFocused, let card else { return }
            let contrast = card.style.increasedContrast
            DSDraw.ring(
                bounds, radius: card.style.cornerRadius, color: contrast ? DS.Color.focusRing : DS.Color.borderStrong,
                width: contrast ? DS.Border.focusRing : DS.Border.hairline)
        }
    }
}
