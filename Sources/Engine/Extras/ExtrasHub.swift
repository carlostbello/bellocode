import BelloCore
import Foundation
import Observation
import OpenCodeKit
import os
import Synchronization

/// The calling thread of an app tool, resolved from the call's `_meta` session ID.
public struct ExtrasCaller: Sendable, Hashable {
    public var sessionID: SessionID
    public var projectID: ProjectID
    /// The thread's own folder (a worktree or the project root).
    public var directory: String
    /// The project's root folder (schedules and grants are per project).
    public var projectDirectory: String
    public var permissionMode: PermissionMode?

    public init(sessionID: SessionID, projectID: ProjectID, directory: String, projectDirectory: String, permissionMode: PermissionMode? = nil) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.directory = directory
        self.projectDirectory = projectDirectory
        self.permissionMode = permissionMode
    }
}

/// Orchestration extras (docs/features/orchestration-extras.md): scheduled tasks, pull-request linking and watching,
/// secret requests and HTML visuals. Owns the four services, routes their app tools, and answers BelloCode's own
/// requests (secret cards, app approvals).
///
/// Threading: `@MainActor`, owned by `Engine` (`engine.extras`), started by `Engine.start()` and stopped by
/// `Engine.stop()`; each service owns and cancels its own tasks.
@MainActor
@Observable
public final class ExtrasHub {
    public let schedules: SchedulerService
    public let mergeRequests: MergeRequestService
    public let secrets: SecretService
    public let visuals: VisualService

    @ObservationIgnored private let core: EngineCore
    @ObservationIgnored private weak var engine: Engine?
    @ObservationIgnored private var archived: Set<SessionID> = []
    @ObservationIgnored private let tasks = TaskBox()
    @ObservationIgnored private let log = Logger(subsystem: "app.bellocode", category: "extras")
    @ObservationIgnored private var started = false
    /// Container execution (docs/features/containers.md): when set, secrets are delivered to commands in the project's
    /// container (`secret_exec`) instead of through a pipe on the Mac.
    @ObservationIgnored weak var environments: EnvironmentService?
    @ObservationIgnored private let containerSecrets = ContainerSecretReferences()
    @ObservationIgnored private let secretVault: any SecretVault
    @ObservationIgnored private let wallClock: any WallClock

    init(core: EngineCore, store: ProjectionStore, engine: Engine, configuration: EngineConfiguration) {
        self.core = core
        self.engine = engine
        schedules = SchedulerService(store: store, clock: configuration.wallClock)
        mergeRequests = MergeRequestService(
            store: store, clock: configuration.wallClock, transport: configuration.forgeTransport, tokens: configuration.forgeTokens,
            baseInterval: configuration.mergeRequestPoll.seconds, maxBackoff: configuration.mergeRequestMaxBackoff.seconds)
        secrets = SecretService(vault: configuration.secretVault, store: store, clock: configuration.wallClock)
        secretVault = configuration.secretVault
        wallClock = configuration.wallClock
        visuals = VisualService(store: store, directory: configuration.visualsDirectory)
        schedules.runner = self
        mergeRequests.host = self
    }

    func start(store: ProjectionStore) async {
        guard !started else { return }
        started = true
        await secrets.load()
        await visuals.load()
        let lineage = store.observe(.lineage)
        tasks.set(
            "lineage",
            Task { [weak self] in
                for await change in lineage {
                    guard let self else { return }
                    let sessions = Array(change.sessions.values)
                    for session in sessions {
                        if session.isArchived { self.archived.insert(session.id) } else { self.archived.remove(session.id) }
                    }
                    self.mergeRequests.ingest(sessions)
                    if !change.removedSessions.isEmpty { self.mergeRequests.removed(change.removedSessions) }
                }
            })
        let outputs = store.observe(.commandOutputs)
        tasks.set(
            "outputs",
            Task { [weak self] in
                for await change in outputs {
                    guard let self else { return }
                    for message in change.messages.values {
                        for hint in MergeRequestHints.commands(in: message) {
                            await self.mergeRequests.noticeCommand(partID: hint.partID, sessionID: message.sessionID, command: hint.command, output: hint.output)
                        }
                    }
                }
            })
        await mergeRequests.start()
        if engine?.configuration.startsExtras ?? true { await schedules.start() }
    }

    func stop() {
        tasks.cancelAll()
        schedules.shutdown()
        mergeRequests.shutdown()
        secrets.shutdown()
        started = false
    }

