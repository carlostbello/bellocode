import SwiftUI

/// A neutral, labelled pane for regions of the window that a later work package fills in.
///
/// It is deliberately plain: a symbol, a title and one line of detail, centred, using system colours so it works in
/// light and dark appearance.
public struct PlaceholderPane: View {
    private let title: String
    private let systemImage: String
    private let detail: String

    public init(_ title: String, systemImage: String, detail: String) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
    }

    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
