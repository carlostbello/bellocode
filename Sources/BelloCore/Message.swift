import Foundation

/// One transcript entry. Assistant content is split into `parts` (text, reasoning, tool calls, …) in stream order.
///
/// `revision` increases every time anything visible in the message changes, so views can cache layout and parsed
/// Markdown by `(id, revision)`. A finished message keeps its revision.
public struct Message: Hashable, Sendable, Codable, Identifiable {
    public var id: MessageID
    public var sessionID: SessionID
    public var kind: MessageKind
    public var created: Timestamp
    public var completed: Timestamp?
    public var parts: [Part]
    public var revision: Int
    /// Delivery of a user message this app sent. `nil` for everything else.
    public var delivery: DeliveryState?

    public init(
        id: MessageID, sessionID: SessionID, kind: MessageKind, created: Timestamp, completed: Timestamp? = nil,
        parts: [Part] = [], revision: Int = 1, delivery: DeliveryState? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.created = created
        self.completed = completed
        self.parts = parts
        self.revision = revision
        self.delivery = delivery
    }

    /// Whether any part is still streaming.
    public var isStreaming: Bool {
        if case .assistant(let info) = kind, info.isOpen { return true }
        return parts.contains { $0.isStreaming }
    }

    /// Plain text for search and copy: user text plus assistant text parts. Reasoning and tool output are excluded.
    public var searchableText: String {
        var pieces: [String] = []
        if case .user(let content) = kind { pieces.append(content.text) }
        for part in parts {
            if case .text(let text) = part.content { pieces.append(text) }
        }
        return pieces.joined(separator: "\n")
    }

    /// Ordering key inside a session: creation time, then ID (opencode IDs are time-ordered).
    public var sortKey: MessageSortKey { MessageSortKey(created: created, id: id) }

    public func part(_ id: PartID) -> Part? { parts.first { $0.id == id } }
}

/// Orders messages in a session.
public struct MessageSortKey: Hashable, Comparable, Sendable, Codable {
    public var created: Timestamp
    public var id: MessageID

    public init(created: Timestamp, id: MessageID) {
        self.created = created
        self.id = id
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.created == rhs.created ? lhs.id < rhs.id : lhs.created < rhs.created
    }
}

/// Where a user message this app sent stands. The UI must not claim delivery before `.accepted`.
public enum DeliveryState: Hashable, Sendable, Codable {
    /// Shown locally; the request is in flight.
    case sending
    /// The server admitted the prompt (it answered the request or echoed it).
    case accepted
    /// The server delivered it to the agent; it is now an ordinary transcript message.
    case delivered
}

public enum MessageKind: Hashable, Sendable, Codable {
    case user(UserContent)
    case assistant(AssistantInfo)
    /// A shell command the user ran.
    case shell(ShellInfo)
    /// End-of-turn marker.
    case turnEnd(TurnEndInfo)
    /// A kind this build does not model (agent/model switches, compaction, synthetic, …), kept as raw JSON.
    case other(type: String, raw: RawJSON)

    public var typeName: String {
        switch self {
        case .user: "user"
        case .assistant: "assistant"
        case .shell: "shell"
        case .turnEnd: "idle"
        case .other(let type, _): type
        }
    }
}

public struct UserContent: Hashable, Sendable, Codable {
    public var text: String
    public var agents: [String]

    public init(text: String, agents: [String] = []) {
        self.text = text
        self.agents = agents
    }
}

public struct AssistantInfo: Hashable, Sendable, Codable {
    public var agent: String?
    public var model: ModelSelection?
    /// `stop`, `tool-calls`, `length`, `error`, … (nil while the step runs).
    public var finish: String?
    public var error: ErrorInfo?
    public var usage: Usage?
    /// The step has started and not ended or failed.
    public var isOpen: Bool

