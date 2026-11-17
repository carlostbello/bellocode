import BelloCore
import Foundation
import Observation
import OpenCodeKit
import os

/// The desktop browser a thread's agent controls: BrowserKit's tab set for that thread. Everything is `@MainActor`.
@MainActor
public protocol BrowserBridgeHost: AnyObject {
    /// The inventory to publish: only the tabs this thread may use (never private or unshared tabs). The server
    /// resolves tab IDs only from this list, so anything left out cannot be targeted.
    func browserInventory() -> BrowserInventory
    /// Runs one agent command. Must honour task cancellation (the server's `cancel`, the person's Stop, our deadline).
    func perform(_ command: BrowserCommand) async -> BrowserOutcome
}

/// Where a thread's agent connection stands. Every state has a text label (status is never colour-only).
public enum BrowserBridgeStatus: Equatable, Sendable {
    /// No browser for this thread is bound (nothing opened yet, or it was closed).
    case off
    /// The person turned browser control off for this thread.
    case disabled
    /// Detached to bound resources (too many threads have browsers); reattaches when the thread is shown.
    case parked
    /// Waiting for the server connection.
    case waitingForServer
    case connecting
    case attached
    /// The connection dropped; retrying with backoff.
    case retrying(attempt: Int)
    /// Another window or app attached to this session. Never reclaimed automatically.
    case replaced
    /// The server refused the attachment (`message` explains).
    case unavailable(String)
    /// The server speaks another `experimental.browser` contract version.
    case incompatible(String)

    public var isAttached: Bool { self == .attached }

    /// A short label for the pane's status chip.
    public var label: String {
        switch self {
        case .off: "Agent not connected"
        case .disabled: "Agent control off"
        case .parked: "Agent detached"
        case .waitingForServer: "Waiting for opencode"
        case .connecting: "Connecting agent…"
        case .attached: "Agent can use this browser"
        case .retrying: "Reconnecting agent…"
        case .replaced: "Agent moved to another window"
        case .unavailable: "Agent unavailable"
        case .incompatible: "Agent bridge incompatible"
        }
    }

    /// A sentence for the tooltip or the banner.
    public var detail: String {
        switch self {
        case .off: "Open a tab to let this thread's agent use the browser."
        case .disabled: "Browser control is off for this thread. Turn it on to let the agent open and use shared tabs."
        case .parked: "Detached because many threads have browsers open. It reconnects when you show this thread."
        case .waitingForServer: "The agent can use the browser once opencode is connected."
        case .connecting: "Connecting this thread's agent to the browser."
        case .attached: "The agent sees the tabs it opened and the tabs you share with it. Private tabs are never shared."
        case .retrying(let attempt): "The connection to opencode dropped. Retrying (attempt \(attempt))."
        case .replaced: "Another BelloCode window or opencode app attached a browser to this thread. Reconnect to take it back."
        case .unavailable(let message): "opencode refused the browser connection: \(message)"
        case .incompatible(let message): "\(message) Update BelloCode, or use the bundled opencode. Browsing works; the agent cannot control it."
        }
    }

    /// The status asks the person to act (Reconnect, or update).
    public var needsAttention: Bool {
        switch self {
        case .replaced, .unavailable, .incompatible: true
        default: false
        }
    }
}

/// Observable per-thread bridge state for the pane.
@MainActor
@Observable
public final class BrowserBridgeModel {
    public let sessionID: SessionID
    public internal(set) var status: BrowserBridgeStatus = .off
    /// Agent commands running now (request ID → operation), for the "Agent is working" line.
    public internal(set) var running: [String: String] = [:]
    /// The most recent command failure code (content-free), for diagnostics.
    public internal(set) var lastFailureCode: String?
    public internal(set) var commandCount = 0

    init(sessionID: SessionID) { self.sessionID = sessionID }
}

