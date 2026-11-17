import Foundation

// VCS, worktree, per-turn diff and revert routes (M2-C), shaped as the pinned 2.3.0 server answered in a sandbox:
// - `GET /api/vcs` answers `{"branch":{}}` until the branch is resolved (the mock resolves it at once).
// - `GET /api/vcs/status` reports untracked files as `added`; staged and unstaged are not distinguished.
// - `POST /api/worktree` checks out a detached HEAD in `<directory or data>/<name or random>`; `branch` must name an
//   existing ref (else 400 `WorktreeError` "fatal: invalid reference"). `DELETE` without `force` refuses a dirty
//   worktree with `forceRequired: true`; an unknown directory is 400 "Invalid worktree directory".
// - `POST …/revert/stage` with `files: true` returns the inverse patches it applied; `files: false` returns `[]`.
// Divergence: repositories are scripted values (`MockVCSRepository`), not real git state.

/// A scripted repository for one directory.
public struct MockVCSRepository: Sendable {
    public var current: String
    public var defaultBranch: String
    public var branches: [String]
    /// Working-copy changes (`FileDiff.Info` values: file, patch, additions, deletions, status).
    public var working: [JSONValue]
    /// Changes since the merge base with the default branch (`mode=branch`); defaults to `working`.
    public var branchChanges: [JSONValue]?

    public init(
        current: String = "main", defaultBranch: String = "main", branches: [String]? = nil, working: [JSONValue] = [],
        branchChanges: [JSONValue]? = nil
    ) {
        self.current = current
        self.defaultBranch = defaultBranch
        self.branches = branches ?? Array(Set([current, defaultBranch])).sorted()
        self.working = working
        self.branchChanges = branchChanges
    }

    /// A `FileDiff.Info` value with counts taken from the patch.
    public static func fileDiff(_ file: String, status: String = "modified", patch: String) -> JSONValue {
        var additions = 0
        var deletions = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") { additions += 1 }
            if line.hasPrefix("-"), !line.hasPrefix("---") { deletions += 1 }
        }
        return [
            "file": .string(file), "patch": .string(patch), "additions": .int(additions), "deletions": .int(deletions),
            "status": .string(status),
        ]
    }

    /// A small repository with two changed files on a feature branch, for demos.
    public static let sample = MockVCSRepository(
        current: "feature/login", defaultBranch: "main", branches: ["feature/login", "main", "release/1.2"],
        working: [
            fileDiff(
                "Sources/App/Login.swift", status: "modified",
                patch: """
                    diff --git a/Sources/App/Login.swift b/Sources/App/Login.swift
                    index 1111111..2222222 100644
                    --- a/Sources/App/Login.swift
                    +++ b/Sources/App/Login.swift
                    @@ -1,5 +1,6 @@
                     import Foundation
                    -func login(user: String) -> Bool {
                    -    user.isEmpty == false
                    +func login(user: String, password: String) -> Bool {
                    +    guard !user.isEmpty else { return false }
                    +    return password.count >= 8
                     }

                    """),
            fileDiff(
                "README.md", status: "added",
                patch: """
                    diff --git a/README.md b/README.md
                    new file mode 100644
                    index 0000000..3333333
                    --- /dev/null
                    +++ b/README.md
                    @@ -0,0 +1,2 @@
                    +# Demo
                    +Sign in with a password.

                    """),
        ])
}

/// VCS state the mock keeps beside `ServerState`.
struct MockVCSState: Sendable {
    var repositories: [String: MockVCSRepository] = [:]
    /// Per-turn diffs: session → user message ID (or "" for the newest turn) → files (full-file patches).
    var turnDiffs: [String: [String: [JSONValue]]] = [:]
    /// The same with a few lines of context (served when the request has `context`); falls back to `turnDiffs`.
    var turnDiffsWithContext: [String: [String: [JSONValue]]] = [:]
    /// Staged reverts per session (`Session.Revert`).
    var reverts: [String: JSONValue] = [:]
    /// Worktrees per project (the main checkout is listed first and never stored here).
    var worktrees: [String: [String]] = [:]
    /// Worktrees holding uncommitted changes (removal needs `force`).
    var dirtyWorktrees: Set<String> = []
    var worktreeCounter = 0
}

