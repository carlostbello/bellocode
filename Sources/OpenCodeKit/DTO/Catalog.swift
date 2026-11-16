import Foundation

// Provider, model and agent catalogs. The contract's `headers`, `body`, `settings` and `request` members are not
// modelled on purpose: they can carry provider credentials and must never be decoded, cached or logged.

/// `Model.Info`.
public struct ModelInfo: Codable, Sendable, Hashable, Identifiable {
    public struct Capabilities: Codable, Sendable, Hashable {
        public var tools: Bool
        public var input: [String]
        public var output: [String]
        public var temperature: Bool?
    }

    public struct Variant: Codable, Sendable, Hashable {
        public var id: String
    }

    public struct Limit: Codable, Sendable, Hashable {
        public var context: Int
        public var input: Int?
        public var output: Int
    }

    public struct Time: Codable, Sendable, Hashable {
        public var released: Double
    }

    public var id: String
    public var modelID: String
    public var providerID: String
    public var canonical: String?
    /// `chat`, `decision`, `image`, or a newer type.
    public var type: String?
    public var family: String?
    public var name: String
    public var capabilities: Capabilities
    public var variants: [Variant]
    public var time: Time
    /// `Model.Cost` entries, kept raw.
    public var cost: [JSONValue]
    public var status: ModelStatus
    public var enabled: Bool
    public var limit: Limit

    /// The reference to send in session create or prompt requests.
    public var ref: ModelRef { ModelRef(id: modelID, providerID: providerID) }
}

public struct ModelStatus: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let alpha: Self = "alpha"
    public static let beta: Self = "beta"
    public static let deprecated: Self = "deprecated"
    public static let active: Self = "active"
}

/// `Provider.Info`.
public struct ProviderInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var canonical: String?
    public var integrationID: String?
    public var name: String
    /// `auto`, `enabled`, `disabled`.
    public var activation: String
    public var package: String
}

/// `Agent.Info`.
public struct AgentInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var model: ModelRef?
    public var description: String?
    public var mode: AgentMode
    public var hidden: Bool
    public var color: String?
    public var steps: Int?
    public var permissions: [PermissionRule]
}

public struct AgentMode: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let primary: Self = "primary"
    public static let subagent: Self = "subagent"
    public static let all: Self = "all"
}

/// `{ location, data: Model.Info | null }` from `GET /api/model/default`.
struct DefaultModelResponse: Decodable, Sendable {
    let location: LocationRef
    let data: ModelInfo?
}

/// `Command.Info` (`GET /api/command`): a slash command the server can run.
public struct CommandInfo: Decodable, Sendable, Hashable {
    public var name: String
    public var description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

/// `Skill.Info` (`GET /api/skill`), without its `content` (not needed for completion and possibly large).
public struct SkillInfo: Decodable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var description: String?
    public var path: String?

    public init(id: String, name: String, description: String? = nil, path: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.path = path
    }

    private enum CodingKeys: String, CodingKey { case id, name, description, path }
}

/// `FileSystem.Entry` (`GET /api/fs/find`): a path relative to the requested location.
public struct FileSystemEntry: Decodable, Sendable, Hashable {
    public enum Kind: String, Decodable, Sendable, Hashable { case file, directory }
    public var path: String
    public var type: Kind

    public init(path: String, type: Kind) {
        self.path = path
        self.type = type
    }
}

/// `Location.PublicInfo` (`GET /api/location`): a directory and the project opencode resolves it to (a subfolder
/// of a git repository resolves to the repository's project).
public struct LocationInfo: Decodable, Sendable, Hashable {
    public struct ProjectRef: Decodable, Sendable, Hashable {
        public var id: String
        public var directory: String
        public var canonical: String
    }

    public var directory: String
    public var project: ProjectRef
}
