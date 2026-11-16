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
    /// `PromptInput.FileAttachment`.
    public struct FileAttachment: Encodable, Sendable, Hashable {
        public var uri: String
        public var name: String?
        public var description: String?

        public init(uri: String, name: String? = nil, description: String? = nil) {
            self.uri = uri
            self.name = name
            self.description = description
        }
    }

    /// Client-chosen message id (`msg_…`); admission is idempotent on it.
    public var id: String?
    public var text: String
    public var files: [FileAttachment]?
    /// `Prompt.AgentAttachment` names.
    public var agents: [String]?
    /// `PromptInput.SkillAttachment` ids.
    public var skills: [String]?
    public var metadata: JSONValue?
    public var delivery: InboxDelivery?
    public var resume: Bool?

    public init(
        text: String, id: String? = nil, files: [FileAttachment]? = nil, agents: [String]? = nil,
        skills: [String]? = nil, metadata: JSONValue? = nil, delivery: InboxDelivery? = nil, resume: Bool? = nil
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
        try container.encodeIfPresent(files, forKey: .files)
        try container.encodeIfPresent(agents?.map { ["name": $0] }, forKey: .agents)
        try container.encodeIfPresent(skills?.map { ["id": $0] }, forKey: .skills)
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
