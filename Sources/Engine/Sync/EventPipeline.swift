import BelloCore
import Foundation
import OpenCodeKit

/// The ordered ingestion path for one event stream: drop exact duplicates, buffer streamed deltas in the
/// `StreamCoalescer`, flush a message's buffer before any other event for it, then reduce. A synchronous value, so the
/// whole path is testable without actors or sockets; `EngineCore` owns one and adds disk loads and publishing.
struct EventPipeline: Sendable {
    var state: ProjectionState
    var coalescer: StreamCoalescer
    private var seen = RecentIDs(capacity: 8192)
    private(set) var duplicatesDropped = 0

    init(state: ProjectionState = ProjectionState(), cadence: Duration = .milliseconds(33)) {
        self.state = state
        coalescer = StreamCoalescer(cadence: cadence)
    }

    /// Applies one event. `clock` is monotonic time (for the coalescer), `now` wall-clock time for events without a
    /// timestamp. Returns what to publish and persist; streamed deltas return an empty reduction until flushed.
    mutating func ingest(_ envelope: OpenCodeEventEnvelope, clock: Duration, now: Timestamp) -> Reduction {
        if let id = envelope.id, !seen.insert(id) {
            duplicatesDropped += 1
            return Reduction()
        }
        if let (key, delta) = EventReducer.streamDelta(of: envelope.event) {
            coalescer.append(delta, for: key, now: clock)
            return Reduction()
        }
        var reduction = Reduction()
        if let target = EventReducer.target(of: envelope.event) {
            reduction.merge(EventReducer.applyDeltas(coalescer.take(messageID: target.message), into: &state, now: now))
        }
        switch envelope.event {
        case .executionSucceeded(let p), .executionStarted(let p):
            reduction.merge(EventReducer.applyDeltas(coalescer.take(sessionID: SessionID(p.sessionID)), into: &state, now: now))
        case .executionFailed(let p):
            reduction.merge(EventReducer.applyDeltas(coalescer.take(sessionID: SessionID(p.sessionID)), into: &state, now: now))
        case .executionInterrupted(let p):
            reduction.merge(EventReducer.applyDeltas(coalescer.take(sessionID: SessionID(p.sessionID)), into: &state, now: now))
        default:
            break
        }
        reduction.merge(EventReducer.reduce(envelope, into: &state, now: now))
        return reduction
    }

    /// Publishes buffered deltas if the cadence has elapsed (or `force`).
    mutating func flushDeltas(clock: Duration, now: Timestamp, force: Bool = false) -> Reduction {
        guard force || coalescer.isDue(now: clock) else { return Reduction() }
        return EventReducer.applyDeltas(coalescer.takeAll(), into: &state, now: now)
    }
}

/// A bounded set of recently seen event IDs (FIFO eviction), for dropping exact duplicate frames.
struct RecentIDs: Sendable {
    let capacity: Int
    private var members: Set<String> = []
    private var ring: [String] = []
    private var next = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        ring.reserveCapacity(self.capacity)
    }

    /// Inserts `id`; returns false if it was already present.
    mutating func insert(_ id: String) -> Bool {
        guard !members.contains(id) else { return false }
        if ring.count < capacity {
            ring.append(id)
        } else {
            members.remove(ring[next])
            ring[next] = id
            next = (next + 1) % capacity
        }
        members.insert(id)
        return true
    }
}
