import AppKit
import BelloCore
import DesignSystem
import Engine

/// The content region: shows the selected thread (header, transcript, request stack, docked composer), a new-thread
/// draft (header and a centred "hero" composer), or an empty state (no projects / nothing selected).
///
/// Switching is synchronous from cached state: the thread model is already open (or opens from the cache in
/// milliseconds) and the surfaces render whatever it holds, so the pane is never blank while loading.
@MainActor
final class ThreadContainerViewController: NSViewController {
    private let workspace: WorkspaceController
    private let surfaces: ShellSurfaces
    private var loop: ObservationLoop?
    private(set) var displayed: ShellSelection?
    private(set) var context: ThreadSurfaceContext?
    private(set) var header: ThreadHeaderView?
    private(set) var transcript: NSViewController?
    private(set) var composer: NSViewController?
    private(set) var requestStack: NSViewController?
    private(set) var statusBanner: StatusUnknownBanner?
    /// Commands cannot run in this project's container (M6-A, docs/features/containers.md).
    private(set) var environmentBanner: EnvironmentBannerHost?
    private(set) var queuedPrompts: QueuedPromptsView?
    private(set) var unconfirmedSends: UnconfirmedSendsView?
    /// Status-unknown, delivery-unknown and queued rows in one `raised` tray attached above the card and composer.
    private(set) var attachedTray: AttachedTrayView?
    private var attachment: (trayToRequests: NSLayoutConstraint, requestsToComposer: NSLayoutConstraint)?
    private var attachmentLoop: ObservationLoop?
    private var surfaceControllers: [NSViewController] = []
    private var content: NSView?
    private var viewedMark: (SessionID, Timestamp)?
    /// Called when the displayed selection changed (window title, focus).
    var onDisplay: ((ThreadSurfaceContext?) -> Void)?

    /// The content column's preferred width: above the controls' hugging (250) so the composer and cards fill the
    /// column, below the side panels' holding priority (270) so it never moves a divider; it takes `readableWidth`
    /// when the window has room and shrinks with it otherwise.
    static let columnPreference = NSLayoutConstraint.Priority(255)

    init(workspace: WorkspaceController, surfaces: ShellSurfaces) {
        self.workspace = workspace
        self.surfaces = surfaces
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = PanelBackgroundView()
        view.setAccessibilityLabel("Thread")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loop = ObservationLoop { [weak self] in self?.update() }
    }

    isolated deinit {
        loop?.cancel()
        attachmentLoop?.cancel()
    }

    /// Reads the selection (observed) and rebuilds only when it changed; marks a finished thread viewed once shown.
    private func update() {
        let selection = workspace.selection
        let hasProjects = !workspace.engine.root.projects.isEmpty
        let key = DisplayKey(selection: selection, hasProjects: hasProjects, draftProjectKnown: draftProjectKnown(selection))
        if key != lastKey {
            lastKey = key
            display(selection, hasProjects: hasProjects)
        }
        markViewedIfNeeded()
    }

    private struct DisplayKey: Equatable {
        var selection: ShellSelection?
        var hasProjects: Bool
        var draftProjectKnown: Bool
    }

    private var lastKey: DisplayKey?

    private func draftProjectKnown(_ selection: ShellSelection?) -> Bool {
        if case .draft(let directory) = selection { return workspace.projectItem(directory: directory) != nil }
        return true
    }

