import Foundation

// Shared shapes from Contracts/opencode-2.3.0/openapi.json. DTOs decode tolerantly: unknown keys are ignored, string
// enums are `OpenEnum` structs, and unions carry an `.unknown` case with the raw JSON.

/// `Location.PublicRef`: the directory a request or event is scoped to.
public struct LocationRef: Codable, Sendable, Hashable {
    public var directory: String
    /// Present on `Location.Ref` (some events); absent on `Location.PublicRef`.
    public var workspaceID: String?

    public init(directory: String, workspaceID: String? = nil) {
        self.directory = directory
        self.workspaceID = workspaceID
    }
}

/// `Model.Ref`.
public struct ModelRef: Codable, Sendable, Hashable {
    public var id: String
    public var providerID: String
    public var variant: String?

    public init(id: String, providerID: String, variant: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.variant = variant
    }
}

/// `TokenUsage.Info`.
public struct TokenUsage: Codable, Sendable, Hashable {
    public struct Cache: Codable, Sendable, Hashable {
        public var read: Double
        public var write: Double
    }

    public var input: Double
    public var output: Double
    public var reasoning: Double
    public var cache: Cache
}

/// `Session.StructuredError`. `response.body` is deliberately not modelled: it can echo provider payloads.
public struct StructuredError: Codable, Sendable, Hashable {
    public var type: String
    public var message: String
    public var status: Int?
    public var retryAfterMs: Int?
}

/// `Permission.Effect`.
public struct PermissionEffect: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let allow: Self = "allow"
    public static let deny: Self = "deny"
    public static let ask: Self = "ask"
}

/// `Permission.Rule`.
public struct PermissionRule: Codable, Sendable, Hashable {
    public var action: String
    public var resource: String
    public var effect: PermissionEffect

    public init(action: String, resource: String, effect: PermissionEffect) {
        self.action = action
        self.resource = resource
        self.effect = effect
    }
}

/// `{ data: T }`, the wrapper most single-object responses use.
struct DataEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let data: T
}

/// `{ location, data: [T] }`, the wrapper of location-scoped list responses.
public struct LocatedList<T: Decodable & Sendable>: Decodable, Sendable {
    public let location: LocationRef
    public let data: [T]
}

/// A page from a cursor-paged list (`{ data, cursor: { previous, next } }`).
public struct Page<T: Decodable & Sendable>: Decodable, Sendable {
    public struct Cursor: Decodable, Sendable, Hashable {
        public var previous: String?
        public var next: String?
    }

    public let data: [T]
    public let cursor: Cursor
}

/// Sort order of the first page of a paged list.
public enum ListOrder: String, Sendable {
    case ascending = "asc"
    case descending = "desc"
}
