import BelloCore
import Foundation

// Merge-request linking and watching (docs/features/orchestration-extras.md). GitLab only, behind `ForgeProvider`
// (ForgeProvider.swift). Pure values and rules here; the API in GitLabProvider.swift, the poller in
// MergeRequestService.swift.

/// A forge instance BelloCode may talk to: a GitLab base URL, possibly with a path prefix
/// (`https://code.example.com/gitlab`). Not secret; the token for it lives in the Keychain.
public struct GitLabInstance: Hashable, Sendable, Codable, Identifiable {
    /// Normalised: scheme + host (+ port) + path prefix, no trailing slash.
    public var baseURL: String

    public init?(baseURL raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = url.host(), !host.isEmpty, url.query == nil, url.fragment == nil
        else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path().split(separator: "/").joined(separator: "/")
        baseURL = "\(scheme)://\(host.lowercased())\(port)" + (path.isEmpty ? "" : "/" + path)
    }

    /// The instance suggested in Settings ▸ GitLab before any is configured (the owner's, docs/PLAN.md §0).
    public static let suggestedBaseURL = "https://gitlab.novacoast.com"

    public var id: String { baseURL }
    public var host: String { URL(string: baseURL)?.host() ?? baseURL }
    /// The path prefix ("gitlab" for `https://h/gitlab`), empty at the root.
    public var pathPrefix: String { URL(string: baseURL)?.path().split(separator: "/").joined(separator: "/") ?? "" }
    public var apiBase: String { baseURL + "/api/v4" }
    public var isPlainHTTP: Bool { baseURL.hasPrefix("http://") }
    public var scheme: String { URL(string: baseURL)?.scheme ?? "https" }
    /// The port, default ones included (443 for https, 80 for http).
    public var effectivePort: Int { URL(string: baseURL)?.port ?? (scheme == "http" ? 80 : 443) }
}

/// `group/subgroup/project!iid` on one GitLab instance.
public struct MergeRequestRef: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var instance: String
    public var projectPath: String
    public var iid: Int

    public init(instance: String, projectPath: String, iid: Int) {
        self.instance = instance
        self.projectPath = projectPath
        self.iid = iid
    }

    public var url: String { "\(instance)/\(projectPath)/-/merge_requests/\(iid)" }
    public var description: String { "\(projectPath)!\(iid)" }
    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.projectPath, lhs.iid) < (rhs.projectPath, rhs.iid) }

    /// Parses an MR URL on one of `instances` (the instance with the longest matching base wins, so path prefixes work).
    public static func parse(_ text: String, instances: [GitLabInstance]) -> MergeRequestRef? {
        find(in: text, instances: instances, limit: 1).first
    }

    /// Every distinct MR URL in `text` on a known instance, in order (bounded). `/merge_requests/new` is not an MR.
    public static func find(in text: String, instances: [GitLabInstance], limit: Int = 20) -> [MergeRequestRef] {
        guard text.contains("/-/merge_requests/") else { return [] }
        let pattern = #"https?://[^\s"'<>()]+?/-/merge_requests/([0-9]{1,9})(?![0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var result: [MergeRequestRef] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let whole = ns.substring(with: match.range)
            guard let iid = Int(ns.substring(with: match.range(at: 1))), let marker = whole.range(of: "/-/merge_requests/") else { continue }
            let projectURL = String(whole[..<marker.lowerBound])
            guard let instance = instances.filter({ projectURL.lowercased().hasPrefix($0.baseURL.lowercased() + "/") })
                .max(by: { $0.baseURL.count < $1.baseURL.count })
            else { continue }
            let path = String(projectURL.dropFirst(instance.baseURL.count + 1))
            guard path.split(separator: "/").count >= 2 else { continue }
            let ref = MergeRequestRef(instance: instance.baseURL, projectPath: path, iid: iid)
            if !result.contains(ref) { result.append(ref) }
            if result.count >= limit { break }
        }
        return result
    }
}

