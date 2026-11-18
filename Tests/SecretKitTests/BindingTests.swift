import BelloCore
import Foundation
import Testing

@testable import SecretKit

/// Binding matching and substitution (docs/features/secrets.md "Binding rules").
@Suite("Secret bindings", .timeLimit(.minutes(1)))
struct BindingTests {
    static let value = "sk_live_CANARY_7f3a9c1e5b2d4f60"
    let placeholder = Placeholder.make()

    func secret(_ bindings: [SecretBinding], mode: SecretUseMode = .placeholder, revoked: Bool = false, uses: [String: Int] = [:]) -> ManagedSecret {
        ManagedSecret(account: "bcs_test", name: "API_KEY", label: "Test API key", mode: mode, bindings: bindings, uses: uses, revoked: revoked)
    }

    func resolver(_ secret: ManagedSecret, project: String = "/p") -> (String) -> ResolvedPlaceholder? {
        let grant = PlaceholderGrant(placeholder: placeholder, account: secret.account, sessionID: "ses_1", projectDirectory: project)
        let placeholder = self.placeholder
        return { $0 == placeholder ? ResolvedPlaceholder(grant: grant, secret: secret, value: SecretValue(Self.value)) : nil }
    }

    func request(_ method: String = "GET", host: String = "api.example.com", target: String = "/v1/items",
                 headers: [HTTPField] = [], body: Data = Data()) -> OutboundRequest {
        OutboundRequest(method: method, scheme: "https", host: host, port: 443, target: target, headers: headers, body: body)
    }

    static let bearer = SecretBinding(host: "api.example.com", methods: ["GET", "POST"], pathPrefixes: ["/v1"],
                                      locations: [.header("Authorization", prefix: "Bearer "), .query("key"), .jsonField("auth.token"),
                                                  .formField("api_key"), .basicAuthPassword])

    @Test func placeholdersAreOpaqueAndWellFormed() {
        let a = Placeholder.make()
        let b = Placeholder.make()
        #expect(a != b)
        #expect(Placeholder.isPlaceholder(a))
        #expect(a.hasPrefix("bcsec_") && a.count == 46)
        #expect(!Placeholder.isPlaceholder(String(a.dropLast())))
        #expect(Placeholder.find(in: Data("x \(a) y".utf8)).placeholders == [a])
        #expect(Placeholder.find(in: Data("x \(a.dropLast(3)) y".utf8)).fragments == 1)
        #expect(Placeholder.find(in: Data("BCSEC_abc".utf8)).fragments == 1)
    }

    @Test func noPlaceholderIsUnchanged() {
        let decision = RequestRewriter().rewrite(request(headers: [HTTPField("Accept", "*/*")])) { _ in nil }
        guard case .unchanged = decision else { Issue.record("expected unchanged"); return }
    }

    @Test func headerSubstitutionOnBoundDestination() throws {
        let decision = RequestRewriter().rewrite(request(headers: [HTTPField("Authorization", "Bearer \(placeholder)")]),
                                                 resolve: resolver(secret([Self.bearer])))
        guard case .substituted(let out, let uses) = decision else { Issue.record("expected substitution: \(decision)"); return }
        #expect(out.headers.first("Authorization") == "Bearer \(Self.value)")
        #expect(uses.count == 1 && uses[0].sessionID == "ses_1")
    }

    @Test func unboundHostIsRefused() {
        let decision = RequestRewriter().rewrite(request(host: "attacker.example", headers: [HTTPField("Authorization", "Bearer \(placeholder)")]),
                                                 resolve: resolver(secret([Self.bearer])))
        guard case .refused(.unboundDestination, _, _) = decision else { Issue.record("\(decision)"); return }
    }

    @Test func lookalikeHostsAndPortsAreUnbound() {
        for (host, port) in [("api.example.com.attacker.io", 443), ("attacker.io", 443), ("API.EXAMPLE.COM", 8443), ("xapi.example.com", 443)] {
            let r = OutboundRequest(method: "GET", scheme: "https", host: host, port: port, target: "/v1/x",
                                    headers: [HTTPField("Authorization", "Bearer \(placeholder)")])
            guard case .refused(.unboundDestination, _, _) = RequestRewriter().rewrite(r, resolve: resolver(secret([Self.bearer]))) else {
                Issue.record("\(host):\(port) was not refused"); continue
            }
        }
        // Case and a trailing dot are the same host.
        let same = OutboundRequest(method: "GET", scheme: "https", host: "API.Example.com.", port: 443, target: "/v1/x",
                                   headers: [HTTPField("Authorization", "Bearer \(placeholder)")])
        guard case .substituted = RequestRewriter().rewrite(same, resolve: resolver(secret([Self.bearer]))) else { Issue.record("same host refused"); return }
    }

