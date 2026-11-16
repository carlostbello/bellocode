import Foundation

/// `Session.Inbox.Delivery`: when a prompt is delivered to a busy session.
public struct InboxDelivery: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Deliver at the next safe step boundary (the server default).
    public static let steer: Self = "steer"
    /// Deliver when the session is idle, one at a time.
    public static let queue: Self = "queue"
}

/// Body of `POST /api/session/{id}/prompt`. The call returns as soon as the prompt is admitted to the inbox; the turn
/// runs asynchronously and is observed through events.
public struct PromptRequest: Encodable, Sendable, Hashable {
    /// `Prompt.Mention`: where a mention sits in `text`, as UTF-16 offsets (JavaScript string indices), end exclusive.
    public struct Mention: Encodable, Sendable, Hashable {
        public var start: Int
        public var end: Int
        public var text: String

        public init(start: Int, end: Int, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// `Prompt.FileSource`: `{type: "uri", uri}` or `{type: "inline"}`.
    public enum FileSource: Encodable, Sendable, Hashable {
        case uri(String)
        case inline

        private enum CodingKeys: String, CodingKey { case type, uri }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .uri(let uri):
                try container.encode("uri", forKey: .type)
                try container.encode(uri, forKey: .uri)
            case .inline:
                try container.encode("inline", forKey: .type)
            }
        }
    }

    /// `PromptInput.FileAttachment`: `uri` is required; the rest is optional.
    public struct FileAttachment: Encodable, Sendable, Hashable {
        public var uri: String
        public var name: String?
        public var description: String?
        public var source: FileSource?
        public var mention: Mention?

        public init(
            uri: String, name: String? = nil, description: String? = nil, source: FileSource? = nil, mention: Mention? = nil
        ) {
            self.uri = uri
            self.name = name
            self.description = description
            self.source = source
            self.mention = mention
        }
    }

    /// `Prompt.AgentAttachment`.
    public struct AgentAttachment: Encodable, Sendable, Hashable {
        public var name: String
        public var mention: Mention?

        public init(name: String, mention: Mention? = nil) {
            self.name = name
            self.mention = mention
        }
    }

    /// `PromptInput.SkillAttachment`.
    public struct SkillAttachment: Encodable, Sendable, Hashable {
        public var id: String
        public var mention: Mention?

        public init(id: String, mention: Mention? = nil) {
            self.id = id
            self.mention = mention
        }
    }

    /// Client-chosen message id (`msg_…`); admission is idempotent on it.
    public var id: String?
    public var text: String
    public var files: [FileAttachment]?
    public var agents: [AgentAttachment]?
    public var skills: [SkillAttachment]?
    public var metadata: JSONValue?
    public var delivery: InboxDelivery?
    public var resume: Bool?

    public init(
        text: String, id: String? = nil, files: [FileAttachment]? = nil, agents: [AgentAttachment]? = nil,
        skills: [SkillAttachment]? = nil, metadata: JSONValue? = nil, delivery: InboxDelivery? = nil, resume: Bool? = nil
    ) {
        self.id = id
        self.text = text
        self.files = files
        self.agents = agents
        self.skills = skills
        self.metadata = metadata
        self.delivery = delivery
        self.resume = resume
    }

    private enum CodingKeys: String, CodingKey { case id, text, files, agents, skills, metadata, delivery, resume }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(files.flatMap { $0.isEmpty ? nil : $0 }, forKey: .files)
        try container.encodeIfPresent(agents.flatMap { $0.isEmpty ? nil : $0 }, forKey: .agents)
        try container.encodeIfPresent(skills.flatMap { $0.isEmpty ? nil : $0 }, forKey: .skills)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(delivery, forKey: .delivery)
        try container.encodeIfPresent(resume, forKey: .resume)
    }
}

/// `Session.Inbox.User`: the admitted inbox item returned by `prompt`. Its `id` becomes the user message id.
public struct InboxUserItem: Decodable, Sendable, Hashable {
    public struct Time: Decodable, Sendable, Hashable { public var created: Double }

    public var id: String
    public var sessionID: String
    public var time: Time
    public var delivery: InboxDelivery
}

/// `SessionInterruptResponse`.
public struct InterruptResult: Decodable, Sendable, Hashable {
    /// Whether an active execution owned by this server process was interrupted.
    public var interrupted: Bool
}

/// `Session.Inbox.Info` (`GET /api/session/{id}/inbox`): an admitted prompt not yet delivered. Only the fields BelloCode
/// shows are decoded; attachments stay on the server.
public struct InboxItem: Decodable, Sendable, Hashable, Identifiable {
    public struct Time: Decodable, Sendable, Hashable { public var created: Double }
    public struct Payload: Decodable, Sendable, Hashable { public var text: String? }

    /// Becomes the user message ID on delivery.
    public var id: String
    public var sessionID: String
    public var time: Time
    /// `user`, `synthetic`, `compaction`, `move`.
    public var type: String
    public var delivery: InboxDelivery
    public var payload: Payload?

    public var text: String? { payload?.text }
}

struct InboxUpdateBody: Encodable, Sendable {
    let delivery: InboxDelivery
}

struct SessionViewBody: Encodable, Sendable {
    let idle: Double
}

struct SwitchAgentBody: Encodable, Sendable {
    let agent: String
}

struct SwitchModelBody: Encodable, Sendable {
    let model: ModelRef
}

/// Body of `POST /api/session/{id}/command` (session.command): run a slash command with its argument text.
public struct CommandRequest: Encodable, Sendable, Hashable {
    public var name: String
    public var text: String
    public var files: [PromptRequest.FileAttachment]?
    public var agents: [PromptRequest.AgentAttachment]?
    public var skills: [PromptRequest.SkillAttachment]?
    public var delivery: InboxDelivery?

    public init(
        name: String, text: String, files: [PromptRequest.FileAttachment]? = nil,
        agents: [PromptRequest.AgentAttachment]? = nil, skills: [PromptRequest.SkillAttachment]? = nil,
        delivery: InboxDelivery? = nil
    ) {
        self.name = name
        self.text = text
        self.files = files?.isEmpty == true ? nil : files
        self.agents = agents?.isEmpty == true ? nil : agents
        self.skills = skills?.isEmpty == true ? nil : skills
        self.delivery = delivery
    }
}
