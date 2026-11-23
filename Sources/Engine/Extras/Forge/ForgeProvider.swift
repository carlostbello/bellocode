import Foundation
import Synchronization

// The forge layer (docs/features/orchestration-extras.md): a small protocol so the provider is swappable; only GitLab
// is implemented. No CLI: the GitLab REST API v4 over URLSession with a personal or project access token from the
// Keychain, sent only as the `PRIVATE-TOKEN` header. TLS uses the system trust store (a self-managed instance with a
// custom CA works once that CA is trusted in Keychain Access); there is no certificate override.

/// A forge failure, phrased for the person (and the agent). Never contains a token.
public enum ForgeError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The URL's or remote's host is not a configured GitLab instance.
    case noInstance(String)
    case noToken(String)
    /// 401: the token is wrong, expired or revoked.
    case tokenInvalid(String)
    /// 403: the token lacks a scope or access to the project.
    case forbidden
    case notFound
    /// 429; `retryAfter` from the `Retry-After` header.
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    case unexpected(String)
    /// The instance uses plain HTTP and the person has not allowed sending its token unencrypted.
    case insecureInstance(String)
    /// The server redirected to another scheme, host or port; the token was not sent there.
    case redirected(from: String, to: String)
    /// 409 or 405: the merge request (or job) changed, or GitLab refused the operation in its current state.
    case conflict(String)
    /// The TLS handshake failed (untrusted or expired certificate, private CA not trusted).
    case tls(String)
    /// The instance's version or edition does not offer this (`minimum`: the first version that does, when known).
    case unsupported(feature: String, minimum: String?)
    /// A write was asked for while GitLab write actions are off for the instance (Settings ▸ GitLab), or the token's
    /// scopes do not allow it.
    case writesDisabled(String)
    /// A write's outcome is unknown (timeout or lost connection after sending): read back before retrying.
    case outcomeUnknown(String)

    /// A wait in whole seconds for a message, or nil when it is not a finite number (AV2-03: `Int(_:)` of an
    /// infinite or out-of-range Double traps); bounded to a day.
    static func wholeSeconds(_ seconds: TimeInterval?) -> Int? {
        guard let seconds, seconds.isFinite else { return nil }
        return Int(exactly: min(86_400, max(0, seconds)).rounded(.up))
    }

    public var description: String {
        switch self {
        case .noInstance(let host): "\(host) is not a configured GitLab instance. Add it in Settings ▸ GitLab."
        case .noToken(let instance): "No access token for \(instance). Add one in Settings ▸ GitLab."
        case .tokenInvalid(let instance): "The GitLab token for \(instance) is invalid or expired. Replace it in Settings ▸ GitLab."
        case .forbidden: "GitLab refused access (403): the token lacks a scope (read_api for reading, api for changes) or your role does not allow this in the project."
        case .notFound: "Not found on GitLab (404), or hidden from this token: GitLab answers 404 for projects and merge requests you cannot see."
        case .rateLimited(let after): "GitLab's rate limit was reached; BelloCode retries\(Self.wholeSeconds(after).map { " in \($0) s" } ?? " later")."
        case .network(let reason): "GitLab could not be reached: \(reason)"
        case .unexpected(let reason): reason
        case .insecureInstance(let instance):
            "\(instance) uses plain HTTP, so the token would cross the network unencrypted. Use its https:// address, or allow HTTP for it explicitly in Settings ▸ GitLab."
        case .redirected(let from, let to):
            "GitLab at \(from) redirected to \(to); BelloCode does not send the token to another address. Use the address it redirects to as the instance URL if that is intended."
        case .conflict(let reason): "GitLab refused the change because the merge request or job changed (409/405): \(reason) Refresh and check before trying again."
        case .tls(let reason): "The TLS connection to GitLab failed: \(reason)"
        case .unsupported(let feature, let minimum):
            "\(feature) is not available on this GitLab instance" + (minimum.map { " (needs GitLab \($0) or later)" } ?? " (its version or edition does not offer it)") + "."
        case .writesDisabled(let reason): reason
        case .outcomeUnknown(let what):
            "GitLab did not confirm \(what) (the connection failed after sending). It may or may not have happened: refresh and check before retrying."
        }
    }

    /// The failure family the interface explains (auth, permission, not found or hidden, conflict, throttled, offline,
    /// TLS, configuration, unsupported). Status alone is never proof: a 404 may be a hidden project.
    public var kind: ForgeErrorKind {
        switch self {
        case .noInstance, .noToken, .insecureInstance, .redirected, .writesDisabled: .configuration
        case .tokenInvalid: .authentication
        case .forbidden: .permission
        case .notFound: .notFoundOrHidden
        case .conflict, .outcomeUnknown: .conflict
        case .rateLimited: .throttled
        case .network: .offline
        case .tls: .tls
        case .unsupported: .unsupported
        case .unexpected: .other
        }
    }

    /// The person must act (no retry helps).
    public var needsPerson: Bool {
        switch self {
        case .noInstance, .noToken, .tokenInvalid, .forbidden, .insecureInstance, .redirected, .tls: true
        default: false
        }
    }
}