/// A git remote resolved to a configured GitLab instance and project path.
public struct ForgeProject: Hashable, Sendable {
    public var instance: GitLabInstance
    public var projectPath: String

    public init(instance: GitLabInstance, projectPath: String) {
        self.instance = instance
        self.projectPath = projectPath
    }

    /// `git@host:group/proj.git`, `ssh://git@host:2222/group/proj.git`, `https://host/prefix/group/proj(.git)`.
    ///
    /// Matching (m1 in docs/reviews/M3-M6-review.md): an HTTP(S) remote matches an instance with the same scheme, host
    /// and effective port, and must carry the instance's path prefix. An SSH remote names no web port or prefix, so it
    /// matches only when exactly one configured instance has its host; with several (different ports or prefixes on one
    /// host) it is ambiguous and resolves to nothing (link the MR by its URL instead).
    public static func resolve(remote raw: String, instances: [GitLabInstance]) -> ForgeProject? {
        let remote = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var host: String
        var path: String
        var isHTTP = false
        var origin: (scheme: String, port: Int)?
        if let url = URL(string: remote), let scheme = url.scheme?.lowercased(), let urlHost = url.host() {
            host = urlHost.lowercased()
            path = url.path()
            isHTTP = scheme == "https" || scheme == "http"
            if isHTTP { origin = (scheme, url.port ?? (scheme == "http" ? 80 : 443)) }
        } else if let at = remote.firstIndex(of: "@"), let colon = remote[at...].firstIndex(of: ":") {
            host = remote[remote.index(after: at)..<colon].lowercased()
            path = String(remote[remote.index(after: colon)...])
        } else {
            return nil
        }
        var parts = path.split(separator: "/").map(String.init)
        if var last = parts.last, last.hasSuffix(".git") {
            last.removeLast(4)
            parts[parts.count - 1] = last
        }
        var candidates = instances.filter { $0.host == host }.sorted { $0.pathPrefix.count > $1.pathPrefix.count }
        if let origin {
            candidates = candidates.filter { $0.scheme == origin.scheme && $0.effectivePort == origin.port }
        } else if candidates.count > 1 {
            return nil
        }
        for instance in candidates {
            var remaining = parts
            let prefix = instance.pathPrefix.split(separator: "/").map(String.init)
            if isHTTP, !prefix.isEmpty {
                guard remaining.starts(with: prefix) else { continue }
                remaining.removeFirst(prefix.count)
            }
            guard remaining.count >= 2 else { continue }
            host = instance.host
            return ForgeProject(instance: instance, projectPath: remaining.joined(separator: "/"))
        }
        return nil
    }

    /// GitLab's page for creating an MR from `branch` (into `target` when known).
    public func newMergeRequestURL(branch: String, target: String?) -> URL? {
        var components = URLComponents(string: "\(instance.baseURL)/\(projectPath)/-/merge_requests/new")
        components?.queryItems = [URLQueryItem(name: "merge_request[source_branch]", value: branch)]
            + (target.map { [URLQueryItem(name: "merge_request[target_branch]", value: $0)] } ?? [])
        return components?.url
    }
}

/// How an MR came to be linked to a thread.
public enum MergeRequestLinkSource: String, Hashable, Sendable, Codable {
    /// The agent called `link_merge_requests`.
    case agent
    /// The thread's branch has this open MR.
    case branch
    /// A `git push` in the thread printed its URL.
    case output
    /// The person linked it.
    case user
}

/// An MR linked to a thread, stored in the session's metadata (`metadata.bellocode_mrs`) so links travel with it.
public struct LinkedMergeRequest: Hashable, Sendable, Codable, Identifiable {
    public var ref: MergeRequestRef
    public var source: MergeRequestLinkSource
    public var watching: Bool
    public var linked: Date

