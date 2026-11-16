import Foundation

// Payloads of `/api/event` frames (`V2Event` in Contracts/opencode-2.3.0/openapi.json). Streaming identity:
// text and reasoning blocks are keyed by (assistantMessageID, ordinal); tool calls by (assistantMessageID, id).
// Deltas are live-only; started/ended/called/success/failed/step/execution events are durable.

public enum EventPayload {
    /// `{ sessionID }`.
    public struct SessionRef: Decodable, Sendable, Hashable {
        public var sessionID: String
    }

    /// `{ sessionID, assistantMessageID }`.
    public struct MessageRef: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var assistantMessageID: String
    }

    /// `session.created`.
    public struct SessionCreated: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var projectID: String
        public var location: LocationRef
        public var parentID: String?
        public var slug: String?
        public var title: String?
        public var agent: String?
        public var model: ModelRef?
        public var version: String?
    }

    /// `session.renamed`.
    public struct SessionRenamed: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var title: String
    }

    /// `session.status`.
    public struct SessionStatusChanged: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var status: SessionStatus
    }

    /// `session.inbox.enqueued`. The prompt text is not decoded here; read it from the message list.
    public struct InboxEnqueued: Decodable, Sendable, Hashable {
        public struct Item: Decodable, Sendable, Hashable {
            /// `user`, `synthetic`, `compaction`, `move`.
            public var type: String
            public var delivery: InboxDelivery?
        }

        public var sessionID: String
        public var inboxID: String
        public var item: Item
    }

    /// `session.inbox.delivered` and `session.inbox.cancelled`.
    public struct InboxRef: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var inboxID: String
    }

    /// `session.execution.failed`.
    public struct ExecutionFailed: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var error: StructuredError
    }

    /// `session.execution.interrupted`.
    public struct ExecutionInterrupted: Decodable, Sendable, Hashable {
        public var sessionID: String
        /// `user`, `shutdown`, `superseded`, `inactivity`.
        public var reason: String
    }

    /// `session.step.started`.
    public struct StepStarted: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var assistantMessageID: String
        public var agent: String
        public var model: ModelRef
        public var snapshot: String?
        public var started: Double?
    }

    /// `session.step.ended`.
    public struct StepEnded: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var assistantMessageID: String
        public var finish: FinishReason
        public var cost: Double?
        public var tokens: TokenUsage?
        public var snapshot: String?
        public var files: [String]?
    }

    /// `session.step.failed`.
    public struct StepFailed: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var assistantMessageID: String
        public var error: StructuredError
    }

    /// `session.text.started`, `session.reasoning.started`.
    public struct BlockStarted: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var assistantMessageID: String
        public var ordinal: Int
    }

    /// `session.text.delta`, `session.reasoning.delta`.
    public struct BlockDelta: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var assistantMessageID: String
        public var ordinal: Int
        public var delta: String
    }

    /// `session.text.ended`, `session.reasoning.ended`: carries the block's full final text.
    public struct BlockEnded: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var assistantMessageID: String
        public var ordinal: Int
        public var text: String
    }

    /// `session.tool.input.started`.
    public struct ToolInputStarted: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var assistantMessageID: String
        public var id: String
        public var name: String
    }

    /// `session.tool.input.delta`.
    public struct ToolInputDelta: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var assistantMessageID: String
        public var id: String
        public var delta: String
    }

    /// `session.tool.input.ended`: the complete raw input text.
    public struct ToolInputEnded: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var assistantMessageID: String
        public var id: String
        public var text: String
    }

    /// `session.tool.called`.
    public struct ToolCalled: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var assistantMessageID: String
        public var id: String
        public var input: JSONValue
        public var executed: Bool
    }

    /// `session.tool.progress`.
    public struct ToolProgress: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var assistantMessageID: String
        public var id: String
        public var metadata: JSONValue?
    }

    /// `session.tool.success`.
    public struct ToolSucceeded: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var assistantMessageID: String
        public var id: String
        public var content: [ToolContent]
        public var metadata: JSONValue?
        public var executed: Bool?
    }

    /// `session.tool.failed`.
    public struct ToolFailed: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var assistantMessageID: String
        public var id: String
        public var error: StructuredError
        public var content: [ToolContent]?
        public var metadata: JSONValue?
        public var executed: Bool?
    }

    /// `session.usage.updated`: cumulative session totals.
    public struct UsageUpdated: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var cost: Double
        public var tokens: TokenUsage
    }

    /// `session.retry.scheduled`.
    public struct RetryScheduled: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var assistantMessageID: String
        public var attempt: Int
        /// Epoch milliseconds of the next attempt.
        public var at: Double
        public var error: StructuredError
    }

    /// `permission.replied`.
    public struct PermissionReplied: Decodable, Sendable, Hashable {
        public var sessionID: String
        public var requestID: String
        public var reply: PermissionDecision
    }

    /// `form.created`.
    public struct FormCreated: Decodable, Sendable, Hashable {
        public var form: FormInfo
    }

    /// `form.replied` and `form.cancelled`.
    public struct FormSettled: Decodable, Sendable, Hashable {
        public var id: String
        public var sessionID: String
    }

    /// `worktree.resolved`.
    public struct WorktreeResolved: Decodable, Sendable, Hashable {
        public var projectID: String
        public var directory: String
        public var previous: String?
    }

    /// `vcs.branch.updated`.
    public struct BranchUpdated: Decodable, Sendable, Hashable {
        public var branch: String?
    }

    /// `shell.created`.
    public struct ShellCreated: Decodable, Sendable, Hashable {
        public struct Info: Decodable, Sendable, Hashable {
            public var id: String
            public var status: String
        }

        public var info: Info
    }

    /// `shell.exited`.
    public struct ShellExited: Decodable, Sendable, Hashable {
        public var id: String
        public var exit: FlexibleNumber?
        public var status: String
    }
}

/// `SessionStatus`.
public enum SessionStatus: Decodable, Sendable, Hashable {
    case idle
    case busy
    /// `next` is epoch milliseconds of the next attempt.
    case retry(attempt: Int, message: String, next: Double)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey { case type, attempt, message, next }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "idle": self = .idle
        case "busy": self = .busy
        case "retry":
            self = .retry(
                attempt: try container.decode(Int.self, forKey: .attempt),
                message: try container.decode(String.self, forKey: .message),
                next: try container.decode(Double.self, forKey: .next)
            )
        default: self = .unknown(type: type)
        }
    }
}
