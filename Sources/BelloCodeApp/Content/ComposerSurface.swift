import AgentUI
import AppKit
import BelloCore
import ComposerKit
import DesignSystem
import DiffKit
import Engine
import Observation

/// The composer mounted for one displayed thread or draft: ComposerKit's `ComposerViewController` with the AgentUI
/// controls (agent, permission mode, model) in its controls bar and a context line (project, branch, workspace)
/// below the card. A draft uses the "hero" composer (three lines) and creates its thread on the first send.
///
/// Threading: `@MainActor`. Owns its observation loop and git read; both end with the controller.
@MainActor
final class ComposerSurfaceController: NSViewController, ComposerSurface {
    let context: ThreadSurfaceContext
    let services: AppServices
    let composer: ComposerViewController
    private(set) var host: (any ComposerHost)?
    /// The draft's choices (nil for a thread).
    private(set) var draftSource: DraftAgentSource?
    private(set) var modelPicker: ModelPickerModel?
    private(set) var modeTrigger = PopoverTrigger()
    private let contextLine = ComposerContextLine()
    private var loop: ObservationLoop?
    private var gitTask: Task<Void, Never>?
    /// A draft's workspace choice (M2-C): local checkout, new worktree or existing worktree.
    private(set) var workspaceDraft: WorkspaceDraft?
    private var gitLoop: ObservationLoop?

