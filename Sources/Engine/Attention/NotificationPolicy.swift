import BelloCore
import Foundation

/// What the user wants notifications for (Settings ▸ Notifications).
public struct NotificationSettings: Hashable, Sendable, Codable {
    public enum Mode: String, CaseIterable, Hashable, Sendable, Codable {
        /// Blockers and completions.
        case all
        /// Approvals, questions and failures only.
        case blockersOnly
        case none

        public var title: String {
            switch self {
            case .all: "Blockers and completions"
            case .blockersOnly: "Only when an agent is blocked or fails"
            case .none: "Off"
            }
        }
    }

    public var mode: Mode
    public var playsSound: Bool
    /// Project directories whose threads never notify.
    public var mutedProjects: Set<String>
    /// Show the "Needs You" list in the menu bar.
    public var showsMenuBarItem: Bool

    public init(mode: Mode = .all, playsSound: Bool = true, mutedProjects: Set<String> = [], showsMenuBarItem: Bool = false) {
        self.mode = mode
        self.playsSound = playsSound
        self.mutedProjects = mutedProjects
        self.showsMenuBarItem = showsMenuBarItem
    }
}

/// One notification to post.
public struct NotificationRequest: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case approval, question, failure, completion
        /// Several threads at once (a burst): one summary instead of a banner each.
        case summary

        public var isBlocker: Bool { self != .completion && self != .summary }
    }

    public var kind: Kind
    public var sessionID: SessionID
    public var projectID: ProjectID
    /// Stable per (thread, status, since), so a repost replaces instead of stacking.
    public var identifier: String
    /// Threads in a summary.
    public var count: Int = 1
}

/// Decides which attention changes become notifications. Pure apart from its memory of what it has already posted;
/// tested directly (AGENTS.md: never per token, never twice for one event).
///
/// Rules: a notification is a *new* entry in the "Needs you" list (approval, question, failure, or a completion that
/// was not seen), identified by thread, status and when it began, posted once. Blockers notify unless that thread is
/// on screen in the key window of the active app; completions notify only while the app is not active. The mode,
/// per-project mute and snooze (snoozed threads leave the list unless blocked) filter them. More than `burstLimit`
/// at once become one summary. The first evaluation only learns the current list (no notifications at launch).
public struct NotificationPolicy: Sendable {
    public struct Context: Sendable {
        public var appIsActive: Bool
        /// The thread shown in the key window, when the app is active.
        public var frontmostThread: SessionID?
        public var settings: NotificationSettings
        /// Project directory for a project ID (for per-project mute).
        public var projectDirectory: @Sendable (ProjectID) -> String?

        public init(
            appIsActive: Bool, frontmostThread: SessionID?, settings: NotificationSettings,
            projectDirectory: @escaping @Sendable (ProjectID) -> String? = { _ in nil }
        ) {
            self.appIsActive = appIsActive
            self.frontmostThread = frontmostThread
            self.settings = settings
            self.projectDirectory = projectDirectory
        }
    }

    public static let burstLimit = 3
    public static let memoryLimit = 1_000

    private var known: Set<String> = []
    private var knownOrder: [String] = []
    private var primed = false

    public init() {}

    public static func identifier(for item: SessionAttention) -> String {
        "\(item.sessionID.rawValue)|\(item.status.rawValue)|\(Int64(item.since.milliseconds))"
    }

    public static func kind(for status: SessionStatus) -> NotificationRequest.Kind? {
        switch status {
        case .awaitingApproval: .approval
        case .awaitingAnswer: .question
        case .failed: .failure
        case .finishedUnread: .completion
        default: nil
        }
    }

    /// The notifications for a new attention summary.
    public mutating func evaluate(_ summary: AttentionSummary, context: Context) -> [NotificationRequest] {
        var fresh: [SessionAttention] = []
        for item in summary.items {
            let id = Self.identifier(for: item)
            guard !known.contains(id) else { continue }
            remember(id)
            fresh.append(item)
        }
        guard primed else {
            primed = true
            return []
        }
        let settings = context.settings
        guard settings.mode != .none else { return [] }
        let requests: [NotificationRequest] = fresh.compactMap { item in
            guard let kind = Self.kind(for: item.status) else { return nil }
            if kind == .completion, settings.mode == .blockersOnly { return nil }
            if let directory = context.projectDirectory(item.projectID), settings.mutedProjects.contains(directory) { return nil }
            if kind.isBlocker {
                if context.appIsActive, context.frontmostThread == item.sessionID { return nil }
            } else if context.appIsActive {
                return nil
            }
            return NotificationRequest(kind: kind, sessionID: item.sessionID, projectID: item.projectID, identifier: Self.identifier(for: item))
        }
        guard requests.count > Self.burstLimit else { return requests }
        let first = requests[0]
        return [
            NotificationRequest(
                kind: .summary, sessionID: first.sessionID, projectID: first.projectID,
                identifier: "summary|\(first.identifier)", count: requests.count),
        ]
    }

    private mutating func remember(_ id: String) {
        known.insert(id)
        knownOrder.append(id)
        if knownOrder.count > Self.memoryLimit {
            let drop = knownOrder.prefix(knownOrder.count - Self.memoryLimit)
            for old in drop { known.remove(old) }
            knownOrder.removeFirst(drop.count)
        }
    }
}

/// When a notification may offer "Allow Once" without opening the app: the same request the card would show, one
/// resource, short enough to read in full, never "Always". Anything else offers Open only. Pure.
public enum NotificationActionSafety {
    public static let maximumOperationLength = 120

    /// The text the notification shows for a permission ("Run: swift build"), and whether Allow Once is offered.
    public static func describe(_ request: PermissionRequest) -> (text: String, allowsInlineApproval: Bool) {
        let verb: String = switch request.action {
        case "bash", "shell": "Run"
        case "edit", "write", "patch": "Edit"
        case "webfetch": "Fetch"
        case "read": "Read"
        default: request.action.capitalized
        }
        let resource = request.resources.first ?? ""
        let full = resource.isEmpty ? verb : "\(verb): \(resource)"
        let fits = request.resources.count <= 1 && full.count <= maximumOperationLength && !resource.contains("\n")
        let text = fits ? full : String(full.prefix(maximumOperationLength - 1)) + "…"
        return (text, fits)
    }
}
