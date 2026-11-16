import Foundation

/// Opens one connection to the event stream and pumps its body bytes. `EventHub` calls `stream` once per connection
/// attempt; implementations must honour task cancellation.
public protocol EventStreamConnector: Sendable {
    /// Connects, calls `onOpen` once the response is accepted, then calls `onChunk` with body bytes in order until the
    /// stream ends (return) or fails (throw). Errors thrown by `onChunk` must propagate and end the connection.
    func stream(
        onOpen: @escaping @Sendable () async -> Void,
        onChunk: @escaping @Sendable ([UInt8]) async throws -> Void
    ) async throws
}

/// Streams `GET /api/event` with `URLSession`. The client is resolved on every attempt, so after a server restart the
/// next attempt uses the new port and password.
public struct URLSessionEventStreamConnector: EventStreamConnector {
    private let session: URLSession
    private let resolveClient: @Sendable () async throws -> OpenCodeClient
    private let idleTimeout: Duration

    public init(
        session: URLSession = URLSessionEventStreamConnector.makeSession(),
        idleTimeout: Duration = .seconds(45),
        client: @escaping @Sendable () async throws -> OpenCodeClient
    ) {
        self.session = session
        self.idleTimeout = idleTimeout
        self.resolveClient = client
    }

    /// Connects to whatever server `supervisor` reports ready, waiting while it starts or restarts.
    public init(supervisor: ServerSupervisor, session: URLSession = URLSessionEventStreamConnector.makeSession()) {
        self.init(session: session) {
            OpenCodeClient(endpoint: try await supervisor.awaitReady())
        }
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        return URLSession(configuration: configuration)
    }

    public func stream(
        onOpen: @escaping @Sendable () async -> Void,
        onChunk: @escaping @Sendable ([UInt8]) async throws -> Void
    ) async throws {
        let client = try await resolveClient()
        let request = try client.eventStreamRequest(idleTimeout: idleTimeout)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw OpenCodeError.invalidResponse }
        guard http.statusCode == 200 else {
            var body: [UInt8] = []
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 64 * 1024 { break }
            }
            let decoded = try? JSONDecoder().decode(ServerErrorBody.self, from: Data(body))
            throw OpenCodeError.http(status: http.statusCode, body: decoded, operation: "event.subscribe")
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        guard contentType?.lowercased().hasPrefix("text/event-stream") == true else {
            throw OpenCodeError.unexpectedContentType(contentType)
        }
        await onOpen()
        // Hand over whole lines (or 64 KiB pieces) so the hub sees a few hops per event, not one per byte.
        var chunk: [UInt8] = []
        chunk.reserveCapacity(4096)
        for try await byte in bytes {
            chunk.append(byte)
            if byte == UInt8(ascii: "\n") || chunk.count >= 64 * 1024 {
                try await onChunk(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { try await onChunk(chunk) }
    }
}