    public init(ref: MergeRequestRef, source: MergeRequestLinkSource, watching: Bool = false, linked: Date) {
        self.ref = ref
        self.source = source
        self.watching = watching
        self.linked = linked
    }

    public var id: String { ref.url }
    public static let metadataKey = "bellocode_mrs"

    public static func decode(fromMetadata raw: RawJSON?) -> [LinkedMergeRequest] {
        guard let raw, let data = raw.text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = object[metadataKey], let listData = try? JSONSerialization.data(withJSONObject: list)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode([LinkedMergeRequest].self, from: listData)) ?? []
    }

    /// The session metadata with the list replaced (other keys kept).
    public static func encode(_ links: [LinkedMergeRequest], intoMetadata raw: RawJSON?) -> [String: Any] {
        var object: [String: Any] = [:]
        if let raw, let data = raw.text.data(using: .utf8), let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if let data = try? encoder.encode(links), let list = try? JSONSerialization.jsonObject(with: data) { object[metadataKey] = list }
        return object
    }
}

public enum MergeRequestState: String, Hashable, Sendable, Codable {
    case opened, merged, closed, locked

    public var label: String {
        switch self {
        case .opened: "Open"
        case .merged: "Merged"
        case .closed: "Closed"
        case .locked: "Locked"
        }
    }

    public var symbolName: String {
        switch self {
        case .opened: "arrow.triangle.pull"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .locked: "lock"
        }
    }

    public var isTerminal: Bool { self == .merged || self == .closed }
}

/// A CI job of the MR's head pipeline.
public struct PipelineJob: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var name: String
    public var stage: String
    /// GitLab job status: created, pending, running, success, failed, canceled, skipped, manual, …
    public var status: String
    public var webURL: String?
    /// A failure that does not fail the pipeline.
    public var allowFailure: Bool?
    /// Seconds.
    public var duration: Double?
    /// GitLab's `failure_reason` ("script_failure", "runner_system_failure", …).
    public var failureReason: String?

    public init(
        id: Int, name: String, stage: String = "", status: String, webURL: String? = nil, allowFailure: Bool? = nil, duration: Double? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.stage = stage
        self.status = status
        self.webURL = webURL
        self.allowFailure = allowFailure
        self.duration = duration
        self.failureReason = failureReason
    }

    public var isFailure: Bool { status == "failed" }
    /// A manual job: playing it may deploy, so it always needs a card (agents) or a confirmation (person).
    public var isManual: Bool { status == "manual" }
    /// Finished jobs can be retried.
    public var isRetryable: Bool { ["failed", "canceled", "success"].contains(status) }
    /// A glyph that is not colour: ✓ ✕ ◌ ▶ ⊘ –.
    public var glyph: String {
        switch status {
        case "success": "✓"
        case "failed": allowFailure == true ? "!" : "✕"
        case "running": "◌"
        case "pending", "created", "waiting_for_resource", "preparing", "scheduled": "…"
        case "manual": "▶"
        case "canceled": "⊘"
        default: "–"
        }
    }
    public var label: String {
        switch status {
        case "success": "Passed"
        case "failed": "Failed"
        case "running": "Running"
        case "pending", "created", "waiting_for_resource", "preparing", "scheduled": "Pending"
        case "canceled": "Canceled"
        case "skipped": "Skipped"
        case "manual": "Manual"
        default: status.capitalized
        }
    }
}

public struct Pipeline: Hashable, Sendable, Codable {
    public var id: Int
    /// GitLab pipeline status: created, waiting_for_resource, preparing, pending, running, success, failed, canceled,
    /// skipped, manual, scheduled.
    public var status: String
    public var webURL: String?
    public var jobs: [PipelineJob]
    /// The commit the pipeline ran on (bind a status to an exact SHA).
    public var sha: String?

    public init(id: Int, status: String, webURL: String? = nil, jobs: [PipelineJob] = [], sha: String? = nil) {
        self.id = id
        self.status = status
        self.webURL = webURL
        self.jobs = jobs
        self.sha = sha
    }

