import Foundation
import Network
import Synchronization

/// The WebKit preview's proxy on the Mac (docs/features/shared-browser.md "Canonical URLs on the Mac"): an HTTP proxy on
/// 127.0.0.1 that a project's `WKWebsiteDataStore` uses for `*.bc` names only, so the built-in preview opens the same
/// `https://<project>.bc:<port>/` URLs as the shared Chrome. It requires per-launch Basic proxy credentials, accepts only
/// requests for `*.bc` hosts, and hands each connection to BelloCode's egress proxy under the routes-only `preview`
/// scope (no internet, no secret substitution). Connections are bounded.
public final class PreviewProxyFront: Sendable {
    public let upstreamPort: UInt16
    let token: String
    public let username: String
    public let password: String
    public let maxConnections: Int
    private let state = Mutex<(listener: NWListener?, active: Int)>((nil, 0))
    private let queue = DispatchQueue(label: "bellocode.preview-proxy")

    public init(upstreamPort: UInt16, token: String, maxConnections: Int = 64) {
        self.upstreamPort = upstreamPort
        self.token = token
        username = "bellocode"
        password = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        self.maxConnections = maxConnections
    }

    /// Binds 127.0.0.1 on a free port and returns it.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        state.withLock { $0.listener = listener }
        return port
    }

    public func stop() {
        state.withLock { $0.listener?.cancel(); $0.listener = nil }
    }

    private func accept(_ connection: NWConnection) {
        let admitted = state.withLock { state -> Bool in
            guard state.active < maxConnections else { return false }
            state.active += 1
            return true
        }
        guard admitted else { return connection.cancel() }
        let client = WireConnection(connection, queue: queue)
        Task {
            await self.serve(client)
            client.cancel()
            self.state.withLock { $0.active -= 1 }
        }
    }

    /// The authority a request asks for (CONNECT target, or an absolute-form URL's host:port).
    static func authority(of head: HTTPHead) -> HostPort? {
        guard head.startLine.count >= 2 else { return nil }
        if head.startLine[0] == "CONNECT" { return HostPort(authority: head.startLine[1]) }
        guard let url = URL(string: head.startLine[1]), let host = url.host else { return nil }
        return HostPort(host: host, port: url.port ?? (url.scheme == "https" ? 443 : 80))
    }

    static func isRouted(_ host: String) -> Bool { host == "bc" || host.hasSuffix(".bc") }

    func authorized(_ head: HTTPHead) -> Bool {
        guard let value = head.fields.first("Proxy-Authorization"), value.lowercased().hasPrefix("basic "),
              let decoded = Data(base64Encoded: String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)) else { return false }
        return String(decoding: decoded, as: UTF8.self) == "\(username):\(password)"
    }

    private func serve(_ client: WireConnection) async {
        do {
            try await client.start()
            guard let data = try await client.readHead(limit: 16 * 1024), let head = HTTPHead(data) else { return }
            guard authorized(head) else {
                try await client.send(Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"BelloCode preview\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                return
            }
            guard let authority = Self.authority(of: head), Self.isRouted(authority.host) else {
                try await client.send(Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                return
            }
            // Forward without our credentials; the egress proxy authenticates the preview scope by its token.
            let forwarded = HTTPHead(startLine: head.startLine, fields: head.fields.filter { $0.name.lowercased() != "proxy-authorization" })
            let upstream = WireConnection(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: upstreamPort)!, using: .tcp), queue: queue)
            try await upstream.start()
            defer { upstream.cancel() }
            try await upstream.send(Data("BCEGRESS \(token)\n".utf8) + forwarded.serialized + (await client.takeBuffer()))
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    while let chunk = try? await client.readSome(), !chunk.isEmpty {
                        if (try? await upstream.send(chunk)) == nil { break }
                    }
                    await upstream.sendEnd()
                }
                group.addTask {
                    while let chunk = try? await upstream.readSome(), !chunk.isEmpty {
                        if (try? await client.send(chunk)) == nil { break }
                    }
                    await client.sendEnd()
                }
                await group.next()
                await group.next()
            }
        } catch {
            return
        }
    }
}
