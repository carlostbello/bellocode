import BelloCore
import Foundation
import Observation

/// A project as the sidebar lists it: BelloCode's registry entry joined with opencode's project, if known yet.
public struct ProjectItem: Hashable, Sendable, Identifiable {
    public var entry: ProjectEntry
    public var project: Project?

    /// The directory (a folder has no opencode project ID until first used).
    public var id: String { entry.directory }
    public var directory: String { entry.directory }
    public var projectID: ProjectID? { project?.id ?? entry.projectID }
    /// The project's name, or the folder's when the folder is inside a larger project (a repository subfolder).
    public var name: String {
        if let project, project.directory == entry.directory { return project.displayName }
        return (entry.directory as NSString).lastPathComponent
    }
    public var isPinned: Bool { entry.pinned }
}

/// App-wide presentation state: connection, the project list, the "Needs you" summary and the catalog.
///
/// Threading: `@MainActor`, owned by `Engine`. Each property changes only for its own topic: a streaming token never
/// touches it, a status change updates `attention` and the affected row only.
@MainActor
@Observable
public final class EngineRoot {
    /// Cached content stays visible in every state; show staleness from this, never a blank pane.
    public private(set) var connection: ConnectionStatus = .cached
    /// Unarchived projects: pinned first, then the user's order.
    public private(set) var projects: [ProjectItem] = []
    /// Projects the user removed from the sidebar (restorable).
    public private(set) var hiddenProjects: [ProjectItem] = []
    /// The global "Needs you" list (urgency, then age) and badge counts.
    public private(set) var attention: AttentionSummary = .empty
    /// Whether local state reaches disk. Show `storage.message` (with `preferencesUnsaved`) wherever it is not `.ok`.
    public private(set) var storage: StorageStatus = .ok
    /// Lists the last resync could not read (their last-known rows stay shown; retried). Empty when fully synced.
    public private(set) var syncGaps = SyncGaps()
    /// Every thread's sidebar organisation (absent = `.none`). Changes only on user action, a wake or auto-settle.
    public internal(set) var organisation: [SessionID: ThreadOrganisation] = [:]
    /// Auto-settle rules (Settings ▸ Threads).
    public internal(set) var organisationRules: OrganisationRules = .default
    public let catalog = CatalogModel()

    @ObservationIgnored private var projectsByID: [ProjectID: Project] = [:]
    @ObservationIgnored private var registry: [String: ProjectEntry] = [:]
    @ObservationIgnored fileprivate var projectModels: [ProjectID: ProjectModel] = [:]

    init() {}

    /// The session list of a project. Created on first request (from the cache, synchronously populated by the
    /// launch snapshot for known projects).
    public func project(_ id: ProjectID) -> ProjectModel? { projectModels[id] }
    /// Every loaded project model (git parity: which threads share a directory).
    var loadedProjects: [ProjectModel] { Array(projectModels.values) }

    fileprivate func setProjects(_ projects: [Project], registry entries: [ProjectEntry]) {
        projectsByID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        registry = Dictionary(entries.map { ($0.directory, $0) }, uniquingKeysWith: { $1 })
        rebuildProjectList()
    }

    fileprivate func apply(projectsChange change: ChangeSet) {
        for id in change.removedProjects { projectsByID[id] = nil }
        for (id, project) in change.projects { projectsByID[id] = project }
        for directory in change.removedRegistry { registry[directory] = nil }
        for (directory, entry) in change.registry { registry[directory] = entry }
        rebuildProjectList()
    }

    private func rebuildProjectList() {
        let byDirectory = Dictionary(projectsByID.values.map { ($0.directory, $0) }, uniquingKeysWith: { $1 })
        let items = registry.values.map { entry in
            ProjectItem(entry: entry, project: entry.projectID.flatMap { projectsByID[$0] } ?? byDirectory[entry.directory])
        }.sorted { lhs, rhs in
            if lhs.entry.pinned != rhs.entry.pinned { return lhs.entry.pinned }
            if lhs.entry.sortOrder != rhs.entry.sortOrder { return lhs.entry.sortOrder < rhs.entry.sortOrder }
            return lhs.directory < rhs.directory
        }
        let visible = items.filter { !$0.entry.archived }
        let hidden = items.filter(\.entry.archived)
        if visible != projects { projects = visible }
        if hidden != hiddenProjects { hiddenProjects = hidden }
    }

