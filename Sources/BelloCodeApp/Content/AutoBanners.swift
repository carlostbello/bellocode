import AppKit
import BelloCore
import DesignSystem
import Engine

/// A row of the attached tray (`AttachedTrayView`): another thread's agent stopped this one (docs/features/auto-mode.md).
/// Names who and why, and offers Resume (⌃⌘P, Thread ▸ Resume Interrupted Thread); queued work waits until then.
@MainActor
final class InterruptedBanner: NSView {
    private let thread: ThreadModel
    private let message = NSTextField(wrappingLabelWithString: "")
    private let openButton = DSButton(title: "Open Thread", variant: .ghost, size: .small)
    private let resumeButton = DSButton(title: "Resume", variant: .primary, size: .small)
    private var collapsed: NSLayoutConstraint!
    private var loop: ObservationLoop?
    private var busy = false
    var openThread: ((SessionID) -> Void)?

    init(thread: ThreadModel) {
        self.thread = thread
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let glyph = NSImageView(image: NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil) ?? NSImage())
        glyph.contentTintColor = DS.Color.icon
        glyph.setAccessibilityElement(false)
        message.font = DS.TextRole.body.font
        message.textColor = DS.Color.text
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        openButton.target = self
        openButton.action = #selector(open)
        openButton.toolTip = "Open the thread that stopped this one"
        resumeButton.target = self
        resumeButton.action = #selector(resume)
        resumeButton.toolTip = "Continue the interrupted work and deliver the held queue (⌃⌘P). Side effects already made stay."
        let row = NSStackView(views: [glyph, message, openButton, resumeButton])
        row.alignment = .centerY
        row.spacing = DS.Space.s8
        row.setCustomSpacing(DS.Space.s10, after: glyph)
        row.edgeInsets = NSEdgeInsets(top: DS.Space.s6, left: DS.Space.s14, bottom: DS.Space.s6, right: DS.Space.s8)
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
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { loop?.cancel() }

    var isShowing: Bool { thread.heldInterrupt != nil }

    private func render() {
        let record = thread.heldInterrupt
        isHidden = record == nil
        collapsed.isActive = record == nil
        guard let record else { return }
        message.stringValue = record.summary + ". Its queued work is held until you resume."
        resumeButton.isEnabled = !busy
        setAccessibilityLabel("Interrupted. \(message.stringValue)")
    }

    @objc func open() {
        guard let record = thread.heldInterrupt else { return }
        openThread?(SessionID(record.by))
    }

    @objc func resume() {
        busy = true
        render()
        Task { [weak self, thread] in
            _ = await thread.resumeAfterInterrupt()
            self?.busy = false
            self?.render()
        }
    }
}

/// A row of the attached tray: Full-access risk notices in this thread that the person has not reviewed. Not a
/// blocking approval (nothing waits on it); the notices themselves sit under their tool calls in the transcript.
@MainActor
final class RiskNoticeBanner: NSView {
    private let thread: ThreadModel
    private let auto: AutoModeService
    private let message = NSTextField(wrappingLabelWithString: "")
    private let auditButton = DSButton(title: "Audit Log", variant: .ghost, size: .small)
    private let reviewedButton = DSButton(title: "Mark Reviewed", variant: .outline, size: .small)
    private var collapsed: NSLayoutConstraint!
    private var loop: ObservationLoop?
    var showAudit: (() -> Void)?

    init(thread: ThreadModel, auto: AutoModeService) {
        self.thread = thread
        self.auto = auto
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let glyph = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage())
        glyph.contentTintColor = DS.Color.warningText
        glyph.setAccessibilityElement(false)
        message.font = DS.TextRole.body.font
        message.textColor = DS.Color.text
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        auditButton.target = self
        auditButton.action = #selector(audit)
        auditButton.toolTip = "Show this thread's Auto audit log (⌃⌘J)"
        reviewedButton.target = self
        reviewedButton.action = #selector(reviewed)
        reviewedButton.toolTip = "Remove these notices from Needs You (they stay in the transcript and the audit log)"
        let row = NSStackView(views: [glyph, message, auditButton, reviewedButton])
        row.alignment = .centerY
        row.spacing = DS.Space.s8
        row.setCustomSpacing(DS.Space.s10, after: glyph)
        row.edgeInsets = NSEdgeInsets(top: DS.Space.s6, left: DS.Space.s14, bottom: DS.Space.s6, right: DS.Space.s8)
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
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { loop?.cancel() }

    var isShowing: Bool { thread.session.map { auto.noticeCount($0.id) > 0 } ?? false }

    private func render() {
        let notices = thread.session.flatMap { auto.unreviewed[$0.id] } ?? []
        isHidden = notices.isEmpty
        collapsed.isActive = notices.isEmpty
        guard let last = notices.last else { return }
        let count = notices.count == 1 ? "1 risk notice" : "\(notices.count) risk notices"
        message.stringValue = "\(count) to review (not blocking): \(last.finding.noticeText)"
        setAccessibilityLabel(message.stringValue)
    }

    @objc func audit() { showAudit?() }

    @objc func reviewed() {
        guard let id = thread.session?.id else { return }
        auto.markReviewed(id)
    }
}
