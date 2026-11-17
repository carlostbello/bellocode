import AppKit
import SwiftUI
import Synchronization

// The colour half of docs/design/visual-language.md §1, as one table. Every value is written once, here, as a Sendable
// `DS.RGBA` per appearance variant; `DS.Color` turns each row into a dynamic `NSColor` (and `DS.SwiftUIColor` into a
// SwiftUI `Color`). Tests and the token dump read the same table, so what is tested is what is drawn.
//
// Palette, metrics and recipes are derived from T3 Code (github.com/pingdotgg/t3code, MIT, © 2026 T3 Tools Inc.).

extension DS {
    /// An sRGB colour with alpha. Plain values: safe anywhere.
    public struct RGBA: Sendable, Hashable, CustomStringConvertible {
        public var red: Double
        public var green: Double
        public var blue: Double
        public var alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// `0xRRGGBB` with an optional alpha (0…1).
        public init(_ hex: UInt32, _ alpha: Double = 1) {
            self.init(
                red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255, alpha: alpha)
        }

        public static func white(_ alpha: Double) -> RGBA { RGBA(0xFFFFFF, alpha) }
        public static func black(_ alpha: Double) -> RGBA { RGBA(0x000000, alpha) }
        public static let clear = RGBA(0x000000, 0)

        public func withAlpha(_ alpha: Double) -> RGBA { RGBA(red: red, green: green, blue: blue, alpha: alpha) }

        /// Source-over compositing of `self` on an opaque-or-not `background`.
        public func over(_ background: RGBA) -> RGBA {
            let a = alpha + background.alpha * (1 - alpha)
            guard a > 0 else { return .clear }
            func mix(_ s: Double, _ d: Double) -> Double { (s * alpha + d * background.alpha * (1 - alpha)) / a }
            return RGBA(red: mix(red, background.red), green: mix(green, background.green), blue: mix(blue, background.blue), alpha: a)
        }

        /// Linear mix: `fraction` of `other`.
        public func mixed(with other: RGBA, _ fraction: Double) -> RGBA {
            func m(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
            return RGBA(red: m(red, other.red), green: m(green, other.green), blue: m(blue, other.blue), alpha: m(alpha, other.alpha))
        }

        /// WCAG 2.x relative luminance (alpha ignored: composite first).
        public var relativeLuminance: Double {
            func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        }

        /// WCAG contrast ratio of `self` composited on `background` (which is assumed opaque).
        public func contrast(on background: RGBA) -> Double {
            let fg = over(background).relativeLuminance
            let bg = background.relativeLuminance
            return (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
        }

        public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

        public var description: String {
            let hex = String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
            return alpha >= 0.9995 ? hex : "\(hex) \(Int((alpha * 1000).rounded()) / 10)%"
        }
    }

    /// The four appearance variants every colour token defines.
    public enum Variant: String, Sendable, CaseIterable, Hashable {
        case light, dark, lightHighContrast, darkHighContrast

        public var isDark: Bool { self == .dark || self == .darkHighContrast }
        public var isHighContrast: Bool { self == .lightHighContrast || self == .darkHighContrast }

        public init(_ appearance: NSAppearance) {
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: self = .dark
            case .accessibilityHighContrastAqua: self = .lightHighContrast
            case .accessibilityHighContrastDarkAqua: self = .darkHighContrast
            default: self = .light
            }
        }

        /// The `NSAppearance` that resolves to this variant (for rendering and tests).
        public var appearance: NSAppearance {
            switch self {
            case .light: NSAppearance(named: .aqua)!
            case .dark: NSAppearance(named: .darkAqua)!
            case .lightHighContrast: NSAppearance(named: .accessibilityHighContrastAqua)!
            case .darkHighContrast: NSAppearance(named: .accessibilityHighContrastDarkAqua)!
            }
        }
    }

    /// One row of the colour table: a name, its four values and what it is for.
    public struct ColorToken: Sendable, Hashable, Identifiable {
        public enum Group: String, Sendable, CaseIterable { case surface, text, border, accent, semantic, selection, diff, syntax, terminal, chrome }

        public let name: String
        public let group: Group
        public let light: RGBA
        public let dark: RGBA
        public let lightHighContrast: RGBA
        public let darkHighContrast: RGBA
        /// Follows the user's macOS accent colour unless it is Multicolor (see `DS.Accent`).
        public let followsUserAccent: Bool
        public let use: String

