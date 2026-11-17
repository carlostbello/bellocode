import AppKit
import SwiftUI

/// BelloCode's semantic design tokens. Every surface takes colours, type, spacing, radii and motion from here, so one
/// change restyles the app and nothing hard-codes a value that ignores appearance, accent or accessibility settings.
///
/// The single source of truth is docs/design/visual-language.md, implemented in `Tokens/`: `DS.Color` (colour table,
/// dynamic for light, dark and both Increase Contrast variants), `DS.TextRole` (type scale on `Typography.baseSize`),
/// `DS.Space`/`DS.Size`/`DS.Radius`/`DS.Border`/`DS.Shadow`/`DS.Surface` and `DS.Motion`. `DS.dump()` prints all of
/// it. The older names in this file are aliases onto those values. Threading: values only; safe anywhere.
public enum DS {}

// MARK: - Colour (legacy names)

extension DS {
    /// Legacy semantic colours, kept source-compatible and re-pointed at the `DS.Color` tokens
    /// (docs/design/visual-language.md §1) so the whole app shifts to the new palette without edits elsewhere.
    ///
    /// - Deprecated: use `DS.Color` directly. Each alias names its replacement; they are deleted in restyle step 10
    ///   (docs/design/restyle-plan.md). Not marked `@available(deprecated)` so that modules restyled later do not
    ///   drown in warnings meanwhile.
    public enum Palette {
        /// → `DS.Color.text`.
        public static let text = DS.Color.text
        /// → `DS.Color.text2`.
        public static let secondaryText = DS.Color.text2
        /// → `DS.Color.text4` (timestamps, separators, disabled hints).
        public static let tertiaryText = DS.Color.text4
        /// → `DS.Color.accent` (the user's accent unless Multicolor).
        public static let accent = DS.Color.accent
        /// → `DS.Color.canvas`.
        public static let windowBackground = DS.Color.canvas
        /// → `DS.Color.canvas`.
        public static let contentBackground = DS.Color.canvas
        /// → `DS.Color.fillHover` (chips, insets, selected backgrounds).
        public static let groupFill = DS.Color.fillHover
        /// → `DS.Color.border`.
        public static let separator = DS.Color.border
        /// → `DS.Color.raised`.
        public static let cardBackground = DS.Color.raised
        /// → `DS.Color.border`.
        public static let cardBorder = DS.Color.border

        /// → `DS.Color.warningText`. Status colours are always paired with a glyph and a word (UX rule 4).
        public static let attention = DS.Color.warningText
        /// → `DS.Color.dangerText`.
        public static let failure = DS.Color.dangerText
        /// → `DS.Color.infoText`.
        public static let running = DS.Color.infoText
        /// → `DS.Color.successText`.
        public static let success = DS.Color.successText
        /// → `DS.Color.text3`.
        public static let neutral = DS.Color.text3

        /// Whether the user asked for more contrast (System Settings > Accessibility > Display).
        @MainActor public static var prefersIncreasedContrast: Bool { DS.Accessibility.increaseContrast }
    }
}

// MARK: - Typography

extension DS {
    /// The type scale. Sizes derive from one configurable `baseSize` (default: the system body size, 13 pt), so a
    /// later "text size" setting scales every surface together.
    public struct Typography: Sendable, Hashable {
        public var baseSize: CGFloat

        public init(baseSize: CGFloat = NSFont.systemFontSize) { self.baseSize = max(9, min(baseSize, 32)) }

        /// The process-wide scale. Set once at launch (or from settings) on the main actor.
        @MainActor public static var current = Typography()

        /// A role at this base size (`DS.TextRole`, visual-language.md §2). Prefer this over the legacy names below.
        public func font(_ role: DS.TextRole) -> NSFont { role.font(base: baseSize) }

        // Legacy names, mapped onto the roles. Deprecated: use `font(_:)` / `DS.TextRole`; removed in restyle step 10.

