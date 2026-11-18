import BelloCore
import ContainerKit
import Foundation
import Observation
import OpenCodeKit
import os

/// Where containerised execution plugs into the app (docs/features/containers.md). Set by the app for the bundled
/// server; nil in mock mode and most tests (the service then reports itself off and never touches a runtime).
public struct ContainerConfiguration: Sendable {
    /// `Contents/Helpers/bellocode-exec`.
    public var helperURL: URL
    /// Where the helper's configuration is written (`BELLOCODE_EXEC_CONFIG`).
    public var execConfigURL: URL
    /// The supervised server's `XDG_DATA_HOME` (opencode keeps its worktrees in `<this>/opencode/worktree/<id6>`).
    public var opencodeDataDirectory: URL?
    /// The runtime; `LiveWorkspaceRuntime` in the app.
    public var runtime: any WorkspaceRuntime
    /// Registry passwords (Keychain service `app.bellocode.registry`, account = registry host).
    public var registryVault: any SecretVault
    /// How often the runtime is checked while it is not ready / while it is.
    public var pollWhileDown: Duration = .seconds(4)
    public var pollWhileUp: Duration = .seconds(30)
    /// How often idle containers are looked for.
    public var idleCheckInterval: Duration = .seconds(60)
    /// The `git` shim first on the server's PATH (opencode's host git, confined by `HostGit`); probed by the self-check.
    public var gitShim: URL?
    /// The administrator's image policy (managed preferences), read at start and when Settings asks.
    public var managedPolicy: @Sendable () -> ManagedImagePolicy.Managed? = { ManagedImagePolicy.read() }

    public init(helperURL: URL, execConfigURL: URL, opencodeDataDirectory: URL?, runtime: any WorkspaceRuntime,
                registryVault: any SecretVault = KeychainSecretVault(service: "app.bellocode.registry")) {
        self.helperURL = helperURL
        self.execConfigURL = execConfigURL
        self.opencodeDataDirectory = opencodeDataDirectory
        self.runtime = runtime
        self.registryVault = registryVault
    }
}

/// One project's environment: its setting, where its container stands, its ports and forwards.
///
/// Threading: `@MainActor`, owned by `EnvironmentService`; values only (all container work happens in the service's
/// tasks off the main actor).
@MainActor
@Observable
public final class ProjectEnvironment {
    public let directory: String
    public internal(set) var settings: ProjectEnvironmentSettings
    public internal(set) var record: EnvironmentRecord
    public internal(set) var phase: EnvironmentPhase = .unknown
    /// The image actually used (the project's or the app default), nil when neither is set.
    public internal(set) var image: String?
    /// Why the running container is out of date (shown in details); it is recreated on next use.
    public internal(set) var outdatedReason: String?
    public internal(set) var ports: [ListeningPort] = []
    public internal(set) var portsUpdated: Date?
    public internal(set) var forwards: [PortForwardInfo] = []
    /// The last stray-process cleanup: how many and when.
    public internal(set) var lastReap: (count: Int, date: Date)?
    public internal(set) var lastActivity: Date?
    /// The last failure of an action started from the UI (pull, rebuild, forward), cleared by the next success.
    public internal(set) var lastError: String?
    /// File-watch bridge counters (Environment pane, measurements).
    public internal(set) var bridgeStats: FileEventBridge.Stats?
    /// The project's MCP servers as opencode reports them for its location (Environment pane).
    public internal(set) var mcpStatus: [MCPServerStatus] = []
    /// The project's services (compose file or the pane) and where each stands.
    public internal(set) var services: [ServiceState] = []
    public internal(set) var servicesSource: ServicesSource = .none
    /// The parsed definition with its ignored and rejected keys (shown in the pane).
    public internal(set) var servicesParse: ComposeParseResult?
    public internal(set) var serviceForwards: [ServiceForwardInfo] = []
    /// The project's opencode ID (names opencode's worktree folder).
    @ObservationIgnored var projectID: ProjectID?
    @ObservationIgnored var extraWorktrees: [String] = []

    init(directory: String, stored: StoredEnvironment) {
        self.directory = directory
        settings = stored.settings
        record = stored.record
    }

    /// The banner for threads and terminals in this project, or nil while commands can run.
    public var notice: EnvironmentNotice? { EnvironmentNotice.from(phase) }
    public var projectKey: String { WorkspaceSpec.projectKey(for: directory) }
    public var containerName: String { WorkspaceSpec.containerName(for: directory) }
}

/// Containerised execution for every project (docs/features/containers.md): the runtime's state, each project's
/// workspace container (created on first use, stopped when idle, recreated when the setting, the image or the project
/// folder changes; its volumes are deleted only by the explicit, confirmed purge), the helper's configuration file, idle stop and the stray-process
/// reaper, the Ports list and its forwards, the file-watch bridge, secrets and setup scripts run in a container, and
/// the isolation self-check. Never falls back to the host: every state that cannot run commands is written to the
/// helper's configuration as a specific, actionable message and published as a banner.
///
/// Threading: `@MainActor` state; runtime calls run in tasks owned by this service (cancelled by `stop()`), off the
/// main actor, and hand back `Sendable` values. A refresh applies only if it is the newest for its project
/// (generation check).
@MainActor
@Observable
public final class EnvironmentService {
    /// Nil while the first check runs.
    public private(set) var runtime: RuntimeState?
    public private(set) var defaults = EnvironmentDefaults()
    /// The last isolation self-check (at engine start and on demand).
    public internal(set) var isolation: IsolationReport?
    public internal(set) var isVerifyingIsolation = false
    /// False without a container configuration (mock mode, tests): the app then shows "Container execution is off".
    public let isEnabled: Bool

