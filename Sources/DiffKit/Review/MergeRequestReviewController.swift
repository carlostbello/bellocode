import AppKit
import DesignSystem
import Engine

/// The review screen in the Merge Requests tab (GitLab 2): a 36 pt toolbar (Back, the MR and version, Refresh,
/// Discard Drafts, Submit Review), a message strip, and the CoreText diff of the MR's latest version with its threads
/// inline. Escape returns to the panel. Content stays visible while reloading (rule: never a blank pane).
@MainActor
public final class MergeRequestReviewController: NSViewController, DiffViewControllerDelegate {
    public let model: MergeRequestReviewModel
    public let diff = DiffViewController()
    /// Back to the panel (Escape, the Back button).
    public var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let messageStrip = NSView()
    private lazy var submitButton = DSButton(title: "Submit Review", variant: .primary, size: .small, target: self, action: #selector(submitReview(_:)))
    private lazy var refreshButton = DSButton(icon: "arrow.clockwise", accessibilityTitle: "Refresh Diff", size: .small, target: self, action: #selector(refreshReview(_:)))
    private lazy var discardButton = DSButton(title: "Discard Drafts", variant: .ghost, size: .small, target: self, action: #selector(discardReviewDrafts(_:)))
    private lazy var backButton = DSButton(title: "Merge Requests", variant: .ghost, size: .small, symbolName: "chevron.left", target: self, action: #selector(closeReview(_:)))
    private var loop: ObservationLoop?
    private var shownFilesKey: [String] = []
    private var shownHead: String?

    public init(model: MergeRequestReviewModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { loop?.cancel() }

    public override func loadView() {
        let root = ReviewRootView()
        root.onEscape = { [weak self] in self?.onClose?() }
        titleLabel.font = DS.TextRole.bodyEmph.font
        titleLabel.textColor = DS.Color.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        versionLabel.font = DS.TextRole.meta.font
        versionLabel.textColor = DS.Color.text3
        versionLabel.lineBreakMode = .byTruncatingTail
        versionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titles = NSStackView(views: [titleLabel, versionLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 0
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        refreshButton.toolTip = "Refresh (⌘R in the review)"
        let toolbar = NSStackView(views: [backButton, titles, spacer, refreshButton, discardButton, submitButton])
        toolbar.spacing = DS.Space.s6
        toolbar.alignment = .centerY
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: DS.Space.s8, bottom: 0, right: DS.Space.s8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = DS.TextRole.label.font
        messageLabel.textColor = DS.Color.text2
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageStrip.wantsLayer = true
        messageStrip.translatesAutoresizingMaskIntoConstraints = false
        messageStrip.addSubview(messageLabel)
        let rule = DSDivider()
        rule.translatesAutoresizingMaskIntoConstraints = false
        addChild(diff)
        diff.delegate = self
        diff.emptyText = "Loading the merge request's diff…"
        diff.commentHint = "Saved as a draft; Submit Review sends it."
        diff.commentActionTitle = "Save Draft"
        diff.annotationActions = { [weak self] annotation in self?.model.actions(for: annotation) ?? [] }
        diff.onAnnotationAction = { [weak self] action, annotation in self?.handle(action, annotation) }
        let diffView = diff.view
        diffView.translatesAutoresizingMaskIntoConstraints = false
        for subview in [toolbar, messageStrip, rule, diffView] { root.addSubview(subview) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: DS.Size.toolbar + 6),
            messageStrip.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            messageStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            messageStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            messageLabel.topAnchor.constraint(equalTo: messageStrip.topAnchor, constant: 6),
            messageLabel.bottomAnchor.constraint(equalTo: messageStrip.bottomAnchor, constant: -6),
            messageLabel.leadingAnchor.constraint(equalTo: messageStrip.leadingAnchor, constant: DS.Space.s12),
            messageLabel.trailingAnchor.constraint(equalTo: messageStrip.trailingAnchor, constant: -DS.Space.s12),
            rule.topAnchor.constraint(equalTo: messageStrip.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: DS.Border.hairline),
            diffView.topAnchor.constraint(equalTo: rule.bottomAnchor),
            diffView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            diffView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            diffView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        loop = ObservationLoop { [weak self] in self?.render() }
        if model.state == nil { Task { await model.load() } }
    }

    /// Re-renders from the model; the diff is redisplayed only when the version's files change, and annotations only
    /// when they differ (the diff compares them), so one new draft does not rebuild the history.
    private func render() {
        titleLabel.stringValue = "Review \(model.ref)" + (model.snapshot.map { " · \($0.title)" } ?? "")
        versionLabel.stringValue = model.versionLine
        let plan = model.service.submitPlan(model.ref)
        submitButton.title = model.submitTitle
        submitButton.isEnabled = plan.sendable > 0 && model.writesEnabled && !model.service.busy.contains(model.ref.url)
        submitButton.toolTip = model.writesEnabled ? "Send your drafts (asks first)" : "GitLab write actions are off for this instance (Settings ▸ GitLab)."
        discardButton.isHidden = model.drafts.isEmpty
        var message = model.message
        var isError = model.isError
        if message == nil {
            switch model.phase {
            case .failed(let reason): (message, isError) = (reason + (model.state != nil ? " Showing the last loaded version." : ""), true)
            case .preparing: message = "GitLab is still preparing this merge request's diff. Refresh in a moment."
            default:
                if let moved = model.service.moved[model.ref.url] { (message, isError) = (moved.description, true) } else if !model.writesEnabled {
                    message = "Read only: GitLab write actions are off for this instance. Drafts are kept here until you turn them on (Settings ▸ GitLab)."
                } else if model.elsewhere > 0 {
                    message = "\(model.elsewhere) more thread\(model.elsewhere == 1 ? " is a general comment or on a file" : "s are general comments or on files") not in this version: see the Merge Requests tab."
                }
            }
        }
        messageLabel.stringValue = message ?? ""
        messageLabel.textColor = isError ? DS.Color.dangerText : DS.Color.text2
        messageStrip.isHidden = message == nil
        messageStrip.layer?.backgroundColor = (isError ? DS.Color.dangerSurface : DS.Color.fillSubtle).resolvedCGColor(for: view.effectiveAppearance)
        let files = model.diffFiles
        let key = files.map { $0.path + ":\($0.additions):\($0.deletions)" }
        let head = model.state?.refs.headSHA
        if key != shownFilesKey || head != shownHead {
            let keep = shownHead == head
            shownFilesKey = key
            shownHead = head
            diff.emptyText = model.state == nil ? (model.phase == .loading ? "Loading the merge request's diff…" : "No diff loaded.") : "This version has no changes."
            diff.display(files, keepPosition: keep)
        }
        diff.annotations = model.annotations
    }

    private func handle(_ action: DiffAnnotationAction, _ annotation: DiffAnnotation) {
        switch action.id {
        case "reply":
            diff.showEditor(
                annotationID: annotation.id, title: "Reply to @\(annotation.notes.first?.author ?? "")", hint: "Saved as a draft; Submit Review sends it.",
                actionTitle: "Save Draft") { [weak self] text in Task { await self?.model.reply(to: annotation, text: text) } }
        case "edit":
            diff.showEditor(annotationID: annotation.id, title: "Edit draft", hint: "Not sent until Submit Review or Send Now.", actionTitle: "Save Draft", initial: model.draftText(annotation)) {
                [weak self] text in Task { await self?.model.edit(annotation, text: text) }
            }
        case "discard", "discardReply":
            Task {
                await model.perform(action, on: annotation)
                registerUndo()
            }
        default:
            Task { await model.perform(action, on: annotation) }
        }
    }

    private func registerUndo() {
        guard !model.lastDiscarded.isEmpty else { return }
        view.window?.undoManager?.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated { Task { await controller.model.undoDiscard() } }
        }
        view.window?.undoManager?.setActionName("Discard Draft")
    }

    // MARK: Commands (toolbar, GitLab menu through the window)

    @objc public func submitReview(_ sender: Any?) { Task { await model.submit() } }
    @objc public func refreshReview(_ sender: Any?) { Task { await model.load() } }
    @objc public func closeReview(_ sender: Any?) { onClose?() }
    @objc public func discardReviewDrafts(_ sender: Any?) {
        Task {
            await model.discardAllDrafts()
            registerUndo()
        }
    }

    /// Runs a thread action on the current thread (menu items: Reply, Resolve, Add to Agent Context).
    public func performOnCurrentThread(_ id: String) {
        guard let annotation = diff.currentAnnotation ?? diff.annotations.first else { return NSSound.beep() }
        guard let action = model.actions(for: annotation).first(where: { $0.id == id && $0.isEnabled }) else { return NSSound.beep() }
        diff.reveal(annotation: annotation.id)
        handle(action, annotation)
    }

    public var hasThreads: Bool { !diff.annotations.isEmpty }

    // MARK: DiffViewControllerDelegate

    public func diffViewController(_ controller: DiffViewController, revertHunk hunkIndex: Int, in file: DiffFile) {}

    public func diffViewController(_ controller: DiffViewController, addComment comment: DiffReviewComment) -> Bool {
        Task { await model.comment(comment) }
        return true
    }

    public func diffViewController(_ controller: DiffViewController, open file: DiffFile, line: Int?) {
        if let url = URL(string: model.ref.url + "/diffs") { model.openURL(url) }
    }
}

/// The review's root: Escape goes back unless a field or the diff's find bar handles it first.
@MainActor
final class ReviewRootView: NSView {
    var onEscape: (() -> Void)?
    override var isFlipped: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