    fileprivate func setConnection(_ status: ConnectionStatus) {
        if status != connection { connection = status }
    }

    fileprivate func setAttention(_ summary: AttentionSummary) {
        if summary != attention { attention = summary }
    }

    fileprivate func setStorage(_ status: StorageStatus) {
        if status != storage { storage = status }
    }

    fileprivate func setSyncGaps(_ gaps: SyncGaps) {
        if gaps != syncGaps { syncGaps = gaps }
    }
}

/// The engine facade: wires the server (supervised or attached), the event stream, the projection store and the
/// presentation models, and exposes the commands UI code calls.
///
/// Threading and ownership: `@MainActor`. Create one per app (or per test), call `start()` once and `stop()` before
/// quitting. All heavy work (network, decoding, reducing, SQLite) runs off the main actor in `EngineCore` and the
/// store; models receive immutable values.
///
/// Lifecycle: `start()` first reads the cache and fills `root` (projects, sessions, attention), so the UI can render
/// before the server is ready; then it starts the server (if supervised) and the event stream. Every connect resyncs
/// from the list endpoints.
///
/// Commands throw `EngineError` (user-presentable). Optimistic changes appear immediately and roll back on failure;
/// nothing is reported as delivered before the server acknowledges it.
@MainActor
public final class Engine {
    public let root = EngineRoot()
    public let store: ProjectionStore
    public let configuration: EngineConfiguration
    /// Model picker favourites, recents and hidden models (app-owned; persisted in the store).
    public let modelPreferences: ModelPreferencesModel
    /// Per-thread terminals on opencode's persistent PTYs (docs/features/terminal.md).
    public let terminals: TerminalService
    /// Palette frecency (app-owned; persisted in the store).
    public let frecency: FrecencyModel
    /// Git status, diffs, worktrees and turn revert (docs/features/diff-git.md).
    public let git: GitService
    /// Per-thread agent control of the built-in browser (`experimental.browser` bridge; docs/features/browser.md).
    public let browser: BrowserBridgeService
    /// Orchestration: the task graph, Agents panel models, cascade stop and app-hosted agent tools
    /// (docs/features/orchestration.md). Created in `init`, started by `start()`.
    public private(set) var orchestration: OrchestrationService!
    /// Auto mode decisions, Full-access risk notices and their audit log (docs/features/auto-mode.md).
    public private(set) var auto: AutoModeService!
    /// Folders the developer works across, in scope for Auto and Full-access notices (docs/features/auto-mode.md).
    /// Default: none (only each thread's project and worktrees). Set by the code-roots settings, or via `codeRootsProvider`.
    public var codeRoots: CodeRoots = .none {
        didSet {
            guard codeRoots != oldValue else { return }
            // Each push sends the latest value, so quick successive changes cannot land out of order.
            Task { [weak self, core] in
                guard let roots = self?.codeRoots else { return }
                await core.setCodeRoots(roots)
            }
        }
    }
    /// Optional source of `codeRoots`; read when set and by `refreshCodeRoots()`.
    public weak var codeRootsProvider: (any CodeRootsProvider)? {
        didSet { refreshCodeRoots() }
    }

    /// Re-reads `codeRootsProvider` (call when its roots change).
    public func refreshCodeRoots() {
        if let provider = codeRootsProvider { codeRoots = provider.codeRoots }
        // Secrets scoped to code roots, the shared workspace's egress scope and the proxy follow at once (N13).
        secretManager?.codeRootsDidChange()
    }
    /// Scheduled tasks, PR linking and watching, secret requests, HTML visuals (docs/features/orchestration-extras.md).
    public private(set) var extras: ExtrasHub!
    /// Secrets by label with brokered, placeholder and visible use; the egress proxy and its audit
    /// (docs/features/secrets.md).
    public private(set) var secretManager: SecretManager!
    /// Containerised execution: runtime state, each project's workspace container, ports, the isolation self-check
    /// (docs/features/containers.md).
    public let environments: EnvironmentService
    /// Git parity: clone from GitLab, publish, new projects (docs/features/git-parity.md).
    public private(set) var gitProjects: GitProjectService!
    /// The one shared Chromium for every thread and project: lifecycle, approvals, tab groups, routes, live view
    /// (docs/features/shared-browser.md).
    public private(set) var sharedBrowser: SharedBrowserService!
    /// opencode's global configuration folder, per-project trust of repository configuration, what the server reports,
    /// reload and restart (docs/features/opencode-config.md).
    public private(set) var openCodeConfig: OpenCodeConfigService!
    /// Settings ▸ Models: opencode's default and small model, and the models of background tasks (Auto's reviewer
    /// lives in `auto`) (docs/features/models.md).
    public internal(set) var models: ModelSettingsService!
    let core: EngineCore

