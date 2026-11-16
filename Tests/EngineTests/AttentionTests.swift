import BelloCore
import Foundation
import Testing

@testable import Engine

@Suite("Attention")
struct AttentionTests {
    private func t(_ ms: Double) -> Timestamp { Fixtures.t(ms) }

    private func permission(_ id: String, _ session: String, at ms: Double) -> PendingRequest {
        .permission(PermissionRequest(id: PermissionRequestID(id), sessionID: SessionID(session), action: "edit", resources: [], received: t(ms)))
    }

    private func question(_ id: String, _ session: String, at ms: Double) -> PendingRequest {
        .question(QuestionRequest(id: QuestionID(id), sessionID: SessionID(session), title: "?", fields: [], received: t(ms)))
    }

    private func sessions(_ list: [Session]) -> [SessionID: Session] {
        Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    @Test func statusPrecedence() {
        var running = Fixtures.session("ses_run")
        running.busySince = t(10)
        var unread = Fixtures.session("ses_unread")
        unread.busySince = t(1)
        unread.idleAt = t(20)
        unread.outcome = .succeeded
        var seen = unread
        seen.id = "ses_seen"
        seen.viewedAt = t(20)
        var failed = unread
        failed.id = "ses_failed"
        failed.outcome = .failed
        var watermarked = unread
        watermarked.id = "ses_mark"
        let blocked = Fixtures.session("ses_blocked")
        var stopping = running
        stopping.id = "ses_stop"
        let (statuses, summary) = AttentionDeriver.derive(
            .init(
                sessions: sessions([running, unread, seen, failed, watermarked, blocked, stopping]),
                pending: [question("frm_1", "ses_blocked", at: 5), permission("per_1", "ses_blocked", at: 7)],
                stopping: ["ses_stop"], threadUI: ["ses_mark": ThreadUIState(sessionID: "ses_mark", visitWatermark: t(25))],
                now: t(100)))
        #expect(statuses["ses_run"]?.status == .running)
        #expect(statuses["ses_unread"]?.status == .finishedUnread)
        #expect(statuses["ses_seen"]?.status == .idle)
        #expect(statuses["ses_failed"]?.status == .failed)
        #expect(statuses["ses_mark"]?.status == .idle)
        #expect(statuses["ses_blocked"]?.status == .awaitingApproval)
        #expect(statuses["ses_blocked"]?.pendingCount == 2)
        #expect(statuses["ses_stop"]?.status == .stopping)
        #expect(summary.items.map(\.sessionID) == ["ses_blocked", "ses_failed", "ses_unread"])
        #expect(summary.counts == AttentionCounts(approvals: 1, questions: 0, failed: 1, unread: 1, running: 2))
    }

    @Test func childBlockersBubbleToEveryAncestor() {
        let root = Fixtures.session("ses_root")
        let child = Fixtures.session("ses_child", parent: "ses_root")
        let grandchild = Fixtures.session("ses_grand", parent: "ses_child")
        var busyRoot = root
        busyRoot.busySince = t(1)
        let (statuses, summary) = AttentionDeriver.derive(
            .init(
                sessions: sessions([busyRoot, child, grandchild]), pending: [question("frm_1", "ses_grand", at: 9)],
                now: t(10)))
        #expect(statuses["ses_grand"]?.status == .awaitingAnswer)
        #expect(statuses["ses_child"]?.status == .awaitingAnswer)
        #expect(statuses["ses_child"]?.blockingChildID == "ses_grand")
        #expect(statuses["ses_root"]?.status == .awaitingAnswer)
        #expect(statuses["ses_root"]?.blockingChildID == "ses_grand")
        #expect(statuses["ses_root"]?.pendingCount == 1)
        // Only the top-level thread is listed; the child is reachable through blockingChildID.
        #expect(summary.items.map(\.sessionID) == ["ses_root"])
        #expect(summary.counts.questions == 1)
        #expect(summary.counts.dockBadge == 1)
    }

    @Test func approvalBeatsAnswerAndOlderFirst() {
        let a = Fixtures.session("ses_a")
        let b = Fixtures.session("ses_b")
        let c = Fixtures.session("ses_c")
        let (_, summary) = AttentionDeriver.derive(
            .init(
                sessions: sessions([a, b, c]),
                pending: [question("frm_a", "ses_a", at: 1), permission("per_b", "ses_b", at: 9), permission("per_c", "ses_c", at: 3)],
                now: t(10)))
        #expect(summary.items.map(\.sessionID) == ["ses_c", "ses_b", "ses_a"])
    }

    @Test func offlineRunningIsUnknownAndSnoozeOrSettleHideOnlyNonBlockers() {
        var running = Fixtures.session("ses_run")
        running.busySince = t(1)
        var unread = Fixtures.session("ses_unread")
        unread.idleAt = t(5)
        var blocked = Fixtures.session("ses_blocked")
        blocked.idleAt = t(5)
        let ui: [SessionID: ThreadUIState] = [
            "ses_unread": ThreadUIState(sessionID: "ses_unread", snoozedUntil: t(1_000)),
            "ses_blocked": ThreadUIState(sessionID: "ses_blocked", settled: true),
        ]
        let (statuses, summary) = AttentionDeriver.derive(
            .init(
                sessions: sessions([running, unread, blocked]), pending: [permission("per_1", "ses_blocked", at: 6)],
                threadUI: ui, connected: false, now: t(10)))
        #expect(statuses["ses_run"]?.status == .unknown)
        #expect(summary.items.map(\.sessionID) == ["ses_blocked"])
    }

    @Test func runningAcrossAServerRestartIsUnknown() {
        var orphan = Fixtures.session("ses_orphan")
        orphan.busySince = t(1)
        var live = Fixtures.session("ses_live")
        live.busySince = t(1)
        let (statuses, summary) = AttentionDeriver.derive(
            .init(sessions: sessions([orphan, live]), pending: [], orphaned: ["ses_orphan"], now: t(5)))
        #expect(statuses["ses_orphan"]?.status == .unknown)
        #expect(statuses["ses_live"]?.status == .running)
        #expect(summary.counts.running == 1)
    }

    @Test func archivedSessionsAreNotListed() {
        var archived = Fixtures.session("ses_old")
        archived.archivedAt = t(1)
        archived.idleAt = t(2)
        let (_, summary) = AttentionDeriver.derive(.init(sessions: sessions([archived]), pending: [], now: t(3)))
        #expect(summary.items.isEmpty)
    }
}

@Suite("SnapshotMerge")
struct SnapshotMergeTests {
    @Test func localStreamedTextAheadOfSnapshotIsKept() {
        let id: MessageID = "msg_1"
        let partID = Part.makeID(message: id, .text(ordinal: 0))
        let local = Message(
            id: id, sessionID: "ses_1", kind: .assistant(AssistantInfo(isOpen: true)), created: Fixtures.t(1),
            parts: [Part(id: partID, index: 0, content: .text("Hello, wor"), isStreaming: true)], revision: 5)
        let server = Message(
            id: id, sessionID: "ses_1", kind: .assistant(AssistantInfo(isOpen: true)), created: Fixtures.t(1),
            parts: [Part(id: partID, index: 0, content: .text("Hello"), isStreaming: true)])
        let merged = SnapshotMerge.message(local: local, server: server)
        #expect(merged.parts.first?.content == .text("Hello, wor"))
        #expect(merged.revision == 5, "nothing changed, so the revision is kept")
    }

