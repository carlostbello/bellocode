import BelloCore
import Foundation
import OpenCodeKit

// The GitLab broker for agents (GitLabTools.swift) and the babysit gate. Never returns the token or request headers;
// every result names its source (host, project, MR, SHA, time) and quotes external text as untrusted.

extension ExtrasHub {
    static let maxPendingGitLabWrites = 16

    // MARK: Scope

    /// The thread's GitLab project (its checkout's `origin`), if it is on a configured instance.
    func gitLabProject(_ caller: ExtrasCaller) async -> ForgeProject? {
        guard let checkout = await checkout(of: caller.sessionID) else { return nil }
        return ForgeProject.resolve(remote: checkout.remote, instances: mergeRequests.instances)
    }

    /// The MR a tool call names (or the thread's only linked MR), and whether it is in the thread's own GitLab project.
    /// Other projects are allowed only for MRs linked to the thread (linking is visible to the person).
    func toolRef(_ arguments: JSONValue, _ caller: ExtrasCaller) async throws -> (ref: MergeRequestRef, ownProject: Bool) {
        let ref: MergeRequestRef
        if let text = arguments["ref"]?.stringValue, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            ref = try await mergeRequests.resolve(text, for: caller.sessionID)
        } else {
            let links = mergeRequests.links(for: caller.sessionID)
            guard links.count == 1 else {
                throw ExtrasError(links.isEmpty ? "Give ref: no merge request is linked to this thread." : "Give ref: this thread has \(links.count) linked merge requests.")
            }
            ref = links[0].ref
        }
        let project = await gitLabProject(caller)
        let own = project.map { $0.instance.baseURL == ref.instance && $0.projectPath == ref.projectPath } ?? false
        guard own || mergeRequests.links(for: caller.sessionID).contains(where: { $0.ref == ref }) else {
            throw ExtrasError(
                "\(ref) is outside this thread's GitLab project\(project.map { " (\($0.projectPath))" } ?? ""). Link it to the thread first (link_merge_requests), which the user sees.")
        }
        return (ref, own)
    }

    /// The header every read result starts with: where it came from and how fresh it is.
    func sourceLine(_ snapshot: MergeRequestSnapshot) -> String {
        let stale = mergeRequests.failureKinds[snapshot.ref.url].map { " (\($0.label): cached data from \(Self.dateText(snapshot.fetched)))" } ?? ""
        return "Source: \(snapshot.webURL) · \(snapshot.ref.instance) · \(snapshot.ref) · head \(snapshot.sha.prefix(12)) · read \(Self.dateText(snapshot.fetched))\(stale)"
    }

    func freshSnapshot(_ ref: MergeRequestRef) async throws -> MergeRequestSnapshot {
        if let snapshot = await mergeRequests.refresh(ref) { return snapshot }
        if let cached = mergeRequests.snapshots[ref.url] { return cached }
        throw ExtrasError(mergeRequests.problems[ref.url] ?? "GitLab could not be read.")
    }

    // MARK: Routing

    func handleGitLab(_ call: ClientMCPCall, caller: ExtrasCaller) async throws -> ClientMCPResult {
        let arguments = call.arguments
        // The instance's token, read once per call off the main actor (GF12), never per note or file.
        func known(_ ref: MergeRequestRef) async -> [String] { await mergeRequests.knownSecrets(ref.instance) }
        switch call.tool {
        case GitLabTools.readMergeRequest:
            let (ref, _) = try await toolRef(arguments, caller)
            let snapshot = try await freshSnapshot(ref)
            let description = (try? await mergeRequests.provider.mergeRequestDescription(ref)) ?? ""
            let known = await known(ref)
            var lines = [sourceLine(snapshot)]
            lines.append("Title: \(snapshot.title)")
            lines.append("State: \(snapshot.stateLabel); \(snapshot.sourceBranch) → \(snapshot.targetBranch); author @\(snapshot.author)")
            lines.append("Pipeline: \(snapshot.pipelineSummary.text)\(snapshot.pipeline.map { " (#\($0.id))" } ?? ""); approvals: \(snapshot.approvals.label); \(snapshot.unresolvedText)")
            if let labels = snapshot.labels, !labels.isEmpty { lines.append("Labels: \(labels.joined(separator: ", "))") }
            if let reviewers = snapshot.reviewers { lines.append("Reviewers: \(reviewers.isEmpty ? "none" : reviewers.map { "@\($0)" }.joined(separator: ", "))") }
            if let status = snapshot.mergeStatus { lines.append("Merge status: \(status)") }
            if let note = snapshot.truncationNote { lines.append(note) }
            lines.append(UntrustedText.block("description of \(ref)", description.isEmpty ? "(empty)" : UntrustedText.sanitise(description, limit: 6_000, known: known)))
            return ClientMCPResult(text: lines.joined(separator: "\n"))
        case GitLabTools.readChanges:
            let (ref, _) = try await toolRef(arguments, caller)
            let snapshot = try await freshSnapshot(ref)
            var changes = try await mergeRequests.provider.changes(ref)
            let known = await known(ref)
            if let filter = arguments["path"]?.stringValue, !filter.isEmpty {
                changes.files = changes.files.filter { $0.newPath.contains(filter) || $0.oldPath.contains(filter) }
            }
            let body: String = changes.files.map { file -> String in
                let name = file.renamedFile ? "\(file.oldPath) → \(file.newPath)" : file.newPath
                let flags = [file.newFile ? "new" : nil, file.deletedFile ? "deleted" : nil, file.tooLarge ? "too large: content not returned" : nil, file.truncated ? "cut" : nil].compactMap { $0 }
                return "=== \(name)\(flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))")\n\(UntrustedText.redact(file.diff, known: known).text)"
            }.joined(separator: "\n")
            let note = changes.incomplete ? "Incomplete: more files or bytes than BelloCode returns (60 files, 64 KB)." : "Complete."
            let parts: [String] = [sourceLine(snapshot), "\(changes.files.count) file(s). \(note)", UntrustedText.block("diff of \(ref)", body)]
            return ClientMCPResult(text: parts.joined(separator: "\n"))
        case GitLabTools.listDiscussions:
            let (ref, _) = try await toolRef(arguments, caller)
            let snapshot = try await freshSnapshot(ref)
            let unresolvedOnly = arguments["unresolvedOnly"]?.boolValue ?? true
            let list = (snapshot.discussions ?? []).filter { !$0.isSystem && (!unresolvedOnly || $0.isUnresolved) }
            let shown = list.suffix(30)
            let known = await known(ref)
            let body: String = shown.map { discussion -> String in
                let head = "discussion \(discussion.id) [\(discussion.isUnresolved ? "unresolved" : discussion.isResolvable ? "resolved" : "comment")]\(discussion.position.map { " on \($0)" } ?? "")"
                let notes: [String] = discussion.notes.filter { !$0.system }.map { note in
                    let body: String = UntrustedText.sanitise(note.body, limit: 1_500, known: known).replacingOccurrences(of: "\n", with: "\n    ")
                    return String("  note \(note.id) by @\(note.author): ") + body
                }
                return ([head] + notes).joined(separator: "\n")
            }.joined(separator: "\n")
            var lines = [sourceLine(snapshot), "\(list.count) \(unresolvedOnly ? "unresolved " : "")discussion(s)\(list.count > shown.count ? "; the last \(shown.count) shown" : "")."]
            if let note = snapshot.truncationNote { lines.append(note) }
            lines.append(UntrustedText.block("discussions of \(ref)", body.isEmpty ? "(none)" : body))
            return ClientMCPResult(text: lines.joined(separator: "\n"))
        case GitLabTools.readPipeline:
            let (ref, _) = try await toolRef(arguments, caller)
            let snapshot = try await freshSnapshot(ref)
            guard let pipeline = snapshot.pipeline else { return ClientMCPResult(text: sourceLine(snapshot) + "\nNo pipeline for the head commit.") }
            var lines = [sourceLine(snapshot), "Pipeline #\(pipeline.id): \(snapshot.pipelineSummary.text)\(pipeline.sha.map { " at \($0.prefix(12))" } ?? ""). \(pipeline.webURL ?? "")"]
            for stage in pipeline.stages {
                lines.append("Stage \(stage.name):")
                for job in stage.jobs {
                    var line = "  job \(job.id) \(job.name): \(job.status)"
                    if job.allowFailure == true { line += " (failure allowed)" }
                    if let reason = job.failureReason { line += ", \(reason)" }
                    if job.isManual { line += " (manual: running it needs the user's approval)" }
                    lines.append(line)
                }
            }
            if let note = snapshot.truncationNote { lines.append(note) }
            return ClientMCPResult(text: lines.joined(separator: "\n"))
        case GitLabTools.readJobLog:
            let (ref, _) = try await toolRef(arguments, caller)
            guard let jobID = arguments["jobID"]?.intValue else { throw ExtrasError("Give jobID.") }
            let snapshot = try await freshSnapshot(ref)
            guard let job = snapshot.pipeline?.jobs.first(where: { $0.id == jobID }) else {
                throw ExtrasError("Job \(jobID) is not in \(ref)'s head pipeline (see gitlab_read_pipeline).")
            }
            switch await mergeRequests.jobLog(ref, jobID: jobID, maxBytes: 64 << 10) {
            case .success(let chunk):
                let excerpt = JobLogExcerpt(log: chunk.text, headOmitted: chunk.headOmitted, known: await known(ref))
                return ClientMCPResult(
                    text: [
                        sourceLine(snapshot), "Job \(job.id) \(job.name) (stage \(job.stage)): \(job.status). \(job.webURL ?? "")",
                        UntrustedText.block("log excerpt of job \(job.name) #\(job.id)", excerpt.text),
                    ].joined(separator: "\n"))
            case .failure(let error):
                throw ExtrasError(error.description)
            }
        case GitLabTools.readApprovals:
            let (ref, _) = try await toolRef(arguments, caller)
            let snapshot = try await freshSnapshot(ref)
            await mergeRequests.loadApprovalRules(ref)
            var lines = [sourceLine(snapshot), "Approvals: \(snapshot.approvals.label)."]
            if !snapshot.approvals.approvedBy.isEmpty { lines.append("Approved by: \(snapshot.approvals.approvedBy.map { "@\($0)" }.joined(separator: ", "))") }
            if let rules = mergeRequests.approvalRules[ref.url], !rules.isEmpty {
                for rule in rules {
                    lines.append("Rule \(rule.isCodeOwner ? "Code Owners" : rule.name)\(rule.section.map { " (\($0))" } ?? ""): \(rule.approvedBy.count) of \(rule.required)\(rule.approved ? ", satisfied" : "")")
                }
            } else {
                lines.append("Required approval rules: not reported by this instance (Free has optional approvals only).")
            }
            lines.append("Agents cannot approve or merge.")
            return ClientMCPResult(text: lines.joined(separator: "\n"))
        case GitLabTools.readIssue: return try await readIssueTool(arguments, caller)
        case GitLabTools.listIssues: return try await listIssuesTool(arguments, caller)
        case GitLabTools.readReviewDiscussions: return try await readReviewDiscussionsTool(arguments, caller)
        case GitLabTools.createDraftComment: return try await requestDraftComment(arguments, caller)
        default:
            return try await requestGitLabWrite(call, caller)
        }
    }

    // MARK: Writes

    private func requestGitLabWrite(_ call: ClientMCPCall, _ caller: ExtrasCaller) async throws -> ClientMCPResult {
        let arguments = call.arguments
        var action: PendingGitLabWrite.Action
        var ownProject: Bool
        var sha: String?
        let instanceURL: String
        let projectPath: String
        var mrLabel = "new merge request"
        var request: String
        var payload: JSONLike?
        var title: String
        switch call.tool {
        case GitLabTools.createMergeRequest:
            guard let project = await gitLabProject(caller), let checkout = await checkout(of: caller.sessionID) else {
                throw ExtrasError("This thread's checkout has no origin remote on a configured GitLab instance.")
            }
            guard let raw = arguments["title"]?.stringValue, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { throw ExtrasError("Give title.") }
            var target = arguments["targetBranch"]?.stringValue ?? ""
            if target.isEmpty { target = (try? await mergeRequests.projectInfo(project))?.defaultBranch ?? "main" }
            let draft = MergeRequestDraft(
                sourceBranch: checkout.branch, targetBranch: target, title: raw, description: arguments["description"]?.stringValue ?? "",
                draft: arguments["draft"]?.boolValue ?? false, removeSourceBranch: true)
            if let problem = draft.problems.first { throw ExtrasError(problem) }
            action = .create(project, draft)
            ownProject = true
            instanceURL = project.instance.baseURL
            projectPath = project.projectPath
            request = "POST /projects/\(GitLabProvider.encode(project.projectPath))/merge_requests"
            payload = .object(draft.payload)
            title = "Create a merge request on GitLab"
        default:
            let (ref, own) = try await toolRef(arguments, caller)
            ownProject = own
            instanceURL = ref.instance
            projectPath = ref.projectPath
            let snapshot = try await freshSnapshot(ref)
            sha = snapshot.sha
            mrLabel = "!\(ref.iid) “\(snapshot.title)” at \(snapshot.sha.prefix(12))"
            let mrPath = GitLabProvider.mrPath(ref)
            switch call.tool {
            case GitLabTools.updateMergeRequest:
                var fields: [String: JSONLike] = [:]
                if let value = arguments["title"]?.stringValue { fields["title"] = .string(value) }
                if let value = arguments["description"]?.stringValue { fields["description"] = .string(value) }
                guard !fields.isEmpty else { throw ExtrasError("Give title and/or description.") }
                action = .update(ref, fields)
                request = "PUT /\(mrPath)"
                payload = .object(fields)
                title = "Edit a merge request on GitLab"
            case GitLabTools.replyToDiscussion:
                guard let discussion = arguments["discussionID"]?.stringValue, let body = arguments["body"]?.stringValue, !body.isEmpty else {
                    throw ExtrasError("Give discussionID and body.")
                }
                guard snapshot.discussions?.contains(where: { $0.id == discussion }) ?? true else { throw ExtrasError("No discussion \(discussion) on \(ref).") }
                action = .reply(ref, discussionID: discussion, body: body)
                request = "POST /\(mrPath)/discussions/\(discussion)/notes"
                payload = .object(["body": .string(body)])
                title = "Reply on a merge request"
            case GitLabTools.resolveDiscussion:
                guard let discussion = arguments["discussionID"]?.stringValue else { throw ExtrasError("Give discussionID.") }
                let resolved = arguments["resolved"]?.boolValue ?? true
                action = .resolve(ref, discussionID: discussion, resolved: resolved)
                request = "PUT /\(mrPath)/discussions/\(discussion)"
                payload = .object(["resolved": .bool(resolved)])
                title = resolved ? "Resolve a discussion" : "Reopen a discussion"
            case GitLabTools.retryJob, GitLabTools.playJob:
                guard let jobID = arguments["jobID"]?.intValue else { throw ExtrasError("Give jobID.") }
                guard let job = snapshot.pipeline?.jobs.first(where: { $0.id == jobID }) else { throw ExtrasError("Job \(jobID) is not in \(ref)'s head pipeline.") }
                let play = call.tool == GitLabTools.playJob
                if play, !job.isManual { throw ExtrasError("Job \(job.name) is not a manual job (\(job.status)).") }
                if !play, !job.isRetryable { throw ExtrasError("Job \(job.name) cannot be retried while \(job.status).") }
                action = play ? .play(ref, jobID: jobID) : .retry(ref, jobID: jobID)
                request = "POST /projects/\(GitLabProvider.encode(ref.projectPath))/jobs/\(jobID)/\(play ? "play" : "retry")"
                payload = nil
                title = play ? "Run manual job “\(job.name)” (may deploy)" : "Retry job “\(job.name)”"
            default:
                return .error("Unknown tool \(call.tool).")
            }
        }
        try mergeRequests.requireWrites(instanceURL)
        let detail = """
            GitLab: \(instanceURL)
            Project: \(projectPath)\(ownProject ? "" : " (not this thread's project)")
            Merge request: \(mrLabel)
            Request: \(request)
            Payload:
            \(payload?.prettyText ?? "(none)")
            """
        let digest = SHA256Hex.of(detail)
        let pending = PendingGitLabWrite(sessionID: caller.sessionID, action: action, sha: sha, summary: title, digest: digest)
        let isPlay = { if case .play = action { true } else { false } }()
        // Full access in the thread's own project acts at once; manual jobs and other projects always ask.
        if caller.permissionMode == .fullAccess, ownProject, !isPlay {
            return ClientMCPResult(text: try await executeGitLabWrite(pending))
        }
        if pendingGitLabWrites.count >= Self.maxPendingGitLabWrites, let oldest = pendingGitLabWrites.keys.sorted().first { pendingGitLabWrites[oldest] = nil }
        let subject = AppRequest.makeID("glw")
        pendingGitLabWrites[subject] = pending
        await core.putAppRequest(
            AppRequest(
                id: AppRequest.makeID("glw"), sessionID: caller.sessionID,
                kind: .approval(AppApproval(action: .gitlabWrite, title: title, detail: detail, scope: "\(instanceURL) · \(projectPath)", subjectID: subject, allowsAlways: false, digest: digest)),
                received: .now))
        return ClientMCPResult(
            text: "Asked the user to approve this exact GitLab request (a card shows it). Nothing was sent yet. You are woken with the result (or the refusal); end your turn now.")
    }

    /// Sends an approved (or policy-allowed) write once. The MR's head must still be the SHA the card showed.
    func executeGitLabWrite(_ pending: PendingGitLabWrite) async throws -> String {
        let provider = mergeRequests.provider
        func checkSHA(_ ref: MergeRequestRef) async throws {
            guard let sha = pending.sha else { return }
            let current = try await freshSnapshot(ref)
            guard current.sha == sha else {
                throw ExtrasError("\(ref) changed since this was asked (head \(sha.prefix(12)) → \(current.sha.prefix(12))). Nothing was sent; read it again and ask again.")
            }
        }
        do {
            switch pending.action {
            case .create(let project, let draft):
                let ref = try await mergeRequests.createMergeRequest(draft, in: project, for: pending.sessionID)
                return "Created \(ref): \(ref.url) (linked to this thread)."
            case .update(let ref, let fields):
                try mergeRequests.requireWrites(ref.instance)
                try await checkSHA(ref)
                try await provider.updateMergeRequest(ref, fields: fields)
                await mergeRequests.refresh(ref)
                return "Updated \(ref) (\(fields.keys.sorted().joined(separator: ", ")))."
            case .reply(let ref, let discussion, let body):
                try mergeRequests.requireWrites(ref.instance)
                try await checkSHA(ref)
                let id = try await provider.reply(ref, discussionID: discussion, body: body)
                await mergeRequests.refresh(ref)
                return "Replied in discussion \(discussion) of \(ref)\(id.map { " (note \($0))" } ?? "")."
            case .resolve(let ref, let discussion, let resolved):
                try mergeRequests.requireWrites(ref.instance)
                try await checkSHA(ref)
                try await provider.resolve(ref, discussionID: discussion, resolved: resolved)
                await mergeRequests.refresh(ref)
                return "\(resolved ? "Resolved" : "Reopened") discussion \(discussion) of \(ref)."
            case .retry(let ref, let jobID):
                let id = try await mergeRequests.retryJob(ref, jobID: jobID)
                return "Retried job \(jobID) of \(ref)\(id.map { " (new job \($0))" } ?? "")."
            case .play(let ref, let jobID):
                let id = try await mergeRequests.playJob(ref, jobID: jobID)
                return "Started manual job \(jobID) of \(ref)\(id.map { " (job \($0))" } ?? "")."
            case .draftComment(let ref, let path, let side, let first, let last, let body, let refs, let serverDraft):
                return try await executeDraftComment(ref, path: path, side: side, first: first, last: last, body: body, refs: refs, serverDraft: serverDraft)
            }
        } catch let error as ForgeError {
            throw ExtrasError(error.description)
        }
    }

    /// Puts a pending write on its card (no "Always"): host, project, MR, SHA and the exact request are in `detail`.
    func raiseGitLabCard(_ pending: PendingGitLabWrite, title: String, detail: String, scope: String) async {
        if pendingGitLabWrites.count >= Self.maxPendingGitLabWrites, let oldest = pendingGitLabWrites.keys.sorted().first { pendingGitLabWrites[oldest] = nil }
        let subject = AppRequest.makeID("glw")
        pendingGitLabWrites[subject] = pending
        await core.putAppRequest(
            AppRequest(
                id: AppRequest.makeID("glw"), sessionID: pending.sessionID,
                kind: .approval(AppApproval(action: .gitlabWrite, title: title, detail: detail, scope: scope, subjectID: subject, allowsAlways: false, digest: pending.digest)),
                received: .now))
    }

    func respondGitLabWrite(_ approval: AppApproval, _ response: AppRequestResponse) async throws {
        guard let pending = pendingGitLabWrites.removeValue(forKey: approval.subjectID), pending.digest == approval.digest else {
            throw ExtrasError("This GitLab request is no longer pending (BelloCode was restarted, or it was answered). Nothing was sent; the agent can ask again.")
        }
        let text: String
        if case .approve = response {
            do {
                text = "[BelloCode GitLab] Approved by the user. " + (try await executeGitLabWrite(pending))
            } catch {
                text = "[BelloCode GitLab] Approved, but GitLab did not accept it: \(ExtrasError.message(error))"
            }
        } else {
            text = "[BelloCode GitLab] The user declined: \(pending.summary). Nothing was sent to GitLab. Do not retry the same request; say what you need instead."
        }
        try await core.postSynthetic(pending.sessionID, text: text, metadata: .object(["bellocode": .object(["wake": .string("gitlab")])]))
    }

    // MARK: Babysit

    /// An agent asks to babysit (watch) MRs: allowed at once where the person said "Always in This Project",
    /// otherwise one card per MR; nothing wakes the thread until it is approved.
    func requestBabysit(_ refs: [MergeRequestRef], _ caller: ExtrasCaller) async throws -> String {
        if babysitGrants.contains(caller.projectDirectory) {
            for ref in refs { try await mergeRequests.setWatching(ref, for: caller.sessionID, true) }
            return "Babysitting \(refs.map(\.description).joined(separator: ", ")). You will be woken once per event (pipeline result, new comments, approvals, merged/closed), within the user's wake budget. Do not poll; end your turn."
        }
        for ref in refs {
            let subject = caller.sessionID.rawValue + "|" + ref.url
            let existing = await core.appRequests().contains { request in
                if case .approval(let approval) = request.kind { approval.action == .gitlabBabysit && approval.subjectID == subject } else { false }
            }
            guard !existing else { continue }
            await core.putAppRequest(
                AppRequest(
                    id: AppRequest.makeID("gbs"), sessionID: caller.sessionID,
                    kind: .approval(
                        AppApproval(
                            action: .gitlabBabysit, title: "Babysit \(ref)",
                            detail: "The agent asks to be woken on \(ref.url): pipeline results, new comments, approvals, merge or close. \(mergeRequests.babysitPolicy.summary)",
                            scope: caller.projectDirectory, subjectID: subject, allowsAlways: true)),
                    received: .now))
        }
        return "Asked the user to allow babysitting \(refs.map(\.description).joined(separator: ", ")) (a card is shown; the MR is linked meanwhile). If allowed, you are woken once per event. End your turn."
    }

    func respondBabysit(_ approval: AppApproval, _ response: AppRequestResponse) async throws {
        let parts = approval.subjectID.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let ref = MergeRequestRef.parse(parts[1], instances: mergeRequests.instances) else {
            throw ExtrasError("The merge request of this request is no longer on a configured GitLab instance.")
        }
        let session = SessionID(parts[0])
        if case .approve(let always) = response {
            if always {
                try await store.setGrant(.gitlabBabysit, scope: approval.scope, granted: true)
                babysitGrants.insert(approval.scope)
            }
            try await mergeRequests.setWatching(ref, for: session, true)
            try? await core.postSynthetic(
                session, text: "\(MergeRequestWakeText.prefix) The user allowed babysitting \(ref). You will be woken once per event.", metadata: nil, resume: false)
        } else {
            try? await core.postSynthetic(
                session, text: "\(MergeRequestWakeText.prefix) The user did not allow babysitting \(ref). It stays linked; do not poll it.", metadata: nil, resume: false)
        }
    }
}
