import BelloCore
import Foundation
import Network
import Security
import Synchronization
import os

/// A host and port.
public struct HostPort: Codable, Sendable, Hashable, CustomStringConvertible {
    public var host: String
    public var port: Int
    public init(host: String, port: Int) {
        self.host = SecretBinding.canonicalHost(host)
        self.port = port
    }
    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    /// `host:port`, `[v6]:port`.
    public init?(authority: String) {
        let text = authority.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65_535).contains(port) else { return nil }
            self.init(host: host, port: port)
            return
        }
        let parts = text.split(separator: ":")
        guard parts.count == 2, !parts[0].isEmpty, let port = Int(parts[1]), (1...65_535).contains(port) else { return nil }
        self.init(host: String(parts[0]), port: port)
    }
}

/// One gateway's view: which projects its workspace container serves and which raw (uninspected) destinations its
/// project allows. Identified by a per-launch token the gateway sends first on every connection.
public struct EgressScope: Sendable {
    public var id: String
    public var token: String
    public var admitsProject: @Sendable (String) -> Bool
    /// `host:port` pairs reached by a raw CONNECT tunnel, without inspection or substitution ("no secret protection").
    public var rawAllowlist: Set<HostPort>

    public init(id: String, token: String, rawAllowlist: Set<HostPort> = [], admitsProject: @escaping @Sendable (String) -> Bool) {
        self.id = id
        self.token = token
        self.rawAllowlist = rawAllowlist
        self.admitsProject = admitsProject
    }
}

/// What the proxy knows of placeholder secrets: grants by placeholder, secrets by account, values (memory only).
public struct EgressSnapshot: Sendable {
    public var grants: [String: PlaceholderGrant]
    public var secrets: [String: ManagedSecret]
    public var values: [String: SecretValue]
    /// The developer's code roots (a `.codeRoots` scope admits projects inside them).
    public var codeRoots: [String]

    public init(grants: [String: PlaceholderGrant] = [:], secrets: [String: ManagedSecret] = [:], values: [String: SecretValue] = [:],
                codeRoots: [String] = []) {
        self.grants = grants
        self.secrets = secrets
        self.values = values
        self.codeRoots = codeRoots
    }

    func resolve(_ placeholder: String) -> ResolvedPlaceholder? {
        guard let grant = grants[placeholder], let secret = secrets[grant.account], let value = values[grant.account] else { return nil }
        var resolved = ResolvedPlaceholder(grant: grant, secret: secret, value: value)
        // The secret's current scope must admit the grant's project at every substitution (R13).
        resolved.scopeAdmits = secret.scope.admits(projectDirectory: grant.projectDirectory, codeRoots: codeRoots)
        return resolved
    }

    /// Hidden secrets with a binding at this origin: their values are looked for in its responses.
    func secretsBound(to scheme: String, host: String, port: Int) -> [ManagedSecret] {
        secrets.values.filter { secret in
            secret.mode != .visible && secret.bindings.contains { $0.matchesOrigin(scheme: scheme, host: host, port: port) }
        }
    }

    /// The thread's placeholder for `account`, for replacing the value in a response.
    func placeholder(account: String, session: String?) -> String? {
        grants.values.first { $0.account == account && $0.sessionID == session }?.placeholder
    }
}

/// What happened (for the audit). Never carries a value; destinations are origin + path, no query.
public enum EgressEvent: Sendable {
    case substituted(SubstitutionUse, destination: String, method: String, status: Int?)
    case refused(SecretRefusal, account: String?, sessionID: String?, destination: String, method: String)
    case responseRedacted(accounts: [String], destination: String, method: String, sessionID: String?)
    case responseBlocked(accounts: [String], destination: String, method: String, reason: String, sessionID: String?)
    case rawTunnel(scope: String, destination: HostPort)
    case connectionRefused(reason: String)
    /// Events dropped because the consumer fell behind (the audit shows that it is incomplete).
    case dropped(Int)
}

public struct EgressProxyConfiguration: Sendable {
    /// An explicit upstream proxy (the company's, when not transparent): destinations are reached through CONNECT.
    public var upstreamProxy: HostPort?
    /// Extra trusted roots (DER) for upstream TLS, on top of the Mac's trust settings (the enterprise roots).
    public var extraAnchors: [Data]
    /// Tests: names resolved to these addresses (loopback test servers allowed).
    public var resolverOverrides: [String: HostPort]
    public var requestBodyLimit: Int
    public var responseBodyLimit: Int
    /// The longest a response from a destination that receives secrets may take to arrive whole (streaming beyond it
    /// is refused, because it cannot be inspected).
    public var inspectedResponseTime: Duration
    public var idleTimeout: Duration
    /// The routing step (internet, a container through a gateway's dial endpoint, or refuse). Default: internet.
    public var router: any EgressRouter

    public init(upstreamProxy: HostPort? = nil, extraAnchors: [Data] = [], resolverOverrides: [String: HostPort] = [:],
                requestBodyLimit: Int = 32 << 20, responseBodyLimit: Int = ResponseFilter.defaultBodyLimit,
                inspectedResponseTime: Duration = .seconds(60), idleTimeout: Duration = .seconds(120),
                router: any EgressRouter = InternetRouter()) {
        self.upstreamProxy = upstreamProxy
        self.extraAnchors = extraAnchors
        self.resolverOverrides = resolverOverrides
        self.requestBodyLimit = requestBodyLimit
        self.responseBodyLimit = responseBodyLimit
        self.inspectedResponseTime = inspectedResponseTime
        self.idleTimeout = idleTimeout
        self.router = router
    }
}