    @Test func afterAServerRestartTheServerCopyWins() {
        let id: MessageID = "msg_1"
        let partID = Part.makeID(message: id, .text(ordinal: 0))
        let local = Message(
            id: id, sessionID: "ses_1", kind: .assistant(AssistantInfo(isOpen: true)), created: Fixtures.t(1),
            parts: [Part(id: partID, index: 0, content: .text("streamed by the old process"), isStreaming: true)], revision: 4)
        let server = Message(
            id: id, sessionID: "ses_1", kind: .assistant(AssistantInfo(isOpen: true)), created: Fixtures.t(1),
            parts: [Part(id: partID, index: 0, content: .text(""), isStreaming: true)])
        let merged = SnapshotMerge.message(local: local, server: server, keepLocalProgress: false)
        #expect(merged.parts.first?.content == .text(""))
        #expect(merged.revision == 5)
    }

    @Test func serverEditWinsAndBumpsRevision() {
        let local = Fixtures.assistantMessage("msg_1", session: "ses_1", text: "old answer", at: 1)
        let server = Fixtures.assistantMessage("msg_1", session: "ses_1", text: "new answer", at: 1)
        let merged = SnapshotMerge.message(local: local, server: server)
        #expect(merged.parts.first?.content == .text("new answer"))
        #expect(merged.revision == local.revision + 1)
    }

    @Test func toolFurtherAlongLocallyIsKept() {
        let id: MessageID = "msg_1"
        let partID = Part.makeID(message: id, .tool(callID: "c"))
        func message(_ status: ToolStatus) -> Message {
            Message(
                id: id, sessionID: "ses_1", kind: .assistant(AssistantInfo(isOpen: true)), created: Fixtures.t(1),
                parts: [Part(id: partID, index: 0, content: .tool(ToolCall(callID: "c", name: "shell", status: status)))])
        }
        let merged = SnapshotMerge.message(local: message(.completed), server: message(.running))
        #expect(merged.parts.first?.content.toolCall?.status == .completed)
    }

    @Test func blocksStartedAfterTheSnapshotSurvive() {
        let id: MessageID = "msg_1"
        let first = Part(id: Part.makeID(message: id, .text(ordinal: 0)), index: 0, content: .text("a"))
        let second = Part(id: Part.makeID(message: id, .text(ordinal: 1)), index: 1, content: .text("b"), isStreaming: true)
        let local = Message(id: id, sessionID: "ses_1", kind: .assistant(AssistantInfo(isOpen: true)), created: Fixtures.t(1), parts: [first, second])
        let server = Message(id: id, sessionID: "ses_1", kind: .assistant(AssistantInfo(isOpen: true)), created: Fixtures.t(1), parts: [first])
        #expect(SnapshotMerge.message(local: local, server: server).parts.map(\.id) == [first.id, second.id])
    }
}
