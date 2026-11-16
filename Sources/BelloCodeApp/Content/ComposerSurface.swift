import AgentUI
import AppKit
import BelloCore
import ComposerKit
import DesignSystem
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
    }

    // MARK: ComposerSurface

    var preferredFocusView: NSView? { composer.textView }
    var hasSendableText: Bool { !composer.currentDraft().isEmpty }
    func performSend() { composer.send(alternate: false) }
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
        composer.contextLineView = contextLine
        contextLine.project = context.projectName
        contextLine.directory = context.directory
        readGitContext()
        loop = ObservationLoop { [weak self] in self?.observeSettings() }
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
        install(leading: [plan, model], trailing: [mode])
    }

    private func install(leading: [NSView], trailing: [NSView]) {
        composer.leadingControls.spacing = DS.Spacing.l
        composer.trailingControls.spacing = DS.Spacing.l
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

/// "project · ⎇ branch · Local checkout": where the agent will act (AGENTS.md UX rule 6). Text, never colour only.
@MainActor
final class ComposerContextLine: NSStackView {
    var project = "" { didSet { render() } }
    var directory = "" { didSet { render() } }
    var git: GitContext? { didSet { render() } }
    private let projectLabel = ComposerContextLine.item(symbol: "folder")
    private let branchLabel = ComposerContextLine.item(symbol: "arrow.triangle.branch")
    private let workspaceLabel = ComposerContextLine.item(symbol: "laptopcomputer")

    init() {
        super.init(frame: .zero)
        spacing = DS.Spacing.l
        for view in [projectLabel, branchLabel, workspaceLabel] { addArrangedSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func item(symbol: String) -> NSButton {
        let button = NSButton(title: "", image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = DS.Typography.current.caption
        button.contentTintColor = DS.Palette.secondaryText
        button.symbolConfiguration = .init(pointSize: DS.Typography.current.caption.pointSize - 1, weight: .regular)
        button.refusesFirstResponder = true
        button.setButtonType(.momentaryChange)
        button.isEnabled = true
        return button
    }

    private func render() {
        let shortPath = (directory as NSString).abbreviatingWithTildeInPath
        projectLabel.title = project
        projectLabel.toolTip = directory
        let branch: String
        if let git, let name = git.branch {
            branch = git.isDetached ? "Detached at \(name)" : name
        } else if git?.workspace == .plainFolder {
            branch = shortPath
        } else {
            branch = "…"
        }
        branchLabel.title = branch
        branchLabel.image = NSImage(
            systemSymbolName: git?.workspace == .plainFolder ? "folder" : "arrow.triangle.branch", accessibilityDescription: nil)
        branchLabel.toolTip = git?.workspace == .plainFolder ? directory : "Branch"
        workspaceLabel.title = git?.workspaceLabel ?? "Local checkout"
        workspaceLabel.isHidden = git?.workspace == .plainFolder
        for label in [projectLabel, branchLabel, workspaceLabel] { label.contentTintColor = DS.Palette.secondaryText }
        setAccessibilityLabel("Acts in \(project), \(branch), \(workspaceLabel.isHidden ? shortPath : workspaceLabel.title)")
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
        guard let model = await context.createThread(source.options) else {
            return .failed(context.visibleError ?? "The thread could not be created.")
        }
        let host = ThreadModelComposerHost(model, fileStore: fileStore)
        created = host
        cache.store(.empty, for: "draft:" + context.projectDirectory)
        return await host.send(submission)
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
