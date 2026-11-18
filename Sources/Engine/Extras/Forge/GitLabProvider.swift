import Foundation
import Synchronization

/// The plain-HTTP instances the person allowed (shared between the service and the provider).
public final class PlainHTTPAllowList: Sendable {
    private let entries = Mutex<Set<String>>([])
    public init() {}
    public func contains(_ baseURL: String) -> Bool { entries.withLock { $0.contains(baseURL) } }
    public func set(_ value: Set<String>) { entries.withLock { $0 = value } }
    public var all: Set<String> { entries.withLock { $0 } }
}

/// Per-instance request discipline shared by every read and write of one provider (docs/features/gitlab.md, "Polling"):
/// at most `limit` requests in flight per instance, and after a 429 the whole instance waits (`Retry-After`, a
/// `RateLimit-Reset`, or an exponential backoff from 30 s to 15 min) before anything else is sent, manual refreshes
/// included. Time is measured on `ContinuousClock` (AGENTS.md rule 21).
actor ForgeGate {
    private let limit: Int
    private var active: [String: Int] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var throttledUntil: [String: Date] = [:]
    private var strikes: [String: Int] = [:]
    private let now: @Sendable () -> Date

    init(limit: Int = 4, now: @escaping @Sendable () -> Date = Date.init) {
        self.limit = limit
        self.now = now
    }

    /// Waits for a slot; throws `rateLimited` (with the remaining wait) while the instance is throttled.
    func acquire(_ instance: String) async throws {
        if let until = throttledUntil[instance] {
            let remaining = until.timeIntervalSince(now())
            if remaining > 0 { throw ForgeError.rateLimited(retryAfter: max(1, remaining.rounded(.up))) }
            throttledUntil[instance] = nil
        }
        if active[instance, default: 0] >= limit {
            await withCheckedContinuation { waiters[instance, default: []].append($0) }
        }
        active[instance, default: 0] += 1
    }

    func release(_ instance: String) {
        active[instance, default: 1] -= 1
        if var queue = waiters[instance], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[instance] = queue
            next.resume()
        }
    }

    /// A 429: the instance waits `after` seconds, or a doubling backoff when GitLab gave none.
    @discardableResult
    func throttle(_ instance: String, after: TimeInterval?) -> TimeInterval {
        let strike = strikes[instance, default: 0] + 1
        strikes[instance] = strike
        let wait = after ?? min(900, 30 * pow(2, Double(strike - 1)))
        throttledUntil[instance] = now().addingTimeInterval(wait)
        return wait
    }

    func succeeded(_ instance: String) { strikes[instance] = nil }

    func remaining(_ instance: String) -> TimeInterval? {
        guard let until = throttledUntil[instance] else { return nil }
        let left = until.timeIntervalSince(now())
        return left > 0 ? left.rounded(.up) : nil
    }
}

/// GitLab REST API v4 (self-managed, with or without a path prefix). Reads and writes with the instance's token
/// (`PRIVATE-TOKEN`, read from the Keychain per request, never stored elsewhere), conditional reads (`If-None-Match` →
/// 304 reuses the cached body), pagination through `X-Next-Page` (bounded), and typed failures. Runs off the main
/// actor; JSON is parsed here.
public struct GitLabProvider: ForgeProvider {
    /// Keychain service of the per-instance tokens (account = the instance's base URL).
    public static let tokenService = "app.bellocode.gitlab-tokens"
    public static let maxPages = 10
    /// Discussions kept in a snapshot (most recent).
    public static let maxDiscussions = 300

    let transport: any ForgeTransport
    let tokens: any SecretVault
    let cache = ForgeCache()
    let gate: ForgeGate
    /// Plain-HTTP instances the person explicitly allowed (Settings ▸ GitLab). Every other `http://` instance is refused
    /// before its token is read.
    let plainHTTPAllowed: PlainHTTPAllowList

