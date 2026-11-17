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

/// Terminal colours from the DesignSystem tokens: the content background and label colour of the current appearance,
/// the system selection colour, and a 16-colour ANSI palette tuned for contrast on each background.
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

        var swiftTerm: SwiftTerm.Color {
            SwiftTerm.Color(red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257)
        }

        var nsColor: NSColor {
            NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    public var isDark: Bool
    public var ansi: [RGB]

    /// ANSI 0–15 for a light background (GitHub-light-like: dark, saturated, readable on white).
    public static let light = TerminalTheme(isDark: false, ansi: [
        0x24292F, 0xCF222E, 0x116329, 0x7D4E00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
        0x57606A, 0xA40E26, 0x1A7F37, 0x9A6700, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
    ].map(RGB.init))

    /// ANSI 0–15 for a dark background (muted, with black lifted so it shows on the background).
    public static let dark = TerminalTheme(isDark: true, ansi: [
        0x3A3F4B, 0xFF7B72, 0x7EE787, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x76E3EA, 0xB1BAC4,
        0x6E7681, 0xFFA198, 0xA5F0A5, 0xF2CC60, 0xA5D6FF, 0xE2C5FF, 0xB3F0FF, 0xF0F6FC,
    ].map(RGB.init))

    @MainActor public static func current(for appearance: NSAppearance) -> TerminalTheme {
        appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map { [.darkAqua, .vibrantDark].contains($0) } == true
            ? .dark : .light
    }

    /// Applies colours to a view, resolving the semantic tokens in `appearance`.
    @MainActor func apply(to view: TerminalView, appearance: NSAppearance) {
        var background = NSColor.textBackgroundColor
        var foreground = NSColor.labelColor
        var selection = NSColor.selectedTextBackgroundColor
        var caret = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            background = (DS.Palette.contentBackground.usingColorSpace(.sRGB) ?? .textBackgroundColor)
            foreground = (DS.Palette.text.usingColorSpace(.sRGB) ?? .labelColor).withAlphaComponent(1)
            selection = NSColor.selectedTextBackgroundColor.usingColorSpace(.sRGB) ?? selection
            caret = (DS.Palette.text.usingColorSpace(.sRGB) ?? .labelColor).withAlphaComponent(0.85)
        }
        view.installColors(ansi.map(\.swiftTerm))
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.selectedTextBackgroundColor = selection
        view.caretColor = caret
        view.updateColorScheme(isDark ? .dark : .light)
    }
}
