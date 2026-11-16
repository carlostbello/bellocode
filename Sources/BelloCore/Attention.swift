import Foundation

/// What a session is doing, from the user's point of view. Every case has a text label so status is never colour-only.
public enum SessionStatus: String, Hashable, Sendable, Codable, CaseIterable {
    /// Blocked on a permission request (its own or a child's).
    case awaitingApproval
    /// Blocked on a question (its own or a child's).
    case awaitingAnswer
    /// The last turn failed and the user has not looked since.
    case failed
    /// The user asked to stop; the server has not confirmed yet.
    case stopping
    case running
    /// The last turn finished after the user last looked.
    case finishedUnread
    case idle
    /// Not connected, and the cached state said it was running: the real state is unknown.
    case unknown

    /// Lower is more urgent. `nil` for statuses that do not need the user.
    public var urgency: Int? {
        switch self {
        case .awaitingApproval: 0
        case .awaitingAnswer: 1
        case .failed: 2
        case .finishedUnread: 3
        case .stopping, .running, .idle, .unknown: nil
        }
    }

    /// Belongs in the "Needs you" list.
    public var needsUser: Bool { urgency != nil }

    /// Blocks the agent until the user acts.
    public var isBlocking: Bool { self == .awaitingApproval || self == .awaitingAnswer }

    public var label: String {
        switch self {
        case .awaitingApproval: "Needs approval"
        case .awaitingAnswer: "Needs answer"
        case .failed: "Failed"
        case .stopping: "Stopping"
        case .running: "Running"
        case .finishedUnread: "Finished"
        case .idle: "Idle"
        case .unknown: "Status unknown"
        }
    }

    /// An SF Symbol name for the status glyph (shown with `label`, never instead of it).
    public var symbolName: String {
        switch self {
        case .awaitingApproval: "hand.raised.fill"
        case .awaitingAnswer: "questionmark.bubble.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stopping: "stop.circle"
        case .running: "circle.dotted"
        case .finishedUnread: "circle.fill"
        case .idle: "circle"
        case .unknown: "questionmark.circle"
        }
    }
}

/// A session's derived status and why.
public struct SessionAttention: Hashable, Sendable {
    public var sessionID: SessionID
    public var projectID: ProjectID
    public var status: SessionStatus
    /// When the session entered this status (request received, turn ended, …), for ordering by age.
    public var since: Timestamp
    /// The descendant whose request bubbled up, when the blocker is in a child session.
    public var blockingChildID: SessionID?
    /// Pending requests in this session and its descendants.
    public var pendingCount: Int

    public init(
        sessionID: SessionID, projectID: ProjectID, status: SessionStatus, since: Timestamp,
        blockingChildID: SessionID? = nil, pendingCount: Int = 0
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.status = status
        self.since = since
        self.blockingChildID = blockingChildID
        self.pendingCount = pendingCount
    }
}

/// Counts for sidebar badges and the Dock badge.
public struct AttentionCounts: Hashable, Sendable {
    public var approvals = 0
    public var questions = 0
    public var failed = 0
    public var unread = 0
    public var running = 0

    public init(approvals: Int = 0, questions: Int = 0, failed: Int = 0, unread: Int = 0, running: Int = 0) {
        self.approvals = approvals
        self.questions = questions
        self.failed = failed
        self.unread = unread
        self.running = running
    }

    /// Entries in the "Needs you" list.
    public var needsYou: Int { approvals + questions + failed + unread }
    /// The Dock badge: sessions blocked on the user or failed. Unread completions show only in the sidebar.
    public var dockBadge: Int { approvals + questions + failed }
}

/// The global "Needs you" list (top-level sessions only; child blockers bubble up), ordered by urgency then age
/// (oldest first), plus counts.
public struct AttentionSummary: Hashable, Sendable {
    public var items: [SessionAttention]
    public var counts: AttentionCounts

    public init(items: [SessionAttention] = [], counts: AttentionCounts = AttentionCounts()) {
        self.items = items
        self.counts = counts
    }

    public static let empty = AttentionSummary()
}

/// Per-thread state that only BelloCode owns. Restored on relaunch.
public struct ThreadUIState: Hashable, Sendable, Codable {
    public var sessionID: SessionID
    public var draft: String
    /// When the user last had the thread open; completions after it count as unread.
    public var visitWatermark: Timestamp?
    public var pinned: Bool
    public var snoozedUntil: Timestamp?
    public var settled: Bool
    /// The message at the top of the viewport and its offset, for scroll restoration.
    public var scrollAnchor: MessageID?
    public var scrollOffset: Double

    public init(
        sessionID: SessionID, draft: String = "", visitWatermark: Timestamp? = nil, pinned: Bool = false,
        snoozedUntil: Timestamp? = nil, settled: Bool = false, scrollAnchor: MessageID? = nil, scrollOffset: Double = 0
    ) {
        self.sessionID = sessionID
        self.draft = draft
        self.visitWatermark = visitWatermark
        self.pinned = pinned
        self.snoozedUntil = snoozedUntil
        self.settled = settled
        self.scrollAnchor = scrollAnchor
        self.scrollOffset = scrollOffset
    }
}
