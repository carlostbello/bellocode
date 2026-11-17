import Foundation
import Synchronization

/// What a subscriber receives from `EventHub`.
public enum EventHubMessage: Sendable {
    /// A decoded event, in stream order.
    case event(OpenCodeEventEnvelope)
    /// State may have been missed: rebuild from the list endpoints, then keep applying the events that follow.
    case resync(ResyncReason)
    /// The connection dropped. A `.resync(.connected)` follows once it is re-established.
    case disconnected(reason: String)
}

public enum ResyncReason: Sendable, Hashable {
    /// A connection was (re)established. `connection` counts connections made by this hub, starting at 1.
    case connected(connection: Int)
    /// This subscriber fell more than its buffer limit behind; buffered events were discarded.
    case overflow
}

/// Which events a subscriber receives. `.resync` and `.disconnected` are always delivered.
public enum EventFilter: Sendable, Hashable {
    case all
    case session(String)
    case sessions(Set<String>)
    /// Events whose `location.directory` is this path.
    case directory(String)
    /// Events of these wire types (such as a plugin RPC's control events).
    case types(Set<String>)

    func matches(_ envelope: OpenCodeEventEnvelope) -> Bool {
        switch self {
        case .all: true
        case .session(let id): envelope.sessionID == id
        case .sessions(let ids): envelope.sessionID.map(ids.contains) ?? false
        case .directory(let path): envelope.directory == path
        case .types(let types): types.contains(envelope.type)
        }
    }
}

/// An ordered, bounded stream of `EventHubMessage`s for one subscriber.
///
/// The buffer never grows past `bufferLimit`. When a push would exceed it, every buffered message is discarded and
/// replaced by a single `.resync(.overflow)`, so a slow consumer sees an explicit gap instead of silent loss. Iteration
/// ends when the hub stops, when `cancel()` is called, or when the iterating task is cancelled. Releasing the
/// subscription and its iterators unsubscribes it.
public final class EventSubscription: AsyncSequence, Sendable {
    public typealias Element = EventHubMessage
    public typealias Failure = Never

    let mailbox: Mailbox

    init(filter: EventFilter, bufferLimit: Int) {
        mailbox = Mailbox(filter: filter, limit: bufferLimit)
    }

    deinit { mailbox.terminate() }

    public var filter: EventFilter { mailbox.filter }

    /// Ends the subscription. Pending messages are discarded.
    public func cancel() { mailbox.terminate() }

    /// Number of times this subscriber overflowed.
    public var overflowCount: Int { mailbox.overflowCount }

    public func makeAsyncIterator() -> Iterator { Iterator(subscription: self) }

    public struct Iterator: AsyncIteratorProtocol {
        let subscription: EventSubscription

        public mutating func next() async -> EventHubMessage? {
            await subscription.mailbox.next()
        }

        public mutating func next(isolation actor: isolated (any Actor)?) async -> EventHubMessage? {
            await subscription.mailbox.next()
        }
    }
}

/// The bounded queue behind an `EventSubscription`.
final class Mailbox: Sendable {
    private struct State {
        var front: [EventHubMessage] = []
        var back: [EventHubMessage] = []
        var waiter: CheckedContinuation<EventHubMessage?, Never>?
        var finished = false
        var terminated = false
        var overflows = 0

        var count: Int { front.count + back.count }

        mutating func popFirst() -> EventHubMessage? {
            if front.isEmpty {
                front = back.reversed()
                back.removeAll(keepingCapacity: true)
            }
            return front.popLast()
        }

        mutating func removeAll() {
            front.removeAll()
            back.removeAll()
        }
    }

    let filter: EventFilter
    let limit: Int
    private let state = Mutex(State())

    init(filter: EventFilter, limit: Int) {
        precondition(limit >= 2, "a buffer must hold at least an overflow marker and one message")
        self.filter = filter
        self.limit = limit
    }

    var isTerminated: Bool { state.withLock { $0.terminated } }
    var overflowCount: Int { state.withLock { $0.overflows } }

    /// Enqueues a message. Returns `false` once the consumer is gone, so the hub can drop the mailbox.
    @discardableResult
    func push(_ message: EventHubMessage) -> Bool {
        let (waiter, alive): (CheckedContinuation<EventHubMessage?, Never>?, Bool) = state.withLock { state in
            guard !state.terminated, !state.finished else { return (nil, !state.terminated) }
            if let waiter = state.waiter {
                state.waiter = nil
                return (waiter, true)
            }
            if state.count >= limit {
                state.removeAll()
                state.back.append(.resync(.overflow))
                state.overflows += 1
            }
            state.back.append(message)
            return (nil, true)
        }
        waiter?.resume(returning: message)
        return alive
    }

    /// Producer side: no more messages; buffered ones are still delivered.
    func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<EventHubMessage?, Never>? in
            state.finished = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    /// Consumer side: stop now and discard buffered messages.
    func terminate() {
        let waiter = state.withLock { state -> CheckedContinuation<EventHubMessage?, Never>? in
            state.terminated = true
            state.removeAll()
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    func next() async -> EventHubMessage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<EventHubMessage?, Never>) in
                let immediate: EventHubMessage?? = state.withLock { state in
                    if state.terminated || Task.isCancelled {
                        state.terminated = true
                        return .some(nil)
                    }
                    if let message = state.popFirst() { return .some(message) }
                    if state.finished { return .some(nil) }
                    precondition(state.waiter == nil, "EventSubscription supports one iterating task at a time")
                    state.waiter = continuation
                    return .none
                }
                if case .some(let value) = immediate { continuation.resume(returning: value) }
            }
        } onCancel: {
            terminate()
        }
    }
}
