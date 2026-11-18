import Darwin
import Dispatch
import Foundation
import Synchronization
import os

private let signposter = OSSignposter(subsystem: "app.bellocode.ContainerKit", category: "docker-filter")
private let log = Logger(subsystem: "app.bellocode", category: "docker-filter")

/// BelloCode's filtered Docker endpoint (docs/features/containers.md, "Docker from the workspace"): a Docker-API
/// compatible HTTP/1.1 server on the Mac's loopback. Containers reach it as `host.docker.internal:<port>` (Rancher
/// Desktop forwards that address to the Mac's loopback); host docker-only mode uses `127.0.0.1:<port>`.
///
/// Authentication: every request path starts with a per-scope token (`DOCKER_HOST=tcp://host:port/<token>`; the Docker
/// client puts it in front of every path, including hijacked ones). A request without a known token is refused before
/// anything else is read. One connection serves one request: the request is read and checked
/// (`DockerFilterPolicy`), sent to the daemon with `Connection: close`, and the daemon's answer is relayed until it
/// closes; a client never gets to send a second, unchecked request on the same daemon connection. Upgraded streams
/// (attach, exec start, build session) are relayed both ways only for routes the policy allowed.
public final class DockerFilterProxy: Sendable {
    public let port: Int
    public let daemonSocket: String
    private let policy: DockerFilterPolicy
    private let listener: FileStream
    private let acceptQueue = DispatchQueue(label: "bellocode.docker-filter.accept")
    /// token → scope.
    private let scopes = Mutex<[String: DockerScope]>([:])
    private let connections = Mutex<[Int: (FileStream, Task<Void, Never>?)]>([:])
    private let counter = Mutex(0)
    /// Refused requests (scope key, method, route, message), newest last, bounded: the app surfaces them.
    private let refusals = Mutex<[Refusal]>([])
    private let onAfter: @Sendable (String, AfterAction) -> Void
    private let onRefusal: @Sendable (Refusal) -> Void
    public let maxConnections = 128
    /// Request bodies that are read whole (JSON) may be at most this large.
    public static let maxJSONBody = 4 * 1024 * 1024

    public struct Refusal: Sendable, Equatable {
        public var scope: String
        public var method: String
        public var path: String
        public var message: String
        public var date: Date
    }