        public var id: String { name }

        init(
            _ name: String, _ group: Group, light: RGBA, dark: RGBA, lightHC: RGBA? = nil, darkHC: RGBA? = nil,
            followsUserAccent: Bool = false, use: String
        ) {
            self.name = name
            self.group = group
            self.light = light
            self.dark = dark
            lightHighContrast = lightHC ?? light
            darkHighContrast = darkHC ?? dark
            self.followsUserAccent = followsUserAccent
            self.use = use
        }

        public func value(_ variant: Variant) -> RGBA {
            switch variant {
            case .light: light
            case .dark: dark
            case .lightHighContrast: lightHighContrast
            case .darkHighContrast: darkHighContrast
            }
        }

        /// A dynamic `NSColor` that resolves per appearance (and per user accent, when `followsUserAccent`).
        public var nsColor: NSColor {
            let token = self
            return NSColor(name: "BelloCode.\(name)") { appearance in
                let variant = Variant(appearance)
                if token.followsUserAccent, let user = DS.Accent.userAccentRGBA() {
                    // Keep the token's alpha recipe on the user's hue (`textSelection`, `focusHalo`).
                    return user.withAlpha(token.value(variant).alpha).nsColor
                }
                return token.value(variant).nsColor
            }
        }
    }

    /// The accent rule (visual-language.md §1): Multicolor (no `AppleAccentColor` default) uses BelloCode's blue;
    /// any explicit choice uses `NSColor.controlAccentColor` for every accent use. Never used as a row fill.
    public enum Accent {
        /// For tests and the gallery: force BelloCode's accent regardless of the system setting.
        public static var ignoresUserAccent: Bool {
            get { ignoresUserAccentStorage.withLock { $0 } }
            set { ignoresUserAccentStorage.withLock { $0 = newValue } }
        }
        private static let ignoresUserAccentStorage = Mutex(false)

        /// The user's explicit accent as sRGB, or nil for Multicolor.
        public static func userAccentRGBA() -> RGBA? {
            guard !ignoresUserAccent, UserDefaults.standard.object(forKey: "AppleAccentColor") != nil,
                  let color = NSColor.controlAccentColor.usingColorSpace(.sRGB)
            else { return nil }
            return RGBA(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent, alpha: color.alphaComponent)
        }
    }
}

// MARK: - The table

extension DS.ColorToken {
    private typealias C = DS.RGBA

    // Shared bases.
    private static let rowWash = C(0xF1F3F7)
    private static let accentDark = C(0x346BF1)
    private static let accentLight = C(0x1B4ED8)

    static let canvas = Self("canvas", .surface, light: C(0xFCFCFC), dark: C(0x000000), use: "Window, transcript, right panel, terminal")
    static let sidebar = Self("sidebar", .surface, light: C(0xFAFAFA), dark: C(0x000000), use: "Sidebar")
    static let raised = Self(
        "raised", .surface, light: C(0xFFFFFF), dark: C(0x111111), darkHC: C(0x161616),
        use: "Composer, attached cards, menus, popovers, palette, toasts")
    static let message = Self("message", .surface, light: C(0xEBEBED), dark: C(0x1E1E1E), use: "User message bubble")
    static let codeFill = Self(
        "codeFill", .surface, light: C(0xFAFAFA), dark: .white(0.035), lightHC: C(0xF4F4F5), darkHC: .white(0.07),
        use: "Code blocks, command previews (light adds `border` 70 %)")
    static let fillSubtle = Self(
        "fillSubtle", .surface, light: C(0xFAFAFA), dark: .white(0.03), lightHC: C(0xF4F4F5), darkHC: .white(0.06),
        use: "Search field, segmented track, report boxes")
    static let fillHover = Self(
        "fillHover", .surface, light: C(0xF4F4F5), dark: .white(0.04), lightHC: C(0xE9E9EB), darkHC: .white(0.08),
        use: "Ghost-control hover/pressed, selected tab")
    static let scrim = Self("scrim", .surface, light: C(0xFCFCFC, 0.60), dark: C(0x000000, 0.64), use: "Behind palette and dialogs (+ blur 4)")
    static let rowHover = Self(
        "rowHover", .surface, light: C(0xF4F4F5), dark: rowWash.withAlpha(0.08), lightHC: C(0xE9E9EB), darkHC: rowWash.withAlpha(0.14),
        use: "Sidebar/list row hover")
    static let rowActive = Self(
        "rowActive", .surface, light: C(0xFFFFFF), dark: rowWash.withAlpha(0.11), darkHC: rowWash.withAlpha(0.18),
        use: "Current thread (light adds `rowRing`)")
    static let rowSelected = Self(
        "rowSelected", .surface, light: C(0xFFFFFF), dark: rowWash.withAlpha(0.07), darkHC: rowWash.withAlpha(0.13),
        use: "Multi-select, file list (light adds `rowRing`)")
    static let rowRing = Self(
        "rowRing", .surface, light: C(0xE4E4E7, 0.7), dark: .clear, lightHC: C(0xA1A1AA), darkHC: .white(0.2),
        use: "Inset ring of active/selected rows in light")
    static let highlight = Self(
        "highlight", .surface, light: C(0x18181B, 0.06), dark: C(0xF5F5F5, 0.09), lightHC: C(0x18181B, 0.12), darkHC: C(0xF5F5F5, 0.18),
        use: "Palette/menu keyboard highlight (never accent)")

