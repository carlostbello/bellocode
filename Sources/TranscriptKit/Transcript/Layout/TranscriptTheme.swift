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
    /// `text2`: tool verbs, reasoning body, secondary labels.
    public var secondary: CGColor
    /// `text3`: summaries, metadata, language labels.
    public var tertiary: CGColor
    /// `text4`: durations, timestamps, chevrons (never content).
    public var quaternary: CGColor
    /// Default icon tint (copy button).
    public var icon: CGColor
    public var link: CGColor
    public var accent: CGColor
    public var codeBackground: CGColor
    /// Code block edge: `border` 70 % in light, none in dark (visual-language.md §4).
    public var codeBorder: CGColor?
    public var cardBackground: CGColor
    /// Card edge: `border` 70 % in light, none in dark.
    public var cardBorder: CGColor
    public var separator: CGColor
    /// `borderStrong`: table header rule.
    public var strongSeparator: CGColor
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
    public var warning: CGColor
    public var running: CGColor
    /// Spinner track (`borderStrong`).
    public var spinnerTrack: CGColor
    public var hoverFill: CGColor
    /// Syntax colours indexed by `TokenKind.rawValue`.
    public var syntax: [CGColor]

    /// Changes whenever anything above changes; part of the layout cache key.
    public var revision: Int

    // Metrics (points), visual-language.md §6 "Chat column".
    public static let rowGap: CGFloat = 6
    public static let turnGap: CGFloat = 24
    /// Paragraph gap.
    public static let blockSpacing: CGFloat = 10
    public static let listSpacing: CGFloat = 4
    public static let indentStep: CGFloat = 20
    public static let quoteStep: CGFloat = 14
    /// Code block body padding: horizontal, top (below the header), bottom.
    public static let codePadding: CGFloat = 14
    public static let codePaddingTop: CGFloat = 6
    public static let codePaddingBottom: CGFloat = 12
    public static let codeHeaderHeight: CGFloat = DS.Size.codeBlockHeader
    public static let toolOutputMaxHeight: CGFloat = 220
    public static let imageMaxHeight: CGFloat = 320
    public static let userBubbleMaxFraction: CGFloat = 0.8
    /// Tool row height (status glyph 14, verb, target, stats).
    public static let toolRowHeight: CGFloat = DS.Size.toolRow
    /// Work-group summary and reasoning disclosure line.
    public static let summaryRowHeight: CGFloat = 24
    /// Indent of a group's child tool rows and of the expanded reasoning text.
    public static let childIndent: CGFloat = 18
    /// Display bound for one monospaced line (copy returns the whole line). Lines are scrolled horizontally, not cut
    /// at a few hundred characters; this only bounds pathological single lines (minified bundles).
    public static let maxDisplayLineUTF16 = 16_384

    /// `prose` (14 at the default base 13).
    public var bodySize: CGFloat { DS.TextRole.prose.size(base: baseSize) }
    public var proseLineHeight: CGFloat { DS.TextRole.prose.lineHeight(base: baseSize) }
    /// User bubble line height (prose at 21).
    public var bubbleLineHeight: CGFloat { proseLineHeight - 1 }
    /// `code` (12.5 / 19).
    public var monoSize: CGFloat { DS.TextRole.code.size(base: baseSize) }
    public var monoLineHeight: CGFloat { DS.TextRole.code.lineHeight(base: baseSize) }
    /// `meta` (11).
    public var smallSize: CGFloat { DS.TextRole.meta.size(base: baseSize) }
    /// `body` (13 / 18): tool rows, summaries, table cells.
    public var uiSize: CGFloat { DS.TextRole.body.size(base: baseSize) }
    public var uiLineHeight: CGFloat { DS.TextRole.body.lineHeight(base: baseSize) }
    /// Tool targets in mono (12).
    public var targetMonoSize: CGFloat { DS.TextRole.label.size(base: baseSize) }
    /// Expanded reasoning (13 / 20).
    public var reasoningLineHeight: CGFloat { uiLineHeight + 2 }

    /// Resolves the theme for an appearance (on the main actor: dynamic colours resolve against the drawing appearance).
    @MainActor
    public static func resolve(appearance: NSAppearance, baseSize: CGFloat, revision: Int) -> TranscriptTheme {
        var theme: TranscriptTheme?
        appearance.performAsCurrentDrawingAppearance {
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
                .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            func c(_ color: NSColor) -> CGColor { color.usingColorSpace(.sRGB)?.cgColor ?? color.cgColor }
            let kinds: [TokenKind] = [
                .keyword, .type, .string, .comment, .number, .function, .property, .tag, .attribute, .variable, .meta,
                .diffAdded, .diffRemoved, .diffHunk, .diffHeader,
            ]
            var syntax = [CGColor](repeating: c(DS.Color.text), count: kinds.count)
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
            // Light cards and code blocks carry a 70 % hairline; dark ones are fill only (high contrast keeps it).
            let edge: CGColor? = (dark && !contrast) ? nil : c(DS.Color.border.withAlphaComponent(contrast ? 1 : 0.7))
            let text = DS.Color.text
            theme = TranscriptTheme(
                baseSize: baseSize, isDark: dark, increasedContrast: contrast,
                text: c(text), secondary: c(DS.Color.text2), tertiary: c(DS.Color.text3), quaternary: c(DS.Color.text4),
                icon: c(DS.Color.icon), link: c(DS.Color.infoText), accent: c(DS.Color.accent),
                codeBackground: c(DS.Color.codeFill), codeBorder: edge,
                cardBackground: c(dark ? DS.Color.fillSubtle : DS.Color.raised), cardBorder: edge ?? CGColor(gray: 0, alpha: 0),
                separator: c(DS.Color.border), strongSeparator: c(DS.Color.borderStrong), userBubble: c(DS.Color.message),
                inlineCodeFill: c(text.withAlphaComponent(dark ? 0.1 : 0.07)),
                mentionFill: c(DS.Color.infoSurface), mentionText: c(DS.Color.infoText),
                selection: c(DS.Color.textSelection), inactiveSelection: c(DS.Color.highlight),
                findHighlight: c(DS.Color.findMatch), findCurrent: c(DS.Color.findActive),
                failure: c(DS.Color.dangerText), failureFill: c(DS.Color.dangerSurface),
                success: c(DS.Color.successText), warning: c(DS.Color.warningText), running: c(DS.Color.infoText),
                spinnerTrack: c(DS.Color.borderStrong), hoverFill: c(DS.Color.fillHover),
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
    /// `prose` regular; `bold` is the 600 weight Markdown strong uses.
    let body: CTFont
    let bold: CTFont
    let italic: CTFont
    let boldItalic: CTFont
    let semibold: CTFont
    /// `body` (13): tool rows, summaries, cards.
    let ui: CTFont
    let uiMedium: CTFont
    /// Table cells: prose size with tabular digits.
    let tabular: CTFont
    let tabularSemibold: CTFont
    /// `meta` (11).
    let small: CTFont
    let smallBold: CTFont
    let smallMono: CTFont
    /// `code` (12.5 / 19).
    let mono: CTFont
    let monoBold: CTFont
    /// Tool targets (mono 12).
    let targetMono: CTFont
    let inlineCode: CTFont
    /// h1 18, h2 16, h3 14, h4+ 14, all semibold.
    let headings: [CTFont]
    let monoLineHeight: CGFloat
    let monoAscent: CGFloat
    let monoAdvance: CGFloat

    init(theme: TranscriptTheme) {
        self.theme = theme
        let size = theme.bodySize
        let semiboldWeight = NSFont.Weight.semibold.rawValue
        body = Self.systemFont(size, weight: NSFont.Weight.regular.rawValue)
        bold = Self.systemFont(size, weight: semiboldWeight)
        italic = CTFontCreateCopyWithSymbolicTraits(body, 0, nil, .traitItalic, .traitItalic) ?? body
        boldItalic = CTFontCreateCopyWithSymbolicTraits(bold, 0, nil, .traitItalic, .traitItalic) ?? bold
        semibold = bold
        ui = Self.systemFont(theme.uiSize, weight: NSFont.Weight.regular.rawValue)
        uiMedium = Self.systemFont(theme.uiSize, weight: NSFont.Weight.medium.rawValue)
        tabular = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular) as CTFont
        tabularSemibold = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold) as CTFont
        small = Self.systemFont(theme.smallSize, weight: NSFont.Weight.regular.rawValue)
        smallBold = Self.systemFont(theme.smallSize, weight: NSFont.Weight.medium.rawValue)
        smallMono = Self.monoFont(theme.smallSize, weight: NSFont.Weight.regular.rawValue)
        mono = Self.monoFont(theme.monoSize, weight: NSFont.Weight.regular.rawValue)
        monoBold = Self.monoFont(theme.monoSize, weight: semiboldWeight)
        targetMono = Self.monoFont(theme.targetMonoSize, weight: NSFont.Weight.regular.rawValue)
        // Inline code at 0.86 em of prose (visual-language.md §6).
        inlineCode = Self.monoFont((size * 0.86 * 2).rounded() / 2, weight: NSFont.Weight.regular.rawValue)
        headings = [
            Self.systemFont(DS.TextRole.proseH1.size(base: theme.baseSize), weight: semiboldWeight),
            Self.systemFont(DS.TextRole.proseH2.size(base: theme.baseSize), weight: semiboldWeight),
            Self.systemFont(DS.TextRole.proseH3.size(base: theme.baseSize), weight: semiboldWeight),
            Self.systemFont(DS.TextRole.proseH3.size(base: theme.baseSize), weight: semiboldWeight),
        ]
        // Fixed code line height (19 at the default size); glyphs centred in it.
        monoLineHeight = theme.monoLineHeight
        monoAscent = ceil(CTFontGetAscent(mono) + (theme.monoLineHeight - CTFontGetAscent(mono) - CTFontGetDescent(mono)) / 2) - 2
        var glyph = CGGlyph()
        var unichar: UniChar = 48
        CTFontGetGlyphsForCharacters(mono, &unichar, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(mono, .horizontal, &glyph, &advance, 1)
        monoAdvance = max(1, advance.width)
    }

    /// Fixed line height for prose in `font` (prose 22, headings per role, anything else its natural height + 4).
    func lineHeight(for font: CTFont) -> CGFloat {
        let size = CTFontGetSize(font)
        if size == CTFontGetSize(body) { return theme.proseLineHeight }
        if size == CTFontGetSize(headings[0]) { return DS.TextRole.proseH1.lineHeight(base: theme.baseSize) }
        if size == CTFontGetSize(headings[1]) { return DS.TextRole.proseH2.lineHeight(base: theme.baseSize) }
        if size == CTFontGetSize(ui) { return theme.uiLineHeight }
        return ceil(CTFontGetAscent(font) + CTFontGetDescent(font)) + 4
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
                font = CTFontGetSize(base) == CTFontGetSize(body) ? inlineCode : Self.monoFont(CTFontGetSize(base) * 0.9, weight: NSFont.Weight.regular.rawValue)
                if baseIsBold { font = Self.monoFont(CTFontGetSize(font), weight: NSFont.Weight.semibold.rawValue) }
            } else if traits.contains(.bold) || traits.contains(.italic) {
                // Strong is semibold (600), never the heavier bold trait.
                if traits.contains(.bold), !baseIsBold {
                    font = Self.systemFont(CTFontGetSize(base), weight: NSFont.Weight.semibold.rawValue)
                }
                if traits.contains(.italic) {
                    font = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic) ?? font
                }
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
