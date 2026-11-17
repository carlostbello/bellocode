import BelloCore
import Foundation

// Pull-request linking and watching, GitHub only (docs/features/orchestration-extras.md). Pure values and rules here;
// fetching in GitHubSource.swift, the poller and wakes in PullRequestService.swift.

/// `owner/repo#number` on github.com.
public struct PullRequestRef: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var owner: String
    public var repo: String
    public var number: Int

    public init(owner: String, repo: String, number: Int) {
        self.owner = owner
        self.repo = repo
        self.number = number
    }

    public var url: String { "https://github.com/\(owner)/\(repo)/pull/\(number)" }
    public var slug: String { "\(owner)/\(repo)" }
    public var description: String { "\(owner)/\(repo)#\(number)" }

    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.slug, lhs.number) < (rhs.slug, rhs.number) }

    /// Parses `https://github.com/o/r/pull/12` (with or without scheme, trailing path, query or fragment).
    public static func parse(_ text: String) -> PullRequestRef? { find(in: text).first }

    /// Every distinct PR URL in `text`, in order of appearance (bounded).
    public static func find(in text: String, limit: Int = 20) -> [PullRequestRef] {
        guard text.contains("github.com") else { return [] }
        let pattern = #"(?:https?://)?(?:www\.)?github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]{1,100})/pull/([0-9]{1,9})(?![0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [PullRequestRef] = []
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let number = Int(ns.substring(with: match.range(at: 3))) else { continue }
            var repo = ns.substring(with: match.range(at: 2))
            if repo.hasSuffix(".git") { repo.removeLast(4) }
            let ref = PullRequestRef(owner: ns.substring(with: match.range(at: 1)), repo: repo, number: number)
            if !result.contains(ref) { result.append(ref) }
            if result.count >= limit { break }
        }
        return result
    }
}

/// How a PR came to be linked to a thread.
public enum PullRequestLinkSource: String, Hashable, Sendable, Codable {
    /// The agent called `link_pull_requests`.
    case agent
    /// The thread's branch has this open PR.
    case branch
    /// A command in the thread printed its URL (`gh pr create`).
    case output
    /// The person linked it.
    case user
}

/// A PR linked to a thread. Stored in the session's metadata (`metadata.bellocode_prs`), so links travel with the
/// session (other clients, a rebuilt cache).
public struct LinkedPullRequest: Hashable, Sendable, Codable, Identifiable {
    public var ref: PullRequestRef
    public var source: PullRequestLinkSource
    public var watching: Bool
    public var linked: Date

    public init(ref: PullRequestRef, source: PullRequestLinkSource, watching: Bool = false, linked: Date) {
        self.ref = ref
        self.source = source
        self.watching = watching
        self.linked = linked
    }

    public var id: String { ref.url }

    /// The metadata key holding the list.
    public static let metadataKey = "bellocode_prs"

    /// Reads the list from a session's raw metadata.
    public static func decode(fromMetadata raw: RawJSON?) -> [LinkedPullRequest] {
        guard let raw, let data = raw.text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = object[metadataKey], let listData = try? JSONSerialization.data(withJSONObject: list)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode([LinkedPullRequest].self, from: listData)) ?? []
    }

    /// The session metadata with the list replaced (other keys kept).
    public static func encode(_ links: [LinkedPullRequest], intoMetadata raw: RawJSON?) -> [String: Any] {
        var object: [String: Any] = [:]
        if let raw, let data = raw.text.data(using: .utf8), let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if let data = try? encoder.encode(links), let list = try? JSONSerialization.jsonObject(with: data) {
            object[metadataKey] = list
        }
        return object
    }
}

public enum PullRequestState: String, Hashable, Sendable, Codable {
    case open, draft, merged, closed

    public var label: String {
        switch self {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }

    public var symbolName: String {
        switch self {
        case .open: "arrow.triangle.pull"
        case .draft: "pencil.circle"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        }
    }

    public var isTerminal: Bool { self == .merged || self == .closed }
}

public enum ReviewDecision: String, Hashable, Sendable, Codable {
    case approved, changesRequested, reviewRequired, none

    public var label: String {
        switch self {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequired: "Review required"
        case .none: "No reviews"
        }
    }
}

public struct CheckRun: Hashable, Sendable, Codable, Identifiable {
    public enum Status: String, Hashable, Sendable, Codable { case queued, inProgress, completed }
    public enum Conclusion: String, Hashable, Sendable, Codable {
        case success, failure, neutral, cancelled, skipped, timedOut, actionRequired, stale, unknown

        public var isFailure: Bool { [.failure, .cancelled, .timedOut, .actionRequired].contains(self) }
    }

    public var id: Int
    public var name: String
    public var status: Status
    public var conclusion: Conclusion?
    public var url: String?

    public init(id: Int, name: String, status: Status, conclusion: Conclusion? = nil, url: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.url = url
    }

