import AppKit
import BelloCore
import DesignSystem
import Engine

/// Follow-ups waiting for the running turn, listed above the composer with their delivery state ("Sending…" until the
/// server acknowledges, then "Queued" or "Steering"), and Steer Now / Remove for each (AGENTS.md UX rule 5). Zero
/// height when the queue is empty. Rows are identified by the queued prompt's server ID.
@MainActor
final class QueuedPromptsView: NSView {
    private let thread: ThreadModel
    private let stack = NSStackView()
    private var collapsed: NSLayoutConstraint!
    private var loop: ObservationLoop?
    private var shown: [QueuedPrompt] = []
    private var shownRunning = false

    init(thread: ThreadModel) {
        self.thread = thread
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.xxs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        collapsed = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.s),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: DS.Spacing.xs),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DS.Spacing.xs).withPriority(.defaultHigh),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Queued follow-ups")
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { loop?.cancel() }

    var rowCount: Int { shown.count }

    private func render() {
        let queue = thread.queue
        let running = thread.isRunning
        guard queue != shown || running != shownRunning else { return }
        shown = queue
        shownRunning = running
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        isHidden = queue.isEmpty
        collapsed.isActive = queue.isEmpty
        for prompt in queue {
            let row = row(for: prompt)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func row(for prompt: QueuedPrompt) -> NSView {
        // After Stop, opencode keeps queued prompts parked until the next message (it does not send them alone).
        let state: String = switch (prompt.state, prompt.delivery, shownRunning) {
        case (.sending, _, _): "Sending…"
        case (.queued, _, false): "Parked"
        case (.queued, .steer, true): "Steering"
        case (.queued, _, true): "Queued"
        }
        let icon = NSImageView(image: NSImage(
            systemSymbolName: prompt.delivery == .steer ? "arrow.turn.down.right" : "text.badge.plus",
            accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = DS.Palette.secondaryText
        let label = NSTextField(labelWithString: state)
        label.font = .systemFont(ofSize: DS.Typography.current.caption.pointSize, weight: .semibold)
        label.textColor = DS.Palette.secondaryText
        let text = NSTextField(labelWithString: prompt.text.replacingOccurrences(of: "\n", with: " "))
        text.font = DS.Typography.current.caption
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow - 10, for: .horizontal)
        let steer = Self.button("Steer Now", symbol: "arrow.turn.down.right", target: self, action: #selector(steer(_:)))
        let remove = Self.button("Remove", symbol: "xmark", target: self, action: #selector(remove(_:)))
        for button in [steer, remove] {
            button.identifier = NSUserInterfaceItemIdentifier(prompt.id.rawValue)
            button.isEnabled = prompt.state == .queued
        }
        steer.isHidden = prompt.delivery == .steer
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [icon, label, text, spacer, steer, remove])
        row.spacing = DS.Spacing.s
        row.alignment = .centerY
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.row)
        row.setAccessibilityLabel("\(state): \(prompt.text)")
        if state == "Parked" {
            row.toolTip = "The turn was stopped. This message waits and goes with your next one; Steer Now sends it now."
        }
        return row
    }

    private static func button(_ title: String, symbol: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.font = DS.Typography.current.caption
        button.contentTintColor = DS.Palette.secondaryText
        button.toolTip = title
        button.controlSize = .small
        return button
    }

    @objc private func steer(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        Task { await thread.steer(MessageID(raw)) }
    }

    @objc private func remove(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        Task { await thread.cancelQueued(MessageID(raw)) }
    }
}
