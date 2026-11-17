import Foundation
import Synchronization

/// GitLab REST API v4 (gitlab.com or self-managed, with or without a path prefix). Reads with the instance's token
/// (`PRIVATE-TOKEN`), conditional requests (`If-None-Match` → 304 reuses the cached body), pagination through
/// `X-Next-Page` (bounded), and typed failures (401 token invalid, 403, 404, 429 with `Retry-After`). Runs off the main
/// actor; JSON is parsed here.
/// The plain-HTTP instances the person allowed (shared between the service and the provider).
public final class PlainHTTPAllowList: Sendable {
    private let entries = Mutex<Set<String>>([])
    public init() {}
    public func contains(_ baseURL: String) -> Bool { entries.withLock { $0.contains(baseURL) } }
    public func set(_ value: Set<String>) { entries.withLock { $0 = value } }
    public var all: Set<String> { entries.withLock { $0 } }
}

public struct GitLabProvider: ForgeProvider {
    /// Keychain service of the per-instance tokens (account = the instance's base URL).
    public static let tokenService = "app.bellocode.gitlab-tokens"
    public static let maxPages = 10

    let transport: any ForgeTransport
    let tokens: any SecretVault
    let cache = ForgeCache()
    /// Plain-HTTP instances the person explicitly allowed (Settings ▸ GitLab). Every other `http://` instance is refused
    /// before its token is read.
    let plainHTTPAllowed: PlainHTTPAllowList

    public init(transport: any ForgeTransport, tokens: any SecretVault, plainHTTPAllowed: PlainHTTPAllowList = PlainHTTPAllowList()) {
        self.transport = transport
        self.tokens = tokens
        self.plainHTTPAllowed = plainHTTPAllowed
    }

    // MARK: Reads

    @concurrent
    public func mergeRequest(_ ref: MergeRequestRef, now: Date) async throws -> MergeRequestSnapshot {
        guard let instance = GitLabInstance(baseURL: ref.instance) else { throw ForgeError.noInstance(ref.instance) }
        let project = "projects/" + Self.encode(ref.projectPath)
        let mr = try Self.object(try await get("\(project)/merge_requests/\(ref.iid)", instance))
        var approvals = MergeRequestApprovals()
        do {
            let raw = try Self.object(try await get("\(project)/merge_requests/\(ref.iid)/approvals", instance))
            approvals = MergeRequestApprovals(
                approved: raw["approved"] as? Bool ?? false, required: raw["approvals_required"] as? Int ?? 0, left: raw["approvals_left"] as? Int ?? 0,
                approvedBy: (raw["approved_by"] as? [[String: Any]] ?? []).compactMap { ($0["user"] as? [String: Any])?["username"] as? String })
        } catch ForgeError.notFound, ForgeError.forbidden {
            // Approvals are not available on every edition or token: the section says "No approvals".
        }
        var pipeline: Pipeline?
        var incomplete: [String] = []
        if let head = mr["head_pipeline"] as? [String: Any] ?? mr["pipeline"] as? [String: Any], let id = head["id"] as? Int {
            let jobList = try await getPaged("projects/\(Self.encode(ref.projectPath))/pipelines/\(id)/jobs?per_page=100", instance)
            if jobList.truncated { incomplete.append("pipeline jobs") }
            let jobs = jobList.items.map { job in
                PipelineJob(
                    id: job["id"] as? Int ?? 0, name: job["name"] as? String ?? "job", stage: job["stage"] as? String ?? "",
                    status: job["status"] as? String ?? "unknown", webURL: job["web_url"] as? String)
            }
            pipeline = Pipeline(id: id, status: head["status"] as? String ?? "unknown", webURL: head["web_url"] as? String, jobs: jobs)
        }
        let discussionList = try await getPaged("\(project)/merge_requests/\(ref.iid)/discussions?per_page=100", instance)
        if discussionList.truncated { incomplete.append("discussions") }
        let discussions = discussionList.items
        let unresolved = discussions.filter { discussion in
            (discussion["notes"] as? [[String: Any]] ?? []).contains { ($0["resolvable"] as? Bool) == true && ($0["resolved"] as? Bool) == false }
        }.count
        let state = MergeRequestState(rawValue: mr["state"] as? String ?? "opened") ?? .opened
        return MergeRequestSnapshot(
            ref: ref, title: mr["title"] as? String ?? "Merge request !\(ref.iid)", state: state,
            draft: (mr["draft"] as? Bool) ?? (mr["work_in_progress"] as? Bool) ?? false, sourceBranch: mr["source_branch"] as? String ?? "",
            targetBranch: mr["target_branch"] as? String ?? "", author: (mr["author"] as? [String: Any])?["username"] as? String ?? "",
            sha: mr["sha"] as? String ?? "", webURL: mr["web_url"] as? String, pipeline: pipeline, approvals: approvals,
            userNotes: mr["user_notes_count"] as? Int ?? 0, unresolvedDiscussions: unresolved, fetched: now,
            truncated: incomplete.isEmpty ? nil : incomplete)
    }

