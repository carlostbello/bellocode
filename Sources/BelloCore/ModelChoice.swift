import Foundation

/// The model a background task uses, as chosen in Settings ▸ Models (docs/features/models.md).
///
/// Stored as one string token so a saved value stays readable and old values keep decoding: `thread`, `server`,
/// `small`, or a model as opencode writes it (`providerID/modelID`, optionally `#variant`). A model token always
/// contains a `/`, the keywords never do.
public enum ModelChoice: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The thread's own model ("Same as thread"; for delegated threads and schedules, "Same as parent").
    case sameAsThread
    /// opencode's default model (opencode.json `model`, else opencode's own pick).
    case serverDefault
    /// The small model (Settings ▸ Models ▸ Small model; else opencode's fast model of the thread's provider).
    case smallModel
    /// One model.
    case specific(ModelSelection)

    public init?(token: String) {
        switch token {
        case "thread": self = .sameAsThread
        case "server": self = .serverDefault
        case "small": self = .smallModel
        default:
            guard let selection = ModelSelection(token: token) else { return nil }
            self = .specific(selection)
        }
    }

    public var token: String {
        switch self {
        case .sameAsThread: "thread"
        case .serverDefault: "server"
        case .smallModel: "small"
        case .specific(let selection): selection.token
        }
    }

    public var selection: ModelSelection? { if case .specific(let selection) = self { selection } else { nil } }

    public var description: String { token }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let token = try container.decode(String.self)
        guard let value = ModelChoice(token: token) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a model choice: \(token.prefix(80))")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }
}

extension ModelSelection {
    /// `providerID/modelID` or `providerID/modelID#variant` (opencode's config form). The model ID may itself contain
    /// slashes (`openrouter/anthropic/claude-…`): only the first one separates the provider.
    public init?(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        let provider = String(trimmed[..<slash])
        var rest = String(trimmed[trimmed.index(after: slash)...])
        var variant: String?
        if let hash = rest.lastIndex(of: "#") {
            variant = String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
        }
        guard !provider.isEmpty, !rest.isEmpty, !provider.contains("#"), variant?.isEmpty != true else { return nil }
        self.init(providerID: provider, modelID: rest, variant: variant)
    }

    /// opencode's config form: `providerID/modelID` or `providerID/modelID#variant`.
    public var token: String { "\(providerID)/\(modelID)" + (variant.map { "#\($0)" } ?? "") }

    /// Same provider and model, whatever the variant.
    public func sameModel(as other: ModelSelection?) -> Bool {
        guard let other else { return false }
        return providerID == other.providerID && modelID == other.modelID
    }
}
