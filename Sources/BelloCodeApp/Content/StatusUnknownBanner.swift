import AppKit
import BelloCore
import DesignSystem
import Engine

/// Shown above the composer when opencode restarted while this thread's turn ran: the server still lists it as busy
/// but nothing runs it. BelloCode does not act on its own; the user chooses Stop (mark it interrupted) or Resume
/// (mark it interrupted and ask the agent to continue). Offline, the sidebar footer's connection state explains instead.
@MainActor
final class StatusUnknownBanner: NSView {
    private let thread: ThreadModel
    private let engine: Engine
    private let message = NSTextField(wrappingLabelWithString: "")
    private let stopButton = DSButton(title: "Stop", variant: .outline, size: .small)
    private let resumeButton = DSButton(title: "Resume", variant: .primary, size: .small)
    private var collapsed: NSLayoutConstraint!
    private var loop: ObservationLoop?
    private var busy = false

    init(thread: ThreadModel, engine: Engine) {
        self.thread = thread
        self.engine = engine
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        let glyph = DSStatusGlyphView()
        glyph.status = .unknown
        glyph.pointSize = DS.Size.iconPoint
        glyph.setAccessibilityElement(false)
        message.font = DS.TextRole.body.font
        message.textColor = DS.Color.text
        message.stringValue = "Status unknown: opencode restarted while this thread was running, and nothing is running it now."
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stopButton.target = self
        stopButton.action = #selector(stop)
        stopButton.toolTip = "Mark the turn as stopped (⌘.)"
        resumeButton.target = self
        resumeButton.action = #selector(resume)
        resumeButton.toolTip = "Mark it stopped and ask the agent to continue where it left off"
        let row = NSStackView(views: [glyph, message, stopButton, resumeButton])
        row.alignment = .centerY
        row.spacing = DS.Space.s8
        row.setCustomSpacing(DS.Space.s10, after: glyph)
        row.edgeInsets = NSEdgeInsets(top: DS.Space.s10, left: DS.Space.s14, bottom: DS.Space.s10, right: DS.Space.s10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        collapsed = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor).withPriority(.defaultHigh),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Status unknown")
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { loop?.cancel() }

    /// Visible: connected, and the thread's status is unknown.
    var isShowing: Bool { thread.isStatusUnknown && engine.root.connection == .live }

    private func render() {
        let show = isShowing
        isHidden = !show
        collapsed.isActive = !show
        stopButton.isEnabled = !busy
        resumeButton.isEnabled = !busy
        if show { setAccessibilityLabel("Status unknown. \(message.stringValue)") }
    }

    override var wantsUpdateLayer: Bool { true }

    /// A `raised` card (`r.xl`) with the composer's outline, like the request cards it sits with.
    override func updateLayer() {
        layer?.cornerRadius = DS.Radius.xl
        layer?.cornerCurve = .continuous
        layer?.borderWidth = DS.Border.hairline
        layer?.backgroundColor = DS.Color.raised.cgColor
        layer?.borderColor = DS.Color.composerOutline.cgColor
    }

    @objc func stop() {
        run { await $0.settleUnknownStatus() }
    }

    @objc func resume() {
        run { _ = await $0.resumeAfterRestart() }
    }

    private func run(_ body: @escaping @MainActor (ThreadModel) async -> Void) {
        busy = true
        render()
        let thread = thread
        Task { [weak self] in
            await body(thread)
            self?.busy = false
            self?.render()
        }
    }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
