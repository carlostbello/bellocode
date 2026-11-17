import Foundation
import Network
import Synchronization

enum TransportError: Error, Equatable {
    case listenerFailed(String)
    case connectionClosed
    case sendFailed(String)
}

/// A loopback TCP listener on an ephemeral port. Accepted connections arrive on ``connections``.
///
/// Admission is bounded: at most `backlog` accepted connections wait for the consumer; beyond that a new connection is
/// cancelled at once (the client sees it closed) and counted in `rejected`, so a burst cannot grow memory.
struct LoopbackListener: Sendable {
    let listener: NWListener
    let port: UInt16
    let connections: AsyncStream<NWConnection>
    let rejectedCount: RejectionCounter

    var rejected: Int { rejectedCount.value }

    static let defaultBacklog = 256

    static func start(queue: DispatchQueue, backlog: Int = defaultBacklog) async throws -> LoopbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw TransportError.listenerFailed("\(error)")
        }
        let (stream, continuation) = AsyncStream.makeStream(of: NWConnection.self, bufferingPolicy: .bufferingOldest(max(1, backlog)))
        let rejected = RejectionCounter()
        listener.newConnectionHandler = { connection in
            if case .dropped = continuation.yield(connection) {
                connection.cancel()
                rejected.increment()
            }
        }
        let resumed = Mutex(false)
        let port: UInt16 = try await withCheckedThrowingContinuation { ready in
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, TransportError>? =
                    switch state {
                    case .ready: .success(listener.port?.rawValue ?? 0)
                    case let .failed(error): .failure(.listenerFailed("\(error)"))
                    case .cancelled: .failure(.listenerFailed("cancelled"))
                    default: nil
                    }
                guard let result else { return }
                if case .cancelled = state { continuation.finish() }
                if case .failed = state { continuation.finish() }
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { ready.resume(with: result) }
            }
            listener.start(queue: queue)
        }
        return LoopbackListener(listener: listener, port: port, connections: stream, rejectedCount: rejected)
    }

    func stop() { listener.cancel() }
}

/// Connections refused because the accept queue was full.
final class RejectionCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

/// Async wrappers over one accepted `NWConnection`.
struct ConnectionIO: Sendable {
    let connection: NWConnection

    func start(queue: DispatchQueue) { connection.start(queue: queue) }

    /// The next bytes from the peer, or `nil` at end of stream.
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: TransportError.sendFailed("\(error)"))
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    /// Sends bytes and returns when the stack has taken them. A slow reader therefore slows only this connection.
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: TransportError.sendFailed("\(error)"))
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    /// Orderly close after pending sends.
    func finish() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        connection.cancel()
    }

    /// Abrupt close: no terminating chunk, as when a server process dies mid-stream.
    func reset() { connection.forceCancel() }
}