    /// Jobs grouped by stage, stages in pipeline order (the order their first job was created; GitLab lists jobs
    /// newest first), jobs by name within a stage.
    public var stages: [PipelineStage] {
        var order: [String] = []
        var groups: [String: [PipelineJob]] = [:]
        for job in jobs.sorted(by: { $0.id < $1.id }) {
            let stage = job.stage.isEmpty ? "jobs" : job.stage
            if groups[stage] == nil { order.append(stage) }
            groups[stage, default: []].append(job)
        }
        return order.map { PipelineStage(name: $0, jobs: groups[$0, default: []].sorted { $0.name < $1.name }) }
    }

    public var failedJobs: [PipelineJob] { jobs.filter { $0.isFailure && $0.allowFailure != true } }

    /// Finished one way or another (a wake may report it).
    public var isFinished: Bool { ["success", "failed", "canceled", "skipped"].contains(status) }
}

/// The pipeline as one state, with a glyph and words (never colour only).
public enum PipelineSummary: Hashable, Sendable {
    case none
    case running(done: Int, total: Int)
    case passed
    case failed(jobs: Int)
    case canceled
    case manual

    public init(_ pipeline: Pipeline?) {
        guard let pipeline else {
            self = .none
            return
        }
        switch pipeline.status {
        case "success": self = .passed
        case "failed": self = .failed(jobs: max(1, pipeline.jobs.filter(\.isFailure).count))
        case "canceled", "skipped": self = .canceled
        case "manual": self = .manual
        default:
            let done = pipeline.jobs.filter { ["success", "failed", "canceled", "skipped"].contains($0.status) }.count
            self = .running(done: done, total: pipeline.jobs.count)
        }
    }

    public var text: String {
        switch self {
        case .none: "No pipeline"
        case .running(let done, let total): total > 0 ? "Pipeline running \(done)/\(total)" : "Pipeline running"
        case .passed: "Pipeline passed"
        case .failed(let jobs): jobs == 1 ? "Pipeline failed (1 job)" : "Pipeline failed (\(jobs) jobs)"
        case .canceled: "Pipeline canceled"
        case .manual: "Pipeline waiting (manual)"
        }
    }

    public var glyph: String {
        switch self {
        case .none: "–"
        case .running, .manual: "◌"
        case .passed: "✓"
        case .failed: "✕"
        case .canceled: "⊘"
        }
    }

    public var symbolName: String {
        switch self {
        case .none: "minus.circle"
        case .running, .manual: "circle.dotted"
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .canceled: "slash.circle"
        }
    }
}

public struct MergeRequestApprovals: Hashable, Sendable, Codable {
    public var approved: Bool
    public var required: Int
    public var left: Int
    public var approvedBy: [String]

    public init(approved: Bool = false, required: Int = 0, left: Int = 0, approvedBy: [String] = []) {
        self.approved = approved
        self.required = required
        self.left = left
        self.approvedBy = approvedBy
    }

    /// "Approved by mara", "1 of 2 approvals", "No approvals".
    public var label: String {
        if required > 0 { return approved ? "Approved (\(approvedBy.count) of \(required))" : "\(required - left) of \(required) approvals" }
        if !approvedBy.isEmpty { return "Approved by \(approvedBy.prefix(3).joined(separator: ", "))" }
        return "No approvals"
    }
}

