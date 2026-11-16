import Foundation

/// `Session.Message.Info`: a union discriminated by `type`. Kinds this package does not model in detail are kept as
/// `.other(type:raw:)`, and unknown kinds from a newer server decode the same way.
public enum SessionMessage: Decodable, Sendable, Hashable, Identifiable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case shell(ShellMessage)
    case idle(IdleMessage)
    /// `agent-switched`, `model-switched`, `location-switched`, `synthetic`, `system`, `skill`, `compaction`, or a
    /// kind added after 2.3.0.
    case other(type: String, id: String, raw: JSONValue)

    public var id: String {
        switch self {
        case .user(let message): message.id
        case .assistant(let message): message.id
        case .shell(let message): message.id
        case .idle(let message): message.id
        case .other(_, let id, _): id
        }
    }

    public var type: String {
        switch self {
        case .user: "user"
        case .assistant: "assistant"
        case .shell: "shell"
        case .idle: "idle"
        case .other(let type, _, _): type
        }
    }

    public init(from decoder: any Decoder) throws {
        let head = try MessageHead(from: decoder)
        switch head.type {
        case "user": self = .user(try UserMessage(from: decoder))
        case "assistant": self = .assistant(try AssistantMessage(from: decoder))
        case "shell": self = .shell(try ShellMessage(from: decoder))
        case "idle": self = .idle(try IdleMessage(from: decoder))
        default: self = .other(type: head.type, id: head.id, raw: try JSONValue(from: decoder))
        }
    }

    private struct MessageHead: Decodable {
        let id: String
        let type: String
    }
}

/// `Session.Message.User`.
public struct UserMessage: Codable, Sendable, Hashable {
    public struct Time: Codable, Sendable, Hashable { public var created: Double }

    public var id: String
    public var time: Time
    public var text: String
    /// `Prompt.FileAttachment` entries (base64 `data`, `mime`, `source`), kept raw.
    public var files: [JSONValue]?
    public var agents: [JSONValue]?
    public var skills: [JSONValue]?
    public var metadata: JSONValue?
}

/// `Session.Message.Assistant`.
public struct AssistantMessage: Codable, Sendable, Hashable {
    public struct Time: Codable, Sendable, Hashable {
        public var created: Double
        public var firstToken: Double?
        public var streamed: Double?
        public var completed: Double?
    }

    public struct Snapshot: Codable, Sendable, Hashable {
        public var start: String?
        public var end: String?
        public var files: [String]?
    }

    public var id: String
    public var time: Time
    public var agent: String
    public var model: ModelRef
    public var content: [AssistantContent]
    public var snapshot: Snapshot?
    public var finish: FinishReason?
    public var cost: Double?
    public var tokens: TokenUsage?
    public var error: StructuredError?
    public var metadata: JSONValue?
}

/// `Session.Message.Assistant.finish`.
public struct FinishReason: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let stop: Self = "stop"
    public static let length: Self = "length"
    public static let toolCalls: Self = "tool-calls"
    public static let contentFilter: Self = "content-filter"
    public static let error: Self = "error"
    public static let unknown: Self = "unknown"
}

/// One block of assistant content: text, reasoning, or a tool call. Position in `content` is the block's ordinal
/// within its kind as used by streaming events.
public enum AssistantContent: Codable, Sendable, Hashable {
    case text(String)
    case reasoning(String)
    case tool(ToolCall)
    case unknown(type: String, raw: JSONValue)

    public init(from decoder: any Decoder) throws {
        let raw = try JSONValue(from: decoder)
        let type = raw["type"]?.stringValue ?? ""
        switch type {
        case "text": self = .text(raw["text"]?.stringValue ?? "")
        case "reasoning": self = .reasoning(raw["text"]?.stringValue ?? "")
        case "tool": self = .tool(try ToolCall(from: decoder))
        default: self = .unknown(type: type, raw: raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(["type": "text", "text": text])
        case .reasoning(let text): try container.encode(["type": "reasoning", "text": text])
        case .tool(let call): try container.encode(call)
        case .unknown(_, let raw): try container.encode(raw)
        }
    }
}

/// `Session.Message.Assistant.Tool`.
public struct ToolCall: Codable, Sendable, Hashable {
    public struct Time: Codable, Sendable, Hashable {
        public var created: Double
        public var ran: Double?
        public var completed: Double?
    }

    /// Unique only within its assistant message.
    public var id: String
    public var name: String
    /// `true` when the provider executed the tool itself.
    public var executed: Bool?
    public var state: ToolState
    public var time: Time
}

/// The tool state machine: streaming → running → completed | error.
public enum ToolState: Codable, Sendable, Hashable {
    case streaming(input: String)
    case running(input: JSONValue, metadata: JSONValue?)
    case completed(input: JSONValue, content: [ToolContent], metadata: JSONValue?)
    case error(input: JSONValue, error: StructuredError, content: [ToolContent]?, metadata: JSONValue?)
    case unknown(status: String, raw: JSONValue)

