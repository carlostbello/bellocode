import BelloCore
import Foundation
import OpenCodeKit

/// Pure reducers: `(event, state) -> state', Reduction`. No I/O, no clocks (time comes from the event or `now`).
///
/// Rules that make replay and duplicates harmless (the stream has no replay and resync re-applies buffered events over
/// a fresh snapshot):
/// - Creation events only fill fields that are still empty; they never overwrite later state.
/// - Tool calls only move forward (`ToolStatus.canAdvance`); an ended text block ignores further deltas.
/// - Execution start/end only move `busySince` / `idleAt` forward in time.
/// - Removals of unknown entities are no-ops; unknown event types are ignored.
/// Exact duplicate frames (same event ID) are dropped before reducing by `EngineCore`.
enum EventReducer {
    /// The message an event targets, so the engine can load it from disk and flush its stream buffer first.
    static func target(of event: OpenCodeEvent) -> (session: SessionID, message: MessageID)? {
        func ref(_ session: String, _ message: String) -> (SessionID, MessageID) { (SessionID(session), MessageID(message)) }
        switch event {
        case .stepStarted(let p): return ref(p.sessionID, p.assistantMessageID)
        case .stepFirstToken(let p), .stepStreamed(let p): return ref(p.sessionID, p.assistantMessageID)
        case .stepEnded(let p): return ref(p.sessionID, p.assistantMessageID)
        case .stepFailed(let p): return ref(p.sessionID, p.assistantMessageID)
        case .textStarted(let p), .reasoningStarted(let p): return ref(p.sessionID, p.assistantMessageID)
        case .textDelta(let p), .reasoningDelta(let p): return ref(p.sessionID, p.assistantMessageID)
        case .textEnded(let p), .reasoningEnded(let p): return ref(p.sessionID, p.assistantMessageID)
        case .toolInputStarted(let p): return ref(p.sessionID, p.assistantMessageID)
        case .toolInputDelta(let p): return ref(p.sessionID, p.assistantMessageID)
        case .toolInputEnded(let p): return ref(p.sessionID, p.assistantMessageID)
        case .toolCalled(let p): return ref(p.sessionID, p.assistantMessageID)
        case .toolProgress(let p): return ref(p.sessionID, p.assistantMessageID)
        case .toolSucceeded(let p): return ref(p.sessionID, p.assistantMessageID)
        case .toolFailed(let p): return ref(p.sessionID, p.assistantMessageID)
        case .inboxEnqueued(let p): return ref(p.sessionID, p.inboxID)
        case .inboxDelivered(let p), .inboxCancelled(let p): return ref(p.sessionID, p.inboxID)
        case .unknown(let type, let raw):
            if case .contentUpdated(let session, let message, _) = ExtraEvent.decode(type: type, raw: raw) {
                return (session, message)
            }
            return nil
        default: return nil
        }
    }

    /// Streamed deltas are not reduced one by one: the engine hands them to the `StreamCoalescer`.
    static func streamDelta(of event: OpenCodeEvent) -> (StreamKey, String)? {
        switch event {
        case .textDelta(let p):
            (StreamKey(sessionID: SessionID(p.sessionID), messageID: MessageID(p.assistantMessageID), kind: .text(ordinal: p.ordinal)), p.delta)
        case .reasoningDelta(let p):
            (
                StreamKey(sessionID: SessionID(p.sessionID), messageID: MessageID(p.assistantMessageID), kind: .reasoning(ordinal: p.ordinal)),
                p.delta
            )
        case .toolInputDelta(let p):
            (StreamKey(sessionID: SessionID(p.sessionID), messageID: MessageID(p.assistantMessageID), kind: .toolInput(callID: p.id)), p.delta)
        default: nil
        }
    }

    /// Whether this event ends streaming for its message or session (flush buffered deltas first).
    static func endsStreaming(_ event: OpenCodeEvent) -> Bool {
        switch event {
        case .textEnded, .reasoningEnded, .toolInputEnded, .toolCalled, .stepEnded, .stepFailed, .executionSucceeded,
            .executionFailed, .executionInterrupted:
            true
        default: false
        }
    }

