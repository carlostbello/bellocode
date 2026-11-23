import BelloCore
import Foundation
import OpenCodeKit

// GitLab 2 agent tools (GitLabTools.swift): issues, positioned review threads, and a draft review comment. Reads are
// scoped like GitLab 1's (the thread's own project, or items linked to the thread) and quote external text as
// untrusted. The draft comment needs the instance's write switch and, unless the thread runs with full access in its
// own project, an approval card showing host, project, MR, head SHA, file, line and text; it is bound to the diff
// version it names and is never published by an agent.

extension ExtrasHub {
    static let maxToolDiscussions = 40

    // MARK: Issues

    /// The project and iid an `issue` argument names: `#12` in the thread's project, or an issue URL of the thread's
    /// project or of an issue linked to the thread.
    func toolIssue(_ arguments: JSONValue, _ caller: ExtrasCaller) async throws -> (ForgeProject, Int) {
        guard let text = arguments["issue"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw ExtrasError("Give issue.") }
        let own = await gitLabProject(caller)
        if let number = Int(text.hasPrefix("#") ? String(text.dropFirst()) : text) {
            guard let own else { throw ExtrasError("This thread's checkout has no origin remote on a configured GitLab instance; give the issue's URL.") }
            return (own, number)
        }
        guard let range = text.range(of: "/-/issues/"), let iid = Int(text[range.upperBound...].prefix { $0.isNumber }),
            let instance = mergeRequests.instances.sorted(by: { $0.baseURL.count > $1.baseURL.count }).first(where: { text.hasPrefix($0.baseURL + "/") })
        else { throw ExtrasError("Not an issue: give its URL (https://gitlab.example.com/group/project/-/issues/12) or #12.") }
        let path = String(text[text.index(text.startIndex, offsetBy: instance.baseURL.count + 1)..<range.lowerBound])
        let project = ForgeProject(instance: instance, projectPath: path)
        let isOwn = own.map { $0.instance == instance && $0.projectPath == path } ?? false
        let linked = gitLabWork.issues(for: caller.sessionID).contains { $0.instance == instance.baseURL && $0.projectPath == path && $0.iid == iid }
        guard isOwn || linked else {
            throw ExtrasError("\(path)#\(iid) is outside this thread's GitLab project\(own.map { " (\($0.projectPath))" } ?? ""). The user can link it to the thread from the Issues panel.")
        }
        return (project, iid)
    }

    func readIssueTool(_ arguments: JSONValue, _ caller: ExtrasCaller) async throws -> ClientMCPResult {
        let (project, iid) = try await toolIssue(arguments, caller)
        let issue = try await gitLabWork.loadIssue(project, iid: iid)
        let known = await mergeRequests.knownSecrets(project.instance.baseURL)
        // Header fields come from GitLab too: cleaned, on one line, redacted (GF13).
        let field = { (text: String) in UntrustedText.field(text, known: known) }
        var lines = ["Source: \(field(issue.webURL)) · \(project.instance.baseURL) · \(field(issue.reference)) · read \(Self.dateText(Date()))"]
        lines.append("State: \(issue.stateLabel); author @\(field(issue.author)); assignees: \(issue.assignees.isEmpty ? "none" : issue.assignees.map { "@\(field($0))" }.joined(separator: ", "))")
        if !issue.labels.isEmpty { lines.append("Labels: \(issue.labels.map(field).joined(separator: ", "))") }
        if let related = gitLabWork.relatedMergeRequests[issue.webURL] {
            lines.append("Related merge requests: \(related.isEmpty ? "none" : related.map { "\(field($0.reference)) (\(field($0.state)))" }.joined(separator: ", "))")
        } else {
            lines.append("Related merge requests: not reported by this instance.")
        }
        if issue.descriptionTruncated { lines.append("The description is longer on GitLab; the start is quoted.") }
        let body = "Title: \(field(issue.title))\n\n" + ((issue.description ?? "").isEmpty ? "(no description)" : UntrustedText.sanitise(issue.description ?? "", limit: 12_000, known: known))
        lines.append(UntrustedText.block("issue \(issue.reference)", body))
        return ClientMCPResult(text: lines.joined(separator: "\n"))
    }