/// What GitLab says about an MR at one moment.
public struct MergeRequestSnapshot: Hashable, Sendable, Codable {
    public var ref: MergeRequestRef
    public var title: String
    public var state: MergeRequestState
    public var draft: Bool
    public var sourceBranch: String
    public var targetBranch: String
    public var author: String
    public var sha: String
    public var webURL: String
    public var pipeline: Pipeline?
    public var approvals: MergeRequestApprovals
    /// Human (non-system) notes on the MR.
    public var userNotes: Int
    public var unresolvedDiscussions: Int
    public var fetched: Date
    /// Lists that hit the page cap ("pipeline jobs", "discussions"): what was read is shown as incomplete, and counts
    /// from them are lower bounds.
    public var truncated: [String]?
    public var labels: [String]?
    public var assignees: [String]?
    /// nil: the instance does not report reviewers (before 13.8).
    public var reviewers: [String]?
    public var updatedAt: Date?
    /// `detailed_merge_status` (15.6+) or the older `merge_status`.
    public var mergeStatus: String?
    /// The discussions read (bounded, most recent last; bodies cut). External text: untrusted.
    public var discussions: [DiscussionDigest]?
    /// The highest note ID seen (a babysit wakes on notes above its baseline).
    public var maxNoteID: Int?

    public init(
        ref: MergeRequestRef, title: String, state: MergeRequestState, draft: Bool = false, sourceBranch: String = "",
        targetBranch: String = "", author: String = "", sha: String = "", webURL: String? = nil, pipeline: Pipeline? = nil,
        approvals: MergeRequestApprovals = MergeRequestApprovals(), userNotes: Int = 0, unresolvedDiscussions: Int = 0, fetched: Date,
        truncated: [String]? = nil
    ) {
        self.truncated = truncated
        self.ref = ref
        self.title = title
        self.state = state
        self.draft = draft
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.author = author
        self.sha = sha
        self.webURL = webURL ?? ref.url
        self.pipeline = pipeline
        self.approvals = approvals
        self.userNotes = userNotes
        self.unresolvedDiscussions = unresolvedDiscussions
        self.fetched = fetched
    }

    public var pipelineSummary: PipelineSummary { PipelineSummary(pipeline) }
    /// "Incomplete: only the first 1000 discussions were read" (nil when complete).
    public var truncationNote: String? {
        guard let truncated, !truncated.isEmpty else { return nil }
        return "Incomplete: GitLab has more \(truncated.joined(separator: " and ")) than BelloCode reads (\(GitLabProvider.maxPages) pages); counts are at least these"
    }
    /// "3 unresolved discussions", "at least 3 …" when the discussions list was cut at the cap.
    public var unresolvedText: String {
        (truncated?.contains("discussions") == true ? "at least " : "") + "\(unresolvedDiscussions) unresolved discussions"
    }
    /// "Open", "Draft", "Merged", "Closed".
    public var stateLabel: String { state == .opened && draft ? "Draft" : state.label }
}

/// A note quoted in a wake (sanitised, bounded); external text, delimited as untrusted when sent.
public struct QuotedNote: Hashable, Sendable, Codable {
    public var id: Int
    public var author: String
    public var body: String
    public var position: String?
    public var discussionID: String

    public init(id: Int, author: String, body: String, position: String? = nil, discussionID: String) {
        self.id = id
        self.author = author
        self.body = body
        self.position = position
        self.discussionID = discussionID
    }
}

/// Why a babysat (watched) MR wakes its thread. Each fires once per observed occurrence (the baseline records what was
/// reported).
public enum MergeRequestWakeEvent: Hashable, Sendable {
    case pipelineFinished(id: Int, summary: PipelineSummary, failedJobs: [String])
    case approved(by: [String])
    case approvalRevoked(by: [String])
    /// New comments by count (instances or snapshots without note IDs).
    case newNotes(Int)
    /// New review notes with their (untrusted) text.
    case comments([QuotedNote])
    case closed(MergeRequestState)

