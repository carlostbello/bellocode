import Foundation

// Records the mock keeps, each rendered to the exact JSON shape of the pinned API (Contracts/opencode-2.3.0).
// Optional fields are omitted when absent, as the real server does.

public struct ModelRef: Sendable, Hashable, Codable {
    public var id: String
    public var providerID: String
    public var variant: String?

    public init(id: String, providerID: String, variant: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.variant = variant
    }

    public var json: JSONValue {
        .compact([("id", .string(id)), ("providerID", .string(providerID)), ("variant", variant.map(JSONValue.string))])
    }

    public static let bigPickle = ModelRef(id: "big-pickle", providerID: "opencode")
}

public struct TokenUsage: Sendable, Hashable {
    public var input: Int
    public var output: Int
    public var reasoning: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, reasoning: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public static let zero = TokenUsage()

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: a.input + b.input, output: a.output + b.output, reasoning: a.reasoning + b.reasoning,
            cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }

    public var json: JSONValue {
        [
            "input": .int(input), "output": .int(output), "reasoning": .int(reasoning),
            "cache": ["read": .int(cacheRead), "write": .int(cacheWrite)],
        ]
    }
}

/// `Session.StructuredError`.
public struct StructuredError: Sendable, Hashable, Codable {
    public var type: String
    public var message: String
    public var status: Int?

    public init(type: String, message: String, status: Int? = nil) {
        self.type = type
        self.message = message
        self.status = status
    }

    public var json: JSONValue {
        .compact([("type", .string(type)), ("message", .string(message)), ("status", status.map(JSONValue.int))])
    }
}

/// `Project`.
public struct MockProject: Sendable, Hashable {
    public var id: String
    public var directory: String
    public var vcs: String?
    public var name: String?
    public var created: Int64
    public var updated: Int64
    public var active: Int64

    public init(id: String, directory: String, vcs: String? = "git", name: String? = nil, time: Int64) {
        self.id = id
        self.directory = directory
        self.vcs = vcs
        self.name = name
        created = time
        updated = time
        active = time
    }

    public var json: JSONValue {
        .compact([
            ("id", .string(id)), ("canonical", .string(directory)), ("vcs", vcs.map(JSONValue.string)),
            ("name", name.map(JSONValue.string)),
            ("time", ["created": .int(Int(created)), "updated": .int(Int(updated)), "active": .int(Int(active))]),
            ("sandboxes", []),
        ])
    }

    func contains(directory other: String) -> Bool {
        other == directory || other.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }
}

/// `Session.Info`.
public struct MockSession: Sendable, Hashable {
    public var id: String
    public var parentID: String?
    public var projectID: String
    public var directory: String
    public var slug: String
    public var title: String?
    public var agent: String?
    public var model: ModelRef?
    public var cost: Double = 0
    public var tokens: TokenUsage = .zero
    public var outcome: String?
    public var created: Int64
    public var updated: Int64
    public var busy: Int64?
    public var idle: Int64?
    public var viewed: Int64?
    public var archived: Int64?
    public var metadata: JSONValue?
    public var permissions: JSONValue?

    public init(
        id: String, parentID: String? = nil, projectID: String, directory: String, slug: String = "mock-session",
        title: String? = nil, agent: String? = nil, model: ModelRef? = nil, time: Int64, metadata: JSONValue? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.projectID = projectID
        self.directory = directory
        self.slug = slug
        self.title = title
        self.agent = agent
        self.model = model
        created = time
        updated = time
        self.metadata = metadata
    }