    static func reduce(_ envelope: OpenCodeEventEnvelope, into state: inout ProjectionState, now: Timestamp) -> Reduction {
        var reduction = Reduction()
        let at = envelope.created.map(Timestamp.init(milliseconds:)) ?? now
        switch envelope.event {
        // MARK: Projects and catalog
        case .projectUpdated(let project):
            state.putProject(Mapping.project(project), into: &reduction)
        case .resourcesChanged(let type):
            if ["provider.updated", "model.updated", "agent.updated", "integration.updated", "models-dev.refreshed"].contains(type) {
                reduction.effects.append(.refreshCatalog(directory: envelope.directory))
            }

        // MARK: Session lifecycle
        case .sessionCreated(let p):
            let id = SessionID(p.sessionID)
            if var session = state.sessions[id] {
                if session.title == nil { session.title = p.title }
                if session.agent == nil { session.agent = p.agent }
                if session.model == nil { session.model = Mapping.model(p.model) }
                if session.parentID == nil { session.parentID = p.parentID.map { SessionID($0) } }
                state.putSession(session, into: &reduction)
            } else {
                let session = Session(
                    id: id, projectID: ProjectID(p.projectID), parentID: p.parentID.map { SessionID($0) }, title: p.title,
                    directory: p.location.directory, agent: p.agent, model: Mapping.model(p.model), created: at, updated: at)
                state.putSession(session, into: &reduction)
            }
        case .sessionRenamed(let p):
            touchSession(p.sessionID, at: at, state: &state, into: &reduction) { $0.title = p.title }
        case .sessionArchived(let p):
            touchSession(p.sessionID, at: at, state: &state, into: &reduction) { $0.archivedAt = $0.archivedAt ?? at }
        case .sessionUnarchived(let p):
            touchSession(p.sessionID, at: at, state: &state, into: &reduction) { $0.archivedAt = nil }
        case .sessionDeleted(let p):
            state.removeSession(SessionID(p.sessionID), into: &reduction)
        case .sessionStatus(let p):
            switch p.status {
            case .busy: executionStarted(SessionID(p.sessionID), at: at, state: &state, into: &reduction)
            case .idle: executionEnded(SessionID(p.sessionID), outcome: nil, error: nil, at: at, state: &state, into: &reduction)
            default: break
            }
        case .sessionIdle(let p):
            executionEnded(SessionID(p.sessionID), outcome: nil, error: nil, at: at, state: &state, into: &reduction)
        case .usageUpdated(let p):
            state.updateSession(SessionID(p.sessionID), into: &reduction) {
                $0.usage = Mapping.usage(cost: p.cost, tokens: p.tokens) ?? $0.usage
            }

        // MARK: Inbox and execution
        case .inboxEnqueued(let p):
            inboxEnqueued(p, at: at, state: &state, into: &reduction)
        case .inboxDelivered(let p):
            inboxDelivered(SessionID(p.sessionID), MessageID(p.inboxID), at: at, state: &state, into: &reduction)
        case .inboxCancelled(let p):
            let id = MessageID(p.inboxID)
            state.removeQueued(id, into: &reduction)
            if let message = state.messages[id], message.delivery == .sending || message.delivery == .accepted {
                state.removeMessage(id, sessionID: message.sessionID, into: &reduction)
            }
        case .executionStarted(let p):
            executionStarted(SessionID(p.sessionID), at: at, state: &state, into: &reduction)
        case .executionSucceeded(let p):
            executionEnded(SessionID(p.sessionID), outcome: .succeeded, error: nil, at: at, state: &state, into: &reduction)
        case .executionFailed(let p):
            executionEnded(
                SessionID(p.sessionID), outcome: .failed, error: Mapping.error(p.error), at: at, state: &state, into: &reduction)
        case .executionInterrupted(let p):
            executionEnded(SessionID(p.sessionID), outcome: .interrupted, error: nil, at: at, state: &state, into: &reduction)
        case .retryScheduled:
            break

        // MARK: Steps
        case .stepStarted(let p):
            let id = MessageID(p.assistantMessageID)
            let sessionID = SessionID(p.sessionID)
            let created = p.started.map(Timestamp.init(milliseconds:)) ?? at
            state.openMessage[sessionID] = id
            state.updateMessage(id, persist: true, into: &reduction, create: { assistantShell(id, sessionID, created) }) { message in
                guard case .assistant(var info) = message.kind else { return }
                info.agent = info.agent ?? p.agent
                info.model = info.model ?? Mapping.model(p.model)
                if message.completed == nil, info.finish == nil, info.error == nil { info.isOpen = true }
                message.kind = .assistant(info)
            }
            requireSession(sessionID, state: state, into: &reduction)
        case .stepFirstToken, .stepStreamed:
            break
        case .stepEnded(let p):
            let id = MessageID(p.assistantMessageID)
            let sessionID = SessionID(p.sessionID)
            if state.openMessage[sessionID] == id { state.openMessage[sessionID] = nil }
            state.updateMessage(id, persist: true, into: &reduction, create: { assistantShell(id, sessionID, at) }) { message in
                guard case .assistant(var info) = message.kind else { return }
                info.finish = p.finish.rawValue
                info.usage = Mapping.usage(cost: p.cost, tokens: p.tokens) ?? info.usage
                info.isOpen = false
                message.kind = .assistant(info)
                message.completed = message.completed ?? at
                closeStreamingParts(&message)
            }
        case .stepFailed(let p):
            let id = MessageID(p.assistantMessageID)
            let sessionID = SessionID(p.sessionID)
            if state.openMessage[sessionID] == id { state.openMessage[sessionID] = nil }
            state.updateMessage(id, persist: true, into: &reduction, create: { assistantShell(id, sessionID, at) }) { message in
                guard case .assistant(var info) = message.kind else { return }
                info.error = Mapping.error(p.error)
                info.finish = info.finish ?? "error"
                info.isOpen = false
                message.kind = .assistant(info)
                message.completed = message.completed ?? at
                closeStreamingParts(&message)
            }

        // MARK: Text and reasoning blocks
        case .textStarted(let p):
            block(p.sessionID, p.assistantMessageID, .text(ordinal: p.ordinal), at: at, state: &state, into: &reduction) { _ in }
        case .reasoningStarted(let p):
            block(p.sessionID, p.assistantMessageID, .reasoning(ordinal: p.ordinal), at: at, state: &state, into: &reduction) { _ in }
        case .textEnded(let p):
            block(p.sessionID, p.assistantMessageID, .text(ordinal: p.ordinal), at: at, state: &state, into: &reduction) { part in
                part.content = .text(p.text)
                part.isStreaming = false
            }
        case .reasoningEnded(let p):
            block(p.sessionID, p.assistantMessageID, .reasoning(ordinal: p.ordinal), at: at, state: &state, into: &reduction) { part in
                part.content = .reasoning(p.text)
                part.isStreaming = false
            }
        case .textDelta, .reasoningDelta, .toolInputDelta:
            // Routed through the StreamCoalescer; see `applyDeltas`.
            break

        // MARK: Tools
        case .toolInputStarted(let p):
            tool(p.sessionID, p.assistantMessageID, p.id, name: p.name, at: at, state: &state, into: &reduction) { _ in }
        case .toolInputEnded(let p):
            tool(p.sessionID, p.assistantMessageID, p.id, name: nil, at: at, state: &state, into: &reduction) { call in
                if call.status == .streamingInput { call.inputText = p.text }
            }
        case .toolCalled(let p):
            tool(p.sessionID, p.assistantMessageID, p.id, name: nil, at: at, state: &state, into: &reduction) { call in
                guard call.status.canAdvance(to: .running) else { return }
                call.status = .running
                call.input = Mapping.raw(p.input)
                if let input = call.input { call.inputText = input.text }
                call.ran = call.ran ?? at
                call.executedByProvider = p.executed
            }
        case .toolProgress(let p):
            tool(p.sessionID, p.assistantMessageID, p.id, name: nil, at: at, state: &state, into: &reduction) { call in
                guard !call.status.isFinished else { return }
                if let metadata = Mapping.raw(p.metadata) { call.metadata = metadata }
            }
        case .toolSucceeded(let p):
            tool(p.sessionID, p.assistantMessageID, p.id, name: nil, at: at, state: &state, into: &reduction) { call in
                guard call.status.canAdvance(to: .completed) else { return }
                call.status = .completed
                call.output = p.content.map(Mapping.toolOutput)
                call.metadata = Mapping.raw(p.metadata) ?? call.metadata
                call.completed = call.completed ?? at
            }
        case .toolFailed(let p):
            tool(p.sessionID, p.assistantMessageID, p.id, name: nil, at: at, state: &state, into: &reduction) { call in
                guard call.status.canAdvance(to: .failed) else { return }
                call.status = .failed
                call.error = Mapping.error(p.error)
                call.output = (p.content ?? []).map(Mapping.toolOutput)
                call.metadata = Mapping.raw(p.metadata) ?? call.metadata
                call.completed = call.completed ?? at
            }

        // MARK: Blocking requests
        case .permissionAsked(let request):
            state.putPending(.permission(Mapping.permission(request, received: at)), into: &reduction)
            requireSession(SessionID(request.sessionID), state: state, into: &reduction)
        case .permissionReplied(let p):
            state.resolvePending(p.requestID, into: &reduction)
        case .formCreated(let form):
            state.putPending(.question(Mapping.question(form, received: at)), into: &reduction)
            requireSession(SessionID(form.sessionID), state: state, into: &reduction)
        case .formReplied(let p), .formCancelled(let p):
            state.resolvePending(p.id, into: &reduction)

        case .unknown(let type, let raw):
            if let extra = ExtraEvent.decode(type: type, raw: raw) {
                reduceExtra(extra, at: at, state: &state, into: &reduction)
            }

        case .serverConnected, .locationShutdown, .worktreeResolved, .branchUpdated, .sessionInstructionsUpdated,
            .shellCreated, .shellExited:
            break
        }
        return reduction
    }

