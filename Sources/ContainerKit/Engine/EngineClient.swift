import Foundation
import os

/// A failure from the container runtime's Engine API, typed so callers can say exactly what to do. `message` texts are
/// the daemon's own error strings (never request bodies, command output or environment values).
public enum ContainerError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The daemon answered with an error status.
    case http(status: Int, message: String)
    case notFound(String)
    case conflict(String)
    /// 401/403 from a registry during a pull ("sign in to the registry").
    case unauthorized(String)
    case unexpectedUpgrade(status: Int)
    case decoding(String)
    /// An error reported inside a progress stream (pull, build).
    case progress(String)
    /// No answer within the deadline; the socket was shut down.
    case timedOut(operation: String)
    /// The socket is missing or refuses connections (the runtime is stopped or starting).
    case unreachable(String)
    case cancelled

    public var description: String {
        switch self {
        case .http(let status, let message): "Engine API \(status): \(message)"
        case .notFound(let message): "not found: \(message)"
        case .conflict(let message): "conflict: \(message)"
        case .unauthorized(let message): "unauthorized: \(message)"
        case .unexpectedUpgrade(let status): "the daemon did not upgrade the connection (HTTP \(status))"
        case .decoding(let what): "could not decode \(what)"
        case .progress(let message): message
        case .timedOut(let operation): "the container runtime did not answer \(operation) in time"
        case .unreachable(let detail): "the container runtime is not reachable (\(detail))"
        case .cancelled: "cancelled"
        }
    }

    /// A registry refused the credentials (or needs some): the fix is to sign in to the registry.
    public var needsRegistrySignIn: Bool {
        switch self {
        case .unauthorized: return true
        case .progress(let message), .http(_, let message), .notFound(let message):
            let lower = message.lowercased()
            return lower.contains("unauthorized") || lower.contains("authentication required") || lower.contains("denied")
                || lower.contains("no basic auth credentials")
        default: return false
        }
    }

    /// Maps transport errors to `.unreachable`/`.cancelled`; passes `ContainerError` through.
    public static func from(_ error: any Error) -> ContainerError {
        if let error = error as? ContainerError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? SocketError { return .unreachable(error.description) }
        if let error = error as? HTTPParseError { return .unreachable("connection closed early (\(error))") }
        return .http(status: 0, message: String(describing: type(of: error)))
    }
}

/// Runs `operation` with a deadline. On expiry the operation's task is cancelled (which shuts its socket down) and
/// `.timedOut` is thrown.
public func withDeadline<T: Sendable>(_ timeout: Duration, operation name: String,
                                      _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw ContainerError.cancelled }
        guard let value = first else { throw ContainerError.timedOut(operation: name) }
        return value
    }
}

private let signposter = OSSignposter(subsystem: "app.bellocode.ContainerKit", category: "engine")

/// Docker Engine API client over a unix domain socket, without third-party code. Each call opens its own connection
/// (cheap over a unix socket), so a streaming or hijacked response never blocks another request.
///
/// Unary calls have a deadline (`requestTimeout`); streams (events, logs, pulls, exec) are bounded by their consumer,
/// which cancels them. Bodies read whole are capped. Nothing here logs request or response content: command output,
/// environment values and registry credentials never reach a log.
public struct EngineClient: Sendable {
    public let socketPath: String
    /// Path prefix such as `/v1.44`. Every endpoint used here exists in 1.44, BelloCode's minimum
    /// (`RuntimeDiscovery.minimumAPIVersion`); a daemon that no longer serves it is reported as unsupported.
    public let apiPrefix: String
    public let apiVersion: String
    /// Deadline for one unary request (connect, send, head, body).
    public var requestTimeout: Duration

    public init(socketPath: String, apiVersion: String = RuntimeDiscovery.minimumAPIVersion, requestTimeout: Duration = .seconds(30)) {
        self.socketPath = socketPath
        self.apiVersion = apiVersion
        self.apiPrefix = "/v\(apiVersion)"
        self.requestTimeout = requestTimeout
    }

