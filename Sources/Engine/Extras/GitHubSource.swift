import Foundation
import Synchronization

// How BelloCode reads GitHub (docs/features/orchestration-extras.md): the `gh` CLI when it is installed and signed in
// (its own stored credentials; BelloCode never sees or stores a token), else the unauthenticated REST API (public
// repositories, 60 requests an hour), else a "connect GitHub" state. Every read is a REST GET with an ETag, so
// unchanged resources cost a 304. Runs off the main actor; tests use `FixtureGitHubTransport` (no network).

/// How GitHub is reachable now, phrased for the person.
public enum GitHubAccess: Hashable, Sendable {
    /// `gh` is signed in: private repositories work.
    case cli
    /// No signed-in `gh`: public repositories only, with a low rate limit.
    case publicAPI
    case unavailable(String)

    public var label: String {
        switch self {
        case .cli: "GitHub via the GitHub CLI (gh)"
        case .publicAPI: "Public GitHub only. Sign in with the GitHub CLI (gh auth login) for private repositories."
        case .unavailable(let reason): "GitHub unavailable: \(reason)"
        }
    }
}

public struct GitHubResponse: Sendable {
    public var status: Int
    public var etag: String?
    public var body: Data

    public init(status: Int, etag: String? = nil, body: Data = Data()) {
        self.status = status
        self.etag = etag
        self.body = body
    }
}

public enum GitHubError: Error, Sendable, Hashable, CustomStringConvertible {
    /// 404: missing, or private without access.
    case notFound
    case unauthorized
    case rateLimited
    case failed(String)

    public var description: String {
        switch self {
        case .notFound: "Not found. If the repository is private, sign in with the GitHub CLI (gh auth login)."
        case .unauthorized: "GitHub refused access. Sign in again with the GitHub CLI (gh auth login)."
        case .rateLimited: "GitHub's rate limit was reached; BelloCode will retry later."
        case .failed(let reason): reason
        }
    }
}

/// One REST GET (path relative to `https://api.github.com/`).
public protocol GitHubTransport: Sendable {
    func get(_ path: String, etag: String?) async throws -> GitHubResponse
}

/// Decides the transport. Re-resolved after failures (gh may have been installed or signed in meanwhile).
public protocol GitHubAccessProvider: Sendable {
    func resolve() async -> (access: GitHubAccess, transport: (any GitHubTransport)?)
}

/// `gh` if signed in, else the public API.
public struct SystemGitHubAccess: GitHubAccessProvider {
    static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    public init() {}

    public func resolve() async -> (access: GitHubAccess, transport: (any GitHubTransport)?) {
        if let path = Self.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let gh = URL(fileURLWithPath: path)
            let runner = GitRunner()
            let status = try? await runner.runProgram(
                gh, ["auth", "status", "--hostname", "github.com"], in: NSTemporaryDirectory(), timeout: .seconds(10), outputLimit: 64 << 10)
            if status?.status == 0 { return (.cli, GHCLITransport(executable: gh)) }
        }
        return (.publicAPI, PublicGitHubTransport())
    }
}

/// `gh api -i …`: gh adds its own credentials. Output is headers, a blank line, then the body.
public struct GHCLITransport: GitHubTransport {
    public var executable: URL

    public init(executable: URL) { self.executable = executable }

    public func get(_ path: String, etag: String?) async throws -> GitHubResponse {
        var arguments = ["api", "-i", "-H", "Accept: application/vnd.github+json"]
        if let etag { arguments += ["-H", "If-None-Match: \(etag)"] }
        arguments.append(path)
        let output = try await GitRunner().runProgram(
            executable, arguments, in: NSTemporaryDirectory(), environment: ["GH_PROMPT_DISABLED": "1", "NO_COLOR": "1"],
            timeout: .seconds(20), outputLimit: 8 << 20)
        return try Self.parse(output.stdout)
    }

