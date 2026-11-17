import BelloCore
import Foundation

/// Maps BelloCore messages to transcript rows. Pure and deterministic.
///
/// Two stages: `segments(for:)` turns one message into row candidates (cached by the controller per message
/// revision), and `rows(from:)` joins consecutive tool calls of one turn into work groups. Grouping never crosses a
/// user message, so the rows of a turn depend only on that turn's messages; the controller rebuilds just the last
/// turn while a reply streams.
public enum RowBuilder {
    /// A row candidate from one message: a finished row, or a tool call waiting to be grouped.
    public enum Segment: Sendable, Equatable {
        case row(TranscriptRow)
        case tool(ToolItem, messageID: MessageID, turnID: MessageID?, revision: Int, created: Timestamp)
    }

    /// Options that affect mapping.
    public struct Context: Sendable {
        /// Measured reasoning durations by part (the transcript times what it sees streaming).
        public var reasoningDurations: [PartID: TimeInterval]

        public init(reasoningDurations: [PartID: TimeInterval] = [:]) {
            self.reasoningDurations = reasoningDurations
        }
    }

    // MARK: Whole transcript

    /// All rows for `messages` (oldest first). `isRunning` adds the "working" row when nothing visible is live.
    public static func rows(for messages: [Message], isRunning: Bool, context: Context = Context()) -> [TranscriptRow] {
        var turn: MessageID?
        var segments: [Segment] = []
        segments.reserveCapacity(messages.count * 2)
        for message in messages {
            if case .user = message.kind { turn = message.id }
            segments += self.segments(for: message, turnID: turn, context: context)
        }
        return rows(from: segments, isRunning: isRunning, lastTurn: turn)
    }

