import AppKit
import BelloCore
import DesignSystem
import Engine

// TEMPORARY transcript for the walking skeleton. Deliberately simple and correct; the real one comes from
// TranscriptKit and is mounted through `ShellSurfaces` (Shell/Seams.swift).

// MARK: - Transcript

/// TEMPORARY: a plain, non-virtualised list of message text. One row per message ID (server identity); a streaming
/// token re-renders only that message's row. Follows the bottom only if the reader was already there.
@MainActor
final class TemporaryTranscriptViewController: NSViewController, FocusableSurface {
    private let context: ThreadSurfaceContext
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No messages yet.")
    private var rows: [MessageID: MessageRowView] = [:]
    private var order: [MessageID] = []
    private var listLoop: ObservationLoop?

    init(context: ThreadSurfaceContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var preferredFocusView: NSView? { scrollView }

    /// Rows currently built (for the switch-time test).
    var renderedMessageCount: Int { order.count }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.l
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.l, left: 0, bottom: DS.Spacing.l, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.setAccessibilityLabel("Transcript")
        emptyLabel.textColor = DS.Palette.tertiaryText
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        let container = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: DS.Spacing.readableWidth),
            stack.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor, constant: -2 * DS.Spacing.xxl),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        let fill = stack.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -2 * DS.Spacing.xxl)
        fill.priority = .defaultHigh
        fill.isActive = true
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        listLoop = ObservationLoop { [weak self] in self?.syncRows() }
    }

    isolated deinit {
        listLoop?.cancel()
    }

    private func syncRows() {
        guard let thread = context.thread else { return }
        let ids = thread.messageIDs
        emptyLabel.isHidden = !(ids.isEmpty && thread.phase == .ready)
        guard ids != order else { return }
        let wasAtBottom = isAtBottom
        let wanted = Set(ids)
        for (id, row) in rows where !wanted.contains(id) {
            row.cancel()
            row.removeFromSuperview()
            rows[id] = nil
        }
        DS.Motion.withoutAnimation {
            for (index, id) in ids.enumerated() {
                let row = rows[id] ?? {
                    let row = MessageRowView(id: id, thread: thread)
                    rows[id] = row
                    return row
                }()
                if index < stack.arrangedSubviews.count, stack.arrangedSubviews[index] === row { continue }
                row.removeFromSuperview()
                stack.insertArrangedSubview(row, at: min(index, stack.arrangedSubviews.count))
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        let firstLoad = order.isEmpty
        order = ids
        if wasAtBottom || firstLoad { scrollToBottom() }
    }

    private var isAtBottom: Bool {
        guard let document = scrollView.documentView else { return true }
        let visible = scrollView.contentView.bounds
        return visible.maxY >= document.bounds.height - 24
    }

    private func scrollToBottom() {
        view.layoutSubtreeIfNeeded()
        guard let document = scrollView.documentView else { return }
        let y = max(0, document.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// One message as selectable text with a role line. Observes only its own `MessageModel` (re-rendered by revision).
@MainActor
private final class MessageRowView: NSView {
    private let role = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private var loop: ObservationLoop?
    private var revision = -1

    init(id: MessageID, thread: ThreadModel) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        role.font = DS.Typography.current.sectionHeader
        role.textColor = DS.Palette.secondaryText
        body.font = DS.Typography.current.body
        body.isSelectable = true
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [role, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.xxs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        loop = ObservationLoop { [weak self, weak thread] in
            guard let self, let model = thread?.message(id) else { return }
            self.render(model.message)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func cancel() { loop?.cancel() }

    private func render(_ message: Message) {
        guard message.revision != revision else { return }
        revision = message.revision
        let (roleText, bodyText) = Self.text(for: message)
        role.stringValue = roleText
        body.stringValue = bodyText
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(roleText)
    }

    /// Plain text for the temporary transcript. Pure.
    static func text(for message: Message) -> (role: String, body: String) {
        switch message.kind {
        case .user(let content):
            let suffix = message.delivery == .sending ? " — sending…" : ""
            return ("You" + suffix, content.text)
        case .assistant(let info):
            var pieces: [String] = []
            for part in message.parts {
                switch part.content {
                case .text(let text): pieces.append(text)
                case .reasoning: pieces.append("[Thinking]")
                case .tool(let call): pieces.append("[\(call.name): \(Self.label(call.status))]")
                case .subagent(let reference): pieces.append("[Sub-agent: \(reference.description ?? reference.call.name)]")
                case .file(let file): pieces.append("[File: \(file.name ?? file.uri)]")
                case .unknown(let type, _): pieces.append("[\(type)]")
                }
            }
            if let error = info.error { pieces.append("Error: \(error.message)") }
            let name = info.agent.map { "Agent (\($0))" } ?? "Agent"
            return (info.isOpen ? "\(name) — working…" : name, pieces.joined(separator: "\n"))
        case .shell(let shell):
            return ("Shell", "$ \(shell.command)\n\(shell.output ?? "")")
        case .turnEnd(let end):
            return ("Turn ended", end.error?.message ?? end.outcome?.rawValue ?? "")
        case .other(let type, _):
            return (type, "")
        }
    }

    private static func label(_ status: ToolStatus) -> String {
        switch status {
        case .streamingInput: "preparing"
        case .running: "running"
        case .completed: "done"
        case .failed: "failed"
        case .unknown(let value): value
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
