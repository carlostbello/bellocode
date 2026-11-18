import Foundation

/// A decoded `/api/event` frame.
public struct OpenCodeEventEnvelope: Sendable {
    /// `durable`: present on events that are also written to the session's event log.
    public struct Durable: Decodable, Sendable, Hashable {
        public var aggregateID: String
        public var seq: Int
        public var version: Int?
    }

    /// Server event id (`evt_…`). Not a replay cursor: the stream is volatile.
    public let id: String?
    public let type: String
    /// Epoch milliseconds.
    public let created: Double?
    /// `location.directory`, when the event is scoped to one.
    public let directory: String?
    public let durable: Durable?
    public let event: OpenCodeEvent

    /// The session this event belongs to, if any.
    public var sessionID: String? { event.sessionID }
}

/// Events BelloCode handles, with an `.unknown` fallback so a newer server never breaks the stream. A frame whose
/// type is known but whose payload does not match the contract also decodes as `.unknown`.
public enum OpenCodeEvent: Sendable {
    // Server and location
    case serverConnected
    case locationShutdown
    case projectUpdated(Project)
    case worktreeResolved(EventPayload.WorktreeResolved)
    case branchUpdated(EventPayload.BranchUpdated)
    /// A catalog or configuration changed (`provider.updated`, `model.updated`, `agent.updated`, …): refetch it.
    /// The payload is not decoded; for `credential.*` it must never be.
    case resourcesChanged(type: String)

    // Session lifecycle
    case sessionCreated(EventPayload.SessionCreated)
    case sessionRenamed(EventPayload.SessionRenamed)
    case sessionArchived(EventPayload.SessionRef)
    case sessionUnarchived(EventPayload.SessionRef)
    case sessionDeleted(EventPayload.SessionRef)
    case sessionStatus(EventPayload.SessionStatusChanged)
    case sessionIdle(EventPayload.SessionRef)
    case sessionInstructionsUpdated(EventPayload.SessionRef)
    case usageUpdated(EventPayload.UsageUpdated)

    // Inbox and execution (turn boundaries)
    case inboxEnqueued(EventPayload.InboxEnqueued)
    case inboxDelivered(EventPayload.InboxRef)
    case inboxCancelled(EventPayload.InboxRef)
    case executionStarted(EventPayload.SessionRef)
    case executionSucceeded(EventPayload.SessionRef)
    case executionFailed(EventPayload.ExecutionFailed)
    case executionInterrupted(EventPayload.ExecutionInterrupted)
    case retryScheduled(EventPayload.RetryScheduled)

    // Steps and streaming content
    case stepStarted(EventPayload.StepStarted)
    case stepFirstToken(EventPayload.MessageRef)
    case stepStreamed(EventPayload.MessageRef)
    case stepEnded(EventPayload.StepEnded)
    case stepFailed(EventPayload.StepFailed)
    case textStarted(EventPayload.BlockStarted)
    case textDelta(EventPayload.BlockDelta)
    case textEnded(EventPayload.BlockEnded)
    case reasoningStarted(EventPayload.BlockStarted)
    case reasoningDelta(EventPayload.BlockDelta)
    case reasoningEnded(EventPayload.BlockEnded)

    // Tools
    case toolInputStarted(EventPayload.ToolInputStarted)
    case toolInputDelta(EventPayload.ToolInputDelta)
    case toolInputEnded(EventPayload.ToolInputEnded)
    case toolCalled(EventPayload.ToolCalled)
    case toolProgress(EventPayload.ToolProgress)
    case toolSucceeded(EventPayload.ToolSucceeded)
    case toolFailed(EventPayload.ToolFailed)
    case shellCreated(EventPayload.ShellCreated)
    case shellExited(EventPayload.ShellExited)

    // Blocking requests
    case permissionAsked(PermissionRequest)
    case permissionReplied(EventPayload.PermissionReplied)
    case formCreated(FormInfo)
    case formReplied(EventPayload.FormSettled)
    case formCancelled(EventPayload.FormSettled)

    /// Any other frame: the `type` and the frame's raw JSON bytes.
    case unknown(type: String, rawJSON: Data)

    /// Event types whose payload is ignored and which only signal "refetch this catalog".
    static let resourceTypes: Set<String> = [
        "integration.updated", "provider.updated", "model.updated", "agent.updated", "command.updated",
        "skill.updated", "websearch.updated", "reference.updated", "plugin.updated", "config.updated",
        "models-dev.refreshed", "credential.updated", "credential.switched", "mcp.status.changed",
        "mcp.resources.changed", "artifact.updated",
    ]

