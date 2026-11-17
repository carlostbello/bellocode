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
        symbolName = Self.symbolName(for: status)
        label = status.label
        needsUser = status.needsUser
    }

    /// How a row draws the glyph (visual-language.md §5): one outline SF Symbol set, a drawn arc spinner for running,
    /// and a 6 pt dot for unread. No emoji, no filled variants.
    public enum Shape: Hashable, Sendable { case symbol, spinner, dot }

    public var shape: Shape {
        switch status {
        case .running: .spinner
        case .finishedUnread: .dot
        default: .symbol
        }
    }

    /// The outline symbol per status (also the still image for running, which rows draw as a spinner).
    public static func symbolName(for status: SessionStatus) -> String {
        switch status {
        case .awaitingApproval: "exclamationmark.shield"
        case .awaitingAnswer: "questionmark.bubble"
        case .failed: "exclamationmark.triangle"
        case .stopping: "stop.circle"
        case .running: "circle.dotted"
        case .finishedUnread: "circle.fill"
        case .idle: "circle"
        case .unknown: "questionmark.circle"
        }
    }

    /// The semantic tone: approval warning, question and running info, failure danger, the rest neutral.
    public var tone: DS.Tone {
        switch status {
        case .awaitingApproval: .warning
        case .awaitingAnswer, .running, .finishedUnread: .info
        case .failed: .danger
        case .stopping, .idle, .unknown: .neutral
        }
    }

    /// The tint: the tone's text colour (`warningText`, `infoText`, `dangerText`), `text3` when neutral.
    public var tint: NSColor { tone == .neutral ? DS.Color.text3 : DS.Color.tone(tone).text }

    /// Statuses whose glyph is worth showing in a dense row. Idle rows stay quiet (no glyph, label still available).
    public var isQuiet: Bool { status == .idle }

    /// A template-free, tinted symbol image sized for a row (accessibility description = label).
    @MainActor
    public func image(pointSize: CGFloat = DS.Size.iconPointRow, weight: NSFont.Weight = .regular) -> NSImage? {
        let pointSize = shape == .dot ? min(pointSize, 6) : pointSize
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
            DSStatusGlyphRepresentable(status: glyph.status)
                .frame(width: DS.Size.statusGlyph, height: DS.Size.statusGlyph)
                .accessibilityHidden(true)
            if showsText {
                Text(glyph.label).foregroundStyle(glyph.tone == .neutral ? SwiftUI.Color.ds.text3 : SwiftUI.Color(nsColor: glyph.tint))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(glyph.label)
    }
}