    public init(
        transport: any ForgeTransport, tokens: any SecretVault, plainHTTPAllowed: PlainHTTPAllowList = PlainHTTPAllowList(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        gate = ForgeGate(now: now)
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
            pipeline = Pipeline(
                id: id, status: head["status"] as? String ?? "unknown", webURL: head["web_url"] as? String, jobs: jobList.items.map(Self.job),
                sha: head["sha"] as? String)
        }
        let discussionList = try await getPaged("\(project)/merge_requests/\(ref.iid)/discussions?per_page=100", instance)
        if discussionList.truncated { incomplete.append("discussions") }
        let discussions = discussionList.items
        let unresolved = discussions.filter { discussion in
            (discussion["notes"] as? [[String: Any]] ?? []).contains { ($0["resolvable"] as? Bool) == true && ($0["resolved"] as? Bool) == false }
        }.count
        let digests = discussions.map(Self.discussion)
        let state = MergeRequestState(rawValue: mr["state"] as? String ?? "opened") ?? .opened
        var snapshot = MergeRequestSnapshot(
            ref: ref, title: mr["title"] as? String ?? "Merge request !\(ref.iid)", state: state,
            draft: (mr["draft"] as? Bool) ?? (mr["work_in_progress"] as? Bool) ?? false, sourceBranch: mr["source_branch"] as? String ?? "",
            targetBranch: mr["target_branch"] as? String ?? "", author: (mr["author"] as? [String: Any])?["username"] as? String ?? "",
            sha: mr["sha"] as? String ?? "", webURL: mr["web_url"] as? String, pipeline: pipeline, approvals: approvals,
            userNotes: mr["user_notes_count"] as? Int ?? 0, unresolvedDiscussions: unresolved, fetched: now,
            truncated: incomplete.isEmpty ? nil : incomplete)
        snapshot.labels = (mr["labels"] as? [Any])?.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["name"] as? String) }
        snapshot.assignees = (mr["assignees"] as? [[String: Any]])?.compactMap { $0["username"] as? String }
            ?? ((mr["assignee"] as? [String: Any])?["username"] as? String).map { [$0] }
        snapshot.reviewers = (mr["reviewers"] as? [[String: Any]])?.compactMap { $0["username"] as? String }
        snapshot.updatedAt = (mr["updated_at"] as? String).flatMap(Self.date)
        snapshot.mergeStatus = mr["detailed_merge_status"] as? String ?? mr["merge_status"] as? String
        snapshot.discussions = Array(digests.suffix(Self.maxDiscussions))
        snapshot.maxNoteID = digests.flatMap(\.notes).map(\.id).max()
        return snapshot
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

    /// Who the token is, the instance's version and edition, and the token's scopes and expiry, each optional: a
    /// missing `/version` or token-introspection endpoint (older GitLab, a resource token) leaves that part unknown.
    @concurrent
    public func instanceStatus(_ instance: GitLabInstance, previous: GitLabCapabilities = GitLabCapabilities(), now: Date) async throws -> GitLabInstanceStatus {
        let user = try await currentUser(instance)
        var capabilities = previous
        do {
            let parsed = GitLabCapabilities.parse(versionJSON: try Self.object(try await get("version", instance, cached: false)))
            capabilities.version = parsed.version
            capabilities.enterprise = parsed.enterprise
        } catch ForgeError.notFound, ForgeError.forbidden, ForgeError.unexpected {
            capabilities.version = nil
        }
        var token: GitLabTokenInfo?
        if capabilities.support(.tokenIntrospection).mayTry {
            do {
                token = GitLabTokenInfo.parse(try Self.object(try await get("personal_access_tokens/self", instance, cached: false)))
                capabilities.record(.tokenIntrospection, true)
            } catch ForgeError.notFound {
                capabilities.record(.tokenIntrospection, false)
            } catch ForgeError.forbidden, ForgeError.unexpected {
                // A resource token, or a policy that hides it: unknown, not "no expiry".
            }
        }
        return GitLabInstanceStatus(user: user, capabilities: capabilities, token: token, checked: now)
    }

    // MARK: HTTP

    func get(_ path: String, _ instance: GitLabInstance, cached: Bool = true, headers: [String: String] = [:]) async throws -> Data {
        try await response(path, instance, cached: cached, headers: headers).body
    }

    /// Every page (following `X-Next-Page`, at most `maxPages`). `truncated` is true when GitLab still advertised a
    /// next page at the cap: the caller must say the list is incomplete, never present it as complete.
    func getPaged(_ path: String, _ instance: GitLabInstance, maxPages: Int = GitLabProvider.maxPages) async throws -> (items: [[String: Any]], truncated: Bool) {
        var items: [[String: Any]] = []
        var page = 1
        var fetched = 0
        while true {
            let separator = path.contains("?") ? "&" : "?"
            let response = try await response(page == 1 ? path : path + "\(separator)page=\(page)", instance, cached: true)
            items += try Self.array(response.body)
            fetched += 1
            guard let next = response.headers["x-next-page"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), next > page else { break }
            if fetched >= maxPages { return (items, true) }
            page = next
        }
        return (items, false)
    }

    /// One request. Writes (`method` other than GET) are never cached or retried here; a lost connection after sending
    /// is `outcomeUnknown`.
    func response(
        _ path: String, _ instance: GitLabInstance, method: String = "GET", body: Data? = nil, cached: Bool, headers extra: [String: String] = [:],
        tailLimit: Int? = nil
    ) async throws -> ForgeResponse {
        guard let url = URL(string: instance.apiBase + "/" + path) else { throw ForgeError.unexpected("Bad GitLab path.") }
        guard url.scheme == "https" || plainHTTPAllowed.contains(instance.baseURL) else { throw ForgeError.insecureInstance(instance.baseURL) }
        guard let secret = try? tokens.read(account: instance.baseURL), !secret.isEmpty else { throw ForgeError.noToken(instance.baseURL) }
        let key = url.absoluteString
        let useCache = cached && method == "GET"
        var headers = ["PRIVATE-TOKEN": String(decoding: secret.utf8, as: UTF8.self), "Accept": "application/json", "User-Agent": "BelloCode"]
        if body != nil { headers["Content-Type"] = "application/json" }
        for (name, value) in extra { headers[name] = value }
        if useCache, let etag = await cache.etag(key) { headers["If-None-Match"] = etag }
        try await gate.acquire(instance.baseURL)
        let response: ForgeResponse
        do {
            response = try await transport.send(ForgeRequest(url: url, headers: headers, method: method, body: body, tailLimit: tailLimit))
            await gate.release(instance.baseURL)
        } catch {
            await gate.release(instance.baseURL)
            throw error
        }
        switch response.status {
        case 200..<300:
            await gate.succeeded(instance.baseURL)
            if useCache, let etag = response.headers["etag"] { await cache.put(key, etag: etag, body: response.body, headers: response.headers) }
            return response
        case 304:
            guard let entry = await cache.entry(key) else { throw ForgeError.unexpected("GitLab answered 304 without a cached copy.") }
            // The cached pagination headers, unless the 304 carries its own.
            return ForgeResponse(status: 200, headers: entry.headers.merging(response.headers) { _, fresh in fresh }, body: entry.body)
        case 400:
            // A request GitLab refuses as it stands (an invalid diff position, a missing field): its message says why.
            throw ForgeError.unexpected("GitLab refused the request (HTTP 400): \(Self.message(response.body) ?? "no reason given").")
        case 401: throw ForgeError.tokenInvalid(instance.baseURL)
        case 403: throw ForgeError.forbidden
        case 404: throw ForgeError.notFound
        case 405, 409, 422:
            throw ForgeError.conflict(Self.message(response.body) ?? "HTTP \(response.status).")
        case 416:
            return response
        case 429:
            let after = Self.retryAfter(response.headers)
            await gate.throttle(instance.baseURL, after: after)
            throw ForgeError.rateLimited(retryAfter: after)
        default: throw ForgeError.unexpected("GitLab answered HTTP \(response.status).")
        }
    }

    /// A JSON write; returns the parsed object (or an empty one for 204).
    func write(_ method: String, _ path: String, _ instance: GitLabInstance, body: JSONLike?) async throws -> [String: Any] {
        let response = try await response(path, instance, method: method, body: body?.data, cached: false)
        if response.body.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
    }

    /// `Retry-After` (seconds or an HTTP date) or `RateLimit-Reset` (epoch seconds).
    static func retryAfter(_ headers: [String: String], now: Date = Date()) -> TimeInterval? {
        if let value = headers["retry-after"]?.trimmingCharacters(in: .whitespaces) {
            if let seconds = TimeInterval(value) { return max(0, seconds) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now).rounded(.up)) }
        }
        if let reset = headers["ratelimit-reset"].flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespaces)) }) {
            return max(0, reset - now.timeIntervalSince1970)
        }
        return nil
    }

    static func message(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let raw = object["message"] ?? object["error"]
        if let text = raw as? String { return String(text.prefix(300)) }
        if let list = raw as? [String] { return String(list.joined(separator: "; ").prefix(300)) }
        if let map = raw as? [String: Any] { return String(map.map { "\($0.key) \($0.value)" }.joined(separator: "; ").prefix(300)) }
        return nil
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

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func job(_ job: [String: Any]) -> PipelineJob {
        PipelineJob(
            id: job["id"] as? Int ?? 0, name: job["name"] as? String ?? "job", stage: job["stage"] as? String ?? "",
            status: job["status"] as? String ?? "unknown", webURL: job["web_url"] as? String, allowFailure: job["allow_failure"] as? Bool,
            duration: job["duration"] as? Double, failureReason: job["failure_reason"] as? String)
    }

    static func discussion(_ raw: [String: Any]) -> DiscussionDigest {
        let notes = (raw["notes"] as? [[String: Any]] ?? []).map { note in
            NoteDigest(
                id: note["id"] as? Int ?? 0, author: (note["author"] as? [String: Any])?["username"] as? String ?? "",
                body: note["body"] as? String ?? "", system: note["system"] as? Bool ?? false,
                created: (note["created_at"] as? String).flatMap(date), resolvable: note["resolvable"] as? Bool ?? false,
                resolved: note["resolved"] as? Bool ?? false)
        }
        var position: String?
        if let first = (raw["notes"] as? [[String: Any]])?.first, let pos = first["position"] as? [String: Any] {
            let path = pos["new_path"] as? String ?? pos["old_path"] as? String ?? ""
            let line = pos["new_line"] as? Int ?? pos["old_line"] as? Int
            position = path + (line.map { ":\($0)" } ?? "")
        }
        return DiscussionDigest(id: raw["id"] as? String ?? "", notes: notes, position: position, individual: raw["individual_note"] as? Bool ?? false)
    }
}
