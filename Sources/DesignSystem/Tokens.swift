import AppKit
import SwiftUI

/// BelloCode's semantic design tokens. Every surface takes colours, type, spacing, radii and motion from here, so one
/// change restyles the app and nothing hard-codes a value that ignores appearance, accent or accessibility settings.
///
/// Colours are semantic (what the colour means), built from system dynamic colours, so they follow light/dark
/// appearance, the user's accent colour and Increase Contrast automatically. Threading: values only; safe anywhere.
public enum DS {}

// MARK: - Colour

extension DS {
    /// Semantic colours. AppKit (`NSColor`) is primary; `swiftUI` mirrors each for hosted views.
    public enum Palette {
        /// Primary text.
        public static let text = NSColor.labelColor
        /// Secondary text: metadata, timestamps, paths.
        public static let secondaryText = NSColor.secondaryLabelColor
        /// Tertiary text: placeholders, disabled hints.
        public static let tertiaryText = NSColor.tertiaryLabelColor
        /// The user's accent colour (selection, primary buttons, unread marks).
        public static let accent = NSColor.controlAccentColor
        /// Window and content backgrounds.
        public static let windowBackground = NSColor.windowBackgroundColor
        public static let contentBackground = NSColor.textBackgroundColor
        /// A subtle fill for grouped content (cards, the user's message, the composer).
        public static let groupFill = NSColor.quaternarySystemFill
        /// Hairlines between regions.
        public static let separator = NSColor.separatorColor

        /// Status meanings. Always shown with a glyph and text, never by colour alone (AGENTS.md UX rule 4).
        public static let attention = NSColor.systemOrange
        public static let failure = NSColor.systemRed
        public static let running = NSColor.controlAccentColor
        public static let success = NSColor.systemGreen
        public static let neutral = NSColor.secondaryLabelColor

        /// Whether the user asked for more contrast (System Settings > Accessibility > Display).
        @MainActor public static var prefersIncreasedContrast: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
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

        /// Thread and window titles.
        public var title: NSFont { .systemFont(ofSize: baseSize + 2, weight: .semibold) }
        /// Body text: messages, row titles, the composer.
        public var body: NSFont { .systemFont(ofSize: baseSize) }
        public var bodyEmphasized: NSFont { .systemFont(ofSize: baseSize, weight: .medium) }
        /// Metadata: times, paths, status lines.
        public var caption: NSFont { .systemFont(ofSize: baseSize - 2) }
        /// Section headers in the sidebar ("Needs you", "Projects").
        public var sectionHeader: NSFont { .systemFont(ofSize: baseSize - 2, weight: .semibold) }
        /// Code, paths shown as code, terminal-adjacent text.
        public var monospaced: NSFont { .monospacedSystemFont(ofSize: baseSize - 1, weight: .regular) }
        /// Small counts (badges).
        public var badge: NSFont { .monospacedDigitSystemFont(ofSize: baseSize - 3, weight: .semibold) }
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
        /// Readable transcript width; wider windows centre the column.
        public static let readableWidth: CGFloat = 760
    }

    public enum Radius {
        public static let small: CGFloat = 4
        public static let medium: CGFloat = 6
        public static let large: CGFloat = 10
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

        @MainActor public static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

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
    /// SwiftUI equivalents for hosted views.
    public enum SwiftUIColors {
        public static let text = Color(nsColor: DS.Palette.text)
        public static let secondaryText = Color(nsColor: DS.Palette.secondaryText)
        public static let accent = Color(nsColor: DS.Palette.accent)
        public static let attention = Color(nsColor: DS.Palette.attention)
        public static let failure = Color(nsColor: DS.Palette.failure)
    }
}
