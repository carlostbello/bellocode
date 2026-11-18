import Foundation

// On-demand reads (job logs, changes, approval rules, project, branches, users) and the writes (create and edit MRs,
// reply, resolve, retry and play jobs, approve, merge). Endpoints and minimum versions: docs/features/gitlab.md.
// Writes are sent once: never retried automatically, and a lost connection after sending is `outcomeUnknown`.

extension GitLabProvider {
    static func instance(_ ref: MergeRequestRef) throws -> GitLabInstance {
        guard let instance = GitLabInstance(baseURL: ref.instance) else { throw ForgeError.noInstance(ref.instance) }
        return instance
    }

    static func mrPath(_ ref: MergeRequestRef) -> String { "projects/\(encode(ref.projectPath))/merge_requests/\(ref.iid)" }

    // MARK: Reads

    /// `GET /projects/:id`: numeric ID and default branch.
    @concurrent
    public func project(_ project: ForgeProject) async throws -> GitLabProjectInfo {
        let raw = try Self.object(try await get("projects/\(Self.encode(project.projectPath))", project.instance))
        return GitLabProjectInfo(
            id: raw["id"] as? Int ?? 0, path: raw["path_with_namespace"] as? String ?? project.projectPath,
            defaultBranch: raw["default_branch"] as? String, webURL: raw["web_url"] as? String)
    }

    /// Branch names matching `search` (one page of at most 50; GitLab sorts by name).
    @concurrent
    public func branches(_ project: ForgeProject, search: String) async throws -> [String] {
        let query = search.isEmpty ? "" : "&search=" + Self.encode(search)
        return try await getPaged("projects/\(Self.encode(project.projectPath))/repository/branches?per_page=50\(query)", project.instance, maxPages: 1)
            .items.compactMap { $0["name"] as? String }
    }

    /// Project members matching `search` (for assignees and reviewers; one page, never a global user scan).
    @concurrent
    public func users(_ project: ForgeProject, search: String) async throws -> [GitLabUserRef] {
        guard !search.isEmpty else { return [] }
        return try await getPaged(
            "projects/\(Self.encode(project.projectPath))/users?per_page=20&search=" + Self.encode(search), project.instance, maxPages: 1
        ).items.compactMap { user in
            guard let id = user["id"] as? Int, let username = user["username"] as? String else { return nil }
            return GitLabUserRef(id: id, username: username, name: user["name"] as? String ?? "")
        }
    }

    /// Required approval rules and Code Owners (`approval_state`, Premium/Ultimate). Unsupported (404/403) on Free,
    /// which the caller records so it is not asked again.
    @concurrent
    public func approvalRules(_ ref: MergeRequestRef) async throws -> [ApprovalRuleDigest] {
        let raw = try Self.object(try await get(Self.mrPath(ref) + "/approval_state", try Self.instance(ref)))
        return (raw["rules"] as? [[String: Any]] ?? []).map { rule in
            ApprovalRuleDigest(
                name: rule["name"] as? String ?? "Rule", type: rule["rule_type"] as? String ?? "regular",
                required: rule["approvals_required"] as? Int ?? 0,
                approvedBy: (rule["approved_by"] as? [[String: Any]] ?? []).compactMap { $0["username"] as? String },
                approved: rule["approved"] as? Bool ?? false, section: rule["section"] as? String)
        }
    }

    /// The end of a job's log, at most `maxBytes`. Asks for `Range: bytes=-maxBytes` (honoured by some GitLab and
    /// proxy setups, never documented): a 206 is the tail; a 200 is the whole log, of which only the end is kept; a 416
    /// (range not satisfiable) falls back to a plain read. Never cached (logs grow while a job runs).
    @concurrent
    public func jobLog(_ project: ForgeProject, jobID: Int, maxBytes: Int, tryRange: Bool) async throws -> JobLogChunk {
        let path = "projects/\(Self.encode(project.projectPath))/jobs/\(jobID)/trace"
        var response = try await response(
            path, project.instance, cached: false, headers: tryRange ? ["Range": "bytes=-\(maxBytes)", "Accept": "text/plain"] : ["Accept": "text/plain"],
            tailLimit: maxBytes)
        var honoured: Bool? = tryRange ? false : nil
        if response.status == 416 {
            response = try await self.response(path, project.instance, cached: false, headers: ["Accept": "text/plain"], tailLimit: maxBytes)
        }
        var total: Int?
        if response.status == 206 {
            honoured = true
            if let range = response.headers["content-range"], let slash = range.lastIndex(of: "/") { total = Int(range[range.index(after: slash)...]) }
        }
        var body = response.body
        total = total ?? Int(response.headers["x-bellocode-total-bytes"] ?? "") ?? body.count
        var omitted = (total ?? body.count) > body.count || response.headers["x-bellocode-truncated"] == "1"
        if body.count > maxBytes {
            body = body.suffix(maxBytes)
            omitted = true
        }
        // Start at a line boundary when the head was cut.
        var text = String(decoding: body, as: UTF8.self)
        if omitted, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return JobLogChunk(jobID: jobID, text: text, totalBytes: total, headOmitted: omitted, rangeHonoured: honoured)
    }