    static let text = Self("text", .text, light: C(0x18181B), dark: C(0xF5F5F5), use: "Titles, prose, values")
    static let sidebarText = Self("sidebarText", .text, light: C(0x18181B), dark: C(0xF1F3F7), use: "Sidebar row titles")
    static let text2 = Self(
        "text2", .text, light: C(0x71717A), dark: C(0xA1A1A1), lightHC: C(0x52525B), darkHC: C(0xC4C4C4),
        use: "Secondary labels, control labels, tool verbs")
    static let text3 = Self(
        "text3", .text, light: C(0x71717A), dark: C(0x8F8F8F), lightHC: C(0x52525B), darkHC: C(0xC4C4C4),
        use: "Row metadata, section labels")
    static let text4 = Self(
        "text4", .text, light: C(0x71717A, 0.6), dark: C(0xA1A1A1, 0.55), lightHC: C(0x52525B), darkHC: C(0xC4C4C4),
        use: "Timestamps, gutters, chevrons, disabled (below AA by design)")
    static let icon = Self(
        "icon", .text, light: C(0x71717A), dark: C(0xA1A1A1, 0.9), lightHC: C(0x52525B), darkHC: C(0xC4C4C4),
        use: "Default icon tint")
    static let placeholder = Self(
        "placeholder", .text, light: C(0x71717A), dark: C(0xA1A1A1), lightHC: C(0x52525B), darkHC: C(0xC4C4C4),
        use: "Composer and field placeholders (= text2)")

    static let border = Self(
        "border", .border, light: C(0xE4E4E7), dark: .white(0.08), lightHC: C(0xA1A1AA), darkHC: .white(0.2),
        use: "Panel dividers, row dividers, card edges")
    static let borderStrong = Self(
        "borderStrong", .border, light: C(0xD4D4D8), dark: .white(0.11), lightHC: C(0xA1A1AA), darkHC: .white(0.2),
        use: "Outline buttons, inputs, popover edge")
    static let composerOutline = Self(
        "composerOutline", .border, light: .black(0.08), dark: .white(0.05), lightHC: C(0xA1A1AA), darkHC: .white(0.2),
        use: "Composer and attached cards")
    static let composerHighlight = Self(
        "composerHighlight", .border, light: .clear, dark: .white(0.03), use: "Inner top highlight of the composer")

    static let accent = Self(
        "accent", .accent, light: accentLight, dark: accentDark, followsUserAccent: true,
        use: "Primary button, Send, focus ring, caret, checkmarks")
    static let accentHover = Self(
        "accentHover", .accent, light: accentLight.withAlpha(0.9).over(C(0xFCFCFC)), dark: accentDark.withAlpha(0.9).over(C(0x000000)),
        use: "Primary hover (accent 90 % on canvas)")
    static let onAccent = Self("onAccent", .accent, light: C(0xFFFFFF), dark: C(0xFFFFFF), use: "Text on accent")
    static let focusRing = Self(
        "focusRing", .accent, light: accentLight, dark: accentDark, followsUserAccent: true, use: "2 pt inset keyboard focus ring")
    static let focusHalo = Self(
        "focusHalo", .accent, light: accentLight.withAlpha(0.24), dark: accentDark.withAlpha(0.24), followsUserAccent: true,
        use: "3 pt halo around a focused text field")
    static let textSelection = Self(
        "textSelection", .selection, light: accentLight.withAlpha(0.2), dark: accentDark.withAlpha(0.3), followsUserAccent: true,
        use: "NSTextView selectedTextAttributes")
    static let findMatch = Self("findMatch", .selection, light: C(0xFFDE8B), dark: C(0x8C6C1F), use: "Find matches")
    static let findActive = Self("findActive", .selection, light: C(0xEEA52B), dark: C(0xEEA52B), use: "Current find match")

