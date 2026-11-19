import BelloCore
import Foundation

import Synchronization

/// The brokered HTTP tool (`http_request`, shown to agents as `bellocode_app_http_request`; docs/features/secrets.md
/// "Brokered"). The agent writes `{{secret:NAME}}` where a value belongs; BelloCode performs the request on the Mac, only
/// to the secret's bound destinations and only with the handle in an allowed place (the same rules as the proxy:
/// each handle becomes a one-off placeholder and goes through `RequestRewriter`), follows a redirect only when the new
/// URL passes the same rules, and returns status, a few allowlisted headers and a bounded body, unless the response
/// contains the value in any form the scanner finds, in which case nothing of it is returned.
///
/// Residual risk (stated in the product): a destination can reflect or transform the value into permitted fields in a
/// way the scanner does not recognise.
public struct SecretBroker: Sendable {
    public static let handlePattern = #"\{\{secret:([A-Za-z_][A-Za-z0-9_]{0,63})\}\}"#
    public static let bodyLimit = 64 * 1024
    public static let responseHeaderAllowlist = [
        "Content-Type", "Content-Length", "Date", "ETag", "Last-Modified", "Location", "Retry-After", "Link",
        "X-RateLimit-Limit", "X-RateLimit-Remaining", "X-RateLimit-Reset", "X-Request-Id", "X-Total", "X-Total-Pages", "X-Next-Page",
    ]
    static let maxRedirects = 3

    public struct Request: Sendable {
        public var method: String
        public var url: String
        public var headers: [String: String]
        public var body: String?

        public init(method: String = "GET", url: String, headers: [String: String] = [:], body: String? = nil) {
            self.method = method.uppercased()
            self.url = url
            self.headers = headers
            self.body = body
        }
    }

    public struct Outcome: Sendable {
        public var text: String
        public var audit: [SecretAuditEntry]
        public var used: [String]
        /// Every use reserved in the ledger (each hop sent), for the owner to persist.
        public var reserved: [SubstitutionUse] = []
    }

    /// Extra roots for TLS (tests' loopback servers); production uses the Mac's trust settings.
    public var extraAnchors: [Data]
    public var timeout: Duration
    /// Per-binding use counts, shared with the egress proxy (R12): each hop reserves its uses before it is sent.
    public var ledger: SecretUseLedger
    /// Persists reserved uses of limited bindings before the request is sent; false refuses it.
    public var recordUses: (@Sendable ([SubstitutionUse]) async -> Bool)?

    public init(extraAnchors: [Data] = [], timeout: Duration = .seconds(30), ledger: SecretUseLedger = SecretUseLedger(),
                recordUses: (@Sendable ([SubstitutionUse]) async -> Bool)? = nil) {
        self.extraAnchors = extraAnchors
        self.timeout = timeout
        self.ledger = ledger
        self.recordUses = recordUses
    }