    static func parse(_ data: Data) throws -> GitHubResponse {
        let separator = Data("\r\n\r\n".utf8)
        let altSeparator = Data("\n\n".utf8)
        let range = data.range(of: separator) ?? data.range(of: altSeparator)
        let headerData = range.map { data[..<$0.lowerBound] } ?? data
        let body = range.map { Data(data[$0.upperBound...]) } ?? Data()
        let lines = String(decoding: headerData, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP"),
            let status = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) })
        else { throw GitHubError.failed("The GitHub CLI returned an unexpected answer.") }
        var etag: String?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "etag" {
                etag = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return GitHubResponse(status: status, etag: etag, body: body)
    }
}

/// Unauthenticated `https://api.github.com` (public repositories).
public struct PublicGitHubTransport: GitHubTransport {
    public init() {}

    public func get(_ path: String, etag: String?) async throws -> GitHubResponse {
        guard let url = URL(string: "https://api.github.com/" + path) else { throw GitHubError.failed("Bad GitHub path.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BelloCode", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.failed("No HTTP response.") }
        return GitHubResponse(status: http.statusCode, etag: http.value(forHTTPHeaderField: "ETag"), body: data)
    }
}

/// Recorded responses by path, for tests: each path answers its queue in order (the last one repeats). Records every
/// request with the ETag it sent.
public final class FixtureGitHubTransport: GitHubTransport, GitHubAccessProvider {
    private let state = Mutex<(responses: [String: [GitHubResponse]], requests: [(String, String?)])>(([:], []))
    public let access: GitHubAccess

    public init(access: GitHubAccess = .cli) { self.access = access }

    public func set(_ path: String, _ responses: [GitHubResponse]) { state.withLock { $0.responses[path] = responses } }

    public func setJSON(_ path: String, _ json: String, etag: String? = nil) {
        set(path, [GitHubResponse(status: 200, etag: etag, body: Data(json.utf8))])
    }

    public var requests: [(path: String, etag: String?)] { state.withLock { $0.requests } }

    public func get(_ path: String, etag: String?) async throws -> GitHubResponse {
        try state.withLock { state in
            state.requests.append((path, etag))
            guard var queue = state.responses[path], let first = queue.first else { return GitHubResponse(status: 404) }
            if queue.count > 1 {
                queue.removeFirst()
                state.responses[path] = queue
            }
            if first.status == 599 { throw GitHubError.failed("network down") }
            // A matching ETag gets a 304, as GitHub does.
            if let etag, etag == first.etag { return GitHubResponse(status: 304, etag: etag) }
            return first
        }
    }

    public func resolve() async -> (access: GitHubAccess, transport: (any GitHubTransport)?) { (access, self) }
}

/// Bounded ETag cache: path → (etag, body). 304 answers reuse the body.
actor GitHubCache {
    private var entries: [String: (etag: String, body: Data)] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 256) { self.limit = limit }

    func get(_ path: String, via transport: any GitHubTransport) async throws -> Data {
        let cached = entries[path]
        let response = try await transport.get(path, etag: cached?.etag)
        switch response.status {
        case 304:
            if let cached { return cached.body }
            throw GitHubError.failed("GitHub answered 304 without a cached copy.")
        case 200..<300:
            if let etag = response.etag { put(path, etag: etag, body: response.body) }
            return response.body
        case 404: throw GitHubError.notFound
        case 401: throw GitHubError.unauthorized
        case 403, 429: throw GitHubError.rateLimited
        default: throw GitHubError.failed("GitHub answered HTTP \(response.status).")
        }
    }

    private func put(_ path: String, etag: String, body: Data) {
        if entries[path] == nil { order.append(path) }
        entries[path] = (etag, body)
        while order.count > limit { entries[order.removeFirst()] = nil }
    }
}

/// Reads a PR's snapshot (three ETag'd GETs) and a branch's open PRs.
struct PullRequestFetcher: Sendable {
    let cache: GitHubCache

