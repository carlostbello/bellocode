import BelloCore
import Foundation

/// One header line, in order (names compared case-insensitively).
public struct HTTPField: Sendable, Hashable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

extension Array where Element == HTTPField {
    public func first(_ name: String) -> String? { first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
    public func all(_ name: String) -> [String] { filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value) }
    public mutating func remove(_ name: String) { removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    public mutating func set(_ name: String, _ value: String) {
        remove(name)
        append(HTTPField(name, value))
    }
}

/// A request as the proxy or broker sees it: destination plus an origin-form target and a complete body.
public struct OutboundRequest: Sendable {
    public var method: String
    public var scheme: String
    public var host: String
    public var port: Int
    /// `/path?query` (origin form, as sent).
    public var target: String
    public var headers: [HTTPField]
    public var body: Data

    public init(method: String, scheme: String, host: String, port: Int, target: String, headers: [HTTPField], body: Data = Data()) {
        self.method = method.uppercased()
        self.scheme = scheme.lowercased()
        self.host = SecretBinding.canonicalHost(host)
        self.port = port
        self.target = target.isEmpty ? "/" : target
        self.headers = headers
        self.body = body
    }

    public var origin: String {
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(host)" + (port == defaultPort ? "" : ":\(port)")
    }

    public var rawPath: String { String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "/") }
    public var rawQuery: String? {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts[1]) : nil
    }

    /// For the audit: origin and path, never the query.
    public var auditDestination: String { origin + (RequestPath.normalized(rawPath) ?? "/…") }
}

/// Path checks for bound destinations: an allowlisted prefix must mean what it says.
public enum RequestPath {
    /// The path with percent-encoded unreserved characters decoded, or nil when it is ambiguous: dot segments, encoded
    /// slashes or backslashes, encoded dots, NUL, or anything not starting with `/`. Ambiguous paths are never used
    /// with a secret (servers and proxies disagree about them).
    public static func normalized(_ raw: String) -> String? {
        guard raw.hasPrefix("/") else { return nil }
        let lower = raw.lowercased()
        for bad in ["%2f", "%5c", "%2e", "%00", "\\", "%25"] where lower.contains(bad) { return nil }
        guard let decoded = raw.removingPercentEncoding else { return nil }
        let segments = decoded.split(separator: "/", omittingEmptySubsequences: false)
        if segments.contains(where: { $0 == "." || $0 == ".." }) { return nil }
        if decoded.contains("//") { return nil }
        return decoded
    }
}

/// Why the proxy or broker refused a request. The text goes to the agent (as the response body), so it names the rule,
/// never a value.
public enum SecretRefusal: Sendable, Hashable {
    case unknownPlaceholder
    case unboundDestination(label: String, origin: String)
    case methodNotAllowed(label: String, method: String)
    case pathNotAllowed(label: String)
    case ambiguousPath(label: String)
    case locationNotAllowed(label: String, location: String)
    case fragment
    case encodedPlaceholder
    case expired(label: String)
    case useLimit(label: String)
    case revoked(label: String)
    case wrongProject(label: String)
    case notPlaceholderMode(label: String)
    case plainHTTP(label: String)
    case unsupportedBody(label: String)
    case upgrade
    case tooLarge

    public var code: String {
        switch self {
        case .unknownPlaceholder: "unknown-placeholder"
        case .unboundDestination: "unbound-destination"
        case .methodNotAllowed: "method-not-allowed"
        case .pathNotAllowed: "path-not-allowed"
        case .ambiguousPath: "ambiguous-path"
        case .locationNotAllowed: "location-not-allowed"
        case .fragment: "placeholder-fragment"
        case .encodedPlaceholder: "encoded-placeholder"
        case .expired: "expired"
        case .useLimit: "use-limit"
        case .revoked: "revoked"
        case .wrongProject: "wrong-project"
        case .notPlaceholderMode: "not-placeholder"
        case .plainHTTP: "plain-http"
        case .unsupportedBody: "unsupported-body"
        case .upgrade: "upgrade-refused"
        case .tooLarge: "too-large"
        }
    }