    public var sessionID: String? {
        switch self {
        case .serverConnected, .locationShutdown, .projectUpdated, .worktreeResolved, .branchUpdated,
            .resourcesChanged, .shellCreated, .shellExited, .unknown:
            nil
        case .sessionCreated(let p): p.sessionID
        case .sessionRenamed(let p): p.sessionID
        case .sessionArchived(let p), .sessionUnarchived(let p), .sessionDeleted(let p), .sessionIdle(let p),
            .sessionInstructionsUpdated(let p), .executionStarted(let p), .executionSucceeded(let p):
            p.sessionID
        case .sessionStatus(let p): p.sessionID
        case .usageUpdated(let p): p.sessionID
        case .inboxEnqueued(let p): p.sessionID
        case .inboxDelivered(let p), .inboxCancelled(let p): p.sessionID
        case .executionFailed(let p): p.sessionID
        case .executionInterrupted(let p): p.sessionID
        case .retryScheduled(let p): p.sessionID
        case .stepStarted(let p): p.sessionID
        case .stepFirstToken(let p), .stepStreamed(let p): p.sessionID
        case .stepEnded(let p): p.sessionID
        case .stepFailed(let p): p.sessionID
        case .textStarted(let p), .reasoningStarted(let p): p.sessionID
        case .textDelta(let p), .reasoningDelta(let p): p.sessionID
        case .textEnded(let p), .reasoningEnded(let p): p.sessionID
        case .toolInputStarted(let p): p.sessionID
        case .toolInputDelta(let p): p.sessionID
        case .toolInputEnded(let p): p.sessionID
        case .toolCalled(let p): p.sessionID
        case .toolProgress(let p): p.sessionID
        case .toolSucceeded(let p): p.sessionID
        case .toolFailed(let p): p.sessionID
        case .permissionAsked(let p): p.sessionID
        case .permissionReplied(let p): p.sessionID
        case .formCreated(let p): p.sessionID
        case .formReplied(let p), .formCancelled(let p): p.sessionID
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { true } else { false }
    }
}

/// Decodes `/api/event` frame data into envelopes. Never throws: anything it cannot interpret becomes `.unknown`.
public struct OpenCodeEventDecoder: Sendable {
    public init() {}

    private struct Head: Decodable {
        struct Location: Decodable { let directory: String? }
        let id: String?
        let type: String
        let created: Double?
        let location: Location?
        let durable: OpenCodeEventEnvelope.Durable?
    }

    private struct Body<P: Decodable>: Decodable { let data: P }

    public func decode(_ data: Data) -> OpenCodeEventEnvelope {
        let decoder = JSONDecoder()
        guard let head = try? decoder.decode(Head.self, from: data) else {
            return OpenCodeEventEnvelope(
                id: nil, type: "", created: nil, directory: nil, durable: nil, event: .unknown(type: "", rawJSON: data)
            )
        }
        let event: OpenCodeEvent
        do {
            event = try decodeEvent(type: head.type, data: data, decoder: decoder)
        } catch {
            event = .unknown(type: head.type, rawJSON: data)
        }
        return OpenCodeEventEnvelope(
            id: head.id, type: head.type, created: head.created, directory: head.location?.directory,
            durable: head.durable, event: event
        )
    }

    private func decodeEvent(type: String, data: Data, decoder: JSONDecoder) throws -> OpenCodeEvent {
        func payload<P: Decodable>(_: P.Type = P.self) throws -> P {
            try decoder.decode(Body<P>.self, from: data).data
        }
        if OpenCodeEvent.resourceTypes.contains(type) { return .resourcesChanged(type: type) }
        switch type {
        case "server.connected": return .serverConnected
        case "location.shutdown": return .locationShutdown
        case "project.updated": return .projectUpdated(try payload())
        case "worktree.resolved": return .worktreeResolved(try payload())
        case "vcs.branch.updated": return .branchUpdated(try payload())

        case "session.created": return .sessionCreated(try payload())
        case "session.renamed": return .sessionRenamed(try payload())
        case "session.archived": return .sessionArchived(try payload())
        case "session.unarchived": return .sessionUnarchived(try payload())
        case "session.deleted": return .sessionDeleted(try payload())
        case "session.status": return .sessionStatus(try payload())
        case "session.idle": return .sessionIdle(try payload())
        case "session.instructions.updated": return .sessionInstructionsUpdated(try payload())
        case "session.usage.updated": return .usageUpdated(try payload())

        case "session.inbox.enqueued": return .inboxEnqueued(try payload())
        case "session.inbox.delivered": return .inboxDelivered(try payload())
        case "session.inbox.cancelled": return .inboxCancelled(try payload())
        case "session.execution.started": return .executionStarted(try payload())
        case "session.execution.succeeded": return .executionSucceeded(try payload())
        case "session.execution.failed": return .executionFailed(try payload())
        case "session.execution.interrupted": return .executionInterrupted(try payload())
        case "session.retry.scheduled": return .retryScheduled(try payload())

        case "session.step.started": return .stepStarted(try payload())
        case "session.step.first-token": return .stepFirstToken(try payload())
        case "session.step.streamed": return .stepStreamed(try payload())
        case "session.step.ended": return .stepEnded(try payload())
        case "session.step.failed": return .stepFailed(try payload())
        case "session.text.started": return .textStarted(try payload())
        case "session.text.delta": return .textDelta(try payload())
        case "session.text.ended": return .textEnded(try payload())
        case "session.reasoning.started": return .reasoningStarted(try payload())
        case "session.reasoning.delta": return .reasoningDelta(try payload())
        case "session.reasoning.ended": return .reasoningEnded(try payload())

        case "session.tool.input.started": return .toolInputStarted(try payload())
        case "session.tool.input.delta": return .toolInputDelta(try payload())
        case "session.tool.input.ended": return .toolInputEnded(try payload())
        case "session.tool.called": return .toolCalled(try payload())
        case "session.tool.progress": return .toolProgress(try payload())
        case "session.tool.success": return .toolSucceeded(try payload())
        case "session.tool.failed": return .toolFailed(try payload())
        case "shell.created": return .shellCreated(try payload())
        case "shell.exited": return .shellExited(try payload())

        case "permission.asked": return .permissionAsked(try payload())
        case "permission.replied": return .permissionReplied(try payload())
        case "form.created": return .formCreated(try payload(EventPayload.FormCreated.self).form)
        case "form.replied": return .formReplied(try payload())
        case "form.cancelled": return .formCancelled(try payload())

        default: return .unknown(type: type, rawJSON: data)
        }
    }
}