    static let success = Self("success", .semantic, light: C(0x00BC7D), dark: C(0x00BC7D), use: "Done, additions (fills, glyphs)")
    static let successText = Self("successText", .semantic, light: C(0x007A55), dark: C(0x00D492), use: "Success words, +n")
    static let warning = Self("warning", .semantic, light: C(0xFE9A00), dark: C(0xFE9A00), use: "Needs you (fills)")
    static let warningText = Self("warningText", .semantic, light: C(0xBB4D00), dark: C(0xFFB900), use: "Approval words, glyphs")
    static let danger = Self("danger", .semantic, light: C(0xFB2C36), dark: C(0xFB414A), use: "Failed, Stop, deletions (fills)")
    static let dangerText = Self("dangerText", .semantic, light: C(0xC10007), dark: C(0xFF6467), use: "Failure words, −n")
    static let info = Self("info", .semantic, light: C(0x2B7FFF), dark: C(0x2B7FFF), use: "Running, questions (fills)")
    static let infoText = Self("infoText", .semantic, light: C(0x1447E6), dark: C(0x51A2FF), use: "Question words, links, spinner head")
    static let successSurface = Self("successSurface", .semantic, light: C(0x00BC7D, 0.08), dark: C(0x00BC7D, 0.16), use: "Pills, tinted cards")
    static let warningSurface = Self("warningSurface", .semantic, light: C(0xFE9A00, 0.08), dark: C(0xFE9A00, 0.16), use: "Pills, tinted cards")
    static let dangerSurface = Self("dangerSurface", .semantic, light: C(0xFB2C36, 0.08), dark: C(0xFB414A, 0.16), use: "Pills, tinted cards")
    static let infoSurface = Self("infoSurface", .semantic, light: C(0x2B7FFF, 0.08), dark: C(0x2B7FFF, 0.16), use: "Pills, tinted cards")

    static let diffAddLine = Self("diffAddLine", .diff, light: C(0x00BC7D, 0.08), dark: C(0x00BC7D, 0.10), use: "Added line fill")
    static let diffAddGutter = Self("diffAddGutter", .diff, light: C(0x00BC7D, 0.14), dark: C(0x00BC7D, 0.16), use: "Added gutter fill")
    static let diffAddWord = Self("diffAddWord", .diff, light: C(0x00BC7D, 0.22), dark: C(0x00D492, 0.28), use: "Added word emphasis")
    static let diffDelLine = Self("diffDelLine", .diff, light: C(0xFB2C36, 0.07), dark: C(0xFB414A, 0.10), use: "Deleted line fill")
    static let diffDelGutter = Self("diffDelGutter", .diff, light: C(0xFB2C36, 0.12), dark: C(0xFB414A, 0.16), use: "Deleted gutter fill")
    static let diffDelWord = Self("diffDelWord", .diff, light: C(0xFB2C36, 0.20), dark: C(0xFF6467, 0.28), use: "Deleted word emphasis")
    static let diffHunk = Self("diffHunk", .diff, light: C(0x2B7FFF, 0.06), dark: C(0x51A2FF, 0.07), use: "Hunk bar fill (text3 mono 11)")
    static let diffModifiedIcon = Self(
        "diffModifiedIcon", .diff, light: C(0x1447E6, 0.5).over(C(0x71717A)), dark: C(0x51A2FF, 0.65), use: "M badge / modified glyph")

