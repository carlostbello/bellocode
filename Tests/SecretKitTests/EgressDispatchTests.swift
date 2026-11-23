import BelloCore
import Foundation
import Network
import Synchronization
import Testing

@testable import SecretKit

/// v1.0.1 verification (docs/reviews/v1.0.1-*-verification.md): the substituted value leaves only under the snapshot
/// of the moment and is scanned for under it (AF15, AV01); transfer codings are undone before scanning (AV02); chunk
/// sizes never overflow (AV09); and every refusal before the send gives its reserved uses back, in memory and in what
/// was stored (AV13, GV05, NV07).
///
/// Most cases speak raw HTTP/1.1 to the proxy (absolute-form, plain http) so exact bytes are visible: the binding is
/// `http://plain.test`, which the proxy accepts (only Settings refuses a plain-http binding).
@Suite("Egress dispatch and reservations", .serialized, .timeLimit(.minutes(3)))
struct EgressDispatchTests {
    static let canary = ProxyTests.canary

    final class Plain: Sendable {
        let proxy: EgressProxy
        let server: EchoServer
        let gateway: TestGateway
        let placeholder: String
        let secret: ManagedSecret
        let recorded = Mutex<[SubstitutionUse]>([])
        let released = Mutex<[SubstitutionUse]>([])

        init(proxy: EgressProxy, server: EchoServer, gateway: TestGateway, placeholder: String, secret: ManagedSecret) {
            self.proxy = proxy
            self.server = server
            self.gateway = gateway
            self.placeholder = placeholder
            self.secret = secret
        }

        var binding: SecretBinding { secret.bindings[0] }
        var reservedUses: Int { proxy.ledger.count(account: secret.account, bindingID: binding.id) }

        func stop() {
            proxy.stop()
            server.stop()
            gateway.stop()
        }

        /// One request on its own connection (the request asks the proxy to close it afterwards).
        func exchange(_ request: String) async throws -> Data {
            try await RawProxyClient.exchange(gatewayPort: gateway.port, request: request)
        }

        func request(_ target: String, host: String = "plain.test", placeholder: Bool = true, extra: String = "") -> String {
            "GET http://\(host)\(target) HTTP/1.1\r\nHost: \(host)\r\n" + (placeholder ? "Authorization: Bearer \(self.placeholder)\r\n" : "")
                + extra + "Connection: close\r\n\r\n"
        }

        func snapshot(value: String) -> EgressSnapshot {
            EgressSnapshot(grants: [placeholder: PlaceholderGrant(placeholder: placeholder, account: secret.account, sessionID: "ses_test", projectDirectory: "/project")],
                           secrets: [secret.account: secret], values: [secret.account: SecretValue(value)])
        }
    }

    /// A loopback port nothing listens on (tcpmux; never served on a Mac).
    static let closedPort = 1

    static func make(host: String = "plain.test", maxUses: Int? = nil, router: (any EgressRouter)? = nil) async throws -> Plain {
        let server = try await EchoServer(name: "plain.test", authority: nil)
        let proxy = EgressProxy(authority: try CertificateAuthority(commonName: "Test egress CA"), configuration: EgressProxyConfiguration(
            resolverOverrides: ["plain.test": HostPort(host: "127.0.0.1", port: Int(server.port)), "down.test": HostPort(host: "127.0.0.1", port: closedPort)],
            requestBodyLimit: 1 << 20, inspectedResponseTime: .seconds(5), router: router ?? InternetRouter()))
        let port = try await proxy.start()
        let token = UUID().uuidString
        proxy.setScopes([EgressScope(id: "test", token: token) { $0 == "/project" }])
        let binding = SecretBinding(scheme: "http", host: host, pathPrefixes: ["/v1"], locations: [.header("Authorization", prefix: "Bearer ")], maxUses: maxUses)
        let secret = ManagedSecret(account: "bcs_plain", name: "API_KEY", label: "Plain key", mode: .placeholder, bindings: [binding])
        let gateway = try await TestGateway(proxyPort: port, token: token)
        let f = Plain(proxy: proxy, server: server, gateway: gateway, placeholder: Placeholder.make(), secret: secret)
        proxy.update(f.snapshot(value: canary))
        proxy.setUseRecorder { [f] uses in f.recorded.withLock { $0 += uses }; return true }
        proxy.setUseReleaser { [f] uses in f.released.withLock { $0 += uses } }
        return f
    }

    static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// Any detectable form of `value`, also inside a gzip body (what a client that decodes transfer codings would see).
    static func leaked(_ value: String, in data: Data) -> Bool {
        let patterns = SecretPatterns(value: Data(value.utf8))
        if !patterns.forms(in: data).isEmpty { return true }
        let magic = Data([0x1F, 0x8B, 0x08])
        if let start = ByteSearch.range(data, magic, from: 0)?.lowerBound,
           let inflated = try? ContentDecoding.gunzip(Data(data.dropFirst(start)), limit: 1 << 20) {
            if !patterns.forms(in: inflated).isEmpty { return true }
            if let inner = ByteSearch.range(inflated, magic, from: 0)?.lowerBound,
               let twice = try? ContentDecoding.gunzip(Data(inflated.dropFirst(inner)), limit: 1 << 20) {
                return !patterns.forms(in: twice).isEmpty
            }
        }
        return false
    }

