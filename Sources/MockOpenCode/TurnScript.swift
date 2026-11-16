import Foundation

/// A scripted assistant turn: what the mock "model" does when a prompt arrives.
///
/// Steps run in order. Text, reasoning and tool steps share one assistant message until a tool finishes; the next
/// content step then opens a new step and message, as a real model loop does (`finish: "tool-calls"`, then a new
/// `session.step.started`). See docs/spikes/mock-opencode.md for the JSON form.
public struct TurnScript: Sendable, Equatable, Codable {
    public var name: String?
    /// Overrides the session's agent for this turn.
    public var agent: String?
    public var model: ModelRef?
    public var steps: [TurnStep]

    public init(name: String? = nil, agent: String? = nil, model: ModelRef? = nil, steps: [TurnStep]) {
        self.name = name
        self.agent = agent
        self.model = model
        self.steps = steps
    }

    public init(
        name: String? = nil, agent: String? = nil, model: ModelRef? = nil,
        @TurnScriptBuilder _ steps: () -> [TurnStep]
    ) {
        self.init(name: name, agent: agent, model: model, steps: steps())
    }

    /// Loads one script from a JSON file.
    public static func load(contentsOf url: URL) throws -> TurnScript {
        try JSONDecoder().decode(TurnScript.self, from: Data(contentsOf: url))
    }

    /// Loads every `*.json` in a directory, keyed by the script's `name` or else the file name.
    public static func loadLibrary(directory: URL) throws -> [String: TurnScript] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var library: [String: TurnScript] = [:]
        for file in files {
            let script = try load(contentsOf: file)
            library[script.name ?? file.deletingPathExtension().lastPathComponent] = script
        }
        return library
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Pacing for streamed text: `chunkSize` characters per delta, `rate` deltas per second.
public struct StreamPacing: Sendable, Equatable, Codable {
    public var chunkSize: Int
    public var rate: Double

    public init(chunkSize: Int = 6, rate: Double = 60) {
        self.chunkSize = max(1, chunkSize)
        self.rate = min(max(rate, 0.1), 1000)
    }

    public static let standard = StreamPacing()
    /// The fastest pace the brief asks for: 200 deltas per second.
    public static let burst = StreamPacing(chunkSize: 3, rate: 200)

    var intervalMilliseconds: Double { 1000 / rate }

