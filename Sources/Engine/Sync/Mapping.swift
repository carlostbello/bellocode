import BelloCore
import Foundation
import OpenCodeKit

// Wire DTOs (OpenCodeKit) to domain values (BelloCore). Names that exist in both modules (`Project`,
// `PermissionRequest`, `ToolCall`, `SessionStatus`) are always module-qualified in Engine files that import both.

enum Mapping {
    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func raw(_ value: JSONValue?) -> RawJSON? {
        guard let value, value != .null else { return nil }
        guard let data = try? jsonEncoder.encode(value) else { return nil }
        return RawJSON(String(decoding: data, as: UTF8.self))
    }

    static func time(_ ms: Double?) -> Timestamp? { ms.map(Timestamp.init(milliseconds:)) }

    static func model(_ ref: ModelRef?) -> ModelSelection? {
        ref.map { ModelSelection(providerID: $0.providerID, modelID: $0.id, variant: $0.variant) }
    }

    static func modelRef(_ selection: ModelSelection) -> ModelRef {
        ModelRef(id: selection.modelID, providerID: selection.providerID, variant: selection.variant)
    }

    static func error(_ error: StructuredError?) -> ErrorInfo? {
        error.map { ErrorInfo(type: $0.type, message: $0.message, status: $0.status) }
    }

    static func usage(cost: Double?, tokens: TokenUsage?) -> Usage? {
        guard cost != nil || tokens != nil else { return nil }
        return Usage(
            cost: cost ?? 0, inputTokens: tokens?.input ?? 0, outputTokens: tokens?.output ?? 0,
            reasoningTokens: tokens?.reasoning ?? 0, cacheReadTokens: tokens?.cache.read ?? 0,
            cacheWriteTokens: tokens?.cache.write ?? 0)
    }

    // MARK: Projects and sessions

    static func project(_ dto: OpenCodeKit.Project) -> BelloCore.Project {
        BelloCore.Project(
            id: ProjectID(dto.id), directory: dto.canonical, name: dto.name, vcs: dto.vcs, iconColor: dto.icon?.color,
            created: Timestamp(milliseconds: dto.time.created), updated: Timestamp(milliseconds: dto.time.updated))
    }

    static func session(_ dto: SessionInfo) -> Session {
        Session(
            id: SessionID(dto.id), projectID: ProjectID(dto.projectID), parentID: dto.parentID.map { SessionID($0) },
            forkedFrom: dto.fork.map { SessionID($0.sessionID) }, title: dto.title, directory: dto.location.directory,
            subpath: dto.subpath.flatMap { $0.isEmpty ? nil : $0 }, agent: dto.agent, model: model(dto.model),
            permissionMode: dto.permissions.flatMap(PermissionModeRules.mode(from:)),
            created: Timestamp(milliseconds: dto.time.created), updated: Timestamp(milliseconds: dto.time.updated),
            busySince: time(dto.time.busy), idleAt: time(dto.time.idle), viewedAt: time(dto.time.viewed),
            archivedAt: time(dto.time.archived), outcome: dto.outcome.flatMap { BelloCore.SessionOutcome(rawValue: $0.rawValue) },
            lastError: nil, usage: usage(cost: dto.cost, tokens: dto.tokens) ?? .zero, metadata: raw(dto.metadata))
    }

    // MARK: Messages

    static func message(_ dto: SessionMessage, sessionID: SessionID) -> Message {
        let id = MessageID(dto.id)
        switch dto {
        case .user(let user):
            var parts: [Part] = []
            for (index, file) in (user.files ?? []).enumerated() {
                let reference = FileReference(
                    uri: file["uri"]?.stringValue ?? "", mime: file["mime"]?.stringValue ?? "application/octet-stream",
                    name: file["name"]?.stringValue)
                parts.append(Part(id: Part.makeID(message: id, .file(index: index)), index: index, content: .file(reference)))
            }
            let agents = (user.agents ?? []).compactMap { $0["name"]?.stringValue }
            return Message(
                id: id, sessionID: sessionID, kind: .user(UserContent(text: user.text, agents: agents)),
                created: Timestamp(milliseconds: user.time.created), parts: parts, delivery: nil)
        case .assistant(let assistant):
            let open = assistant.time.completed == nil && assistant.error == nil && assistant.finish == nil
            let info = AssistantInfo(
                agent: assistant.agent, model: model(assistant.model), finish: assistant.finish?.rawValue,
                error: error(assistant.error), usage: usage(cost: assistant.cost, tokens: assistant.tokens), isOpen: open)
            return Message(
                id: id, sessionID: sessionID, kind: .assistant(info),
                created: Timestamp(milliseconds: assistant.time.created), completed: time(assistant.time.completed),
                parts: parts(assistant.content, messageID: id, open: open))
        case .shell(let shell):
            let info = ShellInfo(
                command: shell.command, status: shell.status, exitCode: shell.exit?.value, output: shell.output?.output,
                truncated: shell.output?.truncated ?? false)
            return Message(
                id: id, sessionID: sessionID, kind: .shell(info), created: Timestamp(milliseconds: shell.time.created),
                completed: time(shell.time.completed))
        case .idle(let idle):
            let info = TurnEndInfo(outcome: BelloCore.SessionOutcome(rawValue: idle.outcome.rawValue), error: error(idle.error))
            return Message(
                id: id, sessionID: sessionID, kind: .turnEnd(info), created: Timestamp(milliseconds: idle.time.created))
        case .other(let type, _, let rawValue):
            let created = rawValue["time"]?["created"]?.numberValue ?? 0
            return Message(
                id: id, sessionID: sessionID, kind: .other(type: type, raw: raw(rawValue) ?? RawJSON("{}")),
                created: Timestamp(milliseconds: created))
        }
    }