    public var text: String {
        switch self {
        case .pipelineFinished(let id, let summary, let failed):
            let jobs = failed.isEmpty ? "" : " Failed jobs: \(failed.prefix(8).joined(separator: ", "))."
            return "Pipeline #\(id) finished: \(summary.text).\(jobs)"
        case .approved(let by): return "Approved by \(by.joined(separator: ", "))."
        case .approvalRevoked(let by): return "Approval revoked by \(by.joined(separator: ", "))."
        case .newNotes(let count): return count == 1 ? "1 new comment." : "\(count) new comments."
        case .comments(let notes):
            let authors = Array(Set(notes.map(\.author))).sorted().map { "@\($0)" }.joined(separator: ", ")
            return (notes.count == 1 ? "1 new comment" : "\(notes.count) new comments") + (authors.isEmpty ? "." : " from \(authors).")
        case .closed(let state): return state == .merged ? "The merge request was merged." : "The merge request was closed without merging."
        }
    }

    public var isTerminal: Bool { if case .closed = self { true } else { false } }
    public var isPipelineFailure: Bool { if case .pipelineFinished(_, .failed, _) = self { true } else { false } }
    public var isPipelineSuccess: Bool { if case .pipelineFinished(_, .passed, _) = self { true } else { false } }
}

/// What a watch already reported, persisted (`app_mr_watch`) so a relaunch never repeats a wake.
public struct MergeRequestWakeBaseline: Hashable, Sendable, Codable {
    /// The pipeline whose finish was reported (or was already finished when the watch began).
    public var pipelineReported: Int?
    /// "id:status" of the reported pipeline result: a retried pipeline that turns from failed to passed reports again.
    public var pipelineKey: String?
    public var approvedBy: [String]
    public var userNotes: Int
    /// The highest note ID already reported (notes above it are new); nil in baselines written before note IDs.
    public var lastNoteID: Int?
    public var terminalReported: MergeRequestState?

    public init(
        pipelineReported: Int? = nil, pipelineKey: String? = nil, approvedBy: [String] = [], userNotes: Int = 0, lastNoteID: Int? = nil,
        terminalReported: MergeRequestState? = nil
    ) {
        self.pipelineReported = pipelineReported
        self.pipelineKey = pipelineKey
        self.approvedBy = approvedBy
        self.userNotes = userNotes
        self.lastNoteID = lastNoteID
        self.terminalReported = terminalReported
    }

    /// What is already true when watching starts does not wake.
    public static func initial(_ snapshot: MergeRequestSnapshot) -> MergeRequestWakeBaseline {
        let finished = snapshot.pipeline.flatMap { $0.isFinished ? $0 : nil }
        return MergeRequestWakeBaseline(
            pipelineReported: finished?.id, pipelineKey: finished.map { "\($0.id):\($0.status)" }, approvedBy: snapshot.approvals.approvedBy.sorted(),
            userNotes: snapshot.userNotes, lastNoteID: snapshot.discussions == nil ? nil : (snapshot.maxNoteID ?? 0),
            terminalReported: snapshot.state.isTerminal ? snapshot.state : nil)
    }

