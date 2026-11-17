// Loopback-only static HTTP server for the fixture pages. One response per connection.

import Foundation
import Network
import Synchronization

/// One fixture response.
struct FixtureResponse: Sendable {
    var status = "200 OK"
    var type = "text/html"
    var body: String
    var headers: [String] = []
}

final class FixtureServer: Sendable {
    let listener: NWListener
    let port: UInt16
    private static let queue = DispatchQueue(label: "bellocode.g3.fixtures")

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    /// `route` maps a request path (with query) and its header lines to a response; nil is a 404.
    static func start(route: @escaping @Sendable (String, [String]) -> FixtureResponse?) async throws -> FixtureServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            receive(connection, buffer: Data(), route: route)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if resumed.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): if resumed.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return FixtureServer(listener: listener, port: port)
    }

    private static func receive(_ connection: NWConnection, buffer: Data, route: @escaping @Sendable (String, [String]) -> FixtureResponse?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil || buffer.count > 65_536 { connection.cancel() } else { receive(connection, buffer: buffer, route: route) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let lines = head.split(separator: "\r\n").map(String.init)
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let reply = route(path, Array(lines.dropFirst())) ?? FixtureResponse(status: "404 Not Found", type: "text/plain", body: "not found")
            let bytes = Data(reply.body.utf8)
            let extra = reply.headers.map { "\($0)\r\n" }.joined()
            var response = Data("HTTP/1.1 \(reply.status)\r\nContent-Type: \(reply.type); charset=utf-8\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\n\(extra)Connection: close\r\n\r\n".utf8)
            response.append(bytes)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() { listener.cancel() }
}

private final class ResumeOnce: Sendable {
    private let done = Mutex(false)
    func claim() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }
}
