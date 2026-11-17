import AppKit
import QuartzCore

// visual-language.md §3 (spacing, sizing, radii), §4 (borders, shadows, materials) and §7 (motion).

extension DS {
    /// The spacing scale (pt). Whitespace comes from the 736 column and 24 gutters, not from padding in controls.
    public enum Space {
        public static let s2: CGFloat = 2
        public static let s4: CGFloat = 4
        public static let s6: CGFloat = 6
        public static let s8: CGFloat = 8
        public static let s10: CGFloat = 10
        public static let s12: CGFloat = 12
        public static let s14: CGFloat = 14
        public static let s16: CGFloat = 16
        public static let s20: CGFloat = 20
        public static let s24: CGFloat = 24
        public static let scale: [CGFloat] = [2, 4, 6, 8, 10, 12, 14, 16, 20, 24]
    }

    /// Fixed sizes of regions, rows and controls (desktop density).
    public enum Size {
        public static let header: CGFloat = 52
        public static let sidebarWidth: CGFloat = 264
        public static let sidebarMinWidth: CGFloat = 220
        public static let sidebarMaxWidth: CGFloat = 360
        public static let rightPanelWidth: CGFloat = 416
        public static let rightPanelMinWidth: CGFloat = 320
        public static let contentMaxWidth: CGFloat = 736
        public static let gutter: CGFloat = 24

        public static let sidebarRow: CGFloat = 28
        public static let sidebarRowTwoLine: CGFloat = 40
        public static let sidebarRowInset: CGFloat = 8
        public static let sidebarContentInset: CGFloat = 10
        public static let sidebarProjectRow: CGFloat = 30
        public static let sidebarGroupLabel: CGFloat = 24
        public static let sidebarTitleColumn: CGFloat = 34
        public static let sidebarChildIndent: CGFloat = 22
        public static let sidebarFooter: CGFloat = 44

        public static let control: CGFloat = 28
        public static let controlSmall: CGFloat = 24
        public static let composerControl: CGFloat = 26
        public static let send: CGFloat = 30
        public static let micro: CGFloat = 20
        public static let menuRow: CGFloat = 28
        public static let menuGroupHeader: CGFloat = 26
        public static let paletteRow: CGFloat = 34
        public static let paletteInput: CGFloat = 48
        public static let paletteWidth: CGFloat = 600
        public static let paletteTop: CGFloat = 96
        public static let paletteFooter: CGFloat = 38
        public static let tabBar: CGFloat = 40
        public static let tab: CGFloat = 26
        public static let toolbar: CGFloat = 36
        public static let terminalTabStrip: CGFloat = 32
        public static let kbd: CGFloat = 18
        public static let pill: CGFloat = 18
        public static let toast: CGFloat = 36
        public static let toolRow: CGFloat = 26
        public static let fileRow: CGFloat = 26
        public static let diffLine: CGFloat = 19
        public static let diffGutter: CGFloat = 34
        public static let diffFileHeader: CGFloat = 34
        public static let diffHunkBar: CGFloat = 24
        public static let codeBlockHeader: CGFloat = 28

        public static let iconBox: CGFloat = 16
        /// SF Symbol point sizes: in a 16 pt box, in rows, in metadata.
        public static let iconPoint: CGFloat = 13
        public static let iconPointRow: CGFloat = 12
        public static let iconPointMeta: CGFloat = 10
        public static let statusGlyph: CGFloat = 14
        public static let checkbox: CGFloat = 14
        public static let switchSize = NSSize(width: 26, height: 16)
        public static let scrollerKnobWidth: CGFloat = 6
    }

    /// Border recipes: 1 px hairlines drawn inside the shape (inset ring), never outside.
    public enum Border {
        public static let hairline: CGFloat = 1
        public static let focusRing: CGFloat = 2
        public static let fieldFocusRing: CGFloat = 1
        public static let fieldFocusHalo: CGFloat = 3
    }

    /// A shadow: offset y, blur radius, spread (negative shrinks) and opacity of `DS.Color.shadow` (black).
    public struct ShadowRecipe: Sendable, Hashable {
        public var y: CGFloat
        public var blur: CGFloat
        public var spread: CGFloat
        public var opacity: Float
        public var color: RGBA = .black(1)

        /// Applies to a layer whose shape is a rounded rect of `bounds` with `radius`. CALayer has no spread, so the
        /// shadow path is inset by the (negative) spread.
        @MainActor public func apply(to layer: CALayer, bounds: CGRect, radius: CGFloat) {
            layer.shadowColor = color.nsColor.cgColor
            layer.shadowOpacity = opacity
            layer.shadowOffset = CGSize(width: 0, height: -y)
            layer.shadowRadius = blur / 2
            let rect = bounds.insetBy(dx: -spread, dy: -spread)
            layer.shadowPath = CGPath(roundedRect: rect, cornerWidth: max(0, radius + spread), cornerHeight: max(0, radius + spread), transform: nil)
        }
    }

