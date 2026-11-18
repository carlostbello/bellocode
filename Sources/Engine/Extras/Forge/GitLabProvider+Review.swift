import Foundation

// GitLab 2 endpoints (docs/features/gitlab.md "Endpoints"): MR versions and their diffs, positioned discussions, draft
// notes and new threads, issues and related MRs, to-dos, approval detail and settings, MR dependencies. Reads are
// bounded and say when they were cut; writes are sent once and never retried automatically.

extension GitLabProvider {
    /// Bounds of one version's diff.
    public static let reviewMaxFiles = 300
    public static let reviewMaxBytes = 4 << 20
    public static let reviewPerFileBytes = 512 << 10
    /// Issues: 20 per page, at most 5 pages per list (the list then says more are on GitLab).
    public static let issuePageSize = 20
    public static let issueMaxPages = 5

    static func projectPath(_ project: ForgeProject) -> String { "projects/\(encode(project.projectPath))" }

    // MARK: Versions and diffs

    /// `GET M/versions` (newest first).
    @concurrent
    public func versions(_ ref: MergeRequestRef) async throws -> [MergeRequestVersion] {
        let list = try await getPaged(Self.mrPath(ref) + "/versions?per_page=100", try Self.instance(ref), maxPages: 1).items
        return list.compactMap { raw in
            guard let id = raw["id"] as? Int, let refs = DiffRefs.parse(raw, commitKeys: true) else { return nil }
            return MergeRequestVersion(id: id, refs: refs, created: (raw["created_at"] as? String).flatMap(Self.date), state: raw["state"] as? String)
        }.sorted { $0.id > $1.id }
    }

    /// The MR's current `diff_refs` (nil while GitLab is still preparing the diff).
    @concurrent
    public func diffRefs(_ ref: MergeRequestRef) async throws -> DiffRefs? {
        let raw = try Self.object(try await get(Self.mrPath(ref), try Self.instance(ref), cached: false))
        return DiffRefs.parse(raw["diff_refs"] as? [String: Any])
    }

    /// `GET M/versions/:id` with its files, bounded (files beyond the bound are listed as missing, never as empty).
    @concurrent
    public func versionDiff(_ ref: MergeRequestRef, version: MergeRequestVersion, count: Int = 1) async throws -> ReviewDiffVersion {
        let raw = try Self.object(try await get(Self.mrPath(ref) + "/versions/\(version.id)", try Self.instance(ref)))
        var items = raw["diffs"] as? [[String: Any]] ?? []
        var incomplete = (raw["state"] as? String) == "overflow"
        if items.count > Self.reviewMaxFiles {
            items = Array(items.prefix(Self.reviewMaxFiles))
            incomplete = true
        }
        var budget = Self.reviewMaxBytes
        var files: [ReviewDiffFile] = []
        for item in items {
            let diff = item["diff"] as? String ?? ""
            let limit = min(Self.reviewPerFileBytes, max(0, budget))
            var cut = diff.utf8.count > limit
            var text = diff
            if cut {
                // Keep whole lines only (a hunk cut mid-line would misnumber what follows).
                let prefix = String(decoding: Data(diff.utf8.prefix(limit)), as: UTF8.self)
                text = prefix.lastIndex(of: "\n").map { String(prefix[...$0]) } ?? ""
                incomplete = true
            }
            budget -= text.utf8.count
            if budget <= 0, !cut, text.isEmpty, !diff.isEmpty { cut = true }
            files.append(
                ReviewDiffFile(
                    oldPath: item["old_path"] as? String ?? "", newPath: item["new_path"] as? String ?? "", newFile: item["new_file"] as? Bool ?? false,
                    deletedFile: item["deleted_file"] as? Bool ?? false, renamedFile: item["renamed_file"] as? Bool ?? false, diff: text, truncated: cut,
                    tooLarge: (item["too_large"] as? Bool) == true || (item["collapsed"] as? Bool) == true))
        }
        var shown = version
        if let refs = DiffRefs.parse(raw, commitKeys: true) { shown.refs = refs }
        return ReviewDiffVersion(version: shown, files: files, incomplete: incomplete, count: count)
    }

    // MARK: Discussions with positions

    /// Every discussion with its full position (paged, bounded; `truncated` when cut).
    @concurrent
    public func reviewDiscussions(_ ref: MergeRequestRef) async throws -> (discussions: [ReviewDiscussion], truncated: Bool) {
        let list = try await getPaged(Self.mrPath(ref) + "/discussions?per_page=100", try Self.instance(ref))
        return (list.items.map(Self.reviewDiscussion), list.truncated)
    }

    static func reviewDiscussion(_ raw: [String: Any]) -> ReviewDiscussion {
        let rawNotes = raw["notes"] as? [[String: Any]] ?? []
        let notes = rawNotes.map { note in
            ReviewNote(
                id: note["id"] as? Int ?? 0, author: (note["author"] as? [String: Any])?["username"] as? String ?? "", body: note["body"] as? String ?? "",
                created: (note["created_at"] as? String).flatMap(date), system: note["system"] as? Bool ?? false,
                resolvable: note["resolvable"] as? Bool ?? false, resolved: note["resolved"] as? Bool ?? false)
        }
        let first = rawNotes.first
        return ReviewDiscussion(
            id: raw["id"] as? String ?? "", notes: notes, position: ReviewPosition.parse(first?["position"] as? [String: Any]),
            originalPosition: ReviewPosition.parse(first?["original_position"] as? [String: Any]))
    }