    @ObservationIgnored let configuration: ContainerConfiguration?
    @ObservationIgnored private let store: ProjectionStore
    @ObservationIgnored var models: [String: ProjectEnvironment] = [:]
    @ObservationIgnored let tasks = TaskBox()
    /// Project MCP servers registered with opencode, per location (`MCPServers.swift`).
    @ObservationIgnored var registeredMCP: [String: [String: JSONValue]] = [:]
    @ObservationIgnored var serviceForwarders: [String: [String: PortForwarder]] = [:]
    /// The administrator's policy (managed preferences), nil when none is managed.
    public private(set) var managedPolicy: ManagedImagePolicy.Managed?
    /// Images BelloCode pulled that were not on this Mac before (image IDs): "Prune" may remove them when unused.
    @ObservationIgnored var pulledImageIDs: Set<String> = []
    @ObservationIgnored private var generations: [String: Int] = [:]
    @ObservationIgnored private var forwarders: [String: [Int: PortForwarder]] = [:]
    @ObservationIgnored private var bridges: [String: FileEventBridge] = [:]
    @ObservationIgnored private var bridgeContainers: [String: String] = [:]
    @ObservationIgnored private var started = false
    /// True once every project's saved policy is in force (S3). Before that nothing is created, published or run.
    @ObservationIgnored private(set) var settingsLoaded = false
    /// The whole settings table could not be read: every project is blocked (never run under defaults).
    @ObservationIgnored private var policyReadFailure: String?
    /// Projects whose saved row could not be decoded: blocked until the person saves the setting again.
    @ObservationIgnored private var unreadablePolicies: Set<String> = []
    /// Why the helper's configuration could not be saved (commands are refused meanwhile); nil when it is current.
    public private(set) var helperConfigProblem: String?
    /// This launch's identity in the helper's files: a configuration from an earlier launch never authorises a command.
    @ObservationIgnored let configEpoch = UUID().uuidString
    /// Serialised writes: each queued write awaits the previous one, so files land in generation order (S4).
    @ObservationIgnored private var writeChain: Task<Void, Never>?
    @ObservationIgnored private var queuedWrite: Task<Void, Never>?
    @ObservationIgnored private var configGeneration = 0
    /// The configuration (without epoch and generation) known to be on disk, and its generation.
    @ObservationIgnored private var installedConfig: ExecHelperConfig?
    @ObservationIgnored private(set) var installedGeneration = 0
    /// Where the helper's files go (atomic, 0600). Tests inject failures and delays.
    @ObservationIgnored var fileSink: @Sendable (Data, URL) async throws -> Void = { data, url in
        try await EnvironmentService.writeFile(data, to: url)
    }
    @ObservationIgnored var configRetryDelay: Duration = .seconds(2)
    @ObservationIgnored var worktreeParent: @MainActor (String) -> String = { directory in
        (NSHomeDirectory() as NSString).appendingPathComponent(".bellocode/worktrees/\((directory as NSString).lastPathComponent)")
    }
    @ObservationIgnored var gitWorktrees: @Sendable (String) async -> [String] = { _ in [] }
    /// The isolation self-check's server access (set by the engine).
    @ObservationIgnored var isolationContext: IsolationCheck.Context?
    @ObservationIgnored nonisolated static let log = Logger(subsystem: "app.bellocode", category: "containers")
    @ObservationIgnored private nonisolated static let signposter = OSSignposter(subsystem: "app.bellocode.engine", category: "containers")

    public init(configuration: ContainerConfiguration?, store: ProjectionStore) {
        self.configuration = configuration
        self.store = store
        isEnabled = configuration != nil
    }

    // MARK: Lifecycle

    /// Loads settings, then checks the runtime and follows its events. Returns once every project's saved execution
    /// policy is in force. A model created before (a project list applied earlier, a pane asking) gets its saved
    /// setting now, replacing the placeholder; a read failure blocks commands instead of applying defaults (S3).
    public func start() async {
        guard !started else { return }
        started = true
        do {
            let (stored, unreadable) = try await store.environmentsChecked()
            unreadablePolicies = unreadable
            for directory in unreadable where models[directory] == nil {
                models[directory] = ProjectEnvironment(directory: directory, stored: StoredEnvironment())
            }
            for (directory, value) in stored {
                if let model = models[directory] {
                    model.settings = value.settings
                    model.record = value.record
                } else {
                    models[directory] = ProjectEnvironment(directory: directory, stored: value)
                }
            }
        } catch {
            policyReadFailure = "BelloCode could not read the saved environment settings (\(error)), so commands are not run under default settings. Restart BelloCode; if this persists, open Settings ▸ Environment."
        }
        if let saved = try? await store.preference(EnvironmentDefaults.preferenceKey, as: EnvironmentDefaults.self) { defaults = saved }
        if let pulled = try? await store.preference(Self.pulledImagesKey, as: [String].self) { pulledImageIDs = Set(pulled) }
        managedPolicy = configuration?.managedPolicy()
        settingsLoaded = true
        for model in models.values { refreshImageAndPhase(model) }
        guard isEnabled else { return }
        tasks.set("runtime", Task { [weak self] in await self?.runtimeLoop() })
        tasks.set("idle", Task { [weak self] in await self?.idleLoop() })
    }

    /// Why the project's saved policy is not in force, or nil when it is.
    func policyBlock(_ model: ProjectEnvironment) -> String? {
        if !settingsLoaded { return "BelloCode is still loading this project's environment settings. Retry in a moment." }
        if let policyReadFailure { return policyReadFailure }
        if unreadablePolicies.contains(model.directory) {
            return "This project's saved environment settings could not be read, so commands are not run under default settings. Review and save them in Project Settings ▸ Environment."
        }
        return nil
    }

    /// Stops forwards, bridges and loops. Containers keep running (they stop when idle or with Rancher Desktop).
    public func stop() {
        tasks.cancelAll()
        queuedWrite?.cancel()
        writeChain?.cancel()
        for (_, ports) in forwarders { for forwarder in ports.values { forwarder.stop() } }
        forwarders.removeAll()
        for bridge in bridges.values { bridge.stop() }
        bridges.removeAll()
        started = false
    }

    // MARK: Models

    /// The environment of the project containing `directory` (a project folder or one of its worktrees).
    public func environment(for directory: String) -> ProjectEnvironment {
        if let model = project(containing: directory) { return model }
        let model = ProjectEnvironment(directory: directory, stored: StoredEnvironment())
        models[directory] = model
        refreshImageAndPhase(model)
        return model
    }

    /// The project whose folder or worktree folders contain `path`, if known.
    public func project(containing path: String) -> ProjectEnvironment? {
        let standardized = (path as NSString).standardizingPath
        if let model = models[standardized] { return model }
        return models.values
            .filter { model in workspaceRoots(model, create: false).contains { standardized == $0 || standardized.hasPrefix($0 + "/") } }
            .max { $0.directory.count < $1.directory.count }
    }

    public var environments: [ProjectEnvironment] { models.values.sorted { $0.directory < $1.directory } }

    /// Called by the engine when the project list changes: known projects get a model. Archiving (hiding) a project
    /// only changes what the sidebar shows: its container, volumes, forwards and settings are untouched (U1 in
    /// docs/reviews/deep-review-1.md). Deleting them is the separate, confirmed `purge`.
    func projectsChanged(_ projects: [ProjectItem]) {
        for item in projects {
            var created = false
            let model = models[item.directory] ?? {
                let model = ProjectEnvironment(directory: item.directory, stored: StoredEnvironment())
                models[item.directory] = model
                created = true
                return model
            }()
            if model.projectID != item.projectID || created {
                model.projectID = item.projectID
                if started { refreshImageAndPhase(model) }
            }
        }
        guard isEnabled else { return }
        scheduleConfigWrite()
    }

