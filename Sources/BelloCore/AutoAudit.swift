import Foundation

/// One Auto audit record (docs/features/auto-mode.md): what was decided or noticed, by whom, under which policy.
/// Labels and codes only: never file contents, command output, or secret values.
public struct AutoAuditEntry: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// Auto let it run once (policy, reviewer or a saved grant).
        case autoApproved
        /// Auto put it in front of the person.
        case escalated
        /// Auto refused it (a hard deny).
        case denied
        /// A Full-access risk notice (not a decision).
        case notice
        /// Another thread's agent stopped this thread, or this thread stopped another.
        case interrupt
    }

    public var id: String
    public var sessionID: SessionID
    public var projectDirectory: String?
    public var kind: Kind
    public var source: AutoDecisionSource?
    /// opencode's permission action or the tool's name.
    public var action: String
    public var toolCallID: String?
    public var findings: [RiskFinding]
    public var reasonCode: String
    public var explanation: String
    public var model: String?
    public var policyVersion: String
    public var latencyMilliseconds: Int?
    /// For notices: the call had only been attempted (running) or had completed, failed.
    public var state: String?
    public var at: Timestamp

    public init(
        id: String, sessionID: SessionID, projectDirectory: String?, kind: Kind, source: AutoDecisionSource?, action: String,
        toolCallID: String?, findings: [RiskFinding], reasonCode: String, explanation: String, model: String? = nil,
        policyVersion: String, latencyMilliseconds: Int? = nil, state: String? = nil, at: Timestamp
    ) {
        self.id = id
        self.sessionID = sessionID
        self.projectDirectory = projectDirectory
        self.kind = kind
        self.source = source
        self.action = action
        self.toolCallID = toolCallID
        self.findings = findings
        self.reasonCode = reasonCode
        self.explanation = explanation
        self.model = model
        self.policyVersion = policyVersion
        self.latencyMilliseconds = latencyMilliseconds
        self.state = state
        self.at = at
    }

    /// The row's title ("Auto-approved · Edits a file inside the project").
    public var title: String {
        switch kind {
        case .autoApproved: "Auto-approved"
        case .escalated: "Asked you"
        case .denied: "Refused"
        case .notice: "Noticed"
        case .interrupt: "Interrupt"
        }
    }
}