        /// → `.title` (13 semibold: thread header title, approval question).
        public var title: NSFont { font(.title) }
        /// → `.body`.
        public var body: NSFont { font(.body) }
        /// → `.bodyEmph` (medium is the emphasis weight; never bold rows).
        public var bodyEmphasized: NSFont { font(.bodyEmph) }
        /// → `.meta`.
        public var caption: NSFont { font(.meta) }
        /// → `.metaEmph`.
        public var captionEmphasized: NSFont { font(.metaEmph) }
        /// → `.metaEmph` (section labels are sentence case, medium, `text3`).
        public var sectionHeader: NSFont { font(.metaEmph) }
        /// → `.code`.
        public var monospaced: NSFont { font(.code) }
        /// → `.metaEmph` with tabular digits (counts).
        public var badge: NSFont { DS.TextRole.metaEmph.font(base: baseSize, monospacedDigits: true) }
    }
}

// MARK: - Spacing and shape

extension DS {
    /// Desktop density: compact rows, no touch-sized padding (AGENTS.md UX rule 7).
    public enum Spacing {
        public static let hairline: CGFloat = 1
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 6
        public static let m: CGFloat = 8
        public static let l: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 24

        /// Sidebar row height (matches a medium source list).
        public static let sidebarRowHeight: CGFloat = 24
        /// The sidebar's leading inset for thread rows under a project.
        public static let sidebarIndent: CGFloat = 14
        /// The content column's maximum width (transcript, request cards, composer); wider windows centre it.
        public static let readableWidth: CGFloat = DS.Size.contentMaxWidth
        /// Side margin of the content column when the window is narrower than `readableWidth`.
        public static let columnMargin: CGFloat = 24
    }

    public enum Radius {
        public static let small: CGFloat = 4
        public static let medium: CGFloat = 6
        public static let large: CGFloat = 10
        /// Cards in the content column (composer, request cards): one radius so they read as one family.
        public static let card: CGFloat = 16
        /// Capsules (badges): half the height.
        public static func capsule(height: CGFloat) -> CGFloat { height / 2 }
    }
}

// MARK: - Motion

extension DS {
    /// Motion rules (AGENTS.md rule 17): no implicit animation on streaming or layout updates; panels are instant by
    /// default; Reduce Motion removes non-essential movement.
    public enum Motion {
        /// Panel show/hide duration. 0 (instant) by default; a later setting may raise it.
        @MainActor public static var panelDuration: TimeInterval = 0
        /// Small, non-layout feedback (a toast fading in).
        public static let feedbackDuration: TimeInterval = 0.15

        @MainActor public static var reduceMotion: Bool { DS.Accessibility.reduceMotion }

        /// The duration to use for a panel change: 0 when instant or when Reduce Motion is on.
        @MainActor public static var effectivePanelDuration: TimeInterval { reduceMotion ? 0 : panelDuration }

        /// The duration to use for non-essential feedback: 0 under Reduce Motion.
        @MainActor public static var effectiveFeedbackDuration: TimeInterval { reduceMotion ? 0 : feedbackDuration }

        /// Runs `changes` without implicit animation (for streaming and layout updates).
        @MainActor public static func withoutAnimation(_ changes: () -> Void) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                changes()
            }
        }
    }
}

// MARK: - SwiftUI mirrors

extension DS.Palette {
    /// SwiftUI equivalents for hosted views. Deprecated: use `Color.ds`.
    public enum SwiftUIColors {
        public static let text = SwiftUI.Color(nsColor: DS.Palette.text)
        public static let secondaryText = SwiftUI.Color(nsColor: DS.Palette.secondaryText)
        public static let accent = SwiftUI.Color(nsColor: DS.Palette.accent)
        public static let attention = SwiftUI.Color(nsColor: DS.Palette.attention)
        public static let failure = SwiftUI.Color(nsColor: DS.Palette.failure)
    }
}