    // MARK: - Deltas

    /// Merges coalesced deltas into their messages. Published live, not written: the block's `ended` event (or the
    /// step's end) persists the final text.
    static func applyDeltas(_ flushes: [StreamCoalescer.Flush], into state: inout ProjectionState, now: Timestamp) -> Reduction {
        var reduction = Reduction()
        var byMessage: [MessageID: [StreamCoalescer.Flush]] = [:]
        var order: [MessageID] = []
        for flush in flushes {
            if byMessage[flush.key.messageID] == nil { order.append(flush.key.messageID) }
            byMessage[flush.key.messageID, default: []].append(flush)
        }
        for messageID in order {
            guard let group = byMessage[messageID], let sessionID = group.first?.key.sessionID else { continue }
            state.updateMessage(messageID, persist: false, into: &reduction, create: { assistantShell(messageID, sessionID, now) }) {
                message in
                for flush in group {
                    switch flush.key.kind {
                    case .text(let ordinal):
                        appendBlock(&message, .text(ordinal: ordinal), flush.text)
                    case .reasoning(let ordinal):
                        appendBlock(&message, .reasoning(ordinal: ordinal), flush.text)
                    case .toolInput(let callID):
                        mutateTool(&message, callID: callID, name: nil, at: now) { call in
                            if call.status == .streamingInput { call.inputText += flush.text }
                        }
                    }
                }
            }
        }
        return reduction
    }