    // MARK: AF15: the window between the last check and the write

    /// A revocation published after the request passed its last check but before its bytes were written: the publish
    /// waits for that write, cancels it, and nothing reaches the destination.
    @Test func aRevocationAfterTheLastCheckStopsTheWrite() async throws {
        let f = try await Self.make(maxUses: 3)
        defer { f.stop() }
        let gate = SendGate()
        f.proxy.faults.withLock { $0.beforeSend = { await gate.hold() } }
        let request = Task { try await f.exchange(f.request("/v1/echo")) }
        await gate.waitUntilHeld()
        #expect(f.proxy.dispatchCount == 1, "authorized and registered")
        let published = OnceBox()
        let publish = Task {
            await f.proxy.publish(EgressSnapshot())
            published.set(f.proxy.dispatchCount)
        }
        // The revocation's publish cannot return while the authorized write is still pending (it withdraws it instead).
        try await waitUntilTrue { published.value != nil || f.proxy.dispatchCancelledCount == 1 }
        #expect(published.value == nil, "the publish returned while the authorized request could still be written")
        gate.release()
        await publish.value
        #expect(published.value == 0, "no write of the withdrawn request outlives the publish")
        let response = try await request.value
        #expect(Self.text(response).hasPrefix("HTTP/1.1 403"), "\(Self.text(response).prefix(120))")
        #expect(!Self.leaked(Self.canary, in: f.server.receivedBytes), "the value left after the revocation was published")
        #expect(f.server.requestCount == 0)
        #expect(f.reservedUses == 0, "nothing was written: the use is given back")
        #expect(f.released.withLock { $0.count } == 1, "and lowered where it was stored (AV13)")
    }

    // MARK: AV01: the response is scanned for the value that was sent

