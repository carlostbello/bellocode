import BelloCore
import Foundation
import Synchronization

/// What a change subscriber listens to. A subscriber is woken only by changes routed to its topic, so a token streaming
/// into one thread never wakes another thread, the sidebar of another project, or the catalog.
public enum ChangeTopic: Hashable, Sendable {
    /// The project list and BelloCode's project registry.
    case projects
    /// Sessions of one project and their derived statuses.
    case sessions(ProjectID)
    /// Everything shown in one thread: its session, messages, pending requests, queue and UI state.
    case thread(SessionID)
    /// The global "Needs you" summary.
    case attention
    /// Providers, models and agents.
    case catalog
    /// The connection status.
    case connection
}

/// One change to the projection, as published by the store (after commit) or the engine (live, ahead of disk).
public enum ProjectionChange: Sendable {
    case project(Project)
    case projectRemoved(ProjectID)
    case registry(ProjectEntry)
    case registryRemoved(directory: String)
    case session(Session)
    case sessionRemoved(SessionID, projectID: ProjectID)
    case status(SessionAttention)
    case message(Message)
    case messageRemoved(MessageID, sessionID: SessionID)
    case pending(PendingRequest)
    case pendingResolved(id: String, sessionID: SessionID)
    case queued(QueuedPrompt)
    case queueRemoved(MessageID, sessionID: SessionID)
    case threadUI(ThreadUIState)
    /// The thread's history was replaced (resync found a gap, or the cache was rebuilt): reload its window.
    case threadReset(SessionID)
    case attention(AttentionSummary)
    case catalog(Catalog)
    case connection(ConnectionStatus)

    /// The topics this change is delivered to.
    var topics: [ChangeTopic] {
        switch self {
        case .project, .projectRemoved, .registry, .registryRemoved: [.projects]
        case .session(let session): [.sessions(session.projectID), .thread(session.id)]
        case .sessionRemoved(let id, let projectID): [.sessions(projectID), .thread(id)]
        case .status(let status): [.sessions(status.projectID), .thread(status.sessionID)]
        case .message(let message): [.thread(message.sessionID)]
        case .messageRemoved(_, let sessionID): [.thread(sessionID)]
        case .pending(let request): [.thread(request.sessionID)]
        case .pendingResolved(_, let sessionID): [.thread(sessionID)]
        case .queued(let prompt): [.thread(prompt.sessionID)]
        case .queueRemoved(_, let sessionID): [.thread(sessionID)]
        case .threadUI(let state): [.thread(state.sessionID)]
        case .threadReset(let id): [.thread(id)]
        case .attention: [.attention]
        case .catalog: [.catalog]
        case .connection: [.connection]
        }
    }
}

/// The engine's connection to opencode, as the UI should present it.
public enum ConnectionStatus: Hashable, Sendable {
    /// Showing cached data; no connection attempt yet.
    case cached
    case connecting
    /// Connected; rebuilding from the list endpoints. Cached content stays visible.
    case syncing
    case live
    /// Disconnected; cached content stays visible and is marked stale.
    case offline(reason: String)
    case stopped

    public var isLive: Bool { self == .live }

    public var label: String {
        switch self {
        case .cached: "Cached"
        case .connecting: "Connecting…"
        case .syncing: "Syncing…"
        case .live: "Connected"
        case .offline: "Offline"
        case .stopped: "Stopped"
        }
    }
}

/// Changes accumulated for one subscriber since it last woke, merged by identity (latest value wins; a message keeps
/// its highest revision). If more than the subscriber's limit of distinct entities pile up, the contents are dropped
/// and `overflowed` is set: the subscriber must reload its topic from the store. That is a visible resync, never silent
/// loss.
public struct ChangeSet: Sendable {
    public var projects: [ProjectID: Project] = [:]
    public var removedProjects: Set<ProjectID> = []
    public var registry: [String: ProjectEntry] = [:]
    public var removedRegistry: Set<String> = []
    public var sessions: [SessionID: Session] = [:]
    public var removedSessions: Set<SessionID> = []
    public var statuses: [SessionID: SessionAttention] = [:]
    public var messages: [MessageID: Message] = [:]
    public var removedMessages: Set<MessageID> = []
    public var pending: [String: PendingRequest] = [:]
    public var resolvedRequests: Set<String> = []
    public var queue: [MessageID: QueuedPrompt] = [:]
    public var removedQueue: Set<MessageID> = []
    public var threadUI: [SessionID: ThreadUIState] = [:]
    public var resetThreads: Set<SessionID> = []
    public var attention: AttentionSummary?
    public var catalog: Catalog?
    public var connection: ConnectionStatus?
    /// Too many changes accumulated; reload the topic.
    public var overflowed = false

