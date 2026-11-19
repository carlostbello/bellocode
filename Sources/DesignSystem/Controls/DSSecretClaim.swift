import Combine
import SwiftUI

/// What BelloCode claims about who can see a secret's value (docs/features/secrets.md): glyph + words, never colour
/// alone, with an info button opening the exact guarantee and its limits. The text comes from the caller
/// (`SecretKit.SecretClaims`), so the product states one guarantee everywhere.
public struct SecretClaimBadge: View {
    public enum Kind: Sendable, Equatable {
        /// Brokered and placeholder: "The agent cannot see this value".
        case hidden
        /// Visible mode: "The agent can see this value".
        case visible
        /// Approved commands and the host pipe: "The command can reveal this value".
        case command
    }

    public let kind: Kind
    public let headline: String
    public let explanation: String
    public let limits: String?
    @StateObject private var popover = SecretClaimPopoverState()

    public init(kind: Kind, headline: String, explanation: String, limits: String? = nil) {
        self.kind = kind
        self.headline = headline
        self.explanation = explanation
        self.limits = limits
    }

    public var body: some View {
        HStack(spacing: DS.Space.s4) {
            Image(systemName: kind.symbolName)
                .font(.system(size: DS.Size.iconPointMeta))
                .foregroundStyle(kind.color)
                .accessibilityHidden(true)
            Text(headline)
                .font(.ds(.labelEmph))
                .foregroundStyle(kind.color)
            Button {
                popover.shown.toggle()
            } label: {
                Image(systemName: "info.circle").font(.system(size: DS.Size.iconPointMeta)).foregroundStyle(SwiftUI.Color.ds.text3)
            }
            .buttonStyle(.plain)
            .help("What this means exactly")
            .accessibilityLabel("Details: \(headline)")
            .glassPopover(isPresented: $popover.shown, width: 340) {
                SecretClaimDetail(kind: kind, headline: headline, explanation: explanation, limits: limits)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
final class SecretClaimPopoverState: ObservableObject {
    @Published var shown = false
}

/// The popover's content (also rendered on its own by the snapshot harness).
public struct SecretClaimDetail: View {
    public let kind: SecretClaimBadge.Kind
    public let headline: String
    public let explanation: String
    public let limits: String?

    public init(kind: SecretClaimBadge.Kind, headline: String, explanation: String, limits: String?) {
        self.kind = kind
        self.headline = headline
        self.explanation = explanation
        self.limits = limits
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s8) {
            HStack(spacing: DS.Space.s6) {
                Image(systemName: kind.symbolName).foregroundStyle(kind.color).accessibilityHidden(true)
                Text(headline).font(.ds(.title)).foregroundStyle(SwiftUI.Color.ds.text)
            }
            Text(explanation)
                .font(.ds(.body)).foregroundStyle(SwiftUI.Color.ds.text)
                .fixedSize(horizontal: false, vertical: true)
            if let limits {
                Text("Limits").font(.ds(.labelEmph)).foregroundStyle(SwiftUI.Color.ds.text2)
                Text(limits)
                    .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.s12)
        .frame(width: 340, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension SecretClaimBadge.Kind {
    var symbolName: String {
        switch self {
        case .hidden: "eye.slash"
        case .visible: "eye"
        case .command: "terminal"
        }
    }

    var color: SwiftUI.Color {
        switch self {
        case .hidden: SwiftUI.Color.ds.successText
        case .visible, .command: SwiftUI.Color.ds.warningText
        }
    }
}
