// G5 SPIKE ONLY (docs/spikes/G5-terminal.md). A throwaway client for opencode 2.3.0's persistent PTY API.
// The production client belongs in OpenCodeKit; do not depend on this file from anything but the spike.
//
// Contract as observed against the pinned binary (see the spike note for the full table):
//   POST /api/session {location:{directory}}                         -> {data: Session}
//   POST /api/experimental/session/{sid}/terminal {args,title,env,cwd?,size?} -> {data: PersistentPty.Info}
//   GET  /api/experimental/session/{sid}/terminal                     -> {data: [Info]}
//   GET  /api/experimental/session/{sid}/terminal/read?lines=N        -> {data: ReadResult | null}
//   GET|PUT|DELETE /api/experimental/persistent-pty/{id}              PUT {size?, title?, attachmentID?}
//   GET  /api/experimental/persistent-pty/{id}/snapshot               -> {data: {info, text, checkpoint(base64), cursor}}
//   POST /api/experimental/persistent-pty/handoff                     -> {handoff: {directory, instanceID, ticket, expiresAt} | null}
//   GET  /api/experimental/persistent-pty/{id}/connect?cursor=&attachment_id=&role=&takeover=&input_protocol=1  (WebSocket)
//     server -> client: text frames are JSON control messages, binary frames are raw PTY output bytes.
//     client -> server (input_protocol=1): binary [flag u8][cols u16 BE][rows u16 BE][payload]; flag 1 = input, 0 = resize only.

import Foundation
import Synchronization

/// Where the spike's opencode server listens. The password is per launch and never logged.
public struct SpikeServerEndpoint: Sendable {
    public let baseURL: URL
    public let password: String

    public init(baseURL: URL, password: String) {
        self.baseURL = baseURL
        self.password = password
    }

    var authorization: String { "Basic " + Data("opencode:\(password)".utf8).base64EncodedString() }
}

public struct SpikeTerminalSize: Codable, Sendable, Equatable {
    public var cols: Int
    public var rows: Int
    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

public struct SpikePersistentTerminalInfo: Decodable, Sendable {
    public struct Output: Decodable, Sendable {
        public let head: Int
        public let tail: Int
    }

    public let id: String
    public let title: String
    public let command: String
    public let cwd: String
    public let status: String
    public let pid: Int
    public let exitCode: Int?
    public let sessionID: String
    public let foregroundProcess: String?
    public let size: SpikeTerminalSize
    public let output: Output
}

public struct SpikeTerminalSnapshot: Sendable {
    public let info: SpikePersistentTerminalInfo
    public let text: String
    /// VT bytes that redraw the current screen (not the scrollback) on a fresh emulator.
    public let checkpoint: Data
    public let cursor: (x: Int, y: Int)
}

public struct SpikeTerminalReadResult: Decodable, Sendable {
    public struct Screen: Decodable, Sendable {
        public let text: String
        public let cols: Int
        public let rows: Int
    }

    public let ptyID: String
    public let title: String
    public let cwd: String
    public let foregroundProcess: String?
    public let screen: Screen
}

public struct SpikeClientError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Plain HTTP calls. Every call is async and runs off the main actor.
public final class SpikePTYClient: Sendable {
    public let endpoint: SpikeServerEndpoint
    private let session: URLSession

    public init(endpoint: SpikeServerEndpoint) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: Sessions and terminals

    public func createSession(directory: String, title: String) async throws -> String {
        struct Body: Encodable {
            struct Location: Encodable { let directory: String }
            let title: String
            let location: Location
        }
        struct Created: Decodable { let id: String }
        let created: Created = try await call("POST", "api/session", body: Body(title: title, location: .init(directory: directory)))
        return created.id
    }

    public func createTerminal(
        sessionID: String, cwd: String, size: SpikeTerminalSize, title: String, env: [String: String] = [:],
        command: String? = nil, args: [String] = []
    ) async throws -> SpikePersistentTerminalInfo {
        struct Body: Encodable {
            let command: String?
            let args: [String]
            let cwd: String
            let title: String
            let env: [String: String]
            let size: SpikeTerminalSize
        }
        return try await call(
            "POST", "api/experimental/session/\(sessionID)/terminal",
            body: Body(command: command, args: args, cwd: cwd, title: title, env: env, size: size)
        )
    }

    public func listTerminals(sessionID: String) async throws -> [SpikePersistentTerminalInfo] {
        try await call("GET", "api/experimental/session/\(sessionID)/terminal")
    }