    /// Joins consecutive tool segments of the same turn into work groups and appends the working row.
    public static func rows(from segments: [Segment], isRunning: Bool, lastTurn: MessageID?) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(segments.count)
        var pending: [(item: ToolItem, messageID: MessageID, turnID: MessageID?, revision: Int, created: Timestamp)] = []
        func flush() {
            guard let first = pending.first else { return }
            var hasher = Hasher()
            for member in pending {
                hasher.combine(member.item.id)
                hasher.combine(member.messageID)
                hasher.combine(member.revision)
            }
            rows.append(
                TranscriptRow(
                    id: .group(first.item.id), messageID: first.messageID, turnID: first.turnID, role: .assistant,
                    content: .work(WorkGroupContent(items: pending.map(\.item))), version: hasher.finalize(),
                    created: first.created))
            pending.removeAll()
        }
        for segment in segments {
            switch segment {
            case .tool(let item, let messageID, let turnID, let revision, let created):
                if let last = pending.last, last.turnID != turnID { flush() }
                pending.append((item, messageID, turnID, revision, created))
            case .row(let row):
                flush()
                rows.append(row)
            }
        }
        flush()
        // Identity must be unique; a duplicated server ID (a corrupt page) keeps its first row rather than crashing.
        var seen = Set<RowID>()
        if rows.contains(where: { !seen.insert($0.id).inserted }) {
            seen.removeAll()
            rows = rows.filter { seen.insert($0.id).inserted }
        }
        if isRunning, !(rows.last?.isLive ?? false) {
            let turn = lastTurn ?? MessageID("start")
            rows.append(
                TranscriptRow(
                    id: .working(turn), messageID: turn, turnID: lastTurn, role: .assistant, content: .working,
                    version: 0, created: rows.last?.created ?? Timestamp(milliseconds: 0)))
        }
        return rows
    }

    // MARK: One message

    public static func segments(for message: Message, turnID: MessageID?, context: Context = Context()) -> [Segment] {
        let revision = message.revision
        func row(_ id: RowID, _ role: RowRole, _ content: RowContent) -> Segment {
            .row(
                TranscriptRow(
                    id: id, messageID: message.id, turnID: turnID, role: role, content: content, version: revision,
                    created: message.created))
        }
        switch message.kind {
        case .user(let user):
            // opencode's child report to its parent (`<subagent …>`) is not the person's message: one compact line.
            if let report = subagentReport(user.text) {
                return [row(.lifecycle(message.id), .system, .lifecycle(LifecycleContent(kind: .note, text: report)))]
            }
            // BelloCode's own wakes (MR watch, secret answers) are not the person's message: one line saying why.
            if let note = belloCodeWake(user.text) {
                return [row(.lifecycle(message.id), .system, .lifecycle(LifecycleContent(kind: .note, text: note)))]
            }
            let files = message.parts.compactMap { part -> FileChip? in
                guard case .file(let file) = part.content else { return nil }
                return chip(file)
            }
            return [
                row(
                    .message(message.id), .user,
                    .user(
                        UserRowContent(
                            text: user.text, attachments: files, agents: user.agents, isSending: message.delivery == .sending)))
            ]

        case .assistant(let info):
            var result: [Segment] = []
            for part in message.parts {
                switch part.content {
                case .text(let text):
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    result.append(row(.part(part.id), .assistant, .markdown(text: text, isStreaming: part.isStreaming)))
                case .reasoning(let text):
                    if text.isEmpty && !part.isStreaming { continue }
                    result.append(
                        row(
                            .part(part.id), .assistant,
                            .reasoning(
                                ReasoningContent(
                                    text: text, isStreaming: part.isStreaming,
                                    duration: context.reasoningDurations[part.id]))))
                case .tool(let call):
                    if let visual = visualCard(call) {
                        result.append(row(.part(part.id), .assistant, .visual(visual)))
                    } else if let card = sendToUserMarkdown(call) {
                        result.append(row(.part(part.id), .assistant, .markdown(text: card, isStreaming: !call.status.isFinished)))
                    } else if let todo = todoList(call) {
                        result.append(row(.part(part.id), .assistant, .todo(todo)))
                    } else {
                        result.append(
                            .tool(
                                toolItem(call, partID: part.id), messageID: message.id, turnID: turnID, revision: revision,
                                created: message.created))
                    }
                case .subagent(let reference):
                    result.append(row(.part(part.id), .assistant, .subagent(subagentCard(reference))))
                case .file(let file):
                    result.append(row(.part(part.id), .assistant, .file(chip(file))))
                case .unknown(let type, _):
                    result.append(row(.part(part.id), .assistant, .unknown(type: type)))
                }
            }
            if let error = info.error, !isAbort(error) {
                result.append(
                    row(.error(message.id), .system, .error(ErrorBannerContent(title: errorTitle(error), message: error.message))))
            }
            return result

        case .shell(let shell):
            let status: ToolItemStatus =
                switch shell.status {
                case "running": .running
                case "exited": (shell.exitCode ?? 0) == 0 ? .done : .failed("Exit code \(Int(shell.exitCode ?? 0))")
                case "timeout": .failed("Timed out")
                case "killed": .failed("Killed")
                default: .unknown(shell.status)
                }
            let duration = message.completed.map { Double($0.milliseconds - message.created.milliseconds) / 1000 }
            let item = ToolItem(
                id: PartID(message.id.rawValue + "/shell"), name: "shell", category: .command,
                verb: status.isActive ? "Running" : "Ran", target: shell.command, status: status, duration: duration,
                input: "$ " + shell.command, output: (shell.output ?? "") + (shell.truncated ? "\n…" : ""),
                outputIsLive: status.isActive)
            return [.tool(item, messageID: message.id, turnID: turnID, revision: revision, created: message.created)]

        case .turnEnd(let end):
            switch end.outcome {
            case .interrupted:
                return [row(.lifecycle(message.id), .system, .lifecycle(LifecycleContent(kind: .interrupted, text: "Interrupted")))]
            case .failed:
                let text = end.error.map(\.message) ?? "The turn failed."
                return [row(.error(message.id), .system, .error(ErrorBannerContent(title: "Turn failed", message: text)))]
            case .succeeded, nil:
                return []
            }

        case .other(let type, let raw):
            if let content = lifecycle(type: type, raw: raw) {
                return [row(.lifecycle(message.id), .system, .lifecycle(content))]
            }
            return [row(.lifecycle(message.id), .system, .unknown(type: type))]
        }
    }

    // MARK: Helpers

    static func chip(_ file: FileReference) -> FileChip {
        let name = file.name ?? URL(string: file.uri)?.lastPathComponent ?? file.uri
        return FileChip(uri: file.uri, mime: file.mime, name: name.isEmpty ? file.uri : name)
    }

    static func isAbort(_ error: ErrorInfo) -> Bool {
        let type = error.type.lowercased()
        return type == "aborted" || type.contains("abort")
    }

    static func errorTitle(_ error: ErrorInfo) -> String {
        switch error.type.lowercased() {
        case "provider": error.status.map { "Provider error (\($0))" } ?? "Provider error"
        case "permission": "Permission denied"
        case "auth", "authentication": "Not signed in"
        default: "Error"
        }
    }

    static func json(_ raw: RawJSON?) -> Any? {
        guard let raw, let data = raw.text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func lifecycle(type: String, raw: RawJSON) -> LifecycleContent? {
        let object = json(raw) as? [String: Any] ?? [:]
        switch type {
        case "compaction":
            switch object["status"] as? String {
            case "running": return LifecycleContent(kind: .compacted, text: "Compacting the conversation…")
            case "failed": return LifecycleContent(kind: .compacted, text: "Compaction failed")
            default: return LifecycleContent(kind: .compacted, text: "Conversation compacted")
            }
        case "model-switched":
            let model = (object["model"] as? [String: Any])?["id"] as? String
            return LifecycleContent(kind: .modelChanged, text: model.map { "Model changed to \($0)" } ?? "Model changed")
        case "agent-switched":
            let agent = object["agent"] as? String
            return LifecycleContent(kind: .agentChanged, text: agent.map { "Agent changed to \($0)" } ?? "Agent changed")
        case "skill":
            let name = object["name"] as? String
            return LifecycleContent(kind: .note, text: name.map { "Loaded skill \($0)" } ?? "Loaded a skill")
        case "location-switched":
            let subpath = object["subpath"] as? String
            return LifecycleContent(kind: .note, text: subpath.map { "Moved to \($0)" } ?? "Location changed")
        case "synthetic", "system":
            let description = object["description"] as? String
            let text = (object["text"] as? String).map { String($0.prefix(160)) }
            guard let line = description ?? text?.split(separator: "\n").first.map(String.init) else { return nil }
            return LifecycleContent(kind: .note, text: line)
        default:
            return nil
        }
    }

    static func todoList(_ call: ToolCall) -> TodoListContent? {
        let name = call.name.lowercased()
        guard name == "todowrite" || name == "todo_write" || name == "todo" else { return nil }
        let input = json(call.input) as? [String: Any] ?? json(RawJSON(call.inputText)) as? [String: Any]
        guard let todos = input?["todos"] as? [[String: Any]] else { return TodoListContent(items: []) }
        return TodoListContent(
            items: todos.map { todo in
                TodoItem(
                    text: todo["content"] as? String ?? todo["text"] as? String ?? "",
                    state: (todo["status"] as? String).flatMap(TodoItem.State.init(rawValue:)) ?? .pending)
            })
    }

    static func subagentCard(_ reference: SubagentReference) -> SubagentCardContent {
        let call = reference.call
        var status: SubagentStatus =
            switch call.status {
            case .streamingInput, .running: .running
            case .completed: .done
            case .failed: .failed
            case .unknown: .unknown
            }
        // A background child outlives its call: the Engine's live state of the child wins once the call succeeded.
        if call.status != .failed, let live = reference.liveStatus {
            status =
                switch live {
                case .running, .stopping: .running
                case .waitingOnChildren: .waitingOnChildren
                case .needsApproval, .needsAnswer: .needsYou
                case .failed: .failed
                case .stopped: .stopped
                case .done, .idle: .done
                case .unknown: .unknown
                }
        }
        // With a live state the call's own duration (the time to start a background child) would mislead: omit it.
        return SubagentCardContent(
            title: reference.description ?? "Sub-agent task", agent: reference.agent, status: status,
            childSessionID: reference.childSessionID, duration: reference.liveStatus == nil ? duration(call) : nil)
    }

    /// "Child task “Write CHANGELOG entry” finished: Drafted the 2.0 entry…" for opencode's report message
    /// `<subagent sessionID="…" state="completed|error|cancelled|running" description="…">body</subagent>`; nil otherwise.
    static func subagentReport(_ text: String) -> String? {
        guard text.hasPrefix("<subagent "), let close = text.firstIndex(of: ">") else { return nil }
        let head = String(text[..<close])
        func attribute(_ name: String) -> String? {
            guard let start = head.range(of: name + "=\"") else { return nil }
            let rest = head[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        let description = attribute("description") ?? "Sub-agent"
        let verb =
            switch attribute("state") {
            case "completed": "finished"
            case "error": "failed"
            case "cancelled": "was stopped"
            case "running": "reported (still working)"
            default: "reported"
            }
        var body = String(text[text.index(after: close)...])
        if let end = body.range(of: "</subagent>", options: .backwards) { body = String(body[..<end.lowerBound]) }
        let summary = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let clipped = summary.count > 160 ? String(summary.prefix(159)) + "…" : summary
        return "↩ “\(description)” \(verb)" + (clipped.isEmpty ? "" : ": " + clipped)
    }

    /// "!12" for an MR URL or "!12" itself.
    static func mergeRequestLabel(_ text: String) -> String {
        if text.hasPrefix("!") { return text }
        if let range = text.range(of: "/-/merge_requests/") { return "!" + text[range.upperBound...].prefix { $0.isNumber } }
        return text
    }

    /// "[BelloCode MR watch] group/proj!1: Pipeline #9 finished…" → "MR watch woke this thread: group/proj!1: …";
    /// "[BelloCode secret] The user saved “X”. secretRef: …" → "Secret: The user saved “X”." (references stay out of
    /// the note). nil for other text.
    static func belloCodeWake(_ text: String) -> String? {
        guard text.hasPrefix("[BelloCode ") else { return nil }
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        if first.hasPrefix("[BelloCode MR watch] ") {
            let rest = first.dropFirst("[BelloCode MR watch] ".count)
            return "↻ MR watch woke this thread: " + (rest.count > 200 ? rest.prefix(199) + "…" : rest)
        }
        if first.hasPrefix("[BelloCode secret] ") {
            var rest = String(first.dropFirst("[BelloCode secret] ".count))
            for marker in [" secretRef:", " One-read path:"] {
                if let range = rest.range(of: marker) { rest = String(rest[..<range.lowerBound]) }
            }
            return "Secret request: " + (rest.count > 200 ? String(rest.prefix(199)) + "…" : rest)
        }
        return nil
    }

    /// BelloCode's `html_render` app tool (`bellocode_app_html_render`) as a visual card, from the call's title and the
    /// result's `visualID:`/`height:`/`note:` lines. nil for other tools.
    static func visualCard(_ call: ToolCall) -> VisualCardContent? {
        guard call.name == "bellocode_app_html_render" || call.name == "html_render" else { return nil }
        let input = call.input.flatMap { try? JSONSerialization.jsonObject(with: Data($0.text.utf8)) as? [String: Any] } ?? [:]
        let title = (input["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Visual"
        var fields: [String: String] = [:]
        for line in call.outputText.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        switch call.status {
        case .failed:
            return VisualCardContent(visualID: "", title: title, height: 60, status: .failed(call.error?.message ?? "the render failed"))
        case .completed:
            guard let id = fields["visualID"], !id.isEmpty else {
                return VisualCardContent(visualID: "", title: title, height: 60, status: .failed(String(call.outputText.prefix(160))))
            }
            return VisualCardContent(visualID: id, title: title, height: Double(fields["height"] ?? "") ?? 240, status: .ready, note: fields["note"])
        default:
            return VisualCardContent(visualID: "", title: title, height: 120, status: .rendering)
        }
    }

    /// The bellocode plugin's `send_to_user` (content the person must read mid-turn) as a quoted Markdown card with a
    /// heading, instead of a tool line. nil for other tools or while the input is still streaming in.
    static func sendToUserMarkdown(_ call: ToolCall) -> String? {
        guard call.name == "send_to_user", call.status != .failed, let raw = call.input,
            let object = try? JSONSerialization.jsonObject(with: Data(raw.text.utf8)) as? [String: Any],
            let markdown = object["markdown"] as? String, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "For you"
        let quoted = markdown.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        return "> **\(title)**\n>\n" + quoted
    }

    static func duration(_ call: ToolCall) -> TimeInterval? {
        guard let end = call.completed, let start = call.ran ?? call.created else { return nil }
        return max(0, Double(end.milliseconds - start.milliseconds) / 1000)
    }

    /// Category, verb and target for a tool name and its input.
    static func describe(name: String, input: [String: Any], active: Bool) -> (ToolCategory, String, String) {
        func string(_ keys: String...) -> String {
            for key in keys { if let value = input[key] as? String, !value.isEmpty { return value } }
            return ""
        }
        var lower = name.lowercased()
        // BelloCode's app tools (client MCP `bellocode_app_*`, docs/features/orchestration-extras.md) read as actions.
        if lower.hasPrefix("bellocode_app_") { lower.removeFirst("bellocode_app_".count) }
        switch lower {
        case "request_secret":
            return (.other, active ? "Asking for secret" : "Asked for secret", string("label"))
        case "secret_file":
            return (.other, active ? "Preparing one-read secret file" : "Prepared one-read secret file", "")
        case "schedule_task", "update_scheduled_task":
            return (.other, active ? "Scheduling" : lower == "schedule_task" ? "Scheduled" : "Updated schedule", string("name", "taskID"))
        case "list_scheduled_tasks":
            return (.other, active ? "Listing scheduled tasks" : "Listed scheduled tasks", "")
        case "delete_scheduled_task", "run_scheduled_task_now":
            return (.other, lower.hasPrefix("delete") ? (active ? "Deleting schedule" : "Deleted schedule") : (active ? "Running schedule" : "Ran schedule"), string("taskID"))
        case "link_merge_requests", "unlink_merge_requests":
            let refs = (input["refs"] as? [String] ?? []).map(mergeRequestLabel)
            return (.other, lower.hasPrefix("link") ? (active ? "Linking MR" : "Linked MR") : (active ? "Unlinking MR" : "Unlinked MR"), refs.joined(separator: ", "))
        case "list_thread_merge_requests":
            return (.other, active ? "Checking linked MRs" : "Checked linked MRs", "")
        case "watch_merge_request", "unwatch_merge_request":
            return (.other, lower.hasPrefix("watch") ? "Watching MR" : "Stopped watching MR", mergeRequestLabel(string("ref")))
        case "html_preview":
            return (.other, active ? "Previewing visual" : "Previewed visual", string("path"))
        case "read", "view", "cat":
            return (.read, active ? "Reading" : "Read", string("filePath", "file_path", "path"))
        case "edit", "multiedit", "str_replace":
            return (.edit, active ? "Editing" : "Edited", string("filePath", "file_path", "path"))
        case "write", "create":
            return (.edit, active ? "Writing" : "Wrote", string("filePath", "file_path", "path"))
        case "patch", "apply_patch":
            return (.edit, active ? "Patching" : "Patched", string("filePath", "path"))
        case "bash", "shell", "exec", "run", "command":
            let command = string("command", "cmd")
            return (.command, active ? "Running" : "Ran", command.split(separator: "\n").first.map(String.init) ?? command)
        case "grep", "search", "codesearch":
            return (.search, active ? "Searching for" : "Searched for", string("pattern", "query"))
        case "glob", "list", "ls", "find":
            return (.search, active ? "Listing" : "Listed", string("pattern", "path", "query"))
        case "websearch":
            return (.search, active ? "Searching the web for" : "Searched the web for", string("query"))
        case "webfetch", "fetch":
            return (.fetch, active ? "Fetching" : "Fetched", string("url"))
        default:
            let readable = name.replacingOccurrences(of: "_", with: " ")
            return (.other, readable.prefix(1).uppercased() + readable.dropFirst(), string("description", "path", "query"))
        }
    }

    /// "Edited" → "Edit" for calls that did not happen.
    static func baseVerb(_ verb: String) -> String {
        let map = [
            "Read": "Read", "Edited": "Edit", "Wrote": "Write", "Patched": "Patch", "Ran": "Run", "Searched for": "Search for",
            "Listed": "List", "Searched the web for": "Search the web for", "Fetched": "Fetch",
        ]
        return map[verb] ?? verb
    }

    static func toolItem(_ call: ToolCall, partID: PartID) -> ToolItem {
        let input = json(call.input) as? [String: Any] ?? json(RawJSON(call.inputText)) as? [String: Any] ?? [:]
        let status: ToolItemStatus =
            switch call.status {
            case .streamingInput: .preparing
            case .running: .running
            case .completed: .done
            case .failed: .failed(call.error?.message ?? "Failed")
            case .unknown(let raw): .unknown(raw)
            }
        var (category, verb, target) = describe(name: call.name, input: input, active: status.isActive)
        if case .failed = status { verb = baseVerb(verb) }
        var inputText = ""
        var isDiff = false
        if category == .command, let command = input["command"] as? String {
            inputText = "$ " + command
        } else if let old = (input["oldString"] ?? input["old_string"] ?? input["old"]) as? String,
            let new = (input["newString"] ?? input["new_string"] ?? input["new"]) as? String
        {
            inputText = diff(old: old, new: new)
            isDiff = true
        } else if !input.isEmpty,
            let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        {
            inputText = text
        } else {
            inputText = call.inputText
        }
        var output = call.outputText
        var live = false
        if status.isActive, output.isEmpty, let metadata = json(call.metadata) as? [String: Any],
            let partial = metadata["output"] as? String
        {
            output = partial
            live = true
        }
        if case .failed(let message) = status, !output.contains(message) {
            output = output.isEmpty ? message : output + "\n" + message
        }
        return ToolItem(
            id: partID, name: call.name, category: category, verb: verb, target: target, status: status,
            duration: duration(call), input: inputText, inputIsDiff: isDiff, output: output, outputIsLive: live)
    }

    /// A minimal line diff for an edit's old and new text: removed lines, then added lines.
    static func diff(old: String, new: String) -> String {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false)
        var prefix = 0
        while prefix < min(oldLines.count, newLines.count), oldLines[prefix] == newLines[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(oldLines.count, newLines.count) - prefix,
            oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix]
        {
            suffix += 1
        }
        var lines: [String] = []
        for line in oldLines[..<prefix].suffix(2) { lines.append("  " + line) }
        for line in oldLines[prefix..<(oldLines.count - suffix)] { lines.append("- " + line) }
        for line in newLines[prefix..<(newLines.count - suffix)] { lines.append("+ " + line) }
        for line in oldLines[(oldLines.count - suffix)...].prefix(2) { lines.append("  " + line) }
        return lines.joined(separator: "\n")
    }
}