public enum ForgeErrorKind: String, Sendable, Hashable, Codable {
    case configuration, authentication, permission, notFoundOrHidden, conflict, throttled, offline, tls, unsupported, other

    /// Short state word for chips and banners ("Offline", "Token expired", …).
    public var label: String {
        switch self {
        case .configuration: "Not configured"
        case .authentication: "Token invalid or expired"
        case .permission: "No access"
        case .notFoundOrHidden: "Not found or hidden"
        case .conflict: "Changed on GitLab"
        case .throttled: "Rate limited"
        case .offline: "Offline"
        case .tls: "TLS problem"
        case .unsupported: "Not supported"
        case .other: "GitLab error"
        }
    }
}

/// What BelloCode needs from a forge. GitLab only today (`GitLabProvider`).
public protocol ForgeProvider: Sendable {
    func mergeRequest(_ ref: MergeRequestRef, now: Date) async throws -> MergeRequestSnapshot
    /// Open MRs whose source branch is `branch` in `project`.
    func openMergeRequests(_ project: ForgeProject, sourceBranch branch: String) async throws -> [MergeRequestRef]
    /// The token's user (Settings ▸ GitLab "Test").
    func currentUser(_ instance: GitLabInstance) async throws -> String
}

public struct ForgeRequest: Sendable, Hashable {
    public var url: URL
    public var headers: [String: String]
    /// GET, POST, PUT (GitLab REST v4).
    public var method: String
    /// A JSON body for POST/PUT.
    public var body: Data?
    /// Keep only the last `tailLimit` bytes of the body (job logs on servers that ignore byte ranges); the response
    /// then carries `x-bellocode-total-bytes` and, when bytes were dropped, `x-bellocode-truncated: 1`.
    public var tailLimit: Int?
    /// Where a redirect may lead (the instance's API base, `https://host/prefix/api/v4`): the same origin and a path at
    /// or below this one, on every hop. Nil: no redirect is followed. The request carries the instance's token, so a
    /// redirect to another application on the same origin (another path prefix) must not take it there (AV04).
    public var redirectScope: URL?

    public init(
        url: URL, headers: [String: String], method: String = "GET", body: Data? = nil, tailLimit: Int? = nil, redirectScope: URL? = nil
    ) {
        self.url = url
        self.headers = headers
        self.method = method
        self.body = body
        self.tailLimit = tailLimit
        self.redirectScope = redirectScope
    }
}

public struct ForgeResponse: Sendable {
    public var status: Int
    /// Lower-cased names.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        self.body = body
    }
}

/// One HTTP request.
public protocol ForgeTransport: Sendable {
    func send(_ request: ForgeRequest) async throws -> ForgeResponse
}

