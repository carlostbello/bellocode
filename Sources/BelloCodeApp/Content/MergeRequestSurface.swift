import AppKit
import BelloCore
import DiffKit
import Engine
import OrchestrationUI
import SwiftUI

/// The window's "Merge Requests" right-panel tab (M3-B, docs/features/orchestration-extras.md), following the displayed
/// thread. Created by `ShellSurfaces.builtIn` (Seams.swift) and bound by `MainWindowController`.
@MainActor
final class MergeRequestSurfaces {
    private(set) var model: MergeRequestPanelModel?
    private let host = NSViewController()
    private(set) var context: ThreadSurfaceContext?
    var showPanel: () -> Void = {}
    /// GitLab 2: the inline review shown over the panel (Escape or Back returns), and Start Thread from an issue.
    private(set) var review: MergeRequestReviewController?
    private var hosting: NSViewController?
    var startThreadFromIssue: ((GitLabIssue, String, String?) -> Void)?

    init() {
        host.view = NSView()
    }

    func makePanelController() -> NSViewController { host }

    /// Binds to a window's engine. Idempotent.
    func bind(engine: Engine) {
        guard model == nil, let extras = engine.extras else { return }
        let model = MergeRequestPanelModel(service: extras.mergeRequests, work: extras.gitLabWork, reviews: extras.reviews)
        model.openReview = { [weak self] ref in self?.openReview(ref) }
        model.projectDirectory = { [weak self] in self?.context?.projectDirectory }
        model.resolveProject = { [weak extras] directory in
            guard let extras, let remote = try? await GitRepository(directory: directory).remoteURL() else { return nil }
            return ForgeProject.resolve(remote: remote, instances: extras.mergeRequests.instances)
        }
        model.startThreadFromIssue = { [weak self] issue, instance, selection in self?.startThreadFromIssue?(issue, instance, selection) }
        model.openURL = { [weak self] url, builtIn in
            if builtIn, self?.context?.onOpenInBrowser?(url) == true { return }
            NSWorkspace.shared.open(url)
        }
        model.openSettings = { (NSApp.delegate as? AppDelegate)?.openSettings(pane: "gitlab") }
        model.insertIntoComposer = { [weak self] text in self?.context?.onInsertIntoComposer?(text) }
        model.confirm = { title, detail, button in Self.confirm(title, detail, button) }
        model.makeCreateContext = { [weak self, weak engine] id in
            guard let engine, let directory = self?.context?.directory ?? engine.orchestration?.node(id)?.node.directory else { return nil }
            return Self.createContext(engine: engine, sessionID: id, directory: directory)
        }
        self.model = model
        let hosting = NSHostingController(rootView: MergeRequestPanelView(model: model))
        hosting.sizingOptions = []
        host.addChild(hosting)
        hosting.view.frame = host.view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        host.view.addSubview(hosting.view)
        self.hosting = hosting
        display(context)
    }

    /// Shows the inline create form for the displayed thread (Changes ▸ Create Merge Request, Thread menu).
    func showCreate() {
        showPanel()
        if model?.create == nil { model?.openCreate() }
    }

    static func confirm(_ title: String, _ detail: String, _ button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The create form's view of a thread: git (the person's own transport) for status, push and commits; the
    /// thread's model for a proposal.
    static func createContext(engine: Engine, sessionID: SessionID, directory: String) -> CreateMergeRequestContext {
        let model = engine.git.repository(for: directory)
        return CreateMergeRequestContext(
            sessionID: sessionID, directory: directory,
            checkout: {
                let repository = model.repository
                guard let status = try? await repository.status() else { return nil }
                let remote = try? await repository.remoteURL()
                return CheckoutState(branch: status.branch, remote: remote ?? nil, upstream: status.upstream, ahead: status.ahead)
            },
            push: {
                try await model.push()
            },
            commits: { target in
                let repository = model.repository
                for range in ["origin/\(target)..HEAD", "\(target)..HEAD"] {
                    if let commits = try? await repository.commits(range, limit: 50) { return commits.reversed().map(\.subject) }
                }
                return []
            },
            generate: { prompt in try await engine.generateText(in: sessionID, prompt: prompt, task: "Merge request text") })
    }

    func display(_ context: ThreadSurfaceContext?) {
        if context?.thread?.sessionID != self.context?.thread?.sessionID { closeReview() }
        self.context = context
        context?.onShowMergeRequests = { [weak self] in self?.showPanel() }
        context?.onShowIssues = { [weak self] in self?.show(section: .issues) }
        model?.display(context?.thread?.sessionID)
    }

    /// Shows a section of the tab (GitLab menu: Show Issues, Show To-dos).
    func show(section: MergeRequestPanelModel.Section) {
        closeReview()
        showPanel()
        model?.section = section
    }

    /// Opens the inline review of `ref` over the panel (the diff of its latest version with threads).
    func openReview(_ ref: MergeRequestRef) {
        guard let model, let reviews = model.reviews else { return }
        if review?.model.ref == ref { return showPanel() }
        closeReview()
        let reviewModel = MergeRequestReviewModel(ref: ref, service: reviews)
        reviewModel.insertIntoComposer = { [weak self] text in self?.context?.onInsertIntoComposer?(text) }
        reviewModel.openURL = { [weak self] url in
            if self?.context?.onOpenInBrowser?(url) == true { return }
            NSWorkspace.shared.open(url)
        }
        reviewModel.confirm = { title, detail, button in Self.confirm(title, detail, button) }
        let controller = MergeRequestReviewController(model: reviewModel)
        controller.onClose = { [weak self] in self?.closeReview() }
        host.addChild(controller)
        controller.view.frame = host.view.bounds
        controller.view.autoresizingMask = [.width, .height]
        host.view.addSubview(controller.view)
        hosting?.view.isHidden = true
        review = controller
        showPanel()
        controller.diff.focus()
    }

