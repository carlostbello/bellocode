import BelloCore
import ContainerKit
import CryptoKit
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
    /// GitLab 2: inline review of MR diffs (versions, positioned discussions, drafts).
    public let reviews: MergeRequestReviewService
    /// GitLab 2: issues, to-dos, approval explanations, dependencies, Code Owners.
    public let gitLabWork: GitLabWorkService
    public let secrets: SecretService
    public let visuals: VisualService

    @ObservationIgnored let core: EngineCore
    @ObservationIgnored weak var engine: Engine?
    @ObservationIgnored private var archived: Set<SessionID> = []
    @ObservationIgnored private let tasks = TaskBox()
    @ObservationIgnored private let log = Logger(subsystem: "app.bellocode", category: "extras")
    @ObservationIgnored private var started = false
    /// Container execution (docs/features/containers.md): when set, secrets are delivered to commands in the project's
    /// container (`secret_exec`) instead of through a pipe on the Mac.
    @ObservationIgnored weak var environments: EnvironmentService?
    @ObservationIgnored private let containerSecrets = ContainerSecretReferences()
    /// The secret manager (docs/features/secrets.md); set by `Engine`.
    @ObservationIgnored weak var secretManager: SecretManager?
    @ObservationIgnored private let secretVault: any SecretVault
    @ObservationIgnored private let wallClock: any WallClock
    @ObservationIgnored let store: ProjectionStore
    /// Secret commands waiting for the person's approval (card), by card subject. In memory only: after a relaunch the
    /// card cannot run anything and asks the agent to request again. At most 16.
    @ObservationIgnored var pendingSecretCommands: [String: PendingSecretCommand] = [:]
    /// "Always for this command" approvals (`app_grant` kind secretCommand, scope `<account>\n<digest>`).
    @ObservationIgnored var secretCommandGrants: Set<String> = []
    /// GitLab changes agents asked for, waiting on their cards (in memory; at most 16).
    @ObservationIgnored var pendingGitLabWrites: [String: PendingGitLabWrite] = [:]
    /// Pushes agents asked for, waiting on their cards (git parity; in memory, at most 8).
    @ObservationIgnored var pendingGitPushes: [String: PendingGitPush] = [:]
    /// Projects where agents may babysit merge requests without asking (`app_grant` kind gitlabBabysit).
    @ObservationIgnored var babysitGrants: Set<String> = []

    init(core: EngineCore, store: ProjectionStore, engine: Engine, configuration: EngineConfiguration) {
        self.core = core
        self.store = store
        self.engine = engine
        schedules = SchedulerService(store: store, clock: configuration.wallClock)
        mergeRequests = MergeRequestService(
            store: store, clock: configuration.wallClock, transport: configuration.forgeTransport, tokens: configuration.forgeTokens,
            baseInterval: configuration.mergeRequestPoll.seconds, maxBackoff: configuration.mergeRequestMaxBackoff.seconds)
        reviews = MergeRequestReviewService(mergeRequests: mergeRequests, store: store)
        gitLabWork = GitLabWorkService(mergeRequests: mergeRequests)
        secrets = SecretService(vault: configuration.secretVault, store: store, clock: configuration.wallClock)
        secretVault = configuration.secretVault
        wallClock = configuration.wallClock
        visuals = VisualService(store: store, directory: configuration.visualsDirectory)
        schedules.runner = self
        mergeRequests.host = self
        gitLabWork.host = self
        schedules.needsApproval = { [weak self] task in await self?.raiseScheduleCard(task, requestedBy: nil) }
    }

    func start(store: ProjectionStore) async {
        guard !started else { return }
        started = true
        await secrets.load()
        await visuals.load()
        secretCommandGrants = (try? await store.grants(.secretCommand)) ?? []
        babysitGrants = (try? await store.grants(.gitlabBabysit)) ?? []
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
                    self.gitLabWork.ingest(sessions)
                    if !change.removedSessions.isEmpty {
                        self.mergeRequests.removed(change.removedSessions)
                        self.gitLabWork.removed(change.removedSessions)
                    }
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
        if engine?.configuration.startsExtras ?? true {
            // Definitions load now (shown at once); dispatch is armed by the first successful reconcile (C7).
            let connection = store.observe(.connection)
            tasks.set(
                "schedule-arming",
                Task { [weak self] in
                    for await change in connection {
                        guard let self else { return }
                        guard let status = change.connection ?? (change.overflowed ? self.engine?.root.connection : nil) else { continue }
                        await self.schedules.setDispatchArmed(status == .live)
                    }
                })
            await schedules.start(armed: engine?.root.connection == .live)
            // Every agent task waiting for approval has a card (after a relaunch, a migration or a crash in between).
            let cards = Set(await scheduleCards().map(\.subjectID))
            for task in schedules.tasks where task.approval == .pending && task.createdBy != nil && !cards.contains(task.id) {
                await raiseScheduleCard(task, requestedBy: nil)
            }
        }
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
                let links = try await mergeRequests.link(refs, to: caller.sessionID, source: .agent)
                var text = "Linked: \(refs.map(\.description).joined(separator: ", ")). This thread has \(links.count) linked merge request(s)."
                if arguments["watch"]?.boolValue == true { text += " " + (try await requestBabysit(refs, caller)) }
                return ClientMCPResult(text: text)
            case ExtrasTools.unlinkMergeRequests:
                let refs = try await mergeRequestRefs(arguments["refs"], caller)
                try await mergeRequests.unlink(refs, from: caller.sessionID)
                return ClientMCPResult(text: "Unlinked: \(refs.map(\.description).joined(separator: ", ")).")
            case ExtrasTools.listThreadMergeRequests: return await listMergeRequests(caller)
            case ExtrasTools.watchMergeRequest, ExtrasTools.unwatchMergeRequest:
                let refs = try await mergeRequestRefs(arguments["ref"].map { .array([$0]) }, caller)
                guard call.tool == ExtrasTools.watchMergeRequest else {
                    try await mergeRequests.setWatching(refs[0], for: caller.sessionID, false)
                    return ClientMCPResult(text: "Stopped babysitting \(refs[0]).")
                }
                if !mergeRequests.links(for: caller.sessionID).contains(where: { $0.ref == refs[0] }) {
                    try await mergeRequests.link(refs, to: caller.sessionID, source: .agent)
                }
                return ClientMCPResult(text: try await requestBabysit(refs, caller))
            case ExtrasTools.requestSecret: return try await requestSecret(arguments, caller)
            case ExtrasTools.secretFile:
                guard let reference = arguments["secretRef"]?.stringValue else { throw ExtrasError("Give secretRef.") }
                if ContainerSecretReferences.isContainerReference(reference) {
                    throw ExtrasError("Commands in this project run in a container, where a file on the Mac cannot be read. Use bellocode_app_secret_exec with this secretRef.")
                }
                let project = caller.projectDirectory
                let (path, label) = try secrets.redeem(reference, by: caller.sessionID) { [weak self] account in
                    self?.commandRevision(account: account, projectDirectory: project)
                }
                return ClientMCPResult(
                    text: "Path for “\(label)”: \(path)\nIt yields the value once, to the first process that reads it, then disappears (10 minutes at most). Use it in one command (--token-file \(path) or \"$(cat \(path))\"). Never print, echo or log it.")
            case ExtrasTools.secretExec: return try await secretExec(arguments, caller)
            case ExtrasTools.httpRequest:
                guard let secretManager else { throw ExtrasError("The secret manager is not running.") }
                return await secretManager.httpRequest(arguments, caller: caller)
            case ExtrasTools.listSecrets:
                guard let secretManager else { throw ExtrasError("The secret manager is not running.") }
                return secretManager.listSecrets(caller: caller)
            case ExtrasTools.htmlPreview:
                let html = try visuals.document(
                    html: arguments["html"]?.stringValue, path: arguments["path"]?.stringValue, directory: caller.directory, roots: visualRoots(caller))
                let hosts = try VisualService.validHosts(Self.stringList(arguments["allowNetwork"]))
                return ClientMCPResult(text: try await visuals.preview(html: html, hosts: hosts))
            case ExtrasTools.htmlRender: return try await htmlRender(arguments, caller)
            case let tool where GitLabTools.all.contains(tool):
                return try await handleGitLab(call, caller: caller)
            case GitPushTool.push: return try await handleGitPush(arguments, caller)
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
            await raiseScheduleCard(created, requestedBy: caller.sessionID)
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
        // An agent's change never keeps the approval: a changed definition (or turning it back on) waits for the user.
        let waits = try await schedules.update(task, consent: false)
        let updated = schedules.task(task.id) ?? task
        if waits {
            await raiseScheduleCard(updated, requestedBy: caller.sessionID)
            return ClientMCPResult(
                text: "Changed “\(updated.name)”. It does not run until the user approves the change (a card shows the before and after). Do not wait for it.")
        }
        return ClientMCPResult(text: "Updated “\(updated.name)”: \(updated.summary); \(updated.isActive ? "next \(Self.dateText(updated.nextRun))" : updated.approval == .pending ? "waiting for approval" : "paused").")
    }

    /// Pending schedule approval cards.
    private func scheduleCards() async -> [AppApproval] {
        await core.appRequests().compactMap { request in
            if case .approval(let approval) = request.kind, approval.action == .schedule { approval } else { nil }
        }
    }

    /// Replaces any card for `task` with one for its current definition: the whole definition for a new task, the
    /// before/after for a change to an approved one. The card carries the definition's digest; approving applies only
    /// to exactly that content.
    func raiseScheduleCard(_ task: ScheduledTask, requestedBy: SessionID?) async {
        for request in await core.appRequests() {
            if case .approval(let approval) = request.kind, approval.action == .schedule, approval.subjectID == task.id {
                await core.resolveAppRequest(request.id)
            }
        }
        let current = task.definition
        let by = (requestedBy ?? task.createdBy).map { " Asked by thread \($0.rawValue)." } ?? ""
        let title: String
        var detail: String
        if let approved = task.approved {
            let changes = approved.changes(to: current)
            title = changes.isEmpty ? "Turn a scheduled task back on" : "Change a scheduled task"
            detail = "“\(task.name)” (\(task.summary)\(Self.destinationText(task))). Approved before; an agent \(changes.isEmpty ? "turned it back on" : "changed it").\(by)"
            if !changes.isEmpty { detail += "\n" + changes.joined(separator: "\n") }
            detail += "\nDeny keeps the version you approved."
        } else {
            title = "Create a scheduled task"
            detail = "“\(task.name)”: \(task.summary)\(Self.destinationText(task)); agent \(task.agent ?? "default"), model \(task.model.map { "\($0.providerID)/\($0.modelID)" } ?? "default"), permission mode \(task.permissionMode?.rawValue ?? "default").\(by)\nPrompt: \(String(task.prompt.prefix(300)))"
        }
        let request = AppRequest(
            id: AppRequest.makeID("sch"), sessionID: requestedBy ?? task.createdBy ?? SessionID(""),
            kind: .approval(
                AppApproval(
                    action: .schedule, title: title, detail: detail, scope: task.directory, subjectID: task.id, allowsAlways: task.approved == nil,
                    digest: current.digest)),
            received: .now)
        await core.putAppRequest(request)
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
        guard let mode = PermissionMode(rawValue: raw) else { throw ExtrasError("permissionMode is ask, autoEdit, auto or fullAccess.") }
        let order: [PermissionMode] = [.ask, .autoEdit, .auto, .fullAccess]
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
                line += " “\(snapshot.title)”: \(snapshot.stateLabel); \(snapshot.approvals.label); \(snapshot.pipelineSummary.text); \(snapshot.unresolvedText)"
                if let note = snapshot.truncationNote { line += " (\(note))" }
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
        func field(_ key: String, _ limit: Int = 200) -> String { String((arguments[key]?.stringValue ?? "").prefix(limit)) }
        let destination = field("destination")
        let proposed = SecretChoice.Mode(rawValue: field("mode")) ?? (destination.isEmpty ? .command : .placeholder)
        let suggestion = SecretChoice(
            mode: proposed == .visible ? .command : proposed, name: field("name", 64), destination: destination, headerName: field("header", 64),
            headerPrefix: field("prefix", 32), queryName: field("query", 64), pathPrefix: field("path"), projectOnly: true)
        let prompt = SecretPrompt(label: String(label.prefix(80)), reason: String(reason.prefix(400)), setupURL: url, delivery: delivery,
                                  suggestion: suggestion, projectDirectory: caller.projectDirectory)
        let request = AppRequest(id: AppRequest.makeID("sec"), sessionID: caller.sessionID, kind: .secret(prompt), received: .now)
        await core.putAppRequest(request)
        return ClientMCPResult(
            text: "Asked the user for “\(prompt.label)” in a private card. You will be woken with a message when they save it (with a one-use reference, never the value) or decline. End your turn now; do not ask for the value in chat.")
    }

    // MARK: Visuals

    /// Where a visual may read a file: the calling thread's project and its worktree folders (S6).
    func visualRoots(_ caller: ExtrasCaller) -> [String] {
        var roots = [caller.projectDirectory, caller.directory]
        if let environments { roots += environments.workspaceRoots(environments.environment(for: caller.projectDirectory), create: false) }
        return roots
    }

    private func htmlRender(_ arguments: JSONValue, _ caller: ExtrasCaller) async throws -> ClientMCPResult {
        let html = try visuals.document(
                    html: arguments["html"]?.stringValue, path: arguments["path"]?.stringValue, directory: caller.directory, roots: visualRoots(caller))
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
                do {
                    try await schedules.approve(approval.subjectID, digest: approval.digest, always: always && approval.allowsAlways)
                } catch {
                    // A stale card (the task changed, or was deleted): it can never apply, so it goes; the current
                    // version has its own card.
                    await core.resolveAppRequest(id)
                    if let task = schedules.task(approval.subjectID), task.approval == .pending,
                       !(await scheduleCards().contains { $0.subjectID == task.id })
                    {
                        await raiseScheduleCard(task, requestedBy: nil)
                    }
                    throw error
                }
            case (.schedule, _):
                // Deny: a change goes back to the approved version; a task never approved is deleted.
                if try await schedules.revertToApproved(approval.subjectID) == nil { try await schedules.delete(approval.subjectID) }
            case (.network, .approve(let always)):
                let hosts = approval.scope.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                await visuals.approveNetwork(approval.subjectID, hosts: hosts, always: always)
            case (.network, _):
                break
            case (.secretCommand, .approve(let always)):
                await core.resolveAppRequest(id)
                try await approveSecretCommand(approval, always: always)
                return
            case (.gitlabWrite, _):
                await core.resolveAppRequest(id)
                try await respondGitLabWrite(approval, response)
                return
            case (.gitPush, _), (.gitForcePush, _):
                await core.resolveAppRequest(id)
                try await respondGitPush(approval, response)
                return
            case (.gitlabBabysit, _):
                try await respondBabysit(approval, response)
            case (.serviceRestart, let response):
                // Project services (docs/features/containers.md): handled by the engine's container tools.
                await core.resolveAppRequest(id)
                if case .approve(let always) = response {
                    await engine?.answerServiceRestart(approval, approved: true, always: always)
                } else {
                    await engine?.answerServiceRestart(approval, approved: false, always: false)
                }
                return
            case (.browserMCP, let response):
                // Shared browser (docs/features/shared-browser.md): the person allows the browse MCP server.
                await core.resolveAppRequest(id)
                if case .approve(let always) = response {
                    await engine?.sharedBrowser?.answerApproval(approval, approved: true, always: always)
                } else {
                    await engine?.sharedBrowser?.answerApproval(approval, approved: false, always: false)
                }
                return
            case (.secretCommand, _):
                await core.resolveAppRequest(id)
                if let pending = pendingSecretCommands.removeValue(forKey: approval.subjectID) {
                    try await core.postSynthetic(
                        pending.sessionID,
                        text: "[BelloCode secret] The user did not allow “\(pending.label)” to be given to that command. It did not run. Do not retry the same command; explain what you need instead.",
                        metadata: .object(["bellocode": .object(["wake": .string("secret"), "outcome": .string("command_declined")])]))
                }
                return
            }
        }
        await core.resolveAppRequest(id)
    }

    private func respondSecret(_ request: AppRequest, _ prompt: SecretPrompt, _ response: AppRequestResponse) async throws {
        let account: String
        switch response {
        case .saveManagedSecret(let value, let choice):
            guard let secretManager else { throw ExtrasError("The secret manager is not running.") }
            let text = try await secretManager.saveFromCard(prompt, value: value, choice: choice, sessionID: request.sessionID)
            if !text.isEmpty {
                try await core.postSynthetic(
                    request.sessionID, text: text, metadata: .object(["bellocode": .object(["wake": .string("secret"), "outcome": .string("saved")])]))
                log.info("managed secret saved; the thread got a handle or placeholder (value not logged)")
                return
            }
            // Command mode: the approved-command path below, with the value already saved.
            guard let saved = secrets.account(forLabel: prompt.label) else { throw ExtrasError("“\(prompt.label)” was not saved.") }
            account = saved
        case .saveSecret(let value):
            account = try await secrets.save(label: prompt.label, value: value)
            await secretManager?.reload()
        case .useSavedSecret:
            if let secretManager, let text = try await secretManager.useSaved(label: prompt.label, sessionID: request.sessionID, projectDirectory: prompt.projectDirectory) {
                try await core.postSynthetic(
                    request.sessionID, text: text, metadata: .object(["bellocode": .object(["wake": .string("secret"), "outcome": .string("saved")])]))
                return
            }
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
        // Only a secret that commands may receive now (commands-only or visible, not revoked, in scope) gets a reference,
        // bound to its current policy revision (R03).
        let projectDirectory = prompt.projectDirectory ?? engine?.orchestration?.node(request.sessionID)?.node.directory
        guard let revision = commandRevision(account: account, projectDirectory: projectDirectory) else {
            try await core.postSynthetic(
                request.sessionID,
                text: "[BelloCode secret] “\(prompt.label)” is protected (brokered, placeholder or revoked) or not available to this project, so it cannot be given to commands. Use the handle or placeholder BelloCode gave you, or ask the user.",
                metadata: .object(["bellocode": .object(["wake": .string("secret"), "outcome": .string("declined")])]))
            return
        }
        let text: String
        if let environments, environments.isEnabled {
            // Containerised project: a pipe on the Mac is unreachable from the container, whatever delivery was asked.
            let reference = containerSecrets.issue(account: account, label: prompt.label, for: request.sessionID, now: wallClock.now(), revision: revision)
            text = "[BelloCode secret] The user saved “\(prompt.label)” for approved commands only. secretRef: \(reference) (one use, this thread, 1 hour). Commands run in this project's container: pass it to bellocode_app_secret_exec with the variable name and the one command that needs it; the user approves that exact command before it receives the value (that command can see it). Never print the value."
            try await core.postSynthetic(
                request.sessionID, text: text, metadata: .object(["bellocode": .object(["wake": .string("secret"), "outcome": .string("saved")])]))
            log.info("secret delivered by container reference (value not logged)")
            return
        }
        switch prompt.delivery {
        case .reference:
            let reference = secrets.issueReference(account: account, label: prompt.label, for: request.sessionID, revision: revision)
            text = "[BelloCode secret] The user saved “\(prompt.label)”. secretRef: \(reference) (one use, this thread, 1 hour). Exchange it with bellocode_app_secret_file for a one-read path when you run the command that needs it. Never print the value."
        case .file:
            // Delivered now: re-checked immediately before the value is read.
            guard commandRevision(account: account, projectDirectory: projectDirectory) == revision else { throw ExtrasError("“\(prompt.label)” changed; nothing was delivered.") }
            let path = try secrets.deliverFile(account: account)
            text = "[BelloCode secret] The user saved “\(prompt.label)”. One-read path: \(path) (yields the value once to one command within 10 minutes, then disappears). Use it as --token-file \(path) or \"$(cat \(path))\". Never print the value."
        }
        try await core.postSynthetic(
            request.sessionID, text: text, metadata: .object(["bellocode": .object(["wake": .string("secret"), "outcome": .string("saved")])]))
        log.info("secret delivered by reference or one-read path (value not logged)")
    }
}

