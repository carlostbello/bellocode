import AppKit
import CoreText
import DesignSystem
import TranscriptKit

/// Colours and metrics of the diff view for one appearance and text size, from the DesignSystem diff tokens
/// (visual-language.md §1 "Diff, code and terminal", §6 "Right panel"): `canvas` background, line fills
/// `diffAddLine`/`diffDelLine`, gutters `diffAddGutter`/`diffDelGutter`, word emphasis `diffAddWord`/`diffDelWord`,
/// hunk bar `diffHunk` with `text3` mono, `text4` line numbers, `codeSmall` lines 19 high, 34 pt file header, 24 pt hunk
/// bar and collapsed-context row. Syntax, selection and find colours come from the transcript's theme. Immutable;
/// resolved and used on the main actor (CTFont is not `Sendable`; row building off the main actor needs none of this).
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
    public var modifiedMarker: CGColor
    public var hunkFill: CGColor
    public var hunkText: CGColor
    public var gapFill: CGColor
    public var fileHeaderFill: CGColor
    public var emptyCellFill: CGColor
    public var gutterText: CGColor
    public var background: CGColor
    public var border: CGColor
    public var text2: CGColor
    public var text3: CGColor
    /// Ghost-button hover fill (Revert, the gap row on hover).
    public var hoverFill: CGColor
    public var focusBar: CGColor
    public var commentMark: CGColor
    /// Review threads (GitLab 2): the card (`raised` + `border`), text, and status tones (glyph + word, colour third).
    public var cardFill: CGColor
    public var cardBorder: CGColor
    public var text: CGColor
    public var warningText: CGColor
    public var successText: CGColor
    public var infoText: CGColor
    /// `body` 13 for note bodies, `meta` 11 for times and states.
    public var proseFont: CTFont
    public var metaFont: CTFont

    public var font: CTFont
    public var boldFont: CTFont
    /// Line numbers: 10.5 pt mono (one point under the code).
    public var gutterFont: CTFont
    /// `label` 12 (hunk actions, gap row) and `labelEmph` (file names).
    public var uiFont: CTFont
    public var uiBoldFont: CTFont
    /// The M/A/D badge letter: mono 9 bold.
    public var badgeFont: CTFont
    public var charWidth: CGFloat
    public var rowHeight: CGFloat
    public var ascent: CGFloat
    public var fileHeaderHeight: CGFloat
    public var hunkHeaderHeight: CGFloat
    public var gapHeight: CGFloat
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
            // Increase Contrast strengthens the tints (the tokens carry no HC variant for these alphas).
            func tint(_ color: NSColor) -> CGColor {
                let resolved = color.usingColorSpace(.sRGB) ?? color
                guard base.increasedContrast else { return resolved.cgColor }
                return resolved.withAlphaComponent(min(1, resolved.alphaComponent * 1.6)).cgColor
            }
            let role = DS.TextRole.codeSmall
            let size = role.font(base: baseSize).pointSize
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
            let delta = baseSize - DS.TextRole.defaultBase
            let rowHeight = max(lineHeight + 3, DS.Size.diffLine + delta)
            theme = DiffTheme(
                base: base,
                addedFill: tint(DS.Color.diffAddLine), removedFill: tint(DS.Color.diffDelLine),
                addedWordFill: tint(DS.Color.diffAddWord), removedWordFill: tint(DS.Color.diffDelWord),
                addedGutterFill: tint(DS.Color.diffAddGutter), removedGutterFill: tint(DS.Color.diffDelGutter),
                addedMarker: c(DS.Color.successText), removedMarker: c(DS.Color.dangerText), modifiedMarker: c(DS.Color.diffModifiedIcon),
                hunkFill: tint(DS.Color.diffHunk), hunkText: c(DS.Color.text3),
                gapFill: c(DS.Color.canvas), fileHeaderFill: c(DS.Color.canvas),
                emptyCellFill: c(DS.Color.fillSubtle), gutterText: c(DS.Color.text4),
                background: c(DS.Color.canvas), border: c(DS.Color.border), text2: c(DS.Color.text2), text3: c(DS.Color.text3),
                hoverFill: c(DS.Color.fillHover), focusBar: c(DS.Color.accent), commentMark: c(DS.Color.infoText),
                cardFill: c(DS.Color.raised), cardBorder: c(DS.Color.borderStrong), text: c(DS.Color.text), warningText: c(DS.Color.warningText),
                successText: c(DS.Color.successText), infoText: c(DS.Color.infoText),
                proseFont: DS.TextRole.body.font(base: baseSize) as CTFont, metaFont: DS.TextRole.meta.font(base: baseSize) as CTFont,
                font: chosen, boldFont: bold,
                gutterFont: NSFont.monospacedDigitSystemFont(ofSize: size - 1, weight: .regular) as CTFont,
                uiFont: DS.TextRole.label.font(base: baseSize) as CTFont,
                uiBoldFont: DS.TextRole.labelEmph.font(base: baseSize) as CTFont,
                badgeFont: NSFont.monospacedSystemFont(ofSize: 9 + delta * 0.5, weight: .bold) as CTFont,
                charWidth: advance.width, rowHeight: rowHeight, ascent: ascent,
                fileHeaderHeight: DS.Size.diffFileHeader + delta,
                hunkHeaderHeight: DS.Size.diffHunkBar + delta,
                gapHeight: DS.Size.diffHunkBar + delta,
                revision: base.revision)
        }
        return theme!
    }
}
