import AppKit
import BelloCore
import SwiftUI

/// The visual form of a session status: an SF Symbol, a tint and the text label. Status is never colour-only: the
/// symbol shape differs per status and every view that shows the glyph also exposes `label` (visibly or as the
/// accessibility label).
public struct StatusGlyph: Hashable, Sendable {
    public var status: SessionStatus
    public var symbolName: String
    public var label: String
    /// Whether this status asks for the user (drawn in the attention tint and listed under "Needs you").
    public var needsUser: Bool

    public init(_ status: SessionStatus) {
        self.status = status
        symbolName = status.symbolName
        label = status.label
        needsUser = status.needsUser
    }

    /// The tint. Running uses the accent; blockers the attention colour; failure red; idle and unknown neutral.
    public var tint: NSColor {
        switch status {
        case .awaitingApproval, .awaitingAnswer: DS.Palette.attention
        case .failed: DS.Palette.failure
        case .running, .stopping: DS.Palette.running
        case .finishedUnread: DS.Palette.accent
        case .idle, .unknown: DS.Palette.neutral
        }
    }

    /// Statuses whose glyph is worth showing in a dense row. Idle rows stay quiet (no glyph, label still available).
    public var isQuiet: Bool { status == .idle }

    /// A template-free, tinted symbol image sized for a row (accessibility description = label).
    @MainActor
    public func image(pointSize: CGFloat = 11, weight: NSFont.Weight = .semibold) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(.init(paletteColors: [tint]))
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
    }
}

/// SwiftUI status glyph plus label, for hosted views (cards, popovers).
public struct StatusLabel: View {
    private let glyph: StatusGlyph
    private let showsText: Bool

    public init(_ status: SessionStatus, showsText: Bool = true) {
        glyph = StatusGlyph(status)
        self.showsText = showsText
    }

    public var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: glyph.symbolName)
                .foregroundStyle(Color(nsColor: glyph.tint))
                .accessibilityHidden(true)
            if showsText {
                Text(glyph.label)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(glyph.label)
    }
}
