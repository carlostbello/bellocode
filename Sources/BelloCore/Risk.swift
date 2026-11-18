import Foundation

// Risk findings, notices and Auto decisions (docs/features/auto-mode.md). Plain values: the Engine's policy produces
// them, tool calls carry them (so the transcript renders them without asking a service), the audit log stores them.
// None of them ever holds file contents, command output or secret values: targets are short labels (a file name, a
// home-relative path, the git subcommand).

/// What a risky action is about. Mandatory categories always escalate in Auto; Full access shows them as notices.
public enum RiskCategory: String, Hashable, Sendable, Codable, CaseIterable {
    /// Reads a secret-looking file or the environment (or would put such content into the context).
    case secretRead
    /// Touches a path outside the project and its worktrees (after canonicalisation).
    case outsidePath
    /// Acts on another project's threads.
    case crossProject
    /// Changes agent, network, secret or isolation configuration.
    case policyChange
    /// A network request that carries credentials or uploads local data.
    case credentialNetwork
    case destructiveGit
    case irreversibleDelete
    /// Publishes or deploys (including `git push`).
    case publish
    /// Installs packages or runs package lifecycle scripts.
    case packageInstall
    /// Adds or enables an MCP server.
    case mcpServer
    /// A command BelloCode cannot analyse (substitution, eval, an inline script, an encoded payload, a parse error).
    case unknownCommand
    /// Targets BelloCode's isolation or credential stores: refused outright.
    case policyViolation

    /// The notice wording ("Read a secret-looking file").
    public var title: String {
        switch self {
        case .secretRead: "Read a secret-looking file"
        case .outsidePath: "Touched a path outside the project"
        case .crossProject: "Acted on another project"
        case .policyChange: "Changed agent or isolation settings"
        case .credentialNetwork: "Network request with credentials"
        case .destructiveGit: "Destructive git"
        case .irreversibleDelete: "Irreversible delete"
        case .publish: "Published or deployed"
        case .packageInstall: "Installed packages"
        case .mcpServer: "Added or enabled an MCP server"
        case .unknownCommand: "Command BelloCode cannot analyse"
        case .policyViolation: "Targets BelloCode's isolation"
        }
    }

    /// The same, as a request ("Reads a secret-looking file"), for approval cards.
    public var asking: String {
        switch self {
        case .secretRead: "Reads a secret-looking file"
        case .outsidePath: "Touches a path outside the project"
        case .crossProject: "Acts on another project"
        case .policyChange: "Changes agent or isolation settings"
        case .credentialNetwork: "Sends credentials or local data over the network"
        case .destructiveGit: "Destructive git"
        case .irreversibleDelete: "Deletes irreversibly"
        case .publish: "Publishes or deploys"
        case .packageInstall: "Installs packages or runs their scripts"
        case .mcpServer: "Adds or enables an MCP server"
        case .unknownCommand: "A command BelloCode cannot analyse"
        case .policyViolation: "Targets BelloCode's isolation"
        }
    }

    /// SF Symbol for notices and audit rows (always shown with text, never colour alone).
    public var symbolName: String {
        switch self {
        case .secretRead: "key"
        case .outsidePath: "folder.badge.questionmark"
        case .crossProject: "arrow.triangle.branch"
        case .policyChange: "gearshape"
        case .credentialNetwork: "network"
        case .destructiveGit, .irreversibleDelete: "exclamationmark.triangle"
        case .publish: "paperplane"
        case .packageInstall: "shippingbox"
        case .mcpServer: "puzzlepiece.extension"
        case .unknownCommand: "questionmark.diamond"
        case .policyViolation: "hand.raised"
        }
    }
}

/// One detected risk: a category and a short target label ("`.env`", "`~/.ssh/id_ed25519`", "`reset --hard`").
public struct RiskFinding: Hashable, Sendable, Codable {
    public var category: RiskCategory
    public var target: String

    public init(_ category: RiskCategory, _ target: String) {
        self.category = category
        self.target = target
    }

    /// "Read a secret-looking file: .env"
    public var noticeText: String { target.isEmpty ? category.title : "\(category.title): \(target)" }
    /// "Reads a secret-looking file: .env"
    public var askingText: String { target.isEmpty ? category.asking : "\(category.asking): \(target)" }
}

/// Where an Auto decision came from.
public enum AutoDecisionSource: String, Hashable, Sendable, Codable {
    /// The deterministic policy (narrow in-project reads and safe edits).
    case policy
    /// The isolated reviewer model.
    case reviewer
    /// A scope the person saved with "Always allow".
    case savedGrant
    /// The person, on an escalation card.
    case person
}