    public var message: String {
        switch self {
        case .unknownPlaceholder: "This placeholder is unknown or was revoked. Ask the user for the secret again with request_secret."
        case .unboundDestination(let label, let origin): "The placeholder for “\(label)” may not be sent to \(origin): it is not one of its bound destinations. BelloCode refused the request; the secret's value never left the Mac."
        case .methodNotAllowed(let label, let method): "The binding of “\(label)” does not allow \(method) requests."
        case .pathNotAllowed(let label): "The binding of “\(label)” does not allow this path."
        case .ambiguousPath(let label): "The path is ambiguous (dot segments or encoded slashes), so “\(label)” is not used with it."
        case .locationNotAllowed(let label, let location): "The placeholder for “\(label)” is in a place its binding does not allow (\(location)). Put it only where the binding says (Settings ▸ Secrets)."
        case .fragment: "The request contains part of a placeholder (split, truncated or altered). Send placeholders whole, exactly as given."
        case .encodedPlaceholder: "The request contains an encoded placeholder. Send placeholders unencoded, only where their binding allows."
        case .expired(let label): "The binding of “\(label)” has expired."
        case .useLimit(let label): "“\(label)” reached its use limit."
        case .revoked(let label): "“\(label)” was revoked."
        case .wrongProject(let label): "“\(label)” is not available to this project."
        case .notPlaceholderMode(let label): "“\(label)” is not a placeholder secret."
        case .plainHTTP(let label): "“\(label)” is never sent over plain http."
        case .unsupportedBody(let label): "The request body type cannot carry “\(label)”; its binding allows JSON or form fields only."
        case .upgrade: "Protocol upgrades (WebSocket, h2c) to a destination that receives secrets cannot be inspected and are refused."
        case .tooLarge: "The request is too large for BelloCode's proxy to inspect."
        }
    }
}

/// What the proxy or broker knows about one placeholder: the grant, its secret and the value (held only in memory).
public struct ResolvedPlaceholder: Sendable {
    public var grant: PlaceholderGrant
    public var secret: ManagedSecret
    public var value: SecretValue
    /// Whether the secret's current scope admits the grant's project (R13). The brokered tool checks scope itself.
    public var scopeAdmits = true

    public init(grant: PlaceholderGrant, secret: ManagedSecret, value: SecretValue) {
        self.grant = grant
        self.secret = secret
        self.value = value
    }
}

/// A substitution that happened (for use counting and the audit).
public struct SubstitutionUse: Sendable, Hashable {
    public var account: String
    public var bindingID: String
    public var sessionID: String
    public var placeholder: String

    public init(account: String, bindingID: String, sessionID: String, placeholder: String) {
        self.account = account
        self.bindingID = bindingID
        self.sessionID = sessionID
        self.placeholder = placeholder
    }
}

public enum RewriteDecision: Sendable {
    /// No placeholder: forward as is.
    case unchanged
    case substituted(OutboundRequest, [SubstitutionUse])
    case refused(SecretRefusal, account: String?, sessionID: String?)
}

/// The substitution rules (docs/features/secrets.md "Binding rules"). Pure: given a request and how to resolve
/// placeholders, decides to forward unchanged, substitute, or refuse.
public struct RequestRewriter: Sendable {
    /// Projects the request's gateway serves; nil: any (the brokered tool, which checks the caller itself).
    public var admitsProject: (@Sendable (String) -> Bool)?
    public var now: Date
    /// Uses so far of (account, binding id), from the shared ledger (R12); nil: the secret's own `uses`.
    public var useCount: (@Sendable (String, String) -> Int)?

    public init(admitsProject: (@Sendable (String) -> Bool)? = nil, now: Date = Date(), useCount: (@Sendable (String, String) -> Int)? = nil) {
        self.admitsProject = admitsProject
        self.now = now
        self.useCount = useCount
    }

