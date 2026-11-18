import BelloCore
import Foundation
import Synchronization

/// An in-process GitLab (REST v4 subset BelloCode uses) for tests, mock mode and snapshots: no network. Stateful
/// (writes change what later reads return), paginated with `X-Next-Page`, ETag/304 like a caching proxy (a 304 carries
/// no pagination headers), byte ranges on job logs when enabled, a version switch (a missing `/version`, an instance
/// older than 15.5 without token introspection, Free without approval rules), and queued forced failures (401, 403,
/// 404, 409, 429 …). It checks the `PRIVATE-TOKEN` header and records each request (never the token).
public final class FakeGitLabServer: ForgeTransport {
    public struct Options: Sendable {
        /// nil: `/version` answers 404.
        public var version: String? = "17.4.1-ee"
        public var tokenIntrospection = true
        /// `approval_state` answers (Premium); false: 404 like Free.
        public var approvalRules = false
        /// Job logs honour `Range: bytes=-N` (206).
        public var rangeSupport = true
        /// `/diffs` exists (15.7+); false: only `/changes`.
        public var diffsEndpoint = true
        /// Items per page the server returns at most.
        public var pageSize = 100
        public var etags = true

        public init() {}
    }

    public struct Note: Sendable {
        public var id: Int
        public var author: String
        public var body: String
        public var system = false
        public var resolvable = true
        public var resolved = false
        public var position: (path: String, line: Int)?
        public var created = "2026-11-17T10:00:00Z"

        public init(id: Int, author: String, body: String, system: Bool = false, resolvable: Bool = true, resolved: Bool = false, position: (path: String, line: Int)? = nil) {
            self.id = id
            self.author = author
            self.body = body
            self.system = system
            self.resolvable = resolvable
            self.resolved = resolved
            self.position = position
        }
    }

    public struct Discussion: Sendable {
        public var id: String
        public var notes: [Note]
        public init(id: String, notes: [Note]) {
            self.id = id
            self.notes = notes
        }
    }

    public struct Job: Sendable {
        public var id: Int
        public var name: String
        public var stage: String
        public var status: String
        public var allowFailure = false
        public var duration: Double? = 42
        public var failureReason: String?
        public init(id: Int, name: String, stage: String, status: String, allowFailure: Bool = false, failureReason: String? = nil) {
            self.id = id
            self.name = name
            self.stage = stage
            self.status = status
            self.allowFailure = allowFailure
            self.failureReason = failureReason
        }
    }

    public struct MR: Sendable {
        public var iid: Int
        public var title: String
        public var description = ""
        public var state = "opened"
        public var source: String
        public var target = "main"
        public var author = "octo"
        public var sha = "9f2c1ab4e5d6"
        public var labels: [String] = []
        public var assignees: [String] = []
        public var reviewers: [String] = []
        public var approvedBy: [String] = []
        public var approvalsRequired = 0
        public var pipelineID: Int?
        public var pipelineStatus = "running"
        public var discussions: [Discussion] = []
        public var diffs: [(old: String, new: String, diff: String)] = []
        public var updatedAt = "2026-11-17T10:00:00Z"

        public init(iid: Int, title: String, source: String) {
            self.iid = iid
            self.title = title
            self.source = source
        }
    }

    public struct Project: Sendable {
        public var id: Int
        public var path: String
        public var defaultBranch = "main"
        public var branches: [String] = ["main"]
        public var members: [GitLabUserRef] = []
        public var mrs: [Int: MR] = [:]
        /// Git parity: protected branches (`repository/branches/:name` reports `protected`).
        public var protectedBranches: Set<String> = []
        public var name: String?
        public var lastActivity = "2026-11-17T10:00:00.000Z"
        public var jobs: [Int: [Job]] = [:]
        public var traces: [Int: String] = [:]
        public init(id: Int, path: String) {
            self.id = id
            self.path = path
        }
    }

    public struct Recorded: Sendable, Hashable {
        public var method: String
        /// The path after `/api/v4/`, query included.
        public var path: String
        public var hadToken: Bool
        public var etag: String?
        public var range: String?
        public var body: String?
    }

    struct State {
        var options: Options
        var projects: [String: Project] = [:]
        var failures: [(match: String, response: ForgeResponse)] = []
        var requests: [Recorded] = []
        var nextID = 50_000
    }

    public let instance: GitLabInstance
    public let token: String
    public let username: String
    private let state: Mutex<State>

    public init(instance: GitLabInstance, token: String, username: String = "me", options: Options = Options()) {
        self.instance = instance
        self.token = token
        self.username = username
        state = Mutex(State(options: options))
    }

