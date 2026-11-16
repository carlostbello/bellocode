// SPIKE (gate G3). Throwaway opencode launcher and HTTP/RPC/SSE client. The real ones live in OpenCodeKit; the spike
// deliberately does not depend on it. Pattern copied from Sources/BelloCodeApp/SmokeTest.swift.

import Foundation
import Synchronization

/// A running opencode child with isolated XDG directories, owned by this process.
public final class SpikeServer: Sendable {
    public let baseURL: URL
    public let directory: URL
    private let password: String
    private let process: Process
    private let stdinLease: FileHandle
    private let root: URL
    private let stderrTail: StderrTail
    public let urlSession: URLSession

    public struct LaunchError: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    private init(baseURL: URL, directory: URL, password: String, process: Process, stdinLease: FileHandle, root: URL, stderrTail: StderrTail) {
        self.baseURL = baseURL
        self.directory = directory
        self.password = password
        self.process = process
        self.stdinLease = stdinLease
        self.root = root
        self.stderrTail = stderrTail
        let configuration = URLSessionConfiguration.ephemeral
        // `attach` stays pending for the attachment's lifetime and `/api/event` is endless: no idle timeouts.
        configuration.timeoutIntervalForRequest = 24 * 3600
        configuration.timeoutIntervalForResource = 24 * 3600
        configuration.httpMaximumConnectionsPerHost = 16
        self.urlSession = URLSession(configuration: configuration)
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var stderrText: String { stderrTail.text }

    /// Launches `opencode serve --stdio --port 0` with temporary XDG directories; never touches the user's own.
    public static func launch(binary: URL) async throws -> SpikeServer {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: binary.path) else { throw LaunchError("no opencode at \(binary.path)") }
        let root = fileManager.temporaryDirectory.appending(path: "bellocode-g3-\(UUID().uuidString)")
        for name in ["config", "data", "state", "cache", "home", "work"] {
            try fileManager.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        let password = UUID().uuidString + UUID().uuidString
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve", "--stdio", "--port", "0"]
        process.currentDirectoryURL = root.appending(path: "work")
        process.environment = [
            "HOME": root.appending(path: "home").path,
            "XDG_CONFIG_HOME": root.appending(path: "config").path,
            "XDG_DATA_HOME": root.appending(path: "data").path,
            "XDG_STATE_HOME": root.appending(path: "state").path,
            "XDG_CACHE_HOME": root.appending(path: "cache").path,
            "TMPDIR": fileManager.temporaryDirectory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "OPENCODE_PASSWORD": password,
            "OPENCODE_CLIENT": "bellocode",
            "OPENCODE_DISABLE_AUTOUPDATE": "1",
            "OPENCODE_DISABLE_CLAUDE_CODE": "1",
        ]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let tail = StderrTail()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { tail.append(data) }
        }
        let (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(64))
        // stdout is drained for the child's whole life (rule 13); only the first line matters.
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") { continuation.yield(String(line)) }
            }
        }
        try process.run()
        let first = try await withDeadline(.seconds(20)) {
            var iterator = lines.makeAsyncIterator()
            return await iterator.next()
        }
        struct Ready: Decodable { let url: URL }
        guard let first, let ready = try? JSONDecoder().decode(Ready.self, from: Data(first.utf8)), ready.url.host() == "127.0.0.1" else {
            process.terminate()
            throw LaunchError("no ready line; stderr: \(tail.text)")
        }
        let server = SpikeServer(
            baseURL: ready.url, directory: root.appending(path: "work"), password: password, process: process,
            stdinLease: stdin.fileHandleForWriting, root: root, stderrTail: tail
        )
        // `/api/info` answers 503 while starting.
        for _ in 0..<100 {
            if let (_, status) = try? await server.send("GET", "api/info"), status == 200 { return server }
            try await Task.sleep(for: .milliseconds(100))
        }
        server.shutdown()
        throw LaunchError("server never became healthy")
    }

    /// Closes the stdin lease, waits up to 5 s, then SIGTERM and SIGKILL. Only ever signals our own child.
    public func shutdown() {
        try? stdinLease.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
        let hard = Date().addingTimeInterval(3)
        while process.isRunning, Date() < hard { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        urlSession.invalidateAndCancel()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: HTTP

    public func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 24 * 3600
        request.setValue("Basic \(Data("opencode:\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try? body.encoded()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    public var locationQuery: [URLQueryItem] { [URLQueryItem(name: "location[directory]", value: directory.path)] }

    public func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> (JSONValue, Int) {
        let (data, response) = try await urlSession.data(for: request(method, path, query: query, body: body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let value = data.isEmpty ? JSONValue.null : ((try? JSONValue.parse(data)) ?? .string(String(decoding: data, as: UTF8.self)))
        return (value, status)
    }

    /// `POST /api/rpc/{rpcID}/{method}` with `{input}` → `{output}`; an `RpcError` body becomes `RPCError`.
    public func rpc(_ method: String, _ input: JSONValue, rpcID: String = BrowserContract.rpcID) async throws -> JSONValue {
        let (value, status) = try await send("POST", "api/rpc/\(rpcID)/\(method)", query: locationQuery, body: ["input": input])
        guard status == 200 else { throw RPCError(status: status, type: value["type"]?.string ?? "http", message: value["message"]?.string ?? value.compactText) }
        return value["output"] ?? .null
    }

    public struct RPCError: Error, CustomStringConvertible {
        public let status: Int
        public let type: String
        public let message: String
        public var description: String { "RPC \(status) \(type): \(message)" }
    }

    /// Server-wide event stream, parsed per WHATWG; yields each frame's JSON.
    public func events() -> AsyncThrowingStream<JSONValue, any Error> {
        let request = request("GET", "api/event")
        let session = urlSession
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(4_096)) { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LaunchError("event stream status \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
                    var parser = SSEParser()
                    for try await byte in bytes {
                        if let event = parser.feed(byte), let value = try? JSONValue.parse(Data(event.data.utf8)) {
                            continuation.yield(value)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private final class StderrTail: Sendable {
    private let storage = Mutex(Data())
    func append(_ data: Data) {
        storage.withLock { buffer in
            buffer.append(data)
            if buffer.count > 8_192 { buffer.removeFirst(buffer.count - 8_192) }
        }
    }
    var text: String { storage.withLock { String(decoding: $0, as: UTF8.self) } }
}

public struct DeadlineExceeded: Error, CustomStringConvertible {
    public var description: String { "deadline exceeded" }
}

public func withDeadline<T: Sendable>(_ duration: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw DeadlineExceeded()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw DeadlineExceeded() }
        return result
    }
}
