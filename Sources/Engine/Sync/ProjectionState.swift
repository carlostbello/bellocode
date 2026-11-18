import BelloCore
import Foundation

/// The in-memory projection reducers work on: the complete session index, pending requests and queue, and a bounded
/// cache of recently touched messages. Owned by `EngineCore`; a plain value so reducers can be tested without it.
struct ProjectionState: Sendable {
    var projects: [ProjectID: Project] = [:]
    var registry: [String: ProjectEntry] = [:]
    var sessions: [SessionID: Session] = [:]
    var pending: [String: PendingRequest] = [:]
    /// Permission requests of Auto sessions awaiting BelloCode's policy (docs/features/auto-mode.md): not shown and not
    /// counted until the policy escalates them (then they move to `pending` with their escalation) or the server
    /// resolves them. Never persisted: after a relaunch the server lists them again and they are triaged again.
    var autoTriage: [String: PermissionRequest] = [:]
    /// Triage entries handed to the Auto service (each is handed over once).
    var autoDispatched: Set<String> = []
    /// Why Auto escalated a request, kept so a resync re-lists it with its reason.
    var autoEscalations: [String: AutoEscalation] = [:]
    /// Configured code roots (`Engine.codeRoots`): in scope for the risk policy.
    var codeRoots: [String] = []
    var queue: [MessageID: QueuedPrompt] = [:]
    var threadUI: [SessionID: ThreadUIState] = [:]
    var messages: MessageCache
    /// Sessions the user asked to stop whose stop the server has not confirmed.
    var stopping: Set<SessionID> = []
    /// Sessions the server reports busy although their execution belonged to a server process that has since died
    /// (opencode keeps `time.busy` set after a crash). Shown as "Status unknown" until a new execution event arrives.
    var orphaned: Set<SessionID> = []
    /// Orphaned turns the user marked stopped, with the time: the server still lists them busy (nothing it runs owns
    /// them), so merges keep them idle until the server starts a newer execution.
    var settledOrphans: [SessionID: Timestamp] = [:]
    /// The assistant message currently streaming in each session.
    var openMessage: [SessionID: MessageID] = [:]
    /// Queue edits the user made that the server has not confirmed by event yet. An older view of the inbox (a late
    /// `session.inbox.enqueued`, or an inbox read before the edit reached the server) must not undo them.
    private(set) var queueEdits: [MessageID: QueueEdit] = [:]
    private var queueEditOrder: [MessageID] = []
    /// Unconfirmed edits kept at most (oldest forgotten first: the server's event or the next resync then decides).
    static let queueEditLimit = 256

    init(messageCapacity: Int = 2048) {
        messages = MessageCache(capacity: messageCapacity)
    }
}

/// A queue edit made locally and not yet confirmed by the server's events.
enum QueueEdit: Sendable, Equatable {
    /// The user withdrew the item (`DELETE …/inbox/{id}`).
    case withdrawn
    /// The user changed how it is delivered (`PATCH …/inbox/{id}`).
    case delivery(PromptDelivery)
}

/// A bounded LRU of messages. Messages with live changes not yet written (streamed text) are reported on eviction so
/// the caller persists them rather than losing them.
struct MessageCache: Sendable {
    let capacity: Int
    private var entries: [MessageID: Message] = [:]
    private var lastUse: [MessageID: UInt64] = [:]
    /// When each message was last put (inserted or replaced), on the same clock as `lastUse`.
    private var lastPut: [MessageID: UInt64] = [:]
    private var tick: UInt64 = 0
    /// Messages whose latest state is only in memory.
    private(set) var unpersisted: Set<MessageID> = []

    init(capacity: Int) {
        self.capacity = max(16, capacity)
    }

    var count: Int { entries.count }

    subscript(id: MessageID) -> Message? { entries[id] }

    func contains(_ id: MessageID) -> Bool { entries[id] != nil }

    /// A point on the cache's clock. Read it before a server read; `putSince(_:)` then tells what changed meanwhile.
    var now: UInt64 { tick }

    /// Whether `id` was put (by an event, a send or a fetch) after `mark`, a value of `now` read earlier.
    func putSince(_ mark: UInt64, _ id: MessageID) -> Bool { (lastPut[id] ?? 0) > mark }