    public init() {}

    var entityCount: Int {
        projects.count + removedProjects.count + registry.count + removedRegistry.count + sessions.count
            + removedSessions.count + statuses.count + messages.count + removedMessages.count + pending.count
            + resolvedRequests.count + queue.count + removedQueue.count + threadUI.count + resetThreads.count
    }

    public var isEmpty: Bool {
        entityCount == 0 && attention == nil && catalog == nil && connection == nil && !overflowed
    }

    mutating func merge(_ change: ProjectionChange) {
        switch change {
        case .project(let project):
            projects[project.id] = project
            removedProjects.remove(project.id)
        case .projectRemoved(let id):
            projects[id] = nil
            removedProjects.insert(id)
        case .registry(let entry):
            registry[entry.directory] = entry
            removedRegistry.remove(entry.directory)
        case .registryRemoved(let directory):
            registry[directory] = nil
            removedRegistry.insert(directory)
        case .session(let session):
            sessions[session.id] = session
            removedSessions.remove(session.id)
        case .sessionRemoved(let id, _):
            sessions[id] = nil
            statuses[id] = nil
            removedSessions.insert(id)
        case .status(let status):
            statuses[status.sessionID] = status
        case .message(let message):
            if let existing = messages[message.id], existing.revision > message.revision { return }
            messages[message.id] = message
            removedMessages.remove(message.id)
        case .messageRemoved(let id, _):
            messages[id] = nil
            removedMessages.insert(id)
        case .pending(let request):
            pending[request.id] = request
            resolvedRequests.remove(request.id)
        case .pendingResolved(let id, _):
            pending[id] = nil
            resolvedRequests.insert(id)
        case .queued(let prompt):
            queue[prompt.id] = prompt
            removedQueue.remove(prompt.id)
        case .queueRemoved(let id, _):
            queue[id] = nil
            removedQueue.insert(id)
        case .threadUI(let state):
            threadUI[state.sessionID] = state
        case .threadReset(let id):
            resetThreads.insert(id)
            // A reset supersedes queued message changes for that thread.
            messages = messages.filter { $0.value.sessionID != id }
        case .attention(let summary):
            attention = summary
        case .catalog(let catalog):
            self.catalog = catalog
        case .connection(let status):
            connection = status
        }
    }
}

/// Fans projection changes out to topic subscribers. Publishing never blocks and never waits for a subscriber.
public final class ChangeBus: Sendable {
    private struct State {
        var subscribers: [UInt64: ChangeMailbox] = [:]
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())
    /// Distinct entities a subscriber may have pending before it is told to reload.
    public let subscriberLimit: Int

    public init(subscriberLimit: Int = 4096) {
        self.subscriberLimit = subscriberLimit
    }

    /// Subscribes to one topic. The subscription ends when it is cancelled or released.
    public func subscribe(_ topic: ChangeTopic, limit: Int? = nil) -> ChangeSubscription {
        let mailbox = ChangeMailbox(topic: topic, limit: limit ?? subscriberLimit)
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            state.subscribers[state.nextID] = mailbox
            return state.nextID
        }
        return ChangeSubscription(mailbox: mailbox) { [weak self] in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
    }

    public func publish(_ changes: [ProjectionChange]) {
        guard !changes.isEmpty else { return }
        let subscribers = state.withLock { Array($0.subscribers.values) }
        guard !subscribers.isEmpty else { return }
        EngineSignposts.publish.measure("route") {
            var byTopic: [ChangeTopic: [ProjectionChange]] = [:]
            for change in changes {
                for topic in change.topics { byTopic[topic, default: []].append(change) }
            }
            for mailbox in subscribers {
                if let routed = byTopic[mailbox.topic] { mailbox.push(routed) }
            }
        }
    }

