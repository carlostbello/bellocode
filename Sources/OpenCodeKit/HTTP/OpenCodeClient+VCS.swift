import Foundation

// VCS status and diffs, worktrees, per-turn diffs and revert (M2-C, docs/features/diff-git.md). Every route was checked
// against Contracts/opencode-2.3.0/openapi.json and the pinned binary.

extension OpenCodeClient {
    // MARK: VCS

    /// `GET /api/vcs` (vcs.get). The branch can be empty on the first call for a location.
    public func vcsInfo(directory: String) async throws -> VcsInfo {
        let request = try makeRequest(.get, ["api", "vcs"], directory: directory)
        return try await send("vcs.get", request, as: DataEnvelope<VcsInfo>.self).data
    }

    /// `GET /api/vcs/base` (vcs.base): nil outside a repository or without a base.
    public func vcsBase(directory: String) async throws -> VcsBase? {
        let request = try makeRequest(.get, ["api", "vcs", "base"], directory: directory)
        return try await send("vcs.base", request, as: DataEnvelope<VcsBase?>.self).data
    }

    /// `GET /api/vcs/status` (vcs.status): changed files with line counts (untracked files as `added`).
    public func vcsStatus(directory: String) async throws -> [VcsFileStatus] {
        let request = try makeRequest(.get, ["api", "vcs", "status"], directory: directory)
        return try await send("vcs.status", request, as: LocatedList<VcsFileStatus>.self).data
    }

    /// `GET /api/vcs/branch` (vcs.branch.list): local branch names.
    public func vcsBranches(directory: String, search: String? = nil, limit: Int? = nil) async throws -> [String] {
        var query: [(String, String)] = []
        if let search { query.append(("search", search)) }
        if let limit { query.append(("limit", String(limit))) }
        let request = try makeRequest(.get, ["api", "vcs", "branch"], query: query, directory: directory)
        return try await send("vcs.branch.list", request, as: DataEnvelope<[String]>.self).data
    }

    /// `GET /api/vcs/diff` (vcs.diff). `base` overrides the repository's default comparison without saving it;
    /// `context` is the number of unchanged lines around each hunk.
    public func vcsDiff(
        directory: String, mode: VcsDiffMode, base: String? = nil, context: Int? = nil, untracked: VcsUntracked? = nil
    ) async throws -> [FileDiffInfo] {
        var query: [(String, String)] = [("mode", mode.rawValue)]
        if let base { query.append(("base", base)) }
        if let context { query.append(("context", String(context))) }
        if let untracked { query.append(("untracked", untracked.rawValue)) }
        let request = try makeRequest(.get, ["api", "vcs", "diff"], query: query, directory: directory, timeout: .seconds(60))
        return try await send("vcs.diff", request, as: LocatedList<FileDiffInfo>.self).data
    }

    // MARK: Per-turn diff and revert

    /// `GET /api/session/{id}/diff` (session.diff): the files a turn changed, from its first snapshot to its last (a
    /// running step compares with the working copy). `from` is the turn's user message (default: the newest turn);
    /// `to` extends the range through a later turn. Without `context` each patch holds the whole file.
    public func sessionDiff(sessionID: String, from: String? = nil, to: String? = nil, context: Int? = nil) async throws -> [FileDiffInfo] {
        var query: [(String, String)] = []
        if let from { query.append(("from", from)) }
        if let to { query.append(("to", to)) }
        if let context { query.append(("context", String(context))) }
        let request = try makeRequest(.get, ["api", "session", sessionID, "diff"], query: query, timeout: .seconds(60))
        return try await send("session.diff", request, as: DataEnvelope<[FileDiffInfo]>.self).data
    }

    /// `POST /api/session/{id}/revert/stage` (session.revert.stage): stage (or move) the revert boundary at a user
    /// message; with `files` the working copy is restored to the turn's start. Measured on 2.3.0: restoring replaces
    /// whole files, so edits made after the turn are lost (callers must check first).
    public func stageRevert(sessionID: String, messageID: String, files: Bool) async throws -> SessionRevertInfo {
        let request = try makeRequest(
            .post, ["api", "session", sessionID, "revert", "stage"], body: RevertStageBody(messageID: messageID, files: files))
        return try await send("session.revert.stage", request, as: DataEnvelope<SessionRevertInfo>.self).data
    }

    /// `DELETE /api/session/{id}/revert` (session.revert.clear): drop the staged boundary; files return to the
    /// snapshot taken when it was staged (2.3.0).
    public func clearRevert(sessionID: String) async throws {
        try await sendIgnoringBody("session.revert.clear", makeRequest(.delete, ["api", "session", sessionID, "revert"]))
    }

    /// `POST /api/session/{id}/revert/commit` (session.revert.commit): make the staged revert permanent.
    public func commitRevert(sessionID: String) async throws {
        try await sendIgnoringBody("session.revert.commit", makeRequest(.post, ["api", "session", sessionID, "revert", "commit"]))
    }

    // MARK: Worktrees

    /// `GET /api/worktree` (worktree.list): the project's saved worktrees, the main checkout included.
    public func worktrees(projectID: String) async throws -> [WorktreeDirectory] {
        let request = try makeRequest(.get, ["api", "worktree"], query: [("projectID", projectID)])
        return try await send("worktree.list", request, as: [WorktreeDirectory].self)
    }

    /// `POST /api/worktree` (worktree.create). Runs the project's start command. See `WorktreeCreateRequest`.
    public func createWorktree(_ body: WorktreeCreateRequest) async throws -> WorktreeInfo {
        let request = try makeRequest(.post, ["api", "worktree"], body: body, timeout: .seconds(300))
        return try await send("worktree.create", request, as: WorktreeInfo.self)
    }

    /// `DELETE /api/worktree` (worktree.remove). Without `force` a worktree holding changes is refused
    /// (`WorktreeError` with `forceRequired`).
    public func removeWorktree(projectID: String, directory: String, force: Bool) async throws {
        let request = try makeRequest(
            .delete, ["api", "worktree"], body: WorktreeRemoveBody(projectID: projectID, directory: directory, force: force))
        try await sendIgnoringBody("worktree.remove", request)
    }

    /// `POST /api/worktree/refresh` (worktree.refresh): re-discover the project's worktrees (adopts ones created with
    /// git directly).
    public func refreshWorktrees(projectID: String) async throws {
        let request = try makeRequest(.post, ["api", "worktree", "refresh"], body: WorktreeRefreshBody(projectID: projectID))
        try await sendIgnoringBody("worktree.refresh", request)
    }
}

extension OpenCodeError {
    /// The `WorktreeError` payload, when this is one.
    public var worktreeError: WorktreeErrorData? {
        guard case .http(_, let body, _) = self, let body, body.tag.rawValue == "WorktreeError",
              let data = body.fields["data"], let message = data["message"]?.stringValue
        else { return nil }
        return WorktreeErrorData(message: message, forceRequired: data["forceRequired"]?.boolValue)
    }
}