/// URLSession with an ephemeral configuration: no cookies, no URL cache (ETags are handled by `ForgeCache`), system
/// trust evaluation, no credential store. Redirects (M1 in docs/reviews/M3-M6-review.md, AV04) are followed only within
/// the request's `redirectScope`: the same origin (scheme, host and effective port) and a path at or below the
/// instance's API base, checked on every hop; any other redirect is refused before it is followed, so the token header
/// never travels to another origin, down to HTTP, or to a sibling application under another path prefix of the same
/// origin. The refused 3xx surfaces as `ForgeError.redirected`.
public struct URLSessionForgeTransport: ForgeTransport {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    /// Same scheme, host and effective port.
    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func origin(_ url: URL) -> (String, String, Int)? {
            guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
            let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
            return (scheme, host, port)
        }
        guard let left = origin(a), let right = origin(b) else { return false }
        return left == right
    }

    /// `url` is on `scope`'s origin and its path is `scope`'s path or below it, segment by segment (no `.` or `..`
    /// segment, literal or percent-encoded, anywhere: a server would resolve it out of the scope).
    public static func within(_ scope: URL, _ url: URL) -> Bool {
        guard sameOrigin(scope, url) else { return false }
        func segments(_ url: URL) -> [String]? {
            let parts = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
            for part in parts {
                let decoded = (part.removingPercentEncoding ?? part).lowercased()
                if decoded == "." || decoded == ".." || decoded.contains("/") || decoded.contains("\\") { return nil }
            }
            return parts
        }
        guard var base = segments(scope), let target = segments(url) else { return false }
        if base.last == "" { base.removeLast() }
        return target.count >= base.count && Array(target.prefix(base.count)) == base
    }

    /// Refuses every redirect outside `scope` (nil: every redirect). Used as the session's delegate (no scope) and as
    /// each request's own task delegate (its scope), which takes precedence.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        let scope: URL?
        init(scope: URL? = nil) { self.scope = scope }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let scope, let to = request.url, URLSessionForgeTransport.within(scope, to) else { return nil }
            return request
        }
    }

    public init() {}

    public func send(_ request: ForgeRequest) async throws -> ForgeResponse {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            var data: Data
            let response: URLResponse
            var extra: [String: String] = [:]
            if let limit = request.tailLimit {
                // Streams and keeps only the end: a 50 MB log never sits in memory whole. Reading stops at 32 MB.
                let (bytes, streamed) = try await Self.session.bytes(for: urlRequest, delegate: RedirectGuard(scope: request.redirectScope))
                response = streamed
                data = Data()
                var total = 0
                var chunk = Data()
                chunk.reserveCapacity(64 << 10)
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count >= 64 << 10 {
                        total += chunk.count
                        data.append(chunk)
                        chunk.removeAll(keepingCapacity: true)
                        if data.count > limit * 2 { data = data.suffix(limit) }
                        if total >= 32 << 20 { break }
                    }
                }
                total += chunk.count
                data.append(chunk)
                if data.count > limit { data = data.suffix(limit) }
                extra["x-bellocode-total-bytes"] = String(total)
                if total > data.count { extra["x-bellocode-truncated"] = "1" }
            } else {
                (data, response) = try await Self.session.data(for: urlRequest, delegate: RedirectGuard(scope: request.redirectScope))
            }
            guard let http = response as? HTTPURLResponse else { throw ForgeError.unexpected("No HTTP response.") }
            if (300..<400).contains(http.statusCode), http.statusCode != 304 {
                let location = http.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: request.url)?.absoluteURL }
                let target = location.map { "\($0.scheme ?? "")://\($0.host() ?? "")\($0.port.map { ":\($0)" } ?? "")" } ?? "another address"
                throw ForgeError.redirected(from: "\(request.url.scheme ?? "")://\(request.url.host() ?? "")\(request.url.port.map { ":\($0)" } ?? "")", to: target)
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
            headers.merge(extra) { _, ours in ours }
            return ForgeResponse(status: http.statusCode, headers: headers, body: data)
        } catch let error as URLError {
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .secureConnectionFailed,
                .clientCertificateRejected, .clientCertificateRequired:
                throw ForgeError.tls("\(request.url.host() ?? "the server")'s certificate is not trusted by this Mac (expired, or signed by a private CA). Trust the instance's CA in Keychain Access (System trust store); BelloCode never bypasses certificate checks.")
            case .timedOut where request.method != "GET", .networkConnectionLost where request.method != "GET":
                throw ForgeError.outcomeUnknown("the change")
            default:
                throw ForgeError.network(error.localizedDescription)
            }
        }
    }
}

