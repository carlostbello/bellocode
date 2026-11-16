import Foundation

/// Providers, models and agents available in one location (directory). Never holds credentials.
public struct Catalog: Hashable, Sendable, Codable {
    public var directory: String
    public var providers: [ProviderEntry]
    public var models: [ModelEntry]
    public var agents: [AgentEntry]
    public var defaultModel: ModelSelection?
    public var fetched: Timestamp

    public init(
        directory: String, providers: [ProviderEntry] = [], models: [ModelEntry] = [], agents: [AgentEntry] = [],
        defaultModel: ModelSelection? = nil, fetched: Timestamp
    ) {
        self.directory = directory
        self.providers = providers
        self.models = models
        self.agents = agents
        self.defaultModel = defaultModel
        self.fetched = fetched
    }

    /// Agents the user can pick for a thread (primary or all, not hidden).
    public var primaryAgents: [AgentEntry] { agents.filter { !$0.hidden && $0.mode != .subagent } }

    public func models(of providerID: String) -> [ModelEntry] { models.filter { $0.providerID == providerID } }
}

public struct ProviderEntry: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// `auto`, `enabled`, `disabled`.
    public var activation: String

    public init(id: String, name: String, activation: String) {
        self.id = id
        self.name = name
        self.activation = activation
    }
}

public struct ModelEntry: Hashable, Sendable, Codable, Identifiable {
    public var providerID: String
    public var modelID: String
    public var name: String
    public var family: String?
    public var contextLimit: Int
    public var outputLimit: Int
    public var variants: [String]
    public var supportsTools: Bool
    public var inputModalities: [String]
    /// `alpha`, `beta`, `deprecated`, `active`.
    public var status: String
    public var enabled: Bool
    /// True when every listed cost is zero (opencode's free models).
    public var isFree: Bool

    public init(
        providerID: String, modelID: String, name: String, family: String? = nil, contextLimit: Int = 0,
        outputLimit: Int = 0, variants: [String] = [], supportsTools: Bool = true, inputModalities: [String] = ["text"],
        status: String = "active", enabled: Bool = true, isFree: Bool = false
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.name = name
        self.family = family
        self.contextLimit = contextLimit
        self.outputLimit = outputLimit
        self.variants = variants
        self.supportsTools = supportsTools
        self.inputModalities = inputModalities
        self.status = status
        self.enabled = enabled
        self.isFree = isFree
    }

    public var id: String { "\(providerID)/\(modelID)" }
    public var selection: ModelSelection { ModelSelection(providerID: providerID, modelID: modelID) }
}

public struct AgentEntry: Hashable, Sendable, Codable, Identifiable {
    public enum Mode: String, Hashable, Sendable, Codable {
        case primary, subagent, all
    }

    public var id: String
    public var name: String
    public var detail: String?
    public var mode: Mode
    public var hidden: Bool
    public var color: String?
    public var model: ModelSelection?

    public init(
        id: String, name: String, detail: String? = nil, mode: Mode, hidden: Bool = false, color: String? = nil,
        model: ModelSelection? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.mode = mode
        self.hidden = hidden
        self.color = color
        self.model = model
    }
}