    private static func appendBlock(_ message: inout Message, _ key: Part.Key, _ text: String) {
        let id = Part.makeID(message: message.id, key)
        if let index = message.parts.firstIndex(where: { $0.id == id }) {
            guard message.parts[index].isStreaming else { return }
            switch message.parts[index].content {
            case .text(let existing): message.parts[index].content = .text(existing + text)
            case .reasoning(let existing): message.parts[index].content = .reasoning(existing + text)
            default: break
            }
        } else {
            let content: PartContent = if case .reasoning = key { .reasoning(text) } else { .text(text) }
            message.parts.append(Part(id: id, index: message.parts.count, content: content, isStreaming: true))
        }
    }

    // MARK: - Helpers

    static func assistantShell(_ id: MessageID, _ sessionID: SessionID, _ created: Timestamp) -> Message {
        Message(id: id, sessionID: sessionID, kind: .assistant(AssistantInfo(isOpen: true)), created: created)
    }

    private static func closeStreamingParts(_ message: inout Message) {
        for index in message.parts.indices where message.parts[index].isStreaming {
            message.parts[index].isStreaming = false
        }
    }

    private static func requireSession(_ id: SessionID, state: ProjectionState, into reduction: inout Reduction) {
        if state.sessions[id] == nil { reduction.effects.append(.fetchSession(id)) }
    }