    /// Builds the view for a selection. Public for the switch-time test.
    func display(_ selection: ShellSelection?, hasProjects: Bool) {
        let signpost = ShellSignposts.content.beginInterval("displayThread")
        defer { ShellSignposts.content.endInterval("displayThread", signpost) }
        tearDown()
        displayed = selection
        let newContent: NSView
        if let selection, let context = workspace.makeContext(for: selection) {
            self.context = context
            newContent = context.isDraft ? makeDraft(context) : makeThread(context)
        } else if !hasProjects {
            newContent = EmptyStateView(
                symbolName: "folder.badge.plus", title: "Add a Project",
                detail: "Choose a folder to work in. BelloCode starts threads there with the bundled opencode.",
                actionTitle: "Add Project…", action: #selector(MainWindowController.addProject(_:)))
        } else {
            newContent = EmptyStateView(
                symbolName: "bubble.left.and.text.bubble.right", title: "No Thread Selected",
                detail: "Select a thread in the sidebar, or start a new one.", actionTitle: "New Thread",
                action: #selector(MainWindowController.newThread(_:)))
        }
        newContent.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newContent)
        NSLayoutConstraint.activate([
            // The window's header bar (52 pt) sits over the top edge and shows this content's title and crumbs.
            newContent.topAnchor.constraint(equalTo: view.topAnchor, constant: DS.Size.header),
            newContent.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            newContent.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            newContent.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        content = newContent
        onDisplay?(context)
    }

    private func tearDown() {
        for child in surfaceControllers { child.removeFromParent() }
        surfaceControllers.removeAll()
        content?.removeFromSuperview()
        content = nil
        context = nil
        header = nil
        transcript = nil
        composer = nil
        requestStack = nil
        statusBanner = nil
        environmentBanner = nil
        queuedPrompts = nil
        unconfirmedSends = nil
        attachedTray = nil
        attachment = nil
        attachmentLoop?.cancel()
        attachmentLoop = nil
    }

    private func adopt(_ controller: NSViewController) -> NSView {
        addChild(controller)
        surfaceControllers.append(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        return controller.view
    }

    private func makeHeader(_ context: ThreadSurfaceContext) -> ThreadHeaderView {
        let header = ThreadHeaderView(context: context) { [weak self] id, title in self?.workspace.rename(id, to: title) }
        header.translatesAutoresizingMaskIntoConstraints = false
        self.header = header
        return header
    }

    private func makeThread(_ context: ThreadSurfaceContext) -> NSView {
        let container = NSView()
        _ = makeHeader(context)
        let transcript = surfaces.transcript(context)
        self.transcript = transcript
        let transcriptView = adopt(transcript)
        let requestStack = surfaces.requestStack(context)
        self.requestStack = requestStack
        let requests = adopt(requestStack)
        let composer = surfaces.composer(context)
        self.composer = composer
        let composerView = adopt(composer)
        let environmentView: NSView
        let tray: NSView
        if let thread = context.thread {
            let unknown = StatusUnknownBanner(thread: thread, engine: workspace.engine)
            statusBanner = unknown
            let queued = QueuedPromptsView(thread: thread)
            queuedPrompts = queued
            let unconfirmed = UnconfirmedSendsView(thread: thread)
            unconfirmed.editInComposer = { [weak self] text in self?.composerSurface?.insertText(text) }
            unconfirmedSends = unconfirmed
            let directory = context.directory
            let environment = EnvironmentBannerHost(engine: workspace.engine, directory: { directory })
            environmentBanner = environment
            environmentView = environment
            let attached = AttachedTrayView(rows: [unknown, unconfirmed, queued])
            attachedTray = attached
            tray = attached
        } else {
            environmentView = Self.collapsedSpacer()
            tray = Self.collapsedSpacer()
        }
        // Back to front: the tray, the request card, the composer. Each overlaps the next by `attachedOverlap`, so the
        // composer covers the card's bottom edge and the card (or composer) covers the tray's: one object (§6).
        for subview in [transcriptView, environmentView, tray, requests, composerView] { container.addSubview(subview) }
        let trayToRequests = requests.topAnchor.constraint(equalTo: tray.bottomAnchor)
        let requestsToComposer = composerView.topAnchor.constraint(equalTo: requests.bottomAnchor)
        attachment = (trayToRequests, requestsToComposer)
        let column = DS.Size.contentMaxWidth
        NSLayoutConstraint.activate([
            // Full width: the transcript centres its own text column (TranscriptKit), so its scroller sits at the edge.
            transcriptView.topAnchor.constraint(equalTo: container.topAnchor),
            transcriptView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            transcriptView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            environmentView.topAnchor.constraint(equalTo: transcriptView.bottomAnchor, constant: DS.Space.s8),
            tray.topAnchor.constraint(equalTo: environmentView.bottomAnchor),
            trayToRequests,
            requestsToComposer,
            composerView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -DS.Space.s8),
        ])
        for docked in [environmentView, tray, requests, composerView] {
            let width = docked.widthAnchor.constraint(equalToConstant: column)
            width.priority = Self.columnPreference
            NSLayoutConstraint.activate([
                docked.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                docked.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -2 * DS.Size.gutter),
                width,
            ])
        }
        attachmentLoop = ObservationLoop { [weak self] in self?.updateAttachment() }
        return container
    }

    private static func collapsedSpacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 0).isActive = true
        return view
    }