    /// Splits on Character boundaries so a delta never holds half a grapheme. Fault injection splits bytes instead.
    func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var count = 0
        for character in text {
            current.append(character)
            count += 1
            if count == chunkSize {
                result.append(current)
                current = ""
                count = 0
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

public struct PermissionAsk: Sendable, Equatable, Codable {
    public var action: String
    public var resources: [String]
    public var save: [String]?
    public var message: String?

    public init(action: String, resources: [String], save: [String]? = nil, message: String? = nil) {
        self.action = action
        self.resources = resources
        self.save = save
        self.message = message
    }
}

public struct ToolStep: Sendable, Equatable, Codable {
    public var name: String
    public var input: JSONValue
    /// Text result. Ignored when `error` is set.
    public var output: String
    /// Extra result content such as images (`{"file": {"uri": …, "mime": …}}`).
    public var files: [ToolContent]?
    /// Result metadata (for example `{"exit": 0}` or a diff).
    public var metadata: JSONValue?
    /// `session.tool.progress` metadata values, spread over `duration`.
    public var progress: [JSONValue]?
    /// Milliseconds the tool "runs".
    public var duration: Int?
    /// Ask for permission before running; the turn blocks until the reply.
    public var permission: PermissionAsk?
    /// Fail the tool with this error.
    public var error: StructuredError?
    /// Pacing for the streamed tool input.
    public var pacing: StreamPacing?

    public init(
        name: String, input: JSONValue = [:], output: String = "", files: [ToolContent]? = nil,
        metadata: JSONValue? = nil, progress: [JSONValue]? = nil, duration: Int? = nil,
        permission: PermissionAsk? = nil, error: StructuredError? = nil, pacing: StreamPacing? = nil
    ) {
        self.name = name
        self.input = input
        self.output = output
        self.files = files
        self.metadata = metadata
        self.progress = progress
        self.duration = duration
        self.permission = permission
        self.error = error
        self.pacing = pacing
    }

    private enum CodingKeys: String, CodingKey {
        case name, input, output, files, metadata, progress, duration, permission, error, pacing
    }

    public init(from decoder: any Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        name = try keyed.decode(String.self, forKey: .name)
        input = try keyed.decodeIfPresent(JSONValue.self, forKey: .input) ?? [:]
        output = try keyed.decodeIfPresent(String.self, forKey: .output) ?? ""
        files = try keyed.decodeIfPresent([ToolContent].self, forKey: .files)
        metadata = try keyed.decodeIfPresent(JSONValue.self, forKey: .metadata)
        progress = try keyed.decodeIfPresent([JSONValue].self, forKey: .progress)
        duration = try keyed.decodeIfPresent(Int.self, forKey: .duration)
        permission = try keyed.decodeIfPresent(PermissionAsk.self, forKey: .permission)
        error = try keyed.decodeIfPresent(StructuredError.self, forKey: .error)
        pacing = try keyed.decodeIfPresent(StreamPacing.self, forKey: .pacing)
    }
}

public struct TextStep: Sendable, Equatable, Codable {
    public var text: String
    public var pacing: StreamPacing?
}

public struct QuestionStep: Sendable, Equatable, Codable {
    public var title: String
    /// `Form.Field` values, as JSON.
    public var fields: JSONValue
}

public struct SubagentStep: Sendable, Equatable, Codable {
    public var agent: String
    public var description: String
    public var prompt: String
    /// What the child session's turn does.
    public var script: TurnScript
    /// When true the parent's `subagent` tool completes only after the child turn ends. The real tool returns at once
    /// with `{"status": "running"}` and the child runs in the background; that is the default.
    public var wait: Bool?
}

/// One step of a ``TurnScript``.
public indirect enum TurnStep: Sendable, Equatable {
    case reasoning(TextStep)
    case text(TextStep)
    case tool(ToolStep)
    /// A `question` tool that opens a form and blocks until it is answered; the answer becomes the tool output.
    case question(QuestionStep)
    /// A `subagent` tool that creates a child session and plays a nested script in it.
    case subagent(SubagentStep)
    /// The model call fails: `session.step.failed` then `session.execution.failed`. Ends the turn.
    case fail(StructuredError)
    case delay(milliseconds: Int)
    /// Ends the turn as if the user pressed Stop (`session.execution.interrupted`, reason `user`).
    case interrupt
    /// Fault: drop every open event stream abruptly, mid-turn.
    case dropEventStreams
    /// Fault: send the next event twice (same `id`).
    case duplicateNextEvent
}

// MARK: - DSL

extension TurnStep {
    public static func text(_ text: String, chunkSize: Int = 6, rate: Double = 60) -> TurnStep {
        .text(TextStep(text: text, pacing: StreamPacing(chunkSize: chunkSize, rate: rate)))
    }

    public static func reasoning(_ text: String, chunkSize: Int = 8, rate: Double = 60) -> TurnStep {
        .reasoning(TextStep(text: text, pacing: StreamPacing(chunkSize: chunkSize, rate: rate)))
    }

    public static func tool(
        _ name: String, input: JSONValue = [:], output: String = "", metadata: JSONValue? = nil,
        progress: [JSONValue]? = nil, duration: Int = 50, permission: PermissionAsk? = nil,
        error: StructuredError? = nil, files: [ToolContent]? = nil
    ) -> TurnStep {
        .tool(
            ToolStep(
                name: name, input: input, output: output, files: files, metadata: metadata, progress: progress,
                duration: duration, permission: permission, error: error))
    }

    public static func question(_ title: String, fields: JSONValue) -> TurnStep {
        .question(QuestionStep(title: title, fields: fields))
    }

    /// A single-choice question, the common case.
    public static func question(_ title: String, key: String = "answer", options: [String]) -> TurnStep {
        .question(
            QuestionStep(
                title: title,
                fields: [
                    [
                        "key": .string(key), "title": .string(title), "type": "string",
                        "options": .array(options.map { ["value": .string($0), "label": .string($0)] }),
                    ]
                ]))
    }

    public static func subagent(
        agent: String = "general", description: String, prompt: String, wait: Bool = false,
        @TurnScriptBuilder _ steps: () -> [TurnStep]
    ) -> TurnStep {
        .subagent(
            SubagentStep(
                agent: agent, description: description, prompt: prompt, script: TurnScript(steps: steps()),
                wait: wait))
    }

    public static func fail(_ message: String, type: String = "provider", status: Int? = nil) -> TurnStep {
        .fail(StructuredError(type: type, message: message, status: status))
    }

    public static func delay(_ milliseconds: Int) -> TurnStep { .delay(milliseconds: milliseconds) }
}

@resultBuilder
public enum TurnScriptBuilder {
    public static func buildExpression(_ step: TurnStep) -> [TurnStep] { [step] }
    public static func buildExpression(_ steps: [TurnStep]) -> [TurnStep] { steps }
    public static func buildBlock(_ parts: [TurnStep]...) -> [TurnStep] { parts.flatMap(\.self) }
    public static func buildOptional(_ part: [TurnStep]?) -> [TurnStep] { part ?? [] }
    public static func buildEither(first: [TurnStep]) -> [TurnStep] { first }
    public static func buildEither(second: [TurnStep]) -> [TurnStep] { second }
    public static func buildArray(_ parts: [[TurnStep]]) -> [TurnStep] { parts.flatMap(\.self) }
}

// MARK: - JSON form

extension TurnStep: Codable {
    private enum Kind: String, Codable {
        case reasoning, text, tool, question, subagent, fail, delay, interrupt, dropEventStreams, duplicateNextEvent
    }

    private enum Keys: String, CodingKey {
        case type, milliseconds, chunkSize, rate, error
    }

    public init(from decoder: any Decoder) throws {
        let keyed = try decoder.container(keyedBy: Keys.self)
        let kind = try keyed.decode(Kind.self, forKey: .type)
        func pacing() throws -> StreamPacing? {
            let chunk = try keyed.decodeIfPresent(Int.self, forKey: .chunkSize)
            let rate = try keyed.decodeIfPresent(Double.self, forKey: .rate)
            guard chunk != nil || rate != nil else { return nil }
            return StreamPacing(chunkSize: chunk ?? StreamPacing.standard.chunkSize, rate: rate ?? StreamPacing.standard.rate)
        }
        switch kind {
        case .reasoning:
            var step = try TextStep(from: decoder)
            step.pacing = try pacing()
            self = .reasoning(step)
        case .text:
            var step = try TextStep(from: decoder)
            step.pacing = try pacing()
            self = .text(step)
        case .tool: self = .tool(try ToolStep(from: decoder))
        case .question: self = .question(try QuestionStep(from: decoder))
        case .subagent: self = .subagent(try SubagentStep(from: decoder))
        case .fail: self = .fail(try StructuredError(from: decoder))
        case .delay: self = .delay(milliseconds: try keyed.decode(Int.self, forKey: .milliseconds))
        case .interrupt: self = .interrupt
        case .dropEventStreams: self = .dropEventStreams
        case .duplicateNextEvent: self = .duplicateNextEvent
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var keyed = encoder.container(keyedBy: Keys.self)
        func encodePacing(_ pacing: StreamPacing?) throws {
            guard let pacing else { return }
            try keyed.encode(pacing.chunkSize, forKey: .chunkSize)
            try keyed.encode(pacing.rate, forKey: .rate)
        }
        switch self {
        case let .reasoning(step):
            try keyed.encode(Kind.reasoning, forKey: .type)
            try TextStep(text: step.text, pacing: nil).encode(to: encoder)
            try encodePacing(step.pacing)
        case let .text(step):
            try keyed.encode(Kind.text, forKey: .type)
            try TextStep(text: step.text, pacing: nil).encode(to: encoder)
            try encodePacing(step.pacing)
        case let .tool(step):
            try keyed.encode(Kind.tool, forKey: .type)
            try step.encode(to: encoder)
        case let .question(step):
            try keyed.encode(Kind.question, forKey: .type)
            try step.encode(to: encoder)
        case let .subagent(step):
            try keyed.encode(Kind.subagent, forKey: .type)
            try step.encode(to: encoder)
        case let .fail(error):
            try keyed.encode(Kind.fail, forKey: .type)
            try error.encode(to: encoder)
        case let .delay(milliseconds):
            try keyed.encode(Kind.delay, forKey: .type)
            try keyed.encode(milliseconds, forKey: .milliseconds)
        case .interrupt: try keyed.encode(Kind.interrupt, forKey: .type)
        case .dropEventStreams: try keyed.encode(Kind.dropEventStreams, forKey: .type)
        case .duplicateNextEvent: try keyed.encode(Kind.duplicateNextEvent, forKey: .type)
        }
    }
}

extension TextStep {
    private enum CodingKeys: String, CodingKey { case text }

    public init(from decoder: any Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        text = try keyed.decode(String.self, forKey: .text)
        pacing = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var keyed = encoder.container(keyedBy: CodingKeys.self)
        try keyed.encode(text, forKey: .text)
    }
}

// MARK: - Built-in scripts

extension TurnScript {
    /// A short reply, the default for any prompt.
    public static let greeting = TurnScript(name: "greeting") {
        TurnStep.text("Hello from **MockOpenCode**. This reply is scripted.", chunkSize: 4, rate: 120)
    }

    /// Exercises every part kind: reasoning, text, a tool with a permission, a question and a sub-agent.
    public static let fullTour = TurnScript(name: "full-tour") {
        TurnStep.reasoning("The user wants a tour. I will list files, ask before editing, then delegate a search.")
        TurnStep.text("Let me look at the project first.\n\n")
        TurnStep.tool(
            "shell", input: ["command": "ls"], output: "Package.swift\nREADME.md\nSources\nTests\n",
            metadata: ["exit": 0, "truncated": false], progress: [["shellID": "sh_mock"]], duration: 120)
        TurnStep.text("I need to edit `README.md`.")
        TurnStep.tool(
            "edit", input: ["path": "README.md", "old": "Hello", "new": "Hello, world"],
            output: "Edited README.md", metadata: ["diff": "--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-Hello\n+Hello, world\n"],
            duration: 40, permission: PermissionAsk(action: "edit", resources: ["README.md"], save: ["README.md"]))
        TurnStep.question("Which test runner should I use?", key: "runner", options: ["swift test", "make test"])
        TurnStep.subagent(agent: "explore", description: "Find TODOs", prompt: "List TODO comments") {
            TurnStep.tool("grep", input: ["pattern": "TODO"], output: "Sources/App.swift:12: // TODO: wire menu\n")
            TurnStep.text("Found one TODO in `Sources/App.swift`.")
        }
        TurnStep.text(
            "## Summary\n\n| Step | Result |\n| --- | --- |\n| List | 4 entries |\n| Edit | done |\n\nAll set.",
            chunkSize: 5, rate: 200)
    }

    public static let failure = TurnScript(name: "failure") {
        TurnStep.text("Working on it")
        TurnStep.fail("Rate limit exceeded", type: "provider", status: 429)
    }

    /// Long text at 200 deltas per second, for streaming and coalescing work.
    public static let burst = TurnScript(name: "burst") {
        TurnStep.text(
            String(repeating: "Streaming **tokens** at 200 per second with `code`, emoji 🚀 and accents é. ", count: 40),
            chunkSize: 3, rate: 200)
    }

    public static var builtIns: [String: TurnScript] {
        Dictionary(uniqueKeysWithValues: [greeting, fullTour, failure, burst].map { ($0.name!, $0) })
    }
}
