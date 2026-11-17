import AppKit

// Small display views: pill, key cap, divider, card, project icon. All draw in one `draw(_:)` from tokens, so they are
// cheap enough for virtualised rows.

/// A status, count or tag pill (visual-language.md §6): 18 high, padding 6, radius 4, tone surface fill + tone text,
/// `metaEmph`. Optional leading glyph (a symbol or the spinner). Accessibility: static text with `title`.
@MainActor
public final class DSPill: NSView {
    public var title: String { didSet { invalidate() } }
    public var tone: DS.Tone { didSet { needsDisplay = true } }
    public var symbolName: String? { didSet { invalidate() } }
    /// Draws the arc spinner as the leading glyph ("2 running").
    public var showsSpinner = false {
        didSet {
            invalidate()
            updateSpin()
        }
    }

    public init(_ title: String, tone: DS.Tone = .neutral, symbolName: String? = nil) {
        self.title = title
        self.tone = tone
        self.symbolName = symbolName
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    private var hasGlyph: Bool { symbolName != nil || showsSpinner }

    public override var intrinsicContentSize: NSSize {
        let text = DSDraw.width(of: title, font: DS.TextRole.metaEmph.font, kern: DS.TextRole.meta.spec.tracking)
        return NSSize(width: max(DS.Size.pill, text + DS.Space.s6 * 2 + (hasGlyph ? 14 : 0)), height: DS.Size.pill)
    }

    private func invalidate() {
        setAccessibilityLabel(title)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let colors = DS.Color.tone(tone)
        DSDraw.fill(bounds, radius: DS.Radius.xs, color: colors.surface)
        let textColor = tone == .neutral ? DS.Color.text2 : colors.text
        var x = bounds.minX + DS.Space.s6
        if showsSpinner {
            DSSpinner.draw(in: NSRect(x: x - 1, y: 0, width: 12, height: bounds.height), diameter: 10, step: DSStepClock.shared.step, head: textColor)
            x += 14
        } else if let symbolName, let image = DSDraw.symbol(symbolName, pointSize: DS.Size.iconPointMeta, weight: .semibold) {
            DSDraw.draw(template: image, in: NSRect(x: x - 1, y: 0, width: 12, height: bounds.height), color: textColor)
            x += 14
        }
        DSDraw.text(
            title, in: NSRect(x: x, y: 0, width: bounds.maxX - x - DS.Space.s6 + 2, height: bounds.height),
            font: DS.TextRole.metaEmph.font, color: textColor, alignment: hasGlyph ? .left : .center,
            kern: DS.TextRole.meta.spec.tracking)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSpin()
    }

    private func updateSpin() {
        if showsSpinner, window != nil, !DS.Motion.reduceMotion { DSStepClock.shared.subscribe(self) } else { DSStepClock.shared.unsubscribe(self) }
    }
}

/// A key cap ("⌘K", "esc"): 18 high, min 18 wide, radius 4, `kbdFill`, `metaEmph` `text2`. Hidden from VoiceOver by
/// default (the owning control names the shortcut in its help).
@MainActor
public final class DSKbd: NSView {
    public var keys: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    public init(_ keys: String) {
        self.keys = keys
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: max(DS.Size.kbd, DSDraw.width(of: keys, font: DS.TextRole.metaEmph.font, kern: 0.5) + 10), height: DS.Size.kbd)
    }

    public override func draw(_ dirtyRect: NSRect) {
        DSDraw.fill(bounds, radius: DS.Radius.xs, color: DS.Color.kbdFill)
        DSDraw.text(keys, in: bounds.insetBy(dx: 4, dy: 0), font: DS.TextRole.metaEmph.font, color: DS.Color.text2, alignment: .center, kern: 0.5)
    }
}

/// A 1 px `border` hairline, horizontal or vertical (by aspect). Inset dividers set their own frame.
@MainActor
public final class DSDivider: NSView {
    public var color: NSColor = DS.Color.border { didSet { needsDisplay = true } }
    public var isVertical: Bool

    public init(vertical: Bool = false) {
        isVertical = vertical
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        if vertical {
            setContentHuggingPriority(.required, for: .horizontal)
        } else {
            setContentHuggingPriority(.required, for: .vertical)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize {
        isVertical ? NSSize(width: 1, height: NSView.noIntrinsicMetric) : NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        layer?.backgroundColor = color.cgColor
    }
}

/// A container surface (visual-language.md §4, §6): `.raised` (composer-family cards: `raised`, `r.xl`, outline),
/// `.inset` (code blocks, report boxes: `codeFill`, `r.md`, no border in dark, `border` 70 % in light), `.tinted`
/// (semantic 4.5 % over `raised`), `.message` (user bubble). Subviews go directly inside.
@MainActor
public final class DSCard: NSView {
    public enum Style: Hashable, Sendable {
        case raised
        case inset
        case tinted(DS.Tone)
        case message
    }

    public var style: Style { didSet { needsDisplay = true } }
    public var radius: CGFloat? { didSet { needsDisplay = true } }

    public init(style: Style = .raised) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public var effectiveRadius: CGFloat {
        radius ?? {
            switch style {
            case .inset: DS.Radius.md
            default: DS.Radius.xl
            }
        }()
    }

    public override func draw(_ dirtyRect: NSRect) {
        let dark = DS.Variant(effectiveAppearance).isDark
        let r = effectiveRadius
        switch style {
        case .raised:
            DSDraw.fill(bounds, radius: r, color: DS.Color.raised)
            if dark { DSDraw.topHighlight(bounds, radius: r, color: DS.Color.composerHighlight) }
            DSDraw.ring(bounds, radius: r, color: DS.Color.composerOutline)
        case .inset:
            DSDraw.fill(bounds, radius: r, color: DS.Color.codeFill)
            if !dark { DSDraw.ring(bounds, radius: r, color: DS.Color.border.withAlphaComponent(0.7)) }
        case .tinted(let tone):
            DSDraw.fill(bounds, radius: r, color: DS.Color.raised)
            DSDraw.fill(bounds, radius: r, color: DS.Color.tone(tone).fill.withAlphaComponent(0.045))
            DSDraw.ring(bounds, radius: r, color: DS.Color.composerOutline)
        case .message:
            DSDraw.fill(bounds, radius: r, color: DS.Color.message)
        }
    }
}

/// A project's icon (replaces the coloured monogram): its favicon if it has one, else a `folder` glyph tinted `icon`,
/// 14 pt in a 16 pt box. Decorative: the project name is always shown beside it.
@MainActor
public final class ProjectIcon: NSView {
    /// The project's favicon (T3 `ProjectFavicon.tsx`), if found.
    public var favicon: NSImage? { didSet { needsDisplay = true } }
    public var symbolName = "folder" { didSet { needsDisplay = true } }
    public var tint: NSColor = DS.Color.icon { didSet { needsDisplay = true } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: DS.Size.iconBox, height: DS.Size.iconBox) }
    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        if let favicon {
            let side: CGFloat = 14
            let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            NSGraphicsContext.saveGraphicsState()
            DS.Radius.path(rect, radius: 3).addClip()
            favicon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        } else if let image = DSDraw.symbol(symbolName, pointSize: DS.Size.iconPoint) {
            DSDraw.draw(template: image, in: bounds, color: tint)
        }
    }
}