    /// A rotation while the upstream connection is being set up: the request leaves with the new value, and the echo of
    /// that new value is redacted like the old one.
    @Test func aRotationInFlightIsScannedForTheValueSent() async throws {
        let router = HeldRouter()
        let f = try await ProxyTests.makeFixture(router: router)
        defer { router.release(); f.stop() }
        let rotated = "sk_live_ROTATED_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let request = Task { try await f.client.get("https://bound.test/v1/echo", headers: ["Authorization": "Bearer \(f.placeholder)"]) }
        await router.waitUntilHeld()
        // What SecretManager publishes after a rotation: same secret, binding and placeholder; a new value.
        f.proxy.update(EgressSnapshot(
            grants: [f.placeholder: PlaceholderGrant(placeholder: f.placeholder, account: f.secret.account, sessionID: "ses_test", projectDirectory: "/project")],
            secrets: [f.secret.account: f.secret], values: [f.secret.account: SecretValue(rotated)]))
        router.release()
        let (status, headers, body) = try await request.value
        #expect(status == 200)
        #expect(ByteSearch.contains(f.bound.receivedBytes, Data(rotated.utf8)), "sent with the current value")
        let seen = Data(headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n").utf8) + body
        #expect(!Self.leaked(rotated, in: seen), "the rotated value came back to the agent")
        #expect(!Self.leaked(Self.canary, in: seen))
        #expect(Self.text(body).contains("Bearer \(f.placeholder)"), "the echo shows the placeholder")
    }

    // MARK: AV02: transfer codings

    @Test func transferAndRepeatedContentCodingsAreUndoneBeforeScanning() async throws {
        let f = try await Self.make()
        defer { f.stop() }
        for encoding in ["te-gzip", "te-gzip-close", "ce-twice"] {
            let response = try await f.exchange(f.request("/v1/echo?enc=\(encoding)"))
            let text = Self.text(response)
            #expect(text.hasPrefix("HTTP/1.1 200") || text.hasPrefix("HTTP/1.1 502"), "\(encoding): \(text.prefix(80))")
            #expect(!Self.leaked(Self.canary, in: response), "\(encoding): the reflected value reached the client")
            if text.hasPrefix("HTTP/1.1 200") {
                #expect(text.contains("Bearer \(f.placeholder)"), "\(encoding): passed decoded, with the placeholder")
                #expect(!text.lowercased().contains("transfer-encoding: gzip"), "\(encoding)")
            }
        }
        #expect(ByteSearch.count(f.server.receivedBytes, Data(Self.canary.utf8)) == 3, "every request was substituted")
    }

    @Test func unknownOrMisplacedTransferCodingsBlock() {
        let filter = ResponseFilter(secrets: [ResponseFilter.Secret(account: "a", value: Data(Self.canary.utf8), replacement: "bcsec_x")])
        for coding in ["compress, chunked", "chunked, gzip", "x-custom"] {
            guard case .block = filter.filter(headers: [HTTPField("Transfer-Encoding", coding)], body: Data("plain".utf8)) else {
                Issue.record("\(coding) passed")
                continue
            }
        }
        guard case .pass(_, let body, _) = filter.filter(headers: [HTTPField("Transfer-Encoding", "gzip"), HTTPField("Transfer-Encoding", "chunked")],
                                                         body: ScannerTests.gzip(Data("x \(Self.canary) y".utf8))) else {
            Issue.record("split Transfer-Encoding fields were not decoded")
            return
        }
        #expect(Self.text(body) == "x bcsec_x y")
    }

    // MARK: AV09: chunk sizes

    @Test func anOverflowingChunkSizeIsRefusedAndTheProxyKeepsServing() async throws {
        let f = try await Self.make()
        defer { f.stop() }
        // The request body: one byte, then a size that overflows when added to it.
        let request = "POST http://plain.test/v1/ok HTTP/1.1\r\nHost: plain.test\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n1\r\na\r\n7fffffffffffffff\r\n"
        let refused = Self.text(try await f.exchange(request))
        #expect(refused.hasPrefix("HTTP/1.1 413"), "\(refused.prefix(80))")
        // An inspected response doing the same.
        let blocked = Self.text(try await f.exchange(f.request("/v1/overflow-chunk")))
        #expect(blocked.hasPrefix("HTTP/1.1 502") && blocked.contains("too large"), "\(blocked.prefix(160))")
        for size in ["+1", "-0", "0x1", " "] {
            #expect(throws: WireError.self, "\(size)") { try WireConnection.chunkSize(size) }
        }
        #expect(try WireConnection.chunkSize("1A;ext=1") == 26)
        let ok = Self.text(try await f.exchange(f.request("/v1/ok")))
        #expect(ok.hasPrefix("HTTP/1.1 200"), "still serving")
    }

    // MARK: AV13, GV05, NV07: reservations

    /// An upgrade carrying a placeholder is refused before anything is reserved: repeating it never uses up the binding.
    @Test func aRefusedUpgradeNeverConsumesAUse() async throws {
        let f = try await Self.make(maxUses: 1)
        defer { f.stop() }
        for _ in 0..<3 {
            let response = Self.text(try await f.exchange(f.request("/v1/ws", extra: "Upgrade: websocket\r\nConnection: Upgrade\r\n")))
            #expect(response.hasPrefix("HTTP/1.1 403") && response.contains(SecretRefusal.upgrade.code), "\(response.prefix(120))")
        }
        #expect(f.reservedUses == 0)
        #expect(f.recorded.withLock { $0.isEmpty }, "nothing was reserved, so nothing was stored")
        let ok = Self.text(try await f.exchange(f.request("/v1/ok")))
        #expect(ok.hasPrefix("HTTP/1.1 200"), "the binding's one use is still there: \(ok.prefix(80))")
        #expect(f.reservedUses == 1)
    }

    /// The destination cannot be reached: nothing was sent, so the use is given back in memory and where it was stored.
    @Test func anUnreachableDestinationGivesTheUseBack() async throws {
        let f = try await Self.make(host: "down.test", maxUses: 1)
        defer { f.stop() }
        let response = Self.text(try await f.exchange(f.request("/v1/ok", host: "down.test")))
        #expect(response.hasPrefix("HTTP/1.1 502"), "\(response.prefix(80))")
        #expect(f.recorded.withLock { $0.count } == 1, "the limited use was stored before connecting")
        #expect(f.released.withLock { $0.count } == 1, "and lowered again")
        #expect(f.reservedUses == 0)
    }

    /// A revocation while connecting refuses the request; a limited use that was stored is lowered again (AV13).
    @Test func aReauthorizationRefusalLowersTheStoredUse() async throws {
        let router = HeldRouter()
        let f = try await Self.make(maxUses: 1, router: router)
        defer { router.release(); f.stop() }
        let request = Task { try await f.exchange(f.request("/v1/echo")) }
        await router.waitUntilHeld()
        f.proxy.update(EgressSnapshot())
        router.release()
        let response = Self.text(try await request.value)
        #expect(response.hasPrefix("HTTP/1.1 403"), "\(response.prefix(80))")
        #expect(f.recorded.withLock { $0.count } == 1)
        #expect(f.released.withLock { $0.map(\.bindingID) } == [f.binding.id])
        #expect(f.reservedUses == 0)
        #expect(f.server.requestCount == 0)
    }
}

/// Holds the proxy's last step before a substituted request is written, until released.
final class SendGate: Sendable {
    private struct State {
        var held = false
        var heldWaiters: [CheckedContinuation<Void, Never>] = []
        var released = false
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func hold() async {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.held = true
            defer { state.heldWaiters = [] }
            return state.heldWaiters
        }
        waiting.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            let go = state.withLock { state -> Bool in
                if state.released { return true }
                state.releaseWaiters.append(continuation)
                return false
            }
            if go { continuation.resume() }
        }
    }

    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                if state.held { return true }
                state.heldWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.releaseWaiters = [] }
            return state.releaseWaiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// A value set once from another task.
final class OnceBox: Sendable {
    private let stored = Mutex<Int?>(nil)
    func set(_ value: Int) { stored.withLock { $0 = value } }
    var value: Int? { stored.withLock { $0 } }
}

/// Waits (bounded, yielding) until `condition` holds.
func waitUntilTrue(_ timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { throw WireError("condition not reached") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