    func listIssuesTool(_ arguments: JSONValue, _ caller: ExtrasCaller) async throws -> ClientMCPResult {
        guard let project = await gitLabProject(caller) else { throw ExtrasError("This thread's checkout has no origin remote on a configured GitLab instance.") }
        let filter: IssueFilter =
            switch arguments["filter"]?.stringValue?.lowercased() {
            case "all": .all
            case "mentioned": .mentioned
            default: .assignedToMe
            }
        let page = min(GitLabProvider.issueMaxPages, max(1, arguments["page"]?.intValue ?? 1))
        let search = arguments["search"]?.stringValue ?? ""
        let projectID = filter == .mentioned ? try? await gitLabWork.projectID(project) : nil
        let result = try await mergeRequests.provider.issues(project, filter: filter, search: search, page: page, projectID: projectID)
        let known = await mergeRequests.knownSecrets(project.instance.baseURL)
        let field = { (text: String) in UntrustedText.field(text, known: known) }
        let body = result.issues.map { issue in
            "#\(issue.iid) [\(issue.stateLabel)] \(field(issue.title))"
                + (issue.assignees.isEmpty ? "" : " — " + issue.assignees.map { "@\(field($0))" }.joined(separator: ", "))
                + (issue.labels.isEmpty ? "" : " — " + issue.labels.map(field).joined(separator: ", "))
        }.joined(separator: "\n")
        var lines = ["Source: \(project.instance.baseURL)/\(project.projectPath)/-/issues · \(filter.title) · page \(page) · read \(Self.dateText(Date()))"]
        lines.append("\(result.issues.count) issue(s)." + (result.nextPage.map { " More on page \($0)." } ?? "") + (result.bounded ? " More on GitLab beyond what BelloCode lists (5 pages); search to narrow." : ""))
        lines.append(UntrustedText.block("issues of \(project.projectPath)", body.isEmpty ? "(none)" : body))
        return ClientMCPResult(text: lines.joined(separator: "\n"))
    }

    // MARK: Review threads

    func readReviewDiscussionsTool(_ arguments: JSONValue, _ caller: ExtrasCaller) async throws -> ClientMCPResult {
        let (ref, _) = try await toolRef(arguments, caller)
        guard let state = await reviews.load(ref) else { throw ExtrasError(Self.reviewProblem(reviews.phases[ref.url])) }
        let unresolvedOnly = arguments["unresolvedOnly"]?.boolValue ?? false
        let known = await mergeRequests.knownSecrets(ref.instance)
        let field = { (text: String) in UntrustedText.field(text, known: known) }
        let anchored = state.anchored.filter { !unresolvedOnly || ($0.discussion.isResolvable && !$0.discussion.isResolved) }
        let shown = anchored.suffix(Self.maxToolDiscussions)
        let body = shown.map { entry -> String in
            let place: String = switch entry.anchor {
            case .line(let path, let side, let line, let start): "at \(field(path)) \(side.rawValue) line \(start.map { "\($0)–" } ?? "")\(line) (current version)"
            case .file(let path, let reason): "at \(field(path)) (file level: \(reason))"
            case .outdated(let position): "outdated: written at \(field(position.label)) on head \(field(String(position.refs.headSHA.prefix(12))))"
            case .general: "general comment"
            }
            let notes = entry.discussion.visibleNotes.map { note in
                "  note \(note.id) by @\(field(note.author)): " + UntrustedText.sanitise(note.body, limit: 1_500, known: known).replacingOccurrences(of: "\n", with: "\n    ")
            }
            return (["discussion \(field(entry.discussion.id)) [\(entry.discussion.stateWord)] \(place)"] + notes).joined(separator: "\n")
        }.joined(separator: "\n")
        var lines = [
            "Source: \(ref.url) · \(ref.instance) · \(ref) · version head \(field(state.refs.headSHA)) base \(field(state.refs.baseSHA)) start \(field(state.refs.startSHA)) · read \(Self.dateText(state.loaded))"
        ]
        lines.append("\(anchored.count) thread(s)\(anchored.count > shown.count ? "; the last \(shown.count) shown" : "")." + (state.discussionsIncomplete ? " The list is incomplete (paging bound)." : ""))
        lines.append("Files in this version: " + state.diff.files.prefix(60).map { $0.renamedFile ? "\(field($0.oldPath)) → \(field($0.newPath))" : field($0.newPath) }.joined(separator: ", ") + (state.diff.incomplete ? " (more not loaded)" : ""))
        lines.append(UntrustedText.block("review threads of \(ref)", body.isEmpty ? "(none)" : body))
        return ClientMCPResult(text: lines.joined(separator: "\n"))
    }

    static func reviewProblem(_ phase: MergeRequestReviewService.Phase?) -> String {
        switch phase {
        case .preparing?: "GitLab is still preparing this merge request's diff; try again shortly."
        case .failed(let reason)?: reason
        default: "The merge request's diff could not be read."
        }
    }

    // MARK: Draft comment