    static let syntaxKeyword = Self("syntaxKeyword", .syntax, light: C(0x9B2393), dark: C(0xFF7AB2), lightHC: C(0x7A0F72), darkHC: C(0xFF9CC6), use: "Keywords")
    static let syntaxType = Self("syntaxType", .syntax, light: C(0x0B4F79), dark: C(0x6BDFFF), lightHC: C(0x053A5C), darkHC: C(0x9AE9FF), use: "Types")
    static let syntaxFunction = Self("syntaxFunction", .syntax, light: C(0x326D74), dark: C(0x67B7A4), lightHC: C(0x1F5157), darkHC: C(0x8ED6C4), use: "Functions")
    static let syntaxString = Self("syntaxString", .syntax, light: C(0xC41A16), dark: C(0xFC6A5D), lightHC: C(0x9A0F0C), darkHC: C(0xFF9488), use: "Strings")
    static let syntaxNumber = Self("syntaxNumber", .syntax, light: C(0x1C00CF), dark: C(0xD0BF69), lightHC: C(0x1400A0), darkHC: C(0xE6D78A), use: "Numbers")
    static let syntaxComment = Self("syntaxComment", .syntax, light: C(0x5D6C79), dark: C(0x7F8C98), lightHC: C(0x3E4A55), darkHC: C(0xA9B4BE), use: "Comments")
    static let syntaxProperty = Self("syntaxProperty", .syntax, light: C(0x6C36A9), dark: C(0xA167E6), lightHC: C(0x52248A), darkHC: C(0xC197F2), use: "Properties")

    static let terminalCursor = Self("terminalCursor", .terminal, light: C(0x26384E), dark: C(0xB4CBFF), use: "Terminal cursor")
    static let terminalSelection = Self("terminalSelection", .terminal, light: C(0x253F63, 0.2), dark: C(0xB4CBFF, 0.25), use: "Terminal selection")
    static let ansiCyan = Self("ansiCyan", .terminal, light: C(0x0B4F79), dark: C(0x6BDFFF), use: "ANSI cyan")
    static let ansiMagenta = Self("ansiMagenta", .terminal, light: C(0x6C36A9), dark: C(0xA167E6), use: "ANSI magenta")

    static let scrollThumb = Self("scrollThumb", .chrome, light: C(0xD9D9D9), dark: .white(0.36), lightHC: C(0xA1A1AA), darkHC: .white(0.5), use: "Overlay scroller knob")
    static let scrollThumbHover = Self("scrollThumbHover", .chrome, light: C(0xBFBFBF), dark: .white(0.45), lightHC: C(0x71717A), darkHC: .white(0.6), use: "Knob on hover")
    static let kbdFill = Self("kbdFill", .chrome, light: C(0x18181B, 0.06), dark: C(0xF5F5F5, 0.08), lightHC: C(0x18181B, 0.1), darkHC: C(0xF5F5F5, 0.14), use: "Key caps")
    static let disabledFill = Self("disabledFill", .chrome, light: C(0x18181B, 0.12), dark: C(0xF5F5F5, 0.12), use: "Disabled Send fill")
    static let shadow = Self("shadow", .chrome, light: .black(1), dark: .black(1), use: "Shadow base colour (recipes set opacity)")

    /// Every token, in documentation order. Tests check this list is complete and unique.
    public static let all: [DS.ColorToken] = [
        canvas, sidebar, raised, message, codeFill, fillSubtle, fillHover, scrim, rowHover, rowActive, rowSelected, rowRing, highlight,
        text, sidebarText, text2, text3, text4, icon, placeholder,
        border, borderStrong, composerOutline, composerHighlight,
        accent, accentHover, onAccent, focusRing, focusHalo,
        textSelection, findMatch, findActive,
        success, successText, warning, warningText, danger, dangerText, info, infoText,
        successSurface, warningSurface, dangerSurface, infoSurface,
        diffAddLine, diffAddGutter, diffAddWord, diffDelLine, diffDelGutter, diffDelWord, diffHunk, diffModifiedIcon,
        syntaxKeyword, syntaxType, syntaxFunction, syntaxString, syntaxNumber, syntaxComment, syntaxProperty,
        terminalCursor, terminalSelection, ansiCyan, ansiMagenta,
        scrollThumb, scrollThumbHover, kbdFill, disabledFill, shadow,
    ]