    public var json: JSONValue {
        let time: JSONValue = .compact([
            ("created", .int(Int(created))), ("updated", .int(Int(updated))), ("busy", busy.map { .int(Int($0)) }),
            ("idle", idle.map { .int(Int($0)) }), ("viewed", viewed.map { .int(Int($0)) }),
            ("archived", archived.map { .int(Int($0)) }),
        ])
        return .compact([
            ("id", .string(id)), ("parentID", parentID.map(JSONValue.string)), ("projectID", .string(projectID)),
            ("agent", agent.map(JSONValue.string)), ("model", model?.json), ("cost", Self.money(cost)),
            ("tokens", tokens.json), ("outcome", outcome.map(JSONValue.string)), ("time", time),
            ("title", title.map(JSONValue.string)), ("metadata", metadata), ("permissions", permissions),
            ("location", ["directory": .string(directory)]),
        ])
    }

    static func money(_ value: Double) -> JSONValue {
        value.rounded() == value ? .int(Int(value)) : .double(value)
    }
}

/// Content of a tool result (`Tool.Content`).
public enum ToolContent: Sendable, Hashable, Codable {
    case text(String)
    case file(uri: String, mime: String, name: String?)

    public var json: JSONValue {
        switch self {
        case let .text(text): ["type": "text", "text": .string(text)]
        case let .file(uri, mime, name):
            .compact([
                ("type", "file"), ("uri", .string(uri)), ("mime", .string(mime)), ("name", name.map(JSONValue.string)),
            ])
        }
    }
}

/// `Session.Message.ToolState.*`.
public enum ToolState: Sendable, Hashable {
    case streaming(input: String)
    case running(input: JSONValue, metadata: JSONValue)
    case completed(input: JSONValue, content: [ToolContent], metadata: JSONValue?)
    case error(input: JSONValue, error: StructuredError, metadata: JSONValue?)

    public var json: JSONValue {
        switch self {
        case let .streaming(input): ["status": "streaming", "input": .string(input)]
        case let .running(input, metadata): ["status": "running", "input": input, "metadata": metadata]
        case let .completed(input, content, metadata):
            .compact([
                ("status", "completed"), ("input", input), ("content", .array(content.map(\.json))),
                ("metadata", metadata),
            ])
        case let .error(input, error, metadata):
            .compact([("status", "error"), ("input", input), ("error", error.json), ("metadata", metadata)])
        }
    }
}

/// One entry of an assistant message's `content`.
public enum AssistantPart: Sendable, Hashable {
    case text(String)
    case reasoning(text: String, created: Int64, completed: Int64?)
    case tool(ToolPart)

    public var json: JSONValue {
        switch self {
        case let .text(text): ["type": "text", "text": .string(text)]
        case let .reasoning(text, created, completed):
            [
                "type": "reasoning", "text": .string(text),
                "time": .compact([("created", .int(Int(created))), ("completed", completed.map { .int(Int($0)) })]),
            ]
        case let .tool(tool): tool.json
        }
    }
}

public struct ToolPart: Sendable, Hashable {
    public var id: String
    public var name: String
    public var executed: Bool = false
    public var state: ToolState
    public var created: Int64
    public var ran: Int64?
    public var completed: Int64?

    public init(id: String, name: String, state: ToolState, created: Int64, ran: Int64? = nil, completed: Int64? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.created = created
        self.ran = ran
        self.completed = completed
    }

    public var json: JSONValue {
        [
            "type": "tool", "id": .string(id), "name": .string(name), "executed": .bool(executed),
            "state": state.json,
            "time": .compact([
                ("created", .int(Int(created))), ("ran", ran.map { .int(Int($0)) }),
                ("completed", completed.map { .int(Int($0)) }),
            ]),
        ]
    }
}

/// `Session.Message.Assistant`.
public struct AssistantMessage: Sendable, Hashable {
    public var id: String
    public var agent: String
    public var model: ModelRef
    public var content: [AssistantPart] = []
    public var created: Int64
    public var firstToken: Int64?
    public var streamed: Int64?
    public var completed: Int64?
    public var finish: String?
    public var cost: Double?
    public var tokens: TokenUsage?
    public var error: StructuredError?
    public var snapshot: String?

