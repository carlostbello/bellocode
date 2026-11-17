import AppKit
import DesignSystem
import SwiftTerm

/// Terminal preferences the host supplies (Settings ▸ Terminal). A value; changing it re-applies to every pane.
public struct TerminalPreferences: Sendable, Hashable {
    /// nil uses the system monospaced font (SF Mono).
    public var fontName: String?
    public var fontSize: CGFloat
    /// Scrollback rows per terminal. Each 100-column row costs about 1.2 KiB (docs/spikes/G5-terminal.md), so the
    /// default 10,000 is about 12 MiB; capped at 100,000.
    public var scrollback: Int
    /// Let programs write the clipboard with OSC 52. Off by default: terminal output is untrusted. Reads are never
    /// allowed.
    public var allowsClipboardWrites: Bool
    /// Option sends Meta (Esc prefix) instead of composing characters.
    public var optionAsMeta: Bool
    /// Ask before pasting several lines into a shell prompt that would run them at once.
    public var confirmsMultilinePaste: Bool

    public static let scrollbackRange = 1_000...100_000
    public static let fontSizeRange: ClosedRange<CGFloat> = 9...24

    public init(
        fontName: String? = nil, fontSize: CGFloat = 12, scrollback: Int = 10_000, allowsClipboardWrites: Bool = false,
        optionAsMeta: Bool = false, confirmsMultilinePaste: Bool = true
    ) {
        self.fontName = fontName
        self.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        self.scrollback = min(max(scrollback, Self.scrollbackRange.lowerBound), Self.scrollbackRange.upperBound)
        self.allowsClipboardWrites = allowsClipboardWrites
        self.optionAsMeta = optionAsMeta
        self.confirmsMultilinePaste = confirmsMultilinePaste
    }

    @MainActor public var font: NSFont {
        if let fontName, let font = NSFont(name: fontName, size: fontSize), font.isFixedPitch { return font }
        return .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
}

/// Terminal colours from the DesignSystem tokens (visual-language.md §1 "Diff, code and terminal", §6 "Terminal
/// drawer"): `canvas` background, `text` foreground, `terminalCursor`, `terminalSelection`, and an ANSI palette derived
/// from the semantic tokens (red = `dangerText`, green = `successText`, yellow = `warningText`, blue = `infoText`, cyan
/// `ansiCyan`, magenta `ansiMagenta`; black/white from the text ramp; bright = the fill tone or a lift toward `text`).
/// Opaque values: translucent tokens are composited over the canvas.
public struct TerminalTheme: Sendable, Hashable {
    public struct RGB: Sendable, Hashable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8

        public init(_ hex: UInt32) {
            red = UInt8((hex >> 16) & 0xFF)
            green = UInt8((hex >> 8) & 0xFF)
            blue = UInt8(hex & 0xFF)
        }

        init(_ rgba: DS.RGBA) {
            func byte(_ value: Double) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
            red = byte(rgba.red)
            green = byte(rgba.green)
            blue = byte(rgba.blue)
        }

        var swiftTerm: SwiftTerm.Color {
            SwiftTerm.Color(red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257)
        }

        var nsColor: NSColor {
            NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    public var isDark: Bool
    public var ansi: [RGB]

    /// The palette for one appearance variant (light, dark and their Increase Contrast forms).
    public static func palette(_ variant: DS.Variant) -> TerminalTheme {
        let canvas = DS.ColorToken.canvas.value(variant)
        func v(_ token: DS.ColorToken) -> DS.RGBA { token.value(variant).over(canvas) }
        let text = v(.text)
        func lift(_ color: DS.RGBA) -> DS.RGBA { color.mixed(with: text, 0.25) }
        let red = v(.dangerText), green = v(.successText), yellow = v(.warningText), blue = v(.infoText)
        let magenta = v(.ansiMagenta), cyan = v(.ansiCyan)
        let ansi: [DS.RGBA] = variant.isDark
            ? [v(.borderStrong).mixed(with: v(.text4), 0.5), red, green, yellow, blue, magenta, cyan, v(.text2),
               v(.text3), lift(red), lift(green), lift(yellow), lift(blue), lift(magenta), lift(cyan), text]
            : [text, red, green, yellow, blue, magenta, cyan, v(.text2),
               v(.text4), v(.danger), v(.success).mixed(with: green, 0.5), v(.warning).mixed(with: yellow, 0.5), v(.info), lift(magenta), lift(cyan), v(.borderStrong)]
        return TerminalTheme(isDark: variant.isDark, ansi: ansi.map(RGB.init))
    }

    public static let light = palette(.light)
    public static let dark = palette(.dark)

    @MainActor public static func current(for appearance: NSAppearance) -> TerminalTheme {
        palette(DS.Variant(appearance))
    }

    /// Applies colours to a view, resolving the tokens in `appearance`.
    @MainActor func apply(to view: TerminalView, appearance: NSAppearance) {
        var background = NSColor.black
        var foreground = NSColor.white
        var selection = NSColor.gray
        var caret = NSColor.white
        appearance.performAsCurrentDrawingAppearance {
            background = DS.Color.canvas.usingColorSpace(.sRGB) ?? background
            foreground = (DS.Color.text.usingColorSpace(.sRGB) ?? foreground).withAlphaComponent(1)
            selection = DS.Color.terminalSelection.usingColorSpace(.sRGB) ?? selection
            caret = DS.Color.terminalCursor.usingColorSpace(.sRGB) ?? caret
        }
        view.installColors(ansi.map(\.swiftTerm))
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.selectedTextBackgroundColor = selection
        view.caretColor = caret
        view.updateColorScheme(isDark ? .dark : .light)
    }
}