    @Test func attackerControlledPathsAreRefused() {
        let auth = [HTTPField("Authorization", "Bearer \(placeholder)")]
        for target in ["/v2/items", "/v1x/items", "/v1/../admin", "/v1/%2e%2e/admin", "/v1%2fadmin", "/v1/./x", "/v1//x", "/v1/a%5cb", "//evil/v1"] {
            let decision = RequestRewriter().rewrite(request(target: target, headers: auth), resolve: resolver(secret([Self.bearer])))
            switch decision {
            case .refused(.pathNotAllowed, _, _), .refused(.ambiguousPath, _, _): break
            default: Issue.record("\(target) → \(decision)")
            }
        }
    }

    @Test func methodNotAllowed() {
        let decision = RequestRewriter().rewrite(request("DELETE", headers: [HTTPField("Authorization", "Bearer \(placeholder)")]),
                                                 resolve: resolver(secret([Self.bearer])))
        guard case .refused(.methodNotAllowed, _, _) = decision else { Issue.record("\(decision)"); return }
    }

    @Test func placeholderOutsideAllowedLocationsIsRefused() {
        let cases: [OutboundRequest] = [
            request(headers: [HTTPField("X-Echo", placeholder)]),
            request(headers: [HTTPField("Authorization", "Token \(placeholder)")]),
            request(headers: [HTTPField("Authorization", "Bearer \(placeholder) extra")]),
            request(target: "/v1/\(placeholder)"),
            request(target: "/v1/items?other=\(placeholder)"),
            request(target: "/v1/items?key=x\(placeholder)"),
            request("POST", headers: [HTTPField("Content-Type", "text/plain")], body: Data(placeholder.utf8)),
            request("POST", headers: [HTTPField("Content-Type", "application/json")], body: Data("{\"note\":\"\(placeholder)\"}".utf8)),
            request("POST", headers: [HTTPField("Content-Type", "application/json")], body: Data("{\"auth\":{\"token\":\"\(placeholder)\"},\"copy\":\"\(placeholder)\"}".utf8)),
            request("POST", headers: [HTTPField("Content-Type", "application/x-www-form-urlencoded")], body: Data("echo=\(placeholder)".utf8)),
        ]
        for r in cases {
            let decision = RequestRewriter().rewrite(r, resolve: resolver(secret([Self.bearer])))
            guard case .refused = decision else { Issue.record("not refused: \(r.target) \(r.headers) \(String(decoding: r.body, as: UTF8.self))"); continue }
        }
    }

    @Test func queryJSONFormAndBasicSubstitution() throws {
        let s = secret([Self.bearer])
        guard case .substituted(let q, _) = RequestRewriter().rewrite(request(target: "/v1/items?a=1&key=\(placeholder)"), resolve: resolver(s)) else {
            Issue.record("query"); return
        }
        #expect(q.target == "/v1/items?a=1&key=" + RequestRewriter.percentEncode(Data(Self.value.utf8)))
        let json = request("POST", headers: [HTTPField("Content-Type", "application/json")], body: Data("{\"auth\":{\"token\":\"\(placeholder)\"}}".utf8))
        guard case .substituted(let j, _) = RequestRewriter().rewrite(json, resolve: resolver(s)) else { Issue.record("json"); return }
        let parsed = try JSONSerialization.jsonObject(with: j.body) as? [String: [String: String]]
        #expect(parsed?["auth"]?["token"] == Self.value)
        #expect(j.headers.first("Content-Length") == String(j.body.count))
        let form = request("POST", headers: [HTTPField("Content-Type", "application/x-www-form-urlencoded")], body: Data("a=b&api_key=\(placeholder)".utf8))
        guard case .substituted(let f, _) = RequestRewriter().rewrite(form, resolve: resolver(s)) else { Issue.record("form"); return }
        #expect(String(decoding: f.body, as: UTF8.self).hasSuffix("api_key=" + RequestRewriter.percentEncode(Data(Self.value.utf8))))
        let basic = request(headers: [HTTPField("Authorization", "Basic " + Data("user:\(placeholder)".utf8).base64EncodedString())])
        guard case .substituted(let b, _) = RequestRewriter().rewrite(basic, resolve: resolver(s)) else { Issue.record("basic"); return }
        #expect(b.headers.first("Authorization") == "Basic " + Data("user:\(Self.value)".utf8).base64EncodedString())
    }