    // MARK: Settings

    public func setDefaults(_ value: EnvironmentDefaults) async {
        let socketChanged = value.socketOverride != defaults.socketOverride
        defaults = value
        try? await store.setPreference(EnvironmentDefaults.preferenceKey, value)
        if socketChanged { await recheckRuntime() }
        for model in models.values { refreshImageAndPhase(model) }
        scheduleConfigWrite()
    }

    /// Saves a project's setting. A change that alters the container recreates it (running commands stop: the pane
    /// says so before saving).
    public func update(_ directory: String, settings: ProjectEnvironmentSettings) async {
        let model = environment(for: directory)
        guard model.settings != settings else { return }
        model.settings = settings
        model.lastError = nil
        if case .pullFailed = model.phase { model.phase = .unknown }
        await persist(model)
        // The person reviewed and saved the setting: it is the policy now (an unreadable row is replaced).
        unreadablePolicies.remove(model.directory)
        refreshImageAndPhase(model, recreate: true)
        restartBridge(model)
        scheduleConfigWrite()
        if model.phase == .ready {
            syncMCPServers(model)
            startServices(model)
        }
    }

    private func persist(_ model: ProjectEnvironment) async {
        try? await store.saveEnvironment(StoredEnvironment(settings: model.settings, record: model.record), directory: model.directory)
    }

    // MARK: Runtime

    /// Checks the runtime now (the banner's Retry).
    public func recheckRuntime() async {
        guard let runtime = configuration?.runtime else { return }
        let state = await runtimeFor(defaults).detect()
        _ = runtime
        apply(runtime: state)
    }

    private func runtimeFor(_ defaults: EnvironmentDefaults) -> any WorkspaceRuntime {
        guard let configuration else { fatalError("container execution is off") }
        if let override = defaults.socketOverride, override != configuration.runtime.socketPath,
           configuration.runtime is LiveWorkspaceRuntime {
            return LiveWorkspaceRuntime(socketOverride: override)
        }
        return configuration.runtime
    }

    var activeRuntime: any WorkspaceRuntime { runtimeFor(defaults) }

    private func runtimeLoop() async {
        guard let configuration else { return }
        while !Task.isCancelled {
            let state = await activeRuntime.detect()
            apply(runtime: state)
            try? await Task.sleep(for: state.isReady ? configuration.pollWhileUp : configuration.pollWhileDown)
        }
    }

    private func apply(runtime state: RuntimeState) {
        let wasReady = runtime?.isReady ?? false
        if runtime != state { runtime = state }
        if state.isReady && !wasReady {
            tasks.set("events", Task { [weak self] in await self?.followEvents() })
            // Secret-command containers a crash left behind (their command had the value in its environment).
            let runtime = activeRuntime
            tasks.set("secret-leftovers", Task { await runtime.removeLeftoverSecretContainers() })
            for model in models.values { refreshImageAndPhase(model) }
        } else if !state.isReady {
            tasks.set("events", Task {})
            for model in models.values {
                model.phase = .runtimeUnavailable(state)
                stopForwards(model)
                bridges.removeValue(forKey: model.directory)?.stop()
            }
        }
        scheduleConfigWrite()
    }

    /// Engine events: (re)connects and overflows rebuild every project's phase from the list endpoints (a reconnect is
    /// not a replay); container start/die/destroy refresh one project; exec activity keeps containers from idling.
    private func followEvents() async {
        for await event in activeRuntime.events() {
            if Task.isCancelled { return }
            switch event {
            case .connected, .overflow:
                for model in models.values { refreshImageAndPhase(model) }
            case .disconnected:
                continue
            case .event(let event):
                handle(event)
            }
        }
    }

    private func handle(_ event: EngineEvent) {
        guard let name = event.attributes["name"], name.hasPrefix("bellocode-ws-"),
              let model = models.values.first(where: { $0.containerName == name }) else { return }
        let action = event.action.split(separator: ":").first.map(String.init) ?? event.action
        switch action {
        case "exec_start", "exec_create":
            model.lastActivity = Date()
        case "exec_die":
            model.lastActivity = Date()
            scheduleReap(model)
        case "start", "die", "stop", "destroy", "kill", "oom":
            refreshImageAndPhase(model)
        default:
            break
        }
    }

    // MARK: Phase

    /// Recomputes a project's phase from the runtime (image present? container status?). Starts a pull when the image
    /// is configured but missing (the configured image only; there is no built-in default). With `recreate`, an
    /// outdated running container is replaced now (a setting change).
    func refreshImageAndPhase(_ model: ProjectEnvironment, recreate: Bool = false) {
        model.image = model.settings.image ?? defaultImage
        guard isEnabled, started else { return }
        loadServices(model)
        if let message = policyBlock(model) {
            if settingsLoaded { model.phase = .policyUnavailable(message) }
            scheduleConfigWrite()
            return
        }
        if case .policyUnavailable = model.phase { model.phase = .unknown }
        if let image = model.image, let refusal = imageRefusal(image) {
            model.phase = .imageRefused(refusal)
            bridges.removeValue(forKey: model.directory)?.stop()
            scheduleConfigWrite()
            return
        }
        if case .imageRefused = model.phase { model.phase = .unknown }
        guard let runtime, runtime.isReady else {
            if let runtime { model.phase = .runtimeUnavailable(runtime) }
            scheduleConfigWrite()
            return
        }
        guard model.image != nil else {
            model.phase = .noImage
            scheduleConfigWrite()
            return
        }
        if model.phase == .noImage { model.phase = .unknown }
        if case .pulling = model.phase { return }
        if case .pullFailed = model.phase, !recreate { return }
        let generation = nextGeneration(model.directory)
        let spec = workspaceSpec(model)
        let runtimeRef = activeRuntime
        tasks.set("refresh-\(model.projectKey)", Task { [weak self] in
            guard let spec else { return }
            do {
                let image = try await runtimeRef.image(spec.image)
                guard let self, self.generations[model.directory] == generation, !Task.isCancelled else { return }
                guard let image else {
                    if self.imagePolicy.pullPolicy == .never {
                        model.phase = .imageRefused("The image \(spec.image) is not on this Mac, and the image policy does not allow pulling. Load it by other means, or ask your administrator.")
                        self.scheduleConfigWrite()
                        return
                    }
                    self.pull(model)
                    return
                }
                model.record.imageID = image.id
                model.record.imageDigest = image.repoDigests?.first
                let declared = PackageCache.declared(byImageLabels: image.labels)
                if (model.record.imageCaches ?? [:]) != declared {
                    model.record.imageCaches = declared
                    // The caches are part of the spec: compute it again with them.
                    if let updated = self.workspaceSpec(model), updated != spec {
                        self.refreshImageAndPhase(model, recreate: recreate)
                        return
                    }
                }
                let unmountable = spec.unmountablePaths()
                guard unmountable.isEmpty else {
                    model.phase = .unmountable(unmountable)
                    self.scheduleConfigWrite()
                    return
                }
                let status = try await runtimeRef.status(spec)
                guard self.generations[model.directory] == generation, !Task.isCancelled else { return }
                model.outdatedReason = status.outdatedReason
                if let id = status.containerID { model.record.containerID = id }
                switch status.phase {
                case .running: model.phase = .ready
                case .outdated where recreate:
                    self.activate(model.directory)
                    return
                case .outdated:
                    // Still running (commands work); replaced on the next activation, with the reason in details.
                    model.phase = status.containerID == nil ? .idle : .ready
                default: model.phase = .idle
                }
                if model.phase == .ready {
                    self.restartBridge(model)
                    // Idempotent and cheap without servers; reconnects servers an idle stop or recreate ended.
                    self.syncMCPServers(model)
                    // The container was started outside the app (a command through the helper): services follow it.
                    if model.services.contains(where: { $0.phase == .notStarted }) { self.startServices(model) }
                } else {
                    self.bridges.removeValue(forKey: model.directory)?.stop()
                }
                self.scheduleConfigWrite()
            } catch {
                guard let self, self.generations[model.directory] == generation else { return }
                model.phase = .failed(Self.describe(error))
                self.scheduleConfigWrite()
            }
        })
    }