    /// Assistant content to parts. Ordinals count blocks of the same kind, matching streaming event identity.
    static func parts(_ content: [AssistantContent], messageID: MessageID, open: Bool) -> [Part] {
        var parts: [Part] = []
        var textOrdinal = 0
        var reasoningOrdinal = 0
        for (index, block) in content.enumerated() {
            let streaming = open && index == content.count - 1
            switch block {
            case .text(let text):
                parts.append(
                    Part(
                        id: Part.makeID(message: messageID, .text(ordinal: textOrdinal)), index: index,
                        content: .text(text), isStreaming: streaming))
                textOrdinal += 1
            case .reasoning(let text):
                parts.append(
                    Part(
                        id: Part.makeID(message: messageID, .reasoning(ordinal: reasoningOrdinal)), index: index,
                        content: .reasoning(text), isStreaming: streaming))
                reasoningOrdinal += 1
            case .tool(let call):
                parts.append(
                    Part(
                        id: Part.makeID(message: messageID, .tool(callID: call.id)), index: index,
                        content: toolContent(toolCall(call))))
            case .unknown(let type, let rawValue):
                parts.append(
                    Part(
                        id: Part.makeID(message: messageID, .other(index: index)), index: index,
                        content: .unknown(type: type, raw: raw(rawValue) ?? RawJSON("{}"))))
            }
        }
        return parts
    }

    static func toolCall(_ dto: OpenCodeKit.ToolCall) -> BelloCore.ToolCall {
        var call = BelloCore.ToolCall(
            callID: dto.id, name: dto.name, status: .streamingInput, created: Timestamp(milliseconds: dto.time.created),
            ran: time(dto.time.ran), completed: time(dto.time.completed), executedByProvider: dto.executed ?? false)
        switch dto.state {
        case .streaming(let input):
            call.inputText = input
        case .running(let input, let metadata):
            call.status = .running
            call.input = raw(input)
            call.inputText = call.input?.text ?? ""
            call.metadata = raw(metadata)
        case .completed(let input, let content, let metadata):
            call.status = .completed
            call.input = raw(input)
            call.inputText = call.input?.text ?? ""
            call.output = content.map(toolOutput)
            call.metadata = raw(metadata)
        case .error(let input, let failure, let content, let metadata):
            call.status = .failed
            call.input = raw(input)
            call.inputText = call.input?.text ?? ""
            call.error = error(failure)
            call.output = (content ?? []).map(toolOutput)
            call.metadata = raw(metadata)
        case .unknown(let status, _):
            call.status = .unknown(status)
        }
        return call
    }

    static func toolOutput(_ content: ToolContent) -> ToolOutput {
        switch content {
        case .text(let text): .text(text)
        case .file(let uri, let mime, let name): .file(FileReference(uri: uri, mime: mime, name: name))
        case .unknown(let type, let rawValue): .unknown(type: type, raw: raw(rawValue) ?? RawJSON("{}"))
        }
    }

    /// Wraps a tool call as `.subagent` when it is the sub-agent tool, else `.tool`.
    static func toolContent(_ call: BelloCore.ToolCall) -> PartContent {
        guard call.name == "subagent" || call.name == "task" else { return .tool(call) }
        let input = call.input.flatMap(json)
        let metadata = call.metadata.flatMap(json)
        let child = metadata?["sessionID"]?.stringValue ?? input?["sessionID"]?.stringValue
        return .subagent(
            SubagentReference(
                call: call, childSessionID: child.map { SessionID($0) }, agent: input?["agent"]?.stringValue,
                description: input?["description"]?.stringValue))
    }

