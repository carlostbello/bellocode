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

    public var id: String { baseURL }
    public var host: String { URL(string: baseURL)?.host() ?? baseURL }
    /// The path prefix ("gitlab" for `https://h/gitlab`), empty at the root.
    public var pathPrefix: String { URL(string: baseURL)?.path().split(separator: "/").joined(separator: "/") ?? "" }
    public var apiBase: String { baseURL + "/api/v4" }
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

    /// `git@host:group/proj.git`, `ssh://git@host:2222/group/proj.git`, `https://host/prefix/group/proj(.git)`.
    /// The host must be a configured instance; an HTTP(S) remote must also carry the instance's path prefix (SSH
    /// remotes never do).
    public static func resolve(remote raw: String, instances: [GitLabInstance]) -> ForgeProject? {
        let remote = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var host: String
        var path: String
        var isHTTP = false
        if let url = URL(string: remote), let scheme = url.scheme?.lowercased(), let urlHost = url.host() {
            host = urlHost.lowercased()
            path = url.path()
            isHTTP = scheme == "https" || scheme == "http"
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
        let candidates = instances.filter { $0.host == host }.sorted { $0.pathPrefix.count > $1.pathPrefix.count }
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

    public init(id: Int, name: String, stage: String = "", status: String, webURL: String? = nil) {
        self.id = id
        self.name = name
        self.stage = stage
        self.status = status
        self.webURL = webURL
    }

    public var isFailure: Bool { status == "failed" }
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

    public init(id: Int, status: String, webURL: String? = nil, jobs: [PipelineJob] = []) {
        self.id = id
        self.status = status
        self.webURL = webURL
        self.jobs = jobs
    }

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

    public init(
        ref: MergeRequestRef, title: String, state: MergeRequestState, draft: Bool = false, sourceBranch: String = "",
        targetBranch: String = "", author: String = "", sha: String = "", webURL: String? = nil, pipeline: Pipeline? = nil,
        approvals: MergeRequestApprovals = MergeRequestApprovals(), userNotes: Int = 0, unresolvedDiscussions: Int = 0, fetched: Date
    ) {
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
    /// "Open", "Draft", "Merged", "Closed".
    public var stateLabel: String { state == .opened && draft ? "Draft" : state.label }
}

/// Why a watched MR wakes its thread. Each fires once per occurrence (the baseline records what was reported).
public enum MergeRequestWakeEvent: Hashable, Sendable {
    case pipelineFinished(id: Int, summary: PipelineSummary, failedJobs: [String])
    case approved(by: [String])
    case approvalRevoked(by: [String])
    case newNotes(Int)
    case closed(MergeRequestState)

    public var text: String {
        switch self {
        case .pipelineFinished(let id, let summary, let failed):
            let jobs = failed.isEmpty ? "" : " Failed jobs: \(failed.prefix(8).joined(separator: ", "))."
            return "Pipeline #\(id) finished: \(summary.text).\(jobs)"
        case .approved(let by): return "Approved by \(by.joined(separator: ", "))."
        case .approvalRevoked(let by): return "Approval revoked by \(by.joined(separator: ", "))."
        case .newNotes(let count): return count == 1 ? "1 new comment." : "\(count) new comments."
        case .closed(let state): return state == .merged ? "The merge request was merged." : "The merge request was closed without merging."
        }
    }
}

/// What a watch already reported, persisted (`app_mr_watch`) so a relaunch never repeats a wake.
public struct MergeRequestWakeBaseline: Hashable, Sendable, Codable {
    /// The pipeline whose finish was reported (or was already finished when the watch began).
    public var pipelineReported: Int?
    public var approvedBy: [String]
    public var userNotes: Int
    public var terminalReported: MergeRequestState?

    public init(pipelineReported: Int? = nil, approvedBy: [String] = [], userNotes: Int = 0, terminalReported: MergeRequestState? = nil) {
        self.pipelineReported = pipelineReported
        self.approvedBy = approvedBy
        self.userNotes = userNotes
        self.terminalReported = terminalReported
    }

    /// What is already true when watching starts does not wake.
    public static func initial(_ snapshot: MergeRequestSnapshot) -> MergeRequestWakeBaseline {
        MergeRequestWakeBaseline(
            pipelineReported: snapshot.pipeline.flatMap { $0.isFinished ? $0.id : nil }, approvedBy: snapshot.approvals.approvedBy.sorted(),
            userNotes: snapshot.userNotes, terminalReported: snapshot.state.isTerminal ? snapshot.state : nil)
    }

    public func diff(_ snapshot: MergeRequestSnapshot) -> (events: [MergeRequestWakeEvent], next: MergeRequestWakeBaseline) {
        var next = self
        var events: [MergeRequestWakeEvent] = []
        if let pipeline = snapshot.pipeline, pipeline.isFinished, pipelineReported != pipeline.id {
            events.append(.pipelineFinished(id: pipeline.id, summary: snapshot.pipelineSummary, failedJobs: pipeline.jobs.filter(\.isFailure).map(\.name)))
            next.pipelineReported = pipeline.id
        }
        let before = Set(approvedBy)
        let now = Set(snapshot.approvals.approvedBy)
        let added = snapshot.approvals.approvedBy.filter { !before.contains($0) }
        let removed = approvedBy.filter { !now.contains($0) }
        if !added.isEmpty { events.append(.approved(by: added)) }
        if !removed.isEmpty { events.append(.approvalRevoked(by: removed)) }
        next.approvedBy = now.sorted()
        if snapshot.userNotes > userNotes { events.append(.newNotes(snapshot.userNotes - userNotes)) }
        next.userNotes = snapshot.userNotes
        if snapshot.state.isTerminal, terminalReported != snapshot.state {
            events.append(.closed(snapshot.state))
            next.terminalReported = snapshot.state
        }
        return (events, next)
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

    public init(sessionID: SessionID, url: String) {
        self.sessionID = sessionID
        self.url = url
        wakes = 0
        consecutiveFailures = 0
    }
}

/// The wake posted to the thread (opencode `synthetic`). Its first line is the transcript's note, so it says why.
public enum MergeRequestWakeText {
    public static let prefix = "[BelloCode MR watch]"

    public static func message(_ snapshot: MergeRequestSnapshot, events: [MergeRequestWakeEvent]) -> String {
        var lines = ["\(prefix) \(snapshot.ref): " + events.map(\.text).joined(separator: " ")]
        lines.append(
            "Merge request: “\(snapshot.title)” (\(snapshot.stateLabel), \(snapshot.approvals.label), \(snapshot.pipelineSummary.text), \(snapshot.unresolvedDiscussions) unresolved discussions).")
        lines.append("MR: \(snapshot.webURL). Act on this if it needs you (fix failures, answer reviewers); otherwise reply briefly.")
        if events.contains(where: { if case .closed = $0 { true } else { false } }) { lines.append("Watching has stopped.") }
        return lines.joined(separator: "\n")
    }
}
