import Foundation
import Synchronization

/// What the emulator consumes, in order.
public enum PTYEmulatorItem: Sendable, Hashable {
    /// Clear the screen and scrollback before what follows (`trimmed`: older output is no longer on the server).
    case reset(trimmed: Bool)
    /// Output bytes, to be parsed by the emulator.
    case output(Data)
    /// A control message, in order with the output around it.
    case control(PTYControlMessage)
}

/// A bounded, ordered, coalescing hand-off from a socket's receive task to the emulator's feed task.
///
/// The producer `push`es frames as they arrive; the consumer takes everything pending with `next()` and gets adjacent
/// output merged into one `Data` (one feed call per batch instead of one per frame). Output is bounded by
/// `capacity` bytes: a producer that gets ahead waits (backpressure reaches the socket and then the server), so
/// nothing is dropped and memory stays bounded (AGENTS.md rules 5 and 10). Control items never wait and are bounded
/// in count; overflowing that bound is a protocol violation and finishes the pipe with `overflowed` set, which the
/// owner turns into a visible resync.
///
/// Threading: `Sendable`; one producer and one consumer.
public final class PTYOutputPipe: Sendable {
    public let capacity: Int
    public let controlLimit: Int

    private struct State {
        var items: [PTYEmulatorItem] = []
        var pendingBytes = 0
        var pendingControls = 0
        var finished = false
        var overflowed = false
        var consumer: CheckedContinuation<[PTYEmulatorItem]?, Never>?
        var producers: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init(capacity: Int = 4 << 20, controlLimit: Int = 4_096) {
        self.capacity = capacity
        self.controlLimit = controlLimit
    }

    /// Bytes waiting for the consumer.
    public var pendingBytes: Int { state.withLock { $0.pendingBytes } }
    /// The pipe finished because too many control messages were pending.
    public var overflowed: Bool { state.withLock { $0.overflowed } }

    /// Appends an item. Output waits while `capacity` bytes are pending; returns at once after `finish()`.
    public func push(_ item: PTYEmulatorItem) async {
        if case .output(let data) = item {
            while true {
                let mustWait = state.withLock { $0.pendingBytes >= capacity && !$0.finished && $0.consumer == nil }
                guard mustWait else { break }
                await withCheckedContinuation { continuation in
                    let resumeNow = state.withLock { state -> Bool in
                        if state.finished || state.pendingBytes < capacity || state.consumer != nil { return true }
                        state.producers.append(continuation)
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            }
            if data.isEmpty { return }
        }
        let waiter = state.withLock { state -> (CheckedContinuation<[PTYEmulatorItem]?, Never>, [PTYEmulatorItem])? in
            guard !state.finished else { return nil }
            switch item {
            case .output(let data):
                state.pendingBytes += data.count
                if case .output(var last) = state.items.last {
                    last.append(data)
                    state.items[state.items.count - 1] = .output(last)
                } else {
                    state.items.append(item)
                }
            case .reset, .control:
                state.pendingControls += 1
                state.items.append(item)
                if state.pendingControls > controlLimit {
                    state.overflowed = true
                    state.finished = true
                }
            }
            guard let consumer = state.consumer else { return nil }
            state.consumer = nil
            return (consumer, take(&state))
        }
        if let (consumer, batch) = waiter { consumer.resume(returning: batch) }
    }

    /// Everything pending (adjacent output merged), waiting if there is nothing; nil once finished and drained.
    public func next() async -> [PTYEmulatorItem]? {
        if let batch = poll() { return batch }
        return await withCheckedContinuation { continuation in
            let (immediate, producers) = state.withLock { state -> ([PTYEmulatorItem]??, [CheckedContinuation<Void, Never>]) in
                let producers = state.producers
                state.producers.removeAll()
                if !state.items.isEmpty { return (.some(take(&state)), producers) }
                if state.finished { return (.some(nil), producers) }
                state.consumer = continuation
                return (.none, producers)
            }
            for producer in producers { producer.resume() }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    /// Pending items without waiting (nil when there are none).
    public func poll() -> [PTYEmulatorItem]? {
        let (batch, producers) = state.withLock { state -> ([PTYEmulatorItem]?, [CheckedContinuation<Void, Never>]) in
            guard !state.items.isEmpty else { return (nil, []) }
            let batch = take(&state)
            let producers = state.producers
            state.producers.removeAll()
            return (batch, producers)
        }
        for producer in producers { producer.resume() }
        return batch
    }

    /// No more items will be pushed; the consumer drains what is pending and then gets nil. Waiting producers return.
    public func finish() {
        let (consumer, producers) = state.withLock { state -> (CheckedContinuation<[PTYEmulatorItem]?, Never>?, [CheckedContinuation<Void, Never>]) in
            state.finished = true
            let consumer = state.items.isEmpty ? state.consumer : nil
            if consumer != nil { state.consumer = nil }
            let producers = state.producers
            state.producers.removeAll()
            return (consumer, producers)
        }
        consumer?.resume(returning: nil)
        for producer in producers { producer.resume() }
    }

    private func take(_ state: inout State) -> [PTYEmulatorItem] {
        let batch = state.items
        state.items.removeAll(keepingCapacity: true)
        state.pendingBytes = 0
        state.pendingControls = 0
        return batch
    }
}
