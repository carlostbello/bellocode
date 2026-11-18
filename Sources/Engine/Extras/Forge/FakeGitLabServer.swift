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
        /// `M/draft_notes` exists (a review is published as one); false: 404 like an instance without it.
        public var draftNotes = true
        /// `M/blocks` and `M/blockees` (Premium dependencies); false: 404.
        public var dependencies = false
        /// `issues/:iid/related_merge_requests` exists.
        public var relatedMergeRequests = true

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
        /// A full diff position (SHAs, both paths, old/new line, range); wins over `position`.
        public var diffPosition: Position?
        /// Where the thread was first written (`original_position`).
        public var originalPosition: Position?
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

    /// A note's diff position as GitLab returns it.
    public struct Position: Sendable, Hashable {
        public var base: String
        public var start: String
        public var head: String
        public var oldPath: String
        public var newPath: String
        public var oldLine: Int?
        public var newLine: Int?
        /// `line_range.start` numbers (old, new), when a range.
        public var rangeStart: (old: Int?, new: Int?)?
        public var type = "text"

        public init(base: String, start: String, head: String, oldPath: String, newPath: String, oldLine: Int? = nil, newLine: Int? = nil, rangeStart: (old: Int?, new: Int?)? = nil) {
            self.base = base
            self.start = start
            self.head = head
            self.oldPath = oldPath
            self.newPath = newPath
            self.oldLine = oldLine
            self.newLine = newLine
            self.rangeStart = rangeStart
        }

        public static func == (a: Self, b: Self) -> Bool {
            a.base == b.base && a.start == b.start && a.head == b.head && a.oldPath == b.oldPath && a.newPath == b.newPath && a.oldLine == b.oldLine
                && a.newLine == b.newLine && a.type == b.type && a.rangeStart?.old == b.rangeStart?.old && a.rangeStart?.new == b.rangeStart?.new
        }

        public func hash(into hasher: inout Hasher) { hasher.combine(head); hasher.combine(newPath); hasher.combine(newLine) }

        var json: [String: Any] {
            var object: [String: Any] = [
                "base_sha": base, "start_sha": start, "head_sha": head, "old_path": oldPath, "new_path": newPath, "position_type": type,
                "old_line": oldLine as Any? ?? NSNull(), "new_line": newLine as Any? ?? NSNull(),
            ]
            if let rangeStart {
                var start: [String: Any] = [:]
                if let old = rangeStart.old { start["old_line"] = old }
                if let new = rangeStart.new { start["new_line"] = new }
                var end: [String: Any] = [:]
                if let oldLine { end["old_line"] = oldLine }
                if let newLine { end["new_line"] = newLine }
                object["line_range"] = ["start": start, "end": end]
            }
            return object
        }

        static func parse(_ raw: [String: Any]?) -> Position? {
            guard let raw, let base = raw["base_sha"] as? String, let start = raw["start_sha"] as? String, let head = raw["head_sha"] as? String else { return nil }
            var position = Position(
                base: base, start: start, head: head, oldPath: raw["old_path"] as? String ?? "", newPath: raw["new_path"] as? String ?? "",
                oldLine: raw["old_line"] as? Int, newLine: raw["new_line"] as? Int)
            position.type = raw["position_type"] as? String ?? "text"
            if let range = raw["line_range"] as? [String: Any], let first = range["start"] as? [String: Any] {
                position.rangeStart = (first["old_line"] as? Int, first["new_line"] as? Int)
            }
            return position
        }
    }

    /// One version of an MR's diff.
    public struct Version: Sendable {
        public var id: Int
        public var base: String
        public var start: String
        public var head: String
        public var diffs: [(old: String, new: String, diff: String)]
        public var created = "2026-11-17T09:00:00Z"
        public init(id: Int, base: String = "b0b0b0b0b0b0b0b0", start: String = "s0s0s0s0s0s0s0s0", head: String, diffs: [(old: String, new: String, diff: String)]) {
            self.id = id
            self.base = base
            self.start = start
            self.head = head
            self.diffs = diffs
        }
    }

    public struct DraftNote: Sendable {
        public var id: Int
        public var note: String
        public var discussionID: String?
        public var position: Position?
        public var resolve: Bool?
    }

    public struct Issue: Sendable {
        public var iid: Int
        public var title: String
        public var description = ""
        public var state = "opened"
        public var author = "mara"
        public var assignees: [String] = []
        public var labels: [String] = []
        /// MR iids GitLab relates to it.
        public var relatedMRs: [Int] = []
        public var updatedAt = "2026-11-17T10:00:00Z"
        public init(iid: Int, title: String, description: String = "", assignees: [String] = []) {
            self.iid = iid
            self.title = title
            self.description = description
            self.assignees = assignees
        }
    }

    public struct Todo: Sendable {
        public var id: Int
        public var action: String
        public var targetType: String
        public var targetIID: Int
        public var projectPath: String
        public var author = "mara"
        public var body = ""
        public var state = "pending"
        public init(id: Int, action: String, targetType: String, targetIID: Int, projectPath: String, body: String = "") {
            self.id = id
            self.action = action
            self.targetType = targetType
            self.targetIID = targetIID
            self.projectPath = projectPath
            self.body = body
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
        /// Diff versions (oldest first); empty: one version made from `sha` and `diffs`.
        public var versions: [Version] = []
        public var draftNotes: [DraftNote] = []
        /// MRs (iids, same project) that must merge before this one.
        public var blockedBy: [Int] = []
        /// Eligible approvers per rule and whether a rule has hidden groups (Premium fixtures).
        public var eligibleApprovers: [String] = []
        public var hiddenGroups = false
        public var resetOnPush = true

        /// The versions GitLab would report.
        public var allVersions: [Version] { versions.isEmpty ? [Version(id: 1, head: sha, diffs: diffs)] : versions }

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
        public var jobs: [Int: [Job]] = [:]
        public var traces: [Int: String] = [:]
        public var issues: [Int: Issue] = [:]
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
        var todos: [Todo] = []
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
    public func addTodo(_ todo: Todo) { state.withLock { $0.todos.append(todo) } }
    public var todos: [Todo] { state.withLock { $0.todos } }
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
        case (_, "projects"): break
        case ("GET", "todos"):
            var items = state.todos.filter { $0.state == (query["state"] ?? "pending") }
            if let action = query["action"] { items = items.filter { $0.action == action } }
            if let type = query["type"] { items = items.filter { $0.targetType == type } }
            if let projectID = query["project_id"].flatMap(Int.init) { items = items.filter { state.projects[$0.projectPath]?.id == projectID } }
            let size = min(options.pageSize, Int(query["per_page"] ?? "20") ?? 20)
            let number = Int(query["page"] ?? "1") ?? 1
            let objects: [Any] = items.reversed().compactMap { todo in
                guard let project = state.projects[todo.projectPath] else { return nil }
                return todoJSON(todo, project, options)
            }
            var headers: [String: String] = [:]
            if objects.count > number * size { headers["X-Next-Page"] = String(number + 1) }
            return Self.json(200, Array(objects.dropFirst((number - 1) * size).prefix(size)), headers: headers)
        case ("POST", "todos"):
            guard segments.count >= 3, let id = Int(segments[1]), let index = state.todos.firstIndex(where: { $0.id == id }) else { return Self.json(404, ["message": "404 Not found"]) }
            state.todos[index].state = "done"
            guard let project = state.projects[state.todos[index].projectPath] else { return Self.json(404, ["message": "404 Not found"]) }
            return Self.json(201, todoJSON(state.todos[index], project, options))
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
        case ("GET", "approvals") where rest.count == 1:
            guard options.approvalRules else { return Self.json(404, ["message": "404 Not found"]) }
            return Self.json(200, [
                "reset_approvals_on_push": project.mrs.values.first?.resetOnPush ?? true, "merge_requests_author_approval": false,
                "merge_requests_disable_committers_approval": false, "selective_code_owner_removals": false,
            ])
        case ("GET", "issues") where rest.count == 1:
            let search = (query["search"] ?? "").lowercased()
            let items = project.issues.values.filter { issue in
                issue.state == (query["state"] ?? "opened") && (query["scope"] != "assigned_to_me" || issue.assignees.contains(username))
                    && (search.isEmpty || issue.title.lowercased().contains(search) || issue.description.lowercased().contains(search))
            }.sorted { $0.iid > $1.iid }.map { issueJSON($0, project, description: false) }
            return page(items)
        case ("GET", "issues") where rest.count >= 2:
            guard let iid = Int(rest[1]), let issue = project.issues[iid] else { return Self.json(404, ["message": "404 Not found"]) }
            if rest.count >= 3, rest[2] == "related_merge_requests" {
                guard options.relatedMergeRequests else { return Self.json(404, ["message": "404 Not found"]) }
                return page(issue.relatedMRs.compactMap { project.mrs[$0] }.map { mrJSON($0, project, options) })
            }
            return etagged(Self.json(200, issueJSON(issue, project, description: true)))
        case ("GET", "merge_requests") where rest.count == 1:
            let source = query["source_branch"]
            let target = query["target_branch"]
            let items = project.mrs.values.filter {
                (query["state"] == nil || $0.state == query["state"]) && (source == nil || $0.source == source) && (target == nil || $0.target == target)
            }
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
                    "user_can_approve": mr.author != username && !mr.approvedBy.contains(username), "user_has_approved": mr.approvedBy.contains(username),
                    "suggested_approvers": mr.eligibleApprovers.prefix(3).map { ["username": $0] },
                ]))
            case ("GET", "approval_state"):
                guard options.approvalRules else { return Self.json(404, ["message": "404 Not found"]) }
                let eligible = mr.eligibleApprovers.map { ["username": $0] }
                return Self.json(200, ["rules": [
                    [
                        "id": 1, "name": "Backend", "rule_type": "regular", "approvals_required": max(1, mr.approvalsRequired),
                        "approved_by": mr.approvedBy.map { ["username": $0] }, "approved": mr.approvedBy.count >= max(1, mr.approvalsRequired),
                        "eligible_approvers": eligible, "groups": mr.hiddenGroups ? [["full_path": "platform/backend"]] : [], "contains_hidden_groups": mr.hiddenGroups,
                    ],
                    [
                        "id": 2, "name": "CODEOWNERS", "rule_type": "code_owner", "section": "src/parser/", "approvals_required": 1, "approved_by": [], "approved": false,
                        "eligible_approvers": [["username": "lee"]],
                    ],
                    ["id": 3, "name": "Docs", "rule_type": "regular", "approvals_required": 0, "approved_by": [], "approved": true, "eligible_approvers": [["username": "mara"]]],
                ]])
            case ("GET", "versions"):
                let versions = mr.allVersions
                if rest.count >= 4 {
                    guard let id = Int(rest[3]), let version = versions.first(where: { $0.id == id }) else { return Self.json(404, ["message": "404 Not found"]) }
                    var object = versionJSON(version)
                    object["diffs"] = version.diffs.map { diffJSON($0) }
                    return etagged(Self.json(200, object))
                }
                return page(versions.reversed().map { versionJSON($0) })
            case ("GET", "draft_notes"):
                guard options.draftNotes else { return Self.json(404, ["message": "404 Not found"]) }
                return page(mr.draftNotes.map { draftJSON($0) })
            case ("POST", "draft_notes"):
                guard options.draftNotes else { return Self.json(404, ["message": "404 Not found"]) }
                if rest.count >= 4, rest[3] == "bulk_publish" {
                    for draft in mr.draftNotes { publish(draft, into: &mr, state: &state) }
                    mr.draftNotes.removeAll()
                    return ForgeResponse(status: 204, headers: [:], body: Data())
                }
                guard let text = input["note"] as? String else { return Self.json(400, ["message": "note is missing"]) }
                let position = Position.parse(input["position"] as? [String: Any])
                if let position, let problem = positionProblem(position, mr) { return Self.json(400, ["message": problem]) }
                state.nextID += 1
                let draft = DraftNote(
                    id: state.nextID, note: text, discussionID: input["in_reply_to_discussion_id"] as? String, position: position,
                    resolve: input["resolve_discussion"] as? Bool)
                mr.draftNotes.append(draft)
                return Self.json(201, draftJSON(draft))
            case ("DELETE", "draft_notes") where rest.count >= 4:
                guard options.draftNotes, let id = Int(rest[3]), let index = mr.draftNotes.firstIndex(where: { $0.id == id }) else { return Self.json(404, ["message": "404 Not found"]) }
                mr.draftNotes.remove(at: index)
                return ForgeResponse(status: 204, headers: [:], body: Data())
            case ("POST", "discussions") where rest.count == 3:
                guard let text = input["body"] as? String else { return Self.json(400, ["message": "body is missing"]) }
                let position = Position.parse(input["position"] as? [String: Any])
                if let position, let problem = positionProblem(position, mr) { return Self.json(400, ["message": problem]) }
                state.nextID += 1
                var note = Note(id: state.nextID, author: username, body: text, resolvable: position != nil)
                note.diffPosition = position
                note.originalPosition = position
                let discussion = Discussion(id: "new\(state.nextID)", notes: [note])
                mr.discussions.append(discussion)
                return Self.json(201, discussionJSON(discussion))
            case ("GET", "blocks"), ("GET", "blockees"):
                guard options.dependencies else { return Self.json(404, ["message": "404 Not found"]) }
                if sub == "blocks" {
                    return page(mr.blockedBy.compactMap { project.mrs[$0] }.map { ["id": $0.iid, "blocking_merge_request": mrJSON($0, project, options)] })
                }
                let waiting = project.mrs.values.filter { $0.blockedBy.contains(mr.iid) }.sorted { $0.iid < $1.iid }
                return page(waiting.map { ["id": $0.iid, "blocked_merge_request": mrJSON($0, project, options)] })
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
        if let latest = mr.allVersions.last {
            object["diff_refs"] = ["base_sha": latest.base, "start_sha": latest.start, "head_sha": latest.head]
        }
        object["references"] = ["full": "\(project.path)!\(mr.iid)", "short": "!\(mr.iid)"]
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
                if let position = note.diffPosition {
                    object["position"] = position.json
                    object["original_position"] = (note.originalPosition ?? position).json
                    object["type"] = "DiffNote"
                } else if let position = note.position {
                    object["position"] = ["new_path": position.path, "new_line": position.line, "position_type": "text"]
                }
                return object
            },
        ]
    }

    // MARK: GitLab 2 shapes

    private func versionJSON(_ version: Version) -> [String: Any] {
        [
            "id": version.id, "base_commit_sha": version.base, "start_commit_sha": version.start, "head_commit_sha": version.head,
            "created_at": version.created, "state": "collected", "real_size": String(version.diffs.count),
        ]
    }

    private func diffJSON(_ diff: (old: String, new: String, diff: String)) -> [String: Any] {
        [
            "old_path": diff.old, "new_path": diff.new, "diff": diff.diff, "new_file": diff.old.isEmpty, "deleted_file": diff.new.isEmpty,
            "renamed_file": !diff.old.isEmpty && !diff.new.isEmpty && diff.old != diff.new, "too_large": false, "collapsed": false,
        ]
    }

    private func draftJSON(_ draft: DraftNote) -> [String: Any] {
        var object: [String: Any] = ["id": draft.id, "note": draft.note, "author_id": 1]
        if let id = draft.discussionID { object["discussion_id"] = id }
        if let position = draft.position { object["position"] = position.json }
        if let resolve = draft.resolve { object["resolve_discussion"] = resolve }
        return object
    }

    /// GitLab refuses a position that is not on the MR's latest version, or whose line is not in that version's diff.
    private func positionProblem(_ position: Position, _ mr: MR) -> String? {
        guard let latest = mr.allVersions.last else { return "no diff" }
        guard position.base == latest.base, position.start == latest.start, position.head == latest.head else {
            return "400 Bad request - Note {:line_code=>[\"can't be blank\", \"must be a valid line code\"]}"
        }
        guard position.type == "text" else { return nil }
        guard let file = latest.diffs.first(where: { $0.new == position.newPath || $0.old == position.oldPath }) else { return "400 Bad request - file not in diff" }
        let lines = ReviewFileLines(oldPath: file.old, newPath: file.new, hunks: ReviewDiffFile(oldPath: file.old, newPath: file.new, diff: file.diff).patch.hunks)
        if let new = position.newLine, !lines.newLines.contains(new) { return "400 Bad request - Note {:line_code=>[\"can't be blank\"]}" }
        if let old = position.oldLine, position.newLine == nil, !lines.oldLines.contains(old) { return "400 Bad request - Note {:line_code=>[\"can't be blank\"]}" }
        return nil
    }

    private func publish(_ draft: DraftNote, into mr: inout MR, state: inout State) {
        state.nextID += 1
        var note = Note(id: state.nextID, author: username, body: draft.note, resolvable: true)
        if let id = draft.discussionID, let index = mr.discussions.firstIndex(where: { $0.id == id }) {
            note.diffPosition = mr.discussions[index].notes.first?.diffPosition
            mr.discussions[index].notes.append(note)
            if let resolve = draft.resolve {
                for i in mr.discussions[index].notes.indices where mr.discussions[index].notes[i].resolvable { mr.discussions[index].notes[i].resolved = resolve }
            }
        } else {
            note.diffPosition = draft.position
            note.originalPosition = draft.position
            note.resolvable = draft.position != nil
            mr.discussions.append(Discussion(id: "pub\(state.nextID)", notes: [note]))
        }
    }

    private func issueJSON(_ issue: Issue, _ project: Project, description: Bool) -> [String: Any] {
        var object: [String: Any] = [
            "id": project.id * 10_000 + issue.iid, "iid": issue.iid, "project_id": project.id, "title": issue.title, "state": issue.state,
            "author": ["username": issue.author], "assignees": issue.assignees.map { ["username": $0] }, "labels": issue.labels,
            "web_url": "\(web(project))/-/issues/\(issue.iid)", "updated_at": issue.updatedAt, "user_notes_count": 0,
            "references": ["full": "\(project.path)#\(issue.iid)", "short": "#\(issue.iid)"],
        ]
        if description { object["description"] = issue.description }
        return object
    }

    private func todoJSON(_ todo: Todo, _ project: Project, _ options: Options) -> [String: Any] {
        var target: [String: Any] = ["iid": todo.targetIID, "title": "Target \(todo.targetIID)"]
        var url = web(project)
        if todo.targetType == "Issue", let issue = project.issues[todo.targetIID] {
            target = issueJSON(issue, project, description: false)
            url += "/-/issues/\(todo.targetIID)"
        } else if todo.targetType == "MergeRequest", let mr = project.mrs[todo.targetIID] {
            target = mrJSON(mr, project, options)
            url += "/-/merge_requests/\(todo.targetIID)"
        }
        return [
            "id": todo.id, "action_name": todo.action, "target_type": todo.targetType, "target": target, "target_url": url, "body": todo.body,
            "state": todo.state, "author": ["username": todo.author], "project": ["id": project.id, "path_with_namespace": project.path],
            "created_at": "2026-11-17T08:00:00Z",
        ]
    }
}
