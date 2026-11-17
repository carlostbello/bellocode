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
    private(set) var queuedPrompts: QueuedPromptsView?
    private(set) var unconfirmedSends: UnconfirmedSendsView?
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
        view = NSView()
        view.setAccessibilityLabel("Thread")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loop = ObservationLoop { [weak self] in self?.update() }
    }

    isolated deinit { loop?.cancel() }

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
            newContent.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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
        queuedPrompts = nil
        unconfirmedSends = nil
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
        let header = makeHeader(context)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let transcript = surfaces.transcript(context)
        self.transcript = transcript
        let transcriptView = adopt(transcript)
        let requestStack = surfaces.requestStack(context)
        self.requestStack = requestStack
        let requests = adopt(requestStack)
        let composer = surfaces.composer(context)
        self.composer = composer
        let composerView = adopt(composer)
        let banner: NSView
        if let thread = context.thread {
            let unknown = StatusUnknownBanner(thread: thread, engine: workspace.engine)
            statusBanner = unknown
            let queued = QueuedPromptsView(thread: thread)
            queuedPrompts = queued
            let unconfirmed = UnconfirmedSendsView(thread: thread)
            unconfirmed.editInComposer = { [weak self] text in self?.composerSurface?.insertText(text) }
            unconfirmedSends = unconfirmed
            let column = NSStackView(views: [unknown, unconfirmed, queued])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 0
            column.detachesHiddenViews = true
            column.translatesAutoresizingMaskIntoConstraints = false
            for view in [unknown, unconfirmed, queued] { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
            banner = column
        } else {
            banner = NSView()
            banner.translatesAutoresizingMaskIntoConstraints = false
            banner.heightAnchor.constraint(equalToConstant: 0).isActive = true
        }
        for subview in [header, separator, transcriptView, requests, banner, composerView] { container.addSubview(subview) }
        let column = DS.Spacing.readableWidth
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // Full width: the transcript centres its own text column (TranscriptKit), so its scroller sits at the edge.
            transcriptView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            transcriptView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            transcriptView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            requests.topAnchor.constraint(equalTo: transcriptView.bottomAnchor, constant: DS.Spacing.s),
            banner.topAnchor.constraint(equalTo: requests.bottomAnchor),
            composerView.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: DS.Spacing.s),
            composerView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -DS.Spacing.m),
        ])
        for docked in [requests, banner, composerView] {
            let width = docked.widthAnchor.constraint(equalToConstant: column)
            width.priority = Self.columnPreference
            NSLayoutConstraint.activate([
                docked.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                docked.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -2 * DS.Spacing.columnMargin),
                width,
            ])
        }
        return container
    }

    private func makeDraft(_ context: ThreadSurfaceContext) -> NSView {
        let container = NSView()
        let header = makeHeader(context)
        let heading = NSTextField(labelWithString: "What should we work on in \(context.projectName)?")
        heading.font = .systemFont(ofSize: DS.Typography.current.baseSize + 9, weight: .semibold)
        heading.alignment = .center
        heading.lineBreakMode = .byTruncatingTail
        heading.translatesAutoresizingMaskIntoConstraints = false
        // The header and the composer's context line already show where the agent acts; no third path here.
        let path = NSTextField(labelWithString: "Free built-in models work without signing in. Choose another with ⇧⌘M.")
        path.font = DS.Typography.current.caption
        path.textColor = DS.Palette.secondaryText
        path.alignment = .center
        path.translatesAutoresizingMaskIntoConstraints = false
        let composer = surfaces.composer(context)
        self.composer = composer
        let composerView = adopt(composer)
        for subview in [header, heading, path, composerView] { container.addSubview(subview) }
        let width = composerView.widthAnchor.constraint(equalToConstant: DS.Spacing.readableWidth)
        width.priority = Self.columnPreference
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            heading.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            heading.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -2 * DS.Spacing.xl),
            path.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: DS.Spacing.xs),
            path.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            composerView.topAnchor.constraint(equalTo: path.bottomAnchor, constant: DS.Spacing.xl),
            composerView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            composerView.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: DS.Spacing.xl),
            composerView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -2 * DS.Spacing.columnMargin),
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