    // MARK: - Tool routing

    func handle(_ call: ClientMCPCall, caller: ExtrasCaller) async -> ClientMCPResult {
        let arguments = call.arguments
        do {
            switch call.tool {
            case ExtrasTools.scheduleTask: return try await scheduleTask(arguments, caller)
            case ExtrasTools.listScheduledTasks: return listSchedules(caller)
            case ExtrasTools.updateScheduledTask: return try await updateSchedule(arguments, caller)
            case ExtrasTools.deleteScheduledTask:
                let task = try ownTask(arguments, caller)
                try await schedules.delete(task.id)
                return ClientMCPResult(text: "Deleted scheduled task “\(task.name)”.")
            case ExtrasTools.runScheduledTaskNow:
                let task = try projectTask(arguments, caller)
                try await schedules.runNow(task.id)
                let last = schedules.task(task.id)?.lastRun
                return ClientMCPResult(text: "Ran “\(task.name)”: \(last?.label ?? "started")\(last?.sessionID.map { " in thread \($0.rawValue)" } ?? "").")
            case ExtrasTools.linkMergeRequests:
                let refs = try await mergeRequestRefs(arguments["refs"], caller)
                let links = try await mergeRequests.link(refs, to: caller.sessionID, source: .agent, watch: arguments["watch"]?.boolValue == true)
                return ClientMCPResult(text: "Linked: \(refs.map(\.description).joined(separator: ", ")). This thread has \(links.count) linked merge request(s).")
            case ExtrasTools.unlinkMergeRequests:
                let refs = try await mergeRequestRefs(arguments["refs"], caller)
                try await mergeRequests.unlink(refs, from: caller.sessionID)
                return ClientMCPResult(text: "Unlinked: \(refs.map(\.description).joined(separator: ", ")).")
            case ExtrasTools.listThreadMergeRequests: return await listMergeRequests(caller)
            case ExtrasTools.watchMergeRequest, ExtrasTools.unwatchMergeRequest:
                let refs = try await mergeRequestRefs(arguments["ref"].map { .array([$0]) }, caller)
                let watching = call.tool == ExtrasTools.watchMergeRequest
                try await mergeRequests.setWatching(refs[0], for: caller.sessionID, watching)
                return ClientMCPResult(
                    text: watching
                        ? "Watching \(refs[0]). You will be woken once per event (pipeline finished, approval given or revoked, comments, merged/closed). Do not poll; end your turn."
                        : "Stopped watching \(refs[0]).")
            case ExtrasTools.requestSecret: return try await requestSecret(arguments, caller)
            case ExtrasTools.secretFile:
                guard let reference = arguments["secretRef"]?.stringValue else { throw ExtrasError("Give secretRef.") }
                if ContainerSecretReferences.isContainerReference(reference) {
                    throw ExtrasError("Commands in this project run in a container, where a file on the Mac cannot be read. Use bellocode_app_secret_exec with this secretRef.")
                }
                let (path, label) = try secrets.redeem(reference, by: caller.sessionID)
                return ClientMCPResult(
                    text: "Path for “\(label)”: \(path)\nIt yields the value once, to the first process that reads it, then disappears (10 minutes at most). Use it in one command (--token-file \(path) or \"$(cat \(path))\"). Never print, echo or log it.")
            case ExtrasTools.secretExec: return try await secretExec(arguments, caller)
            case ExtrasTools.htmlPreview:
                let html = try visuals.document(html: arguments["html"]?.stringValue, path: arguments["path"]?.stringValue, directory: caller.directory)
                let hosts = try VisualService.validHosts(Self.stringList(arguments["allowNetwork"]))
                return ClientMCPResult(text: try await visuals.preview(html: html, hosts: hosts))
            case ExtrasTools.htmlRender: return try await htmlRender(arguments, caller)
            default:
                return .error("Unknown tool \(call.tool).")
            }
        } catch {
            return .error(ExtrasError.message(error))
        }
    }

    // MARK: Schedules