    private let tasks = TaskBox()
    /// The last organisation write sent to the core; each waits for the one before, so they apply in order.
    var organisationWrite: Task<Void, Never>?
    private var openThreads: [SessionID: ThreadModel] = [:]
    private var trackedTasks: [Int: Task<Void, Never>] = [:]
    private var nextTrackedID = 0
    private var defaultDirectory: String?
    private var started = false
    /// Service restarts waiting for the person's approval (`ServiceTools.swift`), and projects where agents may restart
    /// services without asking (`app_grant` kind serviceRestart).
    var pendingServiceRestarts: [String: PendingServiceRestart] = [:]
    var serviceRestartGrants: Set<String> = []
    var serviceRestartGrantsLoaded = false

    /// Opens the store on the calling thread. Prefer `make(configuration:)` from the main actor: opening and migrating
    /// SQLite can take a while on a slow disk.
    public convenience init(configuration: EngineConfiguration) throws {
        let store = try ProjectionStore(location: configuration.store, changes: ChangeBus(subscriberLimit: configuration.subscriberLimit))
        self.init(configuration: configuration, store: store)
    }

    /// Opens (and migrates) the store off the main actor, then creates the engine. Throws `ProjectionStore.OpenError`
    /// for a database that cannot be opened now (it is left unchanged; offer to try again).
    public static func make(configuration: EngineConfiguration) async throws -> Engine {
        let store = try await ProjectionStore.open(
            location: configuration.store, changes: ChangeBus(subscriberLimit: configuration.subscriberLimit))
        return Engine(configuration: configuration, store: store)
    }

