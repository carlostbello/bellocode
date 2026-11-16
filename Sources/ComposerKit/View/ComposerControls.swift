import AppKit

/// The primary button: a round arrow when idle; a labelled pill ("Queue", "Steer", "Stop", "Stopping…") while the agent
/// runs, so the action is never conveyed by colour or icon alone. Drawn in `draw(_:)` (no layer styling), so
/// snapshots and increased contrast render it faithfully.
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

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .noImage
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private var label: String? {
        switch appearanceState {
        case .send: nil
        case .followUp(let delivery): delivery.title
        case .stop: "Stop"
        case .stopping: "Stopping…"
        }
    }

    private var symbolName: String {
        switch appearanceState {
        case .send: "arrow.up"
        case .followUp(.steer): "arrow.turn.down.right"
        case .followUp: "text.line.last.and.arrowtriangle.forward"
        case .stop, .stopping: "stop.fill"
        }
    }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), .foregroundColor: foreground]
    }

    override var intrinsicContentSize: NSSize {
        let height = style.controlHeight
        guard let label else { return NSSize(width: height, height: height) }
        let width = (label as NSString).size(withAttributes: labelAttributes).width
        return NSSize(width: ceil(width) + 12 + 14 + 10, height: height)
    }

    private var fill: NSColor {
        switch appearanceState {
        case .send(let enabled): enabled ? style.accentColor : .quaternaryLabelColor
        case .followUp: style.accentColor
        case .stop: .labelColor
        case .stopping: .tertiaryLabelColor
        }
    }

    private var foreground: NSColor {
        switch appearanceState {
        case .send(let enabled): enabled ? .white : .tertiaryLabelColor
        case .followUp: .white
        case .stop, .stopping: .textBackgroundColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        (isHighlighted ? fill.blended(withFraction: 0.2, of: .black) ?? fill : fill).setFill()
        path.fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: label == nil ? 12 : 10, weight: .bold)
            .applying(.init(paletteColors: [foreground]))
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let size = image.size
            let x = label == nil ? rect.midX - size.width / 2 : rect.minX + 10
            image.draw(in: NSRect(x: x, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
        if let label {
            let text = NSAttributedString(string: label, attributes: labelAttributes)
            let size = text.size()
            text.draw(at: NSPoint(x: rect.minX + 10 + 14 + 2, y: rect.midY - size.height / 2))
        }
        if window?.firstResponder === self, NSApp.isFullKeyboardAccessEnabled {
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// The inline error line: icon, message and a dismiss button. Text plus icon, never colour alone.
@MainActor
final class ComposerErrorView: NSView {
    let label = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private let dismiss = NSButton()
    var onDismiss: (() -> Void)?

    init(style: ComposerStyle) {
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")
        icon.contentTintColor = style.errorColor
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = style.textColor
        label.isSelectable = true
        label.maximumNumberOfLines = 3
        dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        dismiss.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        dismiss.isBordered = false
        dismiss.contentTintColor = .secondaryLabelColor
        dismiss.setAccessibilityLabel("Dismiss error")
        dismiss.toolTip = "Dismiss"
        dismiss.target = self
        dismiss.action = #selector(dismissPressed)
        for view in [icon, label, dismiss] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            dismiss.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            dismiss.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            dismiss.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            dismiss.widthAnchor.constraint(equalToConstant: 16),
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

/// The rounded card behind chips, text and controls. Its border turns to the focus colour while the text has focus
/// (a ring around the whole field, like a search field, rather than around the scrolling text only).
@MainActor
final class ComposerCardView: NSView {
    var style: ComposerStyle { didSet { needsDisplay = true } }
    var isFocused = false {
        didSet { if isFocused != oldValue { needsDisplay = true } }
    }

    init(style: ComposerStyle) {
        self.style = style
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isFocused ? 1.5 : 0.5
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: style.cornerRadius, yRadius: style.cornerRadius
        )
        style.cardBackgroundColor.setFill()
        path.fill()
        if isFocused {
            style.focusBorderColor.withAlphaComponent(style.increasedContrast ? 1 : 0.6).setStroke()
            path.lineWidth = style.increasedContrast ? 3 : 2.5
        } else {
            (style.increasedContrast ? NSColor.labelColor.withAlphaComponent(0.55) : style.borderColor).setStroke()
            path.lineWidth = style.borderWidth
        }
        path.stroke()
    }
}