    private func scheduleTask(_ arguments: JSONValue, _ caller: ExtrasCaller) async throws -> ClientMCPResult {
        guard let name = arguments["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
            let prompt = arguments["prompt"]?.stringValue, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ExtrasError("Give name and prompt.") }
        let timeZone = try Self.timeZone(arguments["timeZone"]?.stringValue)
        guard let rule = try Self.rule(arguments, timeZone: timeZone) else { throw ExtrasError("Give everyMinutes, time (with optional weekdays) or once.") }
        var task = ScheduledTask(
            name: String(name.prefix(80)), prompt: prompt, rule: rule, timeZoneID: timeZone.identifier, directory: caller.projectDirectory,
            destination: try destination(arguments["destination"]?.stringValue, caller), agent: arguments["agent"]?.stringValue,
            model: try Self.model(arguments["model"]?.stringValue), permissionMode: try mode(arguments["permissionMode"]?.stringValue, caller),
            catchUp: arguments["catchUp"]?.boolValue ?? true, createdBy: caller.sessionID, created: schedules.clock.now())
        let approved = schedules.grantedProjects.contains(caller.projectDirectory)
        task.approval = approved ? .approved : .pending
        let created = try await schedules.create(task)
        if !approved {
            let request = AppRequest(
                id: AppRequest.makeID("sch"), sessionID: caller.sessionID,
                kind: .approval(
                    AppApproval(
                        action: .schedule, title: "Create a scheduled task",
                        detail: "“\(created.name)”: \(created.summary)\(Self.destinationText(created)).\nPrompt: \(String(created.prompt.prefix(300)))",
                        scope: caller.projectDirectory, subjectID: created.id)),
                received: .now)
            await core.putAppRequest(request)
            return ClientMCPResult(
                text: "Created “\(created.name)” (\(created.id)), paused until the user approves scheduled tasks for this project (a card is shown). Do not wait for it.")
        }
        return ClientMCPResult(text: "Scheduled “\(created.name)” (\(created.id)): \(created.summary). Next run: \(Self.dateText(created.nextRun)).")
    }

    private func listSchedules(_ caller: ExtrasCaller) -> ClientMCPResult {
        let tasks = schedules.tasks(inProject: caller.projectDirectory)
        guard !tasks.isEmpty else { return ClientMCPResult(text: "No scheduled tasks in this project.") }
        let lines = tasks.map { task in
            var parts = ["- \(task.id) “\(task.name)”: \(task.summary)\(Self.destinationText(task))"]
            parts.append(task.approval == .pending ? "waiting for approval" : task.enabled ? "next \(Self.dateText(task.nextRun))" : "paused")
            if let last = task.lastRun { parts.append("last: \(last.label)\(last.sessionID.map { " (\($0.rawValue))" } ?? "")") }
            parts.append(task.createdBy == nil ? "created by the user (read-only to agents)" : "created by an agent")
            return parts.joined(separator: "; ")
        }
        return ClientMCPResult(text: lines.joined(separator: "\n"))
    }

    private func updateSchedule(_ arguments: JSONValue, _ caller: ExtrasCaller) async throws -> ClientMCPResult {
        var task = try ownTask(arguments, caller)
        if let name = arguments["name"]?.stringValue, !name.isEmpty { task.name = String(name.prefix(80)) }
        if let prompt = arguments["prompt"]?.stringValue, !prompt.isEmpty { task.prompt = prompt }
        if arguments["timeZone"] != nil { task.timeZoneID = try Self.timeZone(arguments["timeZone"]?.stringValue).identifier }
        if let rule = try Self.rule(arguments, timeZone: task.timeZone) { task.rule = rule }
        if arguments["destination"] != nil { task.destination = try destination(arguments["destination"]?.stringValue, caller) }
        if let agent = arguments["agent"]?.stringValue { task.agent = agent.isEmpty ? nil : agent }
        if arguments["model"] != nil { task.model = try Self.model(arguments["model"]?.stringValue) }
        if arguments["permissionMode"] != nil { task.permissionMode = try mode(arguments["permissionMode"]?.stringValue, caller) }
        if let catchUp = arguments["catchUp"]?.boolValue { task.catchUp = catchUp }
        if let enabled = arguments["enabled"]?.boolValue { task.enabled = enabled }
        try await schedules.update(task)
        let updated = schedules.task(task.id) ?? task
        return ClientMCPResult(text: "Updated “\(updated.name)”: \(updated.summary); \(updated.isActive ? "next \(Self.dateText(updated.nextRun))" : updated.approval == .pending ? "waiting for approval" : "paused").")
    }

    private func projectTask(_ arguments: JSONValue, _ caller: ExtrasCaller) throws -> ScheduledTask {
        guard let id = arguments["taskID"]?.stringValue, let task = schedules.task(id), task.directory == caller.projectDirectory else {
            throw ExtrasError("No scheduled task \(arguments["taskID"]?.stringValue ?? "(missing taskID)") in this project.")
        }
        return task
    }