    /// Events since this baseline and the baseline after reporting them. `ignoreAuthors` (the token's own user) and
    /// system notes never wake.
    public func diff(_ snapshot: MergeRequestSnapshot, ignoreAuthors: Set<String> = []) -> (events: [MergeRequestWakeEvent], next: MergeRequestWakeBaseline) {
        var next = self
        var events: [MergeRequestWakeEvent] = []
        if let pipeline = snapshot.pipeline, pipeline.isFinished {
            let key = "\(pipeline.id):\(pipeline.status)"
            let reported = pipelineKey.map { $0 == key } ?? (pipelineReported == pipeline.id)
            if !reported {
                events.append(.pipelineFinished(id: pipeline.id, summary: snapshot.pipelineSummary, failedJobs: pipeline.failedJobs.map(\.name)))
            }
            next.pipelineReported = pipeline.id
            next.pipelineKey = key
        }
        let before = Set(approvedBy)
        let now = Set(snapshot.approvals.approvedBy)
        let added = snapshot.approvals.approvedBy.filter { !before.contains($0) }
        let removed = approvedBy.filter { !now.contains($0) }
        if !added.isEmpty { events.append(.approved(by: added)) }
        if !removed.isEmpty { events.append(.approvalRevoked(by: removed)) }
        next.approvedBy = now.sorted()
        if let discussions = snapshot.discussions, let last = lastNoteID {
            var fresh: [QuotedNote] = []
            for discussion in discussions {
                for note in discussion.notes where note.id > last && !note.system && !ignoreAuthors.contains(note.author) {
                    fresh.append(QuotedNote(id: note.id, author: note.author, body: note.body, position: discussion.position, discussionID: discussion.id))
                }
            }
            if !fresh.isEmpty { events.append(.comments(fresh.sorted { $0.id < $1.id })) }
            next.lastNoteID = max(last, snapshot.maxNoteID ?? last)
        } else {
            if snapshot.userNotes > userNotes { events.append(.newNotes(snapshot.userNotes - userNotes)) }
            if snapshot.discussions != nil { next.lastNoteID = snapshot.maxNoteID ?? 0 }
        }
        next.userNotes = snapshot.userNotes
        if snapshot.state.isTerminal, terminalReported != snapshot.state {
            events.append(.closed(snapshot.state))
            next.terminalReported = snapshot.state
        }
        return (events, next)
    }
}

/// A wake recorded before it is posted (the outbox): if BelloCode stops between posting and recording, the next
/// launch looks for its ID in the thread before posting again, so an observed event wakes once.
public struct PendingWake: Hashable, Sendable, Codable {
    public var id: String
    public var text: String
    public var summary: String
    public var next: MergeRequestWakeBaseline
    public var terminal: Bool
    public var created: Date
    /// Posting attempts so far (after one, the thread is asked first whether it already arrived).
    public var attempts: Int = 0

    public init(id: String, text: String, summary: String, next: MergeRequestWakeBaseline, terminal: Bool, created: Date) {
        self.id = id
        self.text = text
        self.summary = summary
        self.next = next
        self.terminal = terminal
        self.created = created
    }
}

/// A watch's persisted state (`app_mr_watch`).
public struct MergeRequestWatchRecord: Hashable, Sendable, Codable {
    public var sessionID: SessionID
    public var url: String
    public var baseline: MergeRequestWakeBaseline?
    public var wakes: Int
    public var consecutiveFailures: Int
    public var lastWake: Date?
    public var lastWakeText: String?
    /// Why watching stopped by itself (merged, closed, unreachable, token invalid); nil while it runs.
    public var stoppedReason: String?
    /// A wake recorded but not yet confirmed posted.
    public var pending: PendingWake?
    /// When recent wakes were posted (the last hour; for the budget).
    public var recentWakes: [Date]?
    /// Events wait (the budget is spent) until this time.
    public var deferredUntil: Date?
    /// The last successful GitLab read for this watch.
    public var lastChecked: Date?

    public init(sessionID: SessionID, url: String) {
        self.sessionID = sessionID
        self.url = url
        wakes = 0
        consecutiveFailures = 0
    }
}

/// The babysit policy (Settings ▸ GitLab; shown on every babysat MR).
public struct BabysitPolicy: Hashable, Sendable, Codable {
    /// Wakes per thread and MR in any hour; further events wait and arrive together (merged/closed always arrives).
    public var wakesPerHour: Int
    /// Wake when the pipeline passes (failures always wake).
    public var wakeOnPipelineSuccess: Bool
    /// Notes by the token's own user do not wake.
    public var ignoreOwnNotes: Bool

    public init(wakesPerHour: Int = 6, wakeOnPipelineSuccess: Bool = true, ignoreOwnNotes: Bool = true) {
        self.wakesPerHour = wakesPerHour
        self.wakeOnPipelineSuccess = wakeOnPipelineSuccess
        self.ignoreOwnNotes = ignoreOwnNotes
    }

