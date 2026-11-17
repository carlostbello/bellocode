import AppKit

/// A custom-drawn button (visual-language.md §6 "Buttons"): primary, outline, ghost, destructive, each regular (28)
/// or small (24), with an optional leading SF Symbol, an optional trailing chevron (selects) and an optional shortcut
/// hint inside the button. Without a title it is an icon button (square, ghost recipe, `icon` tint → `text` on hover).
///
/// The hint is dropped before the title truncates. Accessibility: role button, label = title (or `accessibilityTitle`
/// for icon buttons), help = the shortcut.
@MainActor
open class DSButton: DSControl {
    public enum Variant: String, Sendable, CaseIterable { case primary, outline, ghost, destructive }
    public enum Size: String, Sendable, CaseIterable { case regular, small }

    public var variant: Variant { didSet { invalidate() } }
    public var size: Size { didSet { invalidate() } }
    public var title: String { didSet { invalidate(); updateAccessibility() } }
    /// Leading SF Symbol name.
    public var symbolName: String? { didSet { invalidate() } }
    /// Shortcut hint such as "⌥⌘Y", drawn after the title at 62 % opacity.
    public var shortcutHint: String? { didSet { invalidate(); updateAccessibility() } }
    /// A trailing chevron (`chevron.down` or `chevron.up.chevron.down`), for select triggers.
    public var trailingSymbolName: String? { didSet { invalidate() } }
    /// Ghost only: `text2` label at rest (toolbars, composer controls).
    public var isMuted = false { didSet { needsDisplay = true } }
    /// A toggle (panel toggles, "on" = `fillHover`); clicking flips `isSelected`.
    public var isToggle = false
    /// The label VoiceOver reads for icon-only buttons.
    public var accessibilityTitle: String? { didSet { updateAccessibility() } }
    /// Content inset override (composer controls use 8).
    public var horizontalPadding: CGFloat? { didSet { invalidate() } }

    public init(
        title: String = "", variant: Variant = .outline, size: Size = .regular, symbolName: String? = nil,
        shortcutHint: String? = nil, target: AnyObject? = nil, action: Selector? = nil
    ) {
        self.title = title
        self.variant = variant
        self.size = size
        self.symbolName = symbolName
        self.shortcutHint = shortcutHint
        super.init(frame: .zero)
        self.target = target
        self.action = action
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        updateAccessibility()
    }

    /// An icon-only button (28×28, or 24×24 small).
    public convenience init(icon symbolName: String, accessibilityTitle: String, size: Size = .regular, target: AnyObject? = nil, action: Selector? = nil) {
        self.init(title: "", variant: .ghost, size: size, symbolName: symbolName, target: target, action: action)
        self.accessibilityTitle = accessibilityTitle
        updateAccessibility()
    }

    open override var scalesWhenPressed: Bool { true }

    public var isIconOnly: Bool { title.isEmpty && symbolName != nil }

    // MARK: Metrics

    public var height: CGFloat { size == .regular ? DS.Size.control : DS.Size.controlSmall }
    public var padding: CGFloat { horizontalPadding ?? (size == .regular ? DS.Space.s10 : DS.Space.s8) }
    public var radius: CGFloat { size == .regular ? DS.Radius.md : DS.Radius.sm }
    public var titleFont: NSFont { size == .regular ? DS.TextRole.bodyEmph.font : DS.TextRole.labelEmph.font }
    public var hintFont: NSFont { DS.TextRole.metaEmph.font }
    private var iconPoint: CGFloat { size == .regular ? DS.Size.iconPoint : DS.Size.iconPointRow }
    private static let iconGap: CGFloat = 6
    private static let hintGap: CGFloat = 4 + 2

    /// Widths of the parts at the current fonts.
    private var parts: (icon: CGFloat, title: CGFloat, hint: CGFloat, trailing: CGFloat) {
        let icon: CGFloat = symbolName == nil ? 0 : DS.Size.iconBox
        let titleWidth = title.isEmpty ? 0 : DSDraw.width(of: title, font: titleFont)
        let hint = (shortcutHint?.isEmpty ?? true) ? 0 : DSDraw.width(of: shortcutHint!, font: hintFont, kern: 0.5)
        let trailing: CGFloat = trailingSymbolName == nil ? 0 : 12
        return (icon, titleWidth, hint, trailing)
    }

