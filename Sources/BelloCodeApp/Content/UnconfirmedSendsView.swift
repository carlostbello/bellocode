import AppKit
import BelloCore
import DesignSystem
import Engine

/// Sends whose delivery is unknown (every answer from opencode was lost), pinned above the composer until resolved
/// (docs/reviews/M1-review.md, M4). "Retry" asks opencode for the message's ID and resends it under that same ID only
/// if opencode does not have it, so it can never run twice. A retry that opencode refuses shows "Not sent" with "Edit in
/// Composer". There is deliberately no action that sends the text as a new message. Zero height when empty.
@MainActor
final class UnconfirmedSendsView: NSView {
    private let thread: ThreadModel
    /// Puts text into this thread's composer (for a send that is definitely not sent).
    var editInComposer: (String) -> Void = { _ in }
    private let stack = NSStackView()
    private var collapsed: NSLayoutConstraint!
    private var loop: ObservationLoop?
    private var shown: [UnconfirmedSend] = []

    init(thread: ThreadModel) {
        self.thread = thread
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        collapsed = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.s14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.s6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: DS.Space.s2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DS.Space.s2).withPriority(.defaultHigh),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Messages with unknown delivery")
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { loop?.cancel() }

    var rowCount: Int { shown.count }

    private func render() {
        let sends = thread.unconfirmedSends
        guard sends != shown else { return }
        shown = sends
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        isHidden = sends.isEmpty
        collapsed.isActive = sends.isEmpty
        for send in sends {
            let row = row(for: send)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func row(for send: UnconfirmedSend) -> NSView {
        let (state, symbol, detail): (String, String, String) = switch send.state {
        case .unknown:
            ("Delivery unknown", "questionmark.circle",
             "opencode did not confirm it received this. Retry checks first and resends under the same ID, so it cannot run twice.")
        case .checking: ("Checking…", "arrow.triangle.2.circlepath", "Asking opencode whether it has this message.")
        case .notSent(let reason): ("Not sent", "exclamationmark.circle", reason)
        }
        let icon = ProjectIcon()
        icon.symbolName = symbol
        icon.tint = DS.Color.warningText
        let label = NSTextField(labelWithString: state)
        label.font = DS.TextRole.labelEmph.font
        label.textColor = DS.Color.warningText
        let text = NSTextField(labelWithString: send.text.replacingOccurrences(of: "\n", with: " "))
        text.font = DS.TextRole.label.font
        text.textColor = DS.Color.text
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow - 10, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var views: [NSView] = [icon, label, text, spacer]
        switch send.state {
        case .unknown, .checking:
            let retry = Self.button("Retry", target: self, action: #selector(retry(_:)))
            retry.identifier = NSUserInterfaceItemIdentifier(send.id.rawValue)
            retry.isEnabled = send.state == .unknown
            retry.toolTip = "Check with opencode, and resend under the same ID only if it does not have this message"
            views.append(retry)
        case .notSent:
            let edit = Self.button("Edit in Composer", target: self, action: #selector(edit(_:)))
            edit.identifier = NSUserInterfaceItemIdentifier(send.id.rawValue)
            views.append(edit)
        }
        let row = NSStackView(views: views)
        row.spacing = DS.Space.s8
        row.alignment = .centerY
        row.heightAnchor.constraint(equalToConstant: DS.Size.control).isActive = true
        row.toolTip = detail
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.row)
        row.setAccessibilityLabel("\(state): \(send.text). \(detail)")
        return row
    }

    private static func button(_ title: String, target: AnyObject, action: Selector) -> DSButton {
        DSButton(title: title, variant: .outline, size: .small, target: target, action: action)
    }

    @objc private func retry(_ sender: NSView) {
        guard let raw = sender.identifier?.rawValue else { return }
        let thread = thread
        Task { await thread.retryUnconfirmed(MessageID(raw)) }
    }

    @objc private func edit(_ sender: NSView) {
        guard let raw = sender.identifier?.rawValue else { return }
        let thread = thread
        Task { [weak self] in
            guard let text = await thread.takeUnconfirmed(MessageID(raw)) else { return }
            self?.editInComposer(text)
        }
    }
}