/// A command an agent asked to run with a saved secret, waiting for the person's approval.
struct PendingSecretCommand: Sendable {
    var account: String
    var label: String
    var sessionID: SessionID
    var directory: String
    var projectDirectory: String
    var name: String
    var command: String
    var policy: SecretCommandPolicy
    var digest: String
    /// The secret's command-policy revision the approval is for (R03).
    var revision: String
}

extension ExtrasHub {
    /// The approval binding: secret (Keychain account) and its command-policy revision, project, variable, the exact
    /// command and its policy. The revision (R03) makes a saved "Always" approval end with any change of the secret's
    /// mode, scope, revocation or value.
    static func secretCommandDigest(account: String, revision: String = "", projectDirectory: String, name: String, command: String, policy: SecretCommandPolicy) -> String {
        var parts = [account, projectDirectory, name, command, policy.network ? "network" : "offline", policy.writesProject ? "writes" : "read-only"]
        // Optional mounts are part of what is approved (S5).
        if !policy.mounts.isEmpty { parts.append("mounts:" + policy.canonicalMounts.joined(separator: ",")) }
        if !revision.isEmpty { parts.append("revision:" + revision) }
        return SHA256Hex.of(parts.joined(separator: "\u{1F}"))
    }

    /// The secret's current command-policy revision, or nil when commands may not receive it now (R03). Without a
    /// secret manager (tests of the legacy path alone) no protected mode exists, so the legacy secret is usable.
    func commandRevision(account: String, projectDirectory: String?) -> String? {
        guard let secretManager else { return secrets.labels.contains { $0.account == account } ? "unmanaged" : nil }
        return secretManager.commandRevision(account: account, projectDirectory: projectDirectory)
    }