    init(configuration: EngineConfiguration, store: ProjectionStore) {
        self.configuration = configuration
        self.store = store
        core = EngineCore(configuration: configuration, store: store)
        modelPreferences = ModelPreferencesModel(store: store, retryBackoff: configuration.writeRetryBackoff, time: configuration.time)
        frecency = FrecencyModel(store: store)
        terminals = TerminalService(store: store, client: { [core] in try await core.currentClient() })
        git = GitService(client: { [core] in try await core.currentClient() }, store: store)
        browser = BrowserBridgeService(
            store: store, client: { [core] in try await core.currentClient() },
            subscribe: { [core] in await core.subscribeBrowserControl() })
        environments = EnvironmentService(configuration: configuration.containers, store: store)
        if store.recovery != .none { root.setStorage(.recovered(store.recovery)) }
        if let containers = configuration.containers {
            // Terminals open in the project's container (bellocode-exec as the PTY command; never a host shell).
            terminals.launch = TerminalLaunch.container(helper: containers.helperURL, execConfig: containers.execConfigURL)
            let environments = self.environments
            git.worktrees.setupRunner = { script, worktree, project in
                try await environments.runSetup(script, in: worktree, projectDirectory: project)
            }
            environments.isolationContext = IsolationCheck.Context(
                client: { [core] in try await core.currentClient() }, helperPath: containers.helperURL.path,
                terminalEnvironment: terminals.launch.environment, gitShim: containers.gitShim?.path)
            let git = self.git
            environments.worktreeParent = { directory in git.cachedPreferences(projectDirectory: directory).parentDirectory(projectDirectory: directory) }
        }
        orchestration = OrchestrationService(core: core, store: store, engine: self)
        auto = AutoModeService(core: core, store: store, engine: self, reviewerModel: configuration.autoReviewerModel)
        codeRoots = configuration.codeRoots
        // Containerised execution owns the developer's code roots (Settings ▸ Containers ▸ Code roots): it provides them
        // to Auto and Full-access notices and says when they change.
        if configuration.containers != nil {
            environments.onCodeRootsChanged = { [weak self] in self?.refreshCodeRoots() }
            codeRootsProvider = environments
        }
        extras = ExtrasHub(core: core, store: store, engine: self, configuration: configuration)
        if configuration.containers != nil { extras.environments = environments }
        secretManager = SecretManager(store: store, vault: configuration.secretVault, legacy: extras.secrets, clock: configuration.wallClock,
                                      configuration: configuration.containers != nil ? configuration.secretManager : nil)
        secretManager.engine = self
        if configuration.containers != nil {
            secretManager.environments = environments
            let environments = self.environments
            secretManager.codeRoots = { environments.codeRootsValidation.roots }
        }
        extras.secretManager = secretManager
        let sharedBrowser = SharedBrowserService(store: store, configuration: configuration.sharedBrowser)
        sharedBrowser.environments = environments
        sharedBrowser.secrets = secretManager
        if configuration.sharedBrowser != nil {
            secretManager.routerOverride = { [weak sharedBrowser] fallback in sharedBrowser?.makeRouter(fallback: fallback) ?? fallback }
        }
        self.sharedBrowser = sharedBrowser
        openCodeConfig = OpenCodeConfigService.make(configuration: configuration, store: store, core: core)
        openCodeConfig.activeLocations = { [weak self] in self?.locationDirectories() ?? [] }
        models = ModelSettingsService.make(configuration: configuration, store: store, core: core)
        models.engine = self
        let mergeRequests = extras.mergeRequests
        secretManager.builtInBrokered = { [weak mergeRequests] in
            guard let mergeRequests else { return [] }
            return mergeRequests.instances.filter { mergeRequests.instancesWithToken.contains($0.baseURL) }.map { instance in
                BuiltInBrokeredSecret(label: "GitLab token", destination: instance.baseURL,
                                      operations: "GitLab API (merge requests, issues, pipelines) and git over HTTPS (credential helper)",
                                      problem: mergeRequests.instanceProblems[instance.baseURL])
            }
        }
        git.forgeInstances = { [weak mergeRequests] in mergeRequests?.instances ?? [] }
        git.tokenScopes = { [weak mergeRequests] base in mergeRequests?.instanceStatus[base]?.token?.scopes }
        gitProjects = GitProjectService(
            git: git, provider: { [weak mergeRequests] in mergeRequests?.provider },
            addProject: { [weak self] directory in await self?.addProject(directory: directory) })
        // Git parity: HTTPS git to the configured GitLab instances authenticates with the Keychain token through
        // `bellocode-exec --git-credential` (only with the bundled helper; tests configure their own).
        if let helper = configuration.gitCredentialHelper ?? configuration.containers?.helperURL,
           let broker = try? GitCredentialBroker(tokens: configuration.forgeTokens)
        {
            git.configureCredentials(GitCredentials(broker: broker, helperPath: helper.path))
            mergeRequests.onInstancesChanged = { [broker] instances in broker.setInstances(instances) }
            broker.setInstances(mergeRequests.instances)
        }
    }

    /// The model of a thread that is open now, without opening it.
    func loadedThread(_ id: SessionID) -> ThreadModel? { openThreads[id] }

    /// What to tell the user about local saving, if anything: database writes or model preferences failing, or a
    /// database set aside at launch. `label` is a short status ("Not saving"), `detail` the explanation.
    public var storageNotice: (label: String, detail: String)? {
        if root.storage == .writeFailing || modelPreferences.saveFailed, let detail = StorageStatus.writeFailing.message {
            return ("Not saving", detail)
        }
        if let detail = root.storage.message { return ("Local data set aside", detail) }
        return nil
    }

    /// Creates the provider sign-in service for this engine's server. Create one per app (Settings and onboarding share
    /// it) and call `shutdown()` before `stop()`.
    ///
    /// - Parameters:
    ///   - openURL: opens authorization pages in the default browser (`NSWorkspace.shared.open`).
    ///   - bundledExecutable: the bundled opencode used as the import client; defaults to the supervised server's.
    public func makeAuthService(openURL: @escaping URLOpener, bundledExecutable: URL? = nil) -> AuthService {
        let core = self.core
        var executable = bundledExecutable
        if executable == nil, case .supervised(let supervisor) = configuration.server {
            executable = supervisor.configuration.executableURL
        }
        let service = AuthService(
            client: { try await core.currentClient() },
            directory: { [weak self] in self?.root.catalog.current?.directory ?? self?.configuration.defaultDirectory },
            openURL: openURL, importer: executable.map { CredentialImporter(bundledExecutableURL: $0) })
        // Integration and credential events refresh the catalog; its revision refreshes the sign-in lists.
        service.refreshOnChange(of: { [weak self] in self?.root.catalog.revision ?? 0 })
        return service
    }

