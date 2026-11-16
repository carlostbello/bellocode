import Foundation
import Testing

@testable import BelloCore

@Suite("Domain model")
struct DomainTests {
    @Test func identifiersAreTypedAndCodeAsBareStrings() throws {
        let id: SessionID = "ses_123"
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == #"["ses_123"]"#)
        #expect(try JSONDecoder().decode([SessionID].self, from: data) == [id])
        #expect(MessageID("msg_a") < MessageID("msg_b"))
    }

    @Test func timestampsRoundTripExactly() throws {
        let stamp = Timestamp(milliseconds: 1_794_855_206_321)
        let back = try JSONDecoder().decode(Timestamp.self, from: try JSONEncoder().encode(stamp))
        #expect(back == stamp)
        #expect(Timestamp(stamp.date) == stamp)
    }

    @Test func toolStatusOnlyMovesForward() {
        #expect(ToolStatus.streamingInput.canAdvance(to: .running))
        #expect(ToolStatus.running.canAdvance(to: .completed))
        #expect(ToolStatus.running.canAdvance(to: .running))
        #expect(!ToolStatus.running.canAdvance(to: .streamingInput))
        #expect(!ToolStatus.completed.canAdvance(to: .running))
        #expect(!ToolStatus.completed.canAdvance(to: .failed))
        #expect(ToolStatus.failed.canAdvance(to: .failed))
    }

    @Test func partIDsAreStableAndDistinct() {
        let message: MessageID = "msg_1"
        let ids: Set<PartID> = [
            Part.makeID(message: message, .text(ordinal: 0)), Part.makeID(message: message, .reasoning(ordinal: 0)),
            Part.makeID(message: message, .tool(callID: "0")), Part.makeID(message: message, .text(ordinal: 1)),
        ]
        #expect(ids.count == 4)
        #expect(Part.makeID(message: message, .text(ordinal: 0)) == Part.makeID(message: message, .text(ordinal: 0)))
    }

    @Test func messagesSortByTimeThenID() {
        let a = MessageSortKey(created: Timestamp(milliseconds: 10), id: "msg_b")
        let b = MessageSortKey(created: Timestamp(milliseconds: 10), id: "msg_c")
        let c = MessageSortKey(created: Timestamp(milliseconds: 9), id: "msg_z")
        #expect([a, b, c].sorted() == [c, a, b])
    }

    @Test func searchableTextSkipsReasoningAndTools() {
        let id: MessageID = "msg_1"
        let message = Message(
            id: id, sessionID: "ses_1", kind: .assistant(AssistantInfo()), created: Timestamp(milliseconds: 1),
            parts: [
                Part(id: Part.makeID(message: id, .reasoning(ordinal: 0)), index: 0, content: .reasoning("thinking")),
                Part(id: Part.makeID(message: id, .text(ordinal: 0)), index: 1, content: .text("Hello")),
                Part(
                    id: Part.makeID(message: id, .tool(callID: "t")), index: 2,
                    content: .tool(ToolCall(callID: "t", name: "shell", status: .running))),
            ])
        #expect(message.searchableText == "Hello")
    }

    @Test func sessionRunningFollowsBusyAndIdle() {
        var session = Session(
            id: "ses_1", projectID: "p", directory: "/tmp", created: Timestamp(milliseconds: 1),
            updated: Timestamp(milliseconds: 1))
        #expect(!session.isRunning)
        session.busySince = Timestamp(milliseconds: 5)
        #expect(session.isRunning)
        session.idleAt = Timestamp(milliseconds: 6)
        #expect(!session.isRunning)
    }

    @Test func statusesAllHaveLabelsAndUrgencyOrder() {
        for status in SessionStatus.allCases { #expect(!status.label.isEmpty) }
        let urgent = SessionStatus.allCases.filter(\.needsUser).sorted { $0.urgency! < $1.urgency! }
        #expect(urgent == [.awaitingApproval, .awaitingAnswer, .failed, .finishedUnread])
        let counts = AttentionCounts(approvals: 1, questions: 2, failed: 1, unread: 3, running: 4)
        #expect(counts.needsYou == 7)
        #expect(counts.dockBadge == 4)
    }

    @Test func domainValuesRoundTripThroughCodable() throws {
        let id: MessageID = "msg_1"
        let message = Message(
            id: id, sessionID: "ses_1",
            kind: .assistant(AssistantInfo(agent: "build", model: ModelSelection(providerID: "p", modelID: "m"))),
            created: Timestamp(milliseconds: 1),
            parts: [
                Part(
                    id: Part.makeID(message: id, .tool(callID: "t")), index: 0,
                    content: .subagent(
                        SubagentReference(
                            call: ToolCall(callID: "t", name: "subagent", status: .failed, error: ErrorInfo(type: "x", message: "y")),
                            childSessionID: "ses_2"))),
                Part(id: "x", index: 1, content: .unknown(type: "weird", raw: RawJSON(#"{"a":1}"#))),
            ], revision: 3, delivery: .accepted)
        let back = try JSONDecoder().decode(Message.self, from: try JSONEncoder().encode(message))
        #expect(back == message)
    }
}
