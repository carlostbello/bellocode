import BelloCore
import Foundation

// The transcript's row model: immutable `Sendable` values derived from BelloCore messages (RowBuilder.swift).
//
// Granularity (docs/features/transcript.md): one row per user message, per visible assistant part (text, reasoning,
// file, sub-agent, todo list), per run of consecutive tool calls (a work group, which may span the several assistant
// messages of one turn), per error and per lifecycle event. Row identity is always derived from a server ID (message
// or part), never an index. A huge text part stays one row but is laid out per Markdown block, with monospaced blocks
// measured arithmetically and drawn line by line, so its cost is bounded by what is visible.

/// A row's stable identity, derived from the server's message or part ID.
public struct RowID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static func message(_ id: MessageID) -> RowID { RowID("m:" + id.rawValue) }
    public static func part(_ id: PartID) -> RowID { RowID("p:" + id.rawValue) }
    /// A work group is named after its first tool call, which never changes as the group grows.
    public static func group(_ first: PartID) -> RowID { RowID("g:" + first.rawValue) }
    public static func error(_ id: MessageID) -> RowID { RowID("e:" + id.rawValue) }
    public static func lifecycle(_ id: MessageID) -> RowID { RowID("l:" + id.rawValue) }
    public static func working(_ turn: MessageID) -> RowID { RowID("w:" + turn.rawValue) }
    /// The risk notice or Auto chip of a tool call (derived from the call's part ID).
    public static func risk(_ part: PartID) -> RowID { RowID("r:" + part.rawValue) }

    public static func < (lhs: RowID, rhs: RowID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

public enum RowRole: Sendable, Equatable {
    case user
    case assistant
    case system
}

/// One transcript row.
public struct TranscriptRow: Sendable, Equatable, Identifiable {
    public var id: RowID
    /// The message the row comes from (the first one for a work group spanning messages).
    public var messageID: MessageID
    /// The user message that started this row's turn (nil before the first prompt).
    public var turnID: MessageID?
    public var role: RowRole
    public var content: RowContent
    /// Changes whenever the row's content changes; part of the layout cache key. Derived from message revisions.
    public var version: Int
    public var created: Timestamp

    public init(
        id: RowID, messageID: MessageID, turnID: MessageID?, role: RowRole, content: RowContent, version: Int,
        created: Timestamp
    ) {
        self.id = id
        self.messageID = messageID
        self.turnID = turnID
        self.role = role
        self.content = content
        self.version = version
        self.created = created
    }

    /// Whether the row still changes (streaming text, a running tool).
    public var isLive: Bool {
        switch content {
        case .markdown(_, let streaming): streaming
        case .reasoning(let reasoning): reasoning.isStreaming
        case .work(let group): group.items.contains { $0.status.isActive }
        case .working: true
        default: false
        }
    }

    /// The row is a failure the user should be able to jump to.
    public var isFailure: Bool {
        switch content {
        case .error: true
        case .work(let group): group.items.contains { if case .failed = $0.status { true } else { false } }
        case .subagent(let card): card.status == .failed
        default: false
        }
    }
}

public enum RowContent: Sendable, Equatable {
    case user(UserRowContent)
    /// Assistant Markdown. `isStreaming`: the part is still receiving text.
    case markdown(text: String, isStreaming: Bool)
    case reasoning(ReasoningContent)
    /// One or more consecutive tool calls (a work group).
    case work(WorkGroupContent)
    case todo(TodoListContent)
    case file(FileChip)
    case subagent(SubagentCardContent)
    /// An HTML visual reply (`html_render`), shown as a snapshot image; the host may lay a live view over it.
    case visual(VisualCardContent)
    case error(ErrorBannerContent)
    case lifecycle(LifecycleContent)
    /// The agent is working and nothing visible is streaming yet.
    case working
    /// A part or message kind this build does not render. Never crashes; shows the type.
    case unknown(type: String)
}

// MARK: - Row payloads

public struct UserRowContent: Sendable, Equatable {
    public var text: String
    public var attachments: [FileChip]
    /// `@agent` names the prompt addressed.
    public var agents: [String]
    /// The prompt is shown locally and the server has not acknowledged it yet.
    public var isSending: Bool

    public init(text: String, attachments: [FileChip] = [], agents: [String] = [], isSending: Bool = false) {
        self.text = text
        self.attachments = attachments
        self.agents = agents
        self.isSending = isSending
    }
}

public struct FileChip: Sendable, Equatable {
    public var uri: String
    public var mime: String
    public var name: String

    public init(uri: String, mime: String, name: String) {
        self.uri = uri
        self.mime = mime
        self.name = name
    }

    public var isImage: Bool { mime.hasPrefix("image/") }
}

public struct ReasoningContent: Sendable, Equatable {
    public var text: String
    public var isStreaming: Bool
    /// Seconds spent thinking, when the transcript saw it happen.
    public var duration: TimeInterval?

    public init(text: String, isStreaming: Bool, duration: TimeInterval? = nil) {
        self.text = text
        self.isStreaming = isStreaming
        self.duration = duration
    }
}

public enum ToolCategory: String, Sendable, Equatable, CaseIterable {
    case read, edit, command, search, fetch, other
}

public enum ToolItemStatus: Sendable, Equatable {
    case preparing
    case running
    case done
    case failed(String)
    case unknown(String)

    public var isActive: Bool {
        switch self {
        case .preparing, .running: true
        default: false
        }
    }

    public var isSuccess: Bool { self == .done }

    /// Words shown beside the glyph (status is never colour only).
    public var label: String {
        switch self {
        case .preparing: "Preparing"
        case .running: "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .unknown(let raw): raw.capitalized
        }
    }

    public var glyph: String {
        switch self {
        case .preparing, .running: "◌"
        case .done: "✓"
        case .failed: "✕"
        case .unknown: "?"
        }
    }
}

/// One tool call, summarised for a compact line: verb, target, status, duration.
public struct ToolItem: Sendable, Equatable {
    /// The tool call's part ID (stable).
    public var id: PartID
    public var name: String
    public var category: ToolCategory
    /// Past-tense verb when finished, progressive while running ("Read", "Reading").
    public var verb: String
    public var target: String
    public var status: ToolItemStatus
    public var duration: TimeInterval?
    /// Readable input: the command for shells, a diff for edits, otherwise the JSON input.
    public var input: String
    public var inputIsDiff: Bool
    public var output: String
    /// Output is arriving while the tool runs (follow its end).
    public var outputIsLive: Bool

    public init(
        id: PartID, name: String, category: ToolCategory, verb: String, target: String, status: ToolItemStatus,
        duration: TimeInterval? = nil, input: String = "", inputIsDiff: Bool = false, output: String = "",
        outputIsLive: Bool = false
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.verb = verb
        self.target = target
        self.status = status
        self.duration = duration
        self.input = input
        self.inputIsDiff = inputIsDiff
        self.output = output
        self.outputIsLive = outputIsLive
    }

    /// "Read Sources/App.swift".
    public var title: String { target.isEmpty ? verb : verb + " " + target }
}

public struct WorkGroupContent: Sendable, Equatable {
    public var items: [ToolItem]

    public init(items: [ToolItem]) { self.items = items }

    /// "Read 4 files, ran 2 commands" for the successful calls.
    public var summary: String { WorkSummary.text(for: items.filter(\.status.isSuccess)) }

    /// Wall time from the first call's start to the last call's end, when known.
    public var duration: TimeInterval? {
        let durations = items.compactMap(\.duration)
        return durations.isEmpty ? nil : durations.reduce(0, +)
    }

    /// The group collapses only when it has at least two finished, successful calls.
    public var isCollapsible: Bool { items.filter(\.status.isSuccess).count >= 2 }
}

public struct TodoItem: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case pending, inProgress = "in_progress", completed, cancelled
    }

    public var text: String
    public var state: State

    public init(text: String, state: State) {
        self.text = text
        self.state = state
    }
}

