import AppKit
import CoreText
import DesignSystem

/// Resolved colours and sizes for one appearance and text size. Immutable and `Sendable` (CGColor is thread-safe and
/// immutable), so layout off the main actor can bake colours into attributed strings.
public struct TranscriptTheme: Sendable, Equatable {
    public var baseSize: CGFloat
    public var isDark: Bool
    public var increasedContrast: Bool

    public var text: CGColor
    public var secondary: CGColor
    public var tertiary: CGColor
    public var link: CGColor
    public var accent: CGColor
    public var codeBackground: CGColor
    public var cardBackground: CGColor
    public var cardBorder: CGColor
    public var separator: CGColor
    public var userBubble: CGColor
    public var inlineCodeFill: CGColor
    public var mentionFill: CGColor
    public var mentionText: CGColor
    public var selection: CGColor
    public var inactiveSelection: CGColor
    public var findHighlight: CGColor
    public var findCurrent: CGColor
    public var failure: CGColor
    public var failureFill: CGColor
    public var success: CGColor
    public var running: CGColor
    public var hoverFill: CGColor
    /// Syntax colours indexed by `TokenKind.rawValue`.
    public var syntax: [CGColor]

    /// Changes whenever anything above changes; part of the layout cache key.
    public var revision: Int

    // Metrics (points).
    public static let rowGap: CGFloat = 6
    public static let turnGap: CGFloat = 22
    public static let blockSpacing: CGFloat = 10
    public static let listSpacing: CGFloat = 4
    public static let indentStep: CGFloat = 20
    public static let quoteStep: CGFloat = 14
    public static let codePadding: CGFloat = 12
    public static let codeHeaderHeight: CGFloat = 28
    public static let toolOutputMaxHeight: CGFloat = 220
    public static let imageMaxHeight: CGFloat = 320
    public static let userBubbleMaxFraction: CGFloat = 0.82
    /// Display bound for one monospaced line (copy returns the whole line). Lines are scrolled horizontally, not cut
    /// at a few hundred characters; this only bounds pathological single lines (minified bundles).
    public static let maxDisplayLineUTF16 = 16_384

    public var bodySize: CGFloat { baseSize + 0.5 }
    public var monoSize: CGFloat { max(9, baseSize - 1) }
    public var smallSize: CGFloat { max(9, baseSize - 1.5) }

    /// Resolves the theme for an appearance (on the main actor: system colours resolve against the drawing appearance).
    @MainActor
    public static func resolve(appearance: NSAppearance, baseSize: CGFloat, revision: Int) -> TranscriptTheme {
        var theme: TranscriptTheme?
        appearance.performAsCurrentDrawingAppearance {
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
                .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            func c(_ color: NSColor) -> CGColor { color.usingColorSpace(.sRGB)?.cgColor ?? color.cgColor }
            let accent = NSColor.controlAccentColor
            let kinds: [TokenKind] = [
                .keyword, .type, .string, .comment, .number, .function, .property, .tag, .attribute, .variable, .meta,
                .diffAdded, .diffRemoved, .diffHunk, .diffHeader,
            ]
            var syntax = [CGColor](repeating: c(.labelColor), count: kinds.count)
            for kind in kinds {
                let color: NSColor =
                    switch kind {
                    case .keyword: DS.Syntax.keyword
                    case .type: DS.Syntax.type
                    case .string: DS.Syntax.string
                    case .comment: DS.Syntax.comment
                    case .number: DS.Syntax.number
                    case .function: DS.Syntax.function
                    case .property: DS.Syntax.property
                    case .tag: DS.Syntax.tag
                    case .attribute: DS.Syntax.attribute
                    case .variable: DS.Syntax.variable
                    case .meta: DS.Syntax.meta
                    case .diffAdded: DS.Syntax.diffAdded
                    case .diffRemoved: DS.Syntax.diffRemoved
                    case .diffHunk: DS.Syntax.diffHunk
                    case .diffHeader: DS.Syntax.diffHeader
                    }
                syntax[Int(kind.rawValue)] = c(color)
            }
            let bubble: NSColor =
                dark ? NSColor(white: 1, alpha: contrast ? 0.14 : 0.075) : NSColor(white: 0, alpha: contrast ? 0.085 : 0.045)
            theme = TranscriptTheme(
                baseSize: baseSize, isDark: dark, increasedContrast: contrast,
                text: c(DS.Palette.text), secondary: c(DS.Palette.secondaryText), tertiary: c(DS.Palette.tertiaryText),
                link: c(.linkColor), accent: c(accent), codeBackground: c(DS.Syntax.codeBackground),
                cardBackground: c(DS.Palette.cardBackground), cardBorder: c(DS.Palette.cardBorder),
                separator: c(DS.Palette.separator), userBubble: c(bubble),
                inlineCodeFill: c(dark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.055)),
                mentionFill: c(accent.withAlphaComponent(dark ? 0.24 : 0.13)),
                mentionText: c(dark ? accent.blended(withFraction: 0.45, of: .white) ?? accent : accent.blended(withFraction: 0.25, of: .black) ?? accent),
                selection: c(.selectedTextBackgroundColor), inactiveSelection: c(.unemphasizedSelectedTextBackgroundColor),
                findHighlight: c(NSColor.systemYellow.withAlphaComponent(dark ? 0.32 : 0.38)),
                findCurrent: c(NSColor.systemYellow.withAlphaComponent(dark ? 0.75 : 0.85)),
                failure: c(DS.Palette.failure), failureFill: c(DS.Palette.failure.withAlphaComponent(dark ? 0.12 : 0.07)),
                success: c(DS.Palette.success), running: c(DS.Palette.running),
                hoverFill: c(dark ? NSColor(white: 1, alpha: 0.04) : NSColor(white: 0, alpha: 0.03)),
                syntax: syntax, revision: revision)
        }
        return theme!
    }

    public func color(for kind: TokenKind) -> CGColor { syntax[Int(kind.rawValue)] }
}