    /// Width with everything shown.
    public var fullWidth: CGFloat {
        if isIconOnly && trailingSymbolName == nil { return height }
        let p = parts
        var width = padding * 2 + p.icon + p.title + p.trailing
        if p.icon > 0, p.title > 0 { width += Self.iconGap }
        if p.hint > 0 { width += Self.hintGap + p.hint }
        if p.trailing > 0 { width += 4 }
        return ceil(width)
    }

    open override var intrinsicContentSize: NSSize { NSSize(width: fullWidth, height: height) }

    /// Whether the hint fits at the current width (it is dropped before the title truncates).
    public var showsHint: Bool {
        guard let hint = shortcutHint, !hint.isEmpty else { return false }
        return bounds.width >= fullWidth - 0.5 || bounds.width == 0
    }

    private func invalidate() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private func updateAccessibility() {
        setAccessibilityRole(.button)
        setAccessibilityLabel(title.isEmpty ? (accessibilityTitle ?? symbolName ?? "") : title)
        setAccessibilityHelp(shortcutHint.map { "Shortcut \($0)" })
        toolTip = isIconOnly ? [accessibilityTitle, shortcutHint].compactMap { $0 }.joined(separator: "  ") : toolTip
    }

    open override func controlStateDidChange(from old: DSControlState) {
        if isToggle { setAccessibilityValue(isSelected ? 1 : 0) }
    }

    open override func activate() {
        if isToggle { isSelected.toggle() }
        super.activate()
    }

    // MARK: Drawing

    open override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let recipe = DSButtonRecipe(variant: isIconOnly ? .ghost : variant, state: controlState, muted: isMuted, iconOnly: isIconOnly)
        if recipe.shadow, controlState.phase != .pressed {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = DS.Color.accent.withAlphaComponent(0.24)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 2
            shadow.set()
            DSDraw.fill(rect.insetBy(dx: 0, dy: 1), radius: radius, color: recipe.fill ?? .clear)
            NSGraphicsContext.restoreGraphicsState()
        }
        if let fill = recipe.fill { DSDraw.fill(rect, radius: radius, color: fill) }
        if recipe.topHighlight {
            DSDraw.topHighlight(rect, radius: radius, color: DS.Shadow.buttonHighlight.nsColor)
        }
        if controlState.phase == .pressed, recipe.fill != nil, variant != .ghost {
            DSDraw.topHighlight(rect, radius: radius, color: DS.Shadow.buttonPressedShade.nsColor)
        }
        if let ring = recipe.ring { DSDraw.ring(rect, radius: radius, color: ring) }

        drawContent(in: rect, recipe: recipe)
        drawFocusRingIfNeeded(in: rect, radius: radius)
    }

    private func drawContent(in rect: NSRect, recipe: DSButtonRecipe) {
        let p = parts
        if isIconOnly && trailingSymbolName == nil {
            if let name = symbolName, let image = DSDraw.symbol(name, pointSize: iconPoint) {
                DSDraw.draw(template: image, in: rect, color: recipe.icon)
            }
            return
        }
        let hint = showsHint ? shortcutHint : nil
        var contentWidth = p.icon + p.title + p.trailing
        if p.icon > 0, p.title > 0 { contentWidth += Self.iconGap }
        if hint != nil { contentWidth += Self.hintGap + p.hint }
        if p.trailing > 0 { contentWidth += 4 }
        let available = rect.width - padding * 2
        var x = rect.minX + padding + max(0, (available - contentWidth) / 2)
        if let name = symbolName, let image = DSDraw.symbol(name, pointSize: iconPoint) {
            DSDraw.draw(template: image, in: NSRect(x: x, y: rect.minY, width: DS.Size.iconBox, height: rect.height), color: recipe.icon)
            x += DS.Size.iconBox + (p.title > 0 ? Self.iconGap : 0)
        }
        let trailingSpace = (hint != nil ? Self.hintGap + p.hint : 0) + (p.trailing > 0 ? 4 + p.trailing : 0)
        let titleWidth = max(0, min(p.title, rect.maxX - padding - trailingSpace - x))
        if !title.isEmpty {
            DSDraw.text(title, in: NSRect(x: x, y: rect.minY, width: titleWidth + 1, height: rect.height), font: titleFont, color: recipe.text)
            x += titleWidth
        }
        if let hint {
            x += Self.hintGap
            DSDraw.text(
                hint, in: NSRect(x: x, y: rect.minY, width: p.hint + 1, height: rect.height), font: hintFont,
                color: recipe.text.withAlphaComponent(0.62), kern: 0.5)
            x += p.hint
        }
        if let trailing = trailingSymbolName, let image = DSDraw.symbol(trailing, pointSize: 9, weight: .semibold) {
            x += 4
            DSDraw.draw(template: image, in: NSRect(x: x, y: rect.minY, width: 12, height: rect.height), color: recipe.chevron)
        }
    }
}