extension MockOpenCodeServer {
    // MARK: Scripting

    /// Scripts the repository at `directory` (and every directory below it).
    public func setRepository(_ repository: MockVCSRepository, for directory: String) {
        vcs.repositories[directory] = repository
    }

    /// Scripts the files a turn changed. `from` is the turn's user message; nil sets the newest turn's diff. `files`
    /// hold full-file patches (no `context`); `withContext` the patches served when a request asks for context.
    public func setTurnDiff(sessionID: String, from messageID: String? = nil, files: [JSONValue], withContext: [JSONValue]? = nil) {
        vcs.turnDiffs[sessionID, default: [:]][messageID ?? ""] = files
        vcs.turnDiffsWithContext[sessionID, default: [:]][messageID ?? ""] = withContext
    }

    /// Adds a worktree to a project's inventory (as a `refresh` after `git worktree add` would); `dirty` marks it as
    /// holding changes.
    public func addWorktree(_ directory: String, projectID: String, dirty: Bool = false) {
        if !(vcs.worktrees[projectID] ?? []).contains(directory) { vcs.worktrees[projectID, default: []].append(directory) }
        if dirty { vcs.dirtyWorktrees.insert(directory) }
    }

    /// The staged revert of a session, if any (tests).
    public func stagedRevert(sessionID: String) -> JSONValue? { vcs.reverts[sessionID] }

    /// The project directories and worktrees known to the mock.
    func worktreeOwner(of directory: String) -> MockProject? {
        for (projectID, directories) in vcs.worktrees where directories.contains(where: { $0 == directory || directory.hasPrefix($0 + "/") }) {
            if let project = state.projects.first(where: { $0.id == projectID }) { return project }
        }
        return nil
    }

    // MARK: Routing

