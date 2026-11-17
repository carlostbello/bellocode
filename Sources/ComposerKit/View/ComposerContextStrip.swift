import AppKit
import DesignSystem

/// The 26 pt context strip under the composer (visual-language.md §6 "Composer", AGENTS.md UX rule 6): project, branch
/// and worktree as `meta text3` with 12 pt glyphs at the leading end, the send-key hint ("↩ queues · ⌘↩ steers") at the
/// trailing end. Text, never colour only. Install it as `ComposerViewController.contextLineView`.
@MainActor
public final class ComposerContextStrip: NSView {
    public struct Item: Equatable, Sendable {
        public var symbolName: String
        public var text: String
        public init(symbolName: String, text: String) {
            self.symbolName = symbolName
            self.text = text
        }
    }

    public var items: [Item] = [] { didSet { if items != oldValue { rebuild() } } }
    public var hint: String = "" { didSet { hintLabel.stringValue = hint; updateAccessibility() } }

    private let leading = NSStackView()
    private let hintLabel = NSTextField(labelWithString: "")

    public init(items: [Item] = [], hint: String = "") {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        leading.orientation = .horizontal
        leading.spacing = DS.Space.s12
        leading.alignment = .centerY
        hintLabel.font = DS.TextRole.meta.font
        hintLabel.textColor = DS.Color.text3
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [leading, hintLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DS.Size.composerControl),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: DS.Space.s12),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        self.items = items
        self.hint = hint
        hintLabel.stringValue = hint
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func rebuild() {
        leading.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            icon.contentTintColor = DS.Color.text3
            let label = NSTextField(labelWithString: item.text)
            label.font = DS.TextRole.meta.font
            label.textColor = DS.Color.text3
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let pair = NSStackView(views: [icon, label])
            pair.spacing = DS.Space.s4
            pair.alignment = .centerY
            leading.addArrangedSubview(pair)
        }
        updateAccessibility()
    }

    private func updateAccessibility() {
        setAccessibilityLabel((items.map(\.text) + (hint.isEmpty ? [] : [hint])).joined(separator: ", "))
    }
}
