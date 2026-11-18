import Foundation

/// A request BelloCode itself raises for an agent (docs/features/orchestration-extras.md): a secret the agent asked
/// for, or an app-level approval (agent-created schedules in a project, network access for an HTML visual). It joins
/// opencode's permissions and questions in `PendingRequest`, so it is pinned above the composer, counted in "Needs
/// you" and never auto-dismissed. It holds no secret value, ever.
public struct AppRequest: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: Hashable, Sendable, Codable {
        case secret(SecretPrompt)
        case approval(AppApproval)
    }

    /// `app_…`, unique; never collides with opencode's `per_…`/`frm_…`.
    public var id: String
    public var sessionID: SessionID
    public var kind: Kind
    public var received: Timestamp

    public static let idPrefix = "app_"

    public init(id: String, sessionID: SessionID, kind: Kind, received: Timestamp) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.received = received
    }

    public static func makeID(_ tag: String) -> String {
        idPrefix + tag + "_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).lowercased()
    }

    /// A secret blocks like a question; an approval like a permission.
    public var isApproval: Bool { if case .approval = kind { true } else { false } }
}

/// What the agent asked for with `request_secret`. Never carries the value.
public struct SecretPrompt: Hashable, Sendable, Codable {
    /// How the agent receives the secret once saved.
    public enum Delivery: String, Hashable, Sendable, Codable {
        /// A one-use reference (`bcsecret_…`), exchanged later for a one-read file with `secret_file`.
        case reference
        /// A one-read file path at once (a named pipe that yields the value to one reader, then disappears).
        case file
    }

    public var label: String
    public var reason: String
    /// A sign-in or setup page, shown as a button (opened only on the user's click).
    public var setupURL: String?
    public var delivery: Delivery
    /// Secret manager (docs/features/secrets.md): what the agent proposes; the person decides on the card.
    public var suggestion: SecretChoice?
    /// The asking thread's project root (a "this project only" scope binds to it).
    public var projectDirectory: String?

    public init(label: String, reason: String, setupURL: String? = nil, delivery: Delivery = .reference, suggestion: SecretChoice? = nil,
                projectDirectory: String? = nil) {
        self.label = label
        self.reason = reason
        self.setupURL = setupURL
        self.delivery = delivery
        self.suggestion = suggestion
        self.projectDirectory = projectDirectory
    }
}

/// How a requested secret will be used, as chosen on the card (docs/features/secrets.md). Holds no value.
public struct SecretChoice: Hashable, Sendable, Codable {
    public enum Mode: String, Hashable, Sendable, Codable, CaseIterable {
        /// BelloCode performs the operation (`bellocode_app_http_request`); the agent gets a handle.
        case brokered
        /// The agent's programs get a placeholder; the proxy substitutes it for the bound destination.
        case placeholder
        /// The agent receives the value (needs `confirmVisible`).
        case visible
        /// Only commands the person approves verbatim receive it (`secret_exec`); such a command can reveal it.
        case command
    }

    public var mode: Mode
    /// The handle (`{{secret:NAME}}`, `$NAME`).
    public var name: String
    /// The bound destination, `https://host[:port]`.
    public var destination: String
    /// Header carrying it (e.g. `Authorization`), with an optional prefix (`Bearer `); or a query parameter.
    public var headerName: String
    public var headerPrefix: String
    public var queryName: String
    /// Allowed path prefix (`/v1`); empty: any path.
    public var pathPrefix: String
    /// Allowed methods, e.g. `GET,POST`; empty: any.
    public var methods: String
    /// True: only this project; false: all projects.
    public var projectOnly: Bool
    public var confirmVisible: Bool

    public init(mode: Mode, name: String = "", destination: String = "", headerName: String = "", headerPrefix: String = "",
                queryName: String = "", pathPrefix: String = "", methods: String = "", projectOnly: Bool = true, confirmVisible: Bool = false) {
        self.mode = mode
        self.name = name
        self.destination = destination
        self.headerName = headerName
        self.headerPrefix = headerPrefix
        self.queryName = queryName
        self.pathPrefix = pathPrefix
        self.methods = methods
        self.projectOnly = projectOnly
        self.confirmVisible = confirmVisible
    }
}

/// An app-level approval card.
public struct AppApproval: Hashable, Sendable, Codable {
    public enum Action: String, Hashable, Sendable, Codable {
        /// The first agent-created scheduled task in a project.
        case schedule
        /// An HTML visual wants to load from network hosts.
        case network
        /// A saved secret goes to one exact command (label, project, variable, command, network and write access shown).
        case secretCommand
        /// An agent asks to babysit a merge request (first time per project; wakes the thread on GitLab events).
        case gitlabBabysit
        /// An agent asks to change something on GitLab (host, project, MR, SHA and the exact payload shown).
        case gitlabWrite
        /// An agent restarts one of the project's service containers (the first time per project).
        case serviceRestart
        /// Git parity: an agent asks to push its branch (remote, branch, commits shown; host git with the token).
        case gitPush
        /// Git parity: an agent asks to force-push (always its own card; never "Always").
        case gitForcePush
    }

    public var action: Action
    /// "Create a scheduled task", "Let a visual load from the network".
    public var title: String
    /// What exactly would happen (schedule summary, host list).
    public var detail: String
    /// The project directory (schedules) or the hosts (network) an "always" covers.
    public var scope: String
    /// The schedule ID or the tool call part ID the decision applies to.
    public var subjectID: String
    public var allowsAlways: Bool
    /// The exact content the card shows (a schedule's definition digest). Approving applies only if the subject still
    /// has this content; a card without one (written by an older version) cannot approve anything.
    public var digest: String?

    public init(action: Action, title: String, detail: String, scope: String, subjectID: String, allowsAlways: Bool = true, digest: String? = nil) {
        self.action = action
        self.title = title
        self.detail = detail
        self.scope = scope
        self.subjectID = subjectID
        self.allowsAlways = allowsAlways
        self.digest = digest
    }
}

/// The user's answer to an app request. A secret value travels only inside `SecretValue`, which never prints.
public enum AppRequestResponse: Sendable {
    case saveSecret(SecretValue)
    /// Secret manager: save with the mode and binding chosen on the card.
    case saveManagedSecret(SecretValue, SecretChoice)
    /// Use the value already stored under the same label.
    case useSavedSecret
    case approve(always: Bool)
    case decline
}

/// A secret value in memory. `description` is redacted so it cannot reach logs or string interpolation by accident.
public struct SecretValue: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let utf8: Data

    public init(_ string: String) { utf8 = Data(string.utf8) }
    public init(data: Data) { utf8 = data }

    public var isEmpty: Bool { utf8.isEmpty }
    public var description: String { "<secret>" }
    public var debugDescription: String { "<secret>" }
}