    init(context: ThreadSurfaceContext, services: AppServices) {
        self.context = context
        self.services = services
        var configuration = ComposerConfiguration()
        configuration.sendKey = services.settings.sendKey
        composer = ComposerViewController(style: AppStyle.composer(hero: context.isDraft), configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        loop?.cancel()
        gitTask?.cancel()
        gitLoop?.cancel()
    }

    // MARK: ComposerSurface

    var preferredFocusView: NSView? { composer.textView }
    var hasSendableText: Bool { !composer.currentDraft().isEmpty }
    func performSend() { composer.send(alternate: false) }
    func insertText(_ text: String) {
        composer.focus()
        composer.insert(text: text)
    }
    var runState: ComposerRunState { composer.controller.runState }

    // MARK: View

    override func loadView() {
        let container = NSView()
        addChild(composer)
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(composer.view)
        NSLayoutConstraint.activate([
            composer.view.topAnchor.constraint(equalTo: container.topAnchor),
            composer.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            composer.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        composer.configuration = configuration()
        if let thread = context.thread {
            host = ThreadModelComposerHost(thread, fileStore: services.attachmentStore)
            mountControls(thread: thread)
        } else {
            let source = DraftAgentSource(directory: context.projectDirectory, engine: context.engine)
            draftSource = source
            host = DraftComposerHost(context: context, source: source, fileStore: services.attachmentStore)
            mountDraftControls(source)
        }
        composer.host = host
        composer.contextLineView = contextLine.strip
        contextLine.project = context.projectName
        contextLine.directory = context.directory
        readGitContext()
        loop = ObservationLoop { [weak self] in self?.observeSettings() }
        observeGitStatus()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        composer.controller.flushDraft()
    }

    /// Completion providers: server commands and skills for `/`, server file search plus agents for `@`, with the
    /// local file index as the offline fallback.
    private func configuration() -> ComposerConfiguration {
        var configuration = composer.configuration
        configuration.sendKey = services.settings.sendKey
        let engine = context.engine
        let directory = context.directory
        let slash = ServerSlashCompletionProvider { @MainActor in
            try await engine.slashEntries(directory: directory).map { entry in
                ServerSlashCompletionProvider.Entry(
                    kind: entry.kind == .skill ? .skill : .command, id: entry.id, name: entry.name, detail: entry.detail)
            }
        }
        let agents = engine.mentionableAgents(directory: directory).map { (name: $0.id, detail: $0.detail) }
        let mention = ServerMentionCompletionProvider(
            root: directory, agents: agents, fallback: FilePathCompletionProvider(root: URL(filePath: directory))
        ) { @MainActor query in
            try await engine.findFiles(directory: directory, query: query)
        }
        configuration.completionProviders = [mention, slash]
        return configuration
    }

    private func observeSettings() {
        let sendKey = services.settings.sendKey
        _ = services.settings.baseFontSize
        if composer.configuration.sendKey != sendKey { composer.configuration.sendKey = sendKey }
        let style = AppStyle.composer(hero: context.isDraft)
        if composer.style.font != style.font { composer.style = style }
        contextLine.hint = Self.sendHint(sendKey: sendKey, running: context.thread?.isRunning ?? false)
    }

    /// The strip's trailing hint: what Return does now (UX rule 5: queue and steer are distinct and labelled).
    static func sendHint(sendKey: SendKey, running: Bool) -> String {
        let plain = SendKeyPolicy.shortcutLabel(sendKey: sendKey, alternate: false)
        let alternate = SendKeyPolicy.shortcutLabel(sendKey: sendKey, alternate: true)
        return running ? "\(plain) queues · \(alternate) steers" : "\(plain) sends"
    }

    // MARK: Controls

    private func mountControls(thread: ThreadModel) {
        let engine = context.engine
        let directory = thread.session?.directory ?? context.directory
        let agents = engine.root.catalog.catalog(for: directory)?.primaryAgents ?? []
        let plan = AppStyle.host(PlanModeToggle(source: thread))
        let mode = AppStyle.host(PermissionModePicker(source: thread, agents: agents, trigger: modeTrigger))
        let picker = AgentUIFactories.modelPickerModel(
            thread: thread, engine: engine, auth: services.auth, onConnect: { [services] id in services.connectProvider(id) })
        modelPicker = picker
        let model = AppStyle.host(ModelPickerButton(model: picker))
        install(leading: [plan, model], trailing: [mode])
    }

    private func mountDraftControls(_ source: DraftAgentSource) {
        let engine = context.engine
        let directory = context.directory
        let agents = engine.root.catalog.catalog(for: directory)?.primaryAgents ?? []
        let plan = AppStyle.host(PlanModeToggle(source: source))
        let mode = AppStyle.host(PermissionModePicker(source: source, agents: agents, trigger: modeTrigger))
        let picker = ModelPickerModel(
            catalog: { [weak engine] in engine?.root.catalog.catalog(for: directory) },
            current: { [weak source, weak engine] in
                source?.session?.model ?? engine?.root.catalog.catalog(for: directory)?.defaultModel
            },
            preferences: engine.modelPreferences,
            apply: { [weak source] selection in
                await source?.setModel(selection)
                return nil
            },
            integrations: { [weak auth = services.auth] in auth?.integrations ?? [] },
            reload: { [weak engine, weak auth = services.auth] in
                await engine?.refreshCatalog(directory: directory)
                await auth?.refresh()
            },
            onConnect: { [services] id in services.connectProvider(id) })
        modelPicker = picker
        let model = AppStyle.host(ModelPickerButton(model: picker))
        // M2-C: where the new thread works (local checkout / new or existing worktree) and its branch.
        let projectID = engine.root.projects.first { $0.directory == context.projectDirectory }?.projectID
        let workspace = WorkspaceDraft(git: engine.git, projectDirectory: context.projectDirectory, projectID: projectID)
        workspace.load()
        workspaceDraft = workspace
        (host as? DraftComposerHost)?.prepareDirectory = { [weak workspace] prompt in
            try await workspace?.prepare(prompt: prompt).directory
        }
        // Git parity: a worktree branch named from the prompt's slug gets a name proposed by the thread's model.
        (host as? DraftComposerHost)?.afterFirstSend = { [weak workspace, engine] model, prompt in
            guard let created = workspace?.takeAutoNamedWorktree() else { return }
            Task { await engine.renameGeneratedBranch(model.sessionID, created: created, firstPrompt: prompt) }
        }
        install(
            leading: [plan, model, AppStyle.host(WorkspacePickerButton(draft: workspace)), AppStyle.host(BranchPickerButton(draft: workspace))],
            trailing: [mode])
    }

    /// Opens the draft's workspace picker (menu: Choose Workspace…).
    func openWorkspacePicker() {
        guard let workspaceDraft else { return NSSound.beep() }
        workspaceDraft.requestWorkspacePicker()
    }

    /// Opens the draft's branch picker (menu: Choose Branch…).
    func openBranchPicker() {
        guard let workspaceDraft else { return NSSound.beep() }
        workspaceDraft.requestBranchPicker()
    }

    /// Keeps the context line's git state (dirty, ahead/behind, worktree choice) current; status refreshes on window
    /// focus and after each turn (ChangesSurfaces) and on file changes while the Changes tab watches.
    private func observeGitStatus() {
        let repository = context.engine.git.repository(for: context.directory)
        gitLoop = ObservationLoop { [weak self] in
            guard let self else { return }
            let status = repository.status
            var text = status.map { status -> String in
                var parts = [status.files.isEmpty ? "clean" : "\(status.files.count) changed"]
                if status.ahead > 0 { parts.append("↑\(status.ahead)") }
                if status.behind > 0 { parts.append("↓\(status.behind)") }
                return parts.joined(separator: " ")
            }
            if let draft = self.workspaceDraft {
                self.contextLine.workspaceOverride = draft.mode == .local ? nil : draft.workspaceLabel
                switch draft.phase {
                case .preparing(let message): text = message
                case .failed(let message): text = "⚠︎ " + message
                case .idle: break
                }
            }
            self.contextLine.statusText = text
        }
    }

    private func install(leading: [NSView], trailing: [NSView]) {
        composer.leadingControls.spacing = DS.Space.s12
        composer.trailingControls.spacing = DS.Space.s12
        for view in leading { composer.leadingControls.addArrangedSubview(view) }
        for view in trailing { composer.trailingControls.addArrangedSubview(view) }
    }

    /// Opens the model picker (menu: Choose Model…).
    func openModelPicker() { modelPicker?.requestOpen() }
    /// Opens the permission-mode popover (menu: Permission Mode…).
    func openPermissionMode() { modeTrigger.fire() }
    /// Switches between the plan and build agents (menu: Toggle Plan Mode).
    func togglePlan() {
        let source: (any AgentModeSource)? = context.thread ?? draftSource
        guard let source else { return }
        let isPlan = source.session?.agent == "plan"
        Task { await source.setAgent(isPlan ? "build" : "plan") }
    }

    // MARK: Context line

    private func readGitContext() {
        let directory = context.directory
        gitTask = Task { [weak self] in
            let git = await GitContext.read(directory: directory)
            guard !Task.isCancelled, let self, self.context.directory == directory else { return }
            self.contextLine.git = git
        }
    }
}

/// "project · ⎇ branch · Local checkout": where the agent will act (AGENTS.md UX rule 6), shown in ComposerKit's
/// `ComposerContextStrip` under the composer (`meta text3`, 12 pt glyphs, the send hint at the trailing end).
@MainActor
final class ComposerContextLine {
    let strip = ComposerContextStrip()
    var project = "" { didSet { if project != oldValue { render() } } }
    var directory = "" { didSet { if directory != oldValue { render() } } }
    var git: GitContext? { didSet { render() } }
    /// "3 changed ↑2", or the worktree being prepared (M2-C).
    var statusText: String? { didSet { if statusText != oldValue { render() } } }
    /// The draft's chosen workspace when it is not the local checkout ("New worktree").
    var workspaceOverride: String? { didSet { if workspaceOverride != oldValue { render() } } }
    var hint: String {
        get { strip.hint }
        set { if strip.hint != newValue { strip.hint = newValue } }
    }

    init() {
        strip.toolTip = nil
        render()
    }

    private func render() {
        let shortPath = (directory as NSString).abbreviatingWithTildeInPath
        let plainFolder = git?.workspace == .plainFolder
        let branch: String
        if let git, let name = git.branch {
            branch = git.isDetached ? "Detached at \(name)" : name
        } else if plainFolder {
            branch = shortPath
        } else {
            branch = "…"
        }
        var items = [ComposerContextStrip.Item(symbolName: "folder", text: project)]
        items.append(.init(symbolName: plainFolder ? "folder" : "arrow.triangle.branch", text: branch))
        if !plainFolder {
            let worktree = git?.workspace == .worktree || workspaceOverride != nil
            let text = (workspaceOverride ?? git?.workspaceLabel ?? "Local checkout") + (statusText.map { " · " + $0 } ?? "")
            items.append(.init(symbolName: worktree ? "square.on.square.dashed" : "laptopcomputer", text: text))
        }
        strip.items = items
        strip.toolTip = directory
    }
}

/// A new-thread draft's agent, model and permission mode before the thread exists. Presented to the AgentUI controls
/// as a session-like value; applied when the first send creates the thread.
@MainActor
@Observable
final class DraftAgentSource: AgentModeSource {
    private(set) var options = DraftThreadOptions()
    let directory: String
    @ObservationIgnored private weak var engine: Engine?

    init(directory: String, engine: Engine) {
        self.directory = directory
        self.engine = engine
    }

    var session: Session? {
        Session(
            id: SessionID("draft"), projectID: ProjectID("draft"), directory: directory, agent: options.agent ?? "build",
            model: options.model, permissionMode: options.permissionMode, created: .now, updated: .now)
    }

    var lastError: EngineError? { nil }
    func setPermissionMode(_ mode: PermissionMode) async { options.permissionMode = mode }
    func setAgent(_ agent: String) async { options.agent = agent }
    func setModel(_ model: ModelSelection) async { options.model = model }
}

/// The composer host for a new-thread draft: keeps the text in the project's draft, and on the first send creates the
/// thread (with the draft's agent, model and mode), then sends through that thread's host. After creation every
/// call goes to the thread, so a failed first send restores the text into the new thread's composer.
@MainActor
final class DraftComposerHost: ComposerHost {
    let context: ThreadSurfaceContext
    let source: DraftAgentSource
    let fileStore: AttachmentFileStore
    private(set) var created: ThreadModelComposerHost?
    private let cache = ComposerDraftCache.shared
    /// Prepares the thread's directory before it is created (the workspace picker's new worktree); nil: the project.
    var prepareDirectory: (@MainActor (String) async throws -> String?)?
    /// Git parity: runs after the first send created the thread (generated worktree branch names).
    var afterFirstSend: (@MainActor (ThreadModel, String) -> Void)?

    init(context: ThreadSurfaceContext, source: DraftAgentSource, fileStore: AttachmentFileStore) {
        self.context = context
        self.source = source
        self.fileStore = fileStore
    }

    var draftKey: String { created?.draftKey ?? "draft:" + context.projectDirectory }

    func loadDraft() -> ComposerDraft {
        if let created { return created.loadDraft() }
        let text = context.newThreadDraft
        if let cached = cache.draft(for: draftKey), cached.text == text { return cached }
        return ComposerDraft(text: text)
    }

    func saveDraft(_ draft: ComposerDraft) {
        if let created { return created.saveDraft(draft) }
        cache.store(draft, for: draftKey)
        if context.newThreadDraft != draft.text { context.draft = draft.text }
    }

    func send(_ submission: ComposerSubmission) async -> ComposerSendOutcome {
        if let created { return await created.send(submission) }
        var options = source.options
        // Git parity: a project still cloning opens at once; its first send waits for the files (T3 Code).
        if let job = context.engine.gitProjects?.job(for: context.projectDirectory), job.state == .cloning {
            await job.waitUntilDone()
            if case .failed(let message) = job.state { return .failed("The clone failed, so nothing was sent: \(message)") }
            if job.state == .cancelled { return .failed("The clone was cancelled, so nothing was sent.") }
        }
        if let prepareDirectory {
            do {
                options.directory = try await prepareDirectory(submission.text)
            } catch {
                return .failed((error as? WorktreeError)?.userMessage ?? (error as? GitError)?.userMessage ?? "The worktree could not be created.")
            }
        }
        guard let model = await context.createThread(options) else {
            return .failed(context.visibleError ?? "The thread could not be created.")
        }
        let host = ThreadModelComposerHost(model, fileStore: fileStore)
        created = host
        cache.store(.empty, for: "draft:" + context.projectDirectory)
        let outcome = await host.send(submission)
        afterFirstSend?(model, submission.text)
        return outcome
    }

    func stop() async { await created?.stop() }
    var runState: ComposerRunState { created?.runState ?? .idle }
    var supportsSteer: Bool { true }
    var supportsAttachments: Bool { true }
    var errorMessage: String? { created?.errorMessage ?? context.visibleError }
    func clearError() {
        created?.clearError()
        context.clearError()
    }

    func observe(_ onChange: @escaping @MainActor () -> Void) -> ComposerObservation {
        let loop = ObservationLoop { [weak self] in
            guard let self else { return }
            _ = self.context.visibleError
            _ = self.context.isCreatingThread
            onChange()
        }
        return ComposerObservation { loop.cancel() }
    }
}
