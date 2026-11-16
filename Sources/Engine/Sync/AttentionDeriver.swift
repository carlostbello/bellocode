import BelloCore
import Foundation

/// Derives each session's status and the global "Needs you" list. Pure; tested directly.
///
/// Per session, the most urgent of: a pending permission (awaiting approval), a pending question (awaiting answer),
/// a requested stop the server has not confirmed (stopping), a running execution (running, or unknown while offline),
/// a failed last turn not yet seen (failed), a finished turn not yet seen (finished, unread), else idle. "Seen" is the
/// later of opencode's `viewedAt` and the app's visit watermark.
///
/// Blockers in child sessions (sub-agents) bubble up: an ancestor shows the child's approval or question, with
/// `blockingChildID` pointing at it, so a blocked sub-agent is never hidden. Only top-level, unarchived sessions
/// appear in the summary; snoozed and settled threads leave it unless they are blocked.
public enum AttentionDeriver {
    public struct Input: Sendable {
        public var sessions: [SessionID: Session]
        public var pending: [PendingRequest]
        public var stopping: Set<SessionID>
        public var threadUI: [SessionID: ThreadUIState]
        public var connected: Bool
        public var now: Timestamp

        public init(
            sessions: [SessionID: Session], pending: [PendingRequest], stopping: Set<SessionID> = [],
            threadUI: [SessionID: ThreadUIState] = [:], connected: Bool = true, now: Timestamp
        ) {
            self.sessions = sessions
            self.pending = pending
            self.stopping = stopping
            self.threadUI = threadUI
            self.connected = connected
            self.now = now
        }
    }

    public static func derive(_ input: Input) -> (statuses: [SessionID: SessionAttention], summary: AttentionSummary) {
        var approvals: [SessionID: Timestamp] = [:]
        var questions: [SessionID: Timestamp] = [:]
        var pendingCounts: [SessionID: Int] = [:]
        for request in input.pending {
            pendingCounts[request.sessionID, default: 0] += 1
            switch request {
            case .permission: approvals[request.sessionID] = min(approvals[request.sessionID] ?? request.received, request.received)
            case .question: questions[request.sessionID] = min(questions[request.sessionID] ?? request.received, request.received)
            }
        }

        var statuses: [SessionID: SessionAttention] = [:]
        for session in input.sessions.values {
            statuses[session.id] = own(session, input: input, approvals: approvals, questions: questions, pending: pendingCounts)
        }

        // Bubble blockers from descendants to every ancestor.
        for session in input.sessions.values {
            guard let child = statuses[session.id] else { continue }
            let ownPending = pendingCounts[session.id] ?? 0
            var ancestorID = session.parentID
            var depth = 0
            while let id = ancestorID, var ancestor = statuses[id], depth < 32 {
                ancestor.pendingCount += ownPending
                if child.status.isBlocking, rank(child.status) < rank(ancestor.status)
                    || (child.status == ancestor.status && ancestor.blockingChildID != nil && child.since < ancestor.since)
                {
                    ancestor.status = child.status
                    ancestor.since = child.since
                    ancestor.blockingChildID = child.blockingChildID ?? session.id
                }
                statuses[id] = ancestor
                ancestorID = input.sessions[id]?.parentID
                depth += 1
            }
        }

        var counts = AttentionCounts()
        var items: [SessionAttention] = []
        for (id, status) in statuses {
            guard let session = input.sessions[id], isTopLevel(session, in: input.sessions), !session.isArchived else { continue }
            if status.status == .running || status.status == .stopping { counts.running += 1 }
            guard status.status.needsUser else { continue }
            let ui = input.threadUI[id]
            if !status.status.isBlocking {
                if ui?.settled == true { continue }
                if let until = ui?.snoozedUntil, until > input.now { continue }
            }
            items.append(status)
            switch status.status {
            case .awaitingApproval: counts.approvals += 1
            case .awaitingAnswer: counts.questions += 1
            case .failed: counts.failed += 1
            case .finishedUnread: counts.unread += 1
            default: break
            }
        }
        items.sort { lhs, rhs in
            let left = lhs.status.urgency ?? .max
            let right = rhs.status.urgency ?? .max
            if left != right { return left < right }
            if lhs.since != rhs.since { return lhs.since < rhs.since }
            return lhs.sessionID < rhs.sessionID
        }
        return (statuses, AttentionSummary(items: items, counts: counts))
    }

    private static func own(
        _ session: Session, input: Input, approvals: [SessionID: Timestamp], questions: [SessionID: Timestamp],
        pending: [SessionID: Int]
    ) -> SessionAttention {
        let seen = max(session.viewedAt ?? Timestamp(milliseconds: 0), input.threadUI[session.id]?.visitWatermark ?? Timestamp(milliseconds: 0))
        let count = pending[session.id] ?? 0
        func make(_ status: SessionStatus, _ since: Timestamp) -> SessionAttention {
            SessionAttention(sessionID: session.id, projectID: session.projectID, status: status, since: since, pendingCount: count)
        }
        if let received = approvals[session.id] { return make(.awaitingApproval, received) }
        if let received = questions[session.id] { return make(.awaitingAnswer, received) }
        if input.stopping.contains(session.id) { return make(.stopping, session.busySince ?? session.updated) }
        if session.isRunning { return make(input.connected ? .running : .unknown, session.busySince ?? session.updated) }
        if let idle = session.idleAt, idle > seen {
            if session.outcome == .failed { return make(.failed, idle) }
            return make(.finishedUnread, idle)
        }
        return make(.idle, session.idleAt ?? session.updated)
    }

    private static func rank(_ status: SessionStatus) -> Int { status.urgency ?? 10 }

    private static func isTopLevel(_ session: Session, in sessions: [SessionID: Session]) -> Bool {
        guard let parent = session.parentID else { return true }
        return sessions[parent] == nil
    }
}
