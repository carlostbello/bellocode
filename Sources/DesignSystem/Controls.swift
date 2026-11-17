import AppKit

// Shared AppKit controls that predate the visual language, restyled onto it (CountBadge, EmptyStateView, UndoToastView).
// New controls live in `Controls/`.

// MARK: - Count badge

/// A count ("3"), hidden when zero. Prominent (attention) counts are a pill: the tint's 16 % (dark) / 10 % (light)
/// surface with the tint as text ("Needs you 2"); others are plain `meta` digits in the tint (`text3` by default).
/// Accessibility: "<count> <noun>".
@MainActor
public final class CountBadge: NSView {
    public var noun = "items" { didSet { updateAccessibility() } }
    public var tint: NSColor = DS.Color.text3 { didSet { needsDisplay = true } }
    public var isProminent = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    public var count = 0 {
        didSet {
            guard count != oldValue else { return }
            isHidden = count == 0
            invalidateIntrinsicContentSize()
            needsDisplay = true
            updateAccessibility()
        }
    }

    private var text: String { count > 999 ? "999+" : "\(count)" }
    private var font: NSFont { DS.TextRole.metaEmph.font(base: DS.Typography.current.baseSize, monospacedDigits: true) }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        let width = DSDraw.width(of: text, font: font)
        return isProminent ? NSSize(width: max(DS.Size.pill, width + 10), height: DS.Size.pill) : NSSize(width: width + 2, height: 16)
    }

    public override func draw(_ dirtyRect: NSRect) {
        if isProminent {
            let dark = DS.Variant(effectiveAppearance).isDark
            DSDraw.fill(bounds, radius: DS.Radius.xs, color: tint.withAlphaComponent(dark ? 0.16 : 0.1))
        }
        DSDraw.text(text, in: bounds, font: font, color: tint, alignment: .center)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func updateAccessibility() {
        setAccessibilityLabel("\(count) \(noun)")
    }
}

// MARK: - Empty state

/// A centred empty, offline or failure state (visual-language.md §6): 32 pt glyph `text4`, `body` title, `label text2`
/// hint, one outline button. No illustrations; never a bare spinner.
@MainActor
public final class EmptyStateView: NSView {
    public let symbol = NSImageView()
    public let title = NSTextField(labelWithString: "")
    public let detail = NSTextField(wrappingLabelWithString: "")
    public let button: DSButton

    public init(symbolName: String, title: String, detail: String, actionTitle: String? = nil, action: Selector? = nil) {
        button = DSButton(title: actionTitle ?? "", variant: .outline, action: action)
        super.init(frame: .zero)
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .light))
        symbol.contentTintColor = DS.Color.text4
        self.title.stringValue = title
        self.title.font = DS.TextRole.bodyEmph.font
        self.title.textColor = DS.Color.text
        self.title.alignment = .center
        self.detail.stringValue = detail
        self.detail.font = DS.TextRole.label.font
        self.detail.textColor = DS.Color.text2
        self.detail.alignment = .center
        self.detail.preferredMaxLayoutWidth = 320
        button.isHidden = actionTitle == nil

        let stack = NSStackView(views: [symbol, self.title, self.detail, button])
        stack.orientation = .vertical
        stack.spacing = DS.Space.s6
        stack.setCustomSpacing(DS.Space.s10, after: symbol)
        stack.setCustomSpacing(DS.Space.s14, after: self.detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.detachesHiddenViews = true
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -DS.Space.s24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: DS.Space.s16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Space.s16),
            self.detail.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - Undo toast

/// "Archived 'Fix tests'  [Undo]" (visual-language.md §6 Toast): glass, `r.lg`, 36 high, icon + text + ghost "Undo".
/// The owner decides when to show and hide it (`DS.Motion.toastDismissDelay`, 6 s); showing and hiding are instant.
@MainActor
public final class UndoToastView: NSView {
    public let message = NSTextField(labelWithString: "")
    public let undoButton = DSButton(title: "Undo", variant: .ghost, size: .small)
    public let icon = NSImageView()
    private let glass = DSGlassView(surface: .popover, radius: DS.Radius.lg)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        message.font = DS.TextRole.body.font
        message.textColor = DS.Color.text
        message.lineBreakMode = .byTruncatingMiddle
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: DS.Size.iconPointRow, weight: .regular))
        icon.contentTintColor = DS.Color.icon
        let stack = NSStackView(views: [icon, message, undoButton])
        stack.spacing = DS.Space.s8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: DS.Space.s12, bottom: 0, right: DS.Space.s6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: DS.Size.toast),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `text` and announces it to VoiceOver.
    public func show(_ text: String) {
        glass.applyFallback()
        message.stringValue = text
        setAccessibilityLabel(text)
        alphaValue = 1
        isHidden = false
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [.announcement: "\(text). Undo available.", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    public func hide() {
        isHidden = true
    }
}