/// Recorded responses by full URL (no network), for tests and mock mode. Each URL answers its queue in order (the
/// last repeats); a matching `If-None-Match` gets a 304. Records each request with whether a token was sent (never
/// the token itself).
public final class FixtureForgeTransport: ForgeTransport {
    public struct Recorded: Sendable, Hashable {
        public var url: String
        public var etag: String?
        public var hadToken: Bool
        public var method: String = "GET"
        public var body: String?
        /// Request headers other than the token (never recorded).
        public var range: String?
    }

    private let state = Mutex<(responses: [String: [ForgeResponse]], requests: [Recorded])>(([:], []))

    public init() {}

    public func set(_ url: String, _ responses: [ForgeResponse]) { state.withLock { $0.responses[url] = responses } }

    public func setJSON(_ url: String, _ json: String, etag: String? = nil, headers: [String: String] = [:]) {
        var all = headers
        if let etag { all["etag"] = etag }
        set(url, [ForgeResponse(status: 200, headers: all, body: Data(json.utf8))])
    }

    public var requests: [Recorded] { state.withLock { $0.requests } }

    public func send(_ request: ForgeRequest) async throws -> ForgeResponse {
        let url = request.url.absoluteString
        let key = request.method == "GET" ? url : request.method + " " + url
        return try state.withLock { state in
            let etag = request.headers["If-None-Match"]
            state.requests.append(
                Recorded(
                    url: url, etag: etag, hadToken: request.headers["PRIVATE-TOKEN"] != nil, method: request.method,
                    body: request.body.map { String(decoding: $0, as: UTF8.self) }, range: request.headers["Range"]))
            guard var queue = state.responses[key], let first = queue.first else { return ForgeResponse(status: 404, body: Data(#"{"message":"404 Not found"}"#.utf8)) }
            if queue.count > 1 {
                queue.removeFirst()
                state.responses[key] = queue
            }
            if first.status == 599 { throw ForgeError.network("connection lost") }
            if let etag, etag == first.headers["etag"], first.status == 200 { return ForgeResponse(status: 304, headers: ["etag": etag]) }
            return first
        }
    }
}

/// Bounded ETag cache: URL → (etag, body, pagination headers). A 304 reuses the body *and* the pagination state it
/// was stored with (M2 in docs/reviews/M3-M6-review.md: a 304 need not repeat `X-Next-Page`, and without it a
/// revalidated first page used to end the listing there).
actor ForgeCache {
    struct Entry {
        var etag: String
        var body: Data
        var headers: [String: String]
    }

    /// The response headers kept with a cached body.
    static let paginationHeaders = ["x-next-page", "x-page", "x-per-page", "x-total", "x-total-pages", "link"]

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 256) { self.limit = limit }

    func etag(_ url: String) -> String? { entries[url]?.etag }
    func entry(_ url: String) -> Entry? { entries[url] }

    func put(_ url: String, etag: String, body: Data, headers: [String: String]) {
        if entries[url] == nil { order.append(url) }
        entries[url] = Entry(etag: etag, body: body, headers: headers.filter { Self.paginationHeaders.contains($0.key) })
        while order.count > limit { entries[order.removeFirst()] = nil }
    }
}
