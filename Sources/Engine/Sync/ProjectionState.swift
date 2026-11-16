import BelloCore
import Foundation

/// The in-memory projection reducers work on: the complete session index, pending requests and queue, and a bounded
/// cache of recently touched messages. Owned by `EngineCore`; a plain value so reducers can be tested without it.
struct ProjectionState: Sendable {
    var projects: [ProjectID: Project] = [:]
    var registry: [String: ProjectEntry] = [:]
    var sessions: [SessionID: Session] = [:]
    var pending: [String: PendingRequest] = [:]
    var queue: [MessageID: QueuedPrompt] = [:]
    var threadUI: [SessionID: ThreadUIState] = [:]
    var messages: MessageCache
    /// Sessions the user asked to stop whose stop the server has not confirmed.
    var stopping: Set<SessionID> = []
    /// The assistant message currently streaming in each session.
    var openMessage: [SessionID: MessageID] = [:]

    init(messageCapacity: Int = 2048) {
        messages = MessageCache(capacity: messageCapacity)
    }
}

/// A bounded LRU of messages. Messages with live changes not yet written (streamed text) are reported on eviction so
/// the caller persists them rather than losing them.
struct MessageCache: Sendable {
    let capacity: Int
    private var entries: [MessageID: Message] = [:]
    private var lastUse: [MessageID: UInt64] = [:]
    private var tick: UInt64 = 0
    /// Messages whose latest state is only in memory.
    private(set) var unpersisted: Set<MessageID> = []

    init(capacity: Int) {
        self.capacity = max(16, capacity)
    }

    var count: Int { entries.count }

    subscript(id: MessageID) -> Message? { entries[id] }

    func contains(_ id: MessageID) -> Bool { entries[id] != nil }

    /// Inserts or replaces; returns unpersisted messages evicted to make room (write them).
    @discardableResult
    mutating func put(_ message: Message, persisted: Bool) -> [Message] {
        tick += 1
        entries[message.id] = message
        lastUse[message.id] = tick
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
}

/// What one reduction produced: changes to publish, writes to persist, effects to run.
struct Reduction: Sendable {
    var changes: [ProjectionChange] = []
    var writes = StoreBatch()
    var effects: [SyncEffect] = []
    /// Sessions whose derived status may have changed.
    var statusDirty: Set<SessionID> = []

    var isEmpty: Bool { changes.isEmpty && writes.isEmpty && effects.isEmpty && statusDirty.isEmpty }

    mutating func merge(_ other: Reduction) {
        changes += other.changes
        writes.merge(other.writes)
        effects += other.effects
        statusDirty.formUnion(other.statusDirty)
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
            }
            guard pending[request.id] != existing else { return }
            pending[request.id] = existing
            reduction.changes.append(.pending(existing))
            reduction.writes.pending.append(existing)
        } else {
            pending[request.id] = request
            reduction.changes.append(.pending(request))
            reduction.writes.pending.append(request)
        }
        reduction.statusDirty.insert(request.sessionID)
    }

    mutating func resolvePending(_ id: String, into reduction: inout Reduction) {
        guard let request = pending.removeValue(forKey: id) else { return }
        reduction.changes.append(.pendingResolved(id: id, sessionID: request.sessionID))
        reduction.writes.resolvedRequests.append(id)
        reduction.statusDirty.insert(request.sessionID)
    }

    mutating func putQueued(_ prompt: QueuedPrompt, into reduction: inout Reduction) {
        guard queue[prompt.id] != prompt else { return }
        queue[prompt.id] = prompt
        reduction.changes.append(.queued(prompt))
        reduction.writes.queue.append(prompt)
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
        threadUI[state.sessionID] = state
        reduction.changes.append(.threadUI(state))
        reduction.writes.threadUI.append(state)
        reduction.statusDirty.insert(state.sessionID)
    }
}