    public func terminal(_ ptyID: String) async throws -> SpikePersistentTerminalInfo {
        try await call("GET", "api/experimental/persistent-pty/\(ptyID)")
    }

    public func resize(_ ptyID: String, to size: SpikeTerminalSize, attachmentID: String?) async throws -> SpikePersistentTerminalInfo {
        struct Body: Encodable {
            let size: SpikeTerminalSize
            let attachmentID: String?
        }
        return try await call("PUT", "api/experimental/persistent-pty/\(ptyID)", body: Body(size: size, attachmentID: attachmentID))
    }

    public func delete(_ ptyID: String) async throws {
        _ = try await raw("DELETE", "api/experimental/persistent-pty/\(ptyID)", body: nil, expect: [204])
    }

    public func snapshot(_ ptyID: String) async throws -> SpikeTerminalSnapshot {
        struct Wire: Decodable {
            struct Cursor: Decodable { let x: Int; let y: Int }
            let info: SpikePersistentTerminalInfo
            let text: String
            let checkpoint: String
            let cursor: Cursor
        }
        let wire: Wire = try await call("GET", "api/experimental/persistent-pty/\(ptyID)/snapshot")
        return SpikeTerminalSnapshot(
            info: wire.info, text: wire.text, checkpoint: Data(base64Encoded: wire.checkpoint) ?? Data(),
            cursor: (wire.cursor.x, wire.cursor.y)
        )
    }

    /// What the agent sees: `experimental.persistentPty.read` (the session's current terminal).
    public func read(sessionID: String, lines: Int?) async throws -> SpikeTerminalReadResult? {
        let query = lines.map { "?lines=\($0)" } ?? ""
        let result: SpikeTerminalReadResult? = try await call("GET", "api/experimental/session/\(sessionID)/terminal/read\(query)")
        return result
    }

    /// Asks the server to hand its pty daemon to a successor. Returns the JSON to put in OPENCODE_PTY_HANDOFF.
    public func handoff() async throws -> Data? {
        let data = try await raw("POST", "api/experimental/persistent-pty/handoff", body: nil, expect: [200])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let handoff = object["handoff"], !(handoff is NSNull) else { return nil }
        return try JSONSerialization.data(withJSONObject: handoff)
    }

    public func serverPID() async throws -> Int {
        struct Info: Decodable { let pid: Int }
        let data = try await raw("GET", "api/info", body: nil, expect: [200])
        return try JSONDecoder().decode(Info.self, from: data).pid
    }

    // MARK: WebSocket

    public func connect(
        ptyID: String, cursor: Int, attachmentID: String = UUID().uuidString, observer: Bool = false, takeover: Bool = false,
        sink: @escaping @Sendable (SpikePTYEvent) -> Void
    ) -> SpikePTYConnection {
        var components = URLComponents(
            url: endpoint.baseURL.appending(path: "api/experimental/persistent-pty/\(ptyID)/connect"),
            resolvingAgainstBaseURL: false
        )!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = [
            URLQueryItem(name: "cursor", value: String(cursor)),
            URLQueryItem(name: "attachment_id", value: attachmentID),
            URLQueryItem(name: "role", value: observer ? "observer" : "controller"),
            URLQueryItem(name: "takeover", value: takeover ? "true" : "false"),
            URLQueryItem(name: "input_protocol", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(endpoint.authorization, forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        // The first message after attach carries the whole retained replay (up to the server's scrollback cap).
        task.maximumMessageSize = 64 << 20
        return SpikePTYConnection(task: task, attachmentID: attachmentID, sink: sink)
    }

    // MARK: Plumbing

    private struct Envelope<T: Decodable>: Decodable { let data: T }

    private func call<T: Decodable>(_ method: String, _ path: String) async throws -> T {
        let data = try await raw(method, path, body: nil, expect: [200])
        return try JSONDecoder().decode(Envelope<T>.self, from: data).data
    }

    private func call<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B) async throws -> T {
        let data = try await raw(method, path, body: try JSONEncoder().encode(body), expect: [200])
        return try JSONDecoder().decode(Envelope<T>.self, from: data).data
    }

    private func raw(_ method: String, _ path: String, body: Data?, expect: Set<Int>) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: endpoint.baseURL)!)
        request.httpMethod = method
        request.setValue(endpoint.authorization, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard expect.contains(status) else {
            throw SpikeClientError("\(method) \(path) -> \(status) \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return data
    }
}

/// Events from one PTY WebSocket, delivered on the connection's receive task (never the main actor).
public enum SpikePTYEvent: Sendable {
    case attached(attachmentID: String, size: SpikeTerminalSize, requestedOffset: Int, availableOffset: Int, endOffset: Int, truncated: Bool)
    case output(Data)
    case replayComplete(endOffset: Int)
    case resized(cols: Int, rows: Int)
    case controllerChanged(attachmentID: String?)
    case exited(code: Int?, finalOffset: Int?)
    case titleChanged(String)
    case foregroundProcessChanged(String?)
    case unknown(String)
    case closed(code: Int, reason: String)
}

/// One attachment to a persistent PTY. Owns its receive task; `close()` cancels it.
public final class SpikePTYConnection: Sendable {
    public let attachmentID: String
    private let task: URLSessionWebSocketTask
    private let receiver = SpikeLocked<Task<Void, Never>?>(nil)
    /// Output byte offset of the next byte we expect (the `cursor` to reconnect with).
    private let offsetState = SpikeLocked(0)
    private let bytesReceived = SpikeLocked(0)

    init(task: URLSessionWebSocketTask, attachmentID: String, sink: @escaping @Sendable (SpikePTYEvent) -> Void) {
        self.task = task
        self.attachmentID = attachmentID
        task.resume()
        let receive = Task { [task, offsetState, bytesReceived] in
            var replaying = true
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    sink(.closed(code: task.closeCode.rawValue, reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "\(error)"))
                    return
                }
                switch message {
                case .data(let data):
                    bytesReceived.withLock { $0 += data.count }
                    if !replaying { offsetState.withLock { $0 += data.count } }
                    sink(.output(data))
                case .string(let text):
                    let event = SpikePTYConnection.decodeControl(text)
                    switch event {
                    case .attached(_, _, _, _, let end, _): offsetState.withLock { $0 = end }
                    case .replayComplete(let end):
                        replaying = false
                        offsetState.withLock { $0 = end }
                    default: break
                    }
                    sink(event)
                @unknown default:
                    break
                }
            }
        }
        receiver.withLock { $0 = receive }
    }