    public init(
        agent: String? = nil, model: ModelSelection? = nil, finish: String? = nil, error: ErrorInfo? = nil,
        usage: Usage? = nil, isOpen: Bool = false
    ) {
        self.agent = agent
        self.model = model
        self.finish = finish
        self.error = error
        self.usage = usage
        self.isOpen = isOpen
    }
}

public struct ShellInfo: Hashable, Sendable, Codable {
    public var command: String
    /// `running`, `exited`, `timeout`, `killed`.
    public var status: String
    public var exitCode: Double?
    public var output: String?
    public var truncated: Bool

    public init(command: String, status: String, exitCode: Double? = nil, output: String? = nil, truncated: Bool = false) {
        self.command = command
        self.status = status
        self.exitCode = exitCode
        self.output = output
        self.truncated = truncated
    }
}

public struct TurnEndInfo: Hashable, Sendable, Codable {
    public var outcome: SessionOutcome?
    public var error: ErrorInfo?

    public init(outcome: SessionOutcome?, error: ErrorInfo? = nil) {
        self.outcome = outcome
        self.error = error
    }
}

// MARK: - Parts

/// One block of a message. Its identity is stable across streaming, persistence and resync.
public struct Part: Hashable, Sendable, Codable, Identifiable {
    public var id: PartID
    /// Position in the message.
    public var index: Int
    public var content: PartContent
    /// Text or reasoning that has started and not ended.
    public var isStreaming: Bool

    public init(id: PartID, index: Int, content: PartContent, isStreaming: Bool = false) {
        self.id = id
        self.index = index
        self.content = content
        self.isStreaming = isStreaming
    }

    /// Stable part IDs: text and reasoning blocks are keyed by their ordinal among blocks of the same kind (as
    /// opencode's streaming events are), tool calls by their call ID, files by position.
    public enum Key: Hashable, Sendable {
        case text(ordinal: Int)
        case reasoning(ordinal: Int)
        case tool(callID: String)
        case file(index: Int)
        case other(index: Int)
    }

    public static func makeID(message: MessageID, _ key: Key) -> PartID {
        switch key {
        case .text(let ordinal): PartID("\(message.rawValue)/text/\(ordinal)")
        case .reasoning(let ordinal): PartID("\(message.rawValue)/reasoning/\(ordinal)")
        case .tool(let callID): PartID("\(message.rawValue)/tool/\(callID)")
        case .file(let index): PartID("\(message.rawValue)/file/\(index)")
        case .other(let index): PartID("\(message.rawValue)/other/\(index)")
        }
    }
}

public enum PartContent: Hashable, Sendable, Codable {
    case text(String)
    case reasoning(String)
    case tool(ToolCall)
    case file(FileReference)
    /// A `subagent` tool call that started (or talks to) a child session.
    case subagent(SubagentReference)
    /// A part kind this build does not model.
    case unknown(type: String, raw: RawJSON)

    /// The tool call behind `.tool` and `.subagent`.
    public var toolCall: ToolCall? {
        switch self {
        case .tool(let call): call
        case .subagent(let reference): reference.call
        default: nil
        }
    }
}

public struct FileReference: Hashable, Sendable, Codable {
    public var uri: String
    public var mime: String
    public var name: String?

    public init(uri: String, mime: String, name: String? = nil) {
        self.uri = uri
        self.mime = mime
        self.name = name
    }

    public var isImage: Bool { mime.hasPrefix("image/") }
}

/// A tool call and its state machine: `streamingInput → running → completed | failed`. Transitions only move forward
/// (`ToolStatus.rank`), so duplicated or late events never move a finished call back.
public struct ToolCall: Hashable, Sendable, Codable {
    /// Unique within its message only.
    public var callID: String
    public var name: String
    public var status: ToolStatus
    /// The raw input text as it streamed (or the serialized input once known).
    public var inputText: String
    /// The parsed input once the call started.
    public var input: RawJSON?
    public var output: [ToolOutput]
    public var metadata: RawJSON?
    public var error: ErrorInfo?
    public var created: Timestamp?
    public var ran: Timestamp?
    public var completed: Timestamp?
    /// The provider ran the tool itself.
    public var executedByProvider: Bool

