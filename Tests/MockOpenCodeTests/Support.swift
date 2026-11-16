import Foundation
import Network
import Synchronization
@testable import MockOpenCode

/// Plain URLSession client for the mock, with the same auth and JSON handling a real client needs.
struct TestClient: Sendable {
    let endpoint: MockOpenCodeEndpoint
    let session: URLSession

    init(_ endpoint: MockOpenCodeEndpoint) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: configuration)
    }

    struct Reply: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
        var json: JSONValue { (try? JSONValue.parse(body)) ?? .null }
    }

    func request(
        _ method: String, _ path: String, json: JSONValue? = nil, auth: Bool = true, headers: [String: String] = [:]
    ) async throws -> Reply {
        var request = URLRequest(url: URL(string: endpoint.url.absoluteString + path)!)
        request.httpMethod = method
        if auth, let header = endpoint.authorizationHeader { request.setValue(header, forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let json {
            request.httpBody = json.data
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            fields[String(describing: key).lowercased()] = String(describing: value)
        }
        return Reply(status: http.statusCode, headers: fields, body: data)
    }

    func get(_ path: String) async throws -> JSONValue { try await request("GET", path).json }

    func post(_ path: String, _ json: JSONValue) async throws -> JSONValue { try await request("POST", path, json: json).json }

    func createSession(title: String = "test", parentID: String? = nil) async throws -> String {
        let body: JSONValue = .compact([("title", .string(title)), ("parentID", parentID.map(JSONValue.string))])
        return try await post("/api/session", body)["data"]?["id"]?.stringValue ?? ""
    }

    func prompt(_ sessionID: String, _ text: String, delivery: String? = nil) async throws -> JSONValue {
        try await post(
            "/api/session/\(sessionID)/prompt",
            .compact([("text", .string(text)), ("delivery", delivery.map(JSONValue.string))]))
    }
}

/// A minimal WHATWG-style SSE parser for tests (handles `\n`, `\r\n`, comments and multi-line `data`).
struct SSEParser {
    private var line: [UInt8] = []
    private var data: [String] = []
    private var lastWasCR = false

    /// Feeds bytes; returns the `data` of every completed event.
    mutating func feed(_ bytes: some Sequence<UInt8>) -> [String] {
        var events: [String] = []
        for byte in bytes {
            if lastWasCR, byte == 10 {
                lastWasCR = false
                continue
            }
            lastWasCR = byte == 13
            if byte == 10 || byte == 13 {
                let text = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                if text.isEmpty {
                    if !data.isEmpty { events.append(data.joined(separator: "\n")) }
                    data.removeAll()
                } else if text.hasPrefix("data:") {
                    var value = text.dropFirst(5)
                    if value.first == " " { value = value.dropFirst() }
                    data.append(String(value))
                }
            } else {
                line.append(byte)
            }
        }
        return events
    }
}

/// Reads `/api/event` through URLSession and yields parsed events in order.
final class EventReader: Sendable {
    let events: AsyncStream<JSONValue>
    private let task: Task<Void, Never>

    init(_ client: TestClient, query: String = "") {
        let (stream, continuation) = AsyncStream.makeStream(of: JSONValue.self, bufferingPolicy: .unbounded)
        events = stream
        task = Task {
            var request = URLRequest(url: URL(string: client.endpoint.url.absoluteString + "/api/event" + query)!)
            request.timeoutInterval = 60
            if let header = client.endpoint.authorizationHeader {
                request.setValue(header, forHTTPHeaderField: "Authorization")
            }
            var parser = SSEParser()
            do {
                let (bytes, _) = try await client.session.bytes(for: request)
                var buffer: [UInt8] = []
                for try await byte in bytes {
                    buffer.append(byte)
                    if byte == 10 {
                        for event in parser.feed(buffer) {
                            if let value = try? JSONValue.parse(event) { continuation.yield(value) }
                        }
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
            } catch {}
            continuation.finish()
        }
    }

    deinit { task.cancel() }

    func cancel() { task.cancel() }

    /// Waits for `server.connected`, so later publishes are guaranteed to reach this subscriber.
    func connected() async throws {
        let first = try await next()
        guard first?["type"]?.stringValue == "server.connected" else { throw TestError("expected server.connected") }
    }

    func next(timeout: Duration = .seconds(10)) async throws -> JSONValue? {
        let events = events
        return try await withThrowingTaskGroup(of: JSONValue?.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestError("timed out waiting for an event")
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    /// Collects events until one satisfies `stop` (inclusive).
    func collect(until stop: (JSONValue) -> Bool, timeout: Duration = .seconds(20)) async throws -> [JSONValue] {
        var collected: [JSONValue] = []
        while let event = try await next(timeout: timeout) {
            collected.append(event)
            if stop(event) { return collected }
        }
        throw TestError("stream ended before the expected event; got \(collected.map { $0["type"]?.stringValue ?? "?" })")
    }
}

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension JSONValue {
    var type: String { self["type"]?.stringValue ?? "" }
}

func isType(_ type: String, session: String? = nil) -> (JSONValue) -> Bool {
    { event in event.type == type && (session == nil || event["data"]?["sessionID"]?.stringValue == session) }
}

/// A raw TCP client, for checking bytes exactly as they leave the server (chunk boundaries, abrupt closes).
final class RawConnection: Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.raw")

    init(port: UInt16) async throws {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let resumed = Mutex(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                let result: Result<Void, any Error>? =
                    switch state {
                    case .ready: .success(())
                    case let .failed(error): .failure(error)
                    default: nil
                    }
                guard let result else { return }
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: Data(text.utf8),
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    /// The next bytes, or `nil` at end of stream or on error.
    func receive() async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete || error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func close() { connection.cancel() }
}

/// Decodes an HTTP/1.1 chunked body incrementally, recording each chunk's size.
struct ChunkDecoder {
    private var buffer = Data()
    private(set) var headDone = false
    private(set) var head = ""
    private(set) var chunkSizes: [Int] = []
    private(set) var payload = Data()
    private(set) var finished = false

    mutating func feed(_ data: Data) {
        buffer.append(data)
        if !headDone {
            guard let range = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else { return }
            head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
            buffer = Data(buffer[range.upperBound...])
            headDone = true
        }
        while let lineEnd = buffer.firstRange(of: Data("\r\n".utf8)) {
            let sizeText = String(decoding: buffer[..<lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(sizeText, radix: 16) else { return }
            let start = lineEnd.upperBound
            guard buffer.distance(from: start, to: buffer.endIndex) >= size + 2 else { return }
            let end = buffer.index(start, offsetBy: size)
            if size == 0 {
                finished = true
                buffer = Data()
                return
            }
            chunkSizes.append(size)
            payload.append(buffer[start..<end])
            buffer = Data(buffer[buffer.index(end, offsetBy: 2)...])
        }
    }
}