    // MARK: Plumbing

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    func open(_ method: String, _ path: String, query: [(String, String)] = [], json: (any Encodable & Sendable)? = nil,
              body: Data? = nil, headers: [(String, String)] = []) async throws -> (HTTPConnection, HTTPResponseHead) {
        let state = signposter.beginInterval("request")
        defer { signposter.endInterval("request", state) }
        var target = apiPrefix + path
        if !query.isEmpty {
            var components = URLComponents()
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            target += "?" + (components.percentEncodedQuery ?? "")
        }
        var allHeaders = headers
        var payload = body
        if let json {
            payload = try Self.encoder.encode(json)
            allHeaders.append(("Content-Type", "application/json"))
        }
        let request = HTTPRequest(method: method, path: target, headers: allHeaders, body: payload)
        // The head must arrive within the request deadline; the body (a stream) is the caller's to bound.
        let socketPath = self.socketPath
        do {
            return try await withDeadline(requestTimeout, operation: "\(method) \(path)") {
                let connection = try HTTPConnection.open(unixPath: socketPath)
                do {
                    try await connection.send(request)
                    return (connection, try await connection.readHead())
                } catch {
                    connection.cancel()
                    throw error
                }
            }
        } catch {
            throw ContainerError.from(error)
        }
    }

    /// A request whose body is read whole (at most `limit` bytes), within `requestTimeout`. Throws for non-2xx answers.
    @discardableResult
    func call(_ method: String, _ path: String, query: [(String, String)] = [], json: (any Encodable & Sendable)? = nil,
              body: Data? = nil, headers: [(String, String)] = [], limit: Int = 32 * 1024 * 1024,
              timeout: Duration? = nil, accepting: Set<Int> = []) async throws -> Data {
        let operation = "\(method) \(path)"
        do {
            return try await withDeadline(timeout ?? requestTimeout, operation: operation) { [self] in
                let (connection, head) = try await open(method, path, query: query, json: json, body: body, headers: headers)
                defer { connection.cancel() }
                let data = try await connection.readBody(limit: limit)
                if accepting.contains(head.status) { return data }
                try Self.check(head, data)
                return data
            }
        } catch {
            throw ContainerError.from(error)
        }
    }

    static func check(_ head: HTTPResponseHead, _ data: Data) throws {
        guard (200..<300).contains(head.status) else {
            let message = (try? JSONDecoder().decode(ContainerErrorBody.self, from: data))?.message
                ?? String(decoding: data.prefix(512), as: UTF8.self)
            switch head.status {
            case 401, 403: throw ContainerError.unauthorized(message)
            case 404: throw ContainerError.notFound(message)
            case 409: throw ContainerError.conflict(message)
            default: throw ContainerError.http(status: head.status, message: message)
            }
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw ContainerError.decoding(String(describing: T.self)) }
    }

