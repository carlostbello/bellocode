import BelloCore
import Foundation
import Testing

@testable import SecretKit

/// R02 (docs/reviews/release-1.0-review.md): a destination bound to a hidden secret must not get the value back to the
/// client through response metadata: the status line's reason phrase, an interim response, a trailer, an unsupported
/// encoding's name (refusal and audit), or an unsolicited protocol switch that leaves the inspected path.
@Suite("Egress response metadata (in-process)", .serialized, .timeLimit(.minutes(3)))
struct ResponseMetadataTests {
    static let canary = "sk_live_META_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

    /// Any trace of the canary, including a case-folded copy (an encoding name is lower-cased before it is reported).
    static func leaked(_ data: Data) -> Bool {
        let patterns = SecretPatterns(value: Data(canary.utf8))
        if !patterns.forms(in: data).isEmpty { return true }
        return ByteSearch.contains(Data(String(decoding: data, as: UTF8.self).lowercased().utf8), Data(canary.lowercased().utf8))
    }

    @Test func reflectedMetadataNeverReachesTheClient() async throws {
        let bound = try await EchoServer(name: "bound.test", authority: nil)
        defer { bound.stop() }
        let proxy = EgressProxy(authority: try CertificateAuthority(commonName: "Metadata test CA"), configuration: EgressProxyConfiguration(
            resolverOverrides: ["bound.test": HostPort(host: "127.0.0.1", port: Int(bound.port))], inspectedResponseTime: .seconds(3)))
        let proxyPort = try await proxy.start()
        defer { proxy.stop() }
        proxy.setScopes([EgressScope(id: "test", token: "meta-token") { $0 == "/project" }])
        // Plain http keeps the client raw; the proxy's rules are the same as inside a TLS tunnel.
        let secret = ManagedSecret(account: "bcs_meta", name: "META", label: "Meta", mode: .placeholder,
                                   bindings: [SecretBinding(scheme: "http", host: "bound.test", locations: [.header("Authorization", prefix: "Bearer ")])])
        let placeholder = Placeholder.make()
        proxy.update(EgressSnapshot(
            grants: [placeholder: PlaceholderGrant(placeholder: placeholder, account: secret.account, sessionID: "ses_meta", projectDirectory: "/project")],
            secrets: [secret.account: secret], values: [secret.account: SecretValue(Self.canary)]))
        let gateway = try await TestGateway(proxyPort: proxyPort, token: "meta-token")
        defer { gateway.stop() }
        let collector = Task { () -> [EgressEvent] in
            var out: [EgressEvent] = []
            for await event in proxy.events { out.append(event) }
            return out
        }

        for route in ["reflect-reason", "reflect-interim", "reflect-trailer", "reflect-encoding", "unsolicited-upgrade"] {
            let before = bound.requestCount
            let response = try await RawProxyClient.exchange(gatewayPort: gateway.port, request:
                "GET http://bound.test/v1/\(route) HTTP/1.1\r\nHost: bound.test\r\nAuthorization: Bearer \(placeholder)\r\nConnection: close\r\n\r\n")
            #expect(bound.requestCount == before + 1, "\(route): the bound server was asked (with the real value)")
            #expect(!response.isEmpty, "\(route): the proxy answered")
            #expect(!Self.leaked(response), "\(route): the value came back to the client: \(String(decoding: response.prefix(200), as: UTF8.self).replacingOccurrences(of: Self.canary, with: "<CANARY>"))")
            if route == "unsolicited-upgrade" || route == "reflect-encoding" {
                #expect(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 502 "), "\(route): blocked")
            } else {
                #expect(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n"), "\(route): BelloCode's own status line")
            }
        }
        #expect(ByteSearch.contains(bound.receivedBytes, Data(Self.canary.utf8)), "substitution happened")
        proxy.stop()
        // Audit details: fixed text, never the destination's.
        let events = await withTaskGroup(of: [EgressEvent]?.self) { group in
            group.addTask { await collector.value }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            collector.cancel()
            return first ?? []
        }
        for event in events {
            if case .responseBlocked(_, _, _, let reason, _) = event { #expect(!Self.leaked(Data(reason.utf8)), "audit reason carries the value") }
        }
    }
}
