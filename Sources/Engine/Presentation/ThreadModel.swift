import BelloCore
import Foundation
import Observation

/// One message's view state.
///
/// Threading: `@MainActor`. Replaced only when the engine publishes a higher `revision`, so a streaming token
/// invalidates exactly this model (the tail message), never the thread's message list or other messages.
@MainActor
@Observable
public final class MessageModel: Identifiable {
    public let id: MessageID
    public private(set) var message: Message

    init(_ message: Message) {
        id = message.id
        self.message = message
    }

    /// Cache parsed Markdown and layout by `(id, revision)` and the rendering parameters.
    public var revision: Int { message.revision }

    /// Applies a newer copy; returns whether anything changed.
    @discardableResult
    func update(_ newer: Message, force: Bool = false) -> Bool {
        guard force ? newer != message : newer.revision > message.revision else { return false }
        message = newer
        return true
    }
}

/// Everything one open thread shows: its messages (as stable IDs plus per-message models), pending approvals and
/// questions, the follow-up queue, and composer-relevant state.
///
/// Threading and ownership: `@MainActor`. Created by `Engine.openThread(_:)`, which returns the same instance while it
/// is open; call `close()` when the thread leaves the screen (the engine closes any left open at `stop()`). It
/// subscribes to its own `.thread` topic only, so other threads' traffic never wakes it.
///
/// Invalidation: `messageIDs` changes only when a message is added, removed or reordered; streaming changes reach only
/// the affected `MessageModel` (`message(_:)`). Follow-tail and scroll position are the view's concern and live
/// outside this model.
///
/// Content appears from the cache first (`phase == .cached`), then reconciles with the server; it is never blank while
/// loading unless the cache has nothing.
@MainActor
@Observable
public final class ThreadModel: Identifiable {
    public enum Phase: Hashable, Sendable {
        /// Opened; the cached window is being read (milliseconds).
        case opening
        /// Showing the cached window.
        case ready
        /// The thread was deleted on the server.
        case deleted
    }

    public let sessionID: SessionID
    public nonisolated var id: SessionID { sessionID }

    public private(set) var phase: Phase = .opening
    public private(set) var session: Session?
    public private(set) var status: SessionAttention?
    /// Loaded messages, oldest first. Identity is the server's message ID.
    public private(set) var messageIDs: [MessageID] = []
    /// Older messages exist (in the cache or on the server); call `loadOlder()`.
    public private(set) var hasOlder = false
    public private(set) var isLoadingOlder = false
    /// Approvals and questions blocking this thread, oldest first, including those of its child sessions (sub-agents):
    /// a request whose `sessionID` differs from `sessionID` came from that child. Shown pinned above the composer.
    public private(set) var pendingRequests: [PendingRequest] = []
    /// Requests whose reply is in flight (show them disabled, not gone).
    public private(set) var submittingRequestIDs: Set<String> = []
    /// Follow-ups admitted (or being admitted) but not yet delivered, oldest first.
    public private(set) var queue: [QueuedPrompt] = []
    /// The last command failure, for an inline error; cleared by the next successful command.
    public private(set) var lastError: EngineError?
    /// App-owned per-thread state (pin, snooze, settle, scroll anchor). The draft is `draft`.
    public private(set) var uiState: ThreadUIState

    /// The unsent composer text. Persisted (debounced) and restored on relaunch.
    public var draft: String {
        didSet {
            guard draft != oldValue else { return }
            scheduleDraftSave()
        }
    }

    @ObservationIgnored private var models: [MessageID: MessageModel] = [:]
    @ObservationIgnored private var keys: [MessageID: MessageSortKey] = [:]
    @ObservationIgnored private let core: EngineCore
    @ObservationIgnored private let tasks = TaskBox()
    @ObservationIgnored private var loadGeneration = 0
    /// Older pages were loaded; the server's newest-window flag no longer describes this window.
    @ObservationIgnored private var didPage = false
    @ObservationIgnored private var subscription: ChangeSubscription?
    @ObservationIgnored private weak var engine: Engine?

    init(sessionID: SessionID, core: EngineCore, store: ProjectionStore, engine: Engine) {
        self.sessionID = sessionID
        self.core = core
        self.engine = engine
        uiState = ThreadUIState(sessionID: sessionID)
        draft = ""
        let subscription = store.observe(.thread(sessionID))
        self.subscription = subscription
        tasks.set(
            "changes",
            Task { [weak self] in
                for await change in subscription {
                    guard let self else { return }
                    self.apply(change)
                }
            })
        reload()
    }

    // MARK: - Derived state

    /// The model for one message.
    public func message(_ id: MessageID) -> MessageModel? { models[id] }

    /// A turn is running (or stopping).
    public var isRunning: Bool {
        switch status?.status {
        case .running, .stopping, .awaitingApproval, .awaitingAnswer: true
        case .unknown, .failed, .finishedUnread, .idle: false
        case nil: session?.isRunning ?? false
        }
    }

