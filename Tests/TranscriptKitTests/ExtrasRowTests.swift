import BelloCore
import Foundation
import Testing

@testable import TranscriptKit

/// M3-B rows (docs/features/orchestration-extras.md): HTML visual cards, wake notes, app-tool lines.
@Suite struct ExtrasRowTests {
    func call(_ name: String, input: String, output: String, status: ToolStatus = .completed) -> ToolCall {
        ToolCall(callID: "c1", name: name, status: status, inputText: input, input: RawJSON(input), output: [.text(output)])
    }

    @Test func htmlRenderBecomesAVisualCard() {
        let done = RowBuilder.visualCard(call("bellocode_app_html_render", input: #"{"title":"Bench","html":"<b>x</b>"}"#,
            output: "visualID: v_0123456789abcdef0123\nheight: 310\nnote: Network blocked until the user approves cdn.example.com\npng: /tmp/x.png"))
        #expect(done == VisualCardContent(visualID: "v_0123456789abcdef0123", title: "Bench", height: 310, status: .ready, note: "Network blocked until the user approves cdn.example.com"))
        #expect(done?.imageSource(dark: true) == "bellocode-visual://v_0123456789abcdef0123?scheme=dark")
        #expect(done?.displayHeight == 310)
        let running = RowBuilder.visualCard(call("bellocode_app_html_render", input: #"{"title":"Bench"}"#, output: "", status: .running))
        #expect(running?.status == .rendering)
        let failed = RowBuilder.visualCard(call("bellocode_app_html_render", input: "{}", output: "BelloCode cannot render visuals right now."))
        if case .failed = failed?.status {} else { Issue.record("a result without visualID is a failure row") }
        #expect(RowBuilder.visualCard(call("bash", input: "{}", output: "")) == nil)
        #expect(VisualCardContent(visualID: "v", title: "t", height: 2_000, status: .ready).displayHeight == VisualCardContent.maxHeight)
    }

    @Test func wakesAreOneLineNotesWithoutReferences() {
        #expect(RowBuilder.belloCodeWake("[BelloCode MR watch] team/app!12: Pipeline #9 finished: Pipeline failed (1 job).\nMerge request: …")
            == "↻ MR watch woke this thread: team/app!12: Pipeline #9 finished: Pipeline failed (1 job).")
        let secret = RowBuilder.belloCodeWake("[BelloCode secret] The user saved “npm token”. secretRef: bcsecret_abc (one use, …)")
        #expect(secret == "Secret request: The user saved “npm token”.")
        #expect(RowBuilder.belloCodeWake("Hello") == nil)
    }

    @Test func appToolsReadAsActions() {
        #expect(RowBuilder.describe(name: "bellocode_app_request_secret", input: ["label": "npm token"], active: false).1 == "Asked for secret")
        #expect(RowBuilder.describe(name: "bellocode_app_schedule_task", input: ["name": "Nightly"], active: false).2 == "Nightly")
        #expect(RowBuilder.describe(name: "bellocode_app_link_merge_requests", input: ["refs": ["https://gitlab.example.com/team/app/-/merge_requests/7", "!8"]], active: false).2 == "!7, !8")
        #expect(RowBuilder.describe(name: "bellocode_app_watch_merge_request", input: ["ref": "https://code.corp/gitlab/a/b/-/merge_requests/9"], active: false).2 == "!9")
    }
}
