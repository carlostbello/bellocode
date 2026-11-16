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