    /// The user asked to stop and the server has not confirmed yet.
    public var isStopping: Bool { status?.status == .stopping }

    /// What Return does in the composer: send now when idle, queue (or steer) while running.
    public var sendMode: PromptDelivery? { isRunning ? .queue : nil }

    // MARK: - Commands

    /// Sends `text` (default: the draft). Idle: appears at once as `.sending`. Running: queued (or steered). On
    /// failure the text returns to the draft and `lastError` is set. Returns the message ID once the server admitted it.
    @discardableResult
    public func send(_ text: String? = nil, delivery: PromptDelivery? = nil) async -> MessageID? {
        let text = text ?? draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let fromDraft = text == draft
        if fromDraft { draft = "" }
        do {
            let id = try await core.sendPrompt(sessionID, text: text, delivery: delivery)
            lastError = nil
            return id
        } catch {
            lastError = EngineError.from(error)
            if fromDraft, draft.isEmpty { draft = text }
            return nil
        }
    }

    /// Stops the running turn. Shows "Stopping" at once; the server's events confirm.
    public func stop() async { await run { try await $0.interrupt(self.sessionID) } }

    public func steer(_ id: MessageID) async { await run { try await $0.steerQueued(id) } }

    public func cancelQueued(_ id: MessageID) async { await run { try await $0.cancelQueued(id) } }

    /// Replies to a permission request: once, always (for its listed scopes) or reject.
    public func reply(to id: PermissionRequestID, _ reply: PermissionReply, message: String? = nil) async {
        submittingRequestIDs.insert(id.rawValue)
        defer { submittingRequestIDs.remove(id.rawValue) }
        await run { try await $0.replyPermission(id, reply: reply, message: message) }
    }

    public func answer(_ id: QuestionID, _ answers: [String: QuestionAnswer]) async {
        submittingRequestIDs.insert(id.rawValue)
        defer { submittingRequestIDs.remove(id.rawValue) }
        await run { try await $0.replyQuestion(id, answers: answers) }
    }

    public func dismiss(_ id: QuestionID) async {
        submittingRequestIDs.insert(id.rawValue)
        defer { submittingRequestIDs.remove(id.rawValue) }
        await run { try await $0.dismissQuestion(id) }
    }

    public func setModel(_ model: ModelSelection) async { await run { try await $0.setModel(self.sessionID, model: model) } }
    public func setAgent(_ agent: String) async { await run { try await $0.setAgent(self.sessionID, agent: agent) } }
    public func setPermissionMode(_ mode: PermissionMode) async {
        await run { try await $0.setPermissionMode(self.sessionID, mode: mode) }
    }

    /// Marks the thread seen (clears "finished, unread"; approvals and questions stay until answered).
    public func markViewed() async { await run { try await $0.markViewed(self.sessionID) } }

    /// Updates app-owned thread state (pin, snooze, settle, scroll anchor).
    public func updateUIState(_ body: @escaping @Sendable (inout ThreadUIState) -> Void) {
        body(&uiState)
        let id = sessionID
        let core = self.core
        engine?.track(Task { await core.updateThreadUI(id, body) })
    }

    public func clearError() { lastError = nil }

    private func run(_ body: @escaping (EngineCore) async throws -> Void) async {
        do {
            try await body(core)
            lastError = nil
        } catch {
            lastError = EngineError.from(error)
        }
    }

    // MARK: - Paging

    /// Loads the previous page (from the cache, else the server) and prepends it.
    public func loadOlder() async {
        guard hasOlder, !isLoadingOlder, let first = messageIDs.first, let key = keys[first] else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let generation = loadGeneration
        do {
            let page = try await core.loadOlder(sessionID, before: key)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            var older: [MessageID] = []
            for message in page.messages where models[message.id] == nil && message.sortKey < key {
                models[message.id] = MessageModel(message)
                keys[message.id] = message.sortKey
                older.append(message.id)
            }
            if !older.isEmpty { messageIDs = older + messageIDs }
            didPage = true
            hasOlder = page.hasOlder
        } catch {
            if !(error is CancellationError) { lastError = EngineError.from(error) }
        }
    }

    /// Unsubscribes, saves the draft and tells the engine the thread is no longer shown.
    public func close() {
        saveDraftNow()
        subscription?.cancel()
        subscription = nil
        tasks.cancelAll()
        engine?.threadClosed(self)
    }

    // MARK: - Applying changes