public struct TodoListContent: Sendable, Equatable {
    public var items: [TodoItem]
    public init(items: [TodoItem]) { self.items = items }
}

public enum SubagentStatus: Sendable, Equatable {
    case running, done, failed, unknown
    /// The child's own run ended while its children still work (live state, docs/features/orchestration.md).
    case waitingOnChildren
    /// The child needs an approval or an answer.
    case needsYou
    case stopped
    public var label: String {
        switch self {
        case .running: "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .unknown: "Unknown"
        case .waitingOnChildren: "Waiting on children"
        case .needsYou: "Needs you"
        case .stopped: "Stopped"
        }
    }
}

public struct SubagentCardContent: Sendable, Equatable {
    public var title: String
    public var agent: String?
    public var status: SubagentStatus
    public var childSessionID: SessionID?
    public var duration: TimeInterval?

    public init(title: String, agent: String?, status: SubagentStatus, childSessionID: SessionID?, duration: TimeInterval?) {
        self.title = title
        self.agent = agent
        self.status = status
        self.childSessionID = childSessionID
        self.duration = duration
    }
}

/// An HTML visual (docs/features/orchestration-extras.md). The image comes from the controller's image loader through
/// `imageSource(dark:)` (`bellocode-visual://<id>?scheme=light|dark`), so off-screen visuals cost a cached bitmap and
/// the transcript stays virtualised. Actions are `bellocode-visual-action://<verb>/<id>` URLs given to `openURL`.
public struct VisualCardContent: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case rendering
        case ready
        case failed(String)
    }

    public var visualID: String
    public var title: String
    /// CSS pixels of content height (capped by the layout).
    public var height: Double
    public var status: Status
    /// "Network blocked: waiting for approval", or nil.
    public var note: String?

    public init(visualID: String, title: String, height: Double, status: Status, note: String? = nil) {
        self.visualID = visualID
        self.title = title
        self.height = height
        self.status = status
        self.note = note
    }

    public static let scheme = "bellocode-visual"
    public static let actionScheme = "bellocode-visual-action"
    public static let maxHeight: Double = 480

    public func imageSource(dark: Bool) -> String { "\(Self.scheme)://\(visualID)?scheme=\(dark ? "dark" : "light")" }
    public func actionURL(_ verb: String) -> String { "\(Self.actionScheme)://\(verb)/\(visualID)" }
    public var displayHeight: Double { min(Self.maxHeight, max(60, height)) }
}

