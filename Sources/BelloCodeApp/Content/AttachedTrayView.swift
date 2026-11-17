import AppKit
import DesignSystem

/// The status-unknown banner, sends of unknown delivery and queued follow-ups, in one `raised` card (`DSCard`, the
/// composer's recipe) attached above the request card or the composer, which overlaps its bottom
/// `DS.Size.attachedOverlap` (visual-language.md §6). Rows keep the composer's text inset (14) so their text lines up
/// with the prompt. Collapsed to zero height when no row has content.
@MainActor
final class AttachedTrayView: NSView {
    private let card = DSCard(style: .raised)
    private let column: NSStackView
    private var collapsed: NSLayoutConstraint!

    init(rows: [NSView]) {
        column = NSStackView(views: rows)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.detachesHiddenViews = true
        for view in [card, column] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for row in rows { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        collapsed = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: DS.Space.s4),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(DS.Size.attachedOverlap + DS.Space.s4))
                .withPriority(.defaultHigh),
        ])
        setAccessibilityElement(false)
        render(visible: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func render(visible: Bool) {
        guard isHidden == visible || collapsed.isActive == visible else { return }
        isHidden = !visible
        collapsed.isActive = !visible
    }
}