/// BelloCode's TLS-terminating egress proxy for workspace containers (docs/features/secrets.md "Egress").
///
/// Containers reach it only through their gateway (`EgressGateway`): the workspace sits on an internal Docker network
/// with no route out; the gateway relays each connection to this listener on the Mac's loopback, prefixed with its
/// scope token. Every HTTPS connection is a CONNECT that the proxy answers itself and then terminates TLS for (with a
/// leaf from `CertificateAuthority`, which containers trust); the decrypted requests go through `RequestRewriter`;
/// responses from destinations that may have received a secret are read whole, decoded and scanned
/// (`ResponseFilter`); others stream through. HTTP/2 is not offered (ALPN `http/1.1` only), upgrades to secret
/// destinations are refused, and redirects are passed to the client, whose follow-up request is judged on its own.
public final class EgressProxy: Sendable {
    private struct TunnelContext: Sendable {
        var scope: EgressScope
        var destination: HostPort
    }

    private struct State: Sendable {
        var frontListener: NWListener?
        var port: UInt16?
        var tlsListeners: [String: (listener: NWListener, port: UInt16)] = [:]
        var pendingTunnels: [UInt16: TunnelContext] = [:]
        var scopes: [String: EgressScope] = [:]
        var snapshot = EgressSnapshot()
        var tasks: [UUID: Task<Void, Never>] = [:]
        var connections: [UUID: NWConnection] = [:]
        var dropped = 0
        var stopped = false
        var dockerEndpointPort: UInt16?
        var useRecorder: (@Sendable ([SubstitutionUse]) async -> Bool)?
    }