    @concurrent
    public func openMergeRequests(_ project: ForgeProject, sourceBranch branch: String) async throws -> [MergeRequestRef] {
        let query = "state=opened&source_branch=" + Self.encode(branch)
        let list = try await getPaged("projects/\(Self.encode(project.projectPath))/merge_requests?\(query)&per_page=20", project.instance).items
        return list.compactMap { ($0["iid"] as? Int).map { MergeRequestRef(instance: project.instance.baseURL, projectPath: project.projectPath, iid: $0) } }
    }

    @concurrent
    public func currentUser(_ instance: GitLabInstance) async throws -> String {
        let user = try Self.object(try await get("user", instance, cached: false))
        return user["username"] as? String ?? "unknown"
    }

    // MARK: HTTP

    func get(_ path: String, _ instance: GitLabInstance, cached: Bool = true) async throws -> Data {
        try await response(path, instance, cached: cached).body
    }

    /// Every page (following `X-Next-Page`, at most `maxPages`). `truncated` is true when GitLab still advertised a
    /// next page at the cap: the caller must say the list is incomplete, never present it as complete.
    func getPaged(_ path: String, _ instance: GitLabInstance) async throws -> (items: [[String: Any]], truncated: Bool) {
        var items: [[String: Any]] = []
        var page = 1
        var fetched = 0
        while true {
            let separator = path.contains("?") ? "&" : "?"
            let response = try await response(page == 1 ? path : path + "\(separator)page=\(page)", instance, cached: true)
            items += try Self.array(response.body)
            fetched += 1
            guard let next = response.headers["x-next-page"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), next > page else { break }
            if fetched >= Self.maxPages { return (items, true) }
            page = next
        }
        return (items, false)
    }

    private func response(_ path: String, _ instance: GitLabInstance, cached: Bool) async throws -> ForgeResponse {
        guard let url = URL(string: instance.apiBase + "/" + path) else { throw ForgeError.unexpected("Bad GitLab path.") }
        guard url.scheme == "https" || plainHTTPAllowed.contains(instance.baseURL) else { throw ForgeError.insecureInstance(instance.baseURL) }
        guard let secret = try? tokens.read(account: instance.baseURL), !secret.isEmpty else { throw ForgeError.noToken(instance.baseURL) }
        let key = url.absoluteString
        var headers = ["PRIVATE-TOKEN": String(decoding: secret.utf8, as: UTF8.self), "Accept": "application/json", "User-Agent": "BelloCode"]
        if cached, let etag = await cache.etag(key) { headers["If-None-Match"] = etag }
        let response = try await transport.send(ForgeRequest(url: url, headers: headers))
        switch response.status {
        case 200..<300:
            if cached, let etag = response.headers["etag"] { await cache.put(key, etag: etag, body: response.body, headers: response.headers) }
            return response
        case 304:
            guard let entry = await cache.entry(key) else { throw ForgeError.unexpected("GitLab answered 304 without a cached copy.") }
            // The cached pagination headers, unless the 304 carries its own.
            return ForgeResponse(status: 200, headers: entry.headers.merging(response.headers) { _, fresh in fresh }, body: entry.body)
        case 401: throw ForgeError.tokenInvalid(instance.baseURL)
        case 403: throw ForgeError.forbidden
        case 404: throw ForgeError.notFound
        case 429: throw ForgeError.rateLimited(retryAfter: response.headers["retry-after"].flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
        default: throw ForgeError.unexpected("GitLab answered HTTP \(response.status).")
        }
    }

    /// A project path or branch as one URL path segment / query value (`/` → `%2F`).
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? text
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ForgeError.unexpected("GitLab returned something unexpected.") }
        return value
    }

    static func array(_ data: Data) throws -> [[String: Any]] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ForgeError.unexpected("GitLab returned something unexpected.") }
        return value
    }
}
