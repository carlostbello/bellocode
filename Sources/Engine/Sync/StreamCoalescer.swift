import BelloCore
import Foundation

/// Identifies one streaming buffer: a text or reasoning block, or a tool call's input, in one message.
public struct StreamKey: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case text(ordinal: Int)
        case reasoning(ordinal: Int)
        case toolInput(callID: String)
    }

    public var sessionID: SessionID
    public var messageID: MessageID
    public var kind: Kind

    public init(sessionID: SessionID, messageID: MessageID, kind: Kind) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.kind = kind
    }
}

/// Accumulates streamed deltas per (message, part) and decides when to publish a merged snapshot.
///
/// Every delta is kept, in order; only intermediate render snapshots are skipped. A flush is due `cadence` after the
/// first delta that is not yet published (default 33 ms, about 30 commits per second per message), and the owner
/// flushes a message at once when its block ends, its step ends or fails, or the turn is interrupted. When pending text
/// reaches `maxPendingBytes` the owner (`EventPipeline.ingest`) takes everything at once, before admitting the next
/// delta, so pending memory stays under `maxPendingBytes` plus one delta without dropping anything.
///
/// A plain value with an injected notion of time (`now` parameters) so cadence is testable without sleeping. Owned by
/// `EngineCore`, off the main actor.
public struct StreamCoalescer: Sendable {
    public struct Flush: Sendable, Equatable {
        public var key: StreamKey
        /// Every delta received for `key` since the last flush, concatenated in arrival order.
        public var text: String
    }

    public let cadence: Duration
    public let maxPendingBytes: Int

    private var order: [StreamKey] = []
    private var buffers: [StreamKey: String] = [:]
    private var pendingBytes = 0
    /// When the oldest unpublished delta arrived.
    private var oldestPending: Duration?

    public init(cadence: Duration = .milliseconds(33), maxPendingBytes: Int = 1 << 20) {
        self.cadence = cadence
        self.maxPendingBytes = maxPendingBytes
    }

    public var isEmpty: Bool { order.isEmpty }
    public var pendingByteCount: Int { pendingBytes }

    /// Adds a delta. Returns the time at which a flush becomes due, if this delta started a new pending interval.
    @discardableResult
    public mutating func append(_ delta: String, for key: StreamKey, now: Duration) -> Duration? {
        guard !delta.isEmpty else { return nil }
        if buffers[key] == nil {
            order.append(key)
            buffers[key] = delta
        } else {
            buffers[key]!.append(delta)
        }
        pendingBytes += delta.utf8.count
        if oldestPending == nil {
            oldestPending = now
            return now + cadence
        }
        return nil
    }

    /// Whether a flush is due at `now`.
    public func isDue(now: Duration) -> Bool {
        guard let oldestPending else { return false }
        return pendingBytes >= maxPendingBytes || now - oldestPending >= cadence
    }

    /// When the next flush is due, if anything is pending.
    public var dueAt: Duration? { oldestPending.map { $0 + cadence } }

    /// Takes everything pending, in first-arrival order per key.
    public mutating func takeAll() -> [Flush] {
        let flushes = order.compactMap { key in buffers[key].map { Flush(key: key, text: $0) } }
        order.removeAll()
        buffers.removeAll()
        pendingBytes = 0
        oldestPending = nil
        return flushes
    }

    /// Takes what is pending for one message (its block ended, or the step ended): flush now, not at the cadence.
    public mutating func take(messageID: MessageID) -> [Flush] {
        let keys = order.filter { $0.messageID == messageID }
        guard !keys.isEmpty else { return [] }
        var flushes: [Flush] = []
        for key in keys {
            if let text = buffers.removeValue(forKey: key) {
                pendingBytes -= text.utf8.count
                flushes.append(Flush(key: key, text: text))
            }
        }
        order.removeAll { $0.messageID == messageID }
        if order.isEmpty { oldestPending = nil }
        return flushes
    }

    /// Takes what is pending for a session (its turn ended or was interrupted).
    public mutating func take(sessionID: SessionID) -> [Flush] {
        var messages: [MessageID] = []
        for key in order where key.sessionID == sessionID && !messages.contains(key.messageID) {
            messages.append(key.messageID)
        }
        return messages.flatMap { take(messageID: $0) }
    }
}