    private func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let core = self.core
        let id = sessionID
        tasks.set(
            "reload",
            Task { [weak self] in
                guard let snapshot = try? await core.threadSnapshot(id) else { return }
                guard let self, generation == self.loadGeneration, !Task.isCancelled else { return }
                self.applySnapshot(snapshot)
            })
    }

    private func applySnapshot(_ snapshot: ThreadSnapshot) {
        let signpost = EngineSignposts.publish.beginInterval("threadSnapshot")
        defer { EngineSignposts.publish.endInterval("threadSnapshot", signpost) }
        session = snapshot.session
        status = snapshot.status
        var newModels: [MessageID: MessageModel] = [:]
        var newKeys: [MessageID: MessageSortKey] = [:]
        for message in snapshot.messages {
            if let existing = models[message.id] {
                existing.update(message, force: true)
                newModels[message.id] = existing
            } else {
                newModels[message.id] = MessageModel(message)
            }
            newKeys[message.id] = message.sortKey
        }
        models = newModels
        keys = newKeys
        let ids = snapshot.messages.map(\.id)
        if ids != messageIDs { messageIDs = ids }
        hasOlder = snapshot.hasOlder
        pendingRequests = snapshot.pending
        queue = snapshot.queue
        uiState = snapshot.ui
        if phase == .opening {
            draft = snapshot.ui.draft
            tasks.remove("draft")
        }
        if phase != .deleted { phase = .ready }
    }

    private func apply(_ change: ChangeSet) {
        let signpost = EngineSignposts.publish.beginInterval("threadApply")
        defer { EngineSignposts.publish.endInterval("threadApply", signpost) }
        if change.overflowed || change.resetThreads.contains(sessionID) {
            reload()
            return
        }
        if change.removedSessions.contains(sessionID) {
            session = nil
            phase = .deleted
        }
        if let updated = change.sessions[sessionID], updated != session { session = updated }
        if let updated = change.statuses[sessionID], updated != status { status = updated }
        if !change.removedMessages.isEmpty {
            let removed = change.removedMessages.filter { models[$0] != nil }
            if !removed.isEmpty {
                for id in removed {
                    models[id] = nil
                    keys[id] = nil
                }
                messageIDs.removeAll { removed.contains($0) }
            }
        }
        if !change.messages.isEmpty { upsert(change.messages.values.sorted { $0.sortKey < $1.sortKey }) }
        if !change.pending.isEmpty || !change.resolvedRequests.isEmpty {
            var byID = Dictionary(pendingRequests.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            for id in change.resolvedRequests { byID[id] = nil }
            for (id, request) in change.pending { byID[id] = request }
            let updated = byID.values.sorted { $0.received == $1.received ? $0.id < $1.id : $0.received < $1.received }
            if updated != pendingRequests { pendingRequests = updated }
        }
        if !change.queue.isEmpty || !change.removedQueue.isEmpty {
            var byID = Dictionary(queue.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            for id in change.removedQueue { byID[id] = nil }
            for (id, prompt) in change.queue { byID[id] = prompt }
            let updated = byID.values.sorted { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created }
            if updated != queue { queue = updated }
        }
        if let serverHasOlder = change.historyHasOlder[sessionID], !didPage, serverHasOlder != hasOlder {
            hasOlder = serverHasOlder
        }
        if let ui = change.threadUI[sessionID] {
            // The draft is owned here while open; other fields follow the store.
            var merged = ui
            merged.draft = uiState.draft
            if merged != uiState { uiState = merged }
        }
    }

    private func upsert(_ messages: [Message]) {
        var ids = messageIDs
        var listChanged = false
        for message in messages {
            if let model = models[message.id] {
                guard message.revision > model.revision else { continue }
                model.update(message)
                if keys[message.id] != message.sortKey {
                    keys[message.id] = message.sortKey
                    ids.removeAll { $0 == message.id }
                    insert(message.id, key: message.sortKey, into: &ids)
                    listChanged = true
                }
            } else {
                // Only messages inside the loaded window; older ones arrive through `loadOlder()`.
                if hasOlder, let first = ids.first, let firstKey = keys[first], message.sortKey < firstKey { continue }
                models[message.id] = MessageModel(message)
                keys[message.id] = message.sortKey
                insert(message.id, key: message.sortKey, into: &ids)
                listChanged = true
            }
        }
        if listChanged { messageIDs = ids }
    }

    private func insert(_ id: MessageID, key: MessageSortKey, into ids: inout [MessageID]) {
        if let last = ids.last, let lastKey = keys[last], lastKey < key {
            ids.append(id)
            return
        }
        var low = 0
        var high = ids.count
        while low < high {
            let mid = (low + high) / 2
            if let midKey = keys[ids[mid]], midKey < key { low = mid + 1 } else { high = mid }
        }
        ids.insert(id, at: low)
    }

    // MARK: - Draft

    private func scheduleDraftSave() {
        let text = draft
        let id = sessionID
        let core = self.core
        tasks.set(
            "draft",
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await core.updateThreadUI(id) { $0.draft = text }
            })
    }

    private func saveDraftNow() {
        tasks.remove("draft")
        let text = draft
        let id = sessionID
        let core = self.core
        engine?.track(Task { await core.updateThreadUI(id) { $0.draft = text } })
    }

    /// For tests and diagnostics: the number of message models held.
    var loadedMessageCount: Int { models.count }
}