    func closeReview() {
        guard let review else { return }
        review.view.removeFromSuperview()
        review.removeFromParent()
        self.review = nil
        hosting?.view.isHidden = false
    }
}

// MARK: - GitLab commands (menus, palette; GitLab 2)

extension MergeRequestSurfaces {
    /// The MR the tab's commands act on: the expanded one, else the only or first linked.
    var focusedLink: LinkedMergeRequest? {
        guard let model else { return nil }
        return model.links.first { $0.ref.url == model.expandedURL } ?? model.links.first
    }

    private var focusedSnapshot: MergeRequestSnapshot? { focusedLink.flatMap { model?.service.snapshots[$0.ref.url] } }

    var commandState: GitLabCommandState {
        var state = GitLabCommandState()
        guard let model else { return state }
        let service = model.service
        state.configured = !service.instances.isEmpty
        state.hasThread = model.threadID != nil
        if let link = focusedLink {
            state.hasMergeRequest = true
            state.babysitting = link.watching
            let settings = service.settings(for: link.ref.instance)
            state.writes = settings.writesEnabled
            state.approveAndMerge = settings.writesEnabled && settings.approveAndMergeEnabled && focusedSnapshot?.state == .opened
            state.hasFailedJob = focusedSnapshot?.pipeline?.failedJobs.isEmpty == false
            state.hasManualJob = focusedSnapshot?.pipeline?.jobs.contains(where: \.isManual) == true
        }
        if let review {
            state.reviewOpen = true
            state.writes = review.model.writesEnabled
            state.reviewHasDrafts = !review.model.drafts.isEmpty
            state.reviewSendable = review.model.service.submitPlan(review.model.ref).sendable > 0
            state.reviewHasThreads = review.hasThreads
            if let current = review.diff.currentAnnotation ?? review.diff.annotations.first,
                let discussion = review.model.state?.discussions.first(where: { $0.id == current.id })
            {
                state.currentThreadResolvable = discussion.isResolvable
                state.currentThreadResolved = discussion.isResolved
            }
        }
        state.issueSelected = model.section == .issues && model.issueDetail != nil
        if model.section == .todos, let id = model.selectedTodo, let entry = model.todos.first(where: { $0.todo.id == id }) {
            state.todoSelected = true
            state.todoWrites = service.settings(for: entry.instance).writesEnabled
        }
        return state
    }

    func perform(_ command: ShellCommand) {
        guard let model else { return }
        let link = focusedLink
        let snapshot = focusedSnapshot
        switch command {
        case .reviewMergeRequest: if let link { model.review(link.ref) }
        case .submitReview: review?.submitReview(nil)
        case .discardReviewDrafts: review?.discardReviewDrafts(nil)
        case .closeReview: closeReview()
        case .nextReviewThread: review?.diff.nextAnnotation()
        case .previousReviewThread: review?.diff.previousAnnotation()
        case .replyToReviewThread: review?.performOnCurrentThread("reply")
        case .toggleReviewThreadResolved: review?.performOnCurrentThread("resolve")
        case .addReviewThreadToAgent: review?.performOnCurrentThread("agent")
        case .refreshMergeRequests: Task { await model.refresh() }
        case .linkMergeRequest:
            let alert = NSAlert()
            alert.messageText = "Link a merge request to this thread"
            alert.informativeText = "Its URL, or !number in this thread's GitLab project."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.placeholderString = "https://gitlab.example.com/group/project/-/merge_requests/12 or !12"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: "Link")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            showPanel()
            model.section = .mergeRequests
            model.linkText = field.stringValue
            Task { await model.link() }
        case .openMergeRequestInGitLab: if let url = URL(string: snapshot?.webURL ?? link?.ref.url ?? "") { model.openURL(url, false) }
        case .toggleBabysit: if let link { Task { await model.setWatching(link, !link.watching) } }
        case .unlinkMergeRequest: if let link { Task { await model.unlink(link) } }
        case .showFailingJobLog:
            if let snapshot, let job = snapshot.pipeline?.failedJobs.first { closeReview(); showPanel(); model.showLog(snapshot.ref, job) }
        case .sendFailureToAgent: if let snapshot, let job = snapshot.pipeline?.failedJobs.first { Task { await model.sendToAgent(snapshot.ref, job) } }
        case .retryFailedJob: if let snapshot, let job = snapshot.pipeline?.failedJobs.first { Task { await model.retry(snapshot.ref, job) } }
        case .playManualJob: if let snapshot, let job = snapshot.pipeline?.jobs.first(where: \.isManual) { Task { await model.play(snapshot.ref, job) } }
        case .approveMergeRequest: if let snapshot { Task { await model.approve(snapshot) } }
        case .mergeMergeRequest: if let snapshot { Task { await model.merge(snapshot) } }
        case .showIssues: show(section: .issues)
        case .showTodos: show(section: .todos)
        case .startThreadFromIssue: if let issue = model.issueDetail { model.startThread(issue) }
        case .linkIssueToThread: if let issue = model.issueDetail { Task { await model.linkIssue(issue) } }
        case .openTodo: if let id = model.selectedTodo, let entry = model.todos.first(where: { $0.todo.id == id }) { model.openTodo(entry.todo) }
        case .markTodoDone:
            if let id = model.selectedTodo, let entry = model.todos.first(where: { $0.todo.id == id }) { Task { await model.markDone(entry.todo, instance: entry.instance) } }
        default: break
        }
    }
}