    // MARK: Setup

    public func update(_ change: (inout Options) -> Void) { state.withLock { change(&$0.options) } }
    public func put(_ project: Project) { state.withLock { $0.projects[project.path] = project } }
    public func edit(_ path: String, _ change: (inout Project) -> Void) { state.withLock { if var p = $0.projects[path] { change(&p); $0.projects[path] = p } } }
    public func editMR(_ path: String, _ iid: Int, _ change: (inout MR) -> Void) {
        edit(path) { project in if var mr = project.mrs[iid] { change(&mr); project.mrs[iid] = mr } }
    }
    public func project(_ path: String) -> Project? { state.withLock { $0.projects[path] } }
    /// The next request whose `METHOD path` contains `match` answers `response` (once).
    public func fail(_ match: String, _ response: ForgeResponse) { state.withLock { $0.failures.append((match, response)) } }
    public func fail(_ match: String, status: Int, headers: [String: String] = [:]) {
        fail(match, ForgeResponse(status: status, headers: headers, body: Data(#"{"message":"\#(status)"}"#.utf8)))
    }
    public var requests: [Recorded] { state.withLock { $0.requests } }
    public func clearRequests() { state.withLock { $0.requests.removeAll() } }

    // MARK: Transport

    public func send(_ request: ForgeRequest) async throws -> ForgeResponse {
        let url = request.url.absoluteString
        guard url.hasPrefix(instance.apiBase + "/") else { return Self.json(404, ["message": "404 Not found"]) }
        let path = String(url.dropFirst(instance.apiBase.count + 1))
        let response = state.withLock { state -> ForgeResponse in
            state.requests.append(
                Recorded(
                    method: request.method, path: path, hadToken: request.headers["PRIVATE-TOKEN"] != nil, etag: request.headers["If-None-Match"],
                    range: request.headers["Range"], body: request.body.map { String(decoding: $0, as: UTF8.self) }))
            if let index = state.failures.firstIndex(where: { (request.method + " " + path).contains($0.match) }) {
                return state.failures.remove(at: index).response
            }
            guard request.headers["PRIVATE-TOKEN"] == token else { return Self.json(401, ["message": "401 Unauthorized"]) }
            return route(&state, request.method, path, body: request.body, headers: request.headers)
        }
        if response.status == 599 { throw ForgeError.network("connection lost") }
        var final = response
        if let limit = request.tailLimit, final.body.count > limit {
            final.headers["x-bellocode-total-bytes"] = String(final.body.count)
            final.headers["x-bellocode-truncated"] = "1"
            final.body = final.body.suffix(limit)
        }
        return final
    }

    static func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> ForgeResponse {
        ForgeResponse(status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
    }

    private func route(_ state: inout State, _ method: String, _ full: String, body: Data?, headers: [String: String]) -> ForgeResponse {
        let parts = full.split(separator: "?", maxSplits: 1)
        let path = String(parts[0])
        var query: [String: String] = [:]
        if parts.count > 1 {
            for item in parts[1].split(separator: "&") {
                let pair = item.split(separator: "=", maxSplits: 1)
                query[String(pair[0])] = pair.count > 1 ? String(pair[1]).removingPercentEncoding ?? String(pair[1]) : ""
            }
        }
        let input = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let segments = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let options = state.options
        switch (method, segments.first ?? "") {
        case ("GET", "user"): return Self.json(200, ["id": 1, "username": username, "name": "Me"])
        case ("GET", "version"):
            guard let version = options.version else { return Self.json(404, ["message": "404 Not found"]) }
            return Self.json(200, ["version": version, "revision": "abc"])
        case ("GET", "personal_access_tokens"):
            guard options.tokenIntrospection else { return Self.json(404, ["message": "404 Not found"]) }
            return Self.json(200, ["id": 7, "name": "bellocode", "scopes": ["api", "read_api"], "active": true, "revoked": false, "expires_at": "2026-12-01"])
        // Git parity: clone picker, namespaces and publish.
        case ("GET", "projects") where segments.count == 1:
            let search = (query["search"] ?? "").lowercased()
            let items = state.projects.values.sorted { $0.lastActivity > $1.lastActivity }
                .filter { search.isEmpty || $0.path.lowercased().contains(search) }.map { projectJSON($0) }
            return Self.json(200, items)
        case ("GET", "namespaces"):
            return Self.json(200, [["id": 1, "full_path": username, "kind": "user"], ["id": 2, "full_path": "team", "kind": "group"]])
        case ("POST", "projects") where segments.count == 1:
            guard let name = input["name"] as? String else { return Self.json(400, ["message": "name is missing"]) }
            let slug = input["path"] as? String ?? name.lowercased()
            let namespace = (input["namespace_id"] as? Int) == 2 ? "team" : username
            let path = namespace + "/" + slug
            if state.projects[path] != nil { return Self.json(400, ["message": ["path": ["has already been taken"]]]) }
            state.nextID += 1
            var created = Project(id: state.nextID, path: path)
            created.name = name
            created.branches = []
            state.projects[path] = created
            return Self.json(201, projectJSON(created))
        case (_, "projects"): break
        default: return Self.json(404, ["message": "404 Not found"])
        }
        guard segments.count >= 2, var project = state.projects[segments[1]] else { return Self.json(404, ["message": "404 Project Not Found"]) }
        defer { state.projects[project.path] = project }
        let rest = Array(segments.dropFirst(2))
        func page(_ items: [Any]) -> ForgeResponse {
            let size = min(options.pageSize, Int(query["per_page"] ?? "20") ?? 20)
            let number = Int(query["page"] ?? "1") ?? 1
            let slice = Array(items.dropFirst((number - 1) * size).prefix(size))
            var headers: [String: String] = [:]
            if items.count > number * size { headers["X-Next-Page"] = String(number + 1) }
            return etagged(Self.json(200, slice, headers: headers))
        }
        func etagged(_ response: ForgeResponse) -> ForgeResponse {
            guard options.etags, method == "GET" else { return response }
            let tag = "W/\"\(response.body.hashValue)\""
            if headers["If-None-Match"] == tag { return ForgeResponse(status: 304, headers: ["etag": tag]) }
            var copy = response
            copy.headers["etag"] = tag
            return copy
        }
        switch (method, rest.first ?? "") {
        case ("GET", ""):
            return etagged(Self.json(200, ["id": project.id, "path_with_namespace": project.path, "default_branch": project.defaultBranch, "web_url": "\(instance.baseURL)/\(project.path)"]))
        case ("GET", "repository") where rest.count >= 3 && rest[1] == "branches":
            let name = rest.dropFirst(2).joined(separator: "/")
            guard project.branches.contains(name) else { return Self.json(404, ["message": "404 Branch Not Found"]) }
            let isProtected = project.protectedBranches.contains(name)
            return Self.json(200, ["name": name, "protected": isProtected, "can_push": !isProtected, "default": name == project.defaultBranch])
        case ("GET", "repository"):
            let search = query["search"] ?? ""
            return page(project.branches.filter { search.isEmpty || $0.contains(search) }.map { ["name": $0] })
        case ("GET", "users"):
            let search = (query["search"] ?? "").lowercased()
            return page(project.members.filter { $0.username.lowercased().contains(search) || $0.name.lowercased().contains(search) }.map { ["id": $0.id, "username": $0.username, "name": $0.name] })
        case ("GET", "pipelines") where rest.count >= 3 && rest[2] == "jobs":
            guard let id = Int(rest[1]), let jobs = project.jobs[id] else { return Self.json(404, ["message": "404 Not found"]) }
            return page(jobs.sorted { $0.id > $1.id }.map { jobJSON($0, project) })
        case ("GET", "jobs") where rest.count >= 3 && rest[2] == "trace":
            guard let id = Int(rest[1]), let trace = project.traces[id] else { return Self.json(404, ["message": "404 Not found"]) }
            let data = Data(trace.utf8)
            if options.rangeSupport, let range = headers["Range"], range.hasPrefix("bytes=-"), let count = Int(range.dropFirst(7)) {
                let tail = data.suffix(count)
                return ForgeResponse(status: 206, headers: ["Content-Range": "bytes \(data.count - tail.count)-\(data.count - 1)/\(data.count)"], body: tail)
            }
            return ForgeResponse(status: 200, headers: ["Content-Type": "text/plain"], body: data)
        case ("POST", "jobs") where rest.count >= 3:
            guard let id = Int(rest[1]) else { return Self.json(404, ["message": "404 Not found"]) }
            for (pipeline, jobs) in project.jobs {
                guard let index = jobs.firstIndex(where: { $0.id == id }) else { continue }
                var job = jobs[index]
                if rest[2] == "play" {
                    guard job.status == "manual" else { return Self.json(400, ["message": "Unplayable Job"]) }
                    job.status = "pending"
                    project.jobs[pipeline]![index] = job
                    return Self.json(200, jobJSON(job, project))
                }
                guard ["failed", "canceled", "success"].contains(job.status) else { return Self.json(403, ["message": "403 Forbidden - Job is not retryable"]) }
                state.nextID += 1
                let retried = Job(id: state.nextID, name: job.name, stage: job.stage, status: "pending")
                project.jobs[pipeline]!.append(retried)
                return Self.json(201, jobJSON(retried, project))
            }
            return Self.json(404, ["message": "404 Not found"])
        case ("GET", "merge_requests") where rest.count == 1:
            let source = query["source_branch"]
            let items = project.mrs.values.filter { (query["state"] == nil || $0.state == query["state"]) && (source == nil || $0.source == source) }
                .sorted { $0.iid > $1.iid }.map { mrJSON($0, project, options) }
            return page(items)
        case ("POST", "merge_requests") where rest.count == 1:
            guard let source = input["source_branch"] as? String, let target = input["target_branch"] as? String, let title = input["title"] as? String else {
                return Self.json(400, ["message": "missing fields"])
            }
            if project.mrs.values.contains(where: { $0.source == source && $0.target == target && $0.state == "opened" }) {
                return Self.json(409, ["message": ["Another open merge request already exists for this source branch"]])
            }
            let iid = (project.mrs.keys.max() ?? 0) + 1
            var mr = MR(iid: iid, title: title, source: source)
            mr.target = target
            mr.description = input["description"] as? String ?? ""
            mr.author = username
            mr.pipelineID = nil
            mr.assignees = (input["assignee_ids"] as? [Int] ?? []).compactMap { id in project.members.first { $0.id == id }?.username }
            mr.reviewers = (input["reviewer_ids"] as? [Int] ?? []).compactMap { id in project.members.first { $0.id == id }?.username }
            project.mrs[iid] = mr
            return Self.json(201, mrJSON(mr, project, options))
        case (_, "merge_requests"):
            guard rest.count >= 2, let iid = Int(rest[1]), var mr = project.mrs[iid] else { return Self.json(404, ["message": "404 Not found"]) }
            defer { project.mrs[iid] = mr }
            let sub = rest.count > 2 ? rest[2] : ""
            switch (method, sub) {
            case ("GET", ""): return etagged(Self.json(200, mrJSON(mr, project, options)))
            case ("PUT", ""):
                if let title = input["title"] as? String { mr.title = title }
                if let description = input["description"] as? String { mr.description = description }
                return Self.json(200, mrJSON(mr, project, options))
            case ("GET", "approvals"):
                return etagged(Self.json(200, [
                    "approved": mr.approvedBy.count >= max(1, mr.approvalsRequired), "approvals_required": mr.approvalsRequired,
                    "approvals_left": max(0, mr.approvalsRequired - mr.approvedBy.count),
                    "approved_by": mr.approvedBy.map { ["user": ["username": $0]] },
                ]))
            case ("GET", "approval_state"):
                guard options.approvalRules else { return Self.json(404, ["message": "404 Not found"]) }
                return Self.json(200, ["rules": [
                    ["name": "Backend", "rule_type": "regular", "approvals_required": max(1, mr.approvalsRequired), "approved_by": mr.approvedBy.map { ["username": $0] }, "approved": mr.approvedBy.count >= max(1, mr.approvalsRequired)],
                    ["name": "CODEOWNERS", "rule_type": "code_owner", "section": "src/parser/", "approvals_required": 1, "approved_by": [], "approved": false],
                ]])
            case ("GET", "discussions"):
                return page(mr.discussions.map { discussionJSON($0) })
            case ("POST", "discussions") where rest.count >= 5 && rest[4] == "notes":
                guard let index = mr.discussions.firstIndex(where: { $0.id == rest[3] }), let text = input["body"] as? String else { return Self.json(404, ["message": "404 Not found"]) }
                state.nextID += 1
                mr.discussions[index].notes.append(Note(id: state.nextID, author: username, body: text))
                return Self.json(201, ["id": state.nextID, "body": text])
            case ("PUT", "discussions") where rest.count >= 4:
                guard let index = mr.discussions.firstIndex(where: { $0.id == rest[3] }) else { return Self.json(404, ["message": "404 Not found"]) }
                let resolved = (input["resolved"] as? Bool) ?? (query["resolved"] == "true")
                for note in mr.discussions[index].notes.indices where mr.discussions[index].notes[note].resolvable { mr.discussions[index].notes[note].resolved = resolved }
                return Self.json(200, discussionJSON(mr.discussions[index]))
            case ("GET", "diffs"):
                guard options.diffsEndpoint else { return Self.json(404, ["message": "404 Not found"]) }
                return page(mr.diffs.map { ["old_path": $0.old, "new_path": $0.new, "diff": $0.diff, "new_file": false, "deleted_file": false, "renamed_file": $0.old != $0.new] })
            case ("GET", "changes"):
                return Self.json(200, ["changes": mr.diffs.map { ["old_path": $0.old, "new_path": $0.new, "diff": $0.diff] }, "overflow": false])
            case ("POST", "approve"):
                guard (input["sha"] as? String) == mr.sha else { return Self.json(409, ["message": "SHA does not match HEAD of source branch"]) }
                if !mr.approvedBy.contains(username) { mr.approvedBy.append(username) }
                return Self.json(201, ["approved": true])
            case ("PUT", "merge"):
                guard (input["sha"] as? String) == mr.sha else { return Self.json(409, ["message": "SHA does not match HEAD of source branch"]) }
                mr.state = "merged"
                return Self.json(200, mrJSON(mr, project, options))
            default: return Self.json(404, ["message": "404 Not found"])
            }
        default:
            return Self.json(404, ["message": "404 Not found"])
        }
    }

    private func projectJSON(_ project: Project) -> [String: Any] {
        ["id": project.id, "path_with_namespace": project.path, "name": project.name ?? (project.path as NSString).lastPathComponent,
         "http_url_to_repo": "\(instance.baseURL)/\(project.path).git", "web_url": "\(instance.baseURL)/\(project.path)",
         "default_branch": project.defaultBranch, "last_activity_at": project.lastActivity]
    }

    private func web(_ project: Project) -> String { "\(instance.baseURL)/\(project.path)" }

    private func jobJSON(_ job: Job, _ project: Project) -> [String: Any] {
        var object: [String: Any] = [
            "id": job.id, "name": job.name, "stage": job.stage, "status": job.status, "allow_failure": job.allowFailure,
            "web_url": "\(web(project))/-/jobs/\(job.id)",
        ]
        if let duration = job.duration { object["duration"] = duration }
        if let reason = job.failureReason { object["failure_reason"] = reason }
        return object
    }

    private func mrJSON(_ mr: MR, _ project: Project, _ options: Options) -> [String: Any] {
        var object: [String: Any] = [
            "id": project.id * 1000 + mr.iid, "iid": mr.iid, "project_id": project.id, "title": mr.title, "description": mr.description, "state": mr.state,
            "source_branch": mr.source, "target_branch": mr.target, "author": ["username": mr.author], "sha": mr.sha,
            "web_url": "\(web(project))/-/merge_requests/\(mr.iid)", "labels": mr.labels, "assignees": mr.assignees.map { ["username": $0] },
            "updated_at": mr.updatedAt, "user_notes_count": mr.discussions.flatMap(\.notes).filter { !$0.system }.count,
            "merge_status": "can_be_merged",
        ]
        if let version = options.version.flatMap(GitLabVersion.init) {
            if version >= GitLabVersion(major: 14, minor: 0) { object["draft"] = mr.title.hasPrefix("Draft:") } else { object["work_in_progress"] = mr.title.hasPrefix("Draft:") }
            if version >= GitLabVersion(major: 13, minor: 8) { object["reviewers"] = mr.reviewers.map { ["username": $0] } }
            if version >= GitLabVersion(major: 15, minor: 6) { object["detailed_merge_status"] = mr.state == "opened" ? "mergeable" : "not_open" }
        } else {
            object["draft"] = mr.title.hasPrefix("Draft:")
        }
        if let pipeline = mr.pipelineID {
            object["head_pipeline"] = ["id": pipeline, "status": mr.pipelineStatus, "sha": mr.sha, "web_url": "\(web(project))/-/pipelines/\(pipeline)"]
        }
        return object
    }

    private func discussionJSON(_ discussion: Discussion) -> [String: Any] {
        [
            "id": discussion.id, "individual_note": discussion.notes.count == 1 && !discussion.notes[0].resolvable,
            "notes": discussion.notes.map { note in
                var object: [String: Any] = [
                    "id": note.id, "author": ["username": note.author], "body": note.body, "system": note.system, "resolvable": note.resolvable,
                    "created_at": note.created,
                ]
                if note.resolvable { object["resolved"] = note.resolved }
                if let position = note.position { object["position"] = ["new_path": position.path, "new_line": position.line, "position_type": "text"] }
                return object
            },
        ]
    }
}