    /// Overlaps whatever is shown: the tray onto the card (or the composer), the card onto the composer. Constants
    /// only, so a request arriving moves nothing but the column above the composer (no animation, rule 17).
    private func updateAttachment() {
        guard let (trayToRequests, requestsToComposer) = attachment else { return }
        let overlap = DS.Size.attachedOverlap
        let hasRequests = requestStackController?.hasRequests ?? false
        // Observed reads: the same state the tray's rows show themselves for.
        let hasTray: Bool = if let thread = context?.thread {
            !thread.queue.isEmpty || !thread.unconfirmedSends.isEmpty || (statusBanner?.isShowing ?? false)
        } else { false }
        attachedTray?.render(visible: hasTray)
        trayToRequests.constant = hasTray ? -overlap : 0
        requestsToComposer.constant = hasRequests ? -overlap : 0
    }

    private func makeDraft(_ context: ThreadSurfaceContext) -> NSView {
        let container = NSView()
        _ = makeHeader(context)
        let heading = NSTextField(labelWithString: "What should we work on in \(context.projectName)?")
        heading.font = .systemFont(ofSize: DS.Typography.current.baseSize + 7, weight: .semibold)
        heading.textColor = DS.Color.text
        heading.alignment = .center
        heading.lineBreakMode = .byTruncatingTail
        heading.translatesAutoresizingMaskIntoConstraints = false
        // The header and the composer's context line already show where the agent acts; no third path here.
        let path = NSTextField(labelWithString: "Free built-in models work without signing in. Choose another with ⇧⌘M.")
        path.font = DS.TextRole.label.font
        path.textColor = DS.Color.text3
        path.alignment = .center
        path.translatesAutoresizingMaskIntoConstraints = false
        let composer = surfaces.composer(context)
        self.composer = composer
        let composerView = adopt(composer)
        for subview in [heading, path, composerView] { container.addSubview(subview) }
        let width = composerView.widthAnchor.constraint(equalToConstant: DS.Size.contentMaxWidth)
        width.priority = Self.columnPreference
        NSLayoutConstraint.activate([
            heading.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            heading.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -2 * DS.Space.s16),
            path.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: DS.Space.s4),
            path.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            composerView.topAnchor.constraint(equalTo: path.bottomAnchor, constant: DS.Space.s16),
            composerView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            composerView.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: DS.Space.s16),
            composerView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -2 * DS.Size.gutter),
            width,
        ])
        return container
    }

    /// A finished, unread thread counts as seen once it is on screen in the key window (approvals stay until
    /// answered; the engine only clears "finished unread").
    private func markViewedIfNeeded() {
        guard let thread = context?.thread, let status = thread.status, status.status == .finishedUnread,
            view.window?.isKeyWindow ?? false
        else { return }
        if let mark = viewedMark, mark.0 == thread.sessionID, mark.1 == status.since { return }
        viewedMark = (thread.sessionID, status.since)
        Task { await thread.markViewed() }
    }

    /// Re-checks "viewed" when the window becomes key.
    func windowDidBecomeKey() { markViewedIfNeeded() }

    // MARK: - Focus

    var composerFocusView: NSView? {
        (composer as? any FocusableSurface)?.preferredFocusView ?? composer?.view
    }

    var transcriptFocusView: NSView? {
        (transcript as? any FocusableSurface)?.preferredFocusView ?? transcript?.view
    }

    /// The mounted transcript (menu commands forward to it when it is not the first responder).
    var transcriptSurface: TranscriptSurfaceController? { transcript as? TranscriptSurfaceController }

    var composerSurface: (any ComposerSurface)? { composer as? any ComposerSurface }

    /// The real composer, when mounted (menu commands forward to it).
    var composerController: ComposerSurfaceController? { composer as? ComposerSurfaceController }

    /// The displayed thread's request stack (menu commands act on its front request).
    var requestStackController: RequestStackSurfaceController? { requestStack as? RequestStackSurfaceController }

    var requestFocusView: NSView? { (requestStack as? any FocusableSurface)?.preferredFocusView }
}