    /// Loads the cache into `root`, then connects. Returns once cached content is shown (it does not wait for the
    /// server).
    public func start() async {
        guard !started else { return }
        started = true
        // Every project's saved execution policy is in force before any project model can create, publish or use an
        // environment (S3 in docs/reviews/deep-review-1.md); the service also refuses until then.
        await environments.start()
        await installCheckpoints()
        await git.loadGlobalPreferences()
        subscribeRoot()
        if let snapshot = try? await core.loadCache() { applyLaunchSnapshot(snapshot) }
        // The helper's configuration exists before the server (and its shell) starts.
        await environments.writeConfigNow()
        // The plugin reads the trust file when each location is set up.
        await openCodeConfig.load()
        // The plugin reads the delegated-thread default at each delegate_task.
        await models.load()
        orchestration.start()
        await core.setCodeRoots(codeRoots)
        auto.start()
        await extras.start(store: store)
        await secretManager.start()
        sharedBrowser.engine = self
        await sharedBrowser.start()
        await modelPreferences.load()
        await frecency.load()
        await core.start()
        if environments.isEnabled {
            // The isolation self-check at engine start (configuration and runtime paths, no scratch thread): once the
            // server is live. Its report is shown in Settings and the runtime status item.
            tasks.set("isolation-check", Task { [weak self] in
                for _ in 0..<240 {
                    guard let self, !Task.isCancelled else { return }
                    if self.root.connection == .live { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard let self, !Task.isCancelled, self.root.connection == .live else { return }
                await self.environments.verifyIsolation()
            })
        }
    }

    /// Closes open threads, writes pending state, stops the event stream and (if supervised) the server.
    public func stop() async {
        await modelPreferences.flush()
        await frecency.flush()
        await terminals.shutdown()
        environments.stop()
        git.shutdown()
        await browser.shutdown()
        await orchestration.shutdown()
        auto.shutdown()
        extras.stop()
        // Before the egress proxy goes: the browser stops in order (its cookie store is committed).
        await sharedBrowser.shutdown()
        await secretManager.stop()
        for thread in Array(openThreads.values) { thread.tearDown() }
        openThreads.removeAll()
        for task in trackedTasks.values { await task.value }
        trackedTasks.removeAll()
        await core.stop()
        for model in root.projectModels.values { model.close() }
        tasks.cancelAll()
        root.setConnection(.stopped)
        started = false
    }

    // MARK: - Models

    /// The session list of a project (created if this project was not in the launch snapshot).
    public func project(_ id: ProjectID) async -> ProjectModel {
        if let model = root.projectModels[id] { return model }
        let (sessions, statuses) = await core.sessions(projectID: id)
        if let model = root.projectModels[id] { return model }
        let model = ProjectModel(projectID: id, sessions: sessions, statuses: statuses, core: core, store: store)
        root.projectModels[id] = model
        return model
    }

    /// Opens a thread: returns its model at once (filled from the cache within milliseconds, then reconciled with the
    /// server). The same instance is returned while it is open. Each call takes a lease that the caller releases with
    /// `ThreadModel.close()`; the model stays live until its last lease is released.
    public func openThread(_ id: SessionID) -> ThreadModel {
        if let model = openThreads[id] {
            model.acquireLease()
            return model
        }
        let model = ThreadModel(sessionID: id, core: core, store: store, engine: self)
        model.acquireLease()
        openThreads[id] = model
        let core = self.core
        track(Task { await core.openThread(id) })
        return model
    }

    func threadClosed(_ model: ThreadModel) {
        guard openThreads[model.sessionID] === model else { return }
        openThreads[model.sessionID] = nil
        let core = self.core
        let id = model.sessionID
        track(Task { await core.closeThread(id) })
    }

    /// Attachment files that sends not yet settled still need (pass to `AttachmentFileStore.cleanUp(keeping:)`).
    public func outboxAttachmentFiles() async -> Set<URL> { await core.outboxAttachmentFiles() }

    /// Keeps a short command task alive until it finishes, so `stop()` waits for it.
    func track(_ task: Task<Void, Never>) {
        nextTrackedID += 1
        let id = nextTrackedID
        trackedTasks[id] = task
        tasks.set(
            "track-\(id)",
            Task { [weak self] in
                await task.value
                self?.trackedTasks[id] = nil
                self?.tasks.remove("track-\(id)")
            })
    }

    // MARK: - Commands: threads

    /// Creates a thread in `directory`. It appears in the sidebar at once when the project is known.
    /// Creates a thread. With `permissionMode` the mode's rules are part of the create request and confirmed by the
    /// server before this returns (S2): a thread is never left running its first prompt under default rules.
    public func createThread(
        in directory: String, title: String? = nil, agent: String? = nil, model: ModelSelection? = nil,
        parent: SessionID? = nil, permissionMode: PermissionMode? = nil
    ) async throws -> Session {
        try await core.createSession(
            directory: directory, title: title, agent: agent, model: model, parentID: parent, permissionMode: permissionMode)
    }

    public func renameThread(_ id: SessionID, to title: String) async throws { try await core.renameSession(id, title: title) }

    /// Deletes on the server (not undoable there). The row disappears at once and returns if the server refuses.
    public func deleteThread(_ id: SessionID) async throws { try await core.deleteSession(id) }

    /// Archives or restores a thread (reversible; prefer this with Undo over delete).
    public func setArchived(_ id: SessionID, _ archived: Bool) async throws { try await core.setArchived(id, archived: archived) }

    /// Sends a prompt to a thread that may not be open. See `ThreadModel.send` for the open-thread variant.
    public func send(
        _ text: String, to id: SessionID, attachments: PromptAttachments = .none, delivery: PromptDelivery? = nil
    ) async throws -> MessageID {
        try await core.sendPrompt(id, text: text, attachments: attachments, delivery: delivery)
    }

    public func stop(_ id: SessionID) async throws { try await core.interrupt(id) }

    public func reply(to request: PermissionRequestID, _ reply: PermissionReply, message: String? = nil) async throws {
        let project = reply == .always ? await core.pendingSessionProject(request) : nil
        try await core.replyPermission(request, reply: reply, message: message)
        // A new saved scope: Auto re-reads the project's grants before its next decision.
        if let project { auto.grantsChanged(project) }
    }

    public func answer(_ question: QuestionID, _ answers: [String: QuestionAnswer]) async throws {
        try await core.replyQuestion(question, answers: answers)
    }

    public func markViewed(_ id: SessionID) async throws { try await core.markViewed(id) }
    public func setModel(_ model: ModelSelection, for id: SessionID) async throws { try await core.setModel(id, model: model) }
    public func setAgent(_ agent: String, for id: SessionID) async throws { try await core.setAgent(id, agent: agent) }
    public func setPermissionMode(_ mode: PermissionMode, for id: SessionID) async throws {
        try await core.setPermissionMode(id, mode: mode)
    }

    // MARK: - Commands: projects

    /// Adds a folder to the sidebar (or restores a hidden one).
    public func addProject(directory: String) async { await core.addProject(directory: directory) }
    /// Hides a project from the sidebar; reversible with `addProject`.
    public func removeProject(directory: String) async { await core.removeProject(directory: directory) }
    public func setProjectPinned(directory: String, _ pinned: Bool) async { await core.setProjectPinned(directory: directory, pinned: pinned) }
    public func moveProject(directory: String, to index: Int) async { await core.moveProject(directory: directory, to: index) }

    // MARK: - Queries

    /// Full-text search over cached message text.
    public func search(_ query: String, limit: Int = 50) async throws -> [SearchHit] {
        try await core.search(query, limit: limit)
    }

    /// Re-reads the provider, model and agent catalog for a location.
    public func refreshCatalog(directory: String) async { await core.refreshCatalog(directory: directory) }

    /// Re-reads every location's catalog (credentials and the default model are server-wide).
    public func refreshAllCatalogs() async { await core.refreshAllCatalogs() }

    /// Waits until every buffered stream delta is published and every pending write is on disk (tests, shutdown).
    public func flush() async { await core.flush() }

    // MARK: - Wiring

    private func applyLaunchSnapshot(_ snapshot: EngineSnapshot) {
        let signpost = EngineSignposts.publish.beginInterval("launchSnapshot")
        defer { EngineSignposts.publish.endInterval("launchSnapshot", signpost) }
        root.setProjects(snapshot.projects, registry: snapshot.registry)
        environments.projectsChanged(root.projects)
        root.setAttention(snapshot.attention)
        root.organisation = snapshot.organisation
        root.organisationRules = snapshot.organisationRules
        let byProject = Dictionary(grouping: snapshot.sessions, by: \.projectID)
        for (projectID, sessions) in byProject where root.projectModels[projectID] == nil {
            root.projectModels[projectID] = ProjectModel(
                projectID: projectID, sessions: sessions, statuses: snapshot.statuses, core: core, store: store)
        }
        for item in root.projects {
            if let id = item.projectID, root.projectModels[id] == nil {
                root.projectModels[id] = ProjectModel(projectID: id, sessions: [], statuses: [:], core: core, store: store)
            }
        }
        defaultDirectory = configuration.defaultDirectory ?? root.projects.first?.directory
        for catalog in snapshot.catalogs { root.catalog.apply(catalog, isDefault: catalog.directory == defaultDirectory) }
    }

    /// On every (re)connect: check the plugin and serve the app tools for the visible projects.
    private func connectOrchestration() {
        let directories = root.projects.map(\.directory)
        let orchestration = self.orchestration!
        track(
            Task {
                if let first = directories.first ?? self.configuration.defaultDirectory { await orchestration.checkPlugin(directory: first) }
                await orchestration.hostAppTools(directories: directories)
                await self.sharedBrowser.hostTools(directories: directories)
            })
        // Project MCP servers are runtime registrations: a (re)connected server has none.
        environments.serverConnected()
    }

    private func subscribeRoot() {
        let topics: [(String, ChangeTopic)] = [
            ("projects", .projects), ("attention", .attention), ("catalog", .catalog), ("connection", .connection),
            ("organisation", .organisation),
        ]
        for (key, topic) in topics {
            let subscription = store.observe(topic)
            tasks.set(
                key,
                Task { [weak self] in
                    for await change in subscription {
                        guard let self else { return }
                        self.applyRoot(change)
                    }
                })
        }
    }

    private func applyRoot(_ change: ChangeSet) {
        if let connection = change.connection {
            let wasLive = root.connection.isLive
            root.setConnection(connection)
            if connection.isLive, !wasLive { connectOrchestration() }
        }
        if let storage = change.storage { root.setStorage(storage) }
        if let gaps = change.syncGaps { root.setSyncGaps(gaps) }
        if let summary = change.attention { root.setAttention(summary) }
        if !change.organisation.isEmpty {
            var next = root.organisation
            for (id, value) in change.organisation { next[id] = value == .none ? nil : value }
            if next != root.organisation { root.organisation = next }
        }
        if let catalog = change.catalog {
            defaultDirectory = defaultDirectory ?? root.projects.first?.directory
            root.catalog.apply(catalog, isDefault: catalog.directory == defaultDirectory)
        }
        if !change.projects.isEmpty || !change.removedProjects.isEmpty || !change.registry.isEmpty
            || !change.removedRegistry.isEmpty
        {
            root.apply(projectsChange: change)
            environments.projectsChanged(root.projects)
            for item in root.projects {
                if let id = item.projectID, root.projectModels[id] == nil {
                    root.projectModels[id] = ProjectModel(projectID: id, sessions: [], statuses: [:], core: core, store: store)
                    let model = root.projectModels[id]!
                    let core = self.core
                    track(
                        Task { [weak model] in
                            let (sessions, statuses) = await core.sessions(projectID: id)
                            model?.seed(sessions: sessions, statuses: statuses)
                        })
                }
            }
        }
        if change.overflowed {
            let core = self.core
            track(
                Task { [weak self] in
                    let snapshot = await core.snapshot()
                    guard let self else { return }
                    self.root.setProjects(snapshot.projects, registry: snapshot.registry)
                    self.environments.projectsChanged(self.root.projects)
                    self.root.setAttention(snapshot.attention)
                    self.root.setConnection(snapshot.connection)
                    self.root.setSyncGaps(snapshot.syncGaps)
                    if self.root.organisation != snapshot.organisation { self.root.organisation = snapshot.organisation }
                })
        }
    }
}

extension ProjectModel {
    /// Fills a model created before its sessions were read (rows already present are kept).
    func seed(sessions: [Session], statuses: [SessionID: SessionAttention]) {
        var change = ChangeSet()
        for session in sessions { change.sessions[session.id] = session }
        change.statuses = statuses
        apply(change)
    }
}

extension Engine {
    /// The directories opencode may hold as locations: every project and its threads' directories (bounded).
    func locationDirectories() -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        let sessions = root.loadedProjects.flatMap { project in project.sessionIDs.compactMap { project.row($0)?.session.directory } }
        for directory in root.projects.map(\.directory) + sessions where !directory.isEmpty && result.count < 512 && seen.insert(directory).inserted {
            result.append(directory)
        }
        return result
    }
}