/// The colours a button draws with for a variant and state. Pure: unit-tested without drawing.
public struct DSButtonRecipe: Sendable {
    public var fill: NSColor?
    public var ring: NSColor?
    public var text: NSColor
    public var icon: NSColor
    public var chevron: NSColor
    public var topHighlight: Bool
    public var shadow: Bool

    public init(variant: DSButton.Variant, state: DSControlState, muted: Bool = false, iconOnly: Bool = false) {
        let phase = state.phase
        let active = phase == .hover || phase == .pressed
        chevron = DS.Color.text4
        switch variant {
        case .primary:
            fill = active ? DS.Color.accentHover : DS.Color.accent
            ring = nil
            text = DS.Color.onAccent
            icon = DS.Color.onAccent
            chevron = DS.Color.onAccent
            topHighlight = phase != .pressed
            shadow = true
        case .outline:
            fill = active || state.isSelected ? DSButtonColors.outlineHover : DSButtonColors.outlineFill
            ring = DS.Color.borderStrong
            text = DS.Color.text
            icon = DS.Color.text2
            topHighlight = false
            shadow = false
        case .ghost:
            fill = active || state.isSelected ? DS.Color.fillHover : nil
            ring = nil
            let quiet = (muted || iconOnly) && !active && !state.isSelected
            text = quiet ? DS.Color.text2 : DS.Color.text
            icon = quiet ? DS.Color.icon : DS.Color.text
            topHighlight = false
            shadow = false
        case .destructive:
            fill = active ? DS.Color.danger : DSButtonColors.destructiveFill
            ring = nil
            text = DS.Color.onAccent
            icon = DS.Color.onAccent
            chevron = DS.Color.onAccent
            topHighlight = phase != .pressed
            shadow = false
        }
    }
}

/// Button-only colours derived from the tokens (visual-language.md §6 table).
public enum DSButtonColors {
    /// Outline rest: `raised` (light) / white 3.5 % (dark).
    public static let outlineFill = NSColor(name: "BelloCode.outlineFill") { appearance in
        DS.Variant(appearance).isDark ? DS.RGBA.white(0.035).nsColor : DS.ColorToken.raised.value(DS.Variant(appearance)).nsColor
    }
    /// Outline hover: `fillHover` (light) / white 6 % (dark).
    public static let outlineHover = NSColor(name: "BelloCode.outlineHover") { appearance in
        let variant = DS.Variant(appearance)
        return variant.isDark ? DS.RGBA.white(variant.isHighContrast ? 0.1 : 0.06).nsColor : DS.ColorToken.fillHover.value(variant).nsColor
    }
    /// Destructive rest: `danger` 90 %.
    public static let destructiveFill = NSColor(name: "BelloCode.destructiveFill") { appearance in
        DS.ColorToken.danger.value(DS.Variant(appearance)).withAlpha(0.9).nsColor
    }
}