    func snapshot(_ ref: PullRequestRef, via transport: any GitHubTransport, now: Date) async throws -> PullRequestSnapshot {
        let base = "repos/\(ref.owner)/\(ref.repo)"
        let pull = try Self.object(try await cache.get("\(base)/pulls/\(ref.number)", via: transport))
        let head = pull["head"] as? [String: Any] ?? [:]
        let sha = head["sha"] as? String ?? ""
        let merged = (pull["merged"] as? Bool) == true || pull["merged_at"] is String
        let state: PullRequestState =
            merged ? .merged : (pull["state"] as? String) == "closed" ? .closed : (pull["draft"] as? Bool) == true ? .draft : .open
        var checks: [CheckRun] = []
        if !sha.isEmpty {
            let body = try Self.object(try await cache.get("\(base)/commits/\(sha)/check-runs?per_page=100", via: transport))
            checks = (body["check_runs"] as? [[String: Any]] ?? []).map(Self.check)
        }
        let reviews = try Self.array(try await cache.get("\(base)/pulls/\(ref.number)/reviews?per_page=100", via: transport)).map { review in
            PullRequestReview(
                id: review["id"] as? Int ?? 0, author: (review["user"] as? [String: Any])?["login"] as? String ?? "someone",
                state: review["state"] as? String ?? "COMMENTED")
        }
        return PullRequestSnapshot(
            ref: ref, title: pull["title"] as? String ?? "Pull request #\(ref.number)", state: state, headSHA: sha,
            headBranch: head["ref"] as? String ?? "", baseBranch: (pull["base"] as? [String: Any])?["ref"] as? String ?? "",
            author: (pull["user"] as? [String: Any])?["login"] as? String ?? "", checks: checks, reviews: reviews,
            reviewComments: pull["review_comments"] as? Int ?? 0, comments: pull["comments"] as? Int ?? 0,
            mergeable: pull["mergeable"] as? Bool, fetched: now)
    }

    /// Open PRs whose head is `branch` in `owner/repo` (same-repository branches).
    func openPullRequests(owner: String, repo: String, branch: String, via transport: any GitHubTransport) async throws -> [PullRequestRef] {
        let escaped = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))) ?? branch
        let list = try Self.array(try await cache.get("repos/\(owner)/\(repo)/pulls?state=open&head=\(owner):\(escaped)", via: transport))
        return list.compactMap { ($0["number"] as? Int).map { PullRequestRef(owner: owner, repo: repo, number: $0) } }
    }

    static func check(_ raw: [String: Any]) -> CheckRun {
        let status: CheckRun.Status =
            switch raw["status"] as? String {
            case "completed": .completed
            case "in_progress": .inProgress
            default: .queued
            }
        let conclusion: CheckRun.Conclusion? = (raw["conclusion"] as? String).map {
            switch $0 {
            case "success": .success
            case "failure": .failure
            case "neutral": .neutral
            case "cancelled": .cancelled
            case "skipped": .skipped
            case "timed_out": .timedOut
            case "action_required": .actionRequired
            case "stale": .stale
            default: .unknown
            }
        }
        return CheckRun(
            id: raw["id"] as? Int ?? 0, name: raw["name"] as? String ?? "check", status: status, conclusion: conclusion,
            url: raw["html_url"] as? String)
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.failed("GitHub returned something unexpected.")
        }
        return value
    }

    static func array(_ data: Data) throws -> [[String: Any]] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError.failed("GitHub returned something unexpected.")
        }
        return value
    }
}

/// `owner/repo` of a GitHub remote URL (`git@github.com:o/r.git`, `https://github.com/o/r`, `ssh://git@github.com/o/r`).
enum GitHubRemote {
    static func parse(_ url: String) -> (owner: String, repo: String)? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "github.com") else { return nil }
        var rest = trimmed[range.upperBound...]
        while let first = rest.first, first == ":" || first == "/" { rest = rest.dropFirst() }
        let parts = rest.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        var repo = String(parts[1])
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        guard !parts[0].isEmpty, !repo.isEmpty else { return nil }
        return (String(parts[0]), repo)
    }
}
