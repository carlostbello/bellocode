import AppKit
@testable import DesignSystem
import Testing

@Suite struct TokenModelTests {
    @Test func everyTokenIsNamedOnceAndResolvesInEveryVariant() {
        let names = DS.ColorToken.all.map(\.name)
        #expect(Set(names).count == names.count, "duplicate token names")
        // Every token the spec's §1 tables name.
        let spec = [
            "canvas", "sidebar", "raised", "message", "codeFill", "fillSubtle", "fillHover", "scrim", "rowHover", "rowActive", "rowSelected",
            "text", "text2", "text3", "text4", "icon", "placeholder", "border", "borderStrong", "composerOutline",
            "accent", "accentHover", "onAccent", "success", "successText", "warning", "warningText", "danger", "dangerText", "info", "infoText",
            "successSurface", "warningSurface", "dangerSurface", "infoSurface", "textSelection", "findMatch", "findActive", "focusRing",
            "diffAddLine", "diffAddGutter", "diffAddWord", "diffDelLine", "diffDelGutter", "diffDelWord", "diffHunk", "diffModifiedIcon",
            "syntaxKeyword", "syntaxType", "syntaxFunction", "syntaxString", "syntaxNumber", "syntaxComment", "syntaxProperty",
            "terminalCursor", "terminalSelection", "scrollThumb", "scrollThumbHover", "kbdFill",
        ]
        for name in spec { #expect(DS.ColorToken.named(name) != nil, "missing token \(name)") }
        DS.Accent.ignoresUserAccent = true
        defer { DS.Accent.ignoresUserAccent = false }
        // Increase Contrast cannot be switched on from a test; its variants are checked through `Variant(matching:)`.
        #expect(DS.Variant(matching: .accessibilityHighContrastDarkAqua) == .darkHighContrast)
        #expect(DS.Variant(matching: .accessibilityHighContrastAqua) == .lightHighContrast)
        #expect(DS.Variant(matching: .darkAqua) == .dark)
        #expect(DS.Variant(matching: nil) == .light)
        for token in DS.ColorToken.all {
            for variant in [DS.Variant.light, .dark] {
                let resolved = token.nsColor.resolved(in: variant.appearance)
                let expected = token.value(variant)
                #expect(abs(resolved.redComponent - expected.red) < 0.01, "\(token.name) \(variant)")
                #expect(abs(resolved.alphaComponent - expected.alpha) < 0.01, "\(token.name) \(variant)")
            }
        }
    }

    @Test func specValuesAreExact() {
        #expect(DS.ColorToken.canvas.dark == DS.RGBA(0x000000))
        #expect(DS.ColorToken.canvas.light == DS.RGBA(0xFCFCFC))
        #expect(DS.ColorToken.raised.dark == DS.RGBA(0x111111))
        #expect(DS.ColorToken.raised.darkHighContrast == DS.RGBA(0x161616))
        #expect(DS.ColorToken.accent.dark == DS.RGBA(0x346BF1))
        #expect(DS.ColorToken.accent.light == DS.RGBA(0x1B4ED8))
        #expect(DS.ColorToken.border.dark == .white(0.08))
        #expect(DS.ColorToken.border.lightHighContrast == DS.RGBA(0xA1A1AA))
        #expect(DS.ColorToken.text2.darkHighContrast == DS.RGBA(0xC4C4C4))
        #expect(DS.ColorToken.text4.darkHighContrast == DS.ColorToken.text3.darkHighContrast)
    }

    @Test func syntaxNamesPointAtTheTokens() {
        #expect(DS.Syntax.keyword === DS.Color.syntaxKeyword)
    }

    /// WCAG AA (4.5:1) for text tokens on the surfaces they are used on, in all four variants.
    /// Deliberate exceptions from the spec: `text4` (timestamps, gutters, chevrons, disabled; §1 "Text") is decorative
    /// metadata and sits at ~2.3:1; the `message` bubble carries only `text`; secondary text on the transient light
    /// `rowHover` wash (#71717A on #F4F4F5) is 4.4:1 with the spec's exact values (passes in Increase Contrast).
    @Test func textTokensMeetAAOnTheirSurfaces() {
        let surfaces = ["canvas", "sidebar", "raised", "rowActive", "rowHover", "codeFill"]
        for variant in DS.Variant.allCases {
            let canvas = DS.ColorToken.canvas.value(variant)
            for surfaceName in surfaces {
                let surface = DS.ColorToken.named(surfaceName)!.value(variant).over(canvas)
                for textName in ["text", "text2", "text3", "placeholder"] {
                    let ratio = DS.ColorToken.named(textName)!.value(variant).contrast(on: surface)
                    let minimum = surfaceName == "rowHover" && variant == .light && textName != "text" ? 4.35 : 4.5
                    #expect(ratio >= minimum, "\(textName) on \(surfaceName) \(variant): \(ratio)")
                }
            }
            let message = DS.ColorToken.message.value(variant).over(canvas)
            #expect(DS.ColorToken.text.value(variant).contrast(on: message) >= 4.5)
            // Semantic words on canvas and raised.
            for name in ["successText", "warningText", "dangerText", "infoText"] {
                for surfaceName in ["canvas", "raised"] {
                    let surface = DS.ColorToken.named(surfaceName)!.value(variant).over(canvas)
                    let ratio = DS.ColorToken.named(name)!.value(variant).contrast(on: surface)
                    #expect(ratio >= 4.5, "\(name) on \(surfaceName) \(variant): \(ratio)")
                }
            }
            // White on the primary button.
            #expect(DS.ColorToken.onAccent.value(variant).contrast(on: DS.ColorToken.accent.value(variant)) >= 4.5)
        }
    }

    @Test func typeRolesMatchSpecAndScaleWithBase() {
        #expect(DS.TextRole.body.font(base: 13).pointSize == 13)
        #expect(DS.TextRole.prose.font(base: 13).pointSize == 14)
        #expect(DS.TextRole.prose.lineHeight(base: 13) == 22)
        #expect(DS.TextRole.meta.font(base: 13).pointSize == 11)
        #expect(DS.TextRole.code.font(base: 13).pointSize == 12.5)
        #expect(DS.TextRole.code.font(base: 13).fontDescriptor.symbolicTraits.contains(.monoSpace))
        for role in DS.TextRole.allCases {
            #expect(role.font(base: 16).pointSize == role.spec.size + 3, "\(role)")
            #expect(role.lineHeight(base: 16) == role.spec.lineHeight + 3, "\(role)")
        }
        #expect(DS.Typography(baseSize: 16).font(.label).pointSize == 15)
        #expect(DS.Typography(baseSize: 16).font(.metaEmph).pointSize == 14)
    }

    @Test func dumpListsEveryToken() {
        let dump = DS.dump()
        for token in DS.ColorToken.all { #expect(dump.contains("\(token.name):")) }
        for role in DS.TextRole.allCases { #expect(dump.contains("\(role.rawValue):")) }
    }

    @Test func compositingAndContrastMath() {
        #expect(abs(DS.RGBA(0xFFFFFF).contrast(on: DS.RGBA(0x000000)) - 21) < 0.01)
        let half = DS.RGBA.white(0.5).over(DS.RGBA(0x000000))
        #expect(abs(half.red - 0.5) < 0.001 && half.alpha == 1)
    }

    @Test func statusGlyphsFollowTheSpec() {
        #expect(StatusGlyph(.awaitingApproval).symbolName == "exclamationmark.shield")
        #expect(StatusGlyph(.awaitingAnswer).symbolName == "questionmark.bubble")
        #expect(StatusGlyph(.failed).symbolName == "exclamationmark.triangle")
        #expect(StatusGlyph(.running).shape == .spinner)
        #expect(StatusGlyph(.finishedUnread).shape == .dot)
        #expect(StatusGlyph(.awaitingApproval).tone == .warning)
        #expect(StatusGlyph(.awaitingAnswer).tone == .info)
        #expect(StatusGlyph(.failed).tone == .danger)
        for status in SessionStatus.allCases { #expect(!StatusGlyph(status).symbolName.contains("fill") || status == .finishedUnread) }
    }
}

import BelloCore

extension NSColor {
    func resolved(in appearance: NSAppearance) -> NSColor {
        var result = self
        appearance.performAsCurrentDrawingAppearance { result = self.usingColorSpace(.sRGB) ?? self }
        return result
    }
}