    /// "Passed", "Failed", "Running", "Queued", "Skipped".
    public var label: String {
        switch status {
        case .queued: return "Queued"
        case .inProgress: return "Running"
        case .completed:
            switch conclusion {
            case .success: return "Passed"
            case .skipped: return "Skipped"
            case .neutral: return "Neutral"
            case .cancelled: return "Cancelled"
            case .timedOut: return "Timed out"
            case .actionRequired: return "Action required"
            case .failure: return "Failed"
            case .stale, .unknown, nil: return "Done"
            }
        }
    }
}

/// The checks as one state, with a glyph and words (never colour only).
public enum ChecksSummary: Hashable, Sendable {
    case none
    case pending(done: Int, total: Int)
    case passing(Int)
    case failing(failed: Int, total: Int)

    public init(_ checks: [CheckRun]) {
        guard !checks.isEmpty else {
            self = .none
            return
        }
        let failed = checks.filter { $0.status == .completed && ($0.conclusion?.isFailure ?? false) }.count
        let done = checks.filter { $0.status == .completed }.count
        if done < checks.count { self = failed > 0 ? .failing(failed: failed, total: checks.count) : .pending(done: done, total: checks.count) }
        else if failed > 0 { self = .failing(failed: failed, total: checks.count) }
        else { self = .passing(checks.count) }
    }

    public var text: String {
        switch self {
        case .none: "No checks"
        case .pending(let done, let total): "Checks \(done)/\(total)"
        case .passing(let total): total == 1 ? "Check passed" : "\(total) checks passed"
        case .failing(let failed, _): failed == 1 ? "1 check failed" : "\(failed) checks failed"
        }
    }

    /// A glyph that reads without colour: ✓ passing, ✕ failing, ◌ pending, – none.
    public var glyph: String {
        switch self {
        case .none: "–"
        case .pending: "◌"
        case .passing: "✓"
        case .failing: "✕"
        }
    }

    public var symbolName: String {
        switch self {
        case .none: "minus.circle"
        case .pending: "circle.dotted"
        case .passing: "checkmark.circle.fill"
        case .failing: "xmark.circle.fill"
        }
    }

    public var isSettled: Bool {
        switch self {
        case .passing, .failing: true
        case .none, .pending: false
        }
    }
}

public struct PullRequestReview: Hashable, Sendable, Codable {
    public var id: Int
    public var author: String
    /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED, PENDING.
    public var state: String

    public init(id: Int, author: String, state: String) {
        self.id = id
        self.author = author
        self.state = state
    }
}

/// What GitHub says about a PR at one moment.
public struct PullRequestSnapshot: Hashable, Sendable, Codable {
    public var ref: PullRequestRef
    public var title: String
    public var state: PullRequestState
    public var headSHA: String
    public var headBranch: String
    public var baseBranch: String
    public var author: String
    public var checks: [CheckRun]
    public var reviews: [PullRequestReview]
    /// Line comments on the diff.
    public var reviewComments: Int
    /// Conversation comments.
    public var comments: Int
    public var mergeable: Bool?
    public var fetched: Date

    public init(
        ref: PullRequestRef, title: String, state: PullRequestState, headSHA: String, headBranch: String = "",
        baseBranch: String = "", author: String = "", checks: [CheckRun] = [], reviews: [PullRequestReview] = [],
        reviewComments: Int = 0, comments: Int = 0, mergeable: Bool? = nil, fetched: Date
    ) {
        self.ref = ref
        self.title = title
        self.state = state
        self.headSHA = headSHA
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.author = author
        self.checks = checks
        self.reviews = reviews
        self.reviewComments = reviewComments
        self.comments = comments
        self.mergeable = mergeable
        self.fetched = fetched
    }

    public var checksSummary: ChecksSummary { ChecksSummary(checks) }

    /// The latest decisive review per author (GitHub's own rule, approximately).
    public var reviewDecision: ReviewDecision {
        var latest: [String: String] = [:]
        for review in reviews.sorted(by: { $0.id < $1.id }) where ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains(review.state) {
            latest[review.author] = review.state
        }
        if latest.values.contains("CHANGES_REQUESTED") { return .changesRequested }
        if latest.values.contains("APPROVED") { return .approved }
        return reviews.isEmpty ? .none : .reviewRequired
    }
}

/// Why a watched PR wakes its thread. Each fires once per occurrence (the baseline records what was reported).
public enum PullRequestWakeEvent: Hashable, Sendable {
    case checksFinished(sha: String, summary: ChecksSummary, failed: [String])
    case reviewSubmitted(authors: [String], decision: ReviewDecision)
    case newComments(Int)
    case closed(PullRequestState)

