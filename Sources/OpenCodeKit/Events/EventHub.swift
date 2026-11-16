import Foundation

/// Holds the single `/api/event` connection, decodes frames and fans them out to subscribers.
///
/// opencode's stream is volatile: events emitted while disconnected are gone, and there is no replay. So after every
/// (re)connect the hub sends `.resync(.connected)` to every subscriber before any event from the new connection, and
/// consumers rebuild from the list endpoints. Each subscriber has its own bounded buffer; overflow becomes a
/// `.resync(.overflow)` for that subscriber only. Reconnects use capped, jittered backoff, reset after a connection
/// opens.
///
/// The hub owns its connection task: call `stop()` to end it.
public actor EventHub {
    public enum ConnectionState: Sendable, Hashable {
        case idle
        case connecting(attempt: Int)
        case connected(connection: Int)
        case waitingToReconnect(attempt: Int, delay: Duration)
        case stopped
    }

    public struct Statistics: Sendable, Hashable {
        public var connections = 0
        public var frames = 0
        public var unknownFrames = 0
        public var overflows = 0
    }

    /// SSE event name the server's HTTP layer uses to report a stream failure (`x-effect-stream.failureEvent`).
    static let streamFailureEvent = "effect/http-api/stream/failure"

    private struct StreamFailure: Error, CustomStringConvertible {
        var description: String { "server reported a stream failure" }
    }

    public let defaultBufferLimit: Int
    /// Largest accepted line or event; a bigger one drops the connection (and so causes a resync).
    public let maxEventBytes: Int
    private let connector: any EventStreamConnector
    private let backoff: BackoffPolicy
    private let time: any TimeSource
    private let random: RandomUnit
    private let decoder = OpenCodeEventDecoder()

    public private(set) var connectionState = ConnectionState.idle
    public private(set) var statistics = Statistics()

    private var mailboxes: [Mailbox] = []
    private var parser: SSEParser
    private var connectionTask: Task<Void, Never>?
    private var openedThisAttempt = false

    public init(
        connector: any EventStreamConnector,
        backoff: BackoffPolicy = BackoffPolicy(initial: .milliseconds(250), maximum: .seconds(10)),
        time: any TimeSource = SystemTimeSource(),
        random: @escaping RandomUnit = systemRandomUnit,
        defaultBufferLimit: Int = 4096,
        maxEventBytes: Int = 16 * 1024 * 1024
    ) {
        self.maxEventBytes = maxEventBytes
        self.connector = connector
        self.backoff = backoff
        self.time = time
        self.random = random
        self.defaultBufferLimit = defaultBufferLimit
        self.parser = SSEParser(maxEventBytes: maxEventBytes)
    }

    /// Subscribes to events matching `filter`. Subscribe before issuing work so nothing is missed; the first message
    /// after connecting is always a `.resync`.
    public func subscribe(_ filter: EventFilter = .all, bufferLimit: Int? = nil) -> EventSubscription {
        let subscription = EventSubscription(filter: filter, bufferLimit: bufferLimit ?? defaultBufferLimit)
        if connectionState == .stopped {
            subscription.mailbox.finish()
        } else {
            mailboxes.append(subscription.mailbox)
        }
        return subscription
    }

    /// Starts connecting. Idempotent.
    public func start() {
        guard connectionTask == nil, connectionState != .stopped else { return }
        connectionTask = Task { await self.run() }
    }

    /// Closes the connection and ends every subscription. The hub cannot be restarted.
    public func stop() async {
        connectionState = .stopped
        let task = connectionTask
        connectionTask = nil
        task?.cancel()
        await task?.value
        for mailbox in mailboxes { mailbox.finish() }
        mailboxes.removeAll()
    }

    // MARK: - Connection loop

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            connectionState = .connecting(attempt: attempt)
            openedThisAttempt = false
            var reason: String
            do {
                try await connector.stream(
                    onOpen: { [weak self] in await self?.didOpen() },
                    onChunk: { [weak self] chunk in try await self?.receive(chunk) }
                )
                reason = "stream ended"
            } catch {
                if Task.isCancelled { break }
                reason = describeError(error)
            }
            if Task.isCancelled { break }
            parser.finish()
            if openedThisAttempt { attempt = 1 }
            Instrumentation.eventLog.info("event stream disconnected: \(reason, privacy: .public)")
            broadcast(.disconnected(reason: reason))
            let delay = backoff.delay(forAttempt: attempt, random: random())
            connectionState = .waitingToReconnect(attempt: attempt, delay: delay)
            do { try await time.sleep(for: delay) } catch { break }
        }
    }

    private func didOpen() {
        guard !Task.isCancelled, connectionState != .stopped else { return }
        parser = SSEParser(maxEventBytes: maxEventBytes)
        openedThisAttempt = true
        statistics.connections += 1
        connectionState = .connected(connection: statistics.connections)
        Instrumentation.eventLog.info("event stream connected (\(self.statistics.connections, privacy: .public))")
        broadcast(.resync(.connected(connection: statistics.connections)))
    }

    private func receive(_ chunk: [UInt8]) throws {
        try Task.checkCancellation()
        let signpost = Instrumentation.events.beginInterval("receive")
        defer { Instrumentation.events.endInterval("receive", signpost) }
        for byte in chunk {
            guard let event = try parser.push(byte) else { continue }
            if event.type == Self.streamFailureEvent { throw StreamFailure() }
            dispatch(event)
        }
    }

    private func dispatch(_ event: SSEEvent) {
        let decodeSignpost = Instrumentation.events.beginInterval("decode")
        let envelope = decoder.decode(Data(event.data.utf8))
        Instrumentation.events.endInterval("decode", decodeSignpost)
        statistics.frames += 1
        if envelope.event.isUnknown { statistics.unknownFrames += 1 }
        let publishSignpost = Instrumentation.events.beginInterval("publish")
        defer { Instrumentation.events.endInterval("publish", publishSignpost) }
        let message = EventHubMessage.event(envelope)
        var pruned = false
        for mailbox in mailboxes where mailbox.filter.matches(envelope) {
            let before = mailbox.overflowCount
            if !mailbox.push(message) { pruned = true }
            statistics.overflows += mailbox.overflowCount - before
        }
        if pruned { mailboxes.removeAll { $0.isTerminated } }
    }

    private func broadcast(_ message: EventHubMessage) {
        var pruned = false
        for mailbox in mailboxes where !mailbox.push(message) { pruned = true }
        if pruned { mailboxes.removeAll { $0.isTerminated } }
    }
}