    public static func named(_ name: String) -> DS.ColorToken? { all.first { $0.name == name } }
}

// MARK: - Dynamic colours

extension DS {
    /// The colour tokens as dynamic `NSColor`s (visual-language.md §1). Resolve at draw time (inside `draw(_:)`,
    /// `updateLayer()` or `effectiveAppearance.performAsCurrentDrawingAppearance`) before taking `.cgColor`.
    public enum Color {
        public static let canvas = ColorToken.canvas.nsColor
        public static let sidebar = ColorToken.sidebar.nsColor
        public static let raised = ColorToken.raised.nsColor
        public static let message = ColorToken.message.nsColor
        public static let codeFill = ColorToken.codeFill.nsColor
        public static let fillSubtle = ColorToken.fillSubtle.nsColor
        public static let fillHover = ColorToken.fillHover.nsColor
        public static let scrim = ColorToken.scrim.nsColor
        public static let rowHover = ColorToken.rowHover.nsColor
        public static let rowActive = ColorToken.rowActive.nsColor
        public static let rowSelected = ColorToken.rowSelected.nsColor
        public static let rowRing = ColorToken.rowRing.nsColor
        public static let highlight = ColorToken.highlight.nsColor

        public static let text = ColorToken.text.nsColor
        public static let sidebarText = ColorToken.sidebarText.nsColor
        public static let text2 = ColorToken.text2.nsColor
        public static let text3 = ColorToken.text3.nsColor
        public static let text4 = ColorToken.text4.nsColor
        public static let icon = ColorToken.icon.nsColor
        public static let placeholder = ColorToken.placeholder.nsColor

        public static let border = ColorToken.border.nsColor
        public static let borderStrong = ColorToken.borderStrong.nsColor
        public static let composerOutline = ColorToken.composerOutline.nsColor
        public static let composerHighlight = ColorToken.composerHighlight.nsColor

        public static let accent = ColorToken.accent.nsColor
        public static let accentHover = NSColor(name: "BelloCode.accentHover") { appearance in
            // accent 90 % on canvas, recomputed when the user's accent is in use.
            let variant = Variant(appearance)
            if let user = Accent.userAccentRGBA() {
                return user.withAlpha(0.9).over(ColorToken.canvas.value(variant)).nsColor
            }
            return ColorToken.accentHover.value(variant).nsColor
        }
        public static let onAccent = ColorToken.onAccent.nsColor
        public static let focusRing = ColorToken.focusRing.nsColor
        public static let focusHalo = ColorToken.focusHalo.nsColor
        public static let textSelection = ColorToken.textSelection.nsColor
        public static let findMatch = ColorToken.findMatch.nsColor
        public static let findActive = ColorToken.findActive.nsColor

        public static let success = ColorToken.success.nsColor
        public static let successText = ColorToken.successText.nsColor
        public static let warning = ColorToken.warning.nsColor
        public static let warningText = ColorToken.warningText.nsColor
        public static let danger = ColorToken.danger.nsColor
        public static let dangerText = ColorToken.dangerText.nsColor
        public static let info = ColorToken.info.nsColor
        public static let infoText = ColorToken.infoText.nsColor
        public static let successSurface = ColorToken.successSurface.nsColor
        public static let warningSurface = ColorToken.warningSurface.nsColor
        public static let dangerSurface = ColorToken.dangerSurface.nsColor
        public static let infoSurface = ColorToken.infoSurface.nsColor

        public static let diffAddLine = ColorToken.diffAddLine.nsColor
        public static let diffAddGutter = ColorToken.diffAddGutter.nsColor
        public static let diffAddWord = ColorToken.diffAddWord.nsColor
        public static let diffDelLine = ColorToken.diffDelLine.nsColor
        public static let diffDelGutter = ColorToken.diffDelGutter.nsColor
        public static let diffDelWord = ColorToken.diffDelWord.nsColor
        public static let diffHunk = ColorToken.diffHunk.nsColor
        public static let diffModifiedIcon = ColorToken.diffModifiedIcon.nsColor

        public static let syntaxKeyword = ColorToken.syntaxKeyword.nsColor
        public static let syntaxType = ColorToken.syntaxType.nsColor
        public static let syntaxFunction = ColorToken.syntaxFunction.nsColor
        public static let syntaxString = ColorToken.syntaxString.nsColor
        public static let syntaxNumber = ColorToken.syntaxNumber.nsColor
        public static let syntaxComment = ColorToken.syntaxComment.nsColor
        public static let syntaxProperty = ColorToken.syntaxProperty.nsColor