    /// `secret_exec` (C3 in docs/reviews/M3-M6-review.md). The agent names the command, so the agent controls what
    /// happens to the value; redaction of the output cannot stop a command that encodes, splits, stores or sends it. So
    /// the person approves the exact command first (card: secret label, project, variable, the command verbatim,
    /// network and write access), unless they approved exactly this before ("Always for This Command"). The command
    /// runs in a one-shot sibling container: no network and a read-only project unless the agent asked and the card
    /// said so. The thread is woken with the (redacted, bounded) output.
    func secretExec(_ arguments: JSONValue, _ caller: ExtrasCaller) async throws -> ClientMCPResult {
        guard let environments, environments.isEnabled else {
            throw ExtrasError("This project's commands do not run in a container; use bellocode_app_secret_file.")
        }
        guard let reference = arguments["secretRef"]?.stringValue, let command = arguments["command"]?.stringValue,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let rawName = arguments["name"]?.stringValue
        else { throw ExtrasError("Give secretRef, name and command.") }
        guard command.utf8.count <= 4_000 else { throw ExtrasError("The command is too long to show for approval (4000 bytes at most).") }
        let name = try SecretVariableName.validate(rawName)
        // Optional host mounts only when asked for, and then exactly as configured now, each listed on the card (S5).
        let mounts = arguments["includeMounts"]?.boolValue == true
            ? environments.environment(for: caller.projectDirectory).settings.userMounts : []
        let policy = SecretCommandPolicy(
            network: arguments["network"]?.boolValue ?? false, writesProject: arguments["writesProject"]?.boolValue ?? false, mounts: mounts)
        let entry = try containerSecrets.redeem(reference, by: caller.sessionID, now: wallClock.now())
        guard let revision = commandRevision(account: entry.account, projectDirectory: caller.projectDirectory), revision == entry.revision else {
            throw ExtrasError("“\(entry.label)” changed since this secretRef was issued (its protection, scope or value), or is not available to this project. Nothing ran; ask again with request_secret.")
        }
        let digest = Self.secretCommandDigest(account: entry.account, revision: revision, projectDirectory: caller.projectDirectory, name: name, command: command, policy: policy)
        let pending = PendingSecretCommand(
            account: entry.account, label: entry.label, sessionID: caller.sessionID, directory: caller.directory,
            projectDirectory: caller.projectDirectory, name: name, command: command, policy: policy, digest: digest, revision: revision)
        if secretCommandGrants.contains(entry.account + "\n" + digest) {
            let text = try await runSecretCommand(pending)
            return ClientMCPResult(text: text)
        }
        if pendingSecretCommands.count >= 16, let oldest = pendingSecretCommands.keys.sorted().first { pendingSecretCommands[oldest] = nil }
        let id = AppRequest.makeID("scmd")
        pendingSecretCommands[id] = pending
        var access = [policy.network ? "network ON" : "no network", policy.writesProject ? "can write the project" : "project read-only"]
        access.append(policy.mounts.isEmpty
            ? "no extra folders"
            : "extra folders: " + policy.mounts.map { "\($0.path) (\($0.readOnly ? "read-only" : "read-write"))" }.joined(separator: ", "))
        let request = AppRequest(
            id: AppRequest.makeID("sec"), sessionID: caller.sessionID,
            kind: .approval(
                AppApproval(
                    action: .secretCommand, title: "Give “\(entry.label)” to a command",
                    detail: "Secret: “\(entry.label)” as $\(name)\nRuns in: \(caller.directory) (one-shot container: \(access.joined(separator: ", ")))\nCommand:\n\(command)",
                    scope: caller.projectDirectory, subjectID: id, allowsAlways: true, digest: digest)),
            received: .now)
        await core.putAppRequest(request)
        return ClientMCPResult(
            text: "Asked the user to approve this exact command for “\(entry.label)” (a card shows it). If they allow it, it runs and you are woken with its output; if not, you are told. End your turn now.")
    }