    public enum Shadow {
        public static func composer(dark: Bool) -> ShadowRecipe {
            dark ? ShadowRecipe(y: 14, blur: 32, spread: -18, opacity: 0.75) : ShadowRecipe(y: 1, blur: 2, spread: 0, opacity: 0.05)
        }
        public static func popover(dark: Bool) -> ShadowRecipe {
            dark ? ShadowRecipe(y: 18, blur: 44, spread: -18, opacity: 0.8) : ShadowRecipe(y: 16, blur: 40, spread: -18, opacity: 0.35)
        }
        public static let dialog = ShadowRecipe(y: 24, blur: 72, spread: -20, opacity: 0.9)
        /// Primary buttons: accent 24 % 0 1 2.
        public static let primaryButton = ShadowRecipe(y: 1, blur: 2, spread: 0, opacity: 0.24)
        /// Selected tab in light: 0 1 2 black 4 %.
        public static let selectedTabLight = ShadowRecipe(y: 1, blur: 2, spread: 0, opacity: 0.04)
        /// Inner top highlight of filled buttons (white 16 %) and pressed inner shade (black 8 %).
        public static let buttonHighlight = RGBA.white(0.16)
        public static let buttonPressedShade = RGBA.black(0.08)
        public static let popoverHighlight = RGBA.white(0.04)
    }

    /// Which native material a floating surface uses, and its opaque fallback (visual-language.md §4).
    public enum Surface: String, Sendable, CaseIterable {
        /// Menus, pickers, completion list, palette, toasts, tooltips.
        case popover
        /// Composer and attached request cards.
        case composer
        /// Optional translucent sidebar.
        case sidebar

        public var material: NSVisualEffectView.Material {
            switch self {
            case .popover: .popover
            case .composer: .headerView
            case .sidebar: .sidebar
            }
        }

        public var blending: NSVisualEffectView.BlendingMode {
            switch self {
            case .popover, .sidebar: .behindWindow
            case .composer: .withinWindow
            }
        }

        /// The tint over the material (`raised` 80 %), and the solid colour used under Reduce Transparency/snapshots.
        public var tintAlpha: CGFloat { self == .sidebar ? 0 : 0.8 }
        public var fallback: NSColor { self == .sidebar ? DS.Color.sidebar : DS.Color.raised }
    }
}

// MARK: - Radii (additions to `DS.Radius`)

extension DS.Radius {
    /// kbd, pills, inline code, badges.
    public static let xs: CGFloat = 4
    /// Sidebar rows, small buttons, diff file rows.
    public static let sm: CGFloat = 6
    /// Buttons, inputs, tabs, code blocks, picker rows (`--control-radius`).
    public static let md: CGFloat = 8
    /// Menus and pickers.
    public static let lg: CGFloat = 10
    /// Composer, attached cards, palette, user bubble.
    public static let xl: CGFloat = 16

    /// Applies a continuous-corner radius to a layer (window corners are the system's; never draw our own).
    @MainActor public static func apply(_ radius: CGFloat, to layer: CALayer?) {
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }

    /// A continuous rounded-rect path (AppKit's `NSBezierPath(roundedRect:)` is circular; this matches CALayer).
    public static func path(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let cg = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        return NSBezierPath(cgPath: cg)
    }
}

// MARK: - Motion (additions to `DS.Motion`)

extension DS.Motion {
    /// Popover, menu, palette in: opacity 0→1 + scale 0.98→1, 120 ms, `--ease-drawer`. Reduce Motion: fade only.
    public static let popInDuration: TimeInterval = 0.12
    public static let popInScale: CGFloat = 0.98
    public static let popOutDuration: TimeInterval = 0.08
    /// `cubic-bezier(0.32, 0.72, 0, 1)`.
    public static let drawerCurve = (c1: CGPoint(x: 0.32, y: 0.72), c2: CGPoint(x: 0, y: 1))
    @MainActor public static var drawerTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
    }
    /// Button press: scale 0.97 (none under Reduce Motion); release 100 ms ease-out.
    public static let pressScale: CGFloat = 0.97
    public static let pressReleaseDuration: TimeInterval = 0.1
    /// Sidebar row reorder.
    public static let rowReorderDuration: TimeInterval = 0.15
    /// A new streamed block fades in once.
    public static let streamFadeInDuration: TimeInterval = 0.15
    /// Toast auto-dismiss.
    public static let toastDismissDelay: TimeInterval = 6
    /// Live tool sweep period; stepped.
    public static let sweepPeriod: TimeInterval = 2.2
    /// Spinners, sweeps and pulses are stepped: this many frames per revolution/period.
    public static let spinnerSteps = 12
    public static let spinnerPeriod: TimeInterval = 0.9

    /// The press scale to use now (1 under Reduce Motion).
    @MainActor public static var effectivePressScale: CGFloat { reduceMotion ? 1 : pressScale }
}

// MARK: - Accessibility preferences

extension DS {
    /// Display accessibility preferences, read live (they change while the app runs).
    @MainActor public enum Accessibility {
        /// Overrides for tests and the gallery (nil = follow the system).
        public static var reduceTransparencyOverride: Bool?
        public static var reduceMotionOverride: Bool?

        public static var reduceTransparency: Bool {
            reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
        public static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
        public static var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }
}
