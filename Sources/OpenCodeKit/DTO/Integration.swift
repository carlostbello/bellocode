import Foundation

// Integrations (provider login) and stored credentials (Contracts/opencode-2.3.0/openapi.json).
//
// Secrets: `GET /api/credential` returns every credential *including its secret value*. `CredentialSummary` decodes only
// the non-secret members (`id`, `integrationID`, `label`, `active`, `value.type`, `value.methodID`); the key, access and
// refresh tokens are never decoded into a Swift value. Request bodies that carry a key (`ConnectKeyBody`) are encoded
// once into the request and never logged.

/// `Integration.Info`: a provider (or other service) and the ways to authenticate with it.
public struct IntegrationInfo: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var methods: [IntegrationMethod]
    public var connections: [IntegrationConnection]

    public init(id: String, name: String, methods: [IntegrationMethod], connections: [IntegrationConnection]) {
        self.id = id
        self.name = name
        self.methods = methods
        self.connections = connections
    }
}

/// `Integration.Method`: the union (oauth, command, key, external, env) flattened into one tolerant struct.
public struct IntegrationMethod: Decodable, Sendable, Hashable {
    public var type: IntegrationMethodType
    /// Present on `oauth`, `command` and `external` (the `methodID` to send); absent on `key` and `env`.
    public var id: String?
    public var label: String?
    /// Extra questions to answer before connecting (`Form.Fields`), sent back as `answer`.
    public var form: [FormField]?
    /// `command` methods: the command line the server will run.
    public var command: [String]?
    /// `env` methods: environment variables the server reads.
    public var names: [String]?

    public init(
        type: IntegrationMethodType, id: String? = nil, label: String? = nil, form: [FormField]? = nil,
        command: [String]? = nil, names: [String]? = nil
    ) {
        self.type = type
        self.id = id
        self.label = label
        self.form = form
        self.command = command
        self.names = names
    }
}

public struct IntegrationMethodType: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let oauth: Self = "oauth"
    public static let command: Self = "command"
    public static let key: Self = "key"
    public static let external: Self = "external"
    public static let env: Self = "env"
}

/// `Connection.Info`: a stored credential (`credential`) or an environment variable the server found (`env`).
public struct IntegrationConnection: Decodable, Sendable, Hashable {
    /// `Connection.Status`: present when the connection needs attention.
    public struct Status: Decodable, Sendable, Hashable {
        /// `needs_auth`.
        public var status: String
        public var message: String
        public var url: String?
    }

    /// `credential` or `env`.
    public var type: String
    /// Credential ID (`credential` connections).
    public var id: String?
    public var label: String?
    /// `key`, `oauth` or `external` (`credential` connections).
    public var method: String?
    /// Variable name (`env` connections).
    public var name: String?
    public var status: Status?
}

/// `Integration.AttemptEncoded`: an OAuth attempt to finish in the browser.
public struct OAuthAttempt: Decodable, Sendable, Hashable {
    public struct Time: Decodable, Sendable, Hashable {
        public var created: FlexibleNumber
        public var expires: FlexibleNumber
    }

    public var attemptID: String
    /// The authorization page to open in the user's browser.
    public var url: String
    public var instructions: String
    /// `auto`: the server's callback completes it (poll the status); `code`: the user pastes a code.
    public var mode: String
    /// For `auto` attempts: the user may also paste the redirect URL (`complete` with it).
    public var paste: Bool?
    public var time: Time
}

/// `Integration.AttemptStatus` and `Integration.CommandAttemptStatus`.
public struct AttemptStatus: Decodable, Sendable, Hashable {
    public var status: AttemptState
    /// Failure reason (`failed`), or progress output (`pending` command attempts).
    public var message: String?
    public var time: OAuthAttempt.Time
}

public struct AttemptState: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let pending: Self = "pending"
    public static let complete: Self = "complete"
    public static let failed: Self = "failed"
    public static let expired: Self = "expired"
}

/// `Integration.CommandAttempt`.
public struct CommandAttempt: Decodable, Sendable, Hashable {
    public var attemptID: String
    public var time: OAuthAttempt.Time
}

/// The non-secret part of `Credential.Entry`. The secret members of `value` are skipped while decoding.
public struct CredentialSummary: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var integrationID: String
    public var label: String
    public var active: Bool
    /// `key`, `oauth` or `external`.
    public var kind: String
    /// The method that produced an `oauth` or `external` credential.
    public var methodID: String?

    public init(id: String, integrationID: String, label: String, active: Bool, kind: String, methodID: String? = nil) {
        self.id = id
        self.integrationID = integrationID
        self.label = label
        self.active = active
        self.kind = kind
        self.methodID = methodID
    }

    private enum CodingKeys: String, CodingKey {
        case id, integrationID, label, active, value
    }

    /// Only these two members of `Credential.Value` are read; `key`, `access`, `refresh` and `expires` are not.
    private enum ValueKeys: String, CodingKey {
        case type, methodID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        integrationID = try container.decode(String.self, forKey: .integrationID)
        label = try container.decode(String.self, forKey: .label)
        active = try container.decode(Bool.self, forKey: .active)
        let value = try container.nestedContainer(keyedBy: ValueKeys.self, forKey: .value)
        kind = try value.decode(String.self, forKey: .type)
        methodID = try value.decodeIfPresent(String.self, forKey: .methodID)
    }
}

/// `PermissionSaved.Info`: a rule saved by an "always" reply. It applies to every session of the project.
public struct SavedPermission: Decodable, Sendable, Hashable, Identifiable {
    public struct Time: Decodable, Sendable, Hashable {
        public var created: Double
        public var updated: Double
    }

    public var id: String
    public var projectID: String
    public var action: String
    public var resource: String
    public var time: Time
}

/// The result of `POST /api/session/{id}/permission`: the effect the server's rules give, and the request ID (pending
/// only when the effect is `ask`).
public struct PermissionEvaluation: Decodable, Sendable, Hashable {
    public var id: String
    public var effect: PermissionEffect
}

/// Body of `POST /api/session/{id}/permission`.
public struct PermissionCreateRequest: Encodable, Sendable, Hashable {
    public var id: String?
    public var action: String
    public var resources: [String]
    public var save: [String]?
    public var agent: String?

    public init(id: String? = nil, action: String, resources: [String], save: [String]? = nil, agent: String? = nil) {
        self.id = id
        self.action = action
        self.resources = resources
        self.save = save
        self.agent = agent
    }
}

struct ConnectKeyBody: Encodable, Sendable {
    let key: String
    let answer: [String: FormValue]?
    let label: String?
}

struct ConnectMethodBody: Encodable, Sendable {
    let methodID: String
    let answer: [String: FormValue]?
    let label: String?
}

struct ConnectCommandBody: Encodable, Sendable {
    let methodID: String
    let label: String?
}

struct OAuthCompleteBody: Encodable, Sendable {
    let code: String?
}

struct CredentialLabelBody: Encodable, Sendable {
    let label: String
}

struct DataList<T: Decodable & Sendable>: Decodable, Sendable {
    let data: [T]
}