    public func rewrite(_ request: OutboundRequest, resolve: (String) -> ResolvedPlaceholder?) -> RewriteDecision {
        let targetData = Data(request.target.utf8)
        let headerData = request.headers.map { Data(($0.name + ":" + $0.value).utf8) }
        var all: [String] = []
        var fragments = 0
        for part in [targetData] + headerData + [request.body] {
            let (found, broken) = Placeholder.find(in: part)
            all += found
            fragments += broken
        }
        // Basic credentials hide their password in base64: decode before looking for encoded prefixes.
        let basic = Self.basicCredentials(request.headers)
        for credential in basic {
            let (found, broken) = Placeholder.find(in: Data(credential.decoded.utf8))
            all += found
            fragments += broken
        }
        if fragments > 0 { return .refused(.fragment, account: nil, sessionID: nil) }
        var encodedCheck = [targetData, request.body] + request.headers.filter { field in
            !(field.name.caseInsensitiveCompare("Authorization") == .orderedSame && field.value.lowercased().hasPrefix("basic "))
        }.map { Data($0.value.utf8) }
        if let decodedTarget = request.target.removingPercentEncoding { encodedCheck.append(Data(decodedTarget.utf8)) }
        if encodedCheck.contains(where: Placeholder.containsEncodedPrefix) {
            return .refused(.encodedPlaceholder, account: nil, sessionID: nil)
        }
        guard !all.isEmpty else { return .unchanged }

        var resolved: [String: ResolvedPlaceholder] = [:]
        for placeholder in Set(all) {
            guard let entry = resolve(placeholder) else { return .refused(.unknownPlaceholder, account: nil, sessionID: nil) }
            resolved[placeholder] = entry
        }
        var output = request
        var uses: [SubstitutionUse] = []
        for (placeholder, entry) in resolved.sorted(by: { $0.key < $1.key }) {
            let secret = entry.secret
            let refuse = { (reason: SecretRefusal) -> RewriteDecision in .refused(reason, account: secret.account, sessionID: entry.grant.sessionID) }
            if secret.revoked { return refuse(.revoked(label: secret.label)) }
            guard secret.mode == .placeholder else { return refuse(.notPlaceholderMode(label: secret.label)) }
            if !entry.scopeAdmits { return refuse(.wrongProject(label: secret.label)) }
            if let admitsProject, !admitsProject(entry.grant.projectDirectory) { return refuse(.wrongProject(label: secret.label)) }
            let origins = secret.bindings.filter { $0.matchesOrigin(scheme: request.scheme, host: request.host, port: request.port) }
            guard !origins.isEmpty else { return refuse(.unboundDestination(label: secret.label, origin: request.origin)) }
            if request.scheme != "https", !origins.contains(where: { $0.scheme == "http" }) { return refuse(.plainHTTP(label: secret.label)) }
            guard let path = RequestPath.normalized(request.rawPath) else { return refuse(.ambiguousPath(label: secret.label)) }
            let methodOK = origins.filter { $0.allows(method: request.method) }
            guard !methodOK.isEmpty else { return refuse(.methodNotAllowed(label: secret.label, method: request.method)) }
            let pathOK = methodOK.filter { $0.allows(path: path) }
            guard !pathOK.isEmpty else { return refuse(.pathNotAllowed(label: secret.label)) }
            let live = pathOK.filter { $0.expires.map { $0 > now } ?? true }
            guard !live.isEmpty else { return refuse(.expired(label: secret.label)) }
            let available = live.filter { binding in
                binding.maxUses.map { (useCount?(secret.account, binding.id) ?? secret.uses[binding.id] ?? 0) < $0 } ?? true
            }
            guard let binding = available.first else { return refuse(.useLimit(label: secret.label)) }
            switch Self.substitute(placeholder, value: entry.value, in: output, allowed: binding.locations) {
            case .failure(let location): return refuse(location.text == "body type"
                ? .unsupportedBody(label: secret.label) : .locationNotAllowed(label: secret.label, location: location.text))
            case .success(let rewritten):
                output = rewritten
                uses.append(SubstitutionUse(account: secret.account, bindingID: binding.id, sessionID: entry.grant.sessionID, placeholder: placeholder))
            }
        }
        // Content-Length follows the body; framing headers are the forwarder's.
        output.headers.remove("Content-Length")
        if !output.body.isEmpty || ["POST", "PUT", "PATCH"].contains(output.method) {
            output.headers.append(HTTPField("Content-Length", String(output.body.count)))
        }
        return .substituted(output, uses)
    }