/// Fonts for one layout pass. CTFonts are not `Sendable`, so each off-main pass makes its own (CoreText caches the
/// underlying font instances, so this is cheap).
final class TranscriptFonts {
    let theme: TranscriptTheme
    let body: CTFont
    let bold: CTFont
    let italic: CTFont
    let boldItalic: CTFont
    let semibold: CTFont
    let small: CTFont
    let smallBold: CTFont
    let mono: CTFont
    let monoBold: CTFont
    let inlineCode: CTFont
    let headings: [CTFont]
    let monoLineHeight: CGFloat
    let monoAscent: CGFloat
    let monoAdvance: CGFloat

    init(theme: TranscriptTheme) {
        self.theme = theme
        let size = theme.bodySize
        body = CTFontCreateUIFontForLanguage(.system, size, nil)!
        bold = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)!
        italic = CTFontCreateCopyWithSymbolicTraits(body, 0, nil, .traitItalic, .traitItalic) ?? body
        boldItalic = CTFontCreateCopyWithSymbolicTraits(bold, 0, nil, .traitItalic, .traitItalic) ?? bold
        semibold = Self.systemFont(size, weight: NSFont.Weight.semibold.rawValue)
        small = CTFontCreateUIFontForLanguage(.system, theme.smallSize, nil)!
        smallBold = Self.systemFont(theme.smallSize, weight: NSFont.Weight.semibold.rawValue)
        mono = Self.monoFont(theme.monoSize, weight: NSFont.Weight.regular.rawValue)
        monoBold = Self.monoFont(theme.monoSize, weight: NSFont.Weight.semibold.rawValue)
        inlineCode = Self.monoFont(size - 1, weight: NSFont.Weight.regular.rawValue)
        headings = [
            Self.systemFont(size + 7, weight: NSFont.Weight.bold.rawValue),
            Self.systemFont(size + 4, weight: NSFont.Weight.semibold.rawValue),
            Self.systemFont(size + 2, weight: NSFont.Weight.semibold.rawValue),
            Self.systemFont(size, weight: NSFont.Weight.semibold.rawValue),
        ]
        monoAscent = ceil(CTFontGetAscent(mono))
        monoLineHeight = ceil(CTFontGetAscent(mono) + CTFontGetDescent(mono) + CTFontGetLeading(mono)) + 4
        var glyph = CGGlyph()
        var unichar: UniChar = 48
        CTFontGetGlyphsForCharacters(mono, &unichar, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(mono, .horizontal, &glyph, &advance, 1)
        monoAdvance = max(1, advance.width)
    }

    static func systemFont(_ size: CGFloat, weight: CGFloat) -> CTFont {
        let traits: [CFString: Any] = [kCTFontWeightTrait: weight]
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    static func monoFont(_ size: CGFloat, weight: CGFloat) -> CTFont {
        // SF Mono (the system monospaced design). NSFont is toll-free bridged and safe to create off the main thread.
        NSFont.monospacedSystemFont(ofSize: size, weight: NSFont.Weight(rawValue: weight)) as CTFont
    }

    // MARK: Attributes

    static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    static let strikeKey = NSAttributedString.Key("BelloStrike")
    static let paragraphKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)

    func attributes(font: CTFont, color: CGColor) -> [NSAttributedString.Key: Any] {
        [Self.fontKey: font, Self.colorKey: color]
    }

    /// Prose with inline styles. `base` is the font for unstyled text; `color` its colour.
    func attributed(_ styled: StyledText, base: CTFont, color: CGColor, baseIsBold: Bool = false) -> NSAttributedString {
        let string = NSMutableAttributedString(string: styled.text, attributes: attributes(font: base, color: color))
        for run in styled.runs where run.location + run.length <= styled.utf16Count {
            let traits = run.traits
            var font = base
            var runColor = color
            if traits.contains(.code) {
                font = inlineCode
                if baseIsBold { font = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold) ?? font }
            } else if traits.contains(.bold) || traits.contains(.italic) {
                var symbolic: CTFontSymbolicTraits = []
                if traits.contains(.bold) { symbolic.insert(.traitBold) }
                if traits.contains(.italic) { symbolic.insert(.traitItalic) }
                font = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, symbolic, symbolic) ?? base
            }
            if traits.contains(.link) { runColor = theme.link }
            if traits.contains(.mention) { runColor = theme.mentionText }
            if traits.contains(.muted) { runColor = theme.secondary }
            var attrs = attributes(font: font, color: runColor)
            if traits.contains(.strike) { attrs[Self.strikeKey] = true }
            string.setAttributes(attrs, range: NSRange(location: run.location, length: run.length))
        }
        return string
    }

    /// A one-style string.
    func plain(_ text: String, font: CTFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: attributes(font: font, color: color))
    }
}