    /// Names referenced by `{{secret:NAME}}` in the URL, headers and body.
    public static func handles(in request: Request) -> [String] {
        let texts = [request.url] + request.headers.flatMap { [$0.key, $0.value] } + [request.body ?? ""]
        guard let regex = try? NSRegularExpression(pattern: handlePattern) else { return [] }
        var names: [String] = []
        for text in texts {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text), !names.contains(String(text[range])) { names.append(String(text[range])) }
            }
        }
        return names
    }

    /// Performs the request. `secrets` maps each referenced name to its secret and value (already checked for scope
    /// and mode by the caller); `sessionID` is the calling thread (audit).
    public func perform(_ request: Request, secrets: [String: (ManagedSecret, SecretValue)], sessionID: String, projectDirectory: String) async -> Outcome {
        var audit: [SecretAuditEntry] = []
        var reserved: [SubstitutionUse] = []
        func refuse(_ text: String, _ account: String?, destination: String) -> Outcome {
            if let account {
                audit.append(SecretAuditEntry(account: account, destination: destination, method: request.method, sessionID: sessionID, outcome: .refused, detail: text))
            }
            return Outcome(text: "BelloCode refused this request: \(text)", audit: audit, used: [], reserved: reserved)
        }
        // Handles → one-off placeholders, resolved only to their secret.
        var substitutions: [String: ResolvedPlaceholder] = [:]
        var byName: [String: String] = [:]
        for (name, (secret, value)) in secrets {
            let placeholder = Placeholder.make()
            byName[name] = placeholder
            substitutions[placeholder] = ResolvedPlaceholder(
                grant: PlaceholderGrant(placeholder: placeholder, account: secret.account, sessionID: sessionID, projectDirectory: projectDirectory),
                secret: { var s = secret; s.mode = .placeholder; return s }(), value: value)
        }
        func fill(_ text: String) -> String {
            var out = text
            for (name, placeholder) in byName { out = out.replacingOccurrences(of: "{{secret:\(name)}}", with: placeholder) }
            return out
        }
        // A raw placeholder or the prefix in the agent's input is refused like an encoded one (never resolved here).
        let input = Data(([request.url, request.body ?? ""] + request.headers.flatMap { [$0.key, $0.value] }).joined(separator: "\n").utf8)
        if !Placeholder.find(in: input).placeholders.isEmpty || Placeholder.find(in: input).fragments > 0 {
            return refuse("use {{secret:NAME}} handles with this tool, not placeholders.", nil, destination: request.url)
        }
        var currentURL = fill(request.url)
        var method = request.method
        var body = request.body.map(fill).map { Data($0.utf8) } ?? Data()
        let headers = request.headers.map { HTTPField(fill($0.key), fill($0.value)) }
        let account = secrets.values.first?.0.account
        for hop in 0...Self.maxRedirects {
            guard let components = URLComponents(string: currentURL), let scheme = components.scheme?.lowercased(), let host = components.host else {
                return refuse("the URL is not valid.", account, destination: request.url)
            }
            guard scheme == "https" else { return refuse("only https URLs may carry a secret.", account, destination: "\(scheme)://\(host)") }
            let port = components.port ?? 443
            let target = (components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath) + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
            var fields = headers
            fields.remove("Host")
            fields.remove("Content-Length")
            let outbound = OutboundRequest(method: method, scheme: scheme, host: host, port: port, target: target, headers: fields, body: body)
            let ledger = self.ledger
            let decision = RequestRewriter(admitsProject: { _ in true }, useCount: { ledger.count(account: $0, bindingID: $1) })
                .rewrite(outbound) { substitutions[$0] }
            let rewritten: OutboundRequest
            var uses: [SubstitutionUse] = []
            switch decision {
            case .unchanged:
                return refuse(hop == 0 ? "the request names no secret ({{secret:NAME}}); use your own tools for requests without one."
                              : "the redirect would drop the secret's handle.", account, destination: outbound.auditDestination)
            case .refused(let reason, let refusedAccount, _):
                return refuse(hop == 0 ? reason.message : "redirect to \(outbound.origin) refused: \(reason.message)", refusedAccount ?? account, destination: outbound.auditDestination)
            case .substituted(let request, let made):
                rewritten = request
                uses = made
            }
            // Count against the binding before anything is sent (every hop is a use); concurrent calls cannot both take
            // a binding's last use.
            let limit = { (use: SubstitutionUse) -> Int? in
                secrets.values.first { $0.0.account == use.account }?.0.bindings.first { $0.id == use.bindingID }?.maxUses
            }
            guard ledger.reserve(uses, limit: limit) else {
                let label = secrets.values.first { $0.0.account == uses.first?.account }?.0.label ?? "the secret"
                return refuse(SecretRefusal.useLimit(label: label).message, uses.first?.account ?? account, destination: outbound.auditDestination)
            }
            reserved += uses
            if uses.contains(where: { limit($0) != nil }), let recordUses, !(await recordUses(uses)) {
                return refuse("BelloCode could not record this use of a limited secret, so it was not sent.", uses.first?.account ?? account,
                              destination: outbound.auditDestination)
            }
            // Perform on the Mac.
            let response: (HTTPURLResponse, Data)
            do {
                response = try await send(rewritten)
            } catch {
                return refuse("\(outbound.origin) could not be reached (\(error.localizedDescription)).", account, destination: outbound.auditDestination)
            }
            let (http, data) = response
            // Scan everything that could reach the agent, before deciding anything else.
            let headerText = http.allHeaderFields.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            let scanned = Data(headerText.utf8) + data
            for (_, (secret, value)) in secrets where !SecretPatterns(value: value.utf8).forms(in: scanned).isEmpty {
                audit.append(SecretAuditEntry(account: secret.account, destination: outbound.auditDestination, method: method, sessionID: sessionID,
                                              outcome: .responseBlocked, detail: "Response contained the value", status: http.statusCode))
                return Outcome(text: "BelloCode withheld the response from \(outbound.origin) (status \(http.statusCode)): it contained the secret's value in some form, so nothing of it is returned.",
                               audit: audit, used: uses.map(\.account), reserved: reserved)
            }
            for use in uses {
                audit.append(SecretAuditEntry(account: use.account, destination: outbound.auditDestination, method: method, sessionID: sessionID,
                                              outcome: .brokered, detail: "Brokered HTTP request", status: http.statusCode))
            }
            if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
               let next = URL(string: location, relativeTo: URL(string: currentURL))?.absoluteURL.absoluteString, hop < Self.maxRedirects {
                // Followed only if the new URL passes the same rules (checked at the top of the loop).
                currentURL = next
                if http.statusCode == 303 || ((http.statusCode == 301 || http.statusCode == 302) && method == "POST") {
                    method = "GET"
                    body = Data()
                }
                continue
            }
            return Outcome(text: Self.describe(http, data), audit: audit, used: uses.map(\.account), reserved: reserved)
        }
        return refuse("too many redirects.", account, destination: request.url)
    }

    static func describe(_ http: HTTPURLResponse, _ data: Data) -> String {
        var lines = ["Status: \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"]
        for name in responseHeaderAllowlist {
            if let value = http.value(forHTTPHeaderField: name) { lines.append("\(name): \(value.prefix(512))") }
        }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let textual = type.isEmpty || type.contains("json") || type.hasPrefix("text/") || type.contains("xml") || type.contains("form")
        if data.isEmpty {
            lines.append("(empty body)")
        } else if textual, let text = String(data: data.prefix(bodyLimit), encoding: .utf8) {
            lines.append("")
            lines.append(text)
            if data.count > bodyLimit { lines.append("… (\(data.count - bodyLimit) more bytes not shown)") }
        } else {
            lines.append("(\(data.count) bytes of \(type.isEmpty ? "binary" : type) not shown)")
        }
        return lines.joined(separator: "\n")
    }

    private func send(_ request: OutboundRequest) async throws -> (HTTPURLResponse, Data) {
        let defaultPort = request.scheme == "https" ? 443 : 80
        let urlString = "\(request.scheme)://\(request.host)\(request.port == defaultPort ? "" : ":\(request.port)")\(request.target)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: TimeInterval(timeout.components.seconds))
        urlRequest.httpMethod = request.method
        for field in request.headers { urlRequest.addValue(field.value, forHTTPHeaderField: field.name) }
        if !request.body.isEmpty { urlRequest.httpBody = request.body }
        let delegate = BrokerSessionDelegate(anchors: extraAnchors)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http, data.prefix(4 << 20))
    }
}

/// Never follows redirects itself (the broker decides), and trusts extra roots when given (tests).
final class BrokerSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let anchors: [Data]
    init(anchors: [Data]) { self.anchors = anchors }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard !anchors.isEmpty, let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        let certificates = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        SecTrustSetAnchorCertificates(trust, certificates as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        return SecTrustEvaluateWithError(trust, nil) ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }
}