    public var text: String {
        switch self {
        case .checksFinished(let sha, let summary, let failed):
            let failures = failed.isEmpty ? "" : " Failed: \(failed.prefix(8).joined(separator: ", "))."
            return "Checks finished on \(sha.prefix(7)): \(summary.text).\(failures)"
        case .reviewSubmitted(let authors, let decision):
            return "Review submitted by \(authors.joined(separator: ", ")) (now: \(decision.label))."
        case .newComments(let count):
            return count == 1 ? "1 new comment." : "\(count) new comments."
        case .closed(let state):
            return state == .merged ? "The pull request was merged." : "The pull request was closed without merging."
        }
    }
}

/// What a watch already reported, so each event wakes once. Persisted (`app_pr_watch`) so a relaunch never repeats a
/// wake.
public struct PullRequestWakeBaseline: Hashable, Sendable, Codable {
    /// The head SHA whose finished checks were reported (or were already finished when the watch began).
    public var checksReportedSHA: String?
    public var reviewIDs: [Int]
    public var commentCount: Int
    public var terminalReported: PullRequestState?

    public init(checksReportedSHA: String? = nil, reviewIDs: [Int] = [], commentCount: Int = 0, terminalReported: PullRequestState? = nil) {
        self.checksReportedSHA = checksReportedSHA
        self.reviewIDs = reviewIDs
        self.commentCount = commentCount
        self.terminalReported = terminalReported
    }

    /// The baseline a new watch starts from: what is already true does not wake.
    public static func initial(_ snapshot: PullRequestSnapshot) -> PullRequestWakeBaseline {
        PullRequestWakeBaseline(
            checksReportedSHA: snapshot.checksSummary.isSettled ? snapshot.headSHA : nil,
            reviewIDs: snapshot.reviews.map(\.id).sorted(), commentCount: snapshot.comments + snapshot.reviewComments,
            terminalReported: snapshot.state.isTerminal ? snapshot.state : nil)
    }

    /// The events `snapshot` brings over this baseline, and the baseline after reporting them.
    public func diff(_ snapshot: PullRequestSnapshot) -> (events: [PullRequestWakeEvent], next: PullRequestWakeBaseline) {
        var next = self
        var events: [PullRequestWakeEvent] = []
        let summary = snapshot.checksSummary
        if summary.isSettled, checksReportedSHA != snapshot.headSHA {
            let failed = snapshot.checks.filter { $0.status == .completed && ($0.conclusion?.isFailure ?? false) }.map(\.name)
            events.append(.checksFinished(sha: snapshot.headSHA, summary: summary, failed: failed))
            next.checksReportedSHA = snapshot.headSHA
        }
        let known = Set(reviewIDs)
        let fresh = snapshot.reviews.filter { !known.contains($0.id) && $0.state != "PENDING" }
        if !fresh.isEmpty {
            var authors: [String] = []
            for review in fresh where !authors.contains(review.author) { authors.append(review.author) }
            events.append(.reviewSubmitted(authors: authors, decision: snapshot.reviewDecision))
            next.reviewIDs = Array(Set(reviewIDs).union(fresh.map(\.id))).sorted()
        }
        let comments = snapshot.comments + snapshot.reviewComments
        if comments > commentCount {
            // Comments that came with a review are part of that review's wake.
            if fresh.isEmpty { events.append(.newComments(comments - commentCount)) }
            next.commentCount = comments
        } else if comments < commentCount {
            next.commentCount = comments  // deleted comments: follow without waking
        }
        if snapshot.state.isTerminal, terminalReported != snapshot.state {
            events.append(.closed(snapshot.state))
            next.terminalReported = snapshot.state
        }
        return (events, next)
    }
}

/// A watch's persisted state (`app_pr_watch`).
public struct PullRequestWatchRecord: Hashable, Sendable, Codable {
    public var sessionID: SessionID
    public var url: String
    public var baseline: PullRequestWakeBaseline?
    public var wakes: Int
    public var consecutiveFailures: Int
    public var lastWake: Date?
    public var lastWakeText: String?
    /// Why watching stopped by itself (merged, closed, unreachable); nil while it runs.
    public var stoppedReason: String?

    public init(sessionID: SessionID, url: String) {
        self.sessionID = sessionID
        self.url = url
        baseline = nil
        wakes = 0
        consecutiveFailures = 0
    }
}

/// The wake message posted to the thread (opencode `synthetic`, so it is not the person's message and is labelled).
public enum PullRequestWakeText {
    public static let prefix = "[BelloCode PR watch]"

    /// The first line is what the transcript shows as the wake note, so it says why: "[BelloCode PR watch] a/b#1:
    /// Checks finished on 9f2c1ab: 1 check failed."
    public static func message(_ snapshot: PullRequestSnapshot, events: [PullRequestWakeEvent]) -> String {
        var lines = ["\(prefix) \(snapshot.ref): " + events.map(\.text).joined(separator: " ")]
        lines.append("Pull request: “\(snapshot.title)” (\(snapshot.state.label), \(snapshot.reviewDecision.label), \(snapshot.checksSummary.text)).")
        lines.append("PR: \(snapshot.ref.url). Act on this if it needs you (fix failures, answer reviews); otherwise reply briefly.")
        if events.contains(where: { if case .closed = $0 { true } else { false } }) {
            lines.append("Watching has stopped.")
        }
        return lines.joined(separator: "\n")
    }
}