    /// Streams newline-delimited JSON values from a long-lived response.
    func jsonLines<T: Decodable & Sendable>(_ connection: HTTPConnection, as type: T.Type) -> AsyncThrowingStream<T, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    while let chunk = try await connection.nextBodyChunk() {
                        buffer.append(chunk)
                        if buffer.count > 4 * 1024 * 1024 { throw HTTPParseError.bodyTooLarge(limit: 4 * 1024 * 1024) }
                        while let newline = buffer.firstIndex(of: 0x0A) {
                            let line = buffer[buffer.startIndex..<newline]
                            buffer = Data(buffer[(newline + 1)...])
                            if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) { continue }
                            if let value = try? JSONDecoder().decode(T.self, from: line) {
                                // Overflow of this bounded buffer would drop values: we wait instead (pull model).
                                while case .dropped = continuation.yield(value) {
                                    try await Task.sleep(for: .milliseconds(5))
                                }
                            }
                        }
                    }
                    if !buffer.isEmpty, let value = try? JSONDecoder().decode(T.self, from: buffer) { continuation.yield(value) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                connection.cancel()
            }
        }
    }

    // MARK: System

    /// `GET /_ping` (unversioned): returns the daemon's API version header.
    public func ping(timeout: Duration = .seconds(3)) async throws -> String {
        do {
            return try await withDeadline(timeout, operation: "ping") { [socketPath] in
                let connection = try HTTPConnection.open(unixPath: socketPath)
                defer { connection.cancel() }
                try await connection.send(HTTPRequest(method: "GET", path: "/_ping"))
                let head = try await connection.readHead()
                let body = try await connection.readBody(limit: 1024)
                try Self.check(head, body)
                return head.header("api-version") ?? ""
            }
        } catch let error as SocketError {
            throw error  // callers distinguish "missing or refused" (not running) from other socket failures
        } catch {
            throw ContainerError.from(error)
        }
    }

    public func version() async throws -> EngineVersion { try decode(EngineVersion.self, try await call("GET", "/version")) }
    public func info() async throws -> EngineInfo { try decode(EngineInfo.self, try await call("GET", "/info")) }

    /// `GET /events` filtered to containers bearing `label`. The stream ends when the consumer stops iterating.
    public func events(labels: [String] = [], since: Date? = nil) async throws -> AsyncThrowingStream<EngineEvent, any Error> {
        var query: [(String, String)] = []
        if !labels.isEmpty { query.append(("filters", Self.filters(["label": labels]))) }
        if let since { query.append(("since", String(Int(since.timeIntervalSince1970)))) }
        let (connection, head) = try await open("GET", "/events", query: query)
        guard head.status == 200 else {
            let body = try await connection.readBody(limit: 64 * 1024)
            try Self.check(head, body)
            throw ContainerError.http(status: head.status, message: "")
        }
        return jsonLines(connection, as: EngineEvent.self)
    }

    static func filters(_ values: [String: [String]]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Images

    public func inspectImage(_ reference: String) async throws -> ImageSummary? {
        do {
            return try decode(ImageSummary.self, try await call("GET", "/images/\(Self.escape(reference))/json"))
        } catch ContainerError.notFound {
            return nil
        }
    }

    /// `POST /images/create`. `registryAuth` is the base64url JSON auth document, held only in memory.
    public func pullImage(_ reference: String, registryAuth: String? = nil,
                          progress: @Sendable (ProgressMessage) -> Void = { _ in }) async throws {
        let (name, tag) = Self.split(reference)
        var headers: [(String, String)] = []
        if let registryAuth { headers.append(("X-Registry-Auth", registryAuth)) }
        let (connection, head) = try await open("POST", "/images/create", query: [("fromImage", name), ("tag", tag)], headers: headers)
        if head.status != 200 {
            let body = try await connection.readBody(limit: 64 * 1024)
            try Self.check(head, body)
        }
        for try await message in jsonLines(connection, as: ProgressMessage.self) {
            if let error = message.error { throw ContainerError.progress(error) }
            progress(message)
        }
    }

    /// `POST /build` with an in-memory tar context (see `TarArchive`). Returns the image ID. `buildArgs` are sent as
    /// `buildargs` (proxies: `ImageBuildNetwork.buildArgs()`), `dockerfile` names the Dockerfile in the context, and
    /// `networkMode` the network `RUN` steps use.
    public func buildImage(context: Data, tag: String, labels: [String: String] = [:], pull: Bool = false,
                           buildArgs: [String: String] = [:], dockerfile: String? = nil, networkMode: String? = nil,
                           progress: @Sendable (ProgressMessage) -> Void = { _ in }) async throws -> String? {
        var query: [(String, String)] = [("t", tag), ("rm", "1"), ("forcerm", "1")]
        if !labels.isEmpty { query.append(("labels", Self.filtersObject(labels))) }
        if pull { query.append(("pull", "1")) }
        if !buildArgs.isEmpty { query.append(("buildargs", Self.filtersObject(buildArgs))) }
        if let dockerfile { query.append(("dockerfile", dockerfile)) }
        if let networkMode { query.append(("networkmode", networkMode)) }
        let (connection, head) = try await open("POST", "/build", query: query, body: context,
                                                headers: [("Content-Type", "application/x-tar")])
        if head.status != 200 {
            let body = try await connection.readBody(limit: 64 * 1024)
            try Self.check(head, body)
        }
        var imageID: String?
        for try await message in jsonLines(connection, as: ProgressMessage.self) {
            if let error = message.error { throw ContainerError.progress(error) }
            if let id = message.aux?.id { imageID = id }
            progress(message)
        }
        return imageID
    }

    static func filtersObject(_ values: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public func removeImage(_ reference: String, force: Bool = false) async throws {
        try await call("DELETE", "/images/\(Self.escape(reference))", query: [("force", force ? "1" : "0")])
    }

    static func split(_ reference: String) -> (String, String) {
        if reference.contains("@") { return (reference, "") }
        let slash = reference.lastIndex(of: "/") ?? reference.startIndex
        if let colon = reference[slash...].lastIndex(of: ":") {
            return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
        }
        return (reference, "latest")
    }

    static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? component
    }

    // MARK: Containers

    public func createContainer(name: String?, _ spec: ContainerCreate) async throws -> String {
        let query = name.map { [("name", $0)] } ?? []
        return try decode(IDResponse.self, try await call("POST", "/containers/create", query: query, json: spec)).id
    }

    /// 304 (already running) counts as success.
    public func startContainer(_ id: String) async throws {
        try await call("POST", "/containers/\(Self.escape(id))/start", limit: 64 * 1024, accepting: [304])
    }

    /// 304 (already stopped) counts as success. The daemon waits up to `timeout` seconds before SIGKILL.
    public func stopContainer(_ id: String, timeout: Int = 5) async throws {
        try await call("POST", "/containers/\(Self.escape(id))/stop", query: [("t", String(timeout))], limit: 64 * 1024,
                       timeout: .seconds(timeout + 30), accepting: [304])
    }

    public func restartContainer(_ id: String, timeout: Int = 5) async throws {
        try await call("POST", "/containers/\(Self.escape(id))/restart", query: [("t", String(timeout))], limit: 64 * 1024,
                       timeout: .seconds(timeout + 30))
    }

    public func killContainer(_ id: String, signal: String = "SIGKILL") async throws {
        try await call("POST", "/containers/\(Self.escape(id))/kill", query: [("signal", signal)])
    }

    public func removeContainer(_ id: String, force: Bool = false, volumes: Bool = false) async throws {
        try await call("DELETE", "/containers/\(Self.escape(id))", query: [("force", force ? "1" : "0"), ("v", volumes ? "1" : "0")])
    }

    public func inspectContainer(_ id: String) async throws -> ContainerInspect? {
        do {
            return try decode(ContainerInspect.self, try await call("GET", "/containers/\(Self.escape(id))/json"))
        } catch ContainerError.notFound {
            return nil
        }
    }

    /// Containers (running or not) bearing every `key=value` label given.
    public func listContainers(labels: [String], all: Bool = true) async throws -> [ContainerSummary] {
        try decode([ContainerSummary].self, try await call(
            "GET", "/containers/json", query: [("all", all ? "1" : "0"), ("filters", Self.filters(["label": labels]))]))
    }

    /// `POST /containers/{id}/wait`: blocks until the container stops; returns its exit code.
    public func waitContainer(_ id: String, condition: String = "not-running") async throws -> Int {
        try decode(WaitResponse.self, try await call("POST", "/containers/\(Self.escape(id))/wait", query: [("condition", condition)], timeout: .seconds(24 * 3600))).statusCode
    }

    /// `GET /containers/{id}/logs`. Output is demultiplexed unless the container has a TTY.
    public func logs(_ id: String, follow: Bool, tail: String = "100", tty: Bool = false) async throws -> AsyncThrowingStream<OutputChunk, any Error> {
        let (connection, head) = try await open("GET", "/containers/\(Self.escape(id))/logs", query: [
            ("follow", follow ? "1" : "0"), ("stdout", "1"), ("stderr", "1"), ("tail", tail),
        ])
        if head.status != 200 {
            let body = try await connection.readBody(limit: 64 * 1024)
            try Self.check(head, body)
        }
        return Self.outputStream(tty: tty) { try await connection.nextBodyChunk() } cancel: { connection.cancel() }
    }

    /// `PUT /containers/{id}/archive`: extracts a tar into the container (used to install helper files).
    public func putArchive(_ id: String, path: String, tar: Data) async throws {
        try await call("PUT", "/containers/\(Self.escape(id))/archive", query: [("path", path)], body: tar,
                       headers: [("Content-Type", "application/x-tar")])
    }

    /// `POST /containers/{id}/attach` with a hijacked stream.
    public func attach(_ id: String, stdin: Bool, logs: Bool = false) async throws -> HTTPConnection {
        let (connection, head) = try await open("POST", "/containers/\(Self.escape(id))/attach", query: [
            ("stream", "1"), ("stdin", stdin ? "1" : "0"), ("stdout", "1"), ("stderr", "1"), ("logs", logs ? "1" : "0"),
        ], headers: [("Connection", "Upgrade"), ("Upgrade", "tcp")])
        guard head.status == 101 || head.status == 200 else {
            connection.cancel()
            throw ContainerError.unexpectedUpgrade(status: head.status)
        }
        return connection
    }

    // MARK: Exec

    public func createExec(_ containerID: String, _ config: ExecConfig) async throws -> String {
        try decode(IDResponse.self, try await call("POST", "/containers/\(Self.escape(containerID))/exec", json: config)).id
    }

    struct ExecStart: Encodable {
        var detach: Bool
        var tty: Bool
        var consoleSize: [Int]?
        enum CodingKeys: String, CodingKey { case detach = "Detach", tty = "Tty", consoleSize = "ConsoleSize" }
    }

    /// Starts an exec and returns the hijacked connection: write stdin to it (`closeWrite()` sends EOF), read raw TTY
    /// bytes or multiplexed frames (`StreamDemuxer`) from it.
    public func startExec(_ execID: String, tty: Bool, consoleSize: (rows: Int, cols: Int)? = nil) async throws -> HTTPConnection {
        let (connection, head) = try await open(
            "POST", "/exec/\(Self.escape(execID))/start",
            json: ExecStart(detach: false, tty: tty, consoleSize: consoleSize.map { [$0.rows, $0.cols] }),
            headers: [("Connection", "Upgrade"), ("Upgrade", "tcp")])
        guard head.status == 101 || head.status == 200 else {
            let body = try? await connection.readBody(limit: 64 * 1024)
            connection.cancel()
            try Self.check(head, body ?? Data())
            throw ContainerError.unexpectedUpgrade(status: head.status)
        }
        return connection
    }

    public func resizeExec(_ execID: String, rows: Int, cols: Int) async throws {
        try await call("POST", "/exec/\(Self.escape(execID))/resize", query: [("h", String(rows)), ("w", String(cols))])
    }

    public func inspectExec(_ execID: String) async throws -> ExecInspect {
        try decode(ExecInspect.self, try await call("GET", "/exec/\(Self.escape(execID))/json"))
    }

    // MARK: Volumes and networks

    public func createVolume(name: String, labels: [String: String]) async throws {
        struct Body: Encodable {
            var name: String
            var labels: [String: String]
            enum CodingKeys: String, CodingKey { case name = "Name", labels = "Labels" }
        }
        try await call("POST", "/volumes/create", json: Body(name: name, labels: labels))
    }

    public func removeVolume(_ name: String, force: Bool = false) async throws {
        try await call("DELETE", "/volumes/\(Self.escape(name))", query: [("force", force ? "1" : "0")])
    }

    public func listVolumes(labels: [String]) async throws -> [String] {
        struct Body: Decodable {
            struct Volume: Decodable { var name: String; enum CodingKeys: String, CodingKey { case name = "Name" } }
            var volumes: [Volume]?
            enum CodingKeys: String, CodingKey { case volumes = "Volumes" }
        }
        return try decode(Body.self, try await call("GET", "/volumes", query: [("filters", Self.filters(["label": labels]))])).volumes?.map(\.name) ?? []
    }

    public func createNetwork(name: String, labels: [String: String], isInternal: Bool) async throws -> String {
        struct Body: Encodable {
            var name: String
            var labels: [String: String]
            var `internal`: Bool
            enum CodingKeys: String, CodingKey { case name = "Name", labels = "Labels", `internal` = "Internal" }
        }
        return try decode(IDResponse.self, try await call("POST", "/networks/create", json: Body(name: name, labels: labels, internal: isInternal))).id
    }

    public func removeNetwork(_ id: String) async throws {
        try await call("DELETE", "/networks/\(Self.escape(id))")
    }

    public func inspectNetwork(_ id: String) async throws -> NetworkInfo? {
        do {
            return try decode(NetworkInfo.self, try await call("GET", "/networks/\(Self.escape(id))"))
        } catch ContainerError.notFound {
            return nil
        }
    }

    /// Volumes with labels, sizes and reference counts (`GET /system/df?type=volume`; sizes may be unknown).
    public func volumeUsage() async throws -> [VolumeInfo] {
        struct Body: Decodable {
            var volumes: [VolumeInfo]?
            enum CodingKeys: String, CodingKey { case volumes = "Volumes" }
        }
        return try decode(Body.self, try await call("GET", "/system/df", query: [("type", "volume")], timeout: .seconds(60))).volumes ?? []
    }

    /// Volumes bearing every label given, with their labels (no sizes).
    public func listVolumeInfos(labels: [String]) async throws -> [VolumeInfo] {
        struct Body: Decodable {
            var volumes: [VolumeInfo]?
            enum CodingKeys: String, CodingKey { case volumes = "Volumes" }
        }
        return try decode(Body.self, try await call("GET", "/volumes", query: [("filters", Self.filters(["label": labels]))])).volumes ?? []
    }

    public func listImages() async throws -> [ImageListItem] {
        try decode([ImageListItem].self, try await call("GET", "/images/json"))
    }

    public func listNetworks(labels: [String]) async throws -> [String] {
        struct Net: Decodable { var id: String; enum CodingKeys: String, CodingKey { case id = "Id" } }
        return try decode([Net].self, try await call("GET", "/networks", query: [("filters", Self.filters(["label": labels]))])).map(\.id)
    }

    // MARK: Output helpers

    /// Wraps a raw byte source as output chunks: demultiplexed in non-TTY mode, all stdout in TTY mode.
    public static func outputStream(tty: Bool, next: @escaping @Sendable () async throws -> Data?,
                                    cancel: @escaping @Sendable () -> Void) -> AsyncThrowingStream<OutputChunk, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let task = Task {
                var demuxer = StreamDemuxer()
                do {
                    while let data = try await next(), !Task.isCancelled {
                        let chunks = tty ? [OutputChunk(.stdout, data)] : try demuxer.feed(data)
                        for chunk in chunks {
                            while case .dropped = continuation.yield(chunk) { try await Task.sleep(for: .milliseconds(2)) }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                cancel()
            }
        }
    }
}