public struct ErrorBannerContent: Sendable, Equatable {
    public var title: String
    public var message: String
    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

public struct LifecycleContent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case interrupted, compacted, modelChanged, agentChanged, note
        /// A Full-access risk notice on the tool call above it (docs/features/auto-mode.md). Not a blocking approval.
        case risk
        /// Auto let the call above run once (chip with the reason).
        case autoApproved
        /// One thread's agent stopped another (shown in both threads).
        case interruption
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

// MARK: - Summaries

enum WorkSummary {
    /// Counts by category, in a fixed order: "Read 4 files, edited a file, ran 2 commands".
    static func text(for items: [ToolItem]) -> String {
        guard !items.isEmpty else { return "" }
        var counts: [ToolCategory: Int] = [:]
        for item in items { counts[item.category, default: 0] += 1 }
        var parts: [String] = []
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? one : "\(n) \(many)" }
        for category in ToolCategory.allCases {
            guard let n = counts[category] else { continue }
            let phrase: String =
                switch category {
                case .read: "read " + count(n, "a file", "files")
                case .edit: "edited " + count(n, "a file", "files")
                case .command: "ran " + count(n, "a command", "commands")
                case .search: "searched " + (n == 1 ? "once" : "\(n) times")
                case .fetch: "fetched " + count(n, "a page", "pages")
                case .other: "used " + count(n, "a tool", "tools")
                }
            parts.append(phrase)
        }
        let joined = parts.joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}

/// Formats durations compactly: "0.4 s", "3 s", "1 m 5 s".
public enum DurationText {
    public static func format(_ seconds: TimeInterval) -> String {
        if seconds < 0.05 { return "0 s" }
        if seconds < 10 { return String(format: "%.1f s", seconds) }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        return rest == 0 ? "\(minutes) m" : "\(minutes) m \(rest) s"
    }
}
