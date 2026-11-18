import Foundation

/// A model choice: `providerID` plus the provider's `modelID`, with an optional variant (reasoning effort and so on).
public struct ModelSelection: Hashable, Sendable, Codable, CustomStringConvertible {
    public var providerID: String
    public var modelID: String
    public var variant: String?

    public init(providerID: String, modelID: String, variant: String? = nil) {
        self.providerID = providerID
        self.modelID = modelID
        self.variant = variant
    }

    public var description: String { "\(providerID)/\(modelID)" + (variant.map { ":\($0)" } ?? "") }
}

/// Token counts and cost (USD). Session values are cumulative; message values are per step.
public struct Usage: Hashable, Sendable, Codable {
    public var cost: Double
    public var inputTokens: Double
    public var outputTokens: Double
    public var reasoningTokens: Double
    public var cacheReadTokens: Double
    public var cacheWriteTokens: Double

    public init(
        cost: Double = 0, inputTokens: Double = 0, outputTokens: Double = 0, reasoningTokens: Double = 0,
        cacheReadTokens: Double = 0, cacheWriteTokens: Double = 0
    ) {
        self.cost = cost
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    public static let zero = Usage()

    /// Tokens that occupy the context window: input plus cache reads.
    public var contextTokens: Double { inputTokens + cacheReadTokens }
}

/// A server error, reduced to what is safe to show and store (never response bodies).
public struct ErrorInfo: Hashable, Sendable, Codable, CustomStringConvertible {
    /// opencode's error type, such as `provider`, `aborted`, `permission`.
    public var type: String
    public var message: String
    public var status: Int?

    public init(type: String, message: String, status: Int? = nil) {
        self.type = type
        self.message = message
        self.status = status
    }

    public var description: String { "\(type): \(message)" }
}

/// A project: a repository (or plain directory) opencode knows. opencode creates projects implicitly the first time a
/// directory is used; BelloCode's own list of added folders is `ProjectEntry`.
public struct Project: Hashable, Sendable, Codable, Identifiable {
    public var id: ProjectID
    /// The canonical directory (repository root).
    public var directory: String
    public var name: String?
    /// `git` or nil.
    public var vcs: String?
    public var iconColor: String?
    public var created: Timestamp
    public var updated: Timestamp

    public init(
        id: ProjectID, directory: String, name: String? = nil, vcs: String? = nil, iconColor: String? = nil,
        created: Timestamp, updated: Timestamp
    ) {
        self.id = id
        self.directory = directory
        self.name = name
        self.vcs = vcs
        self.iconColor = iconColor
        self.created = created
        self.updated = updated
    }

    /// `name`, else the directory's last path component.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return (directory as NSString).lastPathComponent
    }
}

/// BelloCode's own registry of projects the user added, with ordering and flags opencode does not store. Keyed by
/// directory, because a folder has no opencode project ID until the server first uses it.
public struct ProjectEntry: Hashable, Sendable, Codable, Identifiable {
    public var directory: String
    public var projectID: ProjectID?
    public var sortOrder: Int
    public var pinned: Bool
    /// Hidden from the sidebar; opencode data is untouched.
    public var archived: Bool
    public var added: Timestamp

    public init(
        directory: String, projectID: ProjectID? = nil, sortOrder: Int, pinned: Bool = false, archived: Bool = false,
        added: Timestamp
    ) {
        self.directory = directory
        self.projectID = projectID
        self.sortOrder = sortOrder
        self.pinned = pinned
        self.archived = archived
        self.added = added
    }

    public var id: String { directory }
}

/// How a session's turn ended.
public enum SessionOutcome: String, Hashable, Sendable, Codable {
    case succeeded, failed, interrupted
}

/// BelloCode's permission modes, mapped to opencode session permission rules by the Engine.
public enum PermissionMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// Ask before edits and shell commands.
    case ask
    /// Allow edits; ask before shell commands.
    case autoEdit
    /// T3-style Auto (docs/features/auto-mode.md): every request goes to BelloCode's policy; routine work runs, risky
    /// work asks, the rest is reviewed by an isolated model. Never replies "always".
    case auto
    /// Allow everything.
    case fullAccess
}

/// A session (a "thread" in the UI). Child sessions (sub-agents) have a `parentID`.
public struct Session: Hashable, Sendable, Codable, Identifiable {
    public var id: SessionID
    public var projectID: ProjectID
    public var parentID: SessionID?
    /// The session this one was forked from, if any.
    public var forkedFrom: SessionID?
    public var title: String?
    /// The directory the session runs in (the project root or a worktree).
    public var directory: String
    /// Path below the project root, when the session is scoped to one.
    public var subpath: String?
    public var agent: String?
    public var model: ModelSelection?
    public var permissionMode: PermissionMode?
    public var created: Timestamp
    public var updated: Timestamp
    /// Start of the current or last execution.
    public var busySince: Timestamp?
    /// End of the last execution.
    public var idleAt: Timestamp?
    /// The last idle transition the user has seen (opencode's own unread basis).
    public var viewedAt: Timestamp?
    public var archivedAt: Timestamp?
    public var outcome: SessionOutcome?
    /// The error of the last failed execution.
    public var lastError: ErrorInfo?
    public var usage: Usage
    /// Client-owned free-form metadata, as JSON text.
    public var metadata: RawJSON?

    public init(
        id: SessionID, projectID: ProjectID, parentID: SessionID? = nil, forkedFrom: SessionID? = nil,
        title: String? = nil, directory: String, subpath: String? = nil, agent: String? = nil,
        model: ModelSelection? = nil, permissionMode: PermissionMode? = nil, created: Timestamp, updated: Timestamp,
        busySince: Timestamp? = nil, idleAt: Timestamp? = nil, viewedAt: Timestamp? = nil,
        archivedAt: Timestamp? = nil, outcome: SessionOutcome? = nil, lastError: ErrorInfo? = nil,
        usage: Usage = .zero, metadata: RawJSON? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.parentID = parentID
        self.forkedFrom = forkedFrom
        self.title = title
        self.directory = directory
        self.subpath = subpath
        self.agent = agent
        self.model = model
        self.permissionMode = permissionMode
        self.created = created
        self.updated = updated
        self.busySince = busySince
        self.idleAt = idleAt
        self.viewedAt = viewedAt
        self.archivedAt = archivedAt
        self.outcome = outcome
        self.lastError = lastError
        self.usage = usage
        self.metadata = metadata
    }

    /// An execution started and has not ended.
    public var isRunning: Bool {
        guard let busySince else { return false }
        guard let idleAt else { return true }
        return busySince > idleAt
    }

    public var isArchived: Bool { archivedAt != nil }

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "New thread"
    }
}