    private func approveSecretCommand(_ approval: AppApproval, always: Bool) async throws {
        guard let pending = pendingSecretCommands.removeValue(forKey: approval.subjectID), approval.digest == pending.digest else {
            throw ExtrasError("This request is no longer pending (BelloCode was restarted, or it was answered). Nothing ran; the agent can ask again.")
        }
        if always {
            let scope = pending.account + "\n" + pending.digest
            try await store.setGrant(.secretCommand, scope: scope, granted: true)
            secretCommandGrants.insert(scope)
        }
        let text: String
        do {
            text = try await runSecretCommand(pending)
        } catch {
            text = "[BelloCode secret] The approved command for “\(pending.label)” could not run: \(ExtrasError.message(error))"
        }
        try await core.postSynthetic(
            pending.sessionID, text: text.hasPrefix("[BelloCode secret]") ? text : "[BelloCode secret] " + text,
            metadata: .object(["bellocode": .object(["wake": .string("secret"), "outcome": .string("command_ran")])]))
    }

    /// Runs an approved secret command and describes the result (never the value: verbatim occurrences are replaced,
    /// which is a display courtesy, not a guarantee; the approval is the guarantee).
    private func runSecretCommand(_ pending: PendingSecretCommand) async throws -> String {
        guard let environments else { throw ExtrasError("Container execution is off.") }
        // Reauthorized immediately before the value is read: the approval covered the secret as it was (R03).
        guard commandRevision(account: pending.account, projectDirectory: pending.projectDirectory) == pending.revision else {
            throw ExtrasError("“\(pending.label)” changed since this command was approved (its protection, scope or value). Nothing ran; ask again with request_secret.")
        }
        guard let value = try secretVault.read(account: pending.account), !value.isEmpty else {
            throw ExtrasError("“\(pending.label)” is no longer saved. Ask again with request_secret.")
        }
        // The container gets exactly the approved mounts: refused if the project's setting no longer allows one as
        // approved (removed, or made read-only since).
        let configured = environments.environment(for: pending.projectDirectory).settings.userMounts
        for mount in pending.policy.mounts {
            let path = (mount.path as NSString).standardizingPath
            guard let current = configured.first(where: { ($0.path as NSString).standardizingPath == path }), mount.readOnly || !current.readOnly else {
                throw ExtrasError("The project's extra folders changed since this command was approved (\(mount.path)). Nothing ran; ask again.")
            }
        }
        await secrets.touch(account: pending.account)
        let result = try await environments.runWithSecret(
            directory: pending.directory, command: pending.command, name: pending.name, secret: value, policy: pending.policy)
        log.info("secret used in one approved container command (value not logged)")
        let truncated = result.truncated ? " Output was longer than the limit: the middle is omitted (marked)." : ""
        return "Ran the approved command with $\(pending.name) set to “\(pending.label)” (exit \(result.exitCode)).\(truncated) Output:\n\(result.output)"
    }
}

