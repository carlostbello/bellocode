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
        let icon = ProjectIcon()
        icon.symbolName = prompt.delivery == .steer ? "arrow.turn.down.right" : "text.badge.plus"
        icon.tint = DS.Color.icon
        let label = NSTextField(labelWithString: state)
        label.font = DS.TextRole.labelEmph.font
        label.textColor = DS.Color.text2
        let text = NSTextField(labelWithString: prompt.text.replacingOccurrences(of: "\n", with: " "))
        text.font = DS.TextRole.label.font
        text.textColor = DS.Color.text
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
        row.spacing = DS.Space.s8
        row.alignment = .centerY
        row.heightAnchor.constraint(equalToConstant: DS.Size.control).isActive = true
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.row)
        row.setAccessibilityLabel("\(state): \(prompt.text)")
        if state == "Parked" {
            row.toolTip = "The turn was stopped. This message waits and goes with your next one; Steer Now sends it now."
        }
        return row
    }

    private static func button(_ title: String, symbol: String, target: AnyObject, action: Selector) -> DSButton {
        let button = DSButton(title: title, variant: .ghost, size: .small, symbolName: symbol, target: target, action: action)
        button.isMuted = true
        button.toolTip = title
        return button
    }

    @objc private func steer(_ sender: NSView) {
        guard let raw = sender.identifier?.rawValue else { return }
        Task { await thread.steer(MessageID(raw)) }
    }

    @objc private func remove(_ sender: NSView) {
        guard let raw = sender.identifier?.rawValue else { return }
        Task { await thread.cancelQueued(MessageID(raw)) }
    }
}