    private func nextGeneration(_ directory: String) -> Int {
        let value = (generations[directory] ?? 0) + 1
        generations[directory] = value
        return value
    }

    /// Creates or starts the project's container now (a thread in the project is shown, a terminal opens, a setting
    /// changed). Idempotent; a no-op while blocked.
    public func activate(_ directory: String) {
        guard isEnabled, let runtime, runtime.isReady else { return }
        let model = environment(for: directory)
        guard policyBlock(model) == nil else { return }
        guard let spec = workspaceSpec(model) else {
            if model.image == nil { model.phase = .noImage }
            return
        }
        switch model.phase {
        case .ready where model.outdatedReason == nil, .pulling, .noImage, .unmountable, .pullFailed, .runtimeUnavailable, .starting, .imageRefused:
            return
        default:
            break
        }
        model.phase = .starting
        let generation = nextGeneration(model.directory)
        let runtimeRef = activeRuntime
        let firstInventory = model.record.inventory == nil || model.outdatedReason != nil
        // Pull policy "always": fetch the image again before (re)creating, so a moved tag is followed.
        let pullFirst = imagePolicy.pullPolicy == .always && (model.record.containerID == nil || model.outdatedReason != nil || model.phase == .idle)
        let auth = pullFirst ? registryAuth(for: spec.image) : nil
        tasks.set("activate-\(model.projectKey)", Task { [weak self] in
            let interval = Self.signposter.beginInterval("ensureRunning")
            defer { Self.signposter.endInterval("ensureRunning", interval) }
            do {
                if pullFirst { try await runtimeRef.pull(spec.image, auth: auth) { _ in } }
                let id = try await runtimeRef.ensureRunning(spec)
                var inventory: ContainerProbes.ToolInventory?
                if firstInventory { inventory = try? await runtimeRef.inventory(container: id, user: spec.user) }
                guard let self, self.generations[model.directory] == generation, !Task.isCancelled else { return }
                model.record.containerID = id
                model.record.mountIdentity = spec.mountIdentity()
                model.record.lastUsed = Date()
                if let inventory { model.record.inventory = inventory }
                model.outdatedReason = nil
                model.phase = .ready
                model.lastActivity = Date()
                model.lastError = nil
                await self.persist(model)
                self.restartBridge(model)
                self.scheduleConfigWrite()
                self.syncMCPServers(model)
                self.startServices(model)
            } catch {
                guard let self, self.generations[model.directory] == generation else { return }
                if case WorkspaceError.unmountable(let paths) = error { model.phase = .unmountable(paths) } else {
                    model.phase = .failed(Self.describe(error))
                }
                self.scheduleConfigWrite()
            }
        })
    }

    // MARK: Actions

