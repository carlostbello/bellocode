import BelloCore
import Foundation

/// Deterministic sample messages for the demo harness, snapshots and tests (every row kind).
public enum TranscriptSamples {
    public static let session = SessionID("ses_sample")

    /// A builder that numbers IDs and advances time.
    public struct Builder {
        public private(set) var messages: [Message] = []
        private var counter = 0
        private var time: Double

        public init(start: Double = 1_763_300_000_000) { time = start }

        mutating func nextID(_ prefix: String) -> String {
            counter += 1
            return String(format: "%@_%05d", prefix, counter)
        }

        mutating func tick(_ seconds: Double) -> Timestamp {
            time += seconds * 1000
            return Timestamp(milliseconds: time)
        }

        @discardableResult
        public mutating func user(_ text: String, files: [FileReference] = [], sending: Bool = false) -> MessageID {
            let id = MessageID(nextID("msg"))
            let parts = files.enumerated().map { index, file in
                Part(id: Part.makeID(message: id, .file(index: index)), index: index, content: .file(file))
            }
            messages.append(
                Message(
                    id: id, sessionID: session, kind: .user(UserContent(text: text)), created: tick(40), parts: parts,
                    delivery: sending ? .sending : nil))
            return id
        }

        public enum Content {
            case text(String, streaming: Bool = false)
            case reasoning(String, streaming: Bool = false)
            case tool(name: String, input: String, output: String, status: ToolStatus, seconds: Double = 0.4, error: String? = nil, metadata: String? = nil)
            case subagent(description: String, agent: String, status: ToolStatus, child: String?)
            case file(name: String, mime: String, uri: String)
            case unknown(String)
        }

        @discardableResult
        public mutating func assistant(_ contents: [Content], error: ErrorInfo? = nil, open: Bool = false) -> MessageID {
            let id = MessageID(nextID("msg"))
            let created = tick(2)
            var parts: [Part] = []
            var text = 0
            var reasoning = 0
            for (index, content) in contents.enumerated() {
                switch content {
                case .text(let value, let streaming):
                    parts.append(Part(id: Part.makeID(message: id, .text(ordinal: text)), index: index, content: .text(value), isStreaming: streaming))
                    text += 1
                case .reasoning(let value, let streaming):
                    parts.append(
                        Part(id: Part.makeID(message: id, .reasoning(ordinal: reasoning)), index: index, content: .reasoning(value), isStreaming: streaming))
                    reasoning += 1
                case .tool(let name, let input, let output, let status, let seconds, let error, let metadata):
                    let callID = nextID("call")
                    let start = created.milliseconds + Double(index) * 100
                    let call = ToolCall(
                        callID: callID, name: name, status: status, inputText: input, input: RawJSON(input),
                        output: output.isEmpty ? [] : [.text(output)], metadata: metadata.map { RawJSON($0) },
                        error: error.map { ErrorInfo(type: "tool", message: $0) }, created: Timestamp(milliseconds: start),
                        ran: Timestamp(milliseconds: start), completed: status.isFinished ? Timestamp(milliseconds: start + seconds * 1000) : nil)
                    parts.append(Part(id: Part.makeID(message: id, .tool(callID: callID)), index: index, content: .tool(call)))
                case .subagent(let description, let agent, let status, let child):
                    let callID = nextID("call")
                    let call = ToolCall(
                        callID: callID, name: "task", status: status,
                        inputText: "{\"description\":\"\(description)\",\"agent\":\"\(agent)\"}",
                        created: created, ran: created, completed: status.isFinished ? Timestamp(milliseconds: created.milliseconds + 12_400) : nil)
                    parts.append(
                        Part(
                            id: Part.makeID(message: id, .tool(callID: callID)), index: index,
                            content: .subagent(SubagentReference(call: call, childSessionID: child.map { SessionID($0) }, agent: agent, description: description))))
                case .file(let name, let mime, let uri):
                    parts.append(Part(id: Part.makeID(message: id, .file(index: index)), index: index, content: .file(FileReference(uri: uri, mime: mime, name: name))))
                case .unknown(let type):
                    parts.append(Part(id: Part.makeID(message: id, .other(index: index)), index: index, content: .unknown(type: type, raw: RawJSON("{}"))))
                }
            }
            let finished = !open && !contents.contains { if case .text(_, true) = $0 { true } else if case .reasoning(_, true) = $0 { true } else { false } }
            messages.append(
                Message(
                    id: id, sessionID: session,
                    kind: .assistant(AssistantInfo(agent: "build", finish: finished ? "stop" : nil, error: error, isOpen: !finished)),
                    created: created, completed: finished ? tick(1) : nil, parts: parts))
            return id
        }

