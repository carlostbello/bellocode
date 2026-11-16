import Foundation

/// `Session.Info`.
public struct SessionInfo: Codable, Sendable, Hashable, Identifiable {
    public struct Fork: Codable, Sendable, Hashable {
        public var sessionID: String
        /// `{ type: "before" | "through", messageID }`.
        public var boundary: JSONValue
    }

    public struct Time: Codable, Sendable, Hashable {
        public var created: Double
        public var updated: Double
        public var busy: Double?
        public var idle: Double?
        public var viewed: Double?
        public var archived: Double?
    }

    public var id: String
    public var parentID: String?
    public var fork: Fork?
    public var projectID: String
    public var agent: String?
    public var model: ModelRef?
    /// USD.
    public var cost: Double
    public var tokens: TokenUsage
    public var outcome: SessionOutcome?
    public var time: Time
    public var title: String?
    public var subpath: String?
    /// Client-owned free-form storage.
    public var metadata: JSONValue?
    public var permissions: [PermissionRule]?
    /// `Session.Revert`, kept raw until revert lands.
    public var revert: JSONValue?
    public var location: LocationRef
}

/// `Session.Info.outcome` and `Session.Message.Idle.outcome`.
public struct SessionOutcome: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let succeeded: Self = "succeeded"
    public static let failed: Self = "failed"
    public static let interrupted: Self = "interrupted"
}

/// Filters for `GET /api/session`.
public struct SessionListQuery: Sendable, Hashable {
    /// Parent filter.
    public enum Parent: Sendable, Hashable {
        /// Only top-level sessions (`parentID=null`).
        case root
        /// Children of this session.
        case session(String)
    }

    public var directory: String?
    public var project: String?
    public var subpath: String?
    public var parent: Parent?
    public var archived: Bool?
    public var search: String?
    public var limit: Int?
    public var order: ListOrder?
    /// A cursor from a previous page; do not combine with `order`.
    public var cursor: String?

    public init(
        directory: String? = nil, project: String? = nil, subpath: String? = nil, parent: Parent? = nil,
        archived: Bool? = nil, search: String? = nil, limit: Int? = nil, order: ListOrder? = nil, cursor: String? = nil
    ) {
        self.directory = directory
        self.project = project
        self.subpath = subpath
        self.parent = parent
        self.archived = archived
        self.search = search
        self.limit = limit
        self.order = order
        self.cursor = cursor
    }
}

/// Body of `POST /api/session`.
public struct SessionCreateRequest: Encodable, Sendable, Hashable {
    /// Client-chosen id (`ses_…`); optional.
    public var id: String?
    public var parentID: String?
    public var title: String?
    public var agent: String?
    public var model: ModelRef?
    /// The project directory the session runs in.
    public var location: LocationRef?
    public var metadata: JSONValue?
    public var permissions: [PermissionRule]?

    public init(
        directory: String?, id: String? = nil, parentID: String? = nil, title: String? = nil, agent: String? = nil,
        model: ModelRef? = nil, metadata: JSONValue? = nil, permissions: [PermissionRule]? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.agent = agent
        self.model = model
        self.location = directory.map { LocationRef(directory: $0) }
        self.metadata = metadata
        self.permissions = permissions
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(agent, forKey: .agent)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(location.map { ["directory": $0.directory] }, forKey: .location)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(permissions, forKey: .permissions)
    }

    private enum CodingKeys: String, CodingKey {
        case id, parentID, title, agent, model, location, metadata, permissions
    }
}

/// Body of `PATCH /api/session/{id}`. Only non-nil fields are sent.
public struct SessionUpdateRequest: Encodable, Sendable, Hashable {
    public var title: String?
    public var metadata: JSONValue?
    public var permissions: [PermissionRule]?
    /// `true` archives, `false` restores.
    public var archived: Bool?

    public init(title: String? = nil, metadata: JSONValue? = nil, permissions: [PermissionRule]? = nil, archived: Bool? = nil) {
        self.title = title
        self.metadata = metadata
        self.permissions = permissions
        self.archived = archived
    }
}