    public init(
        callID: String, name: String, status: ToolStatus, inputText: String = "", input: RawJSON? = nil,
        output: [ToolOutput] = [], metadata: RawJSON? = nil, error: ErrorInfo? = nil, created: Timestamp? = nil,
        ran: Timestamp? = nil, completed: Timestamp? = nil, executedByProvider: Bool = false
    ) {
        self.callID = callID
        self.name = name
        self.status = status
        self.inputText = inputText
        self.input = input
        self.output = output
        self.metadata = metadata
        self.error = error
        self.created = created
        self.ran = ran
        self.completed = completed
        self.executedByProvider = executedByProvider
    }

    /// Text output joined, for previews.
    public var outputText: String {
        output.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }
}

public enum ToolStatus: Hashable, Sendable, Codable {
    case streamingInput
    case running
    case completed
    case failed
    case unknown(String)

    /// Progress order; a call never moves to a lower rank.
    public var rank: Int {
        switch self {
        case .streamingInput: 0
        case .unknown: 0
        case .running: 1
        case .completed, .failed: 2
        }
    }

    public var isFinished: Bool { rank == 2 }

    public func canAdvance(to next: ToolStatus) -> Bool { next.rank >= rank && !(isFinished && next != self) }
}

public enum ToolOutput: Hashable, Sendable, Codable {
    case text(String)
    case file(FileReference)
    case unknown(type: String, raw: RawJSON)
}

/// A sub-agent call: the tool call plus the child session it runs in, once known.
public struct SubagentReference: Hashable, Sendable, Codable {
    public var call: ToolCall
    public var childSessionID: SessionID?
    public var agent: String?
    public var description: String?
    /// The child thread's live state, filled in by the Engine for open threads (the call itself completes as soon as a
    /// background child starts). nil when unknown; the call status applies then.
    public var liveStatus: ChildTaskStatus?

    public init(
        call: ToolCall, childSessionID: SessionID? = nil, agent: String? = nil, description: String? = nil,
        liveStatus: ChildTaskStatus? = nil
    ) {
        self.call = call
        self.childSessionID = childSessionID
        self.agent = agent
        self.description = description
        self.liveStatus = liveStatus
    }
}

/// A child task's state as cards and the Agents panel show it (docs/features/orchestration.md). Always shown with a
/// text label, never by colour alone.
public enum ChildTaskStatus: String, Hashable, Sendable, Codable, CaseIterable {
    case running
    /// Its own run ended while its children still run.
    case waitingOnChildren
    case needsApproval
    case needsAnswer
    case failed
    case stopping
    case stopped
    case done
    case idle
    case unknown

    public var label: String {
        switch self {
        case .running: "Running"
        case .waitingOnChildren: "Waiting on children"
        case .needsApproval: "Needs approval"
        case .needsAnswer: "Needs answer"
        case .failed: "Failed"
        case .stopping: "Stopping"
        case .stopped: "Stopped"
        case .done: "Done"
        case .idle: "Idle"
        case .unknown: "Status unknown"
        }
    }

    public var symbolName: String {
        switch self {
        case .running: "circle.dotted"
        case .waitingOnChildren: "hourglass"
        case .needsApproval: "hand.raised.fill"
        case .needsAnswer: "questionmark.bubble.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stopping: "stop.circle"
        case .stopped: "stop.fill"
        case .done: "checkmark.circle"
        case .idle: "circle"
        case .unknown: "questionmark.circle"
        }
    }

    /// Needs the person (approval or answer).
    public var isBlocked: Bool { self == .needsApproval || self == .needsAnswer }
    /// Work is still going on here or below.
    public var isActive: Bool { self == .running || self == .waitingOnChildren || self == .stopping || isBlocked }
}