    // MARK: Draft notes and new threads (writes)

    /// `GET M/draft_notes`: the token user's own pending comments on GitLab.
    @concurrent
    public func draftNotes(_ ref: MergeRequestRef) async throws -> [ServerDraftNote] {
        try await getPaged(Self.mrPath(ref) + "/draft_notes?per_page=100", try Self.instance(ref), maxPages: 2).items.compactMap { raw in
            guard let id = raw["id"] as? Int else { return nil }
            return ServerDraftNote(
                id: id, body: raw["note"] as? String ?? "", discussionID: raw["discussion_id"] as? String,
                position: ReviewPosition.parse(raw["position"] as? [String: Any]))
        }
    }

    /// The payload of a draft note (also what an approval card shows).
    public static func draftNotePayload(body: String, position: ReviewPosition?, discussionID: String?, resolve: Bool?) -> JSONLike {
        var object: [String: JSONLike] = ["note": .string(body)]
        if let position { object["position"] = position.payload }
        if let discussionID { object["in_reply_to_discussion_id"] = .string(discussionID) }
        if let resolve { object["resolve_discussion"] = .bool(resolve) }
        return .object(object)
    }

    /// `POST M/draft_notes` → the draft note's ID.
    @concurrent
    public func createDraftNote(_ ref: MergeRequestRef, payload: JSONLike) async throws -> Int? {
        try await write("POST", Self.mrPath(ref) + "/draft_notes", try Self.instance(ref), body: payload)["id"] as? Int
    }

    /// `DELETE M/draft_notes/:id`.
    @concurrent
    public func deleteDraftNote(_ ref: MergeRequestRef, id: Int) async throws {
        _ = try await write("DELETE", Self.mrPath(ref) + "/draft_notes/\(id)", try Self.instance(ref), body: nil)
    }

    /// `POST M/draft_notes/bulk_publish`: publishes all of the user's draft notes on the MR as one review.
    @concurrent
    public func bulkPublishDraftNotes(_ ref: MergeRequestRef) async throws {
        _ = try await write("POST", Self.mrPath(ref) + "/draft_notes/bulk_publish", try Self.instance(ref), body: nil)
    }

    /// The payload of a new thread (`POST M/discussions`).
    public static func discussionPayload(body: String, position: ReviewPosition?) -> JSONLike {
        var object: [String: JSONLike] = ["body": .string(body)]
        if let position { object["position"] = position.payload }
        return .object(object)
    }

    /// `POST M/discussions` → the new discussion's ID.
    @concurrent
    public func createDiscussion(_ ref: MergeRequestRef, payload: JSONLike) async throws -> String? {
        try await write("POST", Self.mrPath(ref) + "/discussions", try Self.instance(ref), body: payload)["id"] as? String
    }

    // MARK: Issues

    /// One page of the project's open issues for `filter` (bounded: `issueMaxPages` pages of `issuePageSize`).
    @concurrent
    public func issues(_ project: ForgeProject, filter: IssueFilter, search: String, page: Int, projectID: Int?) async throws -> IssuePage {
        if filter == .mentioned {
            // GitLab has no "mentioned" issue filter: the person's pending to-dos that mention them on issues.
            var query = "todos?state=pending&type=Issue&per_page=50"
            if let projectID { query += "&project_id=\(projectID)" }
            var seen = Set<Int>()
            var issues: [GitLabIssue] = []
            for action in ["mentioned", "directly_addressed"] {
                let items = try await getPaged(query + "&action=\(action)", project.instance, maxPages: 1).items
                for item in items {
                    guard let target = item["target"] as? [String: Any], var issue = GitLabIssue.parse(target, projectPath: project.projectPath) else { continue }
                    issue.description = nil
                    if (item["project"] as? [String: Any])?["path_with_namespace"] as? String == project.projectPath || projectID != nil, seen.insert(issue.iid).inserted {
                        if !search.isEmpty, !issue.title.localizedCaseInsensitiveContains(search) { continue }
                        issues.append(issue)
                    }
                }
            }
            return IssuePage(issues: issues, nextPage: nil)
        }
        var query = "\(Self.projectPath(project))/issues?state=opened&order_by=updated_at&per_page=\(Self.issuePageSize)&page=\(page)"
        if filter == .assignedToMe { query += "&scope=assigned_to_me" }
        if !search.isEmpty { query += "&search=" + Self.encode(search) }
        let response = try await response(query, project.instance, cached: true)
        let issues = try Self.array(response.body).compactMap { raw -> GitLabIssue? in
            var issue = GitLabIssue.parse(raw, projectPath: project.projectPath)
            issue?.description = nil
            return issue
        }
        let next = response.headers["x-next-page"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > page ? $0 : nil }
        let bounded = next != nil && page >= Self.issueMaxPages
        return IssuePage(issues: issues, nextPage: bounded ? nil : next, bounded: bounded)
    }

