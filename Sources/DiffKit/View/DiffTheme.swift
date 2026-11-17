import AppKit
import CoreText
import DesignSystem
import TranscriptKit

/// Colours and metrics of the diff view for one appearance and text size, on top of the transcript's theme (same
/// syntax colours, selection and find highlights). Immutable; resolved and used on the main actor (CTFont is not
/// `Sendable`; row building off the main actor needs none of this).
public struct DiffTheme: Equatable {
    public var base: TranscriptTheme
    public var addedFill: CGColor
    public var removedFill: CGColor
    public var addedWordFill: CGColor
    public var removedWordFill: CGColor
    public var addedGutterFill: CGColor
    public var removedGutterFill: CGColor
    public var addedMarker: CGColor
    public var removedMarker: CGColor
    public var hunkFill: CGColor
    public var hunkText: CGColor
    public var gapFill: CGColor
    public var fileHeaderFill: CGColor
    public var emptyCellFill: CGColor
    public var gutterText: CGColor
    public var background: CGColor
    public var focusBar: CGColor
    public var commentMark: CGColor

    public var font: CTFont
    public var boldFont: CTFont
    public var uiFont: CTFont
    public var uiBoldFont: CTFont
    public var charWidth: CGFloat
    public var rowHeight: CGFloat
    public var ascent: CGFloat
    public var fileHeaderHeight: CGFloat
    public var revision: Int

    public static func == (a: Self, b: Self) -> Bool { a.revision == b.revision && a.base == b.base }

    @MainActor
    public static func resolve(appearance: NSAppearance, baseSize: CGFloat = DS.Typography.current.baseSize, revision: Int = 0) -> DiffTheme {
        let base = TranscriptTheme.resolve(appearance: appearance, baseSize: baseSize, revision: revision)
        var theme: DiffTheme?
        appearance.performAsCurrentDrawingAppearance {
            func c(_ color: NSColor, _ alpha: CGFloat? = nil) -> CGColor {
                let resolved = color.usingColorSpace(.sRGB) ?? color
                return (alpha.map { resolved.withAlphaComponent($0) } ?? resolved).cgColor
            }
            let dark = base.isDark
            let contrast = base.increasedContrast
            let green = NSColor.systemGreen
            let red = NSColor.systemRed
            let k: CGFloat = contrast ? 1.6 : 1
            let size = max(9, baseSize - 1)
            let font = CTFontCreateWithName("SF Mono" as CFString, size, nil)
            let mono = NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
            let chosen = (CTFontCopyFamilyName(font) as String) == "SF Mono" ? font : mono
            let bold = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold) as CTFont
            var glyph = CGGlyph()
            var unit: UniChar = 0x30
            CTFontGetGlyphsForCharacters(chosen, &unit, &glyph, 1)
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(chosen, .horizontal, &glyph, &advance, 1)
            let ascent = CTFontGetAscent(chosen)
            let lineHeight = ceil(ascent + CTFontGetDescent(chosen) + CTFontGetLeading(chosen))
            theme = DiffTheme(
                base: base,
                addedFill: c(green, (dark ? 0.13 : 0.11) * k), removedFill: c(red, (dark ? 0.13 : 0.10) * k),
                addedWordFill: c(green, (dark ? 0.34 : 0.28) * k), removedWordFill: c(red, (dark ? 0.34 : 0.26) * k),
                addedGutterFill: c(green, (dark ? 0.20 : 0.17) * k), removedGutterFill: c(red, (dark ? 0.20 : 0.15) * k),
                addedMarker: c(DS.Syntax.diffAdded), removedMarker: c(DS.Syntax.diffRemoved),
                hunkFill: c(.controlAccentColor, dark ? 0.12 : 0.07), hunkText: c(.secondaryLabelColor),
                gapFill: c(.quaternarySystemFill), fileHeaderFill: c(.windowBackgroundColor),
                emptyCellFill: c(.quaternarySystemFill, dark ? 0.5 : 0.6), gutterText: c(.tertiaryLabelColor),
                background: c(.textBackgroundColor), focusBar: c(.controlAccentColor), commentMark: c(.controlAccentColor),
                font: chosen, boldFont: bold,
                uiFont: NSFont.systemFont(ofSize: max(9, baseSize - 1)) as CTFont,
                uiBoldFont: NSFont.systemFont(ofSize: max(9, baseSize - 1), weight: .semibold) as CTFont,
                charWidth: advance.width, rowHeight: max(lineHeight + 3, 16), ascent: ascent, fileHeaderHeight: max(lineHeight + 3, 16) + 12,
                revision: base.revision)
        }
        return theme!
    }
}
