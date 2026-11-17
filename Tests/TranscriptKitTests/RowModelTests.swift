import BelloCore
import Foundation
import Testing

@testable import TranscriptKit

@Suite struct RowModelTests {
    typealias Builder = TranscriptSamples.Builder

    func kinds(_ rows: [TranscriptRow]) -> [String] {
        rows.map { row in
            switch row.content {
            case .user: "user"
            case .markdown: "md"
            case .reasoning: "reasoning"
            case .work(let group): "work\(group.items.count)"
            case .todo: "todo"
            case .file: "file"
            case .subagent: "subagent"
            case .visual(let visual): "visual:\(visual.visualID)"
            case .error: "error"
            case .lifecycle(let event): "life:\(event.text)"
            case .working: "working"
            case .unknown(let type): "unknown:\(type)"
            }
        }
    }

    @Test func everyPartKindMapsToARow() {
        var builder = Builder()
        builder.user("Hi @README.md", files: [FileReference(uri: "file:///a.png", mime: "image/png", name: "a.png")])
        builder.assistant([
            .reasoning("thinking"),
            .text("Hello **there**"),
            .tool(name: "todowrite", input: #"{"todos":[{"content":"A","status":"completed"},{"content":"B","status":"in_progress"}]}"#, output: "", status: .completed),
            .subagent(description: "Explore", agent: "explore", status: .running, child: "ses_c"),
            .file(name: "out.txt", mime: "text/plain", uri: "file:///out.txt"),
            .unknown("patch-summary"),
            .text("   \n"),  // whitespace-only text is not a row
        ])
        builder.other("compaction", json: #"{"status":"completed"}"#)
        builder.other("model-switched", json: #"{"model":{"id":"m2","providerID":"p"}}"#)
        builder.other("agent-switched", json: #"{"agent":"plan"}"#)
        builder.other("mystery", json: "{}")
        builder.turnEnd(.interrupted)
        let rows = RowBuilder.rows(for: builder.messages, isRunning: false)
        #expect(
            kinds(rows) == [
                "user", "reasoning", "md", "todo", "subagent", "file", "unknown:patch-summary", "life:Conversation compacted",
                "life:Model changed to m2", "life:Agent changed to plan", "unknown:mystery", "life:Interrupted",
            ])
        guard case .user(let user) = rows[0].content else { Issue.record("user"); return }
        #expect(user.attachments.map(\.name) == ["a.png"])
        guard case .todo(let todo) = rows[3].content else { Issue.record("todo"); return }
        #expect(todo.items.map(\.state) == [.completed, .inProgress])
        guard case .subagent(let card) = rows[4].content else { Issue.record("subagent"); return }
        #expect(card.childSessionID == SessionID("ses_c") && card.status == .running && card.agent == "explore")
        // Identity is the server's: parts by part ID, users by message ID.
        #expect(rows[0].id.rawValue.hasPrefix("m:msg_"))
        #expect(rows[2].id.rawValue.hasPrefix("p:msg_") && rows[2].id.rawValue.contains("/text/"))
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func errorsSendingAndTurnFailures() {
        var builder = Builder()
        builder.user("go", sending: true)
        builder.assistant([.text("partial")], error: ErrorInfo(type: "provider", message: "Overloaded", status: 529))
        builder.assistant([.text("stopped")], error: ErrorInfo(type: "aborted", message: "aborted"))
        builder.turnEnd(.failed, error: ErrorInfo(type: "x", message: "Turn failed badly"))
        let rows = RowBuilder.rows(for: builder.messages, isRunning: false)
        #expect(kinds(rows) == ["user", "md", "error", "md", "error"])
        guard case .user(let user) = rows[0].content, case .error(let error) = rows[2].content else { Issue.record("kinds"); return }
        #expect(user.isSending)
        #expect(error.title == "Provider error (529)" && error.message == "Overloaded")
        #expect(rows[2].isFailure && rows[4].isFailure)
    }

    @Test func consecutiveToolsCollapseIntoAWorkGroupAcrossMessages() {
        var builder = Builder()
        builder.user("work")
        builder.assistant([
            .tool(name: "read", input: #"{"filePath":"a.swift"}"#, output: "a", status: .completed),
            .tool(name: "read", input: #"{"filePath":"b.swift"}"#, output: "b", status: .completed),
        ])
        builder.assistant([.tool(name: "bash", input: #"{"command":"swift test"}"#, output: "ok", status: .completed, seconds: 2)])
        builder.assistant([.tool(name: "edit", input: #"{"filePath":"c.swift","oldString":"x","newString":"y"}"#, output: "", status: .failed, error: "no match")])
        builder.assistant([.text("Done."), .tool(name: "grep", input: #"{"pattern":"TODO"}"#, output: "", status: .running)])
        builder.user("next")
        builder.assistant([.tool(name: "read", input: #"{"filePath":"d.swift"}"#, output: "d", status: .completed)])
        let rows = RowBuilder.rows(for: builder.messages, isRunning: true)
        #expect(kinds(rows) == ["user", "work4", "md", "work1", "user", "work1", "working"])
        guard case .work(let group) = rows[1].content else { Issue.record("group"); return }
        #expect(group.isCollapsible)
        #expect(group.summary == "Read 2 files, ran a command")
        #expect(group.items.map(\.verb) == ["Read", "Read", "Ran", "Edit"], "a failed call reads as what was attempted")
        #expect(group.items[2].input == "$ swift test")
        #expect(group.items[3].inputIsDiff && group.items[3].input.contains("- x") && group.items[3].input.contains("+ y"))
        #expect(rows[1].id == RowID.group(group.items[0].id), "a group is named after its first call")
        // The group's blocks: summary, then member lines; successes hide behind the summary, failures stay visible.
        let blocks = RenderBlocks.blocks(for: rows[1])
        let ui = RowUIState()
        let visible = blocks.filter { RenderBlocks.isVisible($0, content: rows[1].content, ui: ui) }
        #expect(visible.count == 2, "summary and the failed edit")
        if case .toolHeader(let failed) = visible[1].kind { #expect(failed.verb == "Edit") } else { Issue.record("failure hidden") }
        var expanded = ui
        expanded.overrides[.group] = true
        #expect(blocks.filter { RenderBlocks.isVisible($0, content: rows[1].content, ui: expanded) }.count == 5)
        // The running grep is live: no "working" row is needed after it… but a later turn's finished read is not live.
        #expect(rows[3].isLive)
        #expect(rows.last.map { if case .working = $0.content { true } else { false } } == true)
    }

    @Test func groupIdentityIsStableAsTheGroupGrows() {
        var builder = Builder()
        builder.user("work")
        builder.assistant([.tool(name: "read", input: #"{"filePath":"a"}"#, output: "a", status: .completed)])
        let one = RowBuilder.rows(for: builder.messages, isRunning: true)
        builder.assistant([.tool(name: "read", input: #"{"filePath":"b"}"#, output: "b", status: .running)])
        let two = RowBuilder.rows(for: builder.messages, isRunning: true)
        #expect(one[1].id == two[1].id)
        #expect(one[1].version != two[1].version)
    }

    @Test func liveToolOutputComesFromMetadataAndShowsByDefault() {
        var builder = Builder()
        builder.user("build")
        builder.assistant([.tool(name: "bash", input: #"{"command":"make"}"#, output: "", status: .running, metadata: #"{"output":"line 1\nline 2"}"#)], open: true)
        let rows = RowBuilder.rows(for: builder.messages, isRunning: true)
        guard case .work(let group) = rows[1].content, let item = group.items.first else { Issue.record("work"); return }
        #expect(item.outputIsLive && item.output == "line 1\nline 2")
        #expect(RenderBlocks.defaultExpanded(.tool(item.id), content: rows[1].content))
        #expect(RenderBlocks.headerText(item) == "Running make…")
    }

    @Test func turnsAreAssignedAndShellMessagesAreToolLines() {
        var builder = Builder()
        let first = builder.user("one")
        builder.assistant([.text("a")])
        let second = builder.user("two")
        builder.assistant([.text("b")])
        var messages = builder.messages
        messages.append(
            Message(
                id: MessageID("msg_shell"), sessionID: TranscriptSamples.session,
                kind: .shell(ShellInfo(command: "ls -la", status: "exited", exitCode: 1, output: "denied")),
                created: Timestamp(milliseconds: 2e12), completed: Timestamp(milliseconds: 2e12 + 300)))
        let rows = RowBuilder.rows(for: messages, isRunning: false)
        #expect(rows.map(\.turnID) == [first, first, second, second, second])
        guard case .work(let group) = rows[4].content else { Issue.record("shell"); return }
        #expect(group.items[0].status == .failed("Exit code 1") && group.items[0].target == "ls -la")
    }

    @Test func summariesAndDurations() {
        #expect(DurationText.format(0.42) == "0.4 s")
        #expect(DurationText.format(12.4) == "12 s")
        #expect(DurationText.format(65) == "1 m 5 s")
        let item = { (name: String) in
            ToolItem(id: PartID(name), name: name, category: name == "x" ? .other : .read, verb: "Read", target: "", status: .done)
        }
        #expect(WorkSummary.text(for: [item("a")]) == "Read a file")
        #expect(WorkSummary.text(for: [item("a"), item("b"), item("x")]) == "Read 2 files, used a tool")
    }
}