    static func json(_ raw: RawJSON) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(raw.text.utf8))
    }

    // MARK: Requests and queue

    static func permission(_ dto: OpenCodeKit.PermissionRequest, received: Timestamp) -> BelloCore.PermissionRequest {
        BelloCore.PermissionRequest(
            id: PermissionRequestID(dto.id), sessionID: SessionID(dto.sessionID), action: dto.action,
            resources: dto.resources, alwaysScopes: dto.save ?? [], message: dto.message,
            toolMessageID: dto.source?.messageID.map { MessageID($0) }, toolCallID: dto.source?.id, received: received)
    }

    static func question(_ dto: FormInfo, received: Timestamp) -> QuestionRequest {
        QuestionRequest(
            id: QuestionID(dto.id), sessionID: SessionID(dto.sessionID), title: dto.title,
            fields: dto.fields.filter { $0.hidden != true }.map(field), received: received)
    }

    static func field(_ dto: FormField) -> QuestionField {
        let kind: QuestionField.Kind =
            switch dto.type {
            case .string: .text
            case .number: .number
            case .integer: .integer
            case .boolean: .boolean
            case .multiselect: .multiselect
            case .external: .external
            default: .other(dto.type.rawValue)
            }
        return QuestionField(
            key: dto.key, kind: kind, title: dto.title, detail: dto.description, required: dto.required ?? false,
            options: (dto.options ?? []).map { QuestionField.Option(value: $0.value, label: $0.label, detail: $0.description) },
            allowsCustom: dto.custom ?? false, placeholder: dto.placeholder, defaultValue: dto.default.flatMap(answer),
            url: dto.url)
    }

    static func answer(_ value: JSONValue) -> QuestionAnswer? {
        switch value {
        case .string(let text): .text(text)
        case .number(let number): .number(number)
        case .bool(let flag): .bool(flag)
        case .array(let items): .choices(items.compactMap(\.stringValue))
        default: nil
        }
    }

    static func formValue(_ answer: QuestionAnswer) -> FormValue {
        switch answer {
        case .text(let text): .string(text)
        case .number(let number): .number(number)
        case .bool(let flag): .bool(flag)
        case .choices(let values): .strings(values)
        }
    }

    static func queued(_ dto: InboxItem) -> QueuedPrompt? {
        guard dto.type == "user" || dto.type == "synthetic" else { return nil }
        return QueuedPrompt(
            id: MessageID(dto.id), sessionID: SessionID(dto.sessionID), text: dto.text ?? "",
            delivery: PromptDelivery(rawValue: dto.delivery.rawValue) ?? .steer,
            created: Timestamp(milliseconds: dto.time.created), state: .queued)
    }

    // MARK: Catalog

    static func catalog(
        directory: String, providers: [ProviderInfo], models: [ModelInfo], agents: [AgentInfo], defaultModel: ModelInfo?,
        fetched: Timestamp
    ) -> Catalog {
        Catalog(
            directory: directory,
            providers: providers.map { ProviderEntry(id: $0.id, name: $0.name, activation: $0.activation) },
            models: models.map(model),
            agents: agents.map { agent in
                AgentEntry(
                    id: agent.id, name: agent.name, detail: agent.description,
                    mode: AgentEntry.Mode(rawValue: agent.mode.rawValue) ?? .all, hidden: agent.hidden,
                    color: agent.color, model: model(agent.model))
            },
            defaultModel: defaultModel.map { ModelSelection(providerID: $0.providerID, modelID: $0.modelID) },
            fetched: fetched)
    }

    static func model(_ dto: ModelInfo) -> ModelEntry {
        let free = !dto.cost.isEmpty && dto.cost.allSatisfy { cost in
            guard case .object(let fields) = cost else { return false }
            return fields.values.allSatisfy { value in
                switch value {
                case .number(let number): number == 0
                case .object, .array: true
                default: true
                }
            }
        }
        return ModelEntry(
            providerID: dto.providerID, modelID: dto.modelID, name: dto.name, family: dto.family,
            contextLimit: dto.limit.context, outputLimit: dto.limit.output, variants: dto.variants.map(\.id),
            supportsTools: dto.capabilities.tools, inputModalities: dto.capabilities.input, status: dto.status.rawValue,
            enabled: dto.enabled, isFree: free)
    }
}

/// BelloCode permission modes as opencode session rules (last match wins; the default is `ask`).
public enum PermissionModeRules {
    public static func rules(for mode: PermissionMode) -> [PermissionRule] {
        switch mode {
        case .ask:
            [PermissionRule(action: "edit", resource: "*", effect: .ask), PermissionRule(action: "shell", resource: "*", effect: .ask)]
        case .autoEdit:
            [PermissionRule(action: "edit", resource: "*", effect: .allow), PermissionRule(action: "shell", resource: "*", effect: .ask)]
        case .fullAccess:
            [PermissionRule(action: "*", resource: "*", effect: .allow)]
        }
    }

    /// The mode whose rules exactly match `rules`, if any.
    public static func mode(from rules: [PermissionRule]) -> PermissionMode? {
        PermissionMode.allCases.first { self.rules(for: $0) == rules }
    }
}