        public static let terminalCursor = ColorToken.terminalCursor.nsColor
        public static let terminalSelection = ColorToken.terminalSelection.nsColor
        public static let ansiCyan = ColorToken.ansiCyan.nsColor
        public static let ansiMagenta = ColorToken.ansiMagenta.nsColor

        public static let scrollThumb = ColorToken.scrollThumb.nsColor
        public static let scrollThumbHover = ColorToken.scrollThumbHover.nsColor
        public static let kbdFill = ColorToken.kbdFill.nsColor
        public static let disabledFill = ColorToken.disabledFill.nsColor

        /// A semantic tone's colours, for pills, glyphs and tinted cards.
        public static func tone(_ tone: Tone) -> (fill: NSColor, text: NSColor, surface: NSColor) {
            switch tone {
            case .neutral: (fillHover, text2, fillHover)
            case .success: (success, successText, successSurface)
            case .warning: (warning, warningText, warningSurface)
            case .danger: (danger, dangerText, dangerSurface)
            case .info: (info, infoText, infoSurface)
            case .accent: (accent, accent, focusHalo)
            }
        }
    }

    /// Semantic tones shared by pills, glyphs and tinted cards. Never the only cue (status = glyph + word).
    public enum Tone: String, Sendable, CaseIterable { case neutral, success, warning, danger, info, accent }

    /// SwiftUI mirrors of `DS.Color` for hosted views: `Color.ds.text`, `Color.ds.raised`, …
    public enum SwiftUIColor {
        public static let canvas = SwiftUI.Color(nsColor: Color.canvas)
        public static let sidebar = SwiftUI.Color(nsColor: Color.sidebar)
        public static let raised = SwiftUI.Color(nsColor: Color.raised)
        public static let message = SwiftUI.Color(nsColor: Color.message)
        public static let codeFill = SwiftUI.Color(nsColor: Color.codeFill)
        public static let fillSubtle = SwiftUI.Color(nsColor: Color.fillSubtle)
        public static let fillHover = SwiftUI.Color(nsColor: Color.fillHover)
        public static let rowHover = SwiftUI.Color(nsColor: Color.rowHover)
        public static let rowActive = SwiftUI.Color(nsColor: Color.rowActive)
        public static let rowRing = SwiftUI.Color(nsColor: Color.rowRing)
        public static let highlight = SwiftUI.Color(nsColor: Color.highlight)
        public static let text = SwiftUI.Color(nsColor: Color.text)
        public static let text2 = SwiftUI.Color(nsColor: Color.text2)
        public static let text3 = SwiftUI.Color(nsColor: Color.text3)
        public static let text4 = SwiftUI.Color(nsColor: Color.text4)
        public static let icon = SwiftUI.Color(nsColor: Color.icon)
        public static let border = SwiftUI.Color(nsColor: Color.border)
        public static let borderStrong = SwiftUI.Color(nsColor: Color.borderStrong)
        public static let accent = SwiftUI.Color(nsColor: Color.accent)
        public static let accentHover = SwiftUI.Color(nsColor: Color.accentHover)
        public static let onAccent = SwiftUI.Color(nsColor: Color.onAccent)
        public static let focusRing = SwiftUI.Color(nsColor: Color.focusRing)
        public static let success = SwiftUI.Color(nsColor: Color.success)
        public static let successText = SwiftUI.Color(nsColor: Color.successText)
        public static let warning = SwiftUI.Color(nsColor: Color.warning)
        public static let warningText = SwiftUI.Color(nsColor: Color.warningText)
        public static let danger = SwiftUI.Color(nsColor: Color.danger)
        public static let dangerText = SwiftUI.Color(nsColor: Color.dangerText)
        public static let info = SwiftUI.Color(nsColor: Color.info)
        public static let infoText = SwiftUI.Color(nsColor: Color.infoText)
        public static let kbdFill = SwiftUI.Color(nsColor: Color.kbdFill)
        public static let disabledFill = SwiftUI.Color(nsColor: Color.disabledFill)
    }
}

extension SwiftUI.Color {
    /// `Color.ds.text`, `Color.ds.accent`, …: the DesignSystem colour tokens.
    public typealias ds = DS.SwiftUIColor
}
