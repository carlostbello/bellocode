import AppKit

/// The "glass" floating container (visual-language.md §4): an `NSVisualEffectView` (material per `DS.Surface`) under
/// a `raised` 80 % tint, a `borderStrong` (popover) or `composerOutline` (composer) inset ring, a dark-mode top
/// highlight and the surface's shadow recipe. Under Reduce Transparency, or when `forcesSolidFallback` is set
/// (snapshots: in-process rendering cannot capture vibrancy), the material is removed and the fill is solid `raised`.
///
/// Put content in `contentView`. The view itself must not clip (it carries the shadow).
@MainActor
public final class DSGlassView: NSView {
    /// Set by snapshot harnesses and the gallery: draw the opaque fallback everywhere.
    public static var forcesSolidFallback = false

    public let surface: DS.Surface
    public let contentView = NSView()
    public var radius: CGFloat { didSet { needsLayout = true; chrome.needsDisplay = true } }
    /// Draws the shadow (popovers, palette, composer). Off for surfaces inside a panel that has its own window shadow.
    public var showsShadow = true { didSet { needsLayout = true } }

    private let effect = NSVisualEffectView()
    private let chrome: GlassChrome
    private var displayOptionsObserver: (any NSObjectProtocol)?

    public init(surface: DS.Surface = .popover, radius: CGFloat? = nil) {
        self.surface = surface
        self.radius = radius ?? (surface == .composer ? DS.Radius.xl : DS.Radius.lg)
        chrome = GlassChrome(surface: surface)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        effect.material = surface.material
        effect.blendingMode = surface.blending
        effect.state = .active
        effect.wantsLayer = true
        for view in [effect, chrome, contentView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        chrome.radius = self.radius
        displayOptionsObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyFallback() }
        }
        applyFallback()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        if let displayOptionsObserver { NotificationCenter.default.removeObserver(displayOptionsObserver) }
    }

    public override var isFlipped: Bool { true }

    /// Whether the material is replaced by the solid fallback right now.
    public var isSolid: Bool { Self.forcesSolidFallback || DS.Accessibility.reduceTransparency }

    public func applyFallback() {
        effect.isHidden = isSolid
        chrome.solid = isSolid
        chrome.needsDisplay = true
    }

    public override func layout() {
        super.layout()
        chrome.radius = radius
        effect.maskImage = Self.mask(radius: radius)
        if let layer {
            if showsShadow {
                let dark = DS.Variant(effectiveAppearance).isDark
                let recipe = surface == .composer ? DS.Shadow.composer(dark: dark) : DS.Shadow.popover(dark: dark)
                recipe.apply(to: layer, bounds: bounds, radius: radius)
            } else {
                layer.shadowOpacity = 0
            }
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        chrome.needsDisplay = true
    }

    /// A resizable rounded mask for the effect view (continuous corners need a cap-inset image).
    static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            DS.Radius.path(rect, radius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Tint, ring and highlight above the material.
@MainActor
private final class GlassChrome: NSView {
    let surface: DS.Surface
    var radius: CGFloat = DS.Radius.lg
    var solid = false

    init(surface: DS.Surface) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let fill = surface.fallback
        DSDraw.fill(bounds, radius: radius, color: solid ? fill : fill.withAlphaComponent(surface.tintAlpha))
        let dark = DS.Variant(effectiveAppearance).isDark
        if dark {
            DSDraw.topHighlight(bounds, radius: radius, color: surface == .composer ? DS.Color.composerHighlight : DS.Shadow.popoverHighlight.nsColor)
        }
        if surface != .sidebar {
            DSDraw.ring(bounds, radius: radius, color: surface == .composer ? DS.Color.composerOutline : DS.Color.borderStrong)
        }
    }
}

// MARK: - Row backgrounds

/// What a list row looks like: rest, hover (`rowHover`), selected (multi-select, `rowSelected`), active (the current
/// thread, `rowActive`), with an optional keyboard focus ring. Never the accent colour.
public enum DSRowStyle: Hashable, Sendable {
    case rest, hover, selected, active

    /// The fill token name and whether light mode adds the `rowRing` inset ring.
    public var fill: NSColor? {
        switch self {
        case .rest: nil
        case .hover: DS.Color.rowHover
        case .selected: DS.Color.rowSelected
        case .active: DS.Color.rowActive
        }
    }

    public var hasRing: Bool { self == .selected || self == .active }

    public static func resolve(hovered: Bool, selected: Bool, active: Bool) -> DSRowStyle {
        if active { return .active }
        if selected { return .selected }
        if hovered { return .hover }
        return .rest
    }
}

@MainActor
enum DSRowDrawing {
    static func draw(_ style: DSRowStyle, focused: Bool, in rect: NSRect, radius: CGFloat) {
        if let fill = style.fill { DSDraw.fill(rect, radius: radius, color: fill) }
        if style.hasRing { DSDraw.ring(rect, radius: radius, color: DS.Color.rowRing) }
        if focused { DSDraw.ring(rect, radius: radius, color: DS.Color.focusRing, width: DS.Border.focusRing) }
    }
}

/// An `NSTableRowView` that draws the row recipe (6 pt radius, inset 8 from the table edges) instead of the system
/// selection. Use with `selectionHighlightStyle = .none` and `.plain` style. Set `isActive` for the current thread;
/// `isSelected` comes from the table; hover is tracked here. One fill per row: cheap in virtualised lists.
@MainActor
open class DSTableRowView: NSTableRowView {
    public var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    public var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    /// Draws the keyboard focus ring (the table is first responder under Full Keyboard Access and this is its row).
    public var showsFocusRing = false { didSet { if showsFocusRing != oldValue { needsDisplay = true } } }
    public var horizontalInset: CGFloat = DS.Size.sidebarRowInset { didSet { needsDisplay = true } }
    public var verticalInset: CGFloat = 1 { didSet { needsDisplay = true } }
    public var radius: CGFloat = DS.Radius.sm
    public var tracksHover = true

    private var hoverArea: NSTrackingArea?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var rowStyle: DSRowStyle { .resolve(hovered: isHovered, selected: isSelected, active: isActive) }

    open override var isSelected: Bool { didSet { if isSelected != oldValue { needsDisplay = true } } }

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard tracksHover else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    open override func mouseEntered(with event: NSEvent) { isHovered = true }
    open override func mouseExited(with event: NSEvent) { isHovered = false }

    open override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        isActive = false
        showsFocusRing = false
    }

    open override func drawBackground(in dirtyRect: NSRect) {}
    open override func drawSelection(in dirtyRect: NSRect) {}
    open override func drawSeparator(in dirtyRect: NSRect) {}

    open override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        DSRowDrawing.draw(rowStyle, focused: showsFocusRing, in: rect, radius: radius)
    }

    /// Row content stays `text` on our neutral washes (never the inverted selection text).
    open override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// The same recipe as a plain view (menu rows, palette rows, custom lists).