    func routeVCS(_ method: String, _ parts: [String], _ request: HTTPRequest) -> HTTPResponse? {
        guard parts.first == "api" else { return nil }
        let rest = Array(parts.dropFirst())
        switch (method, rest) {
        case ("GET", ["vcs"]):
            let repo = repository(for: location(request))
            return .json([
                "location": ["directory": .string(location(request))],
                "data": ["provider": "git", "branch": ["current": .string(repo.current), "default": .string(repo.defaultBranch)]],
            ])
        case ("GET", ["vcs", "base"]):
            let repo = repository(for: location(request))
            return .json([
                "location": ["directory": .string(location(request))],
                "data": [
                    "name": .string(repo.defaultBranch), "ref": .string("refs/heads/\(repo.defaultBranch)"),
                    "source": .string(repo.current == repo.defaultBranch ? "default" : "reflog"),
                ],
            ])
        case ("GET", ["vcs", "status"]):
            let files = repository(for: location(request)).working.map { file -> JSONValue in
                ["file": file["file"] ?? "", "additions": file["additions"] ?? 0, "deletions": file["deletions"] ?? 0, "status": file["status"] ?? "modified"]
            }
            return located(request, .array(files))
        case ("GET", ["vcs", "branch"]):
            var branches = repository(for: location(request)).branches
            if let search = request.queryValue("search"), !search.isEmpty {
                branches = branches.filter { $0.localizedCaseInsensitiveContains(search) }
            }
            if let limit = Int(request.queryValue("limit") ?? "") { branches = Array(branches.prefix(limit)) }
            return .json(["location": ["directory": .string(location(request))], "data": .array(branches.map(JSONValue.string))])
        case ("GET", ["vcs", "diff"]):
            guard let mode = request.queryValue("mode") else { return Self.invalid("Missing key\n  at [\"mode\"]", kind: "Query") }
            let repo = repository(for: location(request))
            switch mode {
            case "working": return located(request, .array(repo.working))
            case "branch", "committed": return located(request, .array(repo.branchChanges ?? repo.working))
            default: return Self.invalid("Expected \"working\" | \"branch\" | \"committed\"", kind: "Query")
            }
        case ("GET", let p) where p.count == 3 && p[0] == "session" && p[2] == "diff":
            return turnDiff(p[1], request)
        case ("POST", let p) where p.count == 4 && p[0] == "session" && p[2] == "revert" && p[3] == "stage":
            return stageRevert(p[1], request)
        case ("DELETE", let p) where p.count == 3 && p[0] == "session" && p[2] == "revert":
            return finishRevert(p[1], commit: false)
        case ("POST", let p) where p.count == 4 && p[0] == "session" && p[2] == "revert" && p[3] == "commit":
            return finishRevert(p[1], commit: true)
        case ("GET", ["worktree"]):
            guard let projectID = request.queryValue("projectID"), let project = state.projects.first(where: { $0.id == projectID }) else {
                return .error(404, tag: "ProjectNotFoundError", message: "Project not found")
            }
            let list: [JSONValue] = (vcs.worktrees[projectID] ?? []).reversed().map { ["directory": .string($0), "strategy": "git"] }
            return .json(.array(list + [["directory": .string(project.directory)]]))
        case ("POST", ["worktree"]):
            return createWorktree(request)
        case ("DELETE", ["worktree"]):
            return removeWorktree(request)
        case ("POST", ["worktree", "refresh"]):
            switch jsonBody(request) {
            case .failure(let error): return error
            case .success(let body):
                guard let id = body["projectID"]?.stringValue, state.projects.contains(where: { $0.id == id }) else {
                    return .error(404, tag: "ProjectNotFoundError", message: "Project not found")
                }
                publish("worktree.updated", ["projectID": .string(id)])
                return .noContent()
            }
        default:
            return nil
        }
    }

