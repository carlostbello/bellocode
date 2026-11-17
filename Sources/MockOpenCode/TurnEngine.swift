import Foundation

// The turn engine: plays a ``TurnScript`` as the event sequence the pinned opencode emits for a real model turn.
//
// Observed order for one prompt (Contracts/opencode-2.3.0/events-sample.sse):
//   session.inbox.enqueued → session.execution.started → session.inbox.delivered
//   → session.step.started → session.step.first-token → reasoning/text/tool events → session.step.streamed
//   → session.tool.success → session.step.ended{finish: tool-calls} → session.usage.updated
//   → session.step.started … → session.step.ended{finish: stop} → session.usage.updated → session.execution.succeeded
//
// Runners are tasks owned by the server actor (one per busy session), cancelled by interrupt, delete and stop.

/// One admitted prompt waiting in a session's inbox.
struct InboxItem: Sendable {
    let id: String
    let text: String
    /// `files`, `agents`, `skills` as the server echoes them on the user message (nil when none).
    var attachments: JSONValue?
    var delivery: String
    let script: TurnScript
    /// The `Session.Inbox.Item` JSON returned by `prompt` and `GET …/inbox`.
    var json: JSONValue
    /// Set by an interrupt without `resume`: the item waits for the next prompt instead of starting a new run.
    var held = false
}

struct TurnHandle {
    let generation: Int
    let task: Task<Void, Never>
}

enum WaitResult: Sendable {
    case reply(JSONValue, message: String?)
    case cancelled
    case interrupted
}

struct Waiter {
    let sessionID: String
    let continuation: CheckedContinuation<WaitResult, Never>
}

/// How a turn ended early.
enum TurnEnd: Error {
    case interrupted
    case failed(StructuredError)
}

/// Mutable state of one execution, owned by its runner.
struct TurnContext {
    let sessionID: String
    let directory: String
    var agent: String
    var model: ModelRef
    let snapshot: String
    /// The open step's assistant message, if any.
    var messageID: String?
    var streamed = false
    var textOrdinal = 0
    var reasoningOrdinal = 0
    var stepIndex = 0
    var stepOutputChars = 0
    var stepReasoningChars = 0
    var total = TokenUsage.zero
    /// A text or reasoning block that has started but not ended.
    var openBlock: (kind: String, ordinal: Int, part: Int, text: String)?
    /// A tool call that has started but not settled.
    var openTool: (id: String, part: Int, input: JSONValue)?
}

extension MockOpenCodeServer {
    // MARK: Admission

    /// Admits a prompt into the session inbox (`session.inbox.enqueued`) and starts a runner if the session is idle.
    /// Returns the inbox item JSON the real `prompt` route returns.
    func admit(
        sessionID: String, id: String?, text: String, delivery: String, script: TurnScript, attachments: JSONValue? = nil
    ) -> JSONValue {
        let inboxID = id ?? makeID("msg")
        let created = now()
        var fields: [(String, JSONValue?)] = [("text", .string(text))]
        for key in ["files", "agents", "skills"] { fields.append((key, attachments?[key])) }
        let payload = JSONValue.compact(fields)
        let json: JSONValue = [
            "id": .string(inboxID), "sessionID": .string(sessionID), "time": ["created": .int(Int(created))],
            "type": "user", "payload": payload, "delivery": .string(delivery),
        ]
        state.inbox[sessionID, default: [:]][inboxID] = json
        pendingInbox[sessionID, default: []].append(
            InboxItem(id: inboxID, text: text, attachments: attachments, delivery: delivery, script: script, json: json))
        publish(
            "session.inbox.enqueued",
            [
                "inboxID": .string(inboxID), "sessionID": .string(sessionID),
                "item": ["type": "user", "payload": payload, "delivery": .string(delivery)],
            ], location: state.sessions[sessionID]?.directory, durable: sessionID)
        startRunner(sessionID)
        return json
    }