    /// Pulls the project's image with progress (the configured image; credentials from the Keychain, in the request
    /// header only). On success the container is created on first use.
    public func pull(_ model: ProjectEnvironment) {
        guard isEnabled, policyBlock(model) == nil, let image = model.image else { return }
        if let refusal = imageRefusal(image) {
            model.phase = .imageRefused(refusal)
            scheduleConfigWrite()
            return
        }
        let auth = registryAuth(for: image)
        model.phase = .pulling(PullProgress(detail: "starting"))
        model.lastError = nil
        scheduleConfigWrite()
        let generation = nextGeneration(model.directory)
        let runtimeRef = activeRuntime
        let aggregator = PullAggregator()
        tasks.set("pull-\(model.projectKey)", Task { [weak self] in
            let interval = Self.signposter.beginInterval("pull")
            defer { Self.signposter.endInterval("pull", interval) }
            let ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, self.generations[model.directory] == generation else { return }
                    if case .pulling = model.phase { model.phase = .pulling(aggregator.progress) }
                }
            }
            defer { ticker.cancel() }
            do {
                let present = (try? await runtimeRef.image(image)) != nil
                try await runtimeRef.pull(image, auth: auth) { aggregator.add($0) }
                if !present { self?.recordPulled(image) }
                guard let self, self.generations[model.directory] == generation else { return }
                model.phase = .idle
                self.refreshImageAndPhase(model, recreate: true)
                self.activate(model.directory)
            } catch {
                guard let self, self.generations[model.directory] == generation else { return }
                let containerError = ContainerError.from(error)
                model.phase = .pullFailed(message: Self.describe(error), needsSignIn: containerError.needsRegistrySignIn)
                model.lastError = Self.describe(error)
                self.scheduleConfigWrite()
            }
        })
    }

    /// Pulls the image again and recreates the container ("Rebuild").
    public func rebuild(_ directory: String) {
        let model = environment(for: directory)
        model.outdatedReason = "rebuild requested"
        pull(model)
    }

    /// Retries whatever is blocking (the banner's Retry): re-checks the runtime, retries a failed pull, re-activates.
    public func retry(_ directory: String) async {
        reloadManagedPolicy()
        await recheckRuntime()
        let model = environment(for: directory)
        if case .pullFailed = model.phase { pull(model); return }
        if case .failed = model.phase { model.phase = .idle }
        refreshImageAndPhase(model)
        activate(directory)
    }

    public func stopContainer(_ directory: String) {
        let model = environment(for: directory)
        guard let id = model.record.containerID else { return }
        stopForwards(model)
        bridges.removeValue(forKey: model.directory)?.stop()
        let runtimeRef = activeRuntime
        tasks.set("stop-\(model.projectKey)", Task { [weak self] in
            do { try await runtimeRef.stop(container: id) } catch { model.lastError = Self.describe(error) }
            self?.refreshImageAndPhase(model)
        })
    }

    public func restartContainer(_ directory: String) {
        let model = environment(for: directory)
        guard let id = model.record.containerID else { return activate(directory) }
        stopForwards(model)
        let runtimeRef = activeRuntime
        model.phase = .starting
        tasks.set("restart-\(model.projectKey)", Task { [weak self] in
            do { try await runtimeRef.restart(container: id) } catch { model.lastError = Self.describe(error) }
            self?.refreshImageAndPhase(model)
        })
    }

    /// Removes the project's container (never its volumes: caches and $HOME stay). It is created again on next use.
    public func removeContainer(_ directory: String) {
        let model = environment(for: directory)
        stopForwards(model)
        bridges.removeValue(forKey: model.directory)?.stop()
        let key = model.projectKey
        let runtimeRef = activeRuntime
        tasks.set("remove-\(key)", Task { [weak self] in
            do { try await runtimeRef.remove(projectKey: key) } catch { model.lastError = Self.describe(error) }
            model.record.containerID = nil
            self?.refreshImageAndPhase(model)
        })
    }

    /// What "Delete Container and Data…" would delete for the project: shown in its confirmation (it cannot be undone).
    public func storageToPurge(_ directory: String) async throws -> WorkspaceStorage {
        guard isEnabled else { throw EnvironmentBlockedError(message: "Container execution is off in this build.") }
        return try await activeRuntime.storage(projectKey: environment(for: directory).projectKey)
    }

    /// The explicit destructive action: removes the project's containers and exactly the volumes the person confirmed
    /// (its persistent $HOME and caches). The only path in the app that deletes a volume. Throws when the runtime
    /// refuses; the pane shows the error.
    public func purge(_ directory: String, confirmed storage: WorkspaceStorage) async throws {
        let model = environment(for: directory)
        guard storage.projectKey == model.projectKey else {
            throw EnvironmentBlockedError(message: "The confirmed list belongs to another project; nothing was deleted.")
        }
        stopForwards(model)
        bridges.removeValue(forKey: model.directory)?.stop()
        _ = nextGeneration(model.directory)
        tasks.set("refresh-\(model.projectKey)", Task {})
        tasks.set("activate-\(model.projectKey)", Task {})
        do {
            try await activeRuntime.purge(storage)
        } catch {
            model.lastError = Self.describe(error)
            refreshImageAndPhase(model)
            throw error
        }
        model.record.containerID = nil
        model.record.inventory = nil
        model.phase = .idle
        await persist(model)
        refreshImageAndPhase(model)
    }

    /// Removes the project's container and waits for it (tests, `make smoke`).
    public func removeContainerNow(_ directory: String) async {
        removeContainer(directory)
        await tasks.take("remove-\(environment(for: directory).projectKey)")?.value
    }

    /// BelloCode-managed containers (Containers view), with their project when known.
    public func managedContainers() async -> [ManagedContainer] {
        guard isEnabled, runtime?.isReady == true else { return [] }
        let summaries = (try? await activeRuntime.managedContainers()) ?? []
        return summaries.map { summary in
            ManagedContainer(
                id: summary.id, name: summary.name, image: summary.labels[WorkspaceSpec.labelImage] ?? summary.image,
                state: summary.state, status: summary.status ?? summary.state,
                projectDirectory: summary.labels[WorkspaceSpec.labelProject],
                created: summary.created.map { Date(timeIntervalSince1970: TimeInterval($0)) }, service: summary.labels[ServiceLabels.service])
        }.sorted { ($0.projectDirectory ?? $0.name, $0.service ?? "") < ($1.projectDirectory ?? $1.name, $1.service ?? "") }
    }

    /// Starts, stops, restarts or removes one managed container by ID (Containers view).
    public func perform(_ action: ContainerAction, on id: String) async throws {
        let runtimeRef = activeRuntime
        switch action {
        case .start: try await runtimeRef.start(container: id)
        case .stop: try await runtimeRef.stop(container: id)
        case .restart: try await runtimeRef.restart(container: id)
        case .remove: try await runtimeRef.removeContainer(id)
        }
        for model in models.values where model.record.containerID == id { refreshImageAndPhase(model) }
    }

    public enum ContainerAction: String, Sendable, CaseIterable { case start, stop, restart, remove }

    /// The container's own output (its last `tail` lines), for the logs sheet. Display only, never logged.
    public func logs(containerID: String, tail: Int = 300) async -> String {
        guard let data = try? await activeRuntime.logs(container: containerID, tail: tail) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Idle stop and reaper

    private func idleLoop() async {
        guard let configuration else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: configuration.idleCheckInterval)
            guard runtime?.isReady == true else { continue }
            for model in models.values where model.phase == .ready {
                let minutes = model.settings.idleStopMinutes
                guard minutes > 0, model.forwards.isEmpty, model.serviceForwards.isEmpty, let id = model.record.containerID else { continue }
                let last = model.lastActivity ?? model.record.lastUsed ?? .distantPast
                guard Date().timeIntervalSince(last) > TimeInterval(minutes * 60) else { continue }
                let runtimeRef = activeRuntime
                let user = workspaceSpec(model)?.user ?? "\(getuid()):\(getgid())"
                guard await runtimeRef.runningExecs(container: id) == 0 else {
                    model.lastActivity = Date()
                    continue
                }
                _ = try? await runtimeRef.reap(container: id, user: user)
                try? await runtimeRef.stop(container: id)
                bridges.removeValue(forKey: model.directory)?.stop()
                stopServices(model)
                model.phase = .idle
                scheduleConfigWrite()
            }
        }
    }

    /// After a command ends (or is cancelled), once nothing runs in the container any more, kills processes that
    /// escaped their command (`setsid`, double forks). The wrapper's TERM→KILL takes 2 s, so wait 3 s first.
    private func scheduleReap(_ model: ProjectEnvironment) {
        guard let id = model.record.containerID, let spec = workspaceSpec(model) else { return }
        let runtimeRef = activeRuntime
        tasks.set("reap-\(model.projectKey)", Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, await runtimeRef.runningExecs(container: id) == 0 else { return }
            guard let count = try? await runtimeRef.reap(container: id, user: spec.user) else { return }
            if count > 0 {
                model.lastReap = (count, Date())
                Self.log.info("reaped \(count, privacy: .public) stray processes")
            }
            self?.tasks.remove("reap-\(model.projectKey)")
        })
    }

    /// Runs the reaper now (Containers view, "Clean Up Processes"). Returns how many were stopped.
    public func cleanUpProcesses(_ directory: String) async -> Int {
        let model = environment(for: directory)
        guard let id = model.record.containerID, let spec = workspaceSpec(model) else { return 0 }
        let count = (try? await activeRuntime.reap(container: id, user: spec.user)) ?? 0
        model.lastReap = (count, Date())
        return count
    }

    // MARK: Ports and forwards

    /// Reads what listens in the project's container (Ports list).
    public func refreshPorts(_ directory: String) async {
        let model = environment(for: directory)
        guard model.phase == .ready, let id = model.record.containerID, let spec = workspaceSpec(model) else {
            model.ports = []
            return
        }
        do {
            model.ports = try await activeRuntime.listeningPorts(container: id, user: spec.user)
            model.portsUpdated = Date()
        } catch {
            model.lastError = Self.describe(error)
        }
    }

    /// Forwards a container port to host loopback (the same port number when free) and returns its URL.
    @discardableResult
    public func forward(_ directory: String, port: Int) throws -> URL {
        let model = environment(for: directory)
        if let existing = model.forwards.first(where: { $0.containerPort == port }) { return existing.url }
        guard model.phase == .ready, let id = model.record.containerID, let spec = workspaceSpec(model) else {
            throw ContainerError.notFound("the project's container is not running")
        }
        let listener = model.ports.first { $0.port == port } ?? ListeningPort(port: port, address: "127.0.0.1")
        let forwarder: PortForwarder
        do {
            forwarder = try activeRuntime.makeForwarder(container: id, port: listener, hostPort: port, user: spec.user)
        } catch {
            forwarder = try activeRuntime.makeForwarder(container: id, port: listener, hostPort: 0, user: spec.user)
        }
        forwarders[model.directory, default: [:]][port] = forwarder
        tasks.set("forward-\(model.projectKey)-\(port)", Task { await forwarder.run() })
        model.forwards.append(PortForwardInfo(containerPort: port, hostPort: forwarder.hostPort, url: forwarder.url, connections: 0))
        model.forwards.sort { $0.containerPort < $1.containerPort }
        model.lastActivity = Date()
        return forwarder.url
    }

    public func stopForward(_ directory: String, port: Int) {
        let model = environment(for: directory)
        forwarders[model.directory]?.removeValue(forKey: port)?.stop()
        tasks.set("forward-\(model.projectKey)-\(port)", Task {})
        model.forwards.removeAll { $0.containerPort == port }
    }

    private func stopForwards(_ model: ProjectEnvironment) {
        for (port, forwarder) in forwarders.removeValue(forKey: model.directory) ?? [:] {
            forwarder.stop()
            tasks.set("forward-\(model.projectKey)-\(port)", Task {})
        }
        model.forwards = []
    }

    /// The URL the built-in browser opens for a dev-server URL printed in the project's container
    /// (`http://localhost:5173/x` → `http://127.0.0.1:<forwarded>/x`), forwarding the port on demand. Nil for URLs that
    /// are not the container's loopback, or when the container is not running.
    public func browserURL(for url: URL, directory: String) async -> URL? {
        guard isEnabled, let host = url.host?.lowercased(), ["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "::1"].contains(host),
              let port = url.port ?? (url.scheme == "https" ? 443 : 80) as Int? else { return nil }
        let model = environment(for: directory)
        // Already a forward's own address (opened from the Ports list): nothing to map.
        if model.forwards.contains(where: { $0.hostPort == port && $0.hostPort != $0.containerPort }) { return url }
        guard model.phase == .ready else { return nil }
        if model.ports.isEmpty { await refreshPorts(directory) }
        guard let forwarded = try? forward(directory, port: port) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = "127.0.0.1"
        components?.port = URLComponents(url: forwarded, resolvingAgainstBaseURL: false)?.port
        return components?.url
    }

    // MARK: File-watch bridge

    private func restartBridge(_ model: ProjectEnvironment) {
        guard model.settings.fileWatchBridge, model.phase == .ready, let id = model.record.containerID,
              let spec = workspaceSpec(model) else {
            bridges.removeValue(forKey: model.directory)?.stop()
            return
        }
        // The same folders into the same container: keep the running stream (no gap, counters kept).
        if let current = bridges[model.directory], current.isRunning, current.roots == spec.workspaceRoots, bridgeContainers[model.directory] == id {
            return
        }
        bridges.removeValue(forKey: model.directory)?.stop()
        bridgeContainers[model.directory] = id
        let runtimeRef = activeRuntime
        let bridge = FileEventBridge(roots: spec.workspaceRoots) { paths in
            try await runtimeRef.touch(container: id, user: spec.user, paths: paths)
        }
        bridges[model.directory] = bridge
        bridge.start()
    }

    /// Refreshes the bridge counters shown in the Environment pane.
    public func refreshBridgeStats(_ directory: String) {
        let model = environment(for: directory)
        model.bridgeStats = bridges[model.directory]?.stats
    }

    // MARK: Registry credentials

    /// Stores registry credentials in the Keychain (service `app.bellocode.registry`, account = registry host).
    public func signIn(registry: String, username: String, password: SecretValue) throws {
        guard let vault = configuration?.registryVault else { return }
        let document = try JSONSerialization.data(withJSONObject: ["u": username, "p": String(decoding: password.utf8, as: UTF8.self)])
        try vault.store(account: registry, label: "BelloCode registry \(registry)", value: SecretValue(data: document))
    }

    public func signOut(registry: String) throws { try configuration?.registryVault.delete(account: registry) }

    /// The signed-in user for a registry, if any (the password is never returned).
    public func registryUser(_ registry: String) -> String? {
        guard let value = try? configuration?.registryVault.read(account: registry),
              let object = try? JSONSerialization.jsonObject(with: value.utf8) as? [String: String] else { return nil }
        return object["u"]
    }

    func registryAuth(for image: String) -> RegistryAuth? {
        let registry = RegistryAuth.registry(of: image)
        guard let value = try? configuration?.registryVault.read(account: registry),
              let object = try? JSONSerialization.jsonObject(with: value.utf8) as? [String: String],
              let username = object["u"], let password = object["p"] else { return nil }
        return RegistryAuth(username: username, password: password, serverAddress: registry)
    }

    // MARK: Commands BelloCode itself runs in the container

    /// Runs `command` with `secret` in the environment variable `name`, in a one-shot sibling of the project's container
    /// (`WorkspaceManager.runSecretCommand`: no network and a read-only project unless `policy` says otherwise, no
    /// shared home, the value on stdin, never in any configuration). Output is bounded (head and tail kept, the rest
    /// counted) and every verbatim occurrence of the value is replaced with `<secret>`. That replacement only prevents
    /// accidental display: a command that encodes or splits the value is not caught, which is why the user approves the
    /// exact command first (docs/features/orchestration-extras.md, "Secrets").
    public func runWithSecret(directory: String, command: String, name: String, secret: SecretValue, policy: SecretCommandPolicy = .init(),
                              timeout: Duration = .seconds(300)) async throws -> (exitCode: Int, output: String, truncated: Bool) {
        let (_, spec, shell) = try await readyContainer(directory)
        let result = try await activeRuntime.runSecretCommand(
            spec, shell: shell, command: command, workingDir: directory, name: name, secret: Data(secret.utf8), policy: policy, timeout: timeout)
        let value = String(decoding: secret.utf8, as: UTF8.self)
        var output = result.output.stdout.text + result.output.stderr.text
        if !value.isEmpty { output = output.replacingOccurrences(of: value, with: "<secret>") }
        return (result.exitCode, output, result.output.isTruncated)
    }

    /// Runs a worktree setup script in the container (never on the host), in the new worktree folder.
    public func runSetup(_ script: String, in worktree: String, projectDirectory: String) async throws -> WorktreeSetupResult {
        let start = ContinuousClock.now
        let (id, spec, shell) = try await readyContainer(projectDirectory)
        guard spec.contains(worktree) else {
            throw ContainerError.notFound("\(worktree) is not mounted in the project's container; choose a worktree folder inside the project's worktree location")
        }
        let result = try await activeRuntime.run(
            container: id, argv: [shell, "-c", script], workingDir: worktree,
            environment: ["BELLOCODE_WORKTREE_PATH": worktree, "BELLOCODE_PROJECT_ROOT": projectDirectory], user: spec.user,
            timeout: .seconds(600))
        // stdout and stderr each keep their head and tail (marked when cut); the combined text keeps both ends too.
        let combined = WorktreeSetupResult.headAndTail(
            String(decoding: result.stdout, as: UTF8.self) + String(decoding: result.stderr, as: UTF8.self), alreadyOmitted: result.omittedBytes)
        return WorktreeSetupResult(exitCode: Int32(truncatingIfNeeded: result.exitCode), output: combined.text,
                                   duration: ContinuousClock.now - start, omittedBytes: combined.omitted)
    }

    /// Ensures the container runs and returns (id, spec, shell). Throws the blocked message otherwise.
    func readyContainer(_ directory: String) async throws -> (String, WorkspaceSpec, String) {
        guard isEnabled else { throw EnvironmentBlockedError(message: "Container execution is off in this build.") }
        let model = environment(for: directory)
        if let message = policyBlock(model) { throw EnvironmentBlockedError(message: message) }
        if let blocked = model.phase.blocked { throw EnvironmentBlockedError(message: blocked.message) }
        guard let spec = workspaceSpec(model) else { throw EnvironmentBlockedError(message: EnvironmentPhase.noImage.blocked?.message ?? "No image is set.") }
        let id = try await activeRuntime.ensureRunning(spec)
        model.record.containerID = id
        if model.phase != .ready { refreshImageAndPhase(model) }
        return (id, spec, shell(model))
    }

    // MARK: Spec and helper configuration

    /// The folders mounted at the same path: the project, BelloCode's worktree folder for it, opencode's worktree
    /// folder for it, and any other worktree git lists. With `create`, missing worktree folders are created (they must
    /// exist to be mounted).
    func workspaceRoots(_ model: ProjectEnvironment, create: Bool) -> [String] {
        var roots = [model.directory, worktreeParent(model.directory)]
        if let id = model.projectID, let data = configuration?.opencodeDataDirectory {
            roots.append(data.appending(path: "opencode/worktree/\(id.rawValue.prefix(6))").path)
        }
        roots += model.extraWorktrees
        // Worktrees made by earlier versions in the shared `~/.bellocode/worktrees/<name>` folder: only this project's own,
        // one by one (never the folder, which same-named projects share).
        let legacy = WorkspacePreferences.legacyParent(projectDirectory: model.directory)
        if legacy != roots[1] { roots += WorkspacePreferences.ownWorktrees(in: legacy, projectDirectory: model.directory) }
        var seen = Set<String>()
        let standardized = roots.map { ($0 as NSString).standardizingPath }.filter { seen.insert($0).inserted }
        // A root inside another one adds nothing as a mount (the project itself always stays first).
        let unique = standardized.enumerated().filter { index, root in
            index == 0 || !isInside(root, anyOf: standardized.filter { $0 != root })
        }.map(\.element)
        if create {
            for root in unique.dropFirst() where !FileManager.default.fileExists(atPath: root) {
                try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            }
        }
        return unique
    }

    func workspaceSpec(_ model: ProjectEnvironment) -> WorkspaceSpec? {
        guard let image = model.settings.image ?? defaultImage, imageRefusal(image) == nil else { return nil }
        let roots = workspaceRoots(model, create: true)
        var spec = WorkspaceSpec(
            projectRoot: model.directory, extraMounts: Array(roots.dropFirst()), userMounts: model.settings.userMounts,
            image: image, network: model.settings.network, resources: model.settings.resources,
            environment: model.settings.environment)
        spec.serviceNetwork = serviceNetwork(model)
        let caches = model.settings.cacheMounts(imageDeclared: model.record.imageCaches ?? [:])
        spec.cacheMounts = caches.isEmpty ? nil : caches
        return spec
    }

    /// The shell used in the container: bash when the image has it.
    func shell(_ model: ProjectEnvironment) -> String {
        model.record.inventory?.tools.contains("bash") == true ? "/bin/bash" : "/bin/sh"
    }

    /// The helper's configuration for the current state (pure apart from reading models).
    func helperConfig() -> ExecHelperConfig {
        let socket = isEnabled ? activeRuntime.socketPath : ""
        var runtimeBlocked: ExecHelperConfig.Blocked?
        if let runtime, !runtime.isReady {
            runtimeBlocked = .init(message: runtime.userMessage, fix: EnvironmentFix(runtime.fix)?.title)
        } else if runtime == nil {
            runtimeBlocked = nil  // not checked yet: the helper tries and reports what it finds
        }
        let workspaces = models.values.sorted { $0.directory < $1.directory }.map { model -> ExecHelperConfig.Workspace in
            let spec = workspaceSpec(model)
            return ExecHelperConfig.Workspace(
                roots: spec?.workspaceRoots ?? workspaceRoots(model, create: false), container: model.containerName,
                user: spec?.user ?? "\(getuid()):\(getgid())", shell: shell(model),
                blocked: policyBlock(model).map { .init(message: $0, fix: EnvironmentFix.openSettings.title) } ?? model.phase.blocked,
                spec: policyBlock(model) == nil ? spec : nil,
                mountIdentity: model.record.mountIdentity, image: model.image, inventory: model.record.inventory,
                services: model.services.filter { $0.phase != .refused }.map(\.name))
        }
        return ExecHelperConfig(socket: socket, workspaces: workspaces, runtimeBlocked: runtimeBlocked)
    }

    /// Writes the helper configuration soon (coalesced, serialised). Off the main actor, atomically.
    func scheduleConfigWrite() {
        guard isEnabled, settingsLoaded, configuration?.execConfigURL != nil else { return }
        _ = enqueueConfigWrite(delay: .milliseconds(30))
    }

    /// Writes now and waits for the attempt (engine start, before the server launches; tests). A failure is in
    /// `helperConfigProblem` and retried.
    public func writeConfigNow() async {
        guard isEnabled, settingsLoaded, configuration?.execConfigURL != nil else { return }
        await enqueueConfigWrite(delay: nil).value
    }

    /// One writer at a time: a new write waits for the one before it, then writes the configuration as it is *then*
    /// (so the last write always carries the newest state). A write not started yet absorbs later requests.
    private func enqueueConfigWrite(delay: Duration?) -> Task<Void, Never> {
        if let queuedWrite { return queuedWrite }
        let previous = writeChain
        let task = Task { [weak self] in
            if let delay { try? await Task.sleep(for: delay) }
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            self.queuedWrite = nil
            await self.performConfigWrite()
        }
        queuedWrite = task
        writeChain = task
        return task
    }

    /// Writes the requirement (this launch, the new generation), then the configuration with that generation. Success
    /// is recorded only after both are on disk. If the requirement cannot be written the configuration is removed, and
    /// if the configuration cannot be written the newer requirement already refuses it: either way the helper fails
    /// closed. The problem is published and the write retried.
    private func performConfigWrite() async {
        guard let url = configuration?.execConfigURL else { return }
        let body = helperConfig()
        guard body != installedConfig || helperConfigProblem != nil else { return }
        configGeneration += 1
        let generation = configGeneration
        var config = body
        config.epoch = configEpoch
        config.generation = generation
        let requirementURL = ExecHelperConfig.Requirement.url(forConfig: url)
        let sink = fileSink
        var requirementWritten = false
        do {
            try await sink(try ExecHelperConfig.Requirement(epoch: configEpoch, generation: generation).encoded(), requirementURL)
            requirementWritten = true
            try await sink(try config.encoded(), url)
            installedConfig = body
            installedGeneration = generation
            if helperConfigProblem != nil { helperConfigProblem = nil }
        } catch {
            Self.log.error("could not write the helper configuration")
            installedConfig = nil
            if !requirementWritten { await Self.removeFile(url) }
            helperConfigProblem = "BelloCode could not save the command policy for its container helper (\(error.localizedDescription)). Commands are refused until it is saved; retrying."
            let delay = configRetryDelay
            tasks.set("config-retry", Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.scheduleConfigWrite()
            })
        }
    }

    // MARK: Caches

    /// Every cache volume (Settings ▸ Containers ▸ Caches) with sizes.
    public func cacheVolumes() async -> [CacheVolume] {
        guard isEnabled, runtime?.isReady == true else { return [] }
        return (try? await activeRuntime.cacheVolumes()) ?? []
    }

    /// Empties one cache (deletes its volume; it is created again, empty, on next use).
    public func cleanCache(_ name: String) async throws {
        try await activeRuntime.cleanCache(name)
        for model in models.values where model.phase == .ready { refreshImageAndPhase(model) }
    }

    // MARK: Image policy

    /// The policy in force: the administrator's (managed) or the one set in Settings.
    public var imagePolicy: ImagePolicy { managedPolicy?.policy ?? defaults.imagePolicy ?? .open }

    /// The app-wide default image: the administrator's, else Settings'.
    public var defaultImage: String? { managedPolicy?.defaultImage ?? defaults.defaultImage }

    /// Why `image` may not run under the policy, or nil.
    public func imageRefusal(_ image: String) -> String? { imagePolicy.refusal(for: image) }

    /// Re-reads the managed policy (Settings opens, Retry) and re-evaluates every project.
    public func reloadManagedPolicy() {
        let managed = configuration?.managedPolicy()
        guard managed != managedPolicy else { return }
        managedPolicy = managed
        for model in models.values { refreshImageAndPhase(model) }
        scheduleConfigWrite()
    }

    nonisolated static let pulledImagesKey = "containers.pulledImages"

    /// Remembers an image BelloCode pulled that was not on this Mac (so Prune may remove it once unused).
    func recordPulled(_ image: String) {
        let runtimeRef = activeRuntime
        tasks.set("record-pull-\(image)", Task { [weak self] in
            guard let id = try? await runtimeRef.image(image)?.id, let self else { return }
            self.pulledImageIDs.insert(id)
            try? await self.store.setPreference(Self.pulledImagesKey, Array(self.pulledImageIDs).sorted())
        })
    }

    @concurrent
    nonisolated static func writeFile(_ data: Data, to url: URL) async throws {
        try ExecHelperConfig.writeAtomically(data, to: url)
    }

    @concurrent
    nonisolated static func removeFile(_ url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func describe(_ error: any Error) -> String {
        if let error = error as? WorkspaceError { return error.description }
        if let error = error as? EnvironmentBlockedError { return error.message }
        return ContainerError.from(error).description
    }
}