    public let authority: CertificateAuthority
    public let configuration: EgressProxyConfiguration
    /// Per-binding use counts, shared with the brokered tool (R12).
    public let ledger: SecretUseLedger
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "app.bellocode.egress-proxy", qos: .userInitiated, attributes: .concurrent)
    private let eventContinuation: AsyncStream<EgressEvent>.Continuation
    /// The audit feed (newest 1024 kept if the consumer falls behind; the gap is reported as `.dropped`).
    public let events: AsyncStream<EgressEvent>
    private let log = Logger(subsystem: "app.bellocode", category: "egress-proxy")
    private let signposts = OSSignposter(subsystem: "app.bellocode", category: "egress-proxy")
    static let maxTLSListeners = 64

    public init(authority: CertificateAuthority, configuration: EgressProxyConfiguration = .init(), ledger: SecretUseLedger = SecretUseLedger()) {
        self.authority = authority
        self.configuration = configuration
        self.ledger = ledger
        (events, eventContinuation) = AsyncStream.makeStream(of: EgressEvent.self, bufferingPolicy: .bufferingNewest(1_024))
    }

    deinit { eventContinuation.finish() }

    // MARK: Lifecycle

    /// Starts listening on the Mac's loopback; returns the port (gateways connect to `host.docker.internal:port`).
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        if let existing = state.withLock({ $0.port }) { return existing }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let bound = try await Self.ready(listener, queue: queue) { [weak self] connection in self?.acceptFront(connection) }
        state.withLock {
            $0.frontListener = listener
            $0.port = bound
            $0.stopped = false
        }
        log.info("egress proxy listening")
        return bound
    }

    public var port: UInt16? { state.withLock { $0.port } }

    public func stop() {
        let (listeners, tasks, connections) = state.withLock { state -> ([NWListener], [Task<Void, Never>], [NWConnection]) in
            state.stopped = true
            let listeners = [state.frontListener].compactMap { $0 } + state.tlsListeners.values.map(\.listener)
            state.frontListener = nil
            state.port = nil
            state.tlsListeners = [:]
            state.pendingTunnels = [:]
            defer { state.tasks = [:]; state.connections = [:] }
            return (listeners, Array(state.tasks.values), Array(state.connections.values))
        }
        listeners.forEach { $0.cancel() }
        tasks.forEach { $0.cancel() }
        connections.forEach { $0.cancel() }
    }

    public func setScopes(_ scopes: [EgressScope]) {
        state.withLock { $0.scopes = Dictionary(scopes.map { ($0.token, $0) }, uniquingKeysWith: { _, new in new }) }
    }

    public func update(_ snapshot: EgressSnapshot) { state.withLock { $0.snapshot = snapshot } }

    /// Persists reserved uses of limited bindings before the request is dispatched (R12); false refuses the request.
    public func setUseRecorder(_ recorder: (@Sendable ([SubstitutionUse]) async -> Bool)?) { state.withLock { $0.useRecorder = recorder } }

    /// BelloCode's filtered Docker endpoint on the Mac's loopback (execution modes). Gateways relay workspace `docker`
    /// connections here (preamble `BCEGRESS <token> docker`), byte for byte: that endpoint authenticates and filters
    /// every request itself. Nil: such connections are closed.
    public func setDockerEndpointPort(_ port: UInt16?) { state.withLock { $0.dockerEndpointPort = port } }

    /// Live connections (tests check nothing is left).
    public var openConnectionCount: Int { state.withLock { $0.connections.count } }

    private static func ready(_ listener: NWListener, queue: DispatchQueue, accept: @escaping @Sendable (NWConnection) -> Void) async throws -> UInt16 {
        let once = Mutex(false)
        listener.newConnectionHandler = accept
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, any Error>?
                switch state {
                case .ready: result = listener.port.map { .success($0.rawValue) } ?? .failure(WireError("no port"))
                case .failed(let error): result = .failure(error)
                case .cancelled: result = .failure(WireError.closed)
                default: result = nil
                }
                guard let result, once.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: queue)
        }
    }

    private func emit(_ event: EgressEvent) {
        let dropped = state.withLock { state -> Int in defer { state.dropped = 0 }; return state.dropped }
        if dropped > 0 { _ = eventContinuation.yield(.dropped(dropped)) }
        if case .dropped = eventContinuation.yield(event) { state.withLock { $0.dropped += 1 } }
    }

    /// Runs `body` as a task the proxy owns (cancelled by `stop`), with its connection registered.
    private func own(_ connection: NWConnection, _ body: @escaping @Sendable () async -> Void) {
        let id = UUID()
        let accepted = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.connections[id] = connection
            return true
        }
        guard accepted else { connection.cancel(); return }
        let task = Task { [weak self] in
            await body()
            connection.cancel()
            self?.state.withLock { state in
                state.tasks[id] = nil
                state.connections[id] = nil
            }
        }
        state.withLock { state in
            if state.connections[id] != nil { state.tasks[id] = task }
        }
    }

    /// Closes the connection if nothing moves for `idleTimeout` (checked every few seconds on `ContinuousClock`).
    private func watchdog(_ wires: [WireConnection]) -> Task<Void, Never> {
        let limit = configuration.idleTimeout
        return Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                var newest = ContinuousClock.Instant.now - limit - .seconds(1)
                for wire in wires { newest = max(newest, await wire.lastActivity) }
                if ContinuousClock.now - newest > limit {
                    wires.forEach { $0.cancel() }
                    return
                }
            }
        }
    }

    // MARK: Front: gateway connections

    private func acceptFront(_ connection: NWConnection) {
        own(connection) { [weak self] in
            guard let self else { return }
            let wire = WireConnection(connection, queue: self.queue)
            let watchdog = self.watchdog([wire])
            defer { watchdog.cancel() }
            do {
                try await wire.start()
                try await self.serveFront(wire)
            } catch {
                self.log.debug("front connection ended: \(Self.describe(error), privacy: .public)")
                // Closed or refused; nothing to tell the client beyond the closed connection.
            }
        }
    }

    private func serveFront(_ wire: WireConnection) async throws {
        let preamble = try await wire.readLine(limit: 256)
        let parts = preamble.split(separator: " ")
        guard (2...3).contains(parts.count), parts[0] == "BCEGRESS", let scope = state.withLock({ $0.scopes[String(parts[1])] }) else {
            emit(.connectionRefused(reason: "a connection without a valid gateway token"))
            return
        }
        if parts.count == 3 {
            guard parts[2] == "docker", let port = state.withLock({ $0.dockerEndpointPort }) else { return }
            let upstream = WireConnection(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp), queue: queue)
            try await upstream.start()
            let early = await wire.takeBuffer()
            if !early.isEmpty { try await upstream.send(early) }
            _ = scope
            await splice(wire, upstream)
            return
        }
        guard let headData = try await wire.readHead() else { return }
        guard let head = HTTPHead(headData), head.version.hasPrefix("HTTP/1.") else {
            try await wire.send(Self.plainResponse(400, "Bad Request", "BelloCode's proxy speaks HTTP/1.1 only."))
            return
        }
        let method = head.startLine[0].uppercased()
        if method == "CONNECT" {
            guard let destination = HostPort(authority: head.startLine[1]) else {
                try await wire.send(Self.plainResponse(400, "Bad Request", "CONNECT needs host:port."))
                return
            }
            do {
                if scope.rawAllowlist.contains(destination) {
                    try await rawTunnel(wire, to: destination, scope: scope)
                } else {
                    try await interceptTunnel(wire, to: destination, scope: scope)
                }
            } catch let error as TunnelOpened {
                throw error.underlying
            } catch {
                // Never close a CONNECT without an answer: the client would see an opaque proxy failure.
                try await wire.send(Self.plainResponse(502, "Bad Gateway", "BelloCode's proxy could not open the tunnel (\(Self.describe(error)))."))
            }
            return
        }
        // Plain http: absolute-form requests, one connection per destination.
        try await serveRequests(client: wire, first: (head, headData), context: nil, scope: scope)
    }

    /// An allowlisted non-HTTP destination: bytes pass both ways uninspected (no secret is ever substituted here).
    private func rawTunnel(_ client: WireConnection, to destination: HostPort, scope: EgressScope) async throws {
        let upstream = WireConnection(NWConnection(to: endpoint(destination), using: .tcp), queue: queue)
        do { try await upstream.start() } catch {
            try await client.send(Self.plainResponse(502, "Bad Gateway", "BelloCode could not reach \(destination)."))
            return
        }
        emit(.rawTunnel(scope: scope.id, destination: destination))
        do {
            try await client.send(Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8))
        } catch {
            throw TunnelOpened(underlying: error)
        }
        let early = await client.takeBuffer()
        if !early.isEmpty { try? await upstream.send(early) }
        await splice(client, upstream)
    }

    /// Answers the CONNECT itself and terminates TLS through a per-host loopback listener, so the decrypted requests can
    /// be inspected. The client's TLS bytes are spliced into that listener; the listener's connection is matched back
    /// to this tunnel by its source port.
    private func interceptTunnel(_ client: WireConnection, to destination: HostPort, scope: EgressScope) async throws {
        let tlsPort = try await tlsListenerPort(for: destination.host)
        // A listener that has just become ready can refuse the first connection for a moment: retry briefly.
        var connected: WireConnection?
        for attempt in 0..<5 where connected == nil {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(20 * attempt)) }
            let candidate = WireConnection(NWConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: tlsPort)!), using: .tcp), queue: queue)
            do {
                try await candidate.start()
                connected = candidate
            } catch {
                candidate.cancel()
            }
        }
        guard let inner = connected else {
            try await client.send(Self.plainResponse(502, "Bad Gateway", "BelloCode's proxy could not open its inspection endpoint."))
            return
        }
        // Every way out (an error, cancellation, the client gone) closes the inspection connection (N19).
        defer { inner.cancel() }
        // The path (and so the local port) can lag `.ready` by a moment.
        var port: NWEndpoint.Port?
        for _ in 0..<50 {
            if case .hostPort(_, let value)? = inner.connection.currentPath?.localEndpoint { port = value; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let localPort = port else {
            try await client.send(Self.plainResponse(502, "Bad Gateway", "BelloCode's proxy could not open its inspection endpoint."))
            return
        }
        state.withLock { $0.pendingTunnels[localPort.rawValue] = TunnelContext(scope: scope, destination: destination) }
        defer { _ = state.withLock { $0.pendingTunnels.removeValue(forKey: localPort.rawValue) } }
        do {
            if faults.withLock({ $0.failTunnelEstablished }) { throw WireError.closed }
            try await client.send(Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8))
            let early = await client.takeBuffer()
            if !early.isEmpty { try await inner.send(early) }
        } catch {
            throw TunnelOpened(underlying: error)
        }
        await splice(client, inner)
    }

    /// Tests: faults injected at points a real network reaches only by timing.
    struct Faults: Sendable {
        /// The client is gone just as the tunnel's `200` is sent.
        var failTunnelEstablished = false
    }

    let faults = Mutex(Faults())

    /// Tunnels waiting for (or using) their inspection connection (tests: none may be left behind).
    var pendingTunnelCount: Int { state.withLock { $0.pendingTunnels.count } }

    /// Relays both directions until each has ended. A half-close is passed on (`docker run` closes its side of an
    /// attach stream right away and then reads the container's output), so one direction ending never cuts the other;
    /// the idle watchdog bounds a peer that never closes.
    private func splice(_ a: WireConnection, _ b: WireConnection) async {
        let watchdog = self.watchdog([a, b])
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.pump(from: a, to: b) }
            group.addTask { await Self.pump(from: b, to: a) }
            await group.waitForAll()
        }
        watchdog.cancel()
        a.cancel()
        b.cancel()
    }

    private static func pump(from source: WireConnection, to sink: WireConnection) async {
        do {
            while let data = try await source.readSome() { try await sink.send(data) }
            await sink.sendEnd()
        } catch {}
    }

    // MARK: TLS termination

    private func tlsListenerPort(for host: String) async throws -> UInt16 {
        if let existing = state.withLock({ $0.tlsListeners[host]?.port }) { return existing }
        let identity = try authority.identity(for: host)
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else { throw WireError("no identity") }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let port = try await Self.ready(listener, queue: queue) { [weak self] connection in self?.acceptTLS(connection, host: host) }
        let evicted = state.withLock { state -> NWListener? in
            if let raced = state.tlsListeners[host] {
                listener.cancel()
                _ = raced
                return nil
            }
            var evicted: NWListener?
            if state.tlsListeners.count >= Self.maxTLSListeners, let victim = state.tlsListeners.keys.first {
                evicted = state.tlsListeners.removeValue(forKey: victim)?.listener
            }
            state.tlsListeners[host] = (listener, port)
            return evicted
        }
        evicted?.cancel()
        return state.withLock { $0.tlsListeners[host]?.port } ?? port
    }

    private func acceptTLS(_ connection: NWConnection, host: String) {
        own(connection) { [weak self] in
            guard let self else { return }
            let wire = WireConnection(connection, queue: self.queue)
            let watchdog = self.watchdog([wire])
            defer { watchdog.cancel() }
            do {
                try await wire.start()
                guard case .hostPort(_, let remotePort) = connection.endpoint,
                      let context = self.state.withLock({ $0.pendingTunnels[remotePort.rawValue] }), context.destination.host == host
                else { return }
                // SNI, when sent, must name the CONNECT host.
                if let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                   let sni = sec_protocol_metadata_get_server_name(metadata.securityProtocolMetadata).map({ String(cString: $0) }),
                   SecretBinding.canonicalHost(sni) != host {
                    self.emit(.connectionRefused(reason: "TLS server name does not match the CONNECT host"))
                    return
                }
                try await self.serveRequests(client: wire, first: nil, context: context, scope: context.scope)
            } catch {}
        }
    }

    // MARK: Requests

    private struct Upstream {
        var key: String
        var wire: WireConnection
    }

    /// Serves requests on one client connection (inside a TLS tunnel, or plain absolute-form), keeping upstream
    /// connections alive while the destination stays the same.
    private func serveRequests(client: WireConnection, first: (HTTPHead, Data)?, context: TunnelContext?, scope: EgressScope) async throws {
        var upstream: Upstream?
        var pending = first
        defer { upstream?.wire.cancel() }
        while true {
            let head: HTTPHead
            if let current = pending {
                head = current.0
                pending = nil
            } else {
                guard let data = try await client.readHead() else { return }
                guard let parsed = HTTPHead(data) else {
                    try await client.send(Self.plainResponse(400, "Bad Request", "Malformed request."))
                    return
                }
                head = parsed
            }
            guard head.version == "HTTP/1.1" || head.version == "HTTP/1.0" else {
                try await client.send(Self.plainResponse(505, "HTTP Version Not Supported", "BelloCode's proxy speaks HTTP/1.1 only."))
                return
            }
            let keepGoing = try await handle(head, client: client, context: context, scope: scope, upstream: &upstream)
            if !keepGoing { return }
        }
    }

    /// One request. Returns whether the client connection may carry another.
    private func handle(_ head: HTTPHead, client: WireConnection, context: TunnelContext?, scope: EgressScope, upstream: inout Upstream?) async throws -> Bool {
        let method = head.startLine[0].uppercased()
        let target = head.startLine[1]
        // Destination: the tunnel's host (Host must agree) or the absolute-form URI (plain http).
        let scheme: String
        let destination: HostPort
        var originTarget = target
        if let context {
            scheme = "https"
            destination = context.destination
            if let host = head.fields.first("Host"), Self.hostOnly(host) != destination.host {
                try await client.send(Self.plainResponse(421, "Misdirected Request", "The Host header does not match the tunnel's destination."))
                return false
            }
            guard target.hasPrefix("/") else {
                try await client.send(Self.plainResponse(400, "Bad Request", "Use origin-form request targets inside a tunnel."))
                return false
            }
        } else {
            guard let url = URLComponents(string: target), url.scheme?.lowercased() == "http", let host = url.host, !host.isEmpty else {
                try await client.send(Self.plainResponse(400, "Bad Request", "Send absolute http:// URLs, or CONNECT for https."))
                return false
            }
            scheme = "http"
            destination = HostPort(host: host, port: url.port ?? 80)
            originTarget = (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath) + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        }
        guard let framing = head.requestFraming() else {
            try await client.send(Self.plainResponse(400, "Bad Request", "Conflicting or invalid body framing."))
            return false
        }
        if head.fields.first("Expect")?.lowercased() == "100-continue" { try await client.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
        let body: Data
        do {
            body = try await client.readBody(framing, limit: configuration.requestBodyLimit)
        } catch let error as WireError where error == .tooLarge {
            emit(.refused(.tooLarge, account: nil, sessionID: nil, destination: "\(scheme)://\(destination)", method: method))
            try await client.send(Self.refusal(.tooLarge, status: 413))
            return false
        }
        var fields = head.fields
        for hop in ["Proxy-Connection", "Proxy-Authorization", "Keep-Alive", "TE", "Trailer", "Transfer-Encoding", "Expect", "Content-Length"] {
            fields.remove(hop)
        }
        let connectionTokens = (fields.first("Connection") ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for token in connectionTokens where !["close", "keep-alive", "upgrade"].contains(token) { fields.remove(token) }
        let wantsUpgrade = fields.first("Upgrade") != nil
        let clientCloses = connectionTokens.contains("close") || head.version == "HTTP/1.0"
        fields.remove("Connection")
        fields.set("Host", Self.hostHeader(destination, scheme: scheme))
        if !body.isEmpty || ["POST", "PUT", "PATCH"].contains(method) { fields.append(HTTPField("Content-Length", String(body.count))) }
        var request = OutboundRequest(method: method, scheme: scheme, host: destination.host, port: destination.port,
                                      target: originTarget, headers: fields, body: body)
        let original = request
        let snapshot = state.withLock { $0.snapshot }
        let bound = snapshot.secretsBound(to: scheme, host: destination.host, port: destination.port)
        let ledger = self.ledger
        let decision = RequestRewriter(admitsProject: scope.admitsProject, useCount: { ledger.count(account: $0, bindingID: $1) })
            .rewrite(request) { snapshot.resolve($0) }
        var uses: [SubstitutionUse] = []
        switch decision {
        case .refused(let reason, let account, let session):
            emit(.refused(reason, account: account, sessionID: session, destination: request.auditDestination, method: method))
            try await client.send(Self.refusal(reason, status: 403))
            return !clientCloses
        case .unchanged: break
        case .substituted(let rewritten, let made):
            // Reserve uses atomically against the limits in the ledger the brokered tool shares (another connection, or
            // a brokered call, may have used the last one); limited bindings are recorded durably before dispatch.
            let limit = { (use: SubstitutionUse) -> Int? in snapshot.secrets[use.account]?.bindings.first { $0.id == use.bindingID }?.maxUses }
            var allowed = made.allSatisfy { snapshot.secrets[$0.account] != nil } && ledger.reserve(made, limit: limit)
            if allowed, made.contains(where: { limit($0) != nil }) {
                if let recorder = state.withLock({ $0.useRecorder }) { allowed = await recorder(made) }
            }
            guard allowed else {
                let label = snapshot.secrets[made.first?.account ?? ""]?.label ?? "the secret"
                emit(.refused(.useLimit(label: label), account: made.first?.account, sessionID: made.first?.sessionID, destination: request.auditDestination, method: method))
                try await client.send(Self.refusal(.useLimit(label: label), status: 403))
                return !clientCloses
            }
            request = rewritten
            uses = made
        }
        let session = uses.first?.sessionID ?? Self.sessionOfPlaceholders(in: head, body: body, snapshot: snapshot)
        if wantsUpgrade, !bound.isEmpty || !uses.isEmpty {
            emit(.refused(.upgrade, account: bound.first?.account, sessionID: session, destination: request.auditDestination, method: method))
            try await client.send(Self.refusal(.upgrade, status: 403))
            return false
        }
        if wantsUpgrade { request.headers.append(HTTPField("Connection", "Upgrade")) }

        // Upstream (reused while the destination is the same and the connection is open).
        let key = "\(scheme)://\(destination)"
        if upstream?.key != key {
            upstream?.wire.cancel()
            upstream = nil
        }
        var response: (HTTPHead, WireConnection)?
        for attempt in 0..<2 {
            if upstream == nil {
                do {
                    upstream = Upstream(key: key, wire: try await connectUpstream(scheme: scheme, destination: destination, scope: scope.id))
                } catch let error as DestinationRefused {
                    try await client.send(Self.plainResponse(403, "Forbidden", error.message))
                    return false
                } catch {
                    try await client.send(Self.plainResponse(502, "Bad Gateway", "BelloCode could not reach \(destination) (\(Self.describe(error)))."))
                    return false
                }
            }
            guard let wire = upstream?.wire else { break }
            // AF15: the substitution was decided before the use was recorded and the connection opened, both of which can
            // take a while. Re-authorized against the snapshot as it is now, at the handoff to the send: a revocation,
            // narrower scope or binding change published meanwhile refuses the request (nothing was sent), and a rotation
            // sends the current value.
            if !uses.isEmpty {
                switch reauthorize(original, uses: uses, scope: scope) {
                case .success(let current):
                    request = current
                case .failure(let refusal):
                    ledger.release(uses)
                    emit(.refused(refusal.reason, account: refusal.account ?? uses.first?.account, sessionID: refusal.session ?? uses.first?.sessionID,
                                  destination: request.auditDestination, method: method))
                    try await client.send(Self.refusal(refusal.reason, status: 403))
                    return !clientCloses
                }
            }
            do {
                try await wire.send(HTTPHead(startLine: [method, request.target, "HTTP/1.1"], fields: request.headers).serialized + request.body)
                guard let data = try await wire.readHead(limit: 128 * 1024), let parsed = HTTPHead(data) else { throw WireError.closed }
                response = (parsed, wire)
                break
            } catch {
                // A kept-alive upstream may have closed; retry once on a fresh connection for idempotent methods.
                wire.cancel()
                upstream = nil
                if attempt == 1 || !["GET", "HEAD", "OPTIONS"].contains(method) || !uses.isEmpty { break }
            }
        }
        guard let (firstHead, wire) = response else {
            try await client.send(Self.plainResponse(502, "Bad Gateway", "\(destination) closed the connection."))
            return false
        }
        // Interim responses (100 Continue, 103 Early Hints) are not passed on: the proxy answered Expect itself, and an
        // interim head is metadata the inspection below would otherwise have to cover separately. Bounded.
        var responseHead = firstHead
        var interim = 0
        while let code = Self.statusCode(responseHead), (100..<200).contains(code), code != 101 {
            interim += 1
            guard interim <= 8, let data = try? await wire.readHead(limit: 128 * 1024), let parsed = HTTPHead(data) else {
                wire.cancel()
                upstream = nil
                try await client.send(Self.plainResponse(502, "Bad Gateway", "BelloCode: the destination sent an invalid interim response."))
                return false
            }
            responseHead = parsed
        }
        // The status line the client sees is built here: the code is checked, the reason phrase is BelloCode's own (a
        // destination could reflect a submitted value into it).
        guard let status = Self.statusCode(responseHead), responseHead.version.hasPrefix("HTTP/1.") else {
            wire.cancel()
            upstream = nil
            try await client.send(Self.plainResponse(502, "Bad Gateway", "BelloCode: the destination's status line is invalid."))
            return false
        }
        let statusLine = ["HTTP/1.1", String(status), Self.reasonPhrase(status)]
        for use in uses { emit(.substituted(use, destination: request.auditDestination, method: method, status: status)) }
        guard let responseFraming = responseHead.responseFraming(requestMethod: method) else {
            try await client.send(Self.plainResponse(502, "Bad Gateway", "The destination's response framing is invalid."))
            return false
        }
        let upstreamCloses = (responseHead.fields.first("Connection") ?? "").lowercased().contains("close") || responseHead.version == "HTTP/1.0"

        if status == 101 {
            // Only an upgrade the client asked for, to a destination that never receives secrets, becomes a raw tunnel.
            // An unsolicited 101 (or one from a secret-bound destination) would leave the inspected path entirely.
            guard wantsUpgrade, bound.isEmpty, uses.isEmpty else {
                wire.cancel()
                upstream = nil
                emit(.responseBlocked(accounts: bound.map(\.account), destination: request.auditDestination, method: method,
                                      reason: "The destination switched protocols without a negotiated upgrade.", sessionID: session))
                try await client.send(Self.plainResponse(502, "Bad Gateway", "BelloCode: the destination switched protocols without a negotiated upgrade."))
                return false
            }
            try await client.send(HTTPHead(startLine: statusLine, fields: responseHead.fields).serialized)
            await splice(client, wire)
            upstream = nil
            return false
        }

        if bound.isEmpty && uses.isEmpty {
            // Fast path: no secret could be in this response. Head and body pass through as framed.
            var fields = responseHead.fields
            fields.remove("Connection")
            fields.remove("Keep-Alive")
            if responseFraming == .untilClose && !(100..<200).contains(status) {
                fields.append(HTTPField("Connection", "close"))
            }
            try await client.send(HTTPHead(startLine: statusLine, fields: fields).serialized)
            try await wire.relayBody(responseFraming, to: client)
            if upstreamCloses || responseFraming == .untilClose { wire.cancel(); upstream = nil }
            return !clientCloses && responseFraming != .untilClose
        }

        // Inspected path: read the whole response (bounded in size and time), decode, scan, then pass or block.
        let limit = configuration.responseBodyLimit
        let bodyResult: Result<Data, any Error> = await Self.withTimeLimit(configuration.inspectedResponseTime, onTimeout: { wire.cancel() }) {
            try await wire.readBody(responseFraming, limit: limit)
        }
        if upstreamCloses || responseFraming == .untilClose { wire.cancel(); upstream = nil }
        let rawBody: Data
        switch bodyResult {
        case .success(let data): rawBody = data
        case .failure(let error):
            wire.cancel()
            upstream = nil
            let reason = error is TimeLimitExceeded
                ? "The response did not finish within \(configuration.inspectedResponseTime) (streaming responses from a destination that receives secrets cannot be inspected)."
                : (error as? WireError) == WireError.tooLarge ? "The response was too large to inspect." : "The response could not be read."
            emit(.responseBlocked(accounts: bound.map(\.account), destination: request.auditDestination, method: method, reason: reason, sessionID: session))
            try await client.send(Self.plainResponse(502, "Bad Gateway", "BelloCode: " + reason))
            return false
        }
        let filter = ResponseFilter(secrets: bound.compactMap { secret in
            guard let value = snapshot.values[secret.account] else { return nil }
            let replacement = snapshot.placeholder(account: secret.account, session: session) ?? "bcsec_redacted"
            return ResponseFilter.Secret(account: secret.account, value: value.utf8, replacement: replacement)
        }, bodyLimit: limit)
        switch filter.filter(headers: responseHead.fields, body: rawBody) {
        case .block(let reason, let accounts):
            emit(.responseBlocked(accounts: accounts.isEmpty ? bound.map(\.account) : accounts, destination: request.auditDestination,
                                  method: method, reason: reason, sessionID: session))
            try await client.send(Self.plainResponse(502, "Bad Gateway", "BelloCode: " + reason))
            return !clientCloses
        case .pass(var fields, let body, let redactions):
            if !redactions.isEmpty {
                emit(.responseRedacted(accounts: Array(redactions.keys).sorted(), destination: request.auditDestination, method: method, sessionID: session))
            }
            fields.remove("Connection")
            fields.remove("Keep-Alive")
            // The body goes out with a length: trailers were read and dropped, so none are announced.
            fields.remove("Trailer")
            if method == "HEAD" { fields.remove("Content-Length") }
            try await client.send(HTTPHead(startLine: statusLine, fields: fields).serialized + (method == "HEAD" ? Data() : body))
            return !clientCloses
        }
    }

    /// The thread whose placeholder appears in a request that was not substituted (for the audit only).
    private struct Reauthorization: Error {
        var reason: SecretRefusal
        var account: String?
        var session: String?
    }

    /// `original` substituted under the current snapshot: the request to send when it makes exactly the same uses
    /// (secrets, bindings, placeholders) as were reserved, else why not. This request's own reservations are already in
    /// the ledger and are discounted, so its use limits are judged as when it was admitted.
    private func reauthorize(_ original: OutboundRequest, uses: [SubstitutionUse], scope: EgressScope) -> Result<OutboundRequest, Reauthorization> {
        let snapshot = state.withLock { $0.snapshot }
        let ledger = self.ledger
        var own: [String: Int] = [:]
        for use in uses { own[use.account + "\u{1F}" + use.bindingID, default: 0] += 1 }
        let reserved = own
        let rewriter = RequestRewriter(admitsProject: scope.admitsProject, useCount: { account, binding in
            ledger.count(account: account, bindingID: binding) - (reserved[account + "\u{1F}" + binding] ?? 0)
        })
        switch rewriter.rewrite(original, resolve: { snapshot.resolve($0) }) {
        case .substituted(let current, let made) where Set(made) == Set(uses) && made.allSatisfy({ snapshot.secrets[$0.account] != nil }):
            return .success(current)
        case .refused(let reason, let account, let session):
            return .failure(Reauthorization(reason: reason, account: account, session: session))
        default:
            return .failure(Reauthorization(reason: .unknownPlaceholder, account: nil, session: nil))
        }
    }

    private static func sessionOfPlaceholders(in head: HTTPHead, body: Data, snapshot: EgressSnapshot) -> String? {
        let text = Data((head.startLine.joined(separator: " ") + head.fields.map { $0.value }.joined()).utf8)
        return (Placeholder.find(in: text).placeholders + Placeholder.find(in: body).placeholders).lazy.compactMap { snapshot.grants[$0]?.sessionID }.first
    }

    struct DestinationRefused: Error { var message: String }
    /// An error after the tunnel was answered with 200 (no second answer may be sent).
    struct TunnelOpened: Error { var underlying: any Error }
    struct TimeLimitExceeded: Error {}

    /// Runs `body` with a deadline. `onTimeout` must make `body` return (closing the connection it reads from), because
    /// a pending network receive does not observe task cancellation.
    private static func withTimeLimit<T: Sendable>(_ limit: Duration, onTimeout: @escaping @Sendable () -> Void,
                                                   _ body: @escaping @Sendable () async throws -> T) async -> Result<T, any Error> {
        await withTaskGroup(of: Result<T, any Error>?.self) { group in
            group.addTask {
                do { return .success(try await body()) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                if Task.isCancelled { return nil }
                onTimeout()
                return .failure(TimeLimitExceeded())
            }
            var result: Result<T, any Error> = .failure(TimeLimitExceeded())
            for await value in group {
                if let value {
                    result = value
                    break
                }
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: Upstream

    private func endpoint(_ destination: HostPort) -> NWEndpoint {
        if let override = configuration.resolverOverrides[destination.host] {
            return .hostPort(host: NWEndpoint.Host(override.host), port: NWEndpoint.Port(rawValue: UInt16(override.port))!)
        }
        return .hostPort(host: NWEndpoint.Host(destination.host), port: NWEndpoint.Port(rawValue: UInt16(destination.port))!)
    }

    private func connectUpstream(scheme: String, destination: HostPort, scope: String) async throws -> WireConnection {
        switch await configuration.router.route(scheme: scheme, destination: destination, scope: scope) {
        case .internet:
            return try await connectInternet(scheme: scheme, destination: destination)
        case .refuse(let reason):
            throw DestinationRefused(message: "BelloCode: " + reason)
        case .dial(let dial):
            // Plain HTTP to the container (dev servers, services); TLS to a routed container is not offered.
            guard scheme == "http" || dial.terminatesTLS else { throw DestinationRefused(message: "BelloCode: \(destination) is reached over http only.") }
            let wire = WireConnection(NWConnection(to: endpoint(dial.endpoint), using: .tcp), queue: queue)
            try await wire.start()
            if let preamble = dial.preamble { try await wire.send(preamble) }
            return wire
        }
    }

    private func connectInternet(scheme: String, destination: HostPort) async throws -> WireConnection {
        let parameters: NWParameters
        if scheme == "https" {
            let tls = NWProtocolTLS.Options()
            let host = destination.host
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            let anchors = configuration.extraAnchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trustRef, complete in
                let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
                if !anchors.isEmpty {
                    SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                    SecTrustSetAnchorCertificatesOnly(trust, false)
                }
                complete(SecTrustEvaluateWithError(trust, nil))
            }, queue)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        if let proxy = configuration.upstreamProxy, configuration.resolverOverrides[destination.host] == nil {
            let proxyEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.host), port: NWEndpoint.Port(rawValue: UInt16(proxy.port))!)
            let context = NWParameters.PrivacyContext(description: "bellocode-egress")
            context.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: proxyEndpoint)]
            parameters.setPrivacyContext(context)
        }
        let wire = WireConnection(NWConnection(to: endpoint(destination), using: parameters), queue: queue)
        try await wire.start()
        // Never the Mac itself (or link-local, metadata-style addresses) by name: the agent must not reach host services.
        if configuration.resolverOverrides[destination.host] == nil, configuration.upstreamProxy == nil,
           case .hostPort(let host, _)? = wire.connection.currentPath?.remoteEndpoint, Self.isLocal(host) {
            wire.cancel()
            throw DestinationRefused(message: "BelloCode: \(destination.host) resolves to this Mac or a link-local address; the proxy does not connect there.")
        }
        return wire
    }

    static func isLocal(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            let bytes = [UInt8](address.rawValue)
            return bytes.first == 127 || (bytes.count == 4 && bytes[0] == 169 && bytes[1] == 254) || bytes.allSatisfy { $0 == 0 }
        case .ipv6(let address):
            return address == .loopback || address == .any || address.isLinkLocal || address.isIPv4Mapped && (address.asIPv4.map { isLocal(.ipv4($0)) } ?? false)
        default: return false
        }
    }

    // MARK: Messages

    /// The response's status code when it is exactly three digits (100–599); nil otherwise.
    static func statusCode(_ head: HTTPHead) -> Int? {
        guard head.startLine.count > 1 else { return nil }
        let text = head.startLine[1]
        guard text.utf8.count == 3, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let code = Int(text), (100...599).contains(code) else { return nil }
        return code
    }

    /// BelloCode's own reason phrase for a status code (never the destination's).
    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 101: "Switching Protocols"
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 203: "Non-Authoritative Information"
        case 204: "No Content"
        case 205: "Reset Content"
        case 206: "Partial Content"
        case 300: "Multiple Choices"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 411: "Length Required"
        case 412: "Precondition Failed"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 416: "Range Not Satisfiable"
        case 421: "Misdirected Request"
        case 422: "Unprocessable Content"
        case 428: "Precondition Required"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: "Status"
        }
    }

    static func hostOnly(_ hostHeader: String) -> String {
        if hostHeader.hasPrefix("["), let close = hostHeader.firstIndex(of: "]") {
            return SecretBinding.canonicalHost(String(hostHeader[hostHeader.index(after: hostHeader.startIndex)..<close]))
        }
        return SecretBinding.canonicalHost(String(hostHeader.split(separator: ":").first ?? ""))
    }

    static func hostHeader(_ destination: HostPort, scheme: String) -> String {
        let host = destination.host.contains(":") ? "[\(destination.host)]" : destination.host
        let defaultPort = scheme == "https" ? 443 : 80
        return destination.port == defaultPort ? host : "\(host):\(destination.port)"
    }

    static func plainResponse(_ status: Int, _ reason: String, _ text: String, extra: [HTTPField] = []) -> Data {
        let body = Data((text + "\n").utf8)
        let fields = [HTTPField("Content-Type", "text/plain; charset=utf-8"), HTTPField("Content-Length", String(body.count))] + extra
        return HTTPHead(startLine: ["HTTP/1.1", String(status), reason], fields: fields).serialized + body
    }

    static func refusal(_ reason: SecretRefusal, status: Int) -> Data {
        plainResponse(status, status == 413 ? "Payload Too Large" : "Forbidden", "BelloCode refused this request: " + reason.message,
                      extra: [HTTPField("X-BelloCode-Refused", reason.code)])
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? NWError { return error.debugDescription }
        return String(describing: error)
    }
}