        public mutating func turnEnd(_ outcome: SessionOutcome, error: ErrorInfo? = nil) {
            let id = MessageID(nextID("msg"))
            messages.append(Message(id: id, sessionID: session, kind: .turnEnd(TurnEndInfo(outcome: outcome, error: error)), created: tick(0.1)))
        }

        public mutating func other(_ type: String, json: String) {
            let id = MessageID(nextID("msg"))
            messages.append(Message(id: id, sessionID: session, kind: .other(type: type, raw: RawJSON(json)), created: tick(1)))
        }
    }

    public static let markdownReply = """
        I found the problem. The parser assumed every **heading** ends a block, so streamed text jumped when a list followed it.

        ## What changed

        - `MarkdownStream` now re-parses only from the last top-level block
        - Headings are held until content follows
          - nested detail stays aligned under its bullet
        - [x] Split-point tests pass
        - [ ] Benchmarks on the release build

        | File | Change | Lines |
        | :--- | :--- | ---: |
        | `MarkdownStream.swift` | line buffer | 214 |
        | `MarkdownParser.swift` | source ranges | 38 |

        ```swift
        func update(_ source: String) -> Int {
            let display = Self.displayPrefix(source, from: stableEnd)
            return apply(display) // re-parse the tail only
        }
        ```

        > Note: reference definitions disable incremental parsing, because they can change earlier links.

        See [the CommonMark spec](https://spec.commonmark.org) for why lists close when a new block starts.
        """

    /// A mixed transcript with every row kind.
    public static func mixed() -> [Message] {
        var builder = Builder()
        builder.user("The streaming transcript jumps when a list follows a heading. Can you look at @Sources/TranscriptKit/Markdown/MarkdownStream.swift and fix it?")
        builder.assistant([
            .reasoning("The user reports layout jumps. I should read the stream code, check the line buffer, then run the tests."),
            .tool(name: "read", input: #"{"filePath":"Sources/TranscriptKit/Markdown/MarkdownStream.swift"}"#, output: "import Foundation\n\npublic struct MarkdownStream { … }", status: .completed, seconds: 0.2),
            .tool(name: "grep", input: #"{"pattern":"displayPrefix"}"#, output: "MarkdownStream.swift:42\nMarkdownTests.swift:118", status: .completed, seconds: 0.3),
            .tool(name: "read", input: #"{"filePath":"Tests/TranscriptKitTests/MarkdownTests.swift"}"#, output: "@Suite struct MarkdownStreamTests { … }", status: .completed, seconds: 0.2),
            .tool(name: "bash", input: #"{"command":"swift test --filter MarkdownStream"}"#, output: "Test run with 5 tests passed after 0.4 seconds.", status: .completed, seconds: 2.4),
        ])
        builder.assistant([
            .tool(name: "edit", input: #"{"filePath":"Sources/TranscriptKit/Markdown/MarkdownStream.swift","oldString":"let display = source","newString":"let display = Self.displayPrefix(source, from: stableEnd)"}"#, output: "Edited MarkdownStream.swift", status: .failed, seconds: 0.1, error: "File changed on disk since it was read"),
        ])
        builder.assistant([.text(markdownReply)])
        builder.turnEnd(.succeeded)
        builder.user("Great. Delegate the benchmark run and keep a to-do list.")
        builder.assistant([
            .tool(name: "todowrite", input: #"{"todos":[{"content":"Run S1–S8 in release","status":"completed"},{"content":"Compare with the spike","status":"in_progress"},{"content":"Write the feature note","status":"pending"}]}"#, output: "", status: .completed),
            .subagent(description: "Run the transcript benchmarks", agent: "explore", status: .completed, child: "ses_child_1"),
        ])
        builder.assistant([.text("The benchmark agent finished. Numbers are within a few percent of the spike.")], error: ErrorInfo(type: "provider", message: "Rate limit reached for the model. Retry in 30 seconds.", status: 429))
        builder.other("model-switched", json: #"{"model":{"id":"big-pickle","providerID":"opencode"}}"#)
        builder.turnEnd(.interrupted)
        return builder.messages
    }
}
