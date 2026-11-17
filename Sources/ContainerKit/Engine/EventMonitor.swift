import Foundation
import os

private let signposter = OSSignposter(subsystem: "app.bellocode.ContainerKit", category: "events")

/// What an `EngineEventMonitor` reports. A `.connected` after the first one means events may have been missed while
/// disconnected: a consumer rebuilds its state from the list endpoints (AGENTS.md rule 12), never from the events.
public enum EngineMonitorEvent: Sendable, Equatable {
    /// The stream is (re)connected. Rebuild state from `listContainers` now.
    case connected
    case event(EngineEvent)
    /// The stream ended or failed; a reconnect follows after `retryIn`.
    case disconnected(retryIn: Duration)
    /// The consumer fell behind and events were dropped: rebuild state from the list endpoints.
    case overflow
}

/// Follows `GET /events` for BelloCode's labelled containers, reconnecting with capped backoff. Owned by one consumer:
/// stop it by cancelling the iterating task (or `stop()`); nothing outlives it.
public final class EngineEventMonitor: Sendable {
    public let client: EngineClient
    public let labels: [String]
    public let initialBackoff: Duration
    public let maximumBackoff: Duration
    /// Events buffered for a slow consumer before `.overflow` is reported.
    public let bufferLimit: Int

    public init(client: EngineClient, labels: [String], initialBackoff: Duration = .milliseconds(500),
                maximumBackoff: Duration = .seconds(15), bufferLimit: Int = 512) {
        self.client = client
        self.labels = labels
        self.initialBackoff = initialBackoff
        self.maximumBackoff = maximumBackoff
        self.bufferLimit = bufferLimit
    }

    /// The monitor's stream. Iterating starts the connection; ending iteration stops it.
    public func stream() -> AsyncStream<EngineMonitorEvent> {
        let (stream, continuation) = AsyncStream<EngineMonitorEvent>.makeStream(bufferingPolicy: .bufferingNewest(bufferLimit))
        let task = Task { [client, labels, initialBackoff, maximumBackoff] in
            var backoff = initialBackoff
            var overflowed = false
            func send(_ value: EngineMonitorEvent) {
                if case .dropped = continuation.yield(value) { overflowed = true }
                if overflowed, case .enqueued = continuation.yield(.overflow) { overflowed = false }
            }
            while !Task.isCancelled {
                do {
                    let events = try await client.events(labels: labels)
                    send(.connected)
                    backoff = initialBackoff
                    for try await event in events {
                        signposter.emitEvent("event")
                        send(.event(event))
                    }
                } catch is CancellationError {
                    break
                } catch {
                    if Task.isCancelled { break }
                }
                if Task.isCancelled { break }
                send(.disconnected(retryIn: backoff))
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, maximumBackoff)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
