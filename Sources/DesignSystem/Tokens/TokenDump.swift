import AppKit

extension DS {
    /// A plain-text dump of every token (colours per variant, type roles at `base`, metrics, motion), for verification
    /// against visual-language.md. `swift run DesignGallery --dump-tokens` prints it.
    public static func dump(base: CGFloat = DS.TextRole.defaultBase) -> String {
        var lines = ["# BelloCode design tokens", "", "## Colour (light | dark | light HC | dark HC)"]
        for group in ColorToken.Group.allCases {
            let tokens = ColorToken.all.filter { $0.group == group }
            guard !tokens.isEmpty else { continue }
            lines.append("### \(group.rawValue)")
            for token in tokens {
                let values = Variant.allCases.map { token.value($0).description }.joined(separator: " | ")
                lines.append("\(token.name): \(values)\(token.followsUserAccent ? " [user accent]" : "") — \(token.use)")
            }
        }
        lines += ["", "## Type (base \(base))"]
        for role in TextRole.allCases {
            let s = role.spec
            lines.append(
                "\(role.rawValue): \(role.size(base: base))/\(role.lineHeight(base: base)) weight \(s.weight.rawValue) tracking \(s.tracking)\(s.mono ? " mono" : "")")
        }
        lines += [
            "", "## Space", Space.scale.map { "\($0)" }.joined(separator: " "),
            "", "## Radius", "xs \(Radius.xs) sm \(Radius.sm) md \(Radius.md) lg \(Radius.lg) xl \(Radius.xl) (continuous)",
            "", "## Size",
            "header \(Size.header) sidebar \(Size.sidebarWidth) [\(Size.sidebarMinWidth)–\(Size.sidebarMaxWidth)] panel \(Size.rightPanelWidth) column \(Size.contentMaxWidth) gutter \(Size.gutter)",
            "rows: sidebar \(Size.sidebarRow)/\(Size.sidebarRowTwoLine) menu \(Size.menuRow) palette \(Size.paletteRow) tool \(Size.toolRow) diff \(Size.diffLine)",
            "controls: \(Size.control)/\(Size.controlSmall) composer \(Size.composerControl) send \(Size.send) micro \(Size.micro) tab \(Size.tab) kbd \(Size.kbd) pill \(Size.pill)",
            "", "## Shadow",
            "composer dark \(Shadow.composer(dark: true)) light \(Shadow.composer(dark: false))",
            "popover dark \(Shadow.popover(dark: true)) light \(Shadow.popover(dark: false))",
            "dialog \(Shadow.dialog)",
            "", "## Motion",
            "panels instant; popIn \(Motion.popInDuration)s scale \(Motion.popInScale); popOut \(Motion.popOutDuration)s; press \(Motion.pressScale) release \(Motion.pressReleaseDuration)s; reorder \(Motion.rowReorderDuration)s; stream fade \(Motion.streamFadeInDuration)s; toast \(Motion.toastDismissDelay)s; spinner \(Motion.spinnerSteps) steps / \(Motion.spinnerPeriod)s",
            "", "## Surfaces",
        ]
        for surface in Surface.allCases {
            lines.append("\(surface.rawValue): material \(surface.material.rawValue) blending \(surface.blending.rawValue) tint \(surface.tintAlpha)")
        }
        return lines.joined(separator: "\n")
    }
}