    /// "Wakes on pipeline failure or success, new comments, approvals, merge or close; at most 6 an hour; quiet while
    /// the thread is archived or settled; stops when merged or closed."
    public var summary: String {
        "Wakes on pipeline \(wakeOnPipelineSuccess ? "failure or success" : "failure"), new comments\(ignoreOwnNotes ? " (not yours)" : ""), approvals given or revoked, merge or close; at most \(wakesPerHour) an hour (later events wait and arrive together); quiet while the thread is archived or settled; stops when merged or closed."
    }
}

/// One entry of a watch's visible wake log (`app_mr_wake`).
public struct MergeRequestWakeLogEntry: Hashable, Sendable, Codable, Identifiable {
    public enum Outcome: String, Hashable, Sendable, Codable {
        /// The thread was woken.
        case delivered
        /// The thread was settled: recorded, not woken.
        case absorbed
        /// The budget was spent: waiting.
        case deferred
        /// Posting failed; it is tried again.
        case failed
        /// Babysitting started or stopped.
        case started, stopped
    }

    public var id: String
    public var sessionID: SessionID
    public var url: String
    public var at: Date
    public var outcome: Outcome
    public var summary: String

    public init(id: String, sessionID: SessionID, url: String, at: Date, outcome: Outcome, summary: String) {
        self.id = id
        self.sessionID = sessionID
        self.url = url
        self.at = at
        self.outcome = outcome
        self.summary = summary
    }
}

/// The wake posted to the thread (opencode `synthetic`). Its first line is the transcript's note, so it says why. It
/// says it was written by BelloCode, and external text (comments, the failing job's log) is delimited as untrusted.
public enum MergeRequestWakeText {
    public static let prefix = "[BelloCode MR watch]"

    public static func message(
        _ snapshot: MergeRequestSnapshot, events: [MergeRequestWakeEvent], wakeID: String? = nil, failingJob: (job: PipelineJob, excerpt: JobLogExcerpt)? = nil,
        known: [String] = []
    ) -> String {
        var lines = ["\(prefix) \(snapshot.ref): " + events.map(\.text).joined(separator: " ")]
        lines.append("(Synthetic message from BelloCode's merge-request babysitter, not from the user\(wakeID.map { "; wake \($0)" } ?? "").)")
        lines.append(
            "Merge request: “\(snapshot.title)” (\(snapshot.stateLabel), \(snapshot.approvals.label), \(snapshot.pipelineSummary.text), \(snapshot.unresolvedDiscussions) unresolved discussions)"
                + (snapshot.sourceBranch.isEmpty ? "" : ", \(snapshot.sourceBranch) → \(snapshot.targetBranch)") + (snapshot.sha.isEmpty ? "." : " at \(snapshot.sha.prefix(12))."))
        lines.append("MR: \(snapshot.webURL)")
        for event in events {
            guard case .comments(let notes) = event else { continue }
            for note in notes.prefix(5) {
                let label = "comment by @\(note.author)" + (note.position.map { " on \($0)" } ?? "") + ", note \(note.id), discussion \(note.discussionID)"
                lines.append(UntrustedText.block(label, UntrustedText.sanitise(note.body, limit: 1_500, known: known)))
            }
            if notes.count > 5 { lines.append("(\(notes.count - 5) more comments: read them with bellocode_app_gitlab_list_discussions.)") }
        }
        if let failingJob {
            let pipeline = snapshot.pipeline.map { "pipeline #\($0.id)" } ?? "pipeline"
            lines.append(
                UntrustedText.block(
                    "log excerpt of failed job \(failingJob.job.name) (#\(failingJob.job.id), stage \(failingJob.job.stage), \(pipeline))", failingJob.excerpt.text))
        }
        lines.append("Act on this if it needs you (fix failures, answer reviewers); otherwise reply briefly.")
        if events.contains(where: \.isTerminal) { lines.append("Babysitting has stopped.") }
        return lines.joined(separator: "\n")
    }
}