    deinit { close() }

    public var offset: Int { offsetState.withLock { $0 } }
    public var totalBytesReceived: Int { bytesReceived.value }

    public func sendInput(_ bytes: some Collection<UInt8>, size: SpikeTerminalSize) {
        send(flag: 1, size: size, payload: bytes)
    }

    public func sendResize(_ size: SpikeTerminalSize) {
        send(flag: 0, size: size, payload: EmptyCollection())
    }

    public func close() {
        receiver.withLock { task in
            task?.cancel()
            task = nil
        }
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func send(flag: UInt8, size: SpikeTerminalSize, payload: some Collection<UInt8>) {
        var frame = Data(capacity: 5 + payload.count)
        frame.append(flag)
        frame.append(UInt8(truncatingIfNeeded: size.cols >> 8)); frame.append(UInt8(truncatingIfNeeded: size.cols))
        frame.append(UInt8(truncatingIfNeeded: size.rows >> 8)); frame.append(UInt8(truncatingIfNeeded: size.rows))
        frame.append(contentsOf: payload)
        // URLSessionWebSocketTask serializes sends in call order.
        task.send(.data(frame)) { _ in }
    }

    static func decodeControl(_ text: String) -> SpikePTYEvent {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return .unknown(text) }
        switch type {
        case "attached":
            let info = object["info"] as? [String: Any]
            let size = info?["size"] as? [String: Any]
            let replay = object["replay"] as? [String: Any]
            return .attached(
                attachmentID: object["attachmentID"] as? String ?? "",
                size: SpikeTerminalSize(cols: size?["cols"] as? Int ?? 0, rows: size?["rows"] as? Int ?? 0),
                requestedOffset: replay?["requestedOffset"] as? Int ?? 0,
                availableOffset: replay?["availableOffset"] as? Int ?? 0,
                endOffset: replay?["endOffset"] as? Int ?? 0,
                truncated: replay?["truncated"] as? Bool ?? false
            )
        case "replay_complete": return .replayComplete(endOffset: object["endOffset"] as? Int ?? 0)
        case "resized": return .resized(cols: object["cols"] as? Int ?? 0, rows: object["rows"] as? Int ?? 0)
        case "controller_changed": return .controllerChanged(attachmentID: object["attachmentID"] as? String)
        case "exited": return .exited(code: object["exitCode"] as? Int, finalOffset: object["finalOffset"] as? Int)
        case "title_changed": return .titleChanged(object["title"] as? String ?? "")
        case "foreground_process_changed": return .foregroundProcessChanged(object["process"] as? String)
        default: return .unknown(text)
        }
    }
}