    private enum CodingKeys: String, CodingKey { case status, input, metadata, content, error }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "streaming":
            self = .streaming(input: try container.decodeIfPresent(String.self, forKey: .input) ?? "")
        case "running":
            self = .running(
                input: try container.decodeIfPresent(JSONValue.self, forKey: .input) ?? .null,
                metadata: try container.decodeIfPresent(JSONValue.self, forKey: .metadata)
            )
        case "completed":
            self = .completed(
                input: try container.decodeIfPresent(JSONValue.self, forKey: .input) ?? .null,
                content: try container.decodeIfPresent([ToolContent].self, forKey: .content) ?? [],
                metadata: try container.decodeIfPresent(JSONValue.self, forKey: .metadata)
            )
        case "error":
            self = .error(
                input: try container.decodeIfPresent(JSONValue.self, forKey: .input) ?? .null,
                error: try container.decode(StructuredError.self, forKey: .error),
                content: try container.decodeIfPresent([ToolContent].self, forKey: .content),
                metadata: try container.decodeIfPresent(JSONValue.self, forKey: .metadata)
            )
        default:
            self = .unknown(status: status, raw: try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case .unknown(_, let raw) = self {
            try raw.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .streaming(let input):
            try container.encode("streaming", forKey: .status)
            try container.encode(input, forKey: .input)
        case .running(let input, let metadata):
            try container.encode("running", forKey: .status)
            try container.encode(input, forKey: .input)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        case .completed(let input, let content, let metadata):
            try container.encode("completed", forKey: .status)
            try container.encode(input, forKey: .input)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        case .error(let input, let error, let content, let metadata):
            try container.encode("error", forKey: .status)
            try container.encode(input, forKey: .input)
            try container.encode(error, forKey: .error)
            try container.encodeIfPresent(content, forKey: .content)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        case .unknown:
            break
        }
    }
}

/// `Tool.Content`: tool output.
public enum ToolContent: Codable, Sendable, Hashable {
    case text(String)
    case file(uri: String, mime: String, name: String?)
    case unknown(type: String, raw: JSONValue)

    public init(from decoder: any Decoder) throws {
        let raw = try JSONValue(from: decoder)
        let type = raw["type"]?.stringValue ?? ""
        switch type {
        case "text":
            self = .text(raw["text"]?.stringValue ?? "")
        case "file":
            self = .file(
                uri: raw["uri"]?.stringValue ?? "", mime: raw["mime"]?.stringValue ?? "", name: raw["name"]?.stringValue
            )
        default:
            self = .unknown(type: type, raw: raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(JSONValue.object(["type": .string("text"), "text": .string(text)]))
        case .file(let uri, let mime, let name):
            var object: [String: JSONValue] = ["type": .string("file"), "uri": .string(uri), "mime": .string(mime)]
            if let name { object["name"] = .string(name) }
            try container.encode(JSONValue.object(object))
        case .unknown(_, let raw):
            try container.encode(raw)
        }
    }
}

/// `Session.Message.Shell`: a user-run shell command.
public struct ShellMessage: Codable, Sendable, Hashable {
    public struct Time: Codable, Sendable, Hashable {
        public var created: Double
        public var completed: Double?
    }

    public struct Output: Codable, Sendable, Hashable {
        public var output: String
        public var cursor: Int
        public var size: Int
        public var truncated: Bool
    }

    public var id: String
    public var time: Time
    public var shellID: String
    public var command: String
    /// `running`, `exited`, `timeout`, `killed`.
    public var status: String
    public var exit: FlexibleNumber?
    public var output: Output?
}

/// `Session.Message.Idle`: marks the end of a turn.
public struct IdleMessage: Codable, Sendable, Hashable {
    public struct Time: Codable, Sendable, Hashable { public var created: Double }

    public var id: String
    public var time: Time
    public var outcome: SessionOutcome
    public var error: StructuredError?
}

/// Filters for `GET /api/session/{id}/message`.
public struct MessageListQuery: Sendable, Hashable {
    public var limit: Int?
    /// Order of the first page; do not combine with `cursor`.
    public var order: ListOrder?
    public var cursor: String?
    /// Only messages of this `type` (for example `"assistant"`).
    public var type: String?

    public init(limit: Int? = nil, order: ListOrder? = nil, cursor: String? = nil, type: String? = nil) {
        self.limit = limit
        self.order = order
        self.cursor = cursor
        self.type = type
    }
}