    /// The script a prompt plays: `#script:<name>` in the text, else the next script queued for the session, else the
    /// next queued for any session, else the scenario default.
    func selectScript(sessionID: String, text: String) -> TurnScript {
        if let range = text.range(of: "#script:") {
            let name = String(text[range.upperBound...].prefix { !$0.isWhitespace && $0 != "," && $0 != "." })
            if let script = state.scripts[name] { return script }
        }
        if var queued = queuedSessionScripts[sessionID], !queued.isEmpty {
            let script = queued.removeFirst()
            queuedSessionScripts[sessionID] = queued.isEmpty ? nil : queued
            return script
        }
        if !queuedScripts.isEmpty { return queuedScripts.removeFirst() }
        return state.defaultScript
    }

    /// Pending (undelivered) inbox items, for `GET /api/session/{id}/inbox`.
    func inboxJSON(_ sessionID: String) -> JSONValue {
        .array((pendingInbox[sessionID] ?? []).map(\.json))
    }

    // MARK: Interrupt

    /// Stops the running turn, its blocked requests and its running children. Returns whether anything was running.
    func interrupt(_ sessionID: String, resume: Bool) -> Bool {
        for child in state.sessionOrder where state.sessions[child]?.parentID == sessionID {
            _ = interrupt(child, resume: false)
        }
        guard let handle = turns[sessionID] else { return false }
        if !resume, var pending = pendingInbox[sessionID] {
            for index in pending.indices { pending[index].held = true }
            pendingInbox[sessionID] = pending
        }
        handle.task.cancel()
        for (id, waiter) in waiters where waiter.sessionID == sessionID {
            resumeWaiter(id, with: .interrupted)
        }
        return true
    }

