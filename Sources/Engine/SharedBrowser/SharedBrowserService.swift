import BelloCore
import ContainerKit
import Foundation
import Observation
import OpenCodeKit
import SecretKit
import os

/// What the app gives the shared browser (nil in `EngineConfiguration`: unavailable, e.g. tests and mock mode).
public struct SharedBrowserConfiguration: Sendable {
    /// The image's build context (`Resources/browser-image`, or `Containers/browser` in development).
    public var contextDirectory: URL?
    /// BelloCode's own `DOCKER_CONFIG` for builds (no credential helpers).
    public var dockerConfigDirectory: URL
    /// The packing key (Keychain service `app.bellocode.browser-extension-key`).
    public var keyVault: any SecretVault
    public var docker: URL?
    public var extraLabels: [String: String]
    public var containerName: String
    public var volume: String
    /// The Keychain account of the packing key. Debug builds use their own disposable key, so a development context
    /// never receives the installation's production key (R18).
    public var keyAccount: String = SharedBrowserConfiguration.defaultKeyAccount

    public static var defaultKeyAccount: String {
        BrowserImageContext.allowsDevelopmentSources ? SharedBrowserService.developmentKeyAccount : SharedBrowserService.keyAccount
    }

    public init(contextDirectory: URL?, dockerConfigDirectory: URL,
                keyVault: any SecretVault = KeychainSecretVault(service: SharedBrowserService.keyService),
                docker: URL? = BrowserImageBuilder.rancherDocker(), extraLabels: [String: String] = [:],
                containerName: String = BrowserContainerSpec.containerName, volume: String = BrowserContainerSpec.profileVolume) {
        self.contextDirectory = contextDirectory
        self.dockerConfigDirectory = dockerConfigDirectory
        self.keyVault = keyVault
        self.docker = docker
        self.extraLabels = extraLabels
        self.containerName = containerName
        self.volume = volume
    }
}

/// A notice shown in the Chrome panel and told to threads (restarts, cleared data).
public struct BrowserNotice: Sendable, Equatable, Identifiable {
    public var id: Int
    public var date: Date
    public var text: String
}

/// The shared browser (docs/features/shared-browser.md): ONE BelloCode-managed Chromium container for every thread and
/// project, behaving like the developer's own browser (one persistent profile; sign-ins kept and shared by every thread
/// allowed to use it). Owns the supervisor (lazy start, idle stop with the cookie flush, crash restart), the broker
/// behind the agents' `chrome_*` tools (one pooled `browse mcp`, per-thread tab groups, leases), the person's approvals,
/// the canonical `https://<project>.bc:<port>/` routes, the live view's forward and Take Over.
///
/// Threading: `@MainActor` state; Docker work runs in the supervisor and runtime off the main actor; tasks are owned
/// here and cancelled by `shutdown()`.
@MainActor
@Observable
public final class SharedBrowserService {
    nonisolated public static let keyService = "app.bellocode.browser-extension-key"
    nonisolated public static let keyAccount = "extension-packing-key"
    nonisolated public static let developmentKeyAccount = "extension-packing-key-development"
    nonisolated public static let instructionKey = "bellocode.chrome"

    public private(set) var phase: BrowserPhase = .stopped
    public private(set) var generation = 0
    public private(set) var status: BrowserRuntimeStatus?
    public private(set) var settings: SharedBrowserSettings
    public private(set) var notices: [BrowserNotice] = []
    /// Per tab: who is running a call, who drives a shared tab, human control, waiting calls (Chrome panel overlay).
    public private(set) var tabActivity: [String: BrowserTabGate.TabActivity] = [:]
    public private(set) var bindings: [String: BrowserBinding] = [:]
    public private(set) var shares: [BrowserShare] = []
    public private(set) var labels: [String: String] = [:]
    /// Projects whose agents may use the shared Chrome ("Always"), and threads allowed once (session → the directory it
    /// was allowed in; a call must match both).
    public private(set) var approvedProjects: Set<String> = []
    public private(set) var approvedSessions: [String: String] = [:]
    /// Revocations whose stored grant could not be deleted yet: the tools stay hidden (admission is closed), the
    /// pending removal is kept outside SQLite and retried, and Settings shows it until the delete succeeds (R21).
    public private(set) var pendingRevocations: Set<String> = []
    /// The live view's endpoint on the Mac (`http://127.0.0.1:<port>/bellocode.html`), while a viewer is visible.
    public private(set) var viewerURL: URL?
    public private(set) var viewerSubscribers = 0
    /// "*" while the person controls the whole browser, or the tab IDs they took over.
    public private(set) var humanControl: Set<String> = []
    /// Take Over requested, waiting for already-dispatched agent calls to settle (input not yet accepted).
    public private(set) var takingOver: Set<String> = []
    /// Whether this service holds one `.human` activity unit (held while any tab is taken over or being taken over).
    private var humanActivityHeld = false
    /// Whether this service holds one `.viewer` activity unit, and whether the viewer reconciliation is running.
    private var viewerActivityHeld = false
    private var reconcilingViewer = false
    public private(set) var downloads: [BrowserDownload] = []
    public private(set) var imageTag: String?
    public private(set) var lastError: String?
    /// The WebKit preview's proxy front (canonical names on the Mac), when running.
    public private(set) var previewProxy: PreviewProxyEndpoint?