    private static func touchSession(
        _ id: String, at: Timestamp, state: inout ProjectionState, into reduction: inout Reduction, _ body: (inout Session) -> Void
    ) {
        let sessionID = SessionID(id)
        guard state.sessions[sessionID] != nil else {
            reduction.effects.append(.fetchSession(sessionID))
            return
        }
        state.updateSession(sessionID, into: &reduction) { session in
            body(&session)
            if at > session.updated { session.updated = at }
        }
    }

    private static func executionStarted(_ id: SessionID, at: Timestamp, state: inout ProjectionState, into reduction: inout Reduction) {
        if state.orphaned.remove(id) != nil { reduction.statusDirty.insert(id) }
        guard state.sessions[id] != nil else {
            reduction.effects.append(.fetchSession(id))
            return
        }
        state.updateSession(id, into: &reduction) { session in
            if session.busySince == nil || at > session.busySince! { session.busySince = at }
            if at > session.updated { session.updated = at }
        }
    }

    private static func executionEnded(
        _ id: SessionID, outcome: BelloCore.SessionOutcome?, error: ErrorInfo?, at: Timestamp, state: inout ProjectionState,
        into reduction: inout Reduction
    ) {
        // A late or replayed end of an earlier execution must not end a newer one.
        if let session = state.sessions[id] {
            if let busy = session.busySince, busy > at { return }
            if let idle = session.idleAt, idle > at { return }
        }
        state.stopping.remove(id)
        state.orphaned.remove(id)
        reduction.statusDirty.insert(id)
        if let open = state.openMessage.removeValue(forKey: id) {
            state.updateMessage(open, persist: true, into: &reduction, create: { nil }) { message in
                guard case .assistant(var info) = message.kind, info.isOpen else { return }
                info.isOpen = false
                message.kind = .assistant(info)
                closeStreamingParts(&message)
            }
        }
        guard state.sessions[id] != nil else {
            reduction.effects.append(.fetchSession(id))
            return
        }
        state.updateSession(id, into: &reduction) { session in
            session.idleAt = at
            if session.busySince == nil { session.busySince = at }
            if let outcome { session.outcome = outcome }
            session.lastError = outcome == .failed ? error : nil
            if at > session.updated { session.updated = at }
        }
    }

    private static func inboxEnqueued(
        _ p: EventPayload.InboxEnqueued, at: Timestamp, state: inout ProjectionState, into reduction: inout Reduction
    ) {
        guard p.item.type == "user" || p.item.type == "synthetic" else { return }
        let id = MessageID(p.inboxID)
        let sessionID = SessionID(p.sessionID)
        let delivery = PromptDelivery(rawValue: p.item.delivery?.rawValue ?? "steer") ?? .steer
        if let message = state.messages[id] {
            // Our own optimistic send, already in the transcript: the server has it now.
            guard message.delivery == .sending || message.delivery == .accepted else { return }
            state.updateMessage(id, persist: true, into: &reduction, create: { nil }) { message in
                message.delivery = .accepted
                // Adopt the server's clock so the message sorts with the replies.
                message.created = at
            }
        } else if var prompt = state.queue[id] {
            prompt.state = .queued
            prompt.delivery = delivery
            if prompt.text.isEmpty, let text = p.item.text { prompt.text = text }
            state.putQueued(prompt, into: &reduction)
        } else {
            let prompt = QueuedPrompt(
                id: id, sessionID: sessionID, text: p.item.text ?? "", delivery: delivery, created: at, state: .queued)
            state.putQueued(prompt, into: &reduction)
        }
    }