/// Connects each thread's browser to its opencode session through the `experimental.browser` v4 bridge.
///
/// - A thread is *bound* while BelloCode shows a browser for it (`bind`); a bound thread whose control is enabled is
///   attached, at most `maxAttachments` at once (least recently shown are parked).
/// - Controls arrive on one event-hub subscription (filtered to the control type) and are routed by connection ID.
///   After any event-stream gap, every attachment republishes its inventory (a reconnect is not a replay).
/// - A transport loss retries with backoff; `replaced` waits for an explicit `reconnect`; `incompatible` (a contract
///   version bump) and refusals are shown and not retried.
/// - On attach, a session instruction entry (`bellocode.browser`) tells the model what this WebKit browser cannot do;
///   it is removed when control is turned off or the browser is closed.
///
/// Threading and ownership: `@MainActor`; one per engine (`Engine.browser`). Owns its tasks; `shutdown()` ends them.
@MainActor
public final class BrowserBridgeService {
    public static let maxAttachments = 8
    /// The instruction entry key for model guidance.
    public static let guidanceKey = "bellocode.browser"
    static let disabledKey = "browser.controlDisabled"
    static let disabledLimit = 2_000

    private let store: ProjectionStore
    private let client: @Sendable () async throws -> OpenCodeClient
    private let subscribe: @Sendable () async -> (EventSubscription, Bool)?
    private let retryDelays: [Duration]
    private let log = Logger(subsystem: "app.bellocode.Engine", category: "BrowserBridge")
    private let signposter = OSSignposter(subsystem: "app.bellocode.Engine", category: "BrowserBridge")

    private final class Binding {
        let sessionID: SessionID
        var directory: String
        weak var host: (any BrowserBridgeHost)?
        var guidance: String?
        var attachment: BrowserAttachment?
        var task: Task<Void, Never>?
        var retryAttempt = 0
        var lastUsed = Date()
        var guidancePut = false

        init(sessionID: SessionID, directory: String, host: any BrowserBridgeHost, guidance: String?) {
            self.sessionID = sessionID
            self.directory = directory
            self.host = host
            self.guidance = guidance
        }
    }

    private var bindings: [SessionID: Binding] = [:]
    private var models: [SessionID: BrowserBridgeModel] = [:]
    private var routes: [String: BrowserAttachment] = [:]
    private var routeSessions: [String: SessionID] = [:]
    private var disabled: Set<SessionID> = []
    private var disabledLoaded = false
    private var loadTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var streamConnected = false
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    private let attachmentEvents: AsyncStream<(String, BrowserAttachmentEvent)>
    private let attachmentEventSink: AsyncStream<(String, BrowserAttachmentEvent)>.Continuation
    private var isShutdown = false

