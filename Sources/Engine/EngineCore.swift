import BelloCore
import Foundation
import OpenCodeKit

/// Everything the presentation layer needs at launch, read from the cache before any server answers.
public struct EngineSnapshot: Sendable {
    public var projects: [BelloCore.Project]
    public var registry: [ProjectEntry]
    public var sessions: [Session]
    public var statuses: [SessionID: SessionAttention]
    public var attention: AttentionSummary
    public var catalogs: [Catalog]
    public var connection: ConnectionStatus
}

/// A thread as it opens: the newest window of messages plus everything pinned around the composer.
public struct ThreadSnapshot: Sendable {
    public var session: Session?
    public var status: SessionAttention?
    /// Oldest first.
    public var messages: [Message]
    /// Older messages exist (in the cache or on the server).
    public var hasOlder: Bool
    public var pending: [PendingRequest]
    public var queue: [QueuedPrompt]
    public var ui: ThreadUIState
}

/// A page of older messages, oldest first.
public struct OlderMessages: Sendable {
    public var messages: [Message]
    public var hasOlder: Bool
}

/// The engine's actor: owns the in-memory projection, the event loop, resync, write-behind persistence and commands.
///
/// Threading: everything here is isolated to this actor (off the main actor). Network and database calls are awaited;
/// state is only changed in synchronous sections after an await, re-checking the sync generation and cancellation
/// first (AGENTS.md rule 8). Every task it starts is stored and cancelled by `stop()` (rule 9).
///
/// Data flow: EventHub → `EventPipeline` (dedupe, coalesce, reduce) → `commit` → ChangeBus (live, to presentation
/// models) and write-behind batches to the `ProjectionStore`. On every `.resync` it rebuilds from the list endpoints.
actor EngineCore {
    let store: ProjectionStore
    let configuration: EngineConfiguration
    private var bus: ChangeBus { store.changes }
    private var time: any TimeSource { configuration.time }

    private var pipeline: EventPipeline
    private var ids = IdentifierFactory()
    private(set) var connection: ConnectionStatus = .cached
    private var statuses: [SessionID: SessionAttention] = [:]
    private var summary = AttentionSummary.empty
    private var catalogs: [String: Catalog] = [:]

    private var hub: EventHub?
    private var eventTask: Task<Void, Never>?
    private var deltaTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var writeChain: Task<Void, Never>?
    private var effectTask: Task<Void, Never>?
    private var backgroundTasks: [Int: Task<Void, Never>] = [:]
    private var nextTaskID = 0
    private var pendingWrites = StoreBatch()
    private var effectQueue: [SyncEffect] = []
    private let effectLimit = 512
    private var openThreads: [SessionID: Int] = [:]
    /// Optimistic sessions not yet acknowledged; a resync must not delete them.
    private var creatingSessions: Set<SessionID> = []
    /// Incremented by every resync; async work started under an older generation is discarded.
    private var syncGeneration = 0
    private var dynamicGeneration = 0
    private var lastDynamicURL: URL?
    private var started = false

    /// Counters for tests and diagnostics.
    struct Statistics: Sendable {
        var events = 0
        var resyncs = 0
        var writeBatches = 0
        var writeFailures = 0
        var duplicatesDropped = 0
    }

    private(set) var statistics = Statistics()

    init(configuration: EngineConfiguration, store: ProjectionStore) {
        self.configuration = configuration
        self.store = store
        pipeline = EventPipeline(
            state: ProjectionState(messageCapacity: configuration.messageCacheCapacity), cadence: configuration.streamCadence)
    }

    // MARK: - Lifecycle

    /// Loads the cache into memory. Called before connecting, so the UI shows cached content at once.
    func loadCache() async throws -> EngineSnapshot {
        let signpost = EngineSignposts.database.beginInterval("loadCache")
        defer { EngineSignposts.database.endInterval("loadCache", signpost) }
        async let projects = store.projects()
        async let registry = store.registry()
        async let sessions = store.allSessions()
        async let pending = store.pendingRequests()
        async let queue = store.queue()
        async let threadUI = store.threadUIStates()
        async let catalogs = store.catalogs()
        let (p, r, s, pe, q, t, c) = try await (projects, registry, sessions, pending, queue, threadUI, catalogs)
        var state = pipeline.state
        state.projects = Dictionary(p.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        state.registry = Dictionary(r.map { ($0.directory, $0) }, uniquingKeysWith: { $1 })
        state.sessions = Dictionary(s.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        state.pending = Dictionary(pe.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        // An unacknowledged send from a previous run cannot be trusted; the next sync re-reads the inbox.
        state.queue = Dictionary(q.filter { $0.state == .queued }.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        state.threadUI = Dictionary(t.map { ($0.sessionID, $0) }, uniquingKeysWith: { $1 })
        pipeline.state = state
        for catalog in c where self.catalogs[catalog.directory] == nil { self.catalogs[catalog.directory] = catalog }
        recomputeAttention(publish: false)
        return snapshot()
    }

    func snapshot() -> EngineSnapshot {
        EngineSnapshot(
            projects: Array(pipeline.state.projects.values), registry: Array(pipeline.state.registry.values),
            sessions: Array(pipeline.state.sessions.values), statuses: statuses, attention: summary,
            catalogs: Array(catalogs.values), connection: connection)
    }

    /// Starts the server (if supervised) and the event stream.
    func start() async {
        guard !started else { return }
        started = true
        if case .supervised(let supervisor) = configuration.server { await supervisor.start() }
        let connector = URLSessionEventStreamConnector { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.waitForClient()
        }
        let hub = EventHub(connector: connector, backoff: configuration.eventBackoff, defaultBufferLimit: configuration.eventBufferLimit)
        self.hub = hub
        let subscription = await hub.subscribe(.all)
        setConnection(.connecting)
        eventTask = Task { [weak self] in
            for await message in subscription {
                guard let self, !Task.isCancelled else { return }
                await self.receive(message)
            }
        }
        await hub.start()
    }

    /// Stops the event stream, cancels every task this actor started, writes what is pending, and stops a supervised
    /// server.
    func stop() async {
        let hub = self.hub
        self.hub = nil
        eventTask?.cancel()
        eventTask = nil
        await hub?.stop()
        deltaTask?.cancel()
        deltaTask = nil
        effectTask?.cancel()
        effectTask = nil
        for task in backgroundTasks.values { task.cancel() }
        backgroundTasks.removeAll()
        commit(pipeline.flushDeltas(clock: time.now(), now: .now, force: true))
        pendingWrites.messages += pipeline.state.messages.dirtyMessages
        pipeline.state.messages.markPersisted(pipeline.state.messages.dirtyMessages.map(\.id))
        await flushWrites()
        writeTask?.cancel()
        writeTask = nil
        if case .supervised(let supervisor) = configuration.server { await supervisor.stop() }
        setConnection(.stopped)
        started = false
    }

    // MARK: - Server access

    /// The current server, or `.offline` without waiting.
    func currentClient() async throws -> OpenCodeClient {
        switch configuration.server {
        case .supervised(let supervisor):
            guard let endpoint = await supervisor.endpoint else { throw EngineError.offline }
            return OpenCodeClient(endpoint: endpoint)
        case .fixed(let connection):
            return OpenCodeClient(connection: connection)
        case .dynamic(let resolve):
            guard let connection = await resolve() else { throw EngineError.offline }
            return OpenCodeClient(connection: connection)
        }
    }

    /// The server, waiting while it starts or restarts (for the event stream).
    func waitForClient() async throws -> OpenCodeClient {
        switch configuration.server {
        case .supervised(let supervisor):
            return OpenCodeClient(endpoint: try await supervisor.awaitReady())
        case .fixed(let connection):
            return OpenCodeClient(connection: connection)
        case .dynamic(let resolve):
            while true {
                if let connection = await resolve() { return OpenCodeClient(connection: connection) }
                try await time.sleep(for: .milliseconds(50))
            }
        }
    }

    // MARK: - Event loop

    private func receive(_ message: EventHubMessage) async {
        switch message {
        case .event(let envelope):
            await handle(envelope)
        case .resync(let reason):
            await resync(reason)
        case .disconnected(let reason):
            commit(pipeline.flushDeltas(clock: time.now(), now: .now, force: true))
            setConnection(.offline(reason: reason))
        }
    }

    func handle(_ envelope: OpenCodeEventEnvelope) async {
        let signpost = EngineSignposts.events.beginInterval("receive")
        defer { EngineSignposts.events.endInterval("receive", signpost) }
        statistics.events += 1
        if let target = EventReducer.target(of: envelope.event), !pipeline.state.messages.contains(target.message) {
            if let stored = try? await store.messages(ids: [target.message]).first,
                !pipeline.state.messages.contains(target.message)
            {
                pipeline.state.messages.put(stored, persisted: true)
            }
        }
        let reduction = EngineSignposts.events.measure("reduce") {
            pipeline.ingest(envelope, clock: time.now(), now: .now)
        }
        statistics.duplicatesDropped = pipeline.duplicatesDropped
        commit(reduction)
        scheduleDeltaFlush()
    }

    /// Publishes changes, queues writes, re-derives attention and queues effects.
    private func commit(_ reduction: Reduction) {
        guard !reduction.isEmpty else { return }
        if !reduction.changes.isEmpty {
            EngineSignposts.publish.measure("publish") { bus.publish(reduction.changes) }
        }
        if !reduction.writes.isEmpty {
            pendingWrites.merge(reduction.writes)
            scheduleWrite()
        }
        if !reduction.statusDirty.isEmpty { recomputeAttention(publish: true) }
        if !reduction.effects.isEmpty { enqueue(reduction.effects) }
    }

    private func scheduleDeltaFlush() {
        guard deltaTask == nil, let due = pipeline.coalescer.dueAt else { return }
        let delay = max(.zero, due - time.now())
        deltaTask = Task { [weak self, time] in
            try? await time.sleep(for: delay)
            await self?.deltaTick()
        }
    }

    private func deltaTick() {
        deltaTask = nil
        guard !Task.isCancelled else { return }
        commit(pipeline.flushDeltas(clock: time.now(), now: .now))
        scheduleDeltaFlush()
    }

    // MARK: - Persistence

    private func scheduleWrite() {
        guard writeTask == nil else { return }
        let interval = configuration.writeInterval
        writeTask = Task { [weak self, time] in
            try? await time.sleep(for: interval)
            await self?.writeTick()
        }
    }

    private func writeTick() async {
        writeTask = nil
        await flushWrites()
    }

    /// Writes everything pending, in order after any write already in flight.
    func flushWrites() async {
        let batch = pendingWrites
        pendingWrites = StoreBatch()
        let previous = writeChain
        guard !batch.isEmpty else {
            await previous?.value
            return
        }
        let store = self.store
        let task = Task { [weak self] in
            await previous?.value
            do {
                try await store.apply(batch, publish: false)
                await self?.recordWrite(failed: false)
            } catch {
                EngineSignposts.log.error("projection write failed: \(String(describing: type(of: error)), privacy: .public)")
                await self?.recordWrite(failed: true)
            }
        }
        writeChain = task
        await task.value
    }

    private func recordWrite(failed: Bool) {
        statistics.writeBatches += 1
        if failed { statistics.writeFailures += 1 }
    }

    /// Publishes buffered stream deltas and writes everything pending (tests, thread open, shutdown).
    func flush() async {
        commit(pipeline.flushDeltas(clock: time.now(), now: .now, force: true))
        await flushWrites()
    }

    // MARK: - Attention

    private func recomputeAttention(publish: Bool) {
        let state = pipeline.state
        let (newStatuses, newSummary) = AttentionDeriver.derive(
            .init(
                sessions: state.sessions, pending: Array(state.pending.values), stopping: state.stopping,
                threadUI: state.threadUI, connected: connection.isLive || connection == .syncing, now: .now))
        var changes: [ProjectionChange] = []
        for (id, status) in newStatuses where statuses[id] != status { changes.append(.status(status)) }
        let summaryChanged = newSummary != summary
        statuses = newStatuses
        summary = newSummary
        if summaryChanged { changes.append(.attention(newSummary)) }
        if publish, !changes.isEmpty { bus.publish(changes) }
    }

    private func setConnection(_ status: ConnectionStatus) {
        guard status != connection else { return }
        let wasLive = connection.isLive || connection == .syncing
        connection = status
        bus.publish([.connection(status)])
        if wasLive != (status.isLive || status == .syncing) { recomputeAttention(publish: true) }
    }

    // MARK: - Effects

    private func enqueue(_ effects: [SyncEffect]) {
        for effect in effects where !effectQueue.contains(effect) { effectQueue.append(effect) }
        if effectQueue.count > effectLimit {
            // Too far behind to follow individually: a resync re-reads everything.
            effectQueue.removeAll()
            spawn { await $0.resync(.overflow) }
            return
        }
        guard effectTask == nil else { return }
        effectTask = Task { [weak self] in await self?.drainEffects() }
    }

    private func drainEffects() async {
        while !Task.isCancelled, !effectQueue.isEmpty {
            let effect = effectQueue.removeFirst()
            await perform(effect)
        }
        effectTask = nil
    }

    private func perform(_ effect: SyncEffect) async {
        guard let client = try? await currentClient() else { return }
        let generation = syncGeneration
        switch effect {
        case .fetchMessage(let sessionID, let messageID):
            guard let dto = try? await client.message(sessionID: sessionID.rawValue, messageID: messageID.rawValue),
                generation == syncGeneration, !Task.isCancelled
            else { return }
            var reduction = Reduction()
            let merged = SnapshotMerge.message(local: pipeline.state.messages[messageID], server: Mapping.message(dto, sessionID: sessionID))
            pipeline.state.putMessage(merged, persist: true, into: &reduction)
            commit(reduction)
        case .fetchSession(let sessionID):
            guard let dto = try? await client.session(sessionID.rawValue), generation == syncGeneration, !Task.isCancelled else {
                return
            }
            var reduction = Reduction()
            pipeline.state.putSession(mergeSession(local: pipeline.state.sessions[sessionID], server: Mapping.session(dto)), into: &reduction)
            commit(reduction)
        case .refreshCatalog(let directory):
            await refreshCatalog(directory: directory ?? defaultCatalogDirectory())
        }
    }

    private func spawn(_ operation: @escaping @Sendable (EngineCore) async -> Void) {
        nextTaskID += 1
        let id = nextTaskID
        backgroundTasks[id] = Task { [weak self] in
            guard let self else { return }
            await operation(self)
            await self.finishTask(id)
        }
    }

    private func finishTask(_ id: Int) { backgroundTasks[id] = nil }

    // MARK: - Resync

    private struct ServerSnapshot: Sendable {
        var projects: [OpenCodeKit.Project] = []
        var sessions: [SessionInfo] = []
        var sessionsComplete = true
        var permissions: [OpenCodeKit.PermissionRequest] = []
        var forms: [FormInfo] = []
        var pendingComplete = true
        var inbox: [SessionID: [InboxItem]] = [:]
        var windows: [SessionID: Page<SessionMessage>] = [:]
    }

    /// Rebuilds the projection from the list endpoints. Runs on the event loop, so events received meanwhile wait in
    /// the subscription and are applied afterwards (reducers are monotonic, so replaying them is harmless).
    func resync(_ reason: ResyncReason) async {
        let signpost = EngineSignposts.sync.beginInterval("resync")
        defer { EngineSignposts.sync.endInterval("resync", signpost) }
        statistics.resyncs += 1
        setConnection(.syncing)
        commit(pipeline.flushDeltas(clock: time.now(), now: .now, force: true))
        await flushWrites()
        syncGeneration += 1
        let generation = syncGeneration
        for attempt in 1...3 {
            do {
                let client = try await currentClient()
                let snapshot = try await fetchSnapshot(client)
                guard generation == syncGeneration, !Task.isCancelled else { return }
                try await reconcile(snapshot, generation: generation)
                guard generation == syncGeneration, !Task.isCancelled else { return }
                setConnection(.live)
                if catalogs[defaultCatalogDirectory()] == nil { enqueue([.refreshCatalog(directory: nil)]) }
                return
            } catch is CancellationError {
                return
            } catch {
                EngineSignposts.log.error("resync attempt \(attempt, privacy: .public) failed: \(EngineError.from(error).description, privacy: .public)")
                if attempt == 3 {
                    setConnection(.offline(reason: "Could not sync with opencode"))
                    return
                }
                try? await time.sleep(for: .milliseconds(200 * attempt))
            }
        }
    }

    private func fetchSnapshot(_ client: OpenCodeClient) async throws -> ServerSnapshot {
        var snapshot = ServerSnapshot()
        snapshot.projects = try await client.projects()

        var seen = Set<String>()
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await client.sessions(SessionListQuery(limit: configuration.sessionPageSize, cursor: cursor))
            for session in page.data where seen.insert(session.id).inserted { snapshot.sessions.append(session) }
            pages += 1
            cursor = page.data.count < configuration.sessionPageSize ? nil : page.cursor.next
            if cursor != nil, pages >= configuration.maxSessionPages {
                snapshot.sessionsComplete = false
                cursor = nil
            }
        } while cursor != nil

        let directories = Set(snapshot.projects.map(\.canonical)).union(snapshot.sessions.map(\.location.directory))
            .union(pipeline.state.registry.keys)
        let requests = try await boundedMap(Array(directories).sorted()) { directory -> ([OpenCodeKit.PermissionRequest], [FormInfo])? in
            do {
                async let permissions = client.pendingPermissions(directory: directory)
                async let forms = client.pendingForms(directory: directory)
                return try await (permissions, forms)
            } catch let error as OpenCodeError where error.status == 404 {
                return ([], [])
            } catch {
                return nil
            }
        }
        for result in requests {
            guard let (permissions, forms) = result else {
                snapshot.pendingComplete = false
                continue
            }
            snapshot.permissions += permissions
            snapshot.forms += forms
        }

        let running = snapshot.sessions.filter { info in
            guard let busy = info.time.busy else { return false }
            return info.time.idle.map { busy > $0 } ?? true
        }.map { SessionID($0.id) }
        let queued = pipeline.state.queue.values.map(\.sessionID)
        let inboxSessions = Array(Set(running + queued)).sorted()
        let inboxes = try await boundedMap(inboxSessions) { id in (id, try? await client.inbox(sessionID: id.rawValue)) }
        for (id, items) in inboxes { if let items { snapshot.inbox[id] = items } }

        let known = Set(snapshot.sessions.map { SessionID($0.id) })
        let open = openThreads.keys.filter { known.contains($0) }.sorted()
        let windowSize = configuration.windowSize
        let windows = try await boundedMap(open) { id in
            (id, try await client.messages(sessionID: id.rawValue, MessageListQuery(limit: windowSize, order: .descending)))
        }
        for (id, page) in windows { snapshot.windows[id] = page }
        return snapshot
    }

    /// Runs `transform` over `items` with at most `syncConcurrency` in flight; results keep input order.
    private func boundedMap<T: Sendable, R: Sendable>(
        _ items: [T], _ transform: @escaping @Sendable (T) async throws -> R
    ) async throws -> [R] {
        let limit = max(1, configuration.syncConcurrency)
        return try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var results: [R?] = Array(repeating: nil, count: items.count)
            var next = 0
            while next < min(limit, items.count) {
                let index = next
                let item = items[index]
                group.addTask { (index, try await transform(item)) }
                next += 1
            }
            while let (index, result) = try await group.next() {
                results[index] = result
                if next < items.count {
                    let index = next
                    let item = items[index]
                    group.addTask { (index, try await transform(item)) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    private func reconcile(_ snapshot: ServerSnapshot, generation: Int) async throws {
        // Disk reads first (they await); then one synchronous section that changes state.
        var windowInputs: [SessionID: WindowInput] = [:]
        for (id, page) in snapshot.windows {
            windowInputs[id] = try await windowInput(id, page: page)
        }
        guard generation == syncGeneration, !Task.isCancelled else { return }
        let now = Timestamp.now
        var reduction = Reduction()
        var state = pipeline.state

        // Projects: the server list is complete.
        let projects = Dictionary(snapshot.projects.map { (ProjectID($0.id), Mapping.project($0)) }, uniquingKeysWith: { $1 })
        for id in state.projects.keys where projects[id] == nil {
            state.projects[id] = nil
            reduction.changes.append(.projectRemoved(id))
        }
        for project in projects.values.sorted(by: { $0.directory < $1.directory }) { state.putProject(project, into: &reduction) }
        reduction.writes.projects += Array(projects.values)
        reduction.writes.replaceAllProjects = true
        var nextOrder = (state.registry.values.map(\.sortOrder).max() ?? -1) + 1
        let registered = Set(state.registry.values.compactMap(\.projectID))
        for project in projects.values.sorted(by: { $0.created < $1.created })
        where state.registry[project.directory] == nil && !registered.contains(project.id) {
            state.putRegistry(ProjectEntry(directory: project.directory, projectID: project.id, sortOrder: nextOrder, added: now), into: &reduction)
            nextOrder += 1
        }

        // Sessions.
        let sessions = snapshot.sessions.map(Mapping.session)
        let serverIDs = Set(sessions.map(\.id))
        for session in sessions {
            state.putSession(mergeSession(local: state.sessions[session.id], server: session), into: &reduction)
        }
        if snapshot.sessionsComplete {
            for id in state.sessions.keys where !serverIDs.contains(id) && !creatingSessions.contains(id) {
                state.removeSession(id, into: &reduction)
            }
        }
        for session in sessions where !session.isRunning {
            state.stopping.remove(session.id)
            state.openMessage[session.id] = nil
        }

        // Pending requests.
        var serverPending: [PendingRequest] = []
        serverPending += snapshot.permissions.map { .permission(Mapping.permission($0, received: state.pending[$0.id]?.received ?? now)) }
        serverPending += snapshot.forms.map { .question(Mapping.question($0, received: state.pending[$0.id]?.received ?? now)) }
        if snapshot.pendingComplete {
            let keep = Set(serverPending.map(\.id))
            for id in state.pending.keys where !keep.contains(id) { state.resolvePending(id, into: &reduction) }
        }
        for request in serverPending { state.putPending(request, into: &reduction) }

        // Queues: the inbox of running sessions and of sessions we had queued items for.
        for (sessionID, items) in snapshot.inbox {
            let server = items.compactMap(Mapping.queued)
            let keep = Set(server.map(\.id))
            for prompt in state.queue.values where prompt.sessionID == sessionID && prompt.state == .queued && !keep.contains(prompt.id) {
                state.removeQueued(prompt.id, into: &reduction)
            }
            for var prompt in server {
                if let local = state.queue[prompt.id], prompt.text.isEmpty { prompt.text = local.text }
                if state.messages[prompt.id]?.delivery != nil { continue }
                state.putQueued(prompt, into: &reduction)
            }
        }
        for prompt in state.queue.values where prompt.state == .queued && snapshot.inbox[prompt.sessionID] == nil {
            // The session is idle and its inbox was not read: anything we thought queued has been delivered or
            // dropped. The transcript window shows which.
            if !(state.sessions[prompt.sessionID]?.isRunning ?? false) { state.removeQueued(prompt.id, into: &reduction) }
        }

        // Message windows of open threads.
        for (sessionID, input) in windowInputs {
            applyWindow(sessionID, input: input, state: &state, into: &reduction, now: now)
        }
        for id in state.sessions.keys { reduction.statusDirty.insert(id) }
        pipeline.state = state
        commit(reduction)
    }

    /// A fetched newest-first page plus what the cache knows about the same range.
    private struct WindowInput: Sendable {
        var server: [Message]
        var local: [MessageID: Message]
        var cachedInRange: [MessageID]
        var oldestCached: Bool
        var hasOlderCached: Bool
        var full: Bool
        var cursor: String?
        var syncState: SessionSyncState?
    }

    private func windowInput(_ sessionID: SessionID, page: Page<SessionMessage>) async throws -> WindowInput {
        let server = page.data.map { Mapping.message($0, sessionID: sessionID) }.sorted { $0.sortKey < $1.sortKey }
        var local: [MessageID: Message] = [:]
        for message in try await store.messages(ids: server.map(\.id)) { local[message.id] = message }
        var cachedInRange: [MessageID] = []
        var hasOlderCached = false
        if let oldest = server.first, let newest = server.last {
            cachedInRange = try await store.messageIDs(sessionID: sessionID, from: oldest.sortKey, through: newest.sortKey)
            hasOlderCached = try await store.hasMessages(sessionID: sessionID, before: oldest.sortKey)
        }
        return WindowInput(
            server: server, local: local, cachedInRange: cachedInRange,
            oldestCached: server.first.map { local[$0.id] != nil } ?? false, hasOlderCached: hasOlderCached,
            full: page.data.count >= configuration.windowSize, cursor: page.cursor.next,
            syncState: try await store.syncState(sessionID))
    }

    /// Merges a fetched window into the projection: server copies merged onto local ones, local messages missing from
    /// the server's range removed, and a gap before the window (history not contiguous) truncated and announced.
    private func applyWindow(
        _ sessionID: SessionID, input: WindowInput, state: inout ProjectionState, into reduction: inout Reduction, now: Timestamp
    ) {
        let serverIDs = Set(input.server.map(\.id))
        for message in input.server {
            let local = state.messages[message.id] ?? input.local[message.id]
            state.putMessage(SnapshotMerge.message(local: local, server: message), persist: true, into: &reduction)
        }
        let newest = input.server.last?.sortKey
        var candidates = Set(input.cachedInRange)
        for message in state.messages.messages(in: sessionID) {
            if let newest, message.sortKey <= newest, let oldest = input.server.first?.sortKey, message.sortKey >= oldest {
                candidates.insert(message.id)
            }
        }
        if !input.full {
            // The server holds fewer messages than a window: this is the whole history.
            for message in state.messages.messages(in: sessionID) where !serverIDs.contains(message.id) {
                candidates.insert(message.id)
            }
        }
        for id in candidates where !serverIDs.contains(id) {
            if let delivery = state.messages[id]?.delivery, delivery != .delivered { continue }
            state.removeMessage(id, sessionID: sessionID, into: &reduction)
        }
        var sync = input.syncState ?? SessionSyncState(sessionID: sessionID)
        sync.synced = now
        if !input.full {
            if let oldest = input.server.first?.sortKey, input.hasOlderCached {
                reduction.writes.truncatedHistory[sessionID] = oldest
                reduction.changes.append(.threadReset(sessionID))
            } else if input.server.isEmpty {
                for message in state.messages.messages(in: sessionID) where message.delivery == nil || message.delivery == .delivered {
                    state.removeMessage(message.id, sessionID: sessionID, into: &reduction)
                }
            }
            sync.historyComplete = true
            sync.olderCursor = nil
        } else if !input.oldestCached && input.hasOlderCached, let oldest = input.server.first?.sortKey {
            // A gap: the cache's older messages are not known to connect to this window. Drop them; paging refetches.
            reduction.writes.truncatedHistory[sessionID] = oldest
            reduction.changes.append(.threadReset(sessionID))
            for message in state.messages.messages(in: sessionID) where message.sortKey < oldest {
                state.messages.remove(message.id)
            }
            sync.historyComplete = false
            sync.olderCursor = input.cursor
        } else if input.syncState == nil || !input.hasOlderCached {
            sync.historyComplete = false
            sync.olderCursor = input.cursor
        }
        reduction.writes.syncStates.append(sync)
    }

    private func mergeSession(local: Session?, server: Session) -> Session {
        guard let local else { return server }
        var merged = server
        if server.outcome == .failed, server.idleAt == local.idleAt { merged.lastError = local.lastError }
        if merged.permissionMode == nil { merged.permissionMode = local.permissionMode }
        return merged
    }

    // MARK: - Threads

    /// Marks a thread open (its window is refreshed on every resync) and refreshes it now if connected.
    func openThread(_ sessionID: SessionID) {
        openThreads[sessionID, default: 0] += 1
        guard connection.isLive else { return }
        spawn { await $0.refreshWindow(sessionID) }
    }

    func closeThread(_ sessionID: SessionID) {
        guard let count = openThreads[sessionID] else { return }
        openThreads[sessionID] = count > 1 ? count - 1 : nil
    }

    func threadSnapshot(_ sessionID: SessionID) async throws -> ThreadSnapshot {
        commit(pipeline.flushDeltas(clock: time.now(), now: .now, force: true))
        await flushWrites()
        let window = try await store.latestMessages(sessionID: sessionID, limit: configuration.windowSize)
        let sync = try await store.syncState(sessionID)
        var byID = Dictionary(window.messages.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let oldest = window.messages.first?.sortKey
        for live in pipeline.state.messages.messages(in: sessionID) {
            if let stored = byID[live.id] {
                if live.revision >= stored.revision { byID[live.id] = live }
            } else if oldest == nil || live.sortKey >= oldest! || !window.hasOlderCached {
                byID[live.id] = live
            }
        }
        let messages = byID.values.sorted { $0.sortKey < $1.sortKey }
        let state = pipeline.state
        return ThreadSnapshot(
            session: state.sessions[sessionID], status: statuses[sessionID], messages: messages,
            hasOlder: window.hasOlderCached || !(sync?.historyComplete ?? false) && !(messages.isEmpty && sync != nil),
            pending: state.pending.values.filter { $0.sessionID == sessionID }.sorted { $0.received < $1.received },
            queue: state.queue.values.filter { $0.sessionID == sessionID }.sorted { $0.created < $1.created },
            ui: state.threadUI[sessionID] ?? ThreadUIState(sessionID: sessionID))
    }

    /// Re-reads the newest window of a thread from the server.
    func refreshWindow(_ sessionID: SessionID) async {
        guard let client = try? await currentClient() else { return }
        let generation = syncGeneration
        do {
            let page = try await client.messages(
                sessionID: sessionID.rawValue, MessageListQuery(limit: configuration.windowSize, order: .descending))
            let input = try await windowInput(sessionID, page: page)
            guard generation == syncGeneration, !Task.isCancelled, pipeline.state.sessions[sessionID] != nil else { return }
            var reduction = Reduction()
            var state = pipeline.state
            applyWindow(sessionID, input: input, state: &state, into: &reduction, now: .now)
            pipeline.state = state
            commit(reduction)
        } catch {
            EngineSignposts.log.info("window refresh failed: \(EngineError.from(error).description, privacy: .public)")
        }
    }

    /// Older messages before `key`: from the cache, else the next server page (persisted, then read back).
    func loadOlder(_ sessionID: SessionID, before key: MessageSortKey) async throws -> OlderMessages {
        let limit = configuration.pageSize
        let cached = try await store.messages(sessionID: sessionID, before: key, limit: limit)
        if cached.messages.count >= limit { return OlderMessages(messages: cached.messages, hasOlder: true) }
        var sync = try await store.syncState(sessionID)
        if sync?.historyComplete == true { return OlderMessages(messages: cached.messages, hasOlder: cached.hasOlderCached) }
        guard let client = try? await currentClient() else { return OlderMessages(messages: cached.messages, hasOlder: true) }
        if sync?.olderCursor == nil {
            await refreshWindow(sessionID)
            sync = try await store.syncState(sessionID)
            if sync?.historyComplete == true {
                let again = try await store.messages(sessionID: sessionID, before: key, limit: limit)
                return OlderMessages(messages: again.messages, hasOlder: again.hasOlderCached)
            }
        }
        guard let cursor = sync?.olderCursor else { return OlderMessages(messages: cached.messages, hasOlder: cached.hasOlderCached) }
        let generation = syncGeneration
        let page: Page<SessionMessage>
        do {
            page = try await client.messages(sessionID: sessionID.rawValue, MessageListQuery(limit: limit, cursor: cursor))
        } catch let error as OpenCodeError where error.tag == .invalidCursor {
            // The server no longer accepts the cursor: drop the older cache and start again from the newest window.
            var reset = Reduction()
            reset.writes.syncStates = [SessionSyncState(sessionID: sessionID)]
            commit(reset)
            await flushWrites()
            await refreshWindow(sessionID)
            return OlderMessages(messages: cached.messages, hasOlder: true)
        }
        guard generation == syncGeneration, !Task.isCancelled else { throw CancellationError() }
        var reduction = Reduction()
        for dto in page.data {
            let message = Mapping.message(dto, sessionID: sessionID)
            let local = pipeline.state.messages[message.id]
            // Older history goes to disk only; it is not published as live changes.
            reduction.writes.messages.append(SnapshotMerge.message(local: local, server: message))
        }
        let complete = page.data.count < limit
        reduction.writes.syncStates = [
            SessionSyncState(sessionID: sessionID, olderCursor: complete ? nil : page.cursor.next, historyComplete: complete, synced: .now)
        ]
        commit(reduction)
        await flushWrites()
        let again = try await store.messages(sessionID: sessionID, before: key, limit: limit)
        return OlderMessages(messages: again.messages, hasOlder: again.hasOlderCached || !complete)
    }

    // MARK: - Catalog

    private func defaultCatalogDirectory() -> String {
        if let directory = configuration.defaultDirectory { return directory }
        let first = pipeline.state.registry.values.filter { !$0.archived }.min { $0.sortOrder < $1.sortOrder }
        return first?.directory ?? pipeline.state.projects.values.first?.directory ?? "/"
    }

    func catalog(directory: String?) -> Catalog? { catalogs[directory ?? defaultCatalogDirectory()] }

    func refreshCatalog(directory: String) async {
        guard let client = try? await currentClient() else { return }
        do {
            async let providers = client.providers(directory: directory)
            async let models = client.models(directory: directory)
            async let agents = client.agents(directory: directory)
            async let defaultModel = client.defaultModel(directory: directory)
            let catalog = Mapping.catalog(
                directory: directory, providers: try await providers, models: try await models, agents: try await agents,
                defaultModel: try? await defaultModel, fetched: .now)
            guard !Task.isCancelled else { return }
            catalogs[directory] = catalog
            var reduction = Reduction()
            reduction.changes.append(.catalog(catalog))
            reduction.writes.catalogs.append(catalog)
            commit(reduction)
        } catch {
            EngineSignposts.log.info("catalog refresh failed: \(EngineError.from(error).description, privacy: .public)")
        }
    }

    // MARK: - Commands

    /// Runs a server call, translating failures into `EngineError`.
    private func call<T: Sendable>(_ body: (OpenCodeClient) async throws -> T) async throws -> T {
        do {
            return try await body(try await currentClient())
        } catch {
            throw EngineError.from(error)
        }
    }

    func createSession(directory: String, title: String?, agent: String?, model: ModelSelection?, parentID: SessionID?) async throws -> Session {
        let now = Timestamp.now
        let id = ids.sessionID(now: now)
        let projectID = pipeline.state.registry[directory]?.projectID
            ?? pipeline.state.projects.values.first { $0.directory == directory }?.id
        if let projectID {
            // Shown at once; replaced by the server's copy.
            var reduction = Reduction()
            let session = Session(
                id: id, projectID: projectID, parentID: parentID, title: title, directory: directory, agent: agent, model: model,
                created: now, updated: now)
            creatingSessions.insert(id)
            pipeline.state.sessions[id] = session
            reduction.changes.append(.session(session))
            reduction.statusDirty.insert(id)
            commit(reduction)
        }
        defer { creatingSessions.remove(id) }
        do {
            let request = SessionCreateRequest(
                directory: directory, id: id.rawValue, parentID: parentID?.rawValue, title: title, agent: agent,
                model: model.map(Mapping.modelRef))
            let dto = try await call { try await $0.createSession(request) }
            var reduction = Reduction()
            let session = mergeSession(local: pipeline.state.sessions[id], server: Mapping.session(dto))
            pipeline.state.sessions[id] = nil
            pipeline.state.putSession(session, into: &reduction)
            commit(reduction)
            return session
        } catch {
            if let session = pipeline.state.sessions.removeValue(forKey: id) {
                var reduction = Reduction()
                reduction.changes.append(.sessionRemoved(id, projectID: session.projectID))
                reduction.statusDirty.insert(id)
                commit(reduction)
            }
            throw EngineError.from(error)
        }
    }

    func renameSession(_ id: SessionID, title: String) async throws {
        guard let session = pipeline.state.sessions[id] else { throw EngineError.notFound("The thread was not found.") }
        let previous = session.title
        var reduction = Reduction()
        pipeline.state.updateSession(id, into: &reduction) { $0.title = title }
        commit(reduction)
        do {
            try await call { try await $0.updateSession(id.rawValue, SessionUpdateRequest(title: title)) }
        } catch {
            var rollback = Reduction()
            pipeline.state.updateSession(id, into: &rollback) { if $0.title == title { $0.title = previous } }
            commit(rollback)
            throw error
        }
    }

    /// Hides the session at once; the cache row is deleted only after the server confirms.
    func deleteSession(_ id: SessionID) async throws {
        guard let session = pipeline.state.sessions.removeValue(forKey: id) else { throw EngineError.notFound("The thread was not found.") }
        var hide = Reduction()
        hide.changes.append(.sessionRemoved(id, projectID: session.projectID))
        hide.statusDirty.insert(id)
        commit(hide)
        do {
            try await call { try await $0.deleteSession(id.rawValue) }
            var reduction = Reduction()
            pipeline.state.sessions[id] = session
            pipeline.state.removeSession(id, into: &reduction)
            commit(reduction)
        } catch let error as EngineError {
            if case .notFound = error {
                var reduction = Reduction()
                pipeline.state.sessions[id] = session
                pipeline.state.removeSession(id, into: &reduction)
                commit(reduction)
                return
            }
            var restore = Reduction()
            pipeline.state.putSession(session, into: &restore)
            restore.changes.append(.session(session))
            commit(restore)
            throw error
        }
    }

    func setArchived(_ id: SessionID, archived: Bool) async throws {
        guard let previous = pipeline.state.sessions[id] else { throw EngineError.notFound("The thread was not found.") }
        var reduction = Reduction()
        pipeline.state.updateSession(id, into: &reduction) { $0.archivedAt = archived ? .now : nil }
        commit(reduction)
        do {
            try await call { try await $0.updateSession(id.rawValue, SessionUpdateRequest(archived: archived)) }
        } catch {
            var rollback = Reduction()
            pipeline.state.updateSession(id, into: &rollback) { $0.archivedAt = previous.archivedAt }
            commit(rollback)
            throw error
        }
    }

    /// Sends a prompt. Idle: the user message appears at once as `.sending`. Busy: it is listed in the queue as
    /// `.sending` (queue by default, or steer). Either way it becomes `.accepted`/`.queued` only when the server answers.
    /// On failure the optimistic entry is removed and the error thrown (the caller restores the draft).
    func sendPrompt(_ sessionID: SessionID, text: String, delivery: PromptDelivery?) async throws -> MessageID {
        guard let session = pipeline.state.sessions[sessionID] else { throw EngineError.notFound("The thread was not found.") }
        let now = Timestamp.now
        let id = ids.messageID(now: now)
        let busy = session.isRunning || pipeline.state.queue.values.contains { $0.sessionID == sessionID }
        var reduction = Reduction()
        if busy {
            let prompt = QueuedPrompt(id: id, sessionID: sessionID, text: text, delivery: delivery ?? .queue, created: now, state: .sending)
            pipeline.state.queue[id] = prompt
            reduction.changes.append(.queued(prompt))
        } else {
            let latest = pipeline.state.messages.messages(in: sessionID).map(\.created).max()
            let created = max(now, Timestamp(milliseconds: (latest?.milliseconds ?? 0) + 1))
            let message = Message(
                id: id, sessionID: sessionID, kind: .user(UserContent(text: text)), created: created, delivery: .sending)
            pipeline.state.putMessage(message, persist: false, into: &reduction)
        }
        commit(reduction)

        let request = PromptRequest(text: text, id: id.rawValue, delivery: busy ? InboxDelivery(rawValue: (delivery ?? .queue).rawValue) : nil)
        var lastError: (any Error)?
        for attempt in 0..<3 {
            do {
                let item = try await currentClient().prompt(sessionID: sessionID.rawValue, request)
                acknowledgeSend(id, sessionID: sessionID, serverCreated: Timestamp(milliseconds: item.time.created))
                return id
            } catch {
                lastError = error
                // Only a lost answer is retried, with the same ID, so the server admits it at most once.
                guard case OpenCodeError.transport = error, attempt < 2 else { break }
                try? await time.sleep(for: .milliseconds(150 * (attempt + 1)))
            }
        }
        var rollback = Reduction()
        if pipeline.state.queue[id]?.state == .sending { pipeline.state.removeQueued(id, into: &rollback) }
        if pipeline.state.messages[id]?.delivery == .sending { pipeline.state.removeMessage(id, sessionID: sessionID, into: &rollback) }
        commit(rollback)
        throw EngineError.from(lastError ?? EngineError.failed("Send failed."))
    }

    private func acknowledgeSend(_ id: MessageID, sessionID: SessionID, serverCreated: Timestamp) {
        var reduction = Reduction()
        if var prompt = pipeline.state.queue[id], prompt.state == .sending {
            prompt.state = .queued
            prompt.created = serverCreated
            pipeline.state.putQueued(prompt, into: &reduction)
        }
        if pipeline.state.messages[id]?.delivery == .sending {
            pipeline.state.updateMessage(id, persist: true, into: &reduction, create: { nil }) { $0.delivery = .accepted }
        }
        commit(reduction)
    }

    /// Moves a queued prompt to "steer" (deliver at the next step boundary).
    func steerQueued(_ id: MessageID) async throws {
        guard let prompt = pipeline.state.queue[id] else { throw EngineError.notFound("The queued message was already sent.") }
        var reduction = Reduction()
        var steered = prompt
        steered.delivery = .steer
        pipeline.state.putQueued(steered, into: &reduction)
        commit(reduction)
        do {
            try await call { try await $0.updateInboxItem(sessionID: prompt.sessionID.rawValue, inboxID: id.rawValue, delivery: .steer) }
        } catch {
            if pipeline.state.queue[id] != nil {
                var rollback = Reduction()
                pipeline.state.putQueued(prompt, into: &rollback)
                commit(rollback)
            }
            throw error
        }
    }

    /// Withdraws a queued prompt before delivery.
    func cancelQueued(_ id: MessageID) async throws {
        guard let prompt = pipeline.state.queue[id] else { throw EngineError.notFound("The queued message was already sent.") }
        var reduction = Reduction()
        pipeline.state.removeQueued(id, into: &reduction)
        commit(reduction)
        do {
            try await call { try await $0.cancelInboxItem(sessionID: prompt.sessionID.rawValue, inboxID: id.rawValue) }
        } catch {
            var rollback = Reduction()
            pipeline.state.putQueued(prompt, into: &rollback)
            commit(rollback)
            throw error
        }
    }

    /// Asks the server to stop the running turn. The session shows "stopping" at once; events confirm the stop.
    func interrupt(_ sessionID: SessionID) async throws {
        pipeline.state.stopping.insert(sessionID)
        var reduction = Reduction()
        reduction.statusDirty.insert(sessionID)
        commit(reduction)
        do {
            let interrupted = try await call { try await $0.interrupt(sessionID: sessionID.rawValue) }
            if !interrupted {
                pipeline.state.stopping.remove(sessionID)
                var settled = Reduction()
                settled.statusDirty.insert(sessionID)
                commit(settled)
                enqueue([.fetchSession(sessionID)])
            }
        } catch {
            pipeline.state.stopping.remove(sessionID)
            var rollback = Reduction()
            rollback.statusDirty.insert(sessionID)
            commit(rollback)
            throw error
        }
    }

    /// Replies to a permission request. The request is removed when the server acknowledges the reply.
    func replyPermission(_ id: PermissionRequestID, reply: PermissionReply, message: String?) async throws {
        guard let request = pipeline.state.pending[id.rawValue] else { throw EngineError.conflict("The request is no longer pending.") }
        do {
            try await call {
                try await $0.replyPermission(
                    sessionID: request.sessionID.rawValue, requestID: id.rawValue,
                    decision: PermissionDecision(rawValue: reply.rawValue), message: message)
            }
        } catch EngineError.notFound(let detail) {
            resolve(id.rawValue)
            throw EngineError.conflict(detail)
        }
        resolve(id.rawValue)
    }

    func replyQuestion(_ id: QuestionID, answers: [String: QuestionAnswer]) async throws {
        guard let request = pipeline.state.pending[id.rawValue] else { throw EngineError.conflict("The question is no longer pending.") }
        do {
            try await call {
                try await $0.replyForm(
                    sessionID: request.sessionID.rawValue, formID: id.rawValue, answer: answers.mapValues(Mapping.formValue))
            }
        } catch let error as EngineError {
            if case .conflict = error { resolve(id.rawValue) }
            if case .notFound = error { resolve(id.rawValue) }
            throw error
        }
        resolve(id.rawValue)
    }

    func dismissQuestion(_ id: QuestionID) async throws {
        guard let request = pipeline.state.pending[id.rawValue] else { throw EngineError.conflict("The question is no longer pending.") }
        do {
            try await call { try await $0.cancelForm(sessionID: request.sessionID.rawValue, formID: id.rawValue) }
        } catch let error as EngineError {
            if case .conflict = error { resolve(id.rawValue) }
            throw error
        }
        resolve(id.rawValue)
    }

    private func resolve(_ id: String) {
        var reduction = Reduction()
        pipeline.state.resolvePending(id, into: &reduction)
        commit(reduction)
    }

    /// Records that the user looked at the thread: the local watermark moves at once, and opencode's `viewed` follows.
    func markViewed(_ sessionID: SessionID) async throws {
        var ui = pipeline.state.threadUI[sessionID] ?? ThreadUIState(sessionID: sessionID)
        ui.visitWatermark = .now
        var reduction = Reduction()
        pipeline.state.putThreadUI(ui, into: &reduction)
        commit(reduction)
        guard let session = pipeline.state.sessions[sessionID], let idle = session.idleAt,
            session.viewedAt == nil || idle > session.viewedAt!
        else { return }
        try await call { try await $0.viewSession(sessionID.rawValue, idle: idle.milliseconds) }
        var viewed = Reduction()
        pipeline.state.updateSession(sessionID, into: &viewed) { session in
            if session.viewedAt == nil || idle > session.viewedAt! { session.viewedAt = idle }
        }
        commit(viewed)
    }

    func setModel(_ sessionID: SessionID, model: ModelSelection) async throws {
        try await optimisticSession(sessionID, { $0.model = model }) { client in
            try await client.switchModel(sessionID: sessionID.rawValue, model: Mapping.modelRef(model))
        }
    }

    func setAgent(_ sessionID: SessionID, agent: String) async throws {
        try await optimisticSession(sessionID, { $0.agent = agent }) { client in
            try await client.switchAgent(sessionID: sessionID.rawValue, agent: agent)
        }
    }

    func setPermissionMode(_ sessionID: SessionID, mode: PermissionMode) async throws {
        try await optimisticSession(sessionID, { $0.permissionMode = mode }) { client in
            try await client.updateSession(sessionID.rawValue, SessionUpdateRequest(permissions: PermissionModeRules.rules(for: mode)))
        }
    }

    private func optimisticSession(
        _ id: SessionID, _ change: (inout Session) -> Void, request: @Sendable (OpenCodeClient) async throws -> Void
    ) async throws {
        guard let previous = pipeline.state.sessions[id] else { throw EngineError.notFound("The thread was not found.") }
        var reduction = Reduction()
        pipeline.state.updateSession(id, into: &reduction, change)
        let expected = pipeline.state.sessions[id]
        commit(reduction)
        do {
            try await call(request)
        } catch {
            if pipeline.state.sessions[id] == expected {
                var rollback = Reduction()
                pipeline.state.putSession(previous, into: &rollback)
                commit(rollback)
            }
            throw error
        }
    }

    // MARK: - App-owned state

    func updateThreadUI(_ sessionID: SessionID, _ body: @Sendable (inout ThreadUIState) -> Void) {
        var ui = pipeline.state.threadUI[sessionID] ?? ThreadUIState(sessionID: sessionID)
        body(&ui)
        var reduction = Reduction()
        pipeline.state.putThreadUI(ui, into: &reduction)
        commit(reduction)
    }

    /// Adds a folder to the sidebar. opencode learns about it on first use; this asks for its agents to activate it.
    func addProject(directory: String) async {
        var reduction = Reduction()
        if var existing = pipeline.state.registry[directory] {
            existing.archived = false
            pipeline.state.putRegistry(existing, into: &reduction)
        } else {
            let order = (pipeline.state.registry.values.map(\.sortOrder).max() ?? -1) + 1
            let projectID = pipeline.state.projects.values.first { $0.directory == directory }?.id
            pipeline.state.putRegistry(ProjectEntry(directory: directory, projectID: projectID, sortOrder: order, added: .now), into: &reduction)
        }
        commit(reduction)
        guard let client = try? await currentClient() else { return }
        _ = try? await client.agents(directory: directory)
        guard let projects = try? await client.projects() else { return }
        var update = Reduction()
        for project in projects { pipeline.state.putProject(Mapping.project(project), into: &update) }
        commit(update)
    }

    /// Hides a project from the sidebar (opencode data is untouched). Reversible with `addProject`.
    func removeProject(directory: String) {
        guard var entry = pipeline.state.registry[directory] else { return }
        entry.archived = true
        var reduction = Reduction()
        pipeline.state.putRegistry(entry, into: &reduction)
        commit(reduction)
    }

    func setProjectPinned(directory: String, pinned: Bool) {
        guard var entry = pipeline.state.registry[directory] else { return }
        entry.pinned = pinned
        var reduction = Reduction()
        pipeline.state.putRegistry(entry, into: &reduction)
        commit(reduction)
    }

    /// Moves a project to `index` in the sidebar order.
    func moveProject(directory: String, to index: Int) {
        var ordered = pipeline.state.registry.values.sorted { $0.sortOrder < $1.sortOrder }
        guard let from = ordered.firstIndex(where: { $0.directory == directory }) else { return }
        let entry = ordered.remove(at: from)
        ordered.insert(entry, at: max(0, min(index, ordered.count)))
        var reduction = Reduction()
        for (order, var item) in ordered.enumerated() where item.sortOrder != order {
            item.sortOrder = order
            pipeline.state.putRegistry(item, into: &reduction)
        }
        commit(reduction)
    }

    // MARK: - Reads for presentation

    func sessions(projectID: ProjectID) -> (sessions: [Session], statuses: [SessionID: SessionAttention]) {
        let sessions = pipeline.state.sessions.values.filter { $0.projectID == projectID }
        var result: [SessionID: SessionAttention] = [:]
        for session in sessions { result[session.id] = statuses[session.id] }
        return (sessions, result)
    }

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        await flushWrites()
        return try await store.search(query, limit: limit)
    }

    /// The in-memory projection, for tests.
    var projectionForTesting: ProjectionState { pipeline.state }
}
