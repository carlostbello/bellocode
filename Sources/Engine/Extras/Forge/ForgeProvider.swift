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

    public var description: String {
        switch self {
        case .noInstance(let host): "\(host) is not a configured GitLab instance. Add it in Settings ▸ GitLab."
        case .noToken(let instance): "No access token for \(instance). Add one in Settings ▸ GitLab."
        case .tokenInvalid(let instance): "The GitLab token for \(instance) is invalid or expired. Replace it in Settings ▸ GitLab."
        case .forbidden: "GitLab refused access: the token needs the read_api scope and access to this project."
        case .notFound: "Not found on GitLab (or the token cannot see it)."
        case .rateLimited(let after): "GitLab's rate limit was reached; BelloCode retries\(after.map { " in \(Int($0)) s" } ?? " later")."
        case .network(let reason): "GitLab could not be reached: \(reason)"
        case .unexpected(let reason): reason
        case .insecureInstance(let instance):
            "\(instance) uses plain HTTP, so the token would cross the network unencrypted. Use its https:// address, or allow HTTP for it explicitly in Settings ▸ GitLab."
        case .redirected(let from, let to):
            "GitLab at \(from) redirected to \(to); BelloCode does not send the token to another address. Use the address it redirects to as the instance URL if that is intended."
        }
    }

    /// The person must act (no retry helps).
    public var needsPerson: Bool {
        switch self {
        case .noInstance, .noToken, .tokenInvalid, .forbidden, .insecureInstance, .redirected: true
        default: false
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

/// One HTTP GET.
public protocol ForgeTransport: Sendable {
    func send(_ request: ForgeRequest) async throws -> ForgeResponse
}

/// URLSession with an ephemeral configuration: no cookies, no URL cache (ETags are handled by `ForgeCache`), system
/// trust evaluation, no credential store. Redirects (M1 in docs/reviews/M3-M6-review.md) are followed only within the
/// same origin (scheme, host and effective port); any other redirect is refused before it is followed, so the token
/// header never travels to another origin or down to HTTP. The refused 3xx surfaces as `ForgeError.redirected`.
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

    final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let from = task.originalRequest?.url, let to = request.url, URLSessionForgeTransport.sameOrigin(from, to) else { return nil }
            return request
        }
    }

    public init() {}

    public func send(_ request: ForgeRequest) async throws -> ForgeResponse {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await Self.session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw ForgeError.unexpected("No HTTP response.") }
            if (300..<400).contains(http.statusCode), http.statusCode != 304 {
                let location = http.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: request.url)?.absoluteURL }
                let target = location.map { "\($0.scheme ?? "")://\($0.host() ?? "")\($0.port.map { ":\($0)" } ?? "")" } ?? "another address"
                throw ForgeError.redirected(from: "\(request.url.scheme ?? "")://\(request.url.host() ?? "")\(request.url.port.map { ":\($0)" } ?? "")", to: target)
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
            return ForgeResponse(status: http.statusCode, headers: headers, body: data)
        } catch let error as URLError {
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .secureConnectionFailed:
                throw ForgeError.network("its TLS certificate is not trusted by this Mac. Trust the instance's CA in Keychain Access.")
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
        let key = request.url.absoluteString
        return try state.withLock { state in
            let etag = request.headers["If-None-Match"]
            state.requests.append(Recorded(url: key, etag: etag, hadToken: request.headers["PRIVATE-TOKEN"] != nil))
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

/// Bounded ETag cache: URL → (etag, body). A 304 reuses the body.
actor ForgeCache {
    private var entries: [String: (etag: String, body: Data)] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 256) { self.limit = limit }

    func etag(_ url: String) -> String? { entries[url]?.etag }
    func body(_ url: String) -> Data? { entries[url]?.body }

    func put(_ url: String, etag: String, body: Data) {
        if entries[url] == nil { order.append(url) }
        entries[url] = (etag, body)
        while order.count > limit { entries[order.removeFirst()] = nil }
    }
}