    @ObservationIgnored public let configuration: SharedBrowserConfiguration?
    @ObservationIgnored let store: ProjectionStore
    @ObservationIgnored weak var engine: Engine?
    @ObservationIgnored var environments: EnvironmentService?
    @ObservationIgnored var secrets: SecretManager?
    @ObservationIgnored public private(set) var supervisor: BrowserSupervisor?
    @ObservationIgnored public private(set) var broker: SharedBrowserBroker!
    @ObservationIgnored private var runtime: DockerBrowserRuntime?
    @ObservationIgnored private var hosts: [String: ClientMCPHost] = [:]
    @ObservationIgnored private let tasks = TaskBox()
    @ObservationIgnored private var forwards: [String: (forwarder: PortForwarder, task: Task<Void, Never>, project: String, used: ContinuousClock.Instant)] = [:]
    @ObservationIgnored private var viewerForward: (forwarder: PortForwarder, task: Task<Void, Never>)?
    @ObservationIgnored private var previewFront: PreviewProxyFront?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var noticeCounter = 0
    @ObservationIgnored let log = Logger(subsystem: "app.bellocode", category: "shared-browser")
    nonisolated static let maxForwards = 32
    nonisolated static let toolsCacheKey = "browser.shared.tools"
    nonisolated static let pendingRevocationsKey = "browser.shared.pendingRevocations"
    /// Approval cards for the browser that may wait at once; beyond that the agent is told to wait (R20).
    nonisolated static let maxPendingApprovals = 16
    @ObservationIgnored let defaults: UserDefaults

    init(store: ProjectionStore, configuration: SharedBrowserConfiguration?, defaults: UserDefaults = .standard) {
        self.store = store
        self.configuration = configuration
        self.defaults = defaults
        settings = SharedBrowserSettings.load()
        let cached = Self.loadCachedTools()
        broker = SharedBrowserBroker(host: ServiceHost(service: self), cachedTools: cached, toolsCache: { tools in
            Task { @MainActor in Self.saveCachedTools(tools) }
        })
    }

    public var isAvailable: Bool { forceAvailableForSnapshots || (configuration != nil && environments?.isEnabled == true) }
    @ObservationIgnored var forceAvailableForSnapshots = false