    /// `GET /projects/:P/issues/:iid` with its description (bounded).
    @concurrent
    public func issue(_ project: ForgeProject, iid: Int) async throws -> GitLabIssue {
        let raw = try Self.object(try await get("\(Self.projectPath(project))/issues/\(iid)", project.instance))
        guard let issue = GitLabIssue.parse(raw, projectPath: project.projectPath) else { throw ForgeError.unexpected("GitLab returned something unexpected.") }
        return issue
    }

    /// `GET /projects/:P/issues/:iid/related_merge_requests` (one page).
    @concurrent
    public func relatedMergeRequests(_ project: ForgeProject, iid: Int) async throws -> [RelatedMergeRequest] {
        try await getPaged("\(Self.projectPath(project))/issues/\(iid)/related_merge_requests?per_page=20", project.instance, maxPages: 1).items
            .compactMap { RelatedMergeRequest.parse($0, fallbackProject: project.projectPath) }
    }

    // MARK: To-dos

    /// The token user's pending to-dos (newest first; at most two pages of 50).
    @concurrent
    public func todos(_ instance: GitLabInstance) async throws -> (todos: [GitLabTodo], truncated: Bool) {
        let list = try await getPaged("todos?state=pending&per_page=50", instance, maxPages: 2)
        return (list.items.compactMap(GitLabTodo.parse), list.truncated)
    }

    /// `POST /todos/:id/mark_as_done`.
    @concurrent
    public func markTodoDone(_ instance: GitLabInstance, id: Int) async throws {
        _ = try await write("POST", "todos/\(id)/mark_as_done", instance, body: nil)
    }

    // MARK: Approvals

    /// `GET M/approvals` (every tier): counts, who approved, whether the user may approve.
    @concurrent
    public func approvalOverview(_ ref: MergeRequestRef) async throws -> ApprovalOverview {
        let raw = try Self.object(try await get(Self.mrPath(ref) + "/approvals", try Self.instance(ref)))
        return ApprovalOverview(
            required: raw["approvals_required"] as? Int ?? 0, left: raw["approvals_left"] as? Int ?? 0,
            approvedBy: (raw["approved_by"] as? [[String: Any]] ?? []).compactMap { ($0["user"] as? [String: Any])?["username"] as? String },
            userCanApprove: raw["user_can_approve"] as? Bool, userHasApproved: raw["user_has_approved"] as? Bool,
            suggestedApprovers: (raw["suggested_approvers"] as? [[String: Any]] ?? []).compactMap { $0["username"] as? String })
    }

    /// `GET M/approval_state` rules with eligible approvers and hidden-group flags (Premium/Ultimate).
    @concurrent
    public func approvalRuleDetails(_ ref: MergeRequestRef) async throws -> [ApprovalRuleDetail] {
        let raw = try Self.object(try await get(Self.mrPath(ref) + "/approval_state", try Self.instance(ref)))
        return (raw["rules"] as? [[String: Any]] ?? []).map(ApprovalRuleDetail.parse)
    }

    /// `GET /projects/:P/approvals` (Premium/Ultimate): reset on push and author approval.
    @concurrent
    public func approvalSettings(_ project: ForgeProject) async throws -> ApprovalSettings {
        ApprovalSettings.parse(try Self.object(try await get("\(Self.projectPath(project))/approvals", project.instance)))
    }

    // MARK: Dependencies

    /// `GET M/blocks` (MRs that must merge first) or `M/blockees` (MRs waiting for this one): Premium/Ultimate.
    @concurrent
    public func dependencies(_ ref: MergeRequestRef, blockees: Bool) async throws -> [RelatedMergeRequest] {
        let items = try await getPaged(Self.mrPath(ref) + (blockees ? "/blockees" : "/blocks") + "?per_page=50", try Self.instance(ref), maxPages: 1).items
        return items.compactMap { item in
            let key = blockees ? "blocked_merge_request" : "blocking_merge_request"
            return RelatedMergeRequest.parse(item[key] as? [String: Any], fallbackProject: ref.projectPath)
        }
    }

    /// Open MRs of the project by source or target branch (the branch relationships shown when dependencies are not
    /// offered).
    @concurrent
    public func branchMergeRequests(_ project: ForgeProject, sourceBranch: String? = nil, targetBranch: String? = nil) async throws -> [RelatedMergeRequest] {
        var query = "\(Self.projectPath(project))/merge_requests?state=opened&per_page=20"
        if let sourceBranch { query += "&source_branch=" + Self.encode(sourceBranch) }
        if let targetBranch { query += "&target_branch=" + Self.encode(targetBranch) }
        return try await getPaged(query, project.instance, maxPages: 1).items.compactMap { RelatedMergeRequest.parse($0, fallbackProject: project.projectPath) }
    }
}