    /// Inserts or replaces; returns unpersisted messages evicted to make room (write them).
    @discardableResult
    mutating func put(_ message: Message, persisted: Bool) -> [Message] {
        tick += 1
        entries[message.id] = message
        lastUse[message.id] = tick
        lastPut[message.id] = tick
        if persisted { unpersisted.remove(message.id) } else { unpersisted.insert(message.id) }
        return evictIfNeeded()
    }

    mutating func touch(_ id: MessageID) {
        guard entries[id] != nil else { return }
        tick += 1
        lastUse[id] = tick
    }

    mutating func remove(_ id: MessageID) {
        entries[id] = nil
        lastUse[id] = nil
        lastPut[id] = nil
        unpersisted.remove(id)
    }

    mutating func removeAll(in sessionID: SessionID) {
        for (id, message) in entries where message.sessionID == sessionID { remove(id) }
    }

    mutating func markPersisted(_ ids: some Sequence<MessageID>) {
        for id in ids { unpersisted.remove(id) }
    }

    /// Unpersisted messages, to flush at shutdown or before a resync.
    var dirtyMessages: [Message] { unpersisted.compactMap { entries[$0] } }

    func messages(in sessionID: SessionID) -> [Message] {
        entries.values.filter { $0.sessionID == sessionID }
    }

    private mutating func evictIfNeeded() -> [Message] {
        guard entries.count > capacity else { return [] }
        let excess = entries.count - capacity + capacity / 10
        let victims = lastUse.sorted { $0.value < $1.value }.prefix(excess).map(\.key)
        var evicted: [Message] = []
        for id in victims {
            if unpersisted.contains(id), let message = entries[id] { evicted.append(message) }
            remove(id)
        }
        return evicted
    }
}

/// Side effects a reducer asks for. Performed by the engine after the reduction is applied.
enum SyncEffect: Hashable, Sendable {
    /// A user message was delivered whose text this client never saw.
    case fetchMessage(SessionID, MessageID)
    /// An event referenced a session the projection does not know.
    case fetchSession(SessionID)
    /// The provider, model or agent catalog changed for a location (nil: the default location).
    case refreshCatalog(directory: String?)
    /// An added folder has no opencode project of its own directory (a subfolder of a repository, or not used yet):
    /// ask the server which project it belongs to (`GET /api/location`) and record that ID.
    case resolveProject(directory: String)
}

/// What one reduction produced: changes to publish, writes to persist, effects to run.
struct Reduction: Sendable {
    var changes: [ProjectionChange] = []
    var writes = StoreBatch()
    var effects: [SyncEffect] = []
    /// Sessions whose derived status may have changed.
    var statusDirty: Set<SessionID> = []
    /// A permission request entered Auto triage: wake the Auto service.
    var autoTriage = false
    /// Full-access risk notices found on tool calls (for the audit log and Needs you).
    var riskNotices: [RiskNoticeEvent] = []

    var isEmpty: Bool { changes.isEmpty && writes.isEmpty && effects.isEmpty && statusDirty.isEmpty && !autoTriage && riskNotices.isEmpty }

    mutating func merge(_ other: Reduction) {
        changes += other.changes
        writes.merge(other.writes)
        effects += other.effects
        statusDirty.formUnion(other.statusDirty)
        autoTriage = autoTriage || other.autoTriage
        riskNotices += other.riskNotices
    }
}

extension ProjectionState {
    // MARK: Mutation helpers shared by reducers and commands. Each records its change, write and status impact.

    mutating func putSession(_ session: Session, into reduction: inout Reduction) {
        guard sessions[session.id] != session else { return }
        sessions[session.id] = session
        reduction.changes.append(.session(session))
        reduction.writes.sessions.append(session)
        reduction.statusDirty.insert(session.id)
    }

    mutating func updateSession(_ id: SessionID, into reduction: inout Reduction, _ body: (inout Session) -> Void) {
        guard var session = sessions[id] else { return }
        body(&session)
        putSession(session, into: &reduction)
    }