    private static func inboxDelivered(
        _ sessionID: SessionID, _ id: MessageID, at: Timestamp, state: inout ProjectionState, into reduction: inout Reduction
    ) {
        if let prompt = state.queue[id] {
            state.removeQueued(id, into: &reduction)
            let message = Message(
                id: id, sessionID: sessionID, kind: .user(UserContent(text: prompt.text)), created: at, delivery: .delivered)
            state.updateMessage(id, persist: true, into: &reduction, create: { message }) { existing in
                if existing.delivery != nil { existing.delivery = .delivered }
            }
            if prompt.text.isEmpty { reduction.effects.append(.fetchMessage(sessionID, id)) }
        } else if state.messages[id] != nil {
            state.updateMessage(id, persist: true, into: &reduction, create: { nil }) { message in
                if message.delivery != nil, message.delivery != .delivered {
                    message.delivery = .delivered
                    message.created = at
                }
            }
        } else {
            reduction.effects.append(.fetchMessage(sessionID, id))
        }
    }

    private static func block(
        _ session: String, _ messageID: String, _ key: Part.Key, at: Timestamp, state: inout ProjectionState,
        into reduction: inout Reduction, _ body: (inout Part) -> Void
    ) {
        let id = MessageID(messageID)
        let sessionID = SessionID(session)
        state.updateMessage(id, persist: true, into: &reduction, create: { assistantShell(id, sessionID, at) }) { message in
            let partID = Part.makeID(message: id, key)
            if let index = message.parts.firstIndex(where: { $0.id == partID }) {
                body(&message.parts[index])
            } else {
                let content: PartContent = if case .reasoning = key { .reasoning("") } else { .text("") }
                var part = Part(id: partID, index: message.parts.count, content: content, isStreaming: true)
                body(&part)
                message.parts.append(part)
            }
        }
    }

    private static func tool(
        _ session: String, _ messageID: String, _ callID: String, name: String?, at: Timestamp,
        state: inout ProjectionState, into reduction: inout Reduction, _ body: (inout BelloCore.ToolCall) -> Void
    ) {
        let id = MessageID(messageID)
        let sessionID = SessionID(session)
        state.updateMessage(id, persist: true, into: &reduction, create: { assistantShell(id, sessionID, at) }) { message in
            mutateTool(&message, callID: callID, name: name, at: at, body)
        }
    }

    /// Finds or creates the tool part and applies `body`, re-wrapping it as a sub-agent reference when it is one.
    static func mutateTool(
        _ message: inout Message, callID: String, name: String?, at: Timestamp, _ body: (inout BelloCore.ToolCall) -> Void
    ) {
        let partID = Part.makeID(message: message.id, .tool(callID: callID))
        if let index = message.parts.firstIndex(where: { $0.id == partID }), var call = message.parts[index].content.toolCall {
            if let name, call.name.isEmpty { call.name = name }
            body(&call)
            message.parts[index].content = Mapping.toolContent(call)
        } else {
            var call = BelloCore.ToolCall(callID: callID, name: name ?? "", status: .streamingInput, created: at)
            body(&call)
            message.parts.append(Part(id: partID, index: message.parts.count, content: Mapping.toolContent(call)))
        }
    }

