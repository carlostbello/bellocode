import AppKit
import BelloCore
import DesignSystem
import Engine

// TEMPORARY surfaces for the walking skeleton. They are deliberately simple and correct; the real ones come from
// TranscriptKit, AgentUI and ComposerKit and are mounted through `ShellSurfaces` (Shell/Seams.swift).

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

// MARK: - Request stack

/// TEMPORARY: pending approvals and questions pinned above the composer, so a blocked agent is never hidden. Allow
/// once / Always / Deny for permissions; questions can be dismissed here and answered in AgentUI later.
@MainActor
final class TemporaryRequestStackViewController: NSViewController {
    private let context: ThreadSurfaceContext
    private let stack = NSStackView()
    private var loop: ObservationLoop?
    private var shownIDs: [String] = []
    private var shownSubmitting: Set<String> = []

    init(context: ThreadSurfaceContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.s
        stack.setAccessibilityLabel("Pending requests")
        view = stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    isolated deinit { loop?.cancel() }

    private func render() {
        guard let thread = context.thread else {
            stack.isHidden = true
            return
        }
        let requests = thread.pendingRequests
        let ids = requests.map(\.id)
        let submitting = thread.submittingRequestIDs
        guard ids != shownIDs || submitting != shownSubmitting else { return }
        shownIDs = ids
        shownSubmitting = submitting
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        stack.isHidden = requests.isEmpty
        for request in requests {
            let card = RequestCard(request: request, isSubmitting: submitting.contains(request.id), thread: thread)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

@MainActor
private final class RequestCard: NSView {
    private weak var thread: ThreadModel?
    private let request: PendingRequest

    init(request: PendingRequest, isSubmitting: Bool, thread: ThreadModel) {
        self.request = request
        self.thread = thread
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.medium
        layer?.borderWidth = 1
        let glyph: StatusGlyph
        let summary: String
        var buttons: [NSButton] = []
        switch request {
        case .permission(let permission):
            glyph = StatusGlyph(.awaitingApproval)
            let target = permission.resources.prefix(3).joined(separator: ", ")
            summary = "Allow \(permission.action)\(target.isEmpty ? "" : ": \(target)")?"
            buttons = [
                Self.button("Deny", self, #selector(deny)),
                Self.button("Always Allow", self, #selector(always)),
                Self.button("Allow Once", self, #selector(allowOnce), isDefault: true),
            ]
        case .question(let question):
            glyph = StatusGlyph(.awaitingAnswer)
            summary = question.title
            buttons = [Self.button("Dismiss", self, #selector(dismiss))]
        }
        for button in buttons { button.isEnabled = !isSubmitting }
        let icon = NSImageView(image: glyph.image(pointSize: 13) ?? NSImage())
        let title = NSTextField(labelWithString: glyph.label)
        title.font = DS.Typography.current.bodyEmphasized
        let detail = NSTextField(wrappingLabelWithString: isSubmitting ? "\(summary) — sending reply…" : summary)
        detail.font = DS.Typography.current.body
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = DS.Spacing.xxs
        let buttonRow = NSStackView(views: buttons)
        buttonRow.spacing = DS.Spacing.s
        buttonRow.setContentHuggingPriority(.required, for: .horizontal)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [icon, text, spacer, buttonRow])
        row.alignment = .centerY
        row.spacing = DS.Spacing.m
        row.edgeInsets = NSEdgeInsets(top: DS.Spacing.m, left: DS.Spacing.l, bottom: DS.Spacing.m, right: DS.Spacing.m)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(glyph.label): \(summary)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = DS.Palette.attention.withAlphaComponent(0.08).cgColor
        layer?.borderColor = DS.Palette.attention.withAlphaComponent(0.45).cgColor
    }

    private static func button(_ title: String, _ target: AnyObject, _ action: Selector, isDefault: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.controlSize = .small
        button.bezelStyle = .push
        if isDefault { button.bezelColor = DS.Palette.accent }
        return button
    }

    @objc private func allowOnce() { reply(.once) }
    @objc private func always() { reply(.always) }
    @objc private func deny() { reply(.reject) }

    private func reply(_ reply: PermissionReply) {
        guard case .permission(let permission) = request, let thread else { return }
        Task { await thread.reply(to: permission.id, reply) }
    }

    @objc private func dismiss() {
        guard case .question(let question) = request, let thread else { return }
        Task { await thread.dismiss(question.id) }
    }
}

// MARK: - Composer

/// TEMPORARY: a native NSTextView composer. Return sends (Shift-Return, Option-Return: newline; IME composition is
/// never interrupted), Escape or the Stop button stops a running turn; while running, Return queues a follow-up
/// ("Queue" is labelled). Nothing is shown as delivered before the server acknowledges it.
@MainActor
final class TemporaryComposerViewController: NSViewController, NSTextViewDelegate, ComposerSurface {
    private let context: ThreadSurfaceContext
    private let textView = ComposerTextView()
    private let scrollView = NSScrollView()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var heightConstraint: NSLayoutConstraint!
    private var loop: ObservationLoop?
    private var isApplyingDraft = false

    init(context: ThreadSurfaceContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var preferredFocusView: NSView? { textView }
    var hasSendableText: Bool { !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    override func loadView() {
        let typography = DS.Typography.current
        textView.font = typography.body
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: DS.Spacing.xs)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel("Message")
        textView.onSubmit = { [weak self] in self?.performSend() }
        textView.onEscape = { [weak self] in self?.stopIfRunning() ?? false }
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        sendButton.bezelStyle = .push
        sendButton.controlSize = .regular
        sendButton.bezelColor = DS.Palette.accent
        sendButton.toolTip = "Send (Return). Shift-Return inserts a newline."
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.bezelStyle = .push
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        stopButton.imagePosition = .imageLeading
        stopButton.toolTip = "Stop the running turn (Escape or ⌘.)"
        hint.font = typography.caption
        hint.textColor = DS.Palette.tertiaryText
        errorLabel.font = typography.caption
        errorLabel.textColor = DS.Palette.failure
        errorLabel.isHidden = true

        let buttons = NSStackView(views: [hint, NSView(), stopButton, sendButton])
        buttons.spacing = DS.Spacing.s
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let box = ComposerBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scrollView)
        box.addSubview(buttons)
        let container = NSStackView(views: [errorLabel, box])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = DS.Spacing.xs
        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 22)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalTo: container.widthAnchor),
            scrollView.topAnchor.constraint(equalTo: box.topAnchor, constant: DS.Spacing.m),
            scrollView.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: DS.Spacing.l),
            scrollView.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -DS.Spacing.l),
            heightConstraint,
            buttons.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: DS.Spacing.xs),
            buttons.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: DS.Spacing.l),
            buttons.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -DS.Spacing.m),
            buttons.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -DS.Spacing.m),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyDraft(context.draft)
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    isolated deinit { loop?.cancel() }

    private func render() {
        let running = context.isRunning
        stopButton.isHidden = !running
        stopButton.title = context.isStopping ? "Stopping…" : "Stop"
        stopButton.isEnabled = !context.isStopping
        sendButton.title = running ? "Queue" : "Send"
        sendButton.isEnabled = !context.isCreatingThread
        hint.stringValue = running ? "Return queues a follow-up" : (context.isDraft ? "Return sends · creates the thread" : "Return sends · Shift-Return newline")
        if let error = context.visibleError {
            errorLabel.stringValue = error
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }
        textView.placeholder = context.isDraft ? "Ask the agent to work in \(context.projectName)…" : "Message…"
        // The engine restores the draft after a failed send; reflect it if the field is empty.
        if context.visibleError != nil, let thread = context.thread, textView.string.isEmpty, !thread.draft.isEmpty,
            !textView.hasMarkedText()
        {
            applyDraft(thread.draft)
        }
    }

    private func applyDraft(_ text: String) {
        isApplyingDraft = true
        textView.string = text
        isApplyingDraft = false
        updateHeight()
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingDraft else { return }
        context.clearError()
        context.draft = textView.string
        updateHeight()
    }

    private func updateHeight() {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: textView.font ?? DS.Typography.current.body)
        let used = layout.usedRect(for: container).height + 2 * textView.textContainerInset.height
        let height = min(max(used, lineHeight + 2 * textView.textContainerInset.height), lineHeight * 8 + 2 * textView.textContainerInset.height)
        if abs(heightConstraint.constant - height) > 0.5 { heightConstraint.constant = height }
    }

    func performSend() {
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        applyDraft("")
        context.draft = ""
        Task { [context] in _ = await context.send(text) }
    }

    @objc private func sendClicked() { performSend() }
    @objc private func stopClicked() { _ = stopIfRunning() }

    private func stopIfRunning() -> Bool {
        guard context.isRunning else { return false }
        Task { [context] in await context.stop() }
        return true
    }
}

/// The composer's text view: Return submits unless Shift/Option is held or IME composition is active.
@MainActor
final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Bool)?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)), !hasMarkedText() {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if !flags.contains(.shift), !flags.contains(.option) {
                onSubmit?()
                return
            }
            insertNewlineIgnoringFieldEditor(nil)
            return
        }
        if selector == #selector(cancelOperation(_:)), !hasMarkedText(), onEscape?() == true { return }
        super.doCommand(by: selector)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? DS.Typography.current.body, .foregroundColor: DS.Palette.tertiaryText,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

/// The rounded composer background.
@MainActor
private final class ComposerBox: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.large
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = DS.Palette.contentBackground.cgColor
        layer?.borderColor = DS.Palette.separator.cgColor
    }
}