    @Test func splitAndEncodedPlaceholdersAreRefused() {
        let s = secret([Self.bearer])
        let half = placeholder.count / 2
        let first = String(placeholder.prefix(half))
        let second = String(placeholder.dropFirst(half))
        let cases: [(String, OutboundRequest)] = [
            ("split headers", request(headers: [HTTPField("Authorization", "Bearer \(first)"), HTTPField("X-Rest", second)])),
            ("base64", request(headers: [HTTPField("X-Key", Data(placeholder.utf8).base64EncodedString())])),
            ("base64 offset", request(headers: [HTTPField("X-Key", Data(("ab" + placeholder).utf8).base64EncodedString())])),
            ("hex", request(headers: [HTTPField("X-Key", placeholder.utf8.map { String(format: "%02x", $0) }.joined())])),
            ("percent", request(target: "/v1/items?key=bcsec%5F" + placeholder.dropFirst(6))),
            ("json escape", request("POST", headers: [HTTPField("Content-Type", "application/json")],
                                    body: Data("{\"auth\":{\"token\":\"bcsec\\u005f\(placeholder.dropFirst(6))\"}}".utf8))),
            ("upper", request(headers: [HTTPField("Authorization", "Bearer " + placeholder.uppercased())])),
        ]
        for (name, r) in cases {
            switch RequestRewriter().rewrite(r, resolve: resolver(s)) {
            case .refused(.fragment, _, _), .refused(.encodedPlaceholder, _, _): break
            case let other: Issue.record("\(name): \(other)")
            }
        }
    }

    @Test func unknownRevokedExpiredLimitedAndWrongProject() {
        let auth = [HTTPField("Authorization", "Bearer \(placeholder)")]
        guard case .refused(.unknownPlaceholder, _, _) = RequestRewriter().rewrite(request(headers: auth), resolve: { _ in nil }) else { Issue.record("unknown"); return }
        guard case .refused(.revoked, _, _) = RequestRewriter().rewrite(request(headers: auth), resolve: resolver(secret([Self.bearer], revoked: true))) else { Issue.record("revoked"); return }
        var expired = Self.bearer
        expired.expires = Date().addingTimeInterval(-1)
        guard case .refused(.expired, _, _) = RequestRewriter().rewrite(request(headers: auth), resolve: resolver(secret([expired]))) else { Issue.record("expired"); return }
        var limited = Self.bearer
        limited.maxUses = 2
        guard case .refused(.useLimit, _, _) = RequestRewriter().rewrite(request(headers: auth), resolve: resolver(secret([limited], uses: [limited.id: 2]))) else { Issue.record("limit"); return }
        guard case .refused(.wrongProject, _, _) = RequestRewriter(admitsProject: { $0 == "/other" }).rewrite(request(headers: auth), resolve: resolver(secret([Self.bearer]))) else { Issue.record("project"); return }
        guard case .refused(.notPlaceholderMode, _, _) = RequestRewriter().rewrite(request(headers: auth), resolve: resolver(secret([Self.bearer], mode: .visible))) else { Issue.record("mode"); return }
    }

    @Test func bindingValidation() {
        #expect(SecretBinding(host: "*.example.com", locations: [.header("X")]).validationProblems().isEmpty == false)
        #expect(SecretBinding(host: "api.example.com", locations: []).validationProblems().isEmpty == false)
        #expect(SecretBinding(scheme: "http", host: "api.example.com", locations: [.header("X")]).validationProblems().isEmpty == false)
        #expect(Self.bearer.validationProblems().isEmpty)
        #expect(ManagedSecret.handle(from: "OpenAI API key") == "OPENAI_API_KEY")
        #expect(ManagedSecret.handle(from: "3scale") == "SECRET_3SCALE")
        #expect(!ManagedSecret.isValidHandle("PATH") && !ManagedSecret.isValidHandle("1X") && ManagedSecret.isValidHandle("MY_KEY"))
    }

    @Test func scopes() {
        #expect(SecretScope.global.admits(projectDirectory: "/a", codeRoots: []))
        #expect(SecretScope.project("/a/b").admits(projectDirectory: "/a/b", codeRoots: []))
        #expect(!SecretScope.project("/a/b").admits(projectDirectory: "/a/bc", codeRoots: []))
        #expect(SecretScope.codeRoots.admits(projectDirectory: "/r/x", codeRoots: ["/r"]))
        #expect(!SecretScope.codeRoots.admits(projectDirectory: "/s/x", codeRoots: ["/r"]))
    }
}