    /// Snapshot harness only: shows a state without a container (mock mode has no container runtime).
    public func showForSnapshots(phase: BrowserPhase, status: BrowserRuntimeStatus?, bindings: [BrowserBinding],
                                 activity: [String: BrowserTabGate.TabActivity], humanControl: Set<String>, approved: Set<String>,
                                 notice: String? = nil, imageTag: String? = nil, viewers: Int = 0) {
        forceAvailableForSnapshots = true
        self.phase = phase
        self.status = status
        self.bindings = Dictionary(bindings.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, _ in a })
        tabActivity = activity
        self.humanControl = humanControl
        approvedProjects = approved
        self.imageTag = imageTag
        viewerSubscribers = viewers
        if let notice { notices = [BrowserNotice(id: 1, date: .now, text: notice)] }
        for binding in bindings where labels[binding.project] == nil {
            labels[binding.project] = BrowserNaming.projectLabel(directory: binding.project, taken: Set(labels.values))
        }
    }

    // MARK: Setup

    /// The router the egress proxy uses: `*.bc` through this service's table; the preview scope reaches routes only.
    nonisolated func makeRouter(fallback: any EgressRouter) -> any EgressRouter {
        BrowserEgressRouter(
            table: { [weak self] destination, _ in await self?.route(destination) },
            fallback: fallback, routesOnlyScopes: [SecretManager.previewScopeKey])
    }

    func start() async {
        await loadState()
        guard let configuration, let environments, environments.isEnabled else { return }
        let runtime = DockerBrowserRuntime(
            socketPath: environments.activeRuntime.socketPath ?? (NSHomeDirectory() + "/.rd/docker.sock"),
            docker: configuration.docker, contextDirectory: configuration.contextDirectory, configDirectory: configuration.dockerConfigDirectory,
            key: { [vault = configuration.keyVault, account = configuration.keyAccount] in try await Self.packingKey(vault, account: account) },
            network: { [weak self] image in
                guard let self else { throw BrowserStartError.unavailable("BelloCode is shutting down.") }
                return try await self.placeNetwork(image: image)
            },
            containerName: configuration.containerName, volume: configuration.volume, extraLabels: configuration.extraLabels)
        self.runtime = runtime
        let settings = self.settings
        let supervisor = BrowserSupervisor(runtime: runtime, timing: .init(idle: settings.idle)) { [extra = configuration.extraLabels, name = configuration.containerName, volume = configuration.volume] image, placement, seccomp in
            let screen = SharedBrowserSettings.load().screen
            return BrowserContainerSpec(image: image, seccompProfile: seccomp, network: placement.network, proxy: placement.proxy,
                                        certificateDirectory: placement.certificateDirectory, volume: volume, name: name, screen: screen,
                                        extraLabels: extra)
        }
        await attach(supervisor)
        // A browser left running by a previous launch: adopt it (start() skips what is already right) only when used.
    }

    /// Owns `supervisor` and follows its phase and restarts (tests attach one over a fake runtime).
    func attach(_ supervisor: BrowserSupervisor) async {
        self.supervisor = supervisor
        await supervisor.observe({ [weak self] phase, generation, status in
            Task { @MainActor in self?.apply(phase: phase, generation: generation, status: status) }
        }, onRestart: { [weak self] generation, reason in
            Task { @MainActor in await self?.restarted(generation: generation, reason: reason) }
        })
    }

    /// The packing key from the Keychain, made once (RSA-2048, PKCS#8). Never logged, never in argv or a file.
    ///
    /// Only a key that is really absent is generated: a Keychain error (locked, interaction not allowed) is thrown,
    /// never taken for "no key", which would replace the key and change the extension's ID (N12).
    nonisolated static func packingKey(_ vault: any SecretVault, account: String = keyAccount) async throws -> String {
        if let stored = try vault.read(account: account), !stored.isEmpty, let text = String(data: stored.utf8, encoding: .utf8) {
            return text
        }
        let pem = try BrowserExtensionKey.generatePEM()
        let label = account == keyAccount ? "BelloCode shared browser extension packing key" : "BelloCode shared browser extension packing key (development)"
        try vault.store(account: account, label: label, value: SecretValue(pem))
        return pem
    }

    private func loadState() async {
        guard !loaded else { return }
        loaded = true
        bindings = Dictionary(((try? await store.browserBindings()) ?? []).map { ($0.sessionID, $0) }, uniquingKeysWith: { a, _ in a })
        shares = (try? await store.browserShares()) ?? []
        labels = (try? await store.browserLabels()) ?? [:]
        // A revocation that never reached SQLite still applies: never reload a grant the person revoked (R21).
        pendingRevocations = Set(defaults.stringArray(forKey: Self.pendingRevocationsKey) ?? [])
        approvedProjects = ((try? await store.grants(.browserMCP)) ?? []).subtracting(pendingRevocations)
        for directory in pendingRevocations { _ = await finishRevocation(directory) }
    }

    private func apply(phase: BrowserPhase, generation: Int, status: BrowserRuntimeStatus?) {
        let wasReady = self.phase.isReady
        self.phase = phase
        self.generation = generation
        if let status { self.status = status }
        if case .failed(let message) = phase { lastError = message }
        if phase.isReady, !wasReady {
            lastError = nil
            if viewerSubscribers > 0 { Task { await self.openViewerForward() } }
        }
        if !phase.isReady, wasReady { closeRoutes(); closeViewerForward() }
    }

    private func restarted(generation: Int, reason: String) async {
        noticeCounter += 1
        notices.insert(BrowserNotice(id: noticeCounter, date: .now, text: reason), at: 0)
        if notices.count > 20 { notices.removeLast(notices.count - 20) }
        humanControl = []
        await releaseHumanActivityIfIdle()
        await broker.browserRestarted(generation: generation, reason: reason)
    }

    // MARK: Settings and actions

    public func update(_ settings: SharedBrowserSettings) async {
        let screenChanged = settings.screen != self.settings.screen
        self.settings = settings
        settings.save()
        await supervisor?.setIdle(settings.idle)
        if !settings.enabled { await stopBrowser(reason: "turned off") }
        for host in hosts.values { await host.toolsChanged() }
        if screenChanged, phase.isReady { try? await supervisor?.restart() }
    }

    /// Starts the browser now (Settings, the Chrome panel's Start button).
    public func startBrowser() async {
        guard let supervisor else { lastError = "The shared Chrome needs container execution (Rancher Desktop)."; return }
        do { try await supervisor.ensureRunning() } catch { lastError = BrowserSupervisor.describe(error) }
    }

    public func stopBrowser(reason: String = "stopped from Settings") async {
        await supervisor?.stop(reason: reason)
    }

    public func restartBrowser() async {
        do { try await supervisor?.restart() } catch { lastError = BrowserSupervisor.describe(error) }
    }

    /// Deletes every cookie and all site data (signs every site out for every thread). The UI confirms first.
    public func clearSiteData() async {
        do {
            try await supervisor?.clearProfile()
        } catch {
            lastError = "Could not delete the browser profile: \(BrowserSupervisor.describe(error))"
        }
    }

    /// Rebuilds the image on the next start (the container is removed; the profile volume stays).
    public func rebuildImage() async {
        await supervisor?.dropContainer()
        if let runtime, let tag = try? await runtime.expectedTag() {
            try? await EngineClient(socketPath: runtime.socketPath).removeImage(tag, force: true)
        }
        await startBrowser()
    }

    /// Revokes a project's "Always". Admission closes at once (tools hidden, calls refused) and stays closed across
    /// relaunches: the pending removal is recorded outside SQLite before the stored grant is deleted. Returns false
    /// (and Settings shows it, with Retry) when the delete failed (R21).
    @discardableResult
    public func revokeProject(_ directory: String) async -> Bool {
        approvedProjects.remove(directory)
        approvedSessions = approvedSessions.filter { $0.value != directory }
        pendingRevocations.insert(directory)
        defaults.set(pendingRevocations.sorted(), forKey: Self.pendingRevocationsKey)
        await hosts[directory]?.toolsChanged()
        return await finishRevocation(directory)
    }

    /// Deletes the stored grant of a pending revocation; on success the pending record goes too.
    private func finishRevocation(_ directory: String) async -> Bool {
        do {
            try await store.setGrant(.browserMCP, scope: directory, granted: false)
        } catch {
            lastError = "Could not save the revocation for \(URL(filePath: directory).lastPathComponent). Agents there still cannot use the shared Chrome; retry from Settings ▸ Browser."
            return false
        }
        pendingRevocations.remove(directory)
        defaults.set(pendingRevocations.sorted(), forKey: Self.pendingRevocationsKey)
        return true
    }

    public func expectedImageTag() async -> String? { try? await runtime?.expectedTag() }

    public func refreshStatus() async {
        if imageTag == nil { imageTag = await expectedImageTag() }
        if let fresh = await supervisor?.refreshStatus() { status = fresh }
        if phase.isReady, let runtime { downloads = (try? await runtime.downloads()) ?? downloads }
    }

    /// Copies one download to the Mac (explicit request from the downloads shelf).
    public func exportDownload(_ name: String, to folder: URL) async throws -> URL {
        guard let runtime else { throw BrowserStartError.unavailable("The shared Chrome is not set up.") }
        let data = try await runtime.download(name)
        let target = folder.appending(path: URL(filePath: name).lastPathComponent)
        try data.write(to: target, options: .withoutOverwriting)
        return target
    }

    func shutdown() async {
        tasks.cancelAll()
        for host in hosts.values { await host.stop() }
        hosts = [:]
        await broker.shutdown()
        closeViewerForward()
        closeRoutes()
        previewFront?.stop()
        previewFront = nil
        await supervisor?.stop(reason: "BelloCode quit")
    }

    // MARK: Agents (client MCP)

    /// Serves the `chrome_*` tools for these locations (with the app tools, on every connect).
    func hostTools(directories: [String]) async {
        guard isAvailable, let engine, let client = try? await engine.core.currentClient() else { return }
        let wanted = Set(directories.prefix(OrchestrationService.maxHostedLocations))
        for (directory, host) in hosts where !wanted.contains(directory) {
            hosts[directory] = nil
            await host.stop()
        }
        for directory in wanted where hosts[directory] == nil {
            let host = ClientMCPHost(name: SharedBrowserBroker.serverName, directory: directory,
                                     dialer: WebSocketClientMCPDialer(connection: client.connection), provider: broker, maxConcurrentCalls: 16)
            hosts[directory] = host
            await host.start()
        }
    }

    func access(session: String, directory: String) -> BrowserAccess {
        guard isAvailable else { return .unavailable("The shared Chrome needs container execution (Rancher Desktop).") }
        guard settings.enabled else { return .unavailable("The shared Chrome is turned off in Settings ▸ Browser.") }
        if case .sandboxUnavailable = phase { return .unavailable(BrowserStartError.sandboxUnavailable.description) }
        if pendingRevocations.contains(directory) { return .needsApproval }
        if approvedProjects.contains(directory) || approvedSessions[session] == directory { return .allowed }
        return .needsApproval
    }

    /// What the directory-level tools listing advertises: the chrome_* tools when the project is allowed, or when a
    /// thread in it was allowed once (each call is still checked against its exact session and directory, R19).
    func toolAccess(directory: String) -> BrowserToolAccess {
        switch access(session: "", directory: directory) {
        case .unavailable(let reason): return .unavailable(reason)
        case .allowed: return .allowed
        case .needsApproval:
            if !pendingRevocations.contains(directory), approvedSessions.values.contains(directory) { return .someSessions }
            return .needsApproval
        }
    }

    /// Browser approval cards still waiting (durable app requests, so they survive relaunch).
    private func pendingBrowserApprovals() async -> [(session: String, approval: AppApproval)] {
        guard let engine else { return [] }
        return await engine.core.appRequests().compactMap { request in
            if case .approval(let approval) = request.kind, approval.action == .browserMCP { return (request.sessionID.rawValue, approval) }
            return nil
        }
    }

    /// The approval card for the browse MCP server (MCP servers always need a person, even in Auto or Full access).
    public func requestAccess(session: String, directory: String) async -> ClientMCPResult {
        guard let engine else { return .error("BelloCode is not ready.") }
        let pending = await pendingBrowserApprovals()
        if pending.contains(where: { $0.session == session && $0.approval.scope == directory }) {
            return ClientMCPResult(text: "The request is already waiting for the person (a card shows it). End your turn now.")
        }
        // Never evict a waiting card: the agent is told plainly instead (R20).
        if pending.count >= Self.maxPendingApprovals {
            return .error("\(pending.count) shared Chrome requests are already waiting for the person. Do not ask again now; end your turn and explain what you need the browser for.")
        }
        let subject = AppRequest.makeID("chrome")
        let tag = await expectedImageTag() ?? "bellocode-browser (built on first use)"
        let detail = """
            Server: browse \(BrowserVersions.browse) (MCP) in BelloCode's browser container, never on this Mac · Chromium \(BrowserVersions.chromium) (\(tag))
            Each thread works in its own tab group; tabs are shared only when you share them.
            """
        let request = AppRequest(
            id: AppRequest.makeID("chr"), sessionID: SessionID(session),
            kind: .approval(AppApproval(action: .browserMCP, title: "Let agents use the shared Chrome", detail: detail, scope: directory,
                                        subjectID: subject, allowsAlways: true, digest: SHA256Hex.of("browserMCP\n" + directory))),
            received: .now)
        await engine.core.putAppRequest(request)
        return ClientMCPResult(text: "Asked the person to allow the shared Chrome for this project (a card shows it). If they allow it you are woken and the chrome_* tools appear. End your turn now.")
    }

    /// The person answered the card. The session and directory come from the durable request (its session and the
    /// approval's scope, bound by the digest), so a card restored after relaunch is answered like a fresh one. Throws
    /// before anything is applied when the card is not a valid browser approval, and when an "Always" grant could not
    /// be stored: the caller keeps the card (R20).
    func answerApproval(_ approval: AppApproval, session sessionID: SessionID, approved: Bool, always: Bool) async throws {
        guard approval.action == .browserMCP, approval.digest == SHA256Hex.of("browserMCP\n" + approval.scope) else {
            throw BrowserStartError.unavailable("This browser approval card is not valid any more.")
        }
        let pending = (session: sessionID.rawValue, directory: approval.scope)
        if approved {
            if always {
                try await store.setGrant(.browserMCP, scope: pending.directory, granted: true)
                approvedProjects.insert(pending.directory)
                if pendingRevocations.remove(pending.directory) != nil {
                    defaults.set(pendingRevocations.sorted(), forKey: Self.pendingRevocationsKey)
                }
            } else {
                approvedSessions[pending.session] = pending.directory
            }
            await hosts[pending.directory]?.toolsChanged()
            await writeGuidance(session: pending.session, directory: pending.directory)
        }
        let text = approved
            ? "[BelloCode Chrome] The person allowed the shared Chrome\(always ? " for this project" : " for this thread"). Its tools are available now as chrome_* (your own tab group; see the bellocode.chrome instructions)."
            : "[BelloCode Chrome] The person did not allow the shared Chrome. Do not ask again in this turn; use the built-in browser preview (browser.*) or explain what you need."
        try? await engine?.core.postSynthetic(SessionID(pending.session), text: text, metadata: .object(["bellocode": .object([
            "wake": .string("chrome"), "outcome": .string(approved ? "allowed" : "declined"),
        ])]))
    }

    func binding(session: String, directory: String) async -> BrowserBinding {
        if let existing = bindings[session] { return existing }
        let taken = Set(bindings.values.map(\.group))
        var attempt = 0
        var group = BrowserNaming.group(sessionID: session)
        while taken.contains(group) {
            attempt += 1
            group = BrowserNaming.group(sessionID: session, attempt: attempt)
        }
        let binding = BrowserBinding(sessionID: session, project: directory, group: group)
        bindings[session] = binding
        try? await store.saveBrowserBinding(binding)
        await writeGuidance(session: session, directory: directory)
        return binding
    }

    func save(_ binding: BrowserBinding) async {
        bindings[binding.sessionID] = binding
        try? await store.saveBrowserBinding(binding)
    }

    func sharesFor(session: String) -> (withMe: Set<String>, byMe: Set<String>, owners: [String: String]) {
        let now = Date.now
        let active = shares.filter { $0.isActive(at: now) }
        var owners: [String: String] = [:]
        for binding in bindings.values {
            let title = threadTitle(session: binding.sessionID)
            for tab in binding.tabs { owners[tab] = title }
        }
        return (Set(active.filter { $0.granteeSession == session }.map(\.tab)), Set(active.filter { $0.ownerSession == session }.map(\.tab)), owners)
    }

    /// The person shares one of a thread's tabs with another thread (Use Shared Tab…); recorded with an optional expiry.
    public func share(tab: String, from owner: String, to grantee: String, for duration: TimeInterval? = 3600) async {
        let share = BrowserShare(ownerSession: owner, granteeSession: grantee, tab: tab, expires: duration.map { Date.now.addingTimeInterval($0) })
        shares.append(share)
        try? await store.saveBrowserShare(share)
    }

    public func revokeShare(_ id: String) async {
        guard let share = shares.first(where: { $0.id == id }) else { return }
        shares.removeAll { $0.id == id }
        try? await store.deleteBrowserShare(id: id)
        await broker.gate.yield(tab: share.tab)
    }

    public func threadTitle(session: String) -> String {
        engine?.orchestration?.graph.nodes[SessionID(session)]?.title ?? "thread \(session.suffix(6))"
    }

    /// Agent guidance (session instruction entry `bellocode.chrome`): when to use the shared Chrome vs the built-in
    /// WebKit preview, the canonical project URLs, the thread's own group, and that sign-ins are shared.
    func writeGuidance(session: String, directory: String) async {
        guard let engine, let client = try? await engine.core.currentClient() else { return }
        let label = await label(for: directory)
        let group = bindings[session]?.group ?? BrowserNaming.group(sessionID: session)
        let text = BrowserGuidance.text(projectLabel: label, group: group, mainTab: BrowserNaming.mainTab(group: group))
        try? await client.putInstructionEntry(sessionID: session, key: Self.instructionKey, value: .string(text))
    }

    // MARK: Activity (live view, takeover)

    func beginCall() async throws {
        guard let supervisor else { throw BrowserStartError.unavailable("The shared Chrome needs container execution (Rancher Desktop).") }
        try await supervisor.begin(.call)
        scheduleActivityRefresh()
    }

    func endCall() async {
        await supervisor?.end(.call)
        scheduleActivityRefresh()
    }

    private func scheduleActivityRefresh() {
        tasks.set("activity", Task { [weak self] in
            guard let self else { return }
            let activity = await self.broker.tabActivity()
            self.tabActivity = activity
        })
    }

    /// A visible live view (Chrome panel or window): connects only while visible (review optimisation 2). The
    /// supervisor's `.viewer` unit follows "any viewer visible" as one edge, reconciled one step at a time, so a
    /// viewer that disappears while the browser is starting neither leaks the unit nor opens a forward for nobody, and
    /// a failed start never drives the count below zero (N12).
    public func viewerAppeared() async {
        viewerSubscribers += 1
        await reconcileViewer()
    }

    public func viewerDisappeared() async {
        guard viewerSubscribers > 0 else { return }
        viewerSubscribers -= 1
        await reconcileViewer()
    }

    private func reconcileViewer() async {
        guard !reconcilingViewer else { return }  // the running reconciliation picks up the change
        reconcilingViewer = true
        defer { reconcilingViewer = false }
        while true {
            let wanted = viewerSubscribers > 0
            if wanted == viewerActivityHeld { break }
            if wanted {
                do {
                    try await supervisor?.begin(.viewer)
                    viewerActivityHeld = true
                } catch {
                    lastError = BrowserSupervisor.describe(error)
                    break
                }
            } else {
                closeViewerForward()
                viewerActivityHeld = false
                await supervisor?.end(.viewer)
            }
        }
        if viewerActivityHeld, viewerSubscribers > 0 { await openViewerForward() }
    }

    public var viewerPassword: String? { get async { await supervisor?.password } }

    /// Forwards the live view's port of the container proven BelloCode's, addressed by its ID (R07).
    private func openViewerForward() async {
        guard viewerForward == nil, phase.isReady, let runtime else { return }
        guard let id = try? await runtime.ownedContainerID() else { return }
        guard viewerForward == nil, phase.isReady, viewerSubscribers > 0 else { return }
        guard let forwarder = try? PortForwarder(client: EngineClient(socketPath: runtime.socketPath), container: id,
                                                 containerPort: BrowserContainerSpec.viewerPort, maxConnections: 8) else { return }
        viewerForward = (forwarder, Task { await forwarder.run() })
        viewerURL = URL(string: "http://127.0.0.1:\(forwarder.hostPort)/bellocode.html")
    }

    private func closeViewerForward() {
        viewerForward?.forwarder.stop()
        viewerForward?.task.cancel()
        viewerForward = nil
        viewerURL = nil
    }

    /// Take Over: the person controls `tab` ("*" = the whole browser). Agent calls waiting on it fail with Busy, new
    /// ones are refused until Give Back, and calls already sent are cancelled. Control (the live view accepting input)
    /// is acknowledged only once those calls have settled; meanwhile `takingOver` shows it (R22). The browser counts as
    /// active meanwhile.
    ///
    /// The supervisor's `.human` unit is held once while any tab is controlled or being taken over, and released when
    /// the last is given back or the browser restarted (N12).
    public func takeOver(_ tab: String = "*") async {
        guard !humanControl.contains(tab), !takingOver.contains(tab) else { return }
        let first = humanControl.isEmpty && takingOver.isEmpty && !humanActivityHeld
        takingOver.insert(tab)
        if first, let supervisor {
            do {
                try await supervisor.begin(.human)
                humanActivityHeld = true
            } catch {
                lastError = BrowserSupervisor.describe(error)
            }
        }
        let settled = await broker.takeOver(tab)
        takingOver.remove(tab)
        if !settled {
            lastError = "An agent's browser call did not stop in time. Agents are paused; check the page before you continue."
        }
        humanControl.insert(tab)
        tabActivity = await broker.tabActivity()
    }

    public func giveBack(_ tab: String = "*") async {
        guard humanControl.contains(tab) || tab == "*" else { return }
        if tab == "*" { humanControl = [] } else { humanControl.remove(tab) }
        await broker.gate.giveBack(tab)
        await releaseHumanActivityIfIdle()
        tabActivity = await broker.tabActivity()
    }

    /// Ends the `.human` unit once no tab is controlled or being taken over.
    private func releaseHumanActivityIfIdle() async {
        guard humanActivityHeld, humanControl.isEmpty, takingOver.isEmpty else { return }
        humanActivityHeld = false
        await supervisor?.end(.human)
    }

    // MARK: Routes (canonical names)

    /// The project's label for `https://<label>.bc:<port>/` (allocated once, stored).
    public func label(for directory: String) async -> String {
        if let existing = labels[directory] { return existing }
        var taken = Set(labels.values)
        while true {
            let candidate = BrowserNaming.projectLabel(directory: directory, taken: taken)
            if (try? await store.saveBrowserLabel(project: directory, label: candidate)) != false {
                labels[directory] = candidate
                return candidate
            }
            taken.insert(candidate)
        }
    }

    public func canonicalURL(directory: String, port: Int) -> String? {
        labels[directory].map { BrowserNaming.projectURL(label: $0, port: port) }
    }

    /// The projects the router may reach now: those with a running workspace or services.
    func routeProjects() async -> [BrowserRouteProject] {
        guard let environments else { return [] }
        var out: [BrowserRouteProject] = []
        for model in environments.environments {
            let running = model.phase == .ready
            let services = Dictionary(model.services.filter { $0.phase == .running }.map { ($0.name, $0.ports) }, uniquingKeysWith: { a, _ in a })
            guard running || !services.isEmpty else { continue }
            let label = await label(for: model.directory)
            out.append(BrowserRouteProject(directory: model.directory, label: label, projectKey: model.projectKey, workspaceContainer: model.containerName,
                                           workspaceRunning: running, services: services, offline: (model.settings.network == .none)))
        }
        return out
    }

    /// The proxy's table lookup: resolves the name, attaches the gateway to the project network for services, and returns
    /// a dial to a loopback forwarder (the proxy has terminated TLS for the exact host; the private hop is plain HTTP).
    func route(_ destination: HostPort) async -> EgressRoute? {
        let projects = await routeProjects()
        switch BrowserRouteTable.resolve(destination, projects: projects) {
        case .refuse(let reason): return .refuse(reason)
        case .target(let target):
            guard let port = forwarder(for: target) else { return .refuse("No route to \(destination) right now.") }
            return .dial(EgressDial(endpoint: HostPort(host: "127.0.0.1", port: port), terminatesTLS: true))
        }
    }

    private func forwarder(for target: BrowserRouteTarget) -> Int? {
        let key = "\(target.container)|\(target.host)|\(target.port)"
        if let existing = forwards[key] {
            forwards[key]?.used = .now
            return existing.forwarder.hostPort
        }
        guard let runtime else { return nil }
        if forwards.count >= Self.maxForwards, let oldest = forwards.min(by: { $0.value.used < $1.value.used })?.key {
            forwards[oldest]?.forwarder.stop()
            forwards[oldest]?.task.cancel()
            forwards[oldest] = nil
        }
        guard let forwarder = try? PortForwarder(client: EngineClient(socketPath: runtime.socketPath), container: target.container,
                                                 containerPort: target.port, containerHost: target.host) else { return nil }
        forwards[key] = (forwarder, Task { await forwarder.run() }, target.project, .now)
        return forwarder.hostPort
    }

    /// Routes end with the browser, and a project's network is left when the browser stops.
    private func closeRoutes() {
        for entry in forwards.values {
            entry.forwarder.stop()
            entry.task.cancel()
        }
        forwards = [:]
    }

    /// A project went idle: its routes go.
    public func projectInactive(_ directory: String) {
        for (key, entry) in forwards where entry.project == directory {
            entry.forwarder.stop()
            entry.task.cancel()
            forwards[key] = nil
        }
    }

    /// The egress scope for the browser: the network, proxy and certificates; the scope admits the projects the browser
    /// serves (any project with a bound thread), so their placeholders work in pages through the proxy.
    private func placeNetwork(image: String) async throws -> BrowserNetworkPlacement {
        guard let secrets else { throw BrowserStartError.unavailable("The secret manager is not running.") }
        let projects = Set(bindings.values.map(\.project)).union(approvedProjects)
        let admitted = LockedBox(projects)
        tasks.set("admitted", Task { @MainActor [weak self] in
            // Keep the scope's view of served projects current as threads bind.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                admitted.set(Set(self.bindings.values.map(\.project)).union(self.approvedProjects))
            }
        })
        let placement = try await secrets.ensureBrowserScope(image: image, admitsProject: { project in
            admitted.get().contains { project == $0 || project.hasPrefix($0 + "/") }
        }, extraLabels: configuration?.extraLabels ?? [:])
        await startPreviewFront()
        return placement
    }

    /// The loopback proxy the WebKit preview uses for `*.bc` names (same canonical URLs on the Mac).
    func startPreviewFront() async {
        guard previewFront == nil, let secrets, let scope = secrets.previewScope() else { return }
        let front = PreviewProxyFront(upstreamPort: scope.port, token: scope.token)
        do {
            let port = try await front.start()
            previewFront = front
            previewProxy = PreviewProxyEndpoint(port: port, username: front.username, password: front.password, authorityDER: secrets.egressAuthorityDER)
        } catch {
            log.error("preview proxy front failed to start")
        }
    }

    // MARK: Tools cache

    static func loadCachedTools() -> [ClientMCPTool] {
        guard let data = UserDefaults.standard.data(forKey: toolsCacheKey), let value = try? JSONValue.parse(data) else { return [] }
        return (value.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue else { return nil }
            return ClientMCPTool(name: name, description: entry["description"]?.stringValue ?? "", inputSchema: entry["inputSchema"] ?? .object([:]))
        }
    }

    static func saveCachedTools(_ tools: [ClientMCPTool]) {
        let value = JSONValue.array(tools.map { .object(["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema]) })
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: toolsCacheKey) }
    }

    /// browse over exec, only in the container proven BelloCode's, addressed by its ID (R07).
    func makeTransport() async throws -> any BrowseMCPTransport {
        guard let runtime else { throw BrowserStartError.unavailable("The shared Chrome is not set up.") }
        guard let id = try await runtime.ownedContainerID() else { throw BrowserStartError.unavailable("The shared Chrome's container is not running.") }
        return try await ExecBrowseTransport(client: EngineClient(socketPath: runtime.socketPath), container: id)
    }
}

/// The pinned versions (from versions.env; shown on cards and in Settings).
public enum BrowserVersions {
    public static let browse = "0.1.5"
    public static let chromium = "156.0.8078.79"
}

public struct PreviewProxyEndpoint: Sendable, Equatable {
    public var port: UInt16
    public var username: String
    public var password: String
    /// The egress CA the WebKit preview trusts for `*.bc` names only.
    public var authorityDER: Data?
}

/// Bridges the broker's host protocol to the main-actor service.
struct ServiceHost: SharedBrowserHost {
    weak var service: SharedBrowserService?

    func access(session: String, directory: String) async -> BrowserAccess {
        await MainActor.run { service?.access(session: session, directory: directory) ?? .unavailable("BelloCode is shutting down.") }
    }
    func toolAccess(directory: String) async -> BrowserToolAccess {
        await MainActor.run { service?.toolAccess(directory: directory) ?? .unavailable("BelloCode is shutting down.") }
    }
    public func requestAccess(session: String, directory: String) async -> ClientMCPResult {
        guard let service else { return .error("BelloCode is shutting down.") }
        return await service.requestAccess(session: session, directory: directory)
    }
    func binding(session: String, directory: String) async -> BrowserBinding {
        guard let service else { return BrowserBinding(sessionID: session, project: directory, group: BrowserNaming.group(sessionID: session)) }
        return await service.binding(session: session, directory: directory)
    }
    func save(_ binding: BrowserBinding) async { await service?.save(binding) }
    func shares(session: String) async -> (withMe: Set<String>, byMe: Set<String>, owners: [String: String]) {
        await MainActor.run { service?.sharesFor(session: session) ?? ([], [], [:]) }
    }
    func beginCall() async throws {
        guard let service else { throw BrowserStartError.unavailable("BelloCode is shutting down.") }
        try await service.beginCall()
    }
    func endCall() async { await service?.endCall() }
    func makeTransport() async throws -> any BrowseMCPTransport {
        guard let service else { throw BrowserStartError.unavailable("BelloCode is shutting down.") }
        return try await service.makeTransport()
    }
    func generation() async -> Int { await MainActor.run { service?.generation ?? 0 } }
    func threadTitle(session: String) async -> String { await MainActor.run { service?.threadTitle(session: session) ?? session } }
}