@MainActor
public final class DSRowBackgroundView: NSView {
    public var style: DSRowStyle = .rest { didSet { if style != oldValue { needsDisplay = true } } }
    public var showsFocusRing = false { didSet { needsDisplay = true } }
    public var radius: CGFloat = DS.Radius.sm { didSet { needsDisplay = true } }
    public var insets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) { didSet { needsDisplay = true } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(
            x: bounds.minX + insets.left, y: bounds.minY + insets.bottom, width: bounds.width - insets.left - insets.right,
            height: bounds.height - insets.top - insets.bottom)
        DSRowDrawing.draw(style, focused: showsFocusRing, in: rect, radius: radius)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Scroller

/// Overlay scroller (visual-language.md §6): a 6 pt knob, radius 3, `scrollThumb` (hover `scrollThumbHover`), no track.
/// Install with `DSScroller.install(on:)`; AppKit still decides overlay vs legacy from the user's setting, and in legacy
/// mode the knob keeps this look on a clear slot.
@MainActor
public final class DSScroller: NSScroller {
    private var isHovering = false

    public override class var isCompatibleWithOverlayScrollers: Bool { true }

    public static func install(on scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        if scrollView.hasVerticalScroller { scrollView.verticalScroller = DSScroller() }
        if scrollView.hasHorizontalScroller { scrollView.horizontalScroller = DSScroller() }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); isHovering = true; needsDisplay = true }
    public override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); isHovering = false; needsDisplay = true }

    public override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    public override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let vertical = bounds.height > bounds.width
        let width = DS.Size.scrollerKnobWidth
        let rect = vertical
            ? NSRect(x: knob.maxX - width - 3, y: knob.minY + 2, width: width, height: max(0, knob.height - 4))
            : NSRect(x: knob.minX + 2, y: knob.maxY - width - 3, width: max(0, knob.width - 4), height: width)
        DSDraw.fill(rect, radius: width / 2, color: isHovering ? DS.Color.scrollThumbHover : DS.Color.scrollThumb)
    }
}