    func resumeWaiter(_ id: String, with result: WaitResult) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: result)
    }

    private func waitFor(_ id: String, sessionID: String) async -> WaitResult {
        if Task.isCancelled { return .interrupted }
        return await withCheckedContinuation { waiters[id] = Waiter(sessionID: sessionID, continuation: $0) }
    }

    // MARK: Runner

    private func startRunner(_ sessionID: String) {
        guard turns[sessionID] == nil else { return }
        turnGeneration += 1
        let generation = turnGeneration
        let task = Task { await self.runExecutions(sessionID, generation: generation) }
        turns[sessionID] = TurnHandle(generation: generation, task: task)
    }

    private func takeNextInbox(_ sessionID: String, steerOnly: Bool) -> InboxItem? {
        guard var pending = pendingInbox[sessionID], !pending.isEmpty else { return nil }
        guard let index = steerOnly ? pending.firstIndex(where: { $0.delivery == "steer" }) : pending.startIndex else {
            return nil
        }
        let item = pending.remove(at: index)
        pendingInbox[sessionID] = pending.isEmpty ? nil : pending
        return item
    }

    private func runExecutions(_ sessionID: String, generation: Int) async {
        while !Task.isCancelled, state.sessions[sessionID] != nil,
            let item = takeNextInbox(sessionID, steerOnly: false)
        {
            await runExecution(sessionID, first: item)
        }
        if turns[sessionID]?.generation == generation { turns[sessionID] = nil }
        // Items admitted after an interrupt (or kept by `resume`) start a fresh run.
        if state.sessions[sessionID] != nil, pendingInbox[sessionID]?.contains(where: { !$0.held }) == true {
            startRunner(sessionID)
        }
    }

    private func runExecution(_ sessionID: String, first: InboxItem) async {
        guard let session = state.sessions[sessionID] else { return }
        var item = first
        var ctx = TurnContext(
            sessionID: sessionID, directory: session.directory,
            agent: item.script.agent ?? session.agent ?? state.defaultAgent,
            model: item.script.model ?? session.model ?? state.defaultModel, snapshot: ids.hash40())
        let interval = signposter.beginInterval("turn")
        defer { signposter.endInterval("turn", interval) }

        publish("session.execution.started", ["sessionID": .string(sessionID)], durable: sessionID)
        state.sessions[sessionID]?.busy = now()
        var outcome = "succeeded"
        do {
            while true {
                deliver(item, &ctx)
                // A model answers after it is prompted: the step's assistant message must be created strictly after
                // the user message. Without this tick the virtual clock gives both the same `created`, and their
                // order falls to the ID tie-break, where the client-minted prompt ID can sort either way.
                try await sleep(milliseconds: 1)
                try await play(item.script.steps, &ctx)
                closeStep(&ctx, finish: "stop")
                guard let steer = takeNextInbox(sessionID, steerOnly: true) else { break }
                item = steer
                ctx.agent = item.script.agent ?? session.agent ?? state.defaultAgent
                ctx.model = item.script.model ?? session.model ?? state.defaultModel
            }
            publish("session.execution.succeeded", ["sessionID": .string(sessionID)], durable: sessionID)
        } catch let TurnEnd.failed(error) {
            outcome = "failed"
            publish(
                "session.execution.failed", ["sessionID": .string(sessionID), "error": error.json], durable: sessionID)
        } catch {
            // A simulated crash: the process "died", so nothing ends the execution.
            if crashedSessions.remove(sessionID) != nil { return }
            outcome = "interrupted"
            guard state.sessions[sessionID] != nil else { return }
            finishInterrupted(&ctx)
            publish(
                "session.execution.interrupted", ["sessionID": .string(sessionID), "reason": "user"],
                durable: sessionID)
        }
        guard var updated = state.sessions[sessionID] else { return }
        let time = now()
        updated.busy = nil
        updated.idle = time
        updated.updated = time
        updated.outcome = outcome
        updated.tokens = updated.tokens + ctx.total
        state.sessions[sessionID] = updated
    }

    private func deliver(_ item: InboxItem, _ ctx: inout TurnContext) {
        publish(
            "session.inbox.delivered", ["sessionID": .string(ctx.sessionID), "inboxID": .string(item.id)],
            location: ctx.directory, durable: ctx.sessionID)
        state.messages[ctx.sessionID, default: []].append(
            .user(id: item.id, text: item.text, time: now(), attachments: item.attachments))
    }

    // MARK: Steps

    private func play(_ steps: [TurnStep], _ ctx: inout TurnContext) async throws {
        for step in steps {
            try Task.checkCancellation()
            switch step {
            case let .text(step): try await stream(kind: "text", step, &ctx)
            case let .reasoning(step): try await stream(kind: "reasoning", step, &ctx)
            case let .tool(step): try await runTool(step, &ctx)
            case let .question(step): try await runQuestion(step, &ctx)
            case let .subagent(step): try await runSubagent(step, &ctx)
            case let .fail(error):
                openStepIfNeeded(&ctx)
                let messageID = ctx.messageID!
                sessionEvent("session.step.failed", ctx, [("assistantMessageID", .string(messageID)), ("error", error.json)])
                updateAssistant(ctx, messageID) {
                    $0.error = error
                    $0.finish = "error"
                    $0.completed = self.now()
                }
                ctx.messageID = nil
                throw TurnEnd.failed(error)
            case let .delay(milliseconds): try await sleep(milliseconds: Double(milliseconds))
            case .interrupt: throw TurnEnd.interrupted
            case .dropEventStreams: dropEventStreams()
            case .duplicateNextEvent: duplicateNextEvent()
            }
        }
    }

    /// A text or reasoning block: `*.started`, paced `*.delta`s, `*.ended` with the full text.
    private func stream(kind: String, _ step: TextStep, _ ctx: inout TurnContext) async throws {
        openStepIfNeeded(&ctx)
        let messageID = ctx.messageID!
        let ordinal: Int
        let created = now()
        if kind == "text" {
            ordinal = ctx.textOrdinal
            ctx.textOrdinal += 1
        } else {
            ordinal = ctx.reasoningOrdinal
            ctx.reasoningOrdinal += 1
        }
        let base: [(String, JSONValue)] = [("assistantMessageID", .string(messageID)), ("ordinal", .int(ordinal))]
        sessionEvent("session.\(kind).started", ctx, base)
        let part = appendPart(ctx, messageID, kind == "text" ? .text("") : .reasoning(text: "", created: created, completed: nil))
        ctx.openBlock = (kind, ordinal, part, "")
        let pacing = step.pacing ?? .standard
        for chunk in pacing.chunks(step.text) {
            try await sleep(milliseconds: pacing.intervalMilliseconds)
            ctx.openBlock?.text += chunk
            sessionEvent("session.\(kind).delta", ctx, base + [("delta", .string(chunk))], durable: false)
            let text = ctx.openBlock?.text ?? ""
            deltaObserver?(messageID, text.utf8.count, Double(DispatchTime.now().uptimeNanoseconds) / 1e9)
            setPart(ctx, messageID, part, kind == "text" ? .text(text) : .reasoning(text: text, created: created, completed: nil))
        }
        endOpenBlock(&ctx)
        if kind == "text" { ctx.stepOutputChars += step.text.count } else { ctx.stepReasoningChars += step.text.count }
    }

    private func endOpenBlock(_ ctx: inout TurnContext) {
        guard let block = ctx.openBlock, let messageID = ctx.messageID else { return }
        ctx.openBlock = nil
        sessionEvent(
            "session.\(block.kind).ended", ctx,
            [("assistantMessageID", .string(messageID)), ("ordinal", .int(block.ordinal)), ("text", .string(block.text))])
        if block.kind == "reasoning" {
            updateAssistant(ctx, messageID) { message in
                if case let .reasoning(text, created, _) = message.content[block.part] {
                    message.content[block.part] = .reasoning(text: text, created: created, completed: self.now())
                }
            }
        }
    }

    /// Starts a tool call: input streaming, `tool.called` and `step.streamed`. Returns the tool id.
    private func beginTool(name: String, input: JSONValue, pacing: StreamPacing?, _ ctx: inout TurnContext) async throws
        -> String
    {
        openStepIfNeeded(&ctx)
        let messageID = ctx.messageID!
        let toolID = ids.uuid()
        let base: [(String, JSONValue)] = [("assistantMessageID", .string(messageID)), ("id", .string(toolID))]
        sessionEvent("session.tool.input.started", ctx, base + [("name", .string(name))])
        let part = appendPart(ctx, messageID, .tool(ToolPart(id: toolID, name: name, state: .streaming(input: ""), created: now())))
        ctx.openTool = (toolID, part, input)
        let text = input.serialized
        let pacing = pacing ?? StreamPacing(chunkSize: 16, rate: 200)
        var sent = ""
        for chunk in pacing.chunks(text) {
            try await sleep(milliseconds: pacing.intervalMilliseconds)
            sent += chunk
            sessionEvent("session.tool.input.delta", ctx, base + [("delta", .string(chunk))], durable: false)
            updateTool(ctx, messageID, part) { $0.state = .streaming(input: sent) }
        }
        sessionEvent("session.tool.input.ended", ctx, base + [("text", .string(text))])
        sessionEvent("session.tool.called", ctx, base + [("input", input), ("executed", false)])
        let ran = now()
        updateTool(ctx, messageID, part) {
            $0.state = .running(input: input, metadata: [:])
            $0.ran = ran
        }
        if !ctx.streamed {
            ctx.streamed = true
            sessionEvent("session.step.streamed", ctx, [("assistantMessageID", .string(messageID))])
            updateAssistant(ctx, messageID) { $0.streamed = ran }
        }
        ctx.stepOutputChars += text.count
        return toolID
    }

    private func toolProgress(_ metadata: JSONValue, _ ctx: TurnContext) {
        guard let messageID = ctx.messageID, let tool = ctx.openTool else { return }
        sessionEvent(
            "session.tool.progress", ctx,
            [("assistantMessageID", .string(messageID)), ("id", .string(tool.id)), ("metadata", metadata)],
            durable: false)
        updateTool(ctx, messageID, tool.part) { part in
            if case let .running(input, _) = part.state { part.state = .running(input: input, metadata: metadata) }
        }
    }

    private func succeedTool(content: [ToolContent], metadata: JSONValue?, _ ctx: inout TurnContext) {
        guard let messageID = ctx.messageID, let tool = ctx.openTool else { return }
        ctx.openTool = nil
        sessionEvent(
            "session.tool.success", ctx,
            [
                ("assistantMessageID", .string(messageID)), ("id", .string(tool.id)),
                ("content", .array(content.map(\.json))),
            ] + (metadata.map { [("metadata", $0)] } ?? []) + [("executed", false)], version: 2)
        let completed = now()
        updateTool(ctx, messageID, tool.part) {
            $0.state = .completed(input: tool.input, content: content, metadata: metadata)
            $0.completed = completed
        }
    }

    private func failTool(_ error: StructuredError, metadata: JSONValue? = nil, _ ctx: inout TurnContext) {
        guard let messageID = ctx.messageID, let tool = ctx.openTool else { return }
        ctx.openTool = nil
        sessionEvent(
            "session.tool.failed", ctx,
            [("assistantMessageID", .string(messageID)), ("id", .string(tool.id)), ("error", error.json)]
                + (metadata.map { [("metadata", $0)] } ?? []) + [("executed", false)])
        let completed = now()
        updateTool(ctx, messageID, tool.part) {
            $0.state = .error(input: tool.input, error: error, metadata: metadata)
            $0.completed = completed
        }
    }

    private func runTool(_ step: ToolStep, _ ctx: inout TurnContext) async throws {
        _ = try await beginTool(name: step.name, input: step.input, pacing: step.pacing, &ctx)
        if let ask = step.permission, !isAllowed(ask, ctx.sessionID) {
            let decision = try await askPermission(ask, ctx)
            if decision == "reject" {
                failTool(
                    StructuredError(
                        type: "permission", message: "The user rejected permission to use this specific tool call."),
                    &ctx)
                closeStep(&ctx, finish: "tool-calls")
                return
            }
        }
        let duration = Double(step.duration ?? 50)
        let progress = step.progress ?? []
        let slice = duration / Double(progress.count + 1)
        for metadata in progress {
            try await sleep(milliseconds: slice)
            toolProgress(metadata, ctx)
        }
        try await sleep(milliseconds: slice)
        if let error = step.error {
            failTool(error, metadata: step.metadata, &ctx)
        } else {
            succeedTool(content: [.text(step.output)] + (step.files ?? []), metadata: step.metadata, &ctx)
        }
        closeStep(&ctx, finish: "tool-calls")
    }

    private func isAllowed(_ ask: PermissionAsk, _ sessionID: String) -> Bool {
        let allowed = state.allowed[sessionID] ?? []
        return !ask.resources.isEmpty && ask.resources.allSatisfy { allowed.contains(ask.action + "\u{0}" + $0) }
    }

    /// Opens a permission request for the open tool and blocks until it is answered. Returns the decision.
    private func askPermission(_ ask: PermissionAsk, _ ctx: TurnContext) async throws -> String {
        let permission = MockPermission(
            id: makeID("per"), sessionID: ctx.sessionID, action: ask.action, resources: ask.resources, save: ask.save,
            metadata: nil, source: ctx.messageID.flatMap { m in ctx.openTool.map { (m, $0.id) } }, message: ask.message)
        state.permissions.append(permission)
        publish("permission.asked", permission.json, location: ctx.directory)
        switch await waitFor(permission.id, sessionID: ctx.sessionID) {
        case let .reply(decision, _): return decision.stringValue ?? "reject"
        case .cancelled, .interrupted:
            // The request dies with the turn; tell clients it is no longer pending.
            if let index = state.permissions.firstIndex(where: { $0.id == permission.id }) {
                state.permissions.remove(at: index)
                publish(
                    "permission.replied",
                    ["sessionID": .string(ctx.sessionID), "requestID": .string(permission.id), "reply": "reject"],
                    location: ctx.directory)
            }
            throw CancellationError()
        }
    }

    private func runQuestion(_ step: QuestionStep, _ ctx: inout TurnContext) async throws {
        let input: JSONValue = ["title": .string(step.title), "fields": step.fields]
        _ = try await beginTool(name: "question", input: input, pacing: nil, &ctx)
        let form = MockForm(id: makeID("frm"), sessionID: ctx.sessionID, title: step.title, metadata: nil, fields: step.fields)
        state.forms.append(form)
        publish("form.created", ["form": form.json], location: ctx.directory)
        switch await waitFor(form.id, sessionID: ctx.sessionID) {
        case let .reply(answer, _):
            succeedTool(content: [.text(answer.serialized)], metadata: ["answer": answer], &ctx)
        case .cancelled:
            failTool(StructuredError(type: "cancelled", message: "The user dismissed the question."), &ctx)
        case .interrupted:
            if let index = state.forms.firstIndex(where: { $0.id == form.id }) {
                state.forms.remove(at: index)
                state.settledForms.insert(form.id)
                publish(
                    "form.cancelled", ["id": .string(form.id), "sessionID": .string(ctx.sessionID)],
                    location: ctx.directory)
            }
            throw CancellationError()
        }
        closeStep(&ctx, finish: "tool-calls")
    }

    private func runSubagent(_ step: SubagentStep, _ ctx: inout TurnContext) async throws {
        let input: JSONValue = [
            "agent": .string(step.agent), "description": .string(step.description), "prompt": .string(step.prompt),
        ]
        _ = try await beginTool(name: "subagent", input: input, pacing: nil, &ctx)
        let child = makeSession(
            parentID: ctx.sessionID, directory: ctx.directory, title: "\(step.description) (@\(step.agent) subagent)",
            agent: step.agent)
        toolProgress(["sessionID": .string(child.id)], ctx)
        var script = step.script
        script.agent = script.agent ?? step.agent
        _ = admit(sessionID: child.id, id: nil, text: step.prompt, delivery: "steer", script: script)
        if step.wait == true {
            await waitUntilIdle(child.id)
            try Task.checkCancellation()
            let metadata: JSONValue = ["sessionID": .string(child.id), "status": .string(state.sessions[child.id]?.outcome ?? "completed")]
            succeedTool(content: [.text(lastAssistantText(child.id))], metadata: metadata, &ctx)
        } else {
            let metadata: JSONValue = ["sessionID": .string(child.id), "status": "running"]
            succeedTool(content: [.text(metadata.serialized)], metadata: metadata, &ctx)
        }
        closeStep(&ctx, finish: "tool-calls")
    }

    func lastAssistantText(_ sessionID: String) -> String {
        for message in (state.messages[sessionID] ?? []).reversed() {
            guard case let .assistant(assistant) = message.kind else { continue }
            for part in assistant.content.reversed() {
                if case let .text(text) = part { return text }
            }
        }
        return ""
    }

    // MARK: Step boundaries

    private func openStepIfNeeded(_ ctx: inout TurnContext) {
        guard ctx.messageID == nil else { return }
        let messageID = makeID("msg")
        let started = now()
        ctx.messageID = messageID
        ctx.streamed = false
        ctx.textOrdinal = 0
        ctx.reasoningOrdinal = 0
        ctx.stepOutputChars = 0
        ctx.stepReasoningChars = 0
        sessionEvent(
            "session.step.started", ctx,
            [
                ("agent", .string(ctx.agent)), ("model", ctx.model.json), ("assistantMessageID", .string(messageID)),
                ("snapshot", .string(ctx.snapshot)), ("started", .int(Int(started))),
            ])
        var message = AssistantMessage(id: messageID, agent: ctx.agent, model: ctx.model, created: started)
        message.firstToken = started
        state.messages[ctx.sessionID, default: []].append(.assistant(message))
        sessionEvent("session.step.first-token", ctx, [("assistantMessageID", .string(messageID))])
    }

    /// Ends the open step (if any) with `step.streamed` (once), `step.ended` and `usage.updated`.
    private func closeStep(_ ctx: inout TurnContext, finish: String) {
        guard let messageID = ctx.messageID else { return }
        endOpenBlock(&ctx)
        if !ctx.streamed {
            ctx.streamed = true
            sessionEvent("session.step.streamed", ctx, [("assistantMessageID", .string(messageID))])
            let streamed = now()
            updateAssistant(ctx, messageID) { $0.streamed = streamed }
        }
        let tokens = TokenUsage(
            input: 600 + 80 * ctx.stepIndex, output: max(1, ctx.stepOutputChars / 4),
            reasoning: ctx.stepReasoningChars / 4, cacheRead: 4096, cacheWrite: 0)
        ctx.stepIndex += 1
        ctx.total = ctx.total + tokens
        sessionEvent(
            "session.step.ended", ctx,
            [
                ("assistantMessageID", .string(messageID)), ("finish", .string(finish)),
                ("rawFinish", .string(finish == "tool-calls" ? "tool_calls" : finish)), ("tokens", tokens.json),
                ("cost", 0), ("snapshot", .string(ctx.snapshot)), ("files", []),
            ])
        let completed = now()
        updateAssistant(ctx, messageID) {
            $0.finish = finish
            $0.tokens = tokens
            $0.cost = 0
            $0.completed = completed
            $0.snapshot = ctx.snapshot
        }
        let sessionTokens = (state.sessions[ctx.sessionID]?.tokens ?? .zero) + ctx.total
        publish(
            "session.usage.updated", ["sessionID": .string(ctx.sessionID), "cost": 0, "tokens": sessionTokens.json])
        ctx.messageID = nil
    }

    /// After a cancel: end open blocks, fail an unsettled tool and fail the open step.
    private func finishInterrupted(_ ctx: inout TurnContext) {
        endOpenBlock(&ctx)
        failTool(StructuredError(type: "aborted", message: "Tool execution was interrupted."), &ctx)
        guard let messageID = ctx.messageID else { return }
        let error = StructuredError(type: "aborted", message: "The operation was aborted.")
        sessionEvent("session.step.failed", ctx, [("assistantMessageID", .string(messageID)), ("error", error.json)])
        let completed = now()
        updateAssistant(ctx, messageID) {
            $0.error = error
            $0.completed = completed
        }
        ctx.messageID = nil
    }

    // MARK: Event and record helpers

    /// A session-scoped event: `data` starts with `sessionID`, carries the session's location, durable by default.
    private func sessionEvent(
        _ type: String, _ ctx: TurnContext, _ pairs: [(String, JSONValue)], durable: Bool = true, version: Int = 1
    ) {
        publish(
            type, .object([("sessionID", .string(ctx.sessionID))] + pairs), location: ctx.directory,
            durable: durable ? ctx.sessionID : nil, version: version)
    }

    private func updateAssistant(_ ctx: TurnContext, _ messageID: String, _ body: (inout AssistantMessage) -> Void) {
        guard var messages = state.messages[ctx.sessionID],
            let index = messages.lastIndex(where: { $0.id == messageID }),
            case var .assistant(message) = messages[index].kind
        else { return }
        state.messages[ctx.sessionID] = nil  // keep the array uniquely referenced while mutating
        body(&message)
        messages[index].kind = .assistant(message)
        state.messages[ctx.sessionID] = messages
    }

    private func appendPart(_ ctx: TurnContext, _ messageID: String, _ part: AssistantPart) -> Int {
        var index = 0
        updateAssistant(ctx, messageID) {
            index = $0.content.count
            $0.content.append(part)
        }
        return index
    }

    private func setPart(_ ctx: TurnContext, _ messageID: String, _ index: Int, _ part: AssistantPart) {
        updateAssistant(ctx, messageID) { message in
            if message.content.indices.contains(index) { message.content[index] = part }
        }
    }

    private func updateTool(_ ctx: TurnContext, _ messageID: String, _ index: Int, _ body: (inout ToolPart) -> Void) {
        updateAssistant(ctx, messageID) { message in
            guard message.content.indices.contains(index), case var .tool(tool) = message.content[index] else { return }
            body(&tool)
            message.content[index] = .tool(tool)
        }
    }
}