/// A command BelloCode itself would run (setup script, secret exec) cannot run now; `message` says why and what to do.
public struct EnvironmentBlockedError: Error, CustomStringConvertible, Sendable, Equatable {
    public var message: String
    public var description: String { message }
}

/// True when `path` is strictly inside one of `roots`.
private func isInside(_ path: String, anyOf roots: [String]) -> Bool {
    roots.contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
}

/// Aggregates per-layer pull progress into one fraction (thread-safe; fed from the pull's stream).
final class PullAggregator: Sendable {
    private let state = Mutex<[String: (current: Int64, total: Int64)]>([:])
    private let status = Mutex("starting")

    func add(_ message: ProgressMessage) {
        if let id = message.id, let detail = message.progressDetail, let total = detail.total, total > 0 {
            state.withLock { $0[id] = (detail.current ?? 0, total) }
        }
        if let text = message.status { status.withLock { $0 = text } }
    }

    var progress: PullProgress {
        let layers = state.withLock { $0 }
        let total = layers.values.reduce(Int64(0)) { $0 + $1.total }
        let current = layers.values.reduce(Int64(0)) { $0 + min($1.current, $1.total) }
        let fraction = total > 0 ? Double(current) / Double(total) : nil
        let detail = fraction.map { "\(Int($0 * 100)) % of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))" }
            ?? status.withLock { String($0.prefix(60)) }
        return PullProgress(fraction: fraction, detail: detail)
    }
}

import Synchronization