    mutating func removeSession(_ id: SessionID, into reduction: inout Reduction) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        messages.removeAll(in: id)
        for (key, request) in pending where request.sessionID == id { pending[key] = nil }
        for (key, prompt) in queue where prompt.sessionID == id { queue[key] = nil }
        stopping.remove(id)
        openMessage[id] = nil
        reduction.changes.append(.sessionRemoved(id, projectID: session.projectID))
        reduction.writes.removedSessions.append(id)
        reduction.statusDirty.insert(id)
        if let parent = session.parentID { reduction.statusDirty.insert(parent) }
    }

    /// Updates (or creates) a message. Bumps `revision` only when something changed. `persist: false` keeps the change
    /// in memory (streamed deltas); it is written with the next persisted change or on eviction.
    mutating func updateMessage(
        _ id: MessageID, persist: Bool, into reduction: inout Reduction, create: () -> Message?,
        _ body: (inout Message) -> Void
    ) {
        let existing = messages[id]
        guard var message = existing ?? create() else { return }
        let before = message
        body(&message)
        if let existing {
            message.revision = existing.revision
            if message == existing {
                messages.touch(id)
                if persist, messages.unpersisted.contains(id) {
                    reduction.writes.messages.append(message)
                    messages.markPersisted([id])
                }
                return
            }
            message.revision = existing.revision + 1
        } else {
            message.revision = max(before.revision, 1)
        }
        commit(message, persist: persist, into: &reduction)
    }

    mutating func putMessage(_ message: Message, persist: Bool, into reduction: inout Reduction) {
        var message = message
        if let existing = messages[message.id] {
            var comparable = message
            comparable.revision = existing.revision
            if comparable == existing { return }
            message.revision = max(message.revision, existing.revision + 1)
        }
        commit(message, persist: persist, into: &reduction)
    }

    private mutating func commit(_ message: Message, persist: Bool, into reduction: inout Reduction) {
        let evicted = messages.put(message, persisted: persist)
        reduction.changes.append(.message(message))
        if persist { reduction.writes.messages.append(message) }
        reduction.writes.messages += evicted
    }

    mutating func removeMessage(_ id: MessageID, sessionID: SessionID, into reduction: inout Reduction) {
        messages.remove(id)
        reduction.changes.append(.messageRemoved(id, sessionID: sessionID))
        reduction.writes.removedMessages.append(id)
    }

    mutating func putPending(_ request: PendingRequest, into reduction: inout Reduction) {
        if var existing = pending[request.id] {
            // Keep the first time it was seen, so ordering by age is stable across resyncs.
            let received = existing.received
            existing = request
            switch existing {
            case .permission(var permission):
                permission.received = received
                existing = .permission(permission)
            case .question(var question):
                question.received = received
                existing = .question(question)
            case .app(var app):
                app.received = received
                existing = .app(app)
            }
            guard pending[request.id] != existing else { return }
            pending[request.id] = existing
            reduction.changes.append(.pending(existing, ancestors: ancestors(of: request.sessionID)))
            reduction.writes.pending.append(existing)
        } else {
            pending[request.id] = request
            reduction.changes.append(.pending(request, ancestors: ancestors(of: request.sessionID)))
            reduction.writes.pending.append(request)
        }
        reduction.statusDirty.insert(request.sessionID)
    }

    /// The parent chain of a session, nearest first (bounded against cycles).
    func ancestors(of id: SessionID) -> [SessionID] {
        var result: [SessionID] = []
        var next = sessions[id]?.parentID
        while let parent = next, result.count < 32, !result.contains(parent) {
            result.append(parent)
            next = sessions[parent]?.parentID
        }
        return result
    }

    /// Whether `id` is `ancestor` or one of its descendants.
    func isWithin(_ id: SessionID, of ancestor: SessionID) -> Bool {
        id == ancestor || ancestors(of: id).contains(ancestor)
    }

    /// A permission request from the server: Auto sessions' requests go to triage first (hidden until escalated); a
    /// request already shown, or already escalated, stays shown.
    mutating func putPermission(_ request: PermissionRequest, into reduction: inout Reduction) {
        let id = request.id.rawValue
        if let escalation = autoEscalations[id] {
            var shown = request
            shown.autoEscalation = escalation
            autoTriage[id] = nil
            putPending(.permission(shown), into: &reduction)
            return
        }
        if case .permission(let existing)? = pending[id] {
            var shown = request
            shown.autoEscalation = existing.autoEscalation
            putPending(.permission(shown), into: &reduction)
            return
        }
        if sessions[request.sessionID]?.permissionMode == .auto {
            if autoTriage[id] == nil {
                autoTriage[id] = request
                reduction.autoTriage = true
            }
            return
        }
        putPending(.permission(request), into: &reduction)
    }

    /// Moves a triaged request into the visible pending list (Auto escalated it, or the session left Auto).
    mutating func escalateTriage(_ id: String, _ escalation: AutoEscalation?, into reduction: inout Reduction) {
        guard var request = autoTriage.removeValue(forKey: id) else { return }
        autoDispatched.remove(id)
        if let escalation {
            autoEscalations[id] = escalation
            if autoEscalations.count > 1_000, let first = autoEscalations.keys.first { autoEscalations[first] = nil }
            request.autoEscalation = escalation
        }
        putPending(.permission(request), into: &reduction)
    }

    mutating func dropTriage(_ id: String) {
        autoTriage[id] = nil
        autoDispatched.remove(id)
    }

    mutating func resolvePending(_ id: String, into reduction: inout Reduction) {
        dropTriage(id)
        autoEscalations[id] = nil
        guard let request = pending.removeValue(forKey: id) else { return }
        reduction.changes.append(
            .pendingResolved(id: id, sessionID: request.sessionID, ancestors: ancestors(of: request.sessionID)))
        reduction.writes.resolvedRequests.append(id)
        reduction.statusDirty.insert(request.sessionID)
    }

    mutating func putQueued(_ prompt: QueuedPrompt, into reduction: inout Reduction) {
        guard queue[prompt.id] != prompt else { return }
        queue[prompt.id] = prompt
        reduction.changes.append(.queued(prompt))
        reduction.writes.queue.append(prompt)
    }

    /// Records a local queue edit until the server confirms it (`confirmQueueEdit`) or it is rolled back.
    mutating func recordQueueEdit(_ id: MessageID, _ edit: QueueEdit) {
        if queueEdits.updateValue(edit, forKey: id) == nil { queueEditOrder.append(id) }
        while queueEditOrder.count > Self.queueEditLimit {
            queueEdits[queueEditOrder.removeFirst()] = nil
        }
    }

    mutating func confirmQueueEdit(_ id: MessageID) {
        guard queueEdits.removeValue(forKey: id) != nil else { return }
        queueEditOrder.removeAll { $0 == id }
    }

    mutating func removeQueued(_ id: MessageID, into reduction: inout Reduction) {
        guard let prompt = queue.removeValue(forKey: id) else { return }
        reduction.changes.append(.queueRemoved(id, sessionID: prompt.sessionID))
        reduction.writes.removedQueue.append(id)
    }

    mutating func putProject(_ project: Project, into reduction: inout Reduction) {
        guard projects[project.id] != project else { return }
        projects[project.id] = project
        reduction.changes.append(.project(project))
        reduction.writes.projects.append(project)
        if var entry = registry[project.directory], entry.projectID != project.id {
            entry.projectID = project.id
            putRegistry(entry, into: &reduction)
        }
    }

    mutating func putRegistry(_ entry: ProjectEntry, into reduction: inout Reduction) {
        guard registry[entry.directory] != entry else { return }
        registry[entry.directory] = entry
        reduction.changes.append(.registry(entry))
        reduction.writes.registry.append(entry)
    }

    mutating func putThreadUI(_ state: ThreadUIState, into reduction: inout Reduction) {
        guard threadUI[state.sessionID] != state else { return }
        let previous = threadUI[state.sessionID]?.organisation ?? .none
        threadUI[state.sessionID] = state
        reduction.changes.append(.threadUI(state))
        if previous != state.organisation { reduction.changes.append(.organisation(state.sessionID, state.organisation)) }
        reduction.writes.threadUI.append(state)
        reduction.statusDirty.insert(state.sessionID)
    }
}

/// A risk notice on a tool call, from the reducer to the Auto service.
struct RiskNoticeEvent: Sendable, Equatable {
    enum Stage: String, Sendable { case attempted, completed, failed }
    var sessionID: SessionID
    var messageID: MessageID
    var callID: String
    var tool: String
    var findings: [RiskFinding]
    var stage: Stage
    var projectDirectory: String?
}

/// Reading tool input and the plugin's stamped evaluations for the risk detectors.
enum RiskNoticeInput {
    static func object(_ raw: RawJSON) -> [String: Any?]? {
        guard let data = raw.text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object.mapValues { Optional($0) }
    }

    /// `metadata.bellocode_permissions` (Plugin/src/auto.ts `PERMISSIONS_METADATA_KEY`).
    static func evaluations(_ raw: RawJSON) -> [(action: String, resources: [String])]? {
        guard let data = raw.text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = object["bellocode_permissions"] as? [[String: Any]]
        else { return nil }
        return list.compactMap { item in
            guard let action = item["action"] as? String else { return nil }
            return (action, (item["resources"] as? [String]) ?? [])
        }
    }
}