    /// Substitutes every occurrence of `placeholder`, each of which must be in an allowed location; the first
    /// occurrence that is not is the failure.
    static func substitute(_ placeholder: String, value: SecretValue, in request: OutboundRequest, allowed: [SecretLocation]) -> Result<OutboundRequest, LocationErrorText> {
        var out = request
        let valueText = String(decoding: value.utf8, as: UTF8.self)
        // Target: only exact query parameter values.
        if out.target.contains(placeholder) {
            let names = allowed.filter { $0.kind == .query }.map(\.name)
            guard let query = out.rawQuery else { return .failure(LocationErrorText("the URL path")) }
            var items = query.split(separator: "&", omittingEmptySubsequences: false).map(String.init)
            for (index, item) in items.enumerated() where item.contains(placeholder) {
                let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, String(pair[1]) == placeholder,
                      let name = String(pair[0]).removingPercentEncoding, names.contains(name)
                else { return .failure(LocationErrorText("the URL")) }
                items[index] = String(pair[0]) + "=" + percentEncode(value.utf8)
            }
            if out.rawPath.contains(placeholder) { return .failure(LocationErrorText("the URL path")) }
            out.target = out.rawPath + "?" + items.joined(separator: "&")
        }
        // Headers: exact `prefix + placeholder`, or Basic credentials' password.
        for index in out.headers.indices {
            let field = out.headers[index]
            if field.name.contains(placeholder) { return .failure(LocationErrorText("a header name")) }
            if field.name.caseInsensitiveCompare("Authorization") == .orderedSame, field.value.lowercased().hasPrefix("basic "),
               let decoded = basicDecoded(field.value), decoded.contains(placeholder) {
                guard allowed.contains(where: { $0.kind == .basicAuthPassword }) else { return .failure(LocationErrorText("Basic credentials")) }
                let parts = decoded.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, String(parts[1]) == placeholder, !parts[0].contains(placeholder) else {
                    return .failure(LocationErrorText("Basic credentials"))
                }
                let replaced = Data((String(parts[0]) + ":").utf8) + value.utf8
                out.headers[index].value = "Basic " + replaced.base64EncodedString()
                continue
            }
            guard field.value.contains(placeholder) else { continue }
            let value = field.value.trimmingCharacters(in: .whitespaces)
            let match = allowed.first { location in
                location.kind == .header && location.name.caseInsensitiveCompare(field.name) == .orderedSame
                    && value == location.prefix + placeholder
            }
            guard let match else { return .failure(LocationErrorText("header \(field.name)")) }
            out.headers[index].value = match.prefix + valueText
        }
        // Body: JSON or form fields whose whole value is the placeholder.
        let rawCount = ByteSearch.count(out.body, Data(placeholder.utf8))
        if rawCount > 0 {
            let type = (out.headers.first("Content-Type") ?? "").lowercased()
            let encoding = (out.headers.first("Content-Encoding") ?? "identity").lowercased()
            guard encoding == "identity" else { return .failure(LocationErrorText("body type")) }
            if type.hasPrefix("application/json") || type.contains("+json") {
                let names = allowed.filter { $0.kind == .jsonField }.map(\.name)
                guard !names.isEmpty, let json = try? JSONSerialization.jsonObject(with: out.body, options: [.fragmentsAllowed]) else {
                    return .failure(names.isEmpty ? LocationErrorText("the body") : LocationErrorText("body type"))
                }
                let matches = names.reduce(0) { $0 + jsonMatches(json, path: $1.split(separator: ".").map(String.init), placeholder: placeholder) }
                guard matches == rawCount, ByteSearch.count(out.body, Data("\"\(placeholder)\"".utf8)) == rawCount else {
                    return .failure(LocationErrorText("the JSON body"))
                }
                let escaped = jsonEscaped(valueText)
                out.body = ByteSearch.replaceAll(out.body, Data("\"\(placeholder)\"".utf8), with: Data("\"\(escaped)\"".utf8)).0
            } else if type.hasPrefix("application/x-www-form-urlencoded") {
                let names = allowed.filter { $0.kind == .formField }.map(\.name)
                let text = String(decoding: out.body, as: UTF8.self)
                var items = text.split(separator: "&", omittingEmptySubsequences: false).map(String.init)
                var matched = 0
                for (index, item) in items.enumerated() where item.contains(placeholder) {
                    let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pair.count == 2, String(pair[1]) == placeholder,
                          let name = String(pair[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding, names.contains(name)
                    else { return .failure(LocationErrorText("the form body")) }
                    items[index] = String(pair[0]) + "=" + percentEncode(value.utf8)
                    matched += 1
                }
                guard matched == rawCount else { return .failure(LocationErrorText("the form body")) }
                out.body = Data(items.joined(separator: "&").utf8)
            } else {
                return .failure(LocationErrorText(allowed.contains { $0.kind == .jsonField || $0.kind == .formField } ? "body type" : "the body"))
            }
        }
        // Nothing may remain (a placeholder in a place none of the rules above handled).
        if out.target.contains(placeholder) || out.headers.contains(where: { $0.value.contains(placeholder) })
            || ByteSearch.contains(out.body, Data(placeholder.utf8)) {
            return .failure(LocationErrorText("the request"))
        }
        return .success(out)
    }

    struct LocationErrorText: Error, Sendable {
        var text: String
        init(_ text: String) { self.text = text }
    }

    static func jsonMatches(_ json: Any, path: [String], placeholder: String) -> Int {
        guard let first = path.first else { return (json as? String) == placeholder ? 1 : 0 }
        guard let object = json as? [String: Any], let next = object[first] else { return 0 }
        return jsonMatches(next, path: Array(path.dropFirst()), placeholder: placeholder)
    }

    static func jsonEscaped(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst(2).dropLast(2))
    }

    static func percentEncode(_ data: Data) -> String {
        var out = ""
        for byte in data {
            if Placeholder.isBase62(byte) || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E {
                out.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    struct BasicCredential {
        var decoded: String
    }

    static func basicCredentials(_ headers: [HTTPField]) -> [BasicCredential] {
        headers.all("Authorization").compactMap { value in
            value.lowercased().hasPrefix("basic ") ? basicDecoded(value).map(BasicCredential.init) : nil
        }
    }

    static func basicDecoded(_ value: String) -> String? {
        let encoded = value.dropFirst(6).trimmingCharacters(in: .whitespaces)
        return Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) }
    }
}
