import AppKit
import BelloCore
import Foundation
import Testing

@testable import TranscriptKit

/// Review finding M3 (docs/reviews/M2-M4-review.md): a streaming commit must not traverse, copy or re-index the
/// history. Asserted by operation counts (rows the sync scanned, compared, copied or re-indexed) and storage identity,
/// not wall-clock time, so it holds on a loaded machine.
@Suite(.serialized) @MainActor struct StreamingCostTests {
    struct Run {
        var rows: Int
        var rowWork: [Int]
        var tailOnly: [Bool]
        var rowsStorageMoved: Int
    }

    /// Opens `turns` turns, appends a prompt, then streams `updates` revisions of one reply into the tail.
    static func streamIntoHistory(turns: Int, updates: Int) async -> Run {
        let harness = ControllerTests.Harness(messages: ControllerTests.longTranscript(turns: turns))
        defer { harness.close() }
        await harness.settle()
        // Background measurement of every row would keep the transcript unsettled while streaming.
        let deadline = ContinuousClock.now + .seconds(60)
        while !harness.controller.measureAllComplete, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        let controller = harness.controller
        // Each update must be committed by its own sync before the next one. `settle()` alone can return before the
        // observation hop has scheduled that sync on a loaded machine (a full parallel test run); the next update then
        // lands in the same sync, and the first reply revision's list change (a full rebuild) is attributed to a
        // streaming revision. Row work per commit does not depend on load; this ordering did.
        func commit(_ update: () -> Void) async {
            let syncs = controller.metrics.syncs
            update()
            let deadline = ContinuousClock.now + .seconds(30)
            while controller.metrics.syncs == syncs, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            await harness.settle()
        }
        await commit {
            harness.source.update(
                Message(
                    id: MessageID("msg_user_cost"), sessionID: TranscriptSamples.session, kind: .user(UserContent(text: "Stream please")),
                    created: Timestamp(milliseconds: 1.9e12)))
        }
        let id = MessageID("msg_stream_cost")
        var text = ""
        var run = Run(rows: 0, rowWork: [], tailOnly: [], rowsStorageMoved: 0)
        for revision in 1...updates {
            text += "Word \(revision) of the streaming reply, with `code` and more words. "
            if revision % 7 == 0 { text += "\n\n" }
            let streaming = revision < updates
            let part = Part(id: Part.makeID(message: id, .text(ordinal: 0)), index: 0, content: .text(text), isStreaming: streaming)
            let message = Message(
                id: id, sessionID: TranscriptSamples.session, kind: .assistant(AssistantInfo(isOpen: streaming)),
                created: Timestamp(milliseconds: 1.9e12 + 1), parts: [part], revision: revision)
            let before = controller.rows.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
            let syncs = controller.metrics.syncs
            await commit { harness.source.update(message) }
            guard controller.metrics.syncs > syncs, let sample = controller.lastSync else { continue }
            // The first revision appends the reply's row(s); later ones change the tail in place.
            if revision > 1 {
                run.rowWork.append(sample.rowWork)
                run.tailOnly.append(sample.tailOnly)
                if controller.rows.withUnsafeBufferPointer({ UInt(bitPattern: $0.baseAddress) }) != before { run.rowsStorageMoved += 1 }
            }
        }
        run.rows = controller.rows.count
        return run
    }

    @Test func streamingCommitCostIsIndependentOfHistoryLength() async {
        let small = await Self.streamIntoHistory(turns: 20, updates: 16)
        let large = await Self.streamIntoHistory(turns: 300, updates: 16)
        #expect(large.rows > 900)
        #expect(!small.rowWork.isEmpty && !large.rowWork.isEmpty)
        #expect(large.tailOnly.allSatisfy { $0 }, "streaming commits rebuild only the last turn")
        // The last turn here has two rows (prompt, reply); the bound leaves room for its messages and the
        // comparison, never the history.
        #expect((large.rowWork.max() ?? .max) <= 16, "row work per commit: \(large.rowWork)")
        #expect(large.rowWork.max() == small.rowWork.max(), "row work at \(large.rows) rows \(large.rowWork) vs \(small.rows) rows \(small.rowWork)")
        // The row array is replaced in place: no copy of the history per commit (a shared buffer would move it).
        #expect(large.rowsStorageMoved == 0, "rows storage reallocated in \(large.rowsStorageMoved) commits")
    }

    /// The partial replacement keeps rows and the row index identical to a full rebuild through streaming, new
    /// messages inside the turn, a new turn and a prepended page.
    @Test func partialReplacementMatchesAFullRebuild() async {
        let all = ControllerTests.longTranscript(turns: 30)
        let harness = ControllerTests.Harness(messages: Array(all.suffix(60)), older: [Array(all.prefix(all.count - 60))])
        defer { harness.close() }
        await harness.settle()
        let controller = harness.controller
        let source = harness.source
        func check(_ step: String) {
            let expected = RowBuilder.rows(for: source.messages, isRunning: source.isRunning)
            #expect(controller.rows == expected, "rows after \(step)")
            var index: [RowID: Int] = [:]
            for (position, row) in controller.rows.enumerated() where index[row.id] == nil { index[row.id] = position }
            #expect(controller.rowIndex == index, "row index after \(step)")
        }
        check("open")
        source.isRunning = true
        source.update(Message(id: MessageID("msg_u1"), sessionID: TranscriptSamples.session, kind: .user(UserContent(text: "Go")), created: Timestamp(milliseconds: 1.9e12)))
        await harness.settle()
        check("prompt")
        for step in 0..<3 {
            for revision in 1...4 {
                let id = MessageID("msg_a\(step)")
                let text = String(repeating: "Step \(step) words. ", count: revision * 3)
                let part = Part(id: Part.makeID(message: id, .text(ordinal: 0)), index: 0, content: .text(text), isStreaming: revision < 4)
                source.update(Message(id: id, sessionID: TranscriptSamples.session, kind: .assistant(AssistantInfo(isOpen: revision < 4)), created: Timestamp(milliseconds: 1.9e12 + Double(step) + 1), parts: [part], revision: revision))
                await harness.settle()
                check("step \(step) revision \(revision)")
            }
            let toolMessage = MessageID("msg_t\(step)")
            let created = Timestamp(milliseconds: 1.9e12 + Double(step) + 1.5)
            let call = ToolCall(
                callID: "call_t\(step)", name: "bash", status: .completed, inputText: #"{"command":"ls"}"#, input: RawJSON(#"{"command":"ls"}"#),
                output: [.text("a\nb")], created: created, ran: created, completed: created)
            source.update(
                Message(
                    id: toolMessage, sessionID: TranscriptSamples.session, kind: .assistant(AssistantInfo(isOpen: false)), created: created,
                    parts: [Part(id: Part.makeID(message: toolMessage, .tool(callID: "call_t\(step)")), index: 0, content: .tool(call))]))
            await harness.settle()
            check("tool after step \(step)")
        }
        source.isRunning = false
        await harness.settle()
        check("finished")
        source.update(Message(id: MessageID("msg_u2"), sessionID: TranscriptSamples.session, kind: .user(UserContent(text: "Again")), created: Timestamp(milliseconds: 1.95e12)))
        await harness.settle()
        check("second prompt")
        await source.transcriptLoadOlder()
        await harness.settle()
        check("older page")
    }
}
