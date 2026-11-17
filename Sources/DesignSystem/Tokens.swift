import AppKit
import SwiftUI

/// BelloCode's semantic design tokens. Every surface takes colours, type, spacing, radii and motion from here, so one
/// change restyles the app and nothing hard-codes a value that ignores appearance, accent or accessibility settings.
///
/// The single source of truth is docs/design/visual-language.md, implemented in `Tokens/`: `DS.Color` (colour table,
/// dynamic for light, dark and both Increase Contrast variants), `DS.TextRole` (type scale on `Typography.baseSize`),
/// `DS.Space`/`DS.Size`/`DS.Radius`/`DS.Border`/`DS.Shadow`/`DS.Surface` and `DS.Motion`. `DS.dump()` prints all of
/// it. Threading: values only; safe anywhere.
public enum DS {}

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
    }
}

extension DS {
    /// Corner radii (`r.xs`…`r.xl`, Tokens/MetricTokens.swift).
    public enum Radius {}
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
