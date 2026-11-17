import BelloCore
import Foundation
import Testing

@testable import TranscriptKit

@Suite("Orchestration cards")
struct OrchestrationCardTests {
    private func reference(_ status: ToolStatus, live: ChildTaskStatus?) -> SubagentReference {
        SubagentReference(
            call: ToolCall(callID: "c1", name: "delegate_task", status: status), childSessionID: SessionID("ses_child"),
            agent: "general", description: "Count files", liveStatus: live)
    }

    @Test func liveChildStateWinsOverTheFinishedCall() {
        #expect(RowBuilder.subagentCard(reference(.completed, live: nil)).status == .done)
        #expect(RowBuilder.subagentCard(reference(.completed, live: .running)).status == .running)
        #expect(RowBuilder.subagentCard(reference(.completed, live: .waitingOnChildren)).status == .waitingOnChildren)
        #expect(RowBuilder.subagentCard(reference(.completed, live: .needsApproval)).status == .needsYou)
        #expect(RowBuilder.subagentCard(reference(.completed, live: .stopped)).status == .stopped)
        #expect(RowBuilder.subagentCard(reference(.failed, live: .running)).status == .failed)
        let card = RowBuilder.subagentCard(reference(.completed, live: .needsAnswer))
        #expect(RenderBlocks.subagentText(card) == "Count files\n@general · Needs you")
        #expect(card.duration == nil)
    }

    @Test func sendToUserBecomesAQuotedCard() {
        var call = ToolCall(
            callID: "s1", name: "send_to_user", status: .completed,
            input: RawJSON(#"{"markdown":"Plan:\n\n1. Ship","title":"Decision needed"}"#))
        #expect(RowBuilder.sendToUserMarkdown(call) == "> **Decision needed**\n>\n> Plan:\n> \n> 1. Ship")
        call.input = RawJSON(#"{"markdown":"Hello"}"#)
        #expect(RowBuilder.sendToUserMarkdown(call)?.hasPrefix("> **For you**") == true)
        call.status = .failed
        #expect(RowBuilder.sendToUserMarkdown(call) == nil)
        #expect(RowBuilder.sendToUserMarkdown(ToolCall(callID: "x", name: "read", status: .completed, input: RawJSON("{}"))) == nil)
    }

    @Test func childReportsBecomeOneLine() {
        let report = "<subagent sessionID=\"ses_1\" state=\"completed\" description=\"Write CHANGELOG entry\">\nDrafted the 2.0 entry.\nMore.\n</subagent>"
        #expect(RowBuilder.subagentReport(report) == "↩ “Write CHANGELOG entry” finished: Drafted the 2.0 entry.")
        #expect(RowBuilder.subagentReport("<subagent sessionID=\"s\" state=\"error\" description=\"Bench\">\nSubagent failed\n</subagent>") == "↩ “Bench” failed: Subagent failed")
        #expect(RowBuilder.subagentReport("Hello <subagent>") == nil)
    }
}