/// Hex SHA-256 of a string.
enum SHA256Hex {
    static func of(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - The engine behind the services

extension ExtrasHub: ScheduleRunner {
    public func startThread(
        directory: String, title: String, prompt: String, agent: String?, model: ModelSelection?, permissionMode: PermissionMode?
    ) async throws -> SessionID {
        guard let engine else { throw ExtrasError("BelloCode is shutting down.") }
        // The approved mode is part of the creation and confirmed by the server; on any failure nothing is sent (S2).
        let session = try await engine.createThread(in: directory, title: title, agent: agent, model: model, permissionMode: permissionMode)
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

    /// Looks for the wake's ID in the thread's recent synthetic messages on the server.
    public func wakeDelivered(_ sessionID: SessionID, wakeID: String) async -> Bool? {
        guard let client = try? await core.currentClient(),
            let page = try? await client.messages(sessionID: sessionID.rawValue, MessageListQuery(limit: 100, order: .descending, type: "synthetic"))
        else { return nil }
        return page.data.contains { message in
            guard case .other(_, _, let raw) = message else { return false }
            return raw["text"]?.stringValue?.contains(wakeID) == true
        }
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

extension ExtrasHub: GitLabWorkHost {
    public func writeIssueLinks(_ sessionID: SessionID, _ transform: @escaping @Sendable ([LinkedIssue]) -> [LinkedIssue]) async throws -> [LinkedIssue] {
        let box = IssueLinksBox()
        try await core.mergeSessionMetadata(sessionID) { raw in
            let updated = transform(LinkedIssue.decode(fromMetadata: raw))
            box.set(updated)
            return LinkedIssue.encode(updated, intoMetadata: raw)
        }
        return box.value
    }
}

private final class IssueLinksBox: Sendable {
    private let stored = Mutex<[LinkedIssue]>([])
    func set(_ value: [LinkedIssue]) { stored.withLock { $0 = value } }
    var value: [LinkedIssue] { stored.withLock { $0 } }
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