    /// Agents may change only agent-created tasks; the user's own are read-only to them.
    private func ownTask(_ arguments: JSONValue, _ caller: ExtrasCaller) throws -> ScheduledTask {
        let task = try projectTask(arguments, caller)
        guard task.createdBy != nil else { throw ExtrasError("“\(task.name)” was created by the user; only they can change or delete it (Settings ▸ Scheduled Tasks).") }
        return task
    }

    private func destination(_ raw: String?, _ caller: ExtrasCaller) throws -> ScheduleDestination {
        switch raw ?? "new_thread" {
        case "", "new_thread": return .newThread
        case "this_thread": return .thread(caller.sessionID)
        case let id:
            guard let node = engine?.orchestration?.node(SessionID(id))?.node, node.projectID == caller.projectID else {
                throw ExtrasError("destination must be new_thread, this_thread or a thread ID of this project.")
            }
            return .thread(node.id)
        }
    }

    private func mode(_ raw: String?, _ caller: ExtrasCaller) throws -> PermissionMode? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let mode = PermissionMode(rawValue: raw) else { throw ExtrasError("permissionMode is ask, autoEdit or fullAccess.") }
        let order: [PermissionMode] = [.ask, .autoEdit, .fullAccess]
        let own = caller.permissionMode ?? .ask
        guard order.firstIndex(of: mode)! <= order.firstIndex(of: own)! else {
            throw ExtrasError("A scheduled task cannot get a broader permission mode (\(mode.rawValue)) than this thread's (\(own.rawValue)).")
        }
        return mode
    }

    static func rule(_ arguments: JSONValue, timeZone: TimeZone) throws -> ScheduleRule? {
        if let minutes = arguments["everyMinutes"]?.numberValue {
            guard minutes >= 1, minutes <= 60 * 24 * 31 else { throw ExtrasError("everyMinutes must be between 1 and 44640.") }
            return .interval(minutes: Int(minutes.rounded()))
        }
        if let time = arguments["time"]?.stringValue {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { throw ExtrasError("time is \"HH:MM\", 24 h.") }
            let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            let weekdays = try stringList(arguments["weekdays"]).map { name -> Int in
                guard let index = names.firstIndex(of: String(name.lowercased().prefix(3))) else { throw ExtrasError("Unknown weekday \(name).") }
                return index + 1
            }
            return .daily(hour: parts[0], minute: parts[1], weekdays: weekdays.sorted())
        }
        if let once = arguments["once"]?.stringValue {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = timeZone
            guard let date = formatter.date(from: once) ?? { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter.date(from: once) }()
            else { throw ExtrasError("once must be an ISO 8601 date-time with an offset, e.g. 2026-12-01T09:00:00+01:00.") }
            return .once(date)
        }
        return nil
    }

    static func timeZone(_ raw: String?) throws -> TimeZone {
        guard let raw, !raw.isEmpty else { return .current }
        guard let zone = TimeZone(identifier: raw) else { throw ExtrasError("Unknown time zone \(raw) (use an IANA name like Europe/Madrid).") }
        return zone
    }

    static func model(_ raw: String?) throws -> ModelSelection? {
        guard let raw, !raw.isEmpty else { return nil }
        let pieces = raw.split(separator: "#", maxSplits: 1)
        let ref = pieces[0]
        guard let slash = ref.firstIndex(of: "/"), slash != ref.startIndex, ref.index(after: slash) != ref.endIndex else {
            throw ExtrasError("model is \"providerID/modelID\".")
        }
        return ModelSelection(
            providerID: String(ref[..<slash]), modelID: String(ref[ref.index(after: slash)...]), variant: pieces.count > 1 ? String(pieces[1]) : nil)
    }

    static func destinationText(_ task: ScheduledTask) -> String {
        switch task.destination {
        case .newThread: ", new thread each run"
        case .thread(let id): ", into thread \(id.rawValue)"
        }
    }

    static func dateText(_ date: Date?) -> String {
        guard let date else { return "none" }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    // MARK: Merge requests

    private func mergeRequestRefs(_ value: JSONValue?, _ caller: ExtrasCaller) async throws -> [MergeRequestRef] {
        let texts = Self.stringList(value)
        guard !texts.isEmpty, texts.count <= 10 else { throw ExtrasError("Give 1 to 10 merge requests (URL or !iid).") }
        var refs: [MergeRequestRef] = []
        for text in texts { refs.append(try await mergeRequests.resolve(text, for: caller.sessionID)) }
        return refs
    }

    private func listMergeRequests(_ caller: ExtrasCaller) async -> ClientMCPResult {
        let links = mergeRequests.links(for: caller.sessionID)
        guard !links.isEmpty else { return ClientMCPResult(text: "No merge requests are linked to this thread.") }
        var lines: [String] = []
        for link in links {
            let snapshot = await mergeRequests.refresh(link.ref) ?? mergeRequests.snapshots[link.ref.url]
            var line = "- \(link.ref.url)"
            if let snapshot {
                line += " “\(snapshot.title)”: \(snapshot.stateLabel); \(snapshot.approvals.label); \(snapshot.pipelineSummary.text); \(snapshot.unresolvedDiscussions) unresolved discussions"
                let failed = snapshot.pipeline?.jobs.filter(\.isFailure).map(\.name) ?? []
                if !failed.isEmpty { line += " (failed jobs: \(failed.prefix(6).joined(separator: ", ")))" }
            } else if let problem = mergeRequests.problems[link.ref.url] {
                line += ": \(problem)"
            }
            if link.watching { line += "; watching" }
            lines.append(line)
        }
        return ClientMCPResult(text: lines.joined(separator: "\n"))
    }

    // MARK: Secrets

    private func requestSecret(_ arguments: JSONValue, _ caller: ExtrasCaller) async throws -> ClientMCPResult {
        guard let label = arguments["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
            let reason = arguments["reason"]?.stringValue, !reason.isEmpty
        else { throw ExtrasError("Give label and reason.") }
        var url = arguments["url"]?.stringValue
        if let raw = url, URL(string: raw)?.scheme?.lowercased() != "https" { url = nil }
        let delivery = SecretPrompt.Delivery(rawValue: arguments["delivery"]?.stringValue ?? "reference") ?? .reference
        let prompt = SecretPrompt(label: String(label.prefix(80)), reason: String(reason.prefix(400)), setupURL: url, delivery: delivery)
        let request = AppRequest(id: AppRequest.makeID("sec"), sessionID: caller.sessionID, kind: .secret(prompt), received: .now)
        await core.putAppRequest(request)
        return ClientMCPResult(
            text: "Asked the user for “\(prompt.label)” in a private card. You will be woken with a message when they save it (with a one-use reference, never the value) or decline. End your turn now; do not ask for the value in chat.")
    }

    // MARK: Visuals

    private func htmlRender(_ arguments: JSONValue, _ caller: ExtrasCaller) async throws -> ClientMCPResult {
        let html = try visuals.document(html: arguments["html"]?.stringValue, path: arguments["path"]?.stringValue, directory: caller.directory)
        let title = String((arguments["title"]?.stringValue ?? "Visual").prefix(80))
        let hosts = try VisualService.validHosts(Self.stringList(arguments["allowNetwork"]))
        let result = try await visuals.render(html: html, title: title, hosts: hosts, sessionID: caller.sessionID)
        if !result.needsApproval.isEmpty {
            let request = AppRequest(
                id: AppRequest.makeID("net"), sessionID: caller.sessionID,
                kind: .approval(
                    AppApproval(
                        action: .network, title: "Let “\(title)” load from the network",
                        detail: "The visual asks to load content from: \(result.needsApproval.joined(separator: ", ")). Until you allow it, it shows without those resources.",
                        scope: result.needsApproval.joined(separator: ", "), subjectID: result.id)),
                received: .now)
            await core.putAppRequest(request)
        }
        return ClientMCPResult(text: result.text)
    }

    static func stringList(_ value: JSONValue?) -> [String] {
        guard let value else { return [] }
        if let single = value.stringValue { return [single] }
        if case .array(let items) = value { return items.compactMap(\.stringValue) }
        return []
    }

    // MARK: - App requests (the person's answers)

    /// BelloCode's own pending requests (harnesses, diagnostics).
    public func pendingAppRequests() async -> [AppRequest] { await core.appRequests() }

    /// Applies the person's answer to one of BelloCode's own requests. The request disappears only once handled; a
    /// failure leaves it pinned with `lastError` set on the service concerned.
    public func respond(to id: String, _ response: AppRequestResponse) async throws {
        guard let request = await core.appRequest(id) else { throw ExtrasError("That request was already handled.") }
        switch request.kind {
        case .secret(let prompt):
            try await respondSecret(request, prompt, response)
        case .approval(let approval):
            switch (approval.action, response) {
            case (.schedule, .approve(let always)):
                try await schedules.approve(approval.subjectID, always: always)
            case (.schedule, _):
                try await schedules.delete(approval.subjectID)
            case (.network, .approve(let always)):
                let hosts = approval.scope.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                await visuals.approveNetwork(approval.subjectID, hosts: hosts, always: always)
            case (.network, _):
                break
            }
        }
        await core.resolveAppRequest(id)
    }

    private func respondSecret(_ request: AppRequest, _ prompt: SecretPrompt, _ response: AppRequestResponse) async throws {
        let account: String
        switch response {
        case .saveSecret(let value):
            account = try await secrets.save(label: prompt.label, value: value)
        case .useSavedSecret:
            guard let saved = secrets.account(forLabel: prompt.label) else { throw ExtrasError("Nothing is saved as “\(prompt.label)”.") }
            account = saved
            await secrets.touch(account: saved)
        case .decline, .approve:
            try await core.postSynthetic(
                request.sessionID,
                text: "[BelloCode secret] The user declined to provide “\(prompt.label)”. Continue without it, or explain what cannot be done without it. Do not ask for it in chat.",
                metadata: .object(["bellocode": .object(["wake": .string("secret"), "outcome": .string("declined")])]))
            return
        }
        let text: String
        if let environments, environments.isEnabled {
            // Containerised project: a pipe on the Mac is unreachable from the container, whatever delivery was asked.
            let reference = containerSecrets.issue(account: account, label: prompt.label, for: request.sessionID, now: wallClock.now())
            text = "[BelloCode secret] The user saved “\(prompt.label)”. secretRef: \(reference) (one use, this thread, 1 hour). Commands run in this project's container: pass it to bellocode_app_secret_exec with the variable name and the one command that needs it. Never print the value."
            try await core.postSynthetic(
                request.sessionID, text: text, metadata: .object(["bellocode": .object(["wake": .string("secret"), "outcome": .string("saved")])]))
            log.info("secret delivered by container reference (value not logged)")
            return
        }
        switch prompt.delivery {
        case .reference:
            let reference = secrets.issueReference(account: account, label: prompt.label, for: request.sessionID)
            text = "[BelloCode secret] The user saved “\(prompt.label)”. secretRef: \(reference) (one use, this thread, 1 hour). Exchange it with bellocode_app_secret_file for a one-read path when you run the command that needs it. Never print the value."
        case .file:
            let path = try secrets.deliverFile(account: account)
            text = "[BelloCode secret] The user saved “\(prompt.label)”. One-read path: \(path) (yields the value once to one command within 10 minutes, then disappears). Use it as --token-file \(path) or \"$(cat \(path))\". Never print the value."
        }
        try await core.postSynthetic(
            request.sessionID, text: text, metadata: .object(["bellocode": .object(["wake": .string("secret"), "outcome": .string("saved")])]))
        log.info("secret delivered by reference or one-read path (value not logged)")
    }
}

extension ExtrasHub {
    /// `secret_exec`: one command in the caller's project container with the secret in its environment only.
    func secretExec(_ arguments: JSONValue, _ caller: ExtrasCaller) async throws -> ClientMCPResult {
        guard let environments, environments.isEnabled else {
            throw ExtrasError("This project's commands do not run in a container; use bellocode_app_secret_file.")
        }
        guard let reference = arguments["secretRef"]?.stringValue, let command = arguments["command"]?.stringValue,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let rawName = arguments["name"]?.stringValue
        else { throw ExtrasError("Give secretRef, name and command.") }
        let name = try SecretVariableName.validate(rawName)
        let entry = try containerSecrets.redeem(reference, by: caller.sessionID, now: wallClock.now())
        guard let value = try secretVault.read(account: entry.account), !value.isEmpty else {
            throw ExtrasError("“\(entry.label)” is no longer saved. Ask again with request_secret.")
        }
        await secrets.touch(account: entry.account)
        let result = try await environments.runWithSecret(directory: caller.directory, command: command, name: name, secret: value)
        log.info("secret used in one container command (value not logged)")
        return ClientMCPResult(text: "Ran in the project's container with \(name) set (exit \(result.exitCode)). Output (the value, if printed, is shown as <secret>):\n\(result.output)")
    }
}

// MARK: - The engine behind the services

extension ExtrasHub: ScheduleRunner {
    public func startThread(
        directory: String, title: String, prompt: String, agent: String?, model: ModelSelection?, permissionMode: PermissionMode?
    ) async throws -> SessionID {
        guard let engine else { throw ExtrasError("BelloCode is shutting down.") }
        let session = try await engine.createThread(in: directory, title: title, agent: agent, model: model)
        if let permissionMode { try? await engine.setPermissionMode(permissionMode, for: session.id) }
        _ = try await engine.send(prompt, to: session.id)
        return session.id
    }

    public func send(_ prompt: String, to thread: SessionID) async throws {
        guard let engine else { throw ExtrasError("BelloCode is shutting down.") }
        let running = engine.orchestration?.status(of: thread)?.isActive == true
        _ = try await engine.send(prompt, to: thread, delivery: running ? .queue : nil)
    }

    public func threadExists(_ id: SessionID) -> Bool { engine?.orchestration?.node(id) != nil }
}

extension ExtrasHub: MergeRequestHost {
    public func allSessions() async -> [Session] { await core.allSessions().sessions }

    public func writeLinks(_ sessionID: SessionID, _ transform: @escaping @Sendable ([LinkedMergeRequest]) -> [LinkedMergeRequest]) async throws -> [LinkedMergeRequest] {
        let box = LinksBox()
        try await core.mergeSessionMetadata(sessionID) { raw in
            let updated = transform(LinkedMergeRequest.decode(fromMetadata: raw))
            box.set(updated)
            return LinkedMergeRequest.encode(updated, intoMetadata: raw)
        }
        return box.value
    }

    public func wake(_ sessionID: SessionID, text: String, url: String) async throws {
        try await core.postSynthetic(
            sessionID, text: text, metadata: .object(["bellocode": .object(["wake": .string("merge_request"), "url": .string(url)])]))
    }

    public func pause(_ sessionID: SessionID) -> MergeRequestPause {
        if archived.contains(sessionID) { return .archived }
        if engine?.root.organisation[sessionID]?.settled == true { return .settled }
        return .none
    }

    public func checkout(of sessionID: SessionID) async -> (remote: String, branch: String)? {
        guard let directory = engine?.orchestration?.node(sessionID)?.node.directory else { return nil }
        let git = GitRunner()
        guard let head = try? await git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory, timeout: .seconds(5)),
            let remote = try? await git.run(["remote", "get-url", "origin"], in: directory, timeout: .seconds(5))
        else { return nil }
        return (remote.text.trimmingCharacters(in: .whitespacesAndNewlines), head.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Carries the links written inside the metadata transform back out.
private final class LinksBox: Sendable {
    private let stored = Mutex<[LinkedMergeRequest]>([])
    func set(_ value: [LinkedMergeRequest]) { stored.withLock { $0 = value } }
    var value: [LinkedMergeRequest] { stored.withLock { $0 } }
}

/// Finished shell commands in a message whose output may name a GitLab MR (for auto-linking after `git push`).
enum MergeRequestHints {
    struct Hint {
        var partID: String
        var command: String
        var output: String
    }

    static func commands(in message: Message) -> [Hint] {
        switch message.kind {
        case .shell(let shell):
            guard let output = shell.output, output.contains("/-/merge_requests/") else { return [] }
            return [Hint(partID: message.id.rawValue, command: shell.command, output: output)]
        default:
            return message.parts.compactMap { part in
                guard case .tool(let call) = part.content, call.status == .completed, ["bash", "shell"].contains(call.name) else { return nil }
                let output = call.outputText
                guard output.contains("/-/merge_requests/") else { return nil }
                let input = call.input.flatMap { try? JSONSerialization.jsonObject(with: Data($0.text.utf8)) as? [String: Any] }
                return Hint(partID: part.id.rawValue, command: input?["command"] as? String ?? "", output: output)
            }
        }
    }

    /// Whether the message is worth publishing to `.commandOutputs` (cheap check).
    static func mayContain(_ message: Message) -> Bool {
        switch message.kind {
        case .shell(let shell): return shell.output?.contains("/-/merge_requests/") == true
        default:
            return message.parts.contains { part in
                guard case .tool(let call) = part.content, call.status == .completed, ["bash", "shell"].contains(call.name) else { return false }
                return call.outputText.contains("/-/merge_requests/")
            }
        }
    }
}