    /// The MR's changed files, bounded: at most `maxFiles` files and `maxBytes` of diff text in total, each file cut at
    /// `perFileBytes`. Uses `/diffs` (15.7+) and falls back to the deprecated `/changes`.
    @concurrent
    public func changes(_ ref: MergeRequestRef, maxFiles: Int = 60, maxBytes: Int = 64_000, perFileBytes: Int = 16_000) async throws -> MergeRequestChanges {
        let instance = try Self.instance(ref)
        var items: [[String: Any]]
        var incomplete = false
        do {
            let list = try await getPaged(Self.mrPath(ref) + "/diffs?per_page=50", instance, maxPages: max(1, (maxFiles + 49) / 50))
            items = list.items
            incomplete = list.truncated
        } catch ForgeError.notFound {
            let raw = try Self.object(try await get(Self.mrPath(ref) + "/changes", instance))
            items = raw["changes"] as? [[String: Any]] ?? []
            if (raw["overflow"] as? Bool) == true { incomplete = true }
        }
        if items.count > maxFiles {
            items = Array(items.prefix(maxFiles))
            incomplete = true
        }
        var budget = maxBytes
        var files: [MergeRequestFileChange] = []
        for item in items {
            let diff = item["diff"] as? String ?? ""
            let limit = min(perFileBytes, max(0, budget))
            let cut = diff.utf8.count > limit
            let text = cut ? String(decoding: Data(diff.utf8.prefix(limit)), as: UTF8.self) : diff
            budget -= text.utf8.count
            if cut { incomplete = true }
            files.append(
                MergeRequestFileChange(
                    oldPath: item["old_path"] as? String ?? "", newPath: item["new_path"] as? String ?? "", newFile: item["new_file"] as? Bool ?? false,
                    deletedFile: item["deleted_file"] as? Bool ?? false, renamedFile: item["renamed_file"] as? Bool ?? false, diff: text, truncated: cut,
                    tooLarge: (item["too_large"] as? Bool) == true || (item["collapsed"] as? Bool) == true))
        }
        return MergeRequestChanges(files: files, incomplete: incomplete)
    }

    /// The MR's description (on demand: not kept in snapshots).
    @concurrent
    public func mergeRequestDescription(_ ref: MergeRequestRef) async throws -> String {
        let raw = try Self.object(try await get(Self.mrPath(ref), try Self.instance(ref)))
        return raw["description"] as? String ?? ""
    }

    // MARK: Writes

    /// `POST /projects/:id/merge_requests`. Returns the new MR.
    @concurrent
    public func createMergeRequest(_ project: ForgeProject, _ draft: MergeRequestDraft) async throws -> MergeRequestRef {
        let raw = try await write("POST", "projects/\(Self.encode(project.projectPath))/merge_requests", project.instance, body: .object(draft.payload))
        guard let iid = raw["iid"] as? Int else { throw ForgeError.unexpected("GitLab did not return the new merge request.") }
        return MergeRequestRef(instance: project.instance.baseURL, projectPath: project.projectPath, iid: iid)
    }

    /// `PUT M` with only the changed fields (`title`, `description`).
    @concurrent
    public func updateMergeRequest(_ ref: MergeRequestRef, fields: [String: JSONLike]) async throws {
        _ = try await write("PUT", Self.mrPath(ref), try Self.instance(ref), body: .object(fields))
    }

    /// `POST M/discussions/:id/notes`.
    @concurrent
    public func reply(_ ref: MergeRequestRef, discussionID: String, body: String) async throws -> Int? {
        let raw = try await write(
            "POST", Self.mrPath(ref) + "/discussions/\(Self.encode(discussionID))/notes", try Self.instance(ref), body: .object(["body": .string(body)]))
        return raw["id"] as? Int
    }

    /// `PUT M/discussions/:id?resolved=…`.
    @concurrent
    public func resolve(_ ref: MergeRequestRef, discussionID: String, resolved: Bool) async throws {
        _ = try await write(
            "PUT", Self.mrPath(ref) + "/discussions/\(Self.encode(discussionID))?resolved=\(resolved)", try Self.instance(ref),
            body: .object(["resolved": .bool(resolved)]))
    }

    /// `POST /projects/:id/jobs/:job/retry` → the new job's ID.
    @concurrent
    public func retryJob(_ project: ForgeProject, jobID: Int) async throws -> Int? {
        try await write("POST", "projects/\(Self.encode(project.projectPath))/jobs/\(jobID)/retry", project.instance, body: nil)["id"] as? Int
    }

    /// `POST /projects/:id/jobs/:job/play` (a manual job; may deploy).
    @concurrent
    public func playJob(_ project: ForgeProject, jobID: Int) async throws -> Int? {
        try await write("POST", "projects/\(Self.encode(project.projectPath))/jobs/\(jobID)/play", project.instance, body: nil)["id"] as? Int
    }

    /// `POST M/approve` with the reviewed `sha` (GitLab refuses with 409 when the head moved).
    @concurrent
    public func approve(_ ref: MergeRequestRef, sha: String) async throws {
        _ = try await write("POST", Self.mrPath(ref) + "/approve", try Self.instance(ref), body: .object(["sha": .string(sha)]))
    }

    /// `PUT M/merge` with the reviewed `sha`; GitLab applies every merge check and branch rule.
    @concurrent
    public func merge(_ ref: MergeRequestRef, sha: String) async throws {
        _ = try await write("PUT", Self.mrPath(ref) + "/merge", try Self.instance(ref), body: .object(["sha": .string(sha)]))
    }
}