/// An Auto approval attached to the tool call it let through (the transcript's "Auto-approved" chip).
public struct AutoApproval: Hashable, Sendable, Codable {
    public var source: AutoDecisionSource
    /// Stable code (`in_project_edit`, `reviewer_allow`, …).
    public var reasonCode: String
    /// One short line, no content.
    public var explanation: String
    public var model: String?
    public var policyVersion: String
    public var requestID: String
    public var at: Timestamp

    public init(
        source: AutoDecisionSource, reasonCode: String, explanation: String, model: String? = nil, policyVersion: String,
        requestID: String, at: Timestamp
    ) {
        self.source = source
        self.reasonCode = reasonCode
        self.explanation = explanation
        self.model = model
        self.policyVersion = policyVersion
        self.requestID = requestID
        self.at = at
    }
}

/// Risk detected on a tool call (Full access notices) and an Auto approval, carried by `ToolCall.risk`.
public struct ToolRisk: Hashable, Sendable, Codable {
    /// Full access (and opencode-default) notices: what the call did that BelloCode surfaces. Best effort.
    public var notices: [RiskFinding]
    public var autoApproval: AutoApproval?

    public init(notices: [RiskFinding] = [], autoApproval: AutoApproval? = nil) {
        self.notices = notices
        self.autoApproval = autoApproval
    }

    public var isEmpty: Bool { notices.isEmpty && autoApproval == nil }
}

/// Why Auto put a request in front of the person (shown on the approval card; the card is the existing one).
public struct AutoEscalation: Hashable, Sendable, Codable {
    /// Mandatory findings (empty when the reviewer escalated).
    public var findings: [RiskFinding]
    public var source: AutoDecisionSource
    public var reasonCode: String
    public var explanation: String
    public var policyVersion: String

    public init(findings: [RiskFinding], source: AutoDecisionSource, reasonCode: String, explanation: String, policyVersion: String) {
        self.findings = findings
        self.source = source
        self.reasonCode = reasonCode
        self.explanation = explanation
        self.policyVersion = policyVersion
    }

    /// One line for the card: "Auto asks you: Reads a secret-looking file: .env".
    public var summary: String {
        if let first = findings.first {
            let more = findings.count > 1 ? " (+\(findings.count - 1) more)" : ""
            return "Auto asks you: " + first.askingText + more
        }
        return "Auto asks you: " + explanation
    }
}

/// `metadata.bellocode_interrupt` on a thread another thread's agent stopped (Plugin/src/auto.ts `InterruptRecord`).
public struct InterruptRecord: Hashable, Sendable, Codable {
    /// The interrupting thread.
    public var by: String
    public var byTitle: String?
    public var reason: String
    /// Milliseconds since 1970.
    public var at: Double
    /// What was asked ("stop").
    public var requested: String
    /// What happened: `stopped`, `still_running`, `failed`, `not_running`.
    public var actual: String
    /// Queued work waits for the person's Resume.
    public var held: Bool

    public init(by: String, byTitle: String? = nil, reason: String, at: Double, requested: String = "stop", actual: String, held: Bool) {
        self.by = by
        self.byTitle = byTitle
        self.reason = reason
        self.at = at
        self.requested = requested
        self.actual = actual
        self.held = held
    }

    public static let metadataKey = "bellocode_interrupt"

    /// From a session's raw metadata JSON.
    public static func from(metadata: RawJSON?) -> InterruptRecord? {
        guard let data = metadata?.text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = object[metadataKey],
            let encoded = try? JSONSerialization.data(withJSONObject: value)
        else { return nil }
        return try? JSONDecoder().decode(InterruptRecord.self, from: encoded)
    }

    /// "Stopped by “Refactor parser”: it edits the same file"
    public var summary: String {
        let who = byTitle.map { "“\($0)”" } ?? "another thread"
        let state = actual == "stopped" ? "" : actual == "still_running" ? " (still stopping)" : actual == "failed" ? " (the stop failed)" : ""
        return "Stopped by \(who)\(state): \(reason)"
    }
}

/// Folders a developer works across ("code roots", e.g. `~/Documents/Repos`), configured per developer (and optionally
/// by an administrator). Paths inside any of them are in scope for Auto and Full-access notices: no escalation or notice
/// for location alone, and another project inside them is not "cross-project". Secrets and risky actions still count.
/// The default is empty: only the thread's project and its worktrees are in scope. Set `Engine.codeRoots`.
public struct CodeRoots: Hashable, Sendable, Codable {
    /// Absolute or `~/` paths.
    public var directories: [String]

    public init(_ directories: [String] = []) { self.directories = directories }

    public static let none = CodeRoots()
}

/// What another package provides to keep `Engine.codeRoots` current (developer settings, an administrator key).
@MainActor
public protocol CodeRootsProvider: AnyObject {
    var codeRoots: CodeRoots { get }
}