    public init(
        store: ProjectionStore, client: @escaping @Sendable () async throws -> OpenCodeClient,
        subscribe: @escaping @Sendable () async -> (EventSubscription, Bool)?,
        retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30)]
    ) {
        self.store = store
        self.client = client
        self.subscribe = subscribe
        self.retryDelays = retryDelays
        (attachmentEvents, attachmentEventSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(512))
    }

    // MARK: Public API

    /// The observable state of a thread's bridge (created on first use, kept while bound).
    public func model(for sessionID: SessionID) -> BrowserBridgeModel {
        if let model = models[sessionID] { return model }
        let model = BrowserBridgeModel(sessionID: sessionID)
        models[sessionID] = model
        return model
    }

    /// Shows a browser for this thread: attach (unless control is off) and keep it attached while bound. Calling it
    /// again (the thread is shown again) marks it recently used and reattaches a parked or failed binding.
    public func bind(_ sessionID: SessionID, directory: String, host: any BrowserBridgeHost, guidance: String? = nil) {
        guard !isShutdown else { return }
        startEventsLoop()
        if let binding = bindings[sessionID] {
            binding.host = host
            binding.directory = directory
            binding.guidance = guidance ?? binding.guidance
            binding.lastUsed = Date()
            switch model(for: sessionID).status {
            case .parked, .off, .unavailable, .waitingForServer: connect(binding)
            default: break
            }
        } else {
            let binding = Binding(sessionID: sessionID, directory: directory, host: host, guidance: guidance)
            bindings[sessionID] = binding
            connect(binding)
        }
        enforceAttachmentLimit(keeping: sessionID)
    }

    /// The browser for this thread was closed: detach and remove the guidance entry.
    public func unbind(_ sessionID: SessionID) {
        guard let binding = bindings.removeValue(forKey: sessionID) else { return }
        detach(binding, status: .off)
        removeGuidance(binding)
    }

    /// The window closed: detach but keep the guidance entry (it describes this browser's limits only while the tools
    /// are present, and the thread reattaches when shown again).
    public func unbindKeepingGuidance(_ sessionID: SessionID) {
        guard let binding = bindings.removeValue(forKey: sessionID) else { return }
        detach(binding, status: .off)
    }

    /// After `replaced`, `unavailable` or a parked binding: attach again on the person's request.
    public func reconnect(_ sessionID: SessionID) {
        guard let binding = bindings[sessionID] else { return }
        binding.retryAttempt = 0
        binding.lastUsed = Date()
        connect(binding)
        enforceAttachmentLimit(keeping: sessionID)
    }

    /// The host's shared tabs changed: publish soon (coalesced by the attachment's outbox).
    public func publish(_ sessionID: SessionID) {
        guard let attachment = bindings[sessionID]?.attachment else { return }
        Task { await attachment.requestPublish() }
    }

    /// Publishes now and returns once the server acknowledged (`tabs.open`/`tabs.close` answer after this).
    public func publishAndWait(_ sessionID: SessionID) async {
        guard let attachment = bindings[sessionID]?.attachment else { return }
        await attachment.publishAndWait()
    }

    /// The person pressed Stop: cancel the thread's running agent commands (answered `cancelled`).
    public func cancelRunning(_ sessionID: SessionID) {
        guard let attachment = bindings[sessionID]?.attachment else { return }
        Task { await attachment.cancelAll() }
    }

    public func isControlEnabled(_ sessionID: SessionID) -> Bool { !disabled.contains(sessionID) }

    /// Turns browser control on or off for a thread (persisted). Off detaches at once: the agent loses the tools.
    public func setControlEnabled(_ enabled: Bool, for sessionID: SessionID) {
        if enabled { disabled.remove(sessionID) } else { disabled.insert(sessionID) }
        saveDisabled()
        guard let binding = bindings[sessionID] else {
            model(for: sessionID).status = enabled ? .off : .disabled
            return
        }
        if enabled {
            binding.retryAttempt = 0
            connect(binding)
            enforceAttachmentLimit(keeping: sessionID)
        } else {
            detach(binding, status: .disabled)
            removeGuidance(binding)
        }
    }

    /// Loads persisted per-thread settings. Called by `bind` too; await it before reading `isControlEnabled` at launch.
    public func loadSettings() async {
        if disabledLoaded { return }
        if let loadTask { return await loadTask.value }
        let store = self.store
        let task = Task { [weak self] in
            let saved = (try? await store.preference(Self.disabledKey, as: [String].self)) ?? []
            guard let self else { return }
            self.disabled.formUnion(saved.map { SessionID($0) })
            self.disabledLoaded = true
        }
        loadTask = task
        await task.value
    }

    /// Detaches everything (window or app closing). Guidance entries stay: they describe this browser's limits only
    /// while its tools are present.
    public func shutdown() async {
        isShutdown = true
        let attachments = bindings.values.compactMap(\.attachment)
        for binding in bindings.values {
            binding.task?.cancel()
            binding.attachment = nil
        }
        bindings.removeAll()
        for attachment in attachments { await attachment.stop() }
        routes.removeAll()
        routeSessions.removeAll()
        pumpTask?.cancel()
        eventsTask?.cancel()
        attachmentEventSink.finish()
        resumeConnectionWaiters()
    }

    /// Sessions currently attached (diagnostics, tests).
    public var attachedSessionIDs: [SessionID] {
        bindings.values.filter { models[$0.sessionID]?.status == .attached }.map(\.sessionID)
    }

    /// The live attachment of a thread (tests).
    public func attachment(for sessionID: SessionID) -> BrowserAttachment? { bindings[sessionID]?.attachment }

    // MARK: Connecting

    private func connect(_ binding: Binding) {
        binding.task?.cancel()
        let previous = binding.attachment
        binding.attachment = nil
        if let previous { Task { await previous.stop() } }
        let sessionID = binding.sessionID
        binding.task = Task { [weak self] in
            await self?.loadSettings()
            guard let self, !Task.isCancelled else { return }
            guard self.isControlEnabled(sessionID) else {
                self.model(for: sessionID).status = .disabled
                return
            }
            await self.attachLoop(binding)
        }
    }

    private func attachLoop(_ binding: Binding) async {
        let sessionID = binding.sessionID
        let model = self.model(for: sessionID)
        while !Task.isCancelled, bindings[sessionID] === binding {
            while !streamConnected {
                model.status = .waitingForServer
                await ensurePump()
                await waitForConnection()
                if Task.isCancelled || isShutdown { return }
            }
            model.status = binding.retryAttempt == 0 ? .connecting : .retrying(attempt: binding.retryAttempt)
            let attachment = makeAttachment(binding)
            binding.attachment = attachment
            routes[attachment.connectionID] = attachment
            routeSessions[attachment.connectionID] = sessionID
            let interval = signposter.beginInterval("attach")
            do {
                try await attachment.start()
                signposter.endInterval("attach", interval)
                guard !Task.isCancelled, binding.attachment === attachment else { return }
                binding.retryAttempt = 0
                model.status = .attached
                putGuidance(binding)
                return
            } catch {
                signposter.endInterval("attach", interval)
                routes[attachment.connectionID] = nil
                routeSessions[attachment.connectionID] = nil
                if binding.attachment === attachment { binding.attachment = nil }
                if Task.isCancelled { return }
                guard let delay = handleFailure(error, binding: binding) else { return }
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// Applies an end reason; returns a retry delay, or nil to stop.
    private func handleFailure(_ end: BrowserAttachmentEnd, binding: Binding) -> Duration? {
        let model = self.model(for: binding.sessionID)
        switch end {
        case .replaced:
            model.status = .replaced
            return nil
        case .incompatible(_, let message):
            model.status = .incompatible(message)
            log.error("browser bridge incompatible: contract \(BrowserContract.version, privacy: .public)")
            return nil
        case .unavailable(let message, let retryable):
            guard retryable else {
                model.status = .unavailable(message)
                return nil
            }
            fallthrough
        case .closed:
            binding.retryAttempt += 1
            model.status = .retrying(attempt: binding.retryAttempt)
            return retryDelays[min(binding.retryAttempt - 1, retryDelays.count - 1)]
        }
    }

    /// Our deadline for one command, below the server's 60 s so the agent gets our explanation: a `wait` gets its own
    /// timeout plus a margin, page loads 45 s, everything else 50 s.
    public nonisolated static func timeout(for command: BrowserCommand) -> Duration {
        switch command.type {
        case "wait":
            let requested = command.action["timeoutMs"]?.intValue ?? 10_000
            return .milliseconds(min(max(requested, 0), 30_000) + 5_000)
        case "navigate", "tabs.open", "reload", "back", "forward": return .seconds(45)
        default: return BrowserContract.defaultCommandTimeout
        }
    }

    private func makeAttachment(_ binding: Binding) -> BrowserAttachment {
        let sessionID = binding.sessionID
        let sink = attachmentEventSink
        let connectionID = UUID().uuidString.lowercased()
        let attachment = BrowserAttachment(
            sessionID: sessionID.rawValue, directory: binding.directory, connectionID: connectionID, client: client,
            inventory: { [weak self] in await self?.inventory(sessionID) ?? BrowserInventory() },
            perform: { [weak self] command in
                await self?.perform(command, sessionID: sessionID)
                    ?? .failure(BrowserFailure(.disconnected, "BelloCode closed this thread's browser. Call browser.tabs.list({}) after the user reopens it."))
            },
            observer: { event in sink.yield((connectionID, event)) },
            commandTimeout: Self.timeout(for:))
        return attachment
    }

    private func inventory(_ sessionID: SessionID) -> BrowserInventory {
        bindings[sessionID]?.host?.browserInventory() ?? BrowserInventory()
    }

    private func perform(_ command: BrowserCommand, sessionID: SessionID) async -> BrowserOutcome {
        guard isControlEnabled(sessionID) else {
            return .failure(BrowserFailure(.controlDisabled, "The user turned off browser control for this thread. Do not retry; ask the user to turn it on if you need the browser."))
        }
        guard let host = bindings[sessionID]?.host else {
            return .failure(BrowserFailure(.disconnected, "This thread's browser is not open in BelloCode. Ask the user to open it, then call browser.tabs.list({})."))
        }
        let interval = signposter.beginInterval("perform")
        defer { signposter.endInterval("perform", interval) }
        return await host.perform(command)
    }

    private func detach(_ binding: Binding, status: BrowserBridgeStatus) {
        binding.task?.cancel()
        binding.task = nil
        if let attachment = binding.attachment {
            routes[attachment.connectionID] = nil
            routeSessions[attachment.connectionID] = nil
            Task { await attachment.stop() }
        }
        binding.attachment = nil
        let model = self.model(for: binding.sessionID)
        model.status = status
        model.running.removeAll()
    }

    private func enforceAttachmentLimit(keeping sessionID: SessionID) {
        let active = bindings.values.filter { $0.attachment != nil || $0.task != nil }
        guard active.count > Self.maxAttachments else { return }
        let victims = active.filter { $0.sessionID != sessionID }.sorted { $0.lastUsed < $1.lastUsed }
            .prefix(active.count - Self.maxAttachments)
        for victim in victims { detach(victim, status: .parked) }
    }

    // MARK: Guidance

    private func putGuidance(_ binding: Binding) {
        guard let guidance = binding.guidance else { return }
        let client = self.client
        let sessionID = binding.sessionID.rawValue
        binding.guidancePut = true
        Task { [log] in
            do {
                try await client().putInstructionEntry(sessionID: sessionID, key: Self.guidanceKey, value: .string(guidance))
            } catch {
                log.error("browser guidance entry not written: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    private func removeGuidance(_ binding: Binding) {
        guard binding.guidance != nil else { return }
        let client = self.client
        let sessionID = binding.sessionID.rawValue
        binding.guidancePut = false
        Task { try? await client().deleteInstructionEntry(sessionID: sessionID, key: Self.guidanceKey) }
    }

    private func saveDisabled() {
        let store = self.store
        let values = Array(disabled.map(\.rawValue).sorted().suffix(Self.disabledLimit))
        Task { try? await store.setPreference(Self.disabledKey, values) }
    }

    // MARK: Event routing

    private func startEventsLoop() {
        guard eventsTask == nil else { return }
        let events = attachmentEvents
        eventsTask = Task { [weak self] in
            for await (connectionID, event) in events {
                guard let self else { return }
                self.handle(event, connectionID: connectionID)
            }
        }
    }

    private func handle(_ event: BrowserAttachmentEvent, connectionID: String) {
        guard let sessionID = routeSessions[connectionID], let model = models[sessionID] else { return }
        switch event {
        case .attached, .stateRejected:
            break
        case .commandStarted(let requestID, let operation):
            model.running[requestID] = operation
            model.commandCount += 1
        case .commandFinished(let requestID, _, let failureCode):
            model.running[requestID] = nil
            if let failureCode { model.lastFailureCode = failureCode }
        case .commandCancelled(let requestID):
            model.running[requestID] = nil
        case .ended(let end):
            routes[connectionID] = nil
            routeSessions[connectionID] = nil
            model.running.removeAll()
            // Only an attachment that was established and then ended; a start failure is handled by the attach loop.
            guard model.status == .attached, let binding = bindings[sessionID], binding.attachment?.connectionID == connectionID
            else { return }
            binding.attachment = nil
            if let delay = handleFailure(end, binding: binding) {
                binding.task?.cancel()
                binding.task = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard let self, !Task.isCancelled else { return }
                    await self.attachLoop(binding)
                }
            }
        }
    }

    private func ensurePump() async {
        guard pumpTask == nil, !isShutdown else { return }
        // Claim the slot before suspending so concurrent callers do not subscribe twice.
        pumpTask = Task {}
        guard let (subscription, connected) = await subscribe() else {
            pumpTask = nil
            try? await Task.sleep(for: .milliseconds(250))
            return
        }
        streamConnected = connected
        if connected { resumeConnectionWaiters() }
        pumpTask = Task { [weak self] in
            for await message in subscription {
                guard let self, !Task.isCancelled else { return }
                await self.receive(message)
            }
        }
    }

    private func receive(_ message: EventHubMessage) async {
        switch message {
        case .event(let envelope):
            guard let control = envelope.browserControl, let id = control.connectionID, let attachment = routes[id] else { return }
            await attachment.receive(control)
        case .resync:
            streamConnected = true
            resumeConnectionWaiters()
            for attachment in routes.values { await attachment.eventStreamResynced() }
        case .disconnected:
            streamConnected = false
        }
    }

    private func waitForConnection() async {
        if streamConnected || isShutdown { return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.resumeConnectionWaiters()
        }
        defer { timer.cancel() }
        await withCheckedContinuation { connectionWaiters.append($0) }
    }

    private func resumeConnectionWaiters() {
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