    /// Tells every subscriber to reload (after `rebuild`).
    public func publishReloadAll() {
        let subscribers = state.withLock { Array($0.subscribers.values) }
        for mailbox in subscribers { mailbox.forceOverflow() }
    }

    var subscriberCount: Int { state.withLock { $0.subscribers.count } }
}

/// The receiving end of a topic subscription: an `AsyncSequence` of merged `ChangeSet`s. One iterating task at a time.
public final class ChangeSubscription: AsyncSequence, Sendable {
    public typealias Element = ChangeSet
    public typealias Failure = Never

    let mailbox: ChangeMailbox
    private let onCancel: @Sendable () -> Void

    init(mailbox: ChangeMailbox, onCancel: @escaping @Sendable () -> Void) {
        self.mailbox = mailbox
        self.onCancel = onCancel
    }

    deinit { cancel() }

    public var topic: ChangeTopic { mailbox.topic }

    /// Ends the subscription; a waiting iterator returns nil.
    public func cancel() {
        mailbox.finish()
        onCancel()
    }

    /// Takes whatever is pending without waiting (nil when nothing is).
    public func poll() -> ChangeSet? { mailbox.poll() }

    public func makeAsyncIterator() -> Iterator { Iterator(mailbox: mailbox) }

    public struct Iterator: AsyncIteratorProtocol {
        let mailbox: ChangeMailbox

        public mutating func next() async -> ChangeSet? { await mailbox.next() }

        public mutating func next(isolation actor: isolated (any Actor)?) async -> ChangeSet? { await mailbox.next() }
    }
}

/// The bounded, merging buffer behind a subscription.
final class ChangeMailbox: Sendable {
    private struct State {
        var pending = ChangeSet()
        var waiter: CheckedContinuation<ChangeSet?, Never>?
        var finished = false
    }

    let topic: ChangeTopic
    let limit: Int
    private let state = Mutex(State())

    init(topic: ChangeTopic, limit: Int) {
        self.topic = topic
        self.limit = max(1, limit)
    }

    func push(_ changes: [ProjectionChange]) {
        let delivery: (CheckedContinuation<ChangeSet?, Never>, ChangeSet)? = state.withLock { state in
            guard !state.finished else { return nil }
            for change in changes { state.pending.merge(change) }
            if state.pending.entityCount > limit {
                var reset = ChangeSet()
                reset.overflowed = true
                reset.attention = state.pending.attention
                reset.connection = state.pending.connection
                state.pending = reset
            }
            guard let waiter = state.waiter else { return nil }
            state.waiter = nil
            let batch = state.pending
            state.pending = ChangeSet()
            return (waiter, batch)
        }
        if let (waiter, batch) = delivery { waiter.resume(returning: batch) }
    }

    func forceOverflow() {
        let delivery: (CheckedContinuation<ChangeSet?, Never>, ChangeSet)? = state.withLock { state in
            guard !state.finished else { return nil }
            state.pending = ChangeSet()
            state.pending.overflowed = true
            guard let waiter = state.waiter else { return nil }
            state.waiter = nil
            let batch = state.pending
            state.pending = ChangeSet()
            return (waiter, batch)
        }
        if let (waiter, batch) = delivery { waiter.resume(returning: batch) }
    }

    func poll() -> ChangeSet? {
        state.withLock { state in
            guard !state.pending.isEmpty else { return nil }
            defer { state.pending = ChangeSet() }
            return state.pending
        }
    }

    func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<ChangeSet?, Never>? in
            state.finished = true
            state.pending = ChangeSet()
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    func next() async -> ChangeSet? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ChangeSet?, Never>) in
                let immediate: ChangeSet?? = state.withLock { state in
                    if state.finished || Task.isCancelled { return .some(nil) }
                    if !state.pending.isEmpty {
                        defer { state.pending = ChangeSet() }
                        return .some(state.pending)
                    }
                    precondition(state.waiter == nil, "ChangeSubscription supports one iterating task at a time")
                    state.waiter = continuation
                    return .none
                }
                if case .some(let value) = immediate { continuation.resume(returning: value) }
            }
        } onCancel: {
            finish()
        }
    }
}