    public init(id: String, agent: String, model: ModelRef, created: Int64, content: [AssistantPart] = []) {
        self.id = id
        self.agent = agent
        self.model = model
        self.created = created
        self.content = content
    }

    public var json: JSONValue {
        let time: JSONValue = .compact([
            ("created", .int(Int(created))), ("firstToken", firstToken.map { .int(Int($0)) }),
            ("streamed", streamed.map { .int(Int($0)) }), ("completed", completed.map { .int(Int($0)) }),
        ])
        return .compact([
            ("id", .string(id)), ("time", time), ("type", "assistant"), ("agent", .string(agent)),
            ("model", model.json), ("content", .array(content.map(\.json))),
            ("snapshot", snapshot.map { ["start": .string($0), "end": .string($0), "files": []] }),
            ("finish", finish.map(JSONValue.string)), ("cost", cost.map(MockSession.money)), ("tokens", tokens?.json),
            ("error", error?.json),
        ])
    }
}

/// One `Session.Message.Info`.
public struct MockMessage: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case user(text: String, created: Int64, metadata: JSONValue?)
        case assistant(AssistantMessage)
        /// Any other message type (`synthetic`, `shell`, `compaction`, ...), stored as its full JSON.
        case raw(type: String, json: JSONValue)
    }

    public var id: String
    public var kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public static func user(id: String, text: String, time: Int64) -> MockMessage {
        MockMessage(id: id, kind: .user(text: text, created: time, metadata: nil))
    }

    public static func assistant(_ message: AssistantMessage) -> MockMessage {
        MockMessage(id: message.id, kind: .assistant(message))
    }

    public var type: String {
        switch kind {
        case .user: "user"
        case .assistant: "assistant"
        case let .raw(type, _): type
        }
    }

    public var json: JSONValue {
        switch kind {
        case let .user(text, created, metadata):
            .compact([
                ("id", .string(id)), ("metadata", metadata), ("time", ["created": .int(Int(created))]),
                ("text", .string(text)), ("type", "user"),
            ])
        case let .assistant(message): message.json
        case let .raw(_, json): json
        }
    }
}

/// `Permission.Request`.
public struct MockPermission: Sendable, Hashable {
    public var id: String
    public var sessionID: String
    public var action: String
    public var resources: [String]
    public var save: [String]?
    public var metadata: JSONValue?
    public var source: (messageID: String, toolID: String)?
    public var message: String?

    public static func == (a: MockPermission, b: MockPermission) -> Bool { a.json == b.json }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var json: JSONValue {
        .compact([
            ("id", .string(id)), ("sessionID", .string(sessionID)), ("action", .string(action)),
            ("resources", .array(resources.map(JSONValue.string))),
            ("save", save.map { .array($0.map(JSONValue.string)) }), ("metadata", metadata),
            ("source", source.map { ["type": "tool", "messageID": .string($0.messageID), "id": .string($0.toolID)] }),
            ("message", message.map(JSONValue.string)),
        ])
    }
}

/// `Form.Info` (questions and elicitations).
public struct MockForm: Sendable, Hashable {
    public var id: String
    public var sessionID: String
    public var title: String
    public var metadata: JSONValue?
    public var fields: JSONValue

    public var json: JSONValue {
        .compact([
            ("id", .string(id)), ("sessionID", .string(sessionID)), ("title", .string(title)), ("metadata", metadata),
            ("fields", fields),
        ])
    }
}

/// Providers, models and agents served by `/api/provider`, `/api/model` and `/api/agent`, as raw API JSON.
public struct MockCatalog: Sendable {
    public var providers: [JSONValue]
    public var models: [JSONValue]
    public var agents: [JSONValue]
    public var defaultModelID: String

    public init(providers: [JSONValue], models: [JSONValue], agents: [JSONValue], defaultModelID: String) {
        self.providers = providers
        self.models = models
        self.agents = agents
        self.defaultModelID = defaultModelID
    }
}