    /// - Parameters:
    ///   - lookup: daemon lookups for ownership checks (nil: `EngineDockerLookup` over `daemonSocket`).
    ///   - imageRefusal: the image policy.
    ///   - host: the address to listen on (loopback only).
    public init(daemonSocket: String, port: Int = 0, lookup: (any DockerLookup)? = nil,
                imageRefusal: @escaping @Sendable (String) -> String? = { _ in nil },
                onAfter: @escaping @Sendable (String, AfterAction) -> Void = { _, _ in },
                onRefusal: @escaping @Sendable (Refusal) -> Void = { _ in }) throws {
        self.daemonSocket = daemonSocket
        self.onAfter = onAfter
        self.onRefusal = onRefusal
        let pulled = PulledImages()
        pulledStore = pulled
        policy = DockerFilterPolicy(lookup: lookup ?? EngineDockerLookup(client: EngineClient(socketPath: daemonSocket)),
                                    imageRefusal: imageRefusal, pulledBy: { scope in pulled.images(scope) })
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system(operation: "socket", errno: errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")  // loopback only
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            throw SocketError.system(operation: "bind", errno: code)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.port = Int(UInt16(bigEndian: actual.sin_port))
        listener = FileStream(fd: fd, owned: true, isSocket: true)
    }

    private let pulledStore: PulledImages

    /// Registers (or updates) a scope and returns its token, stable for the scope's key while the proxy lives.
    @discardableResult
    public func register(_ scope: DockerScope) -> String {
        scopes.withLock { scopes in
            if let (token, _) = scopes.first(where: { $0.value.key == scope.key }) {
                scopes[token] = scope
                return token
            }
            var bytes = [UInt8](repeating: 0, count: 24)
            _ = SecRandomCopyBytesShim.fill(&bytes)
            let token = "bc" + bytes.map { String(format: "%02x", $0) }.joined()
            scopes[token] = scope
            return token
        }
    }

    /// Removes a scope: its token stops working at once.
    public func unregister(scope key: String) {
        scopes.withLock { scopes in scopes = scopes.filter { $0.value.key != key } }
    }

    public var recentRefusals: [Refusal] { refusals.withLock { $0 } }

    /// Accepts until `stop()` or cancellation; each connection is served by a task this proxy owns.
    public func run() async {
        await withTaskCancellationHandler {
            while !Task.isCancelled, !listener.isCancelled {
                guard let fd = await accept() else { break }
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                let peer = FileStream(fd: fd, owned: true, isSocket: true)
                let id = counter.withLock { value -> Int in
                    value += 1
                    return value
                }
                let admitted = connections.withLock { slots -> Bool in
                    guard slots.count < maxConnections else { return false }
                    slots[id] = (peer, nil)
                    return true
                }
                guard admitted else {
                    peer.cancel()
                    continue
                }
                let task = Task { [self] in
                    await serve(peer)
                    peer.cancel()
                    _ = connections.withLock { $0.removeValue(forKey: id) }
                }
                connections.withLock { slots in if slots[id] != nil { slots[id]?.1 = task } }
            }
        } onCancel: {
            stop()
        }
    }

    public func stop() {
        listener.cancel()
        Darwin.shutdown(listener.fd, SHUT_RDWR)
        for (peer, task) in connections.withLock({ Array($0.values) }) {
            peer.cancel()
            task?.cancel()
        }
    }

    private func accept() async -> Int32? {
        await withCheckedContinuation { continuation in
            acceptQueue.async { [listener] in
                while true {
                    var pfd = pollfd(fd: listener.fd, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&pfd, 1, 200)
                    if listener.isCancelled { return continuation.resume(returning: nil) }
                    if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                    let fd = Darwin.accept(listener.fd, nil, nil)
                    if fd >= 0 { return continuation.resume(returning: fd) }
                    if errno == EINTR { continue }
                    return continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: One request

    struct RequestHead {
        var method: String
        var target: String
        var headers: [(String, String)]
        func header(_ name: String) -> String? { headers.first { $0.0.lowercased() == name }?.1 }
    }

    /// Reads the head (bounded) and returns it with whatever body bytes followed it.
    static func readHead(_ peer: FileStream) async throws -> (RequestHead, Data)? {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.range(of: terminator) == nil {
            if buffer.count > HTTPHeadParser.maxHeadBytes { throw HTTPParseError.headTooLarge }
            let data = try await peer.read()
            if data.isEmpty { return nil }
            buffer.append(data)
        }
        let range = buffer.range(of: terminator)!
        let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw HTTPParseError.malformedStatusLine }
        var headers: [(String, String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformedHeader }
            headers.append((String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return (RequestHead(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers), Data(buffer[range.upperBound...]))
    }

    /// Reads a request body: by `Content-Length`, or chunked (decoded). Bounded by `limit`.
    struct BodyReader {
        let peer: FileStream
        var buffered: Data
        let chunked: Bool
        var remaining: Int
        var finished = false
        let limit: Int
        var total = 0

        init(peer: FileStream, buffered: Data, head: RequestHead, limit: Int) throws {
            self.peer = peer
            self.buffered = buffered
            self.limit = limit
            if let encoding = head.header("transfer-encoding") {
                guard encoding.lowercased() == "chunked" else { throw HTTPParseError.malformedHeader }
                guard head.header("content-length") == nil else { throw HTTPParseError.malformedHeader }
                chunked = true
                remaining = 0
            } else {
                chunked = false
                remaining = Int(head.header("content-length") ?? "0") ?? -1
                guard remaining >= 0 else { throw HTTPParseError.malformedHeader }
                finished = remaining == 0
            }
        }

        mutating func fill() async throws {
            let data = try await peer.read()
            if data.isEmpty { throw HTTPParseError.unexpectedEnd }
            buffered.append(data)
        }

        /// The next piece of the body, nil at its end.
        mutating func next() async throws -> Data? {
            if finished { return nil }
            var piece: Data
            if !chunked {
                if buffered.isEmpty { try await fill() }
                let count = min(remaining, buffered.count)
                piece = Data(buffered.prefix(count))
                buffered = Data(buffered.dropFirst(count))
                remaining -= count
                if remaining == 0 { finished = true }
            } else {
                if remaining == 0 {
                    // A chunk-size line.
                    while buffered.range(of: Data("\r\n".utf8)) == nil {
                        if buffered.count > 1024 { throw HTTPParseError.malformedChunk }
                        try await fill()
                    }
                    let line = buffered.range(of: Data("\r\n".utf8))!
                    let text = String(decoding: buffered[..<line.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
                    guard let size = Int(text.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else { throw HTTPParseError.malformedChunk }
                    buffered = Data(buffered[line.upperBound...])
                    if size == 0 {
                        // Trailer section: skip to the empty line.
                        while buffered.range(of: Data("\r\n".utf8)) == nil { try await fill() }
                        finished = true
                        return nil
                    }
                    remaining = size + 2  // data and its CRLF
                }
                if buffered.isEmpty { try await fill() }
                let count = min(remaining, buffered.count)
                piece = Data(buffered.prefix(count))
                buffered = Data(buffered.dropFirst(count))
                remaining -= count
                if remaining < 2 {
                    // Strip the chunk's trailing CRLF from the payload.
                    let crlfInPiece = 2 - remaining
                    piece = Data(piece.dropLast(min(crlfInPiece, piece.count)))
                }
            }
            total += piece.count
            if total > limit { throw HTTPParseError.bodyTooLarge(limit: limit) }
            return piece
        }

        mutating func readAll() async throws -> Data {
            var data = Data()
            while let piece = try await next() { data.append(piece) }
            return data
        }
    }

    func serve(_ peer: FileStream) async {
        let interval = signposter.beginInterval("request")
        defer { signposter.endInterval("request", interval) }
        do {
            guard let (head, rest) = try await Self.readHead(peer) else { return }
            // The token is the first path segment.
            let target = head.target
            guard target.hasPrefix("/") else { return try await respond(peer, 400, "malformed request target") }
            let afterSlash = target.dropFirst()
            let tokenEnd = afterSlash.firstIndex { $0 == "/" || $0 == "?" } ?? afterSlash.endIndex
            let token = String(afterSlash[..<tokenEnd])
            guard let scope = scopeFor(token: token) else {
                return try await respond(peer, 401, "BelloCode's Docker endpoint needs the workspace's token in DOCKER_HOST (set by BelloCode for every command). Do not set DOCKER_HOST yourself.")
            }
            let route = String(afterSlash[tokenEnd...])
            var request = DockerAPIRequest.parse(method: head.method, target: route.isEmpty ? "/" : route)
            var reader = try BodyReader(peer: peer, buffered: rest, head: head, limit: Self.maxJSONBody)
            // Routes whose bodies stream are known from the path alone; read the rest whole (bounded) before deciding.
            let streams = Self.streamsBody(request)
            if !streams { request.body = try await reader.readAll() }
            let decision = await policy.decide(request, scope: scope)
            switch decision {
            case .refuse(let status, let message):
                let refusal = Refusal(scope: scope.key, method: request.method, path: request.path, message: message, date: Date())
                refusals.withLock { list in
                    list.append(refusal)
                    if list.count > 50 { list.removeFirst(list.count - 50) }
                }
                onRefusal(refusal)
                log.info("refused \(request.method, privacy: .public) \(request.path, privacy: .public)")
                try await respond(peer, status, message)
            case .forward(let forwarded, let streamBody, let hijack, let after):
                guard streamBody == streams else { return try await respond(peer, 500, "internal routing mismatch") }
                try await forward(forwarded, head: head, reader: &reader, streamBody: streamBody, hijack: hijack, peer: peer,
                                  after: after.map { (scope.key, $0) })
            }
        } catch {
            try? await respond(peer, 400, "BelloCode could not read this Docker request (\(error)).")
        }
    }

    static func streamsBody(_ request: DockerAPIRequest) -> Bool {
        let segments = request.path.split(separator: "/")
        if request.method == "POST", segments == ["build"] { return true }
        if request.method == "PUT", segments.count == 3, segments[0] == "containers", segments[2] == "archive" { return true }
        return false
    }

    func scopeFor(token: String) -> DockerScope? {
        guard token.count > 10 else { return nil }
        return scopes.withLock { scopes in
            // Constant-time comparison against every token.
            var found: DockerScope?
            let probe = Array(token.utf8)
            for (candidate, scope) in scopes {
                let bytes = Array(candidate.utf8)
                var difference = UInt8(bytes.count == probe.count ? 0 : 1)
                for index in 0..<min(bytes.count, probe.count) { difference |= bytes[index] ^ probe[index] }
                if difference == 0 { found = scope }
            }
            return found
        }
    }

    /// Headers passed to the daemon (everything else, including hop-by-hop headers and framing, is dropped).
    static let forwardedHeaders: Set<String> = ["content-type", "x-registry-auth", "x-registry-config", "accept", "user-agent", "x-docker-expose-session-uuid", "x-docker-expose-session-name", "x-docker-expose-session-sharedkey", "x-docker-expose-session-grpc-method"]

    func forward(_ request: DockerAPIRequest, head: RequestHead, reader: inout BodyReader, streamBody: Bool, hijack: Bool,
                 peer: FileStream, after: (String, AfterAction)?) async throws {
        let daemon: FileStream
        do { daemon = try FileStream.connect(unixPath: daemonSocket) } catch {
            return try await respond(peer, 503, "Docker (Rancher Desktop) is not reachable from BelloCode right now.")
        }
        defer { daemon.cancel() }
        var text = "\(request.method) \(request.target) HTTP/1.1\r\nHost: docker\r\n"
        for (name, value) in head.headers where Self.forwardedHeaders.contains(name.lowercased()) || name.lowercased().hasPrefix("x-docker-expose-session") {
            guard !value.contains("\r"), !value.contains("\n") else { continue }
            text += "\(name): \(value)\r\n"
        }
        if hijack {
            let upgrade = (head.header("upgrade") ?? "tcp").lowercased()
            guard ["tcp", "h2c"].contains(upgrade) else { return try await respond(peer, 400, "unsupported upgrade “\(upgrade)”") }
            text += "Connection: Upgrade\r\nUpgrade: \(upgrade)\r\n"
        } else {
            text += "Connection: close\r\n"
        }
        if streamBody {
            text += "Transfer-Encoding: chunked\r\n\r\n"
            try await daemon.write(Data(text.utf8))
            // The daemon may answer (and close) before the whole context is sent, e.g. a refused Dockerfile: its
            // answer is still relayed below.
            do {
                while let piece = try await reader.next() {
                    if piece.isEmpty { continue }
                    try await daemon.write(Data(String(piece.count, radix: 16).utf8) + Data("\r\n".utf8) + piece + Data("\r\n".utf8))
                }
                try await daemon.write(Data("0\r\n\r\n".utf8))
            } catch let error as HTTPParseError {
                throw error
            } catch {}
        } else {
            let body = request.body ?? Data()
            if !body.isEmpty || ["POST", "PUT"].contains(request.method) { text += "Content-Length: \(body.count)\r\n" }
            text += "\r\n"
            try await daemon.write(Data(text.utf8) + body)
        }
        // The answer, as the daemon sends it. Its status decides whether bookkeeping happens.
        var first = true
        if hijack {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    while let data = try? await peer.read(), !data.isEmpty {
                        if (try? await daemon.write(data)) == nil { break }
                    }
                    daemon.shutdownWrite()
                }
                group.addTask {
                    while let data = try? await daemon.read(), !data.isEmpty {
                        if (try? await peer.write(data)) == nil { break }
                    }
                    peer.cancel()
                    daemon.cancel()
                }
            }
            return
        }
        while let data = try? await daemon.read(), !data.isEmpty {
            if first, let after, data.starts(with: Data("HTTP/1.1 200".utf8)) { recordAfter(after.0, after.1) }
            first = false
            try await peer.write(data)
        }
    }

    private func recordAfter(_ scope: String, _ action: AfterAction) {
        switch action {
        case .pulled(let reference):
            pulledStore.insert(reference, scope: scope)
        }
        onAfter(scope, action)
    }

    /// A Docker-style error answer (`{"message": …}`), then the connection closes.
    func respond(_ peer: FileStream, _ status: Int, _ message: String) async throws {
        let body = (try? JSONSerialization.data(withJSONObject: ["message": message])) ?? Data()
        let reason = [400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nApi-Version: 1.47\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        try await peer.write(Data(head.utf8) + body)
    }
}

/// Images each scope pulled (it may tag and delete them).
final class PulledImages: Sendable {
    private let state = Mutex<[String: Set<String>]>([:])
    func images(_ scope: String) -> Set<String> { state.withLock { $0[scope] ?? [] } }
    func insert(_ reference: String, scope: String) { _ = state.withLock { $0[scope, default: []].insert(reference) } }
}

/// Random bytes for tokens (Security framework, with `arc4random_buf` as the fallback it never needs).
enum SecRandomCopyBytesShim {
    static func fill(_ bytes: inout [UInt8]) -> Bool {
        arc4random_buf(&bytes, bytes.count)
        return true
    }
}

/// `DockerLookup` over the daemon socket.
public struct EngineDockerLookup: DockerLookup {
    public let client: EngineClient
    public init(client: EngineClient) { self.client = client }

    func object(_ path: String, name: (([String: Any]) -> String)?, labels: ([String: Any]) -> [String: String]?) async -> DockerObject? {
        guard let data = try? await client.call("GET", path, limit: 4 * 1024 * 1024),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let id = (json["Id"] as? String) ?? (json["ID"] as? String) ?? (json["Name"] as? String) ?? ""
        return DockerObject(id: id, name: name?(json) ?? "", labels: labels(json) ?? [:])
    }

    static func escape(_ reference: String) -> String {
        reference.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? reference
    }

    public func container(_ reference: String) async -> DockerObject? {
        await object("/containers/\(Self.escape(reference))/json", name: { (($0["Name"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) },
                     labels: { ($0["Config"] as? [String: Any])?["Labels"] as? [String: String] })
    }

    public func volume(_ name: String) async -> DockerObject? {
        await object("/volumes/\(Self.escape(name))", name: { ($0["Name"] as? String) ?? "" }, labels: { $0["Labels"] as? [String: String] })
    }

    public func network(_ reference: String) async -> DockerObject? {
        await object("/networks/\(Self.escape(reference))", name: { ($0["Name"] as? String) ?? "" }, labels: { $0["Labels"] as? [String: String] })
    }

    public func image(_ reference: String) async -> DockerObject? {
        await object("/images/\(Self.escape(reference))/json", name: { _ in reference },
                     labels: { ($0["Config"] as? [String: Any])?["Labels"] as? [String: String] })
    }

    public func execContainer(_ id: String) async -> String? {
        guard let data = try? await client.call("GET", "/exec/\(Self.escape(id))/json"),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["ContainerID"] as? String
    }

    public func containerCount(scope: String) async -> Int {
        (try? await client.listContainers(labels: ["\(DockerAgentLabels.scope)=\(scope)"]).count) ?? 0
    }

    public func createVolume(name: String, labels: [String: String]) async throws {
        try await client.createVolume(name: name, labels: labels)
    }
}