    private static func reduceExtra(_ extra: ExtraEvent, at: Timestamp, state: inout ProjectionState, into reduction: inout Reduction) {
        switch extra {
        case .agentSelected(let id, let agent):
            touchSession(id.rawValue, at: at, state: &state, into: &reduction) { $0.agent = agent }
        case .modelSelected(let id, let model):
            touchSession(id.rawValue, at: at, state: &state, into: &reduction) { $0.model = model }
        case .viewed(let id, let idle):
            state.updateSession(id, into: &reduction) { session in
                if session.viewedAt == nil || idle > session.viewedAt! { session.viewedAt = idle }
            }
        case .metadataUpdated(let id, let metadata):
            state.updateSession(id, into: &reduction) { $0.metadata = metadata }
        case .permissionsChanged(let id, let rules):
            state.updateSession(id, into: &reduction) { $0.permissionMode = PermissionModeRules.mode(from: rules) }
        case .contentUpdated(let sessionID, let messageID, let content):
            state.updateMessage(messageID, persist: true, into: &reduction, create: { assistantShell(messageID, sessionID, at) }) {
                message in
                let open: Bool = if case .assistant(let info) = message.kind { info.isOpen } else { false }
                message.parts = Mapping.parts(content, messageID: messageID, open: open)
            }
        case .inboxDeliveryChanged(let id, let delivery):
            if var prompt = state.queue[id] {
                prompt.delivery = delivery
                state.putQueued(prompt, into: &reduction)
            }
        }
    }
}

/// Event types OpenCodeKit does not decode (they arrive as `.unknown`), decoded here from the raw frame.
enum ExtraEvent: Sendable {
    case agentSelected(SessionID, String)
    case modelSelected(SessionID, ModelSelection)
    case viewed(SessionID, Timestamp)
    case metadataUpdated(SessionID, RawJSON?)
    case permissionsChanged(SessionID, [PermissionRule])
    case contentUpdated(SessionID, MessageID, [AssistantContent])
    case inboxDeliveryChanged(MessageID, PromptDelivery)

    private struct Frame<P: Decodable>: Decodable { let data: P }
    private struct AgentSelected: Decodable { let sessionID: String; let agent: String }
    private struct ModelSelected: Decodable { let sessionID: String; let model: ModelRef }
    private struct Viewed: Decodable { let sessionID: String; let idle: Double }
    private struct Metadata: Decodable { let sessionID: String; let metadata: JSONValue? }
    private struct Permissions: Decodable { let sessionID: String; let permissions: [PermissionRule] }
    private struct Content: Decodable { let sessionID: String; let messageID: String; let content: [AssistantContent] }
    private struct DeliveryChanged: Decodable { let inboxID: String; let delivery: String }

    static func decode(type: String, raw: Data) -> ExtraEvent? {
        let decoder = JSONDecoder()
        func payload<P: Decodable>(_: P.Type) -> P? { try? decoder.decode(Frame<P>.self, from: raw).data }
        switch type {
        case "session.agent.selected":
            return payload(AgentSelected.self).map { .agentSelected(SessionID($0.sessionID), $0.agent) }
        case "session.model.selected":
            return payload(ModelSelected.self).flatMap { p in Mapping.model(p.model).map { .modelSelected(SessionID(p.sessionID), $0) } }
        case "session.viewed":
            return payload(Viewed.self).map { .viewed(SessionID($0.sessionID), Timestamp(milliseconds: $0.idle)) }
        case "session.metadata.updated":
            return payload(Metadata.self).map { .metadataUpdated(SessionID($0.sessionID), Mapping.raw($0.metadata)) }
        case "session.permissions":
            return payload(Permissions.self).map { .permissionsChanged(SessionID($0.sessionID), $0.permissions) }
        case "session.message.content.updated":
            return payload(Content.self).map { .contentUpdated(SessionID($0.sessionID), MessageID($0.messageID), $0.content) }
        case "session.inbox.delivery.changed":
            return payload(DeliveryChanged.self).flatMap { p in
                PromptDelivery(rawValue: p.delivery).map { .inboxDeliveryChanged(MessageID(p.inboxID), $0) }
            }
        default:
            return nil
        }
    }
}
