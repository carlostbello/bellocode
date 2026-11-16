import Foundation

/// A pending approval: the agent wants to run `action` on `resources` and is blocked until the user replies.
public struct PermissionRequest: Hashable, Sendable, Codable, Identifiable {
    public var id: PermissionRequestID
    public var sessionID: SessionID
    /// `read`, `edit`, `shell`, `external_directory`, … (plugins may add more).
    public var action: String
    public var resources: [String]
    /// Patterns an "always" reply would allow from now on, so the UI can show the exact scope.
    public var alwaysScopes: [String]
    public var message: String?
    /// The tool call that asked.
    public var toolMessageID: MessageID?
    public var toolCallID: String?
    public var received: Timestamp

    public init(
        id: PermissionRequestID, sessionID: SessionID, action: String, resources: [String], alwaysScopes: [String] = [],
        message: String? = nil, toolMessageID: MessageID? = nil, toolCallID: String? = nil, received: Timestamp
    ) {
        self.id = id
        self.sessionID = sessionID
        self.action = action
        self.resources = resources
        self.alwaysScopes = alwaysScopes
        self.message = message
        self.toolMessageID = toolMessageID
        self.toolCallID = toolCallID
        self.received = received
    }
}

/// A reply to a permission request.
public enum PermissionReply: String, Hashable, Sendable, Codable, CaseIterable {
    /// Allow this one call.
    case once
    /// Allow this call and save `alwaysScopes` for the session.
    case always
    /// Deny; the tool call fails and the agent is told.
    case reject
}

/// A structured question (opencode "form": the `question` tool or an MCP elicitation).
public struct QuestionRequest: Hashable, Sendable, Codable, Identifiable {
    public var id: QuestionID
    public var sessionID: SessionID
    public var title: String
    public var fields: [QuestionField]
    public var received: Timestamp

    public init(id: QuestionID, sessionID: SessionID, title: String, fields: [QuestionField], received: Timestamp) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.fields = fields
        self.received = received
    }
}

public struct QuestionField: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: Hashable, Sendable, Codable {
        case text, number, integer, boolean, multiselect
        /// Open `url` (for example an OAuth page); there is nothing to type.
        case external
        case other(String)
    }

    public struct Option: Hashable, Sendable, Codable {
        public var value: String
        public var label: String
        public var detail: String?

        public init(value: String, label: String, detail: String? = nil) {
            self.value = value
            self.label = label
            self.detail = detail
        }
    }

    /// The answer key.
    public var key: String
    public var kind: Kind
    public var title: String?
    public var detail: String?
    public var required: Bool
    public var options: [Option]
    /// A custom answer is allowed besides `options`.
    public var allowsCustom: Bool
    public var placeholder: String?
    public var defaultValue: QuestionAnswer?
    public var url: String?

    public init(
        key: String, kind: Kind, title: String? = nil, detail: String? = nil, required: Bool = false,
        options: [Option] = [], allowsCustom: Bool = false, placeholder: String? = nil,
        defaultValue: QuestionAnswer? = nil, url: String? = nil
    ) {
        self.key = key
        self.kind = kind
        self.title = title
        self.detail = detail
        self.required = required
        self.options = options
        self.allowsCustom = allowsCustom
        self.placeholder = placeholder
        self.defaultValue = defaultValue
        self.url = url
    }

    public var id: String { key }
}

public enum QuestionAnswer: Hashable, Sendable, Codable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case choices([String])
}

/// Anything that blocks an agent until the user acts. Pinned above the composer and counted in the sidebar.
public enum PendingRequest: Hashable, Sendable, Codable, Identifiable {
    case permission(PermissionRequest)
    case question(QuestionRequest)

    /// Unique across both kinds (`per_…` / `frm_…`).
    public var id: String {
        switch self {
        case .permission(let request): request.id.rawValue
        case .question(let request): request.id.rawValue
        }
    }

    public var sessionID: SessionID {
        switch self {
        case .permission(let request): request.sessionID
        case .question(let request): request.sessionID
        }
    }

    public var received: Timestamp {
        switch self {
        case .permission(let request): request.received
        case .question(let request): request.received
        }
    }

    public var isPermission: Bool { if case .permission = self { true } else { false } }
}

// MARK: - Queue

/// When a follow-up reaches a running agent.
public enum PromptDelivery: String, Hashable, Sendable, Codable {
    /// At the next safe step boundary of the running turn.
    case steer
    /// After the running turn ends, one at a time.
    case queue
}

/// A follow-up that is admitted (or being admitted) but not yet delivered to the agent.
public struct QueuedPrompt: Hashable, Sendable, Codable, Identifiable {
    public enum State: Hashable, Sendable, Codable {
        /// The request is in flight; not yet acknowledged.
        case sending
        /// The server holds it in the session inbox.
        case queued
    }

    /// The inbox item ID, which becomes the user message ID on delivery.
    public var id: MessageID
    public var sessionID: SessionID
    public var text: String
    public var delivery: PromptDelivery
    public var created: Timestamp
    public var state: State

    public init(id: MessageID, sessionID: SessionID, text: String, delivery: PromptDelivery, created: Timestamp, state: State) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.delivery = delivery
        self.created = created
        self.state = state
    }
}