    private func repository(for directory: String) -> MockVCSRepository {
        let match = vcs.repositories.keys.filter { directory == $0 || directory.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        return match.flatMap { vcs.repositories[$0] } ?? MockVCSRepository()
    }

    private func turnDiff(_ sessionID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard state.sessions[sessionID] != nil else { return Self.sessionNotFound(sessionID) }
        var diffs = vcs.turnDiffs[sessionID] ?? [:]
        if request.queryValue("context") != nil { diffs.merge(vcs.turnDiffsWithContext[sessionID] ?? [:]) { _, context in context } }
        let from = request.queryValue("from") ?? ""
        if !from.isEmpty, !(state.messages[sessionID] ?? []).contains(where: { $0.id == from }), diffs[from] == nil {
            return .error(404, tag: "MessageNotFoundError", message: "Message not found: \(from)", extra: [("messageID", .string(from))])
        }
        return .json(["data": .array(diffs[from] ?? (from.isEmpty ? diffs[""] ?? [] : []))])
    }

    private func stageRevert(_ sessionID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard state.sessions[sessionID] != nil else { return Self.sessionNotFound(sessionID) }
        let body: JSONValue
        switch jsonBody(request) {
        case .failure(let error): return error
        case .success(let value): body = value
        }
        guard let messageID = body["messageID"]?.stringValue else { return Self.invalid("Missing key\n  at [\"messageID\"]") }
        let applied = body["files"]?.boolValue == true
        let files = applied ? (vcs.turnDiffs[sessionID]?[messageID] ?? []).map(Self.inverted) : []
        let revert: JSONValue = ["messageID": .string(messageID), "snapshot": .string("snap_\(makeID("snp"))"), "files": .array(files)]
        vcs.reverts[sessionID] = revert
        publish("session.revert.staged", ["sessionID": .string(sessionID), "revert": revert], durable: sessionID)
        return .json(["data": revert])
    }

    private func finishRevert(_ sessionID: String, commit: Bool) -> HTTPResponse {
        guard state.sessions[sessionID] != nil else { return Self.sessionNotFound(sessionID) }
        guard let revert = vcs.reverts.removeValue(forKey: sessionID) else { return .noContent() }
        if commit {
            publish("session.revert.committed", ["sessionID": .string(sessionID), "to": revert["messageID"] ?? ""], durable: sessionID)
        } else {
            publish("session.revert.cleared", ["sessionID": .string(sessionID)], durable: sessionID)
        }
        return .noContent()
    }

    /// The inverse of a `FileDiff.Info` (old and new sides swapped), as the real stage returns.
    static func inverted(_ file: JSONValue) -> JSONValue {
        let patch = (file["patch"]?.stringValue ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if line.hasPrefix("+++") || line.hasPrefix("---") { return String(line) }
            if line.hasPrefix("+") { return "-" + line.dropFirst() }
            if line.hasPrefix("-") { return "+" + line.dropFirst() }
            return String(line)
        }.joined(separator: "\n")
        let status = file["status"]?.stringValue
        return [
            "file": file["file"] ?? "", "patch": .string(patch), "additions": file["deletions"] ?? 0,
            "deletions": file["additions"] ?? 0,
            "status": .string(status == "added" ? "deleted" : status == "deleted" ? "added" : "modified"),
        ]
    }

    private func createWorktree(_ request: HTTPRequest) -> HTTPResponse {
        let body: JSONValue
        switch jsonBody(request) {
        case .failure(let error): return error
        case .success(let value): body = value
        }
        guard let projectID = body["projectID"]?.stringValue, let project = state.projects.first(where: { $0.id == projectID }) else {
            return .error(404, tag: "ProjectNotFoundError", message: "Project not found")
        }
        if let branch = body["branch"]?.stringValue, !repository(for: project.directory).branches.contains(branch) {
            return Self.worktreeError("fatal: invalid reference: \(branch)", forceRequired: false)
        }
        vcs.worktreeCounter += 1
        let parent = body["directory"]?.stringValue ?? "/tmp/mock-opencode/worktree/\(projectID.prefix(6))"
        let directory = parent + "/" + (body["name"]?.stringValue ?? "calm-rocket-\(vcs.worktreeCounter)")
        addWorktree(directory, projectID: projectID)
        publish("worktree.updated", ["projectID": .string(projectID)])
        return .json(["directory": .string(directory)])
    }

    private func removeWorktree(_ request: HTTPRequest) -> HTTPResponse {
        let body: JSONValue
        switch jsonBody(request) {
        case .failure(let error): return error
        case .success(let value): body = value
        }
        guard let projectID = body["projectID"]?.stringValue, state.projects.contains(where: { $0.id == projectID }) else {
            return .error(404, tag: "ProjectNotFoundError", message: "Project not found")
        }
        guard let directory = body["directory"]?.stringValue, let force = body["force"]?.boolValue else {
            return Self.invalid("Missing key\n  at [\"force\"]")
        }
        guard (vcs.worktrees[projectID] ?? []).contains(directory) else {
            return .json(
                [
                    "_tag": "WorktreeError", "name": "WorktreeError",
                    "data": ["message": .string("Invalid worktree directory: \(directory)"), "forceRequired": .null],
                ], status: 400)
        }
        if vcs.dirtyWorktrees.contains(directory), !force {
            return Self.worktreeError("fatal: '\(directory)' contains modified or untracked files, use --force to delete it", forceRequired: true)
        }
        vcs.worktrees[projectID]?.removeAll { $0 == directory }
        vcs.dirtyWorktrees.remove(directory)
        publish("worktree.updated", ["projectID": .string(projectID)])
        return .noContent()
    }

    static func worktreeError(_ message: String, forceRequired: Bool) -> HTTPResponse {
        .json(
            [
                "_tag": "WorktreeError", "name": "WorktreeError",
                "data": ["message": .string(message), "forceRequired": .bool(forceRequired)],
            ], status: 400)
    }
}