    func requestDraftComment(_ arguments: JSONValue, _ caller: ExtrasCaller) async throws -> ClientMCPResult {
        let (ref, own) = try await toolRef(arguments, caller)
        guard let path = arguments["path"]?.stringValue, !path.isEmpty, let line = arguments["line"]?.intValue,
            let body = arguments["body"]?.stringValue, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ExtrasError("Give path, line and body.") }
        let side: ReviewSide = arguments["side"]?.stringValue?.lowercased() == "old" ? .old : .new
        let first = min(arguments["startLine"]?.intValue ?? line, line)
        try mergeRequests.requireWrites(ref.instance)
        guard let state = await reviews.load(ref) else { throw ExtrasError(Self.reviewProblem(reviews.phases[ref.url])) }
        guard let file = state.diff.files.first(where: { $0.newPath == path || $0.oldPath == path }) else {
            throw ExtrasError("\(path) is not in the latest version of \(ref) (gitlab_read_review_discussions lists its files).")
        }
        guard let position = file.lines.position(refs: state.refs, side: side, first: first, last: line) else {
            throw ExtrasError("\(side == .old ? "Old line" : "Line") \(first == line ? "\(line)" : "\(first)–\(line)") of \(path) is not in the diff; GitLab only takes comments on lines of the diff.")
        }
        let serverDraft = mergeRequests.capabilities(ref.instance).support(.draftNotes).isAvailable && state.serverDrafts != nil
        let snapshot = try? await freshSnapshot(ref)
        let lines = first == line ? "\(line)" : "\(first)–\(line)"
        let payload = GitLabProvider.draftNotePayload(body: body, position: position, discussionID: nil, resolve: nil)
        let detail = """
            GitLab: \(ref.instance)
            Project: \(ref.projectPath)\(own ? "" : " (not this thread's project)")
            Merge request: !\(ref.iid)\(snapshot.map { " “\($0.title)”" } ?? "") at head \(state.refs.headSHA.prefix(12))
            File: \(file.renamedFile ? "\(file.oldPath) → \(file.newPath)" : file.newPath) (\(side == .old ? "old side" : "new side"))
            Line: \(lines)
            Text:
            \(body)
            Saved as: \(serverDraft ? "a GitLab draft note (unpublished; the user submits the review)" : "a BelloCode review draft (this instance offers no draft notes); the user sends it")
            Request: \(serverDraft ? "POST /\(GitLabProvider.mrPath(ref))/draft_notes" : "none until the user submits")
            Payload:
            \(payload.prettyText)
            """
        let pending = PendingGitLabWrite(
            sessionID: caller.sessionID,
            action: .draftComment(ref, path: file.newPath.isEmpty ? file.oldPath : file.newPath, side: side, first: first, last: line, body: body, refs: state.refs, serverDraft: serverDraft),
            sha: state.refs.headSHA, summary: "Add a draft review comment on \(path):\(lines)", digest: SHA256Hex.of(detail))
        if caller.permissionMode == .fullAccess, own {
            return ClientMCPResult(text: try await executeGitLabWrite(pending))
        }
        await raiseGitLabCard(pending, title: "Add a draft review comment", detail: detail, scope: "\(ref.instance) · \(ref.projectPath)")
        return ClientMCPResult(text: "Asked the user to approve this draft comment (a card shows it). Nothing was saved yet; it will be a draft only, never published by you. You are woken with the result; end your turn now.")
    }

    /// Saves the approved draft comment, bound to the version it named: if the MR moved since, nothing is saved.
    func executeDraftComment(
        _ ref: MergeRequestRef, path: String, side: ReviewSide, first: Int, last: Int, body: String, refs: DiffRefs, serverDraft: Bool
    ) async throws -> String {
        try mergeRequests.requireWrites(ref.instance)
        guard let state = await reviews.load(ref) else { throw ExtrasError(Self.reviewProblem(reviews.phases[ref.url])) }
        guard state.refs == refs else {
            throw ExtrasError("\(ref) changed since this was asked (head \(refs.headSHA.prefix(12)) → \(state.refs.headSHA.prefix(12))). Nothing was saved; read the review threads again and ask again.")
        }
        if serverDraft {
            guard let file = state.diff.files.first(where: { $0.newPath == path || $0.oldPath == path }),
                let position = file.lines.position(refs: refs, side: side, first: first, last: last)
            else { throw ExtrasError("That line is no longer in the diff. Nothing was saved.") }
            let id = try await mergeRequests.provider.createDraftNote(ref, payload: GitLabProvider.draftNotePayload(body: body, position: position, discussionID: nil, resolve: nil))
            await reviews.load(ref)
            return "Saved a GitLab draft note\(id.map { " (\($0))" } ?? "") on \(path):\(first == last ? "\(last)" : "\(first)–\(last)") of \(ref). It is not published; the user submits the review."
        }
        let draft = try await reviews.addDraft(ref, path: path, side: side, first: first, last: last, body: body, byAgent: true)
        return "Saved a BelloCode review draft (\(draft.id)) on \(path):\(first == last ? "\(last)" : "\(first)–\(last)") of \(ref). This instance offers no GitLab draft notes; the user sends it from the review."
    }
}
