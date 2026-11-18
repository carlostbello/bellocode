import BelloCore
import Foundation
import Observation
import OpenCodeKit
import os

/// BelloCode's Auto mode and Full-access risk visibility (docs/features/auto-mode.md). `engine.auto`.
///
/// Auto: every permission request of an Auto session is held in the projection's triage set (not shown, not counted)
/// until this service decides. The deterministic `RiskPolicy` refuses, escalates (the request moves into the visible
/// pending list with its reason: the existing pinned card and Needs-you count) or allows; the rest goes to the
/// isolated reviewer. Approvals reply `once`, never `always`, bound to the request ID, the exact input hash, the
/// policy version and the session's execution (a result for a request that left triage, a session that left Auto or
/// a new run is discarded and the person decides). Every decision is audited (no content).
///
/// Full access: the reducer runs the same detectors on tool calls (`ToolCall.risk.notices`, shown in the transcript);
/// this service audits them and keeps the unreviewed ones per thread for Needs you (non-blocking).
@MainActor
@Observable
public final class AutoModeService {
    /// Settings for the reviewer (persisted in `app_preference` under `auto.reviewer`).
    public private(set) var settings: AutoReviewer.Settings = .standard
    /// The model reviews use now (`settings.model`, else a fast free catalogue model, else the server's default).
    public var reviewerModel: ModelRef? {
        AutoReviewer.modelRef(settings.model) ?? AutoReviewer.defaultModel(from: engine?.root.catalog.current?.models ?? [])
    }
    /// Unreviewed Full-access notices per thread (newest last), for Needs you. Reviewing clears them.
    public private(set) var unreviewed: [SessionID: [Notice]] = [:]
    /// Notices that could not be listed because too many arrived at once (shown, never silent).
    public private(set) var droppedNotices = 0
    /// Requests being decided now (diagnostics; the UI shows "Auto is checking…" for these).
    public private(set) var deciding: Set<PermissionRequestID> = []
    /// Audit entries loaded per thread (newest first), refreshed as decisions are made.
    public private(set) var audit: [SessionID: [AutoAuditEntry]] = [:]

    public struct Notice: Hashable, Sendable, Identifiable {
        public var id: String
        public var sessionID: SessionID
        public var messageID: MessageID
        public var callID: String
        public var tool: String
        public var finding: RiskFinding
        public var stage: String
        public var at: Timestamp
    }

    public static let noticesPerThread = 50
    public static let maxInFlight = 64

    private let core: EngineCore
    private let store: ProjectionStore
    private weak var engine: Engine?
    private let reviewer: AutoReviewer
    private let tasks = TaskBox()
    private var inFlight: [PermissionRequestID: Task<Void, Never>] = [:]
    private var savedGrants: [ProjectID: (rules: [SavedPermission], at: ContinuousClock.Instant)] = [:]
    private let clock = ContinuousClock()
    private let log = Logger(subsystem: "app.bellocode", category: "auto")

    init(core: EngineCore, store: ProjectionStore, engine: Engine, reviewerModel: (any AutoReviewer.Model)? = nil) {
        self.core = core
        self.store = store
        self.engine = engine
        self.reviewer = AutoReviewer(backend: reviewerModel ?? OpenCodeReviewModel(client: { [core] in try await core.currentClient() }))
    }

    func start() {
        tasks.set("load", Task { [weak self] in await self?.loadSettings() })
        tasks.set("triage", Task { [weak self, core] in
            let signals = await core.autoTriageSignals()
            for await _ in signals {
                guard let self, !Task.isCancelled else { return }
                await self.drain()
            }
        })
    }

    func shutdown() {
        tasks.cancelAll()
        auditWriter?.cancel()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    // MARK: Settings

    private static let settingsKey = "auto.reviewer"

    private func loadSettings() async {
        if let saved = try? await store.preference(Self.settingsKey, as: AutoReviewer.Settings.self) {
            settings = saved
            await reviewer.update(saved)
        }
    }

    public func updateSettings(_ new: AutoReviewer.Settings) async {
        settings = new
        await reviewer.update(new)
        try? await store.setPreference(Self.settingsKey, new)
    }

    // MARK: Triage

    private func drain() async {
        let requests = await core.takeAutoTriage()
        for request in requests where inFlight[request.id] == nil {
            if inFlight.count >= Self.maxInFlight {
                await core.escalateAutoRequest(request.id, escalation(source: .policy, code: "auto_busy", text: "Auto has too many requests at once, so you decide."))
                continue
            }
            let id = request.id
            deciding.insert(id)
            inFlight[id] = Task { [weak self] in
                await self?.decide(id)
                self?.finish(id)
            }
        }
        let notices = await core.takeRiskNotices()
        if !notices.events.isEmpty || notices.dropped > 0 { record(notices.events, dropped: notices.dropped) }
    }

    private func finish(_ id: PermissionRequestID) {
        inFlight[id] = nil
        deciding.remove(id)
    }

    /// Decides one request (internal for tests).
    func decide(_ id: PermissionRequestID) async {
        let signpost = EngineSignposts.auto.beginInterval("auto.decide")
        defer { EngineSignposts.auto.endInterval("auto.decide", signpost) }
        guard let context = await core.autoContext(for: id) else { return }
        let session = context.session
        guard session.permissionMode == .auto else {
            await core.escalateAutoRequest(id, nil)
            return
        }
        let started = clock.now
        let policyContext = Self.policyContext(context)
        let action = Self.action(context)
        let verdict = RiskPolicy.decide(action, in: policyContext)
        switch verdict {
        case .deny(let finding):
            let text = "BelloCode Auto refused this: \(finding.askingText). It targets BelloCode's isolation or credential stores."
            do {
                try await core.replyAutoRequest(id, reply: .reject, message: text)
                append(entry(context, .denied, source: .policy, findings: [finding], code: "policy_violation", text: text, started: started))
            } catch {
                await escalate(id, context, escalation(findings: [finding], source: .policy, code: "policy_violation", text: finding.askingText), started)
            }
        case .escalate(let findings):
            await escalate(id, context, escalation(findings: findings, source: .policy, code: findings[0].category.rawValue, text: findings[0].askingText), started)
        case .allow(let code, let text):
            await approve(id, context, source: .policy, code: code, text: text, model: nil, started: started)
        case .review(let note):
            if await savedGrantCovers(context) {
                await approve(id, context, source: .savedGrant, code: "saved_grant", text: "Covered by a scope you saved with Always allow", model: nil, started: started)
                return
            }
            let input = AutoReviewer.Input.make(action: action, context: policyContext, purpose: context.threadTitle, note: note)
            let model = reviewerModel
            let result = await reviewer.review(input, model: model)
            // Binding: the same request, still waiting, same input, same policy, same run of a session still in Auto.
            guard !Task.isCancelled else { return }
            guard await core.isInAutoTriage(id), let now = await core.autoContext(for: id) else { return }
            let current = AutoReviewer.Input.make(action: Self.action(now), context: Self.policyContext(now), purpose: now.threadTitle, note: note)
            let fresh = now.session.permissionMode == .auto && now.session.busySince == session.busySince
                && current.hash == result.inputHash && RiskPolicy.version == Self.policyVersionAtStart
            guard fresh else {
                await escalate(id, now, escalation(source: .reviewer, code: "stale_review", text: "The request changed while it was reviewed, so you decide."), started)
                return
            }
            if result.outcome.allows {
                await approve(id, now, source: .reviewer, code: result.outcome.reasonCode, text: result.outcome.explanation, model: result.model, started: started)
            } else {
                await escalate(id, now, escalation(source: .reviewer, code: result.outcome.reasonCode, text: result.outcome.explanation), started, model: result.model)
            }
        }
    }

    /// The policy version this process started with: a decision is never applied under another.
    static let policyVersionAtStart = RiskPolicy.version

    private func approve(
        _ id: PermissionRequestID, _ context: AutoRequestContext, source: AutoDecisionSource, code: String, text: String, model: String?,
        started: ContinuousClock.Instant
    ) async {
        do {
            try await core.replyAutoRequest(id, reply: .once, message: nil)
        } catch {
            // The reply did not reach the server: never claim an approval; the person decides.
            await escalate(id, context, escalation(source: source, code: "reply_failed", text: "Auto could not deliver its approval, so you decide."), started)
            return
        }
        let request = context.request
        if let messageID = request.toolMessageID, let callID = request.toolCallID {
            let approval = AutoApproval(
                source: source, reasonCode: code, explanation: text, model: model, policyVersion: RiskPolicy.version,
                requestID: id.rawValue, at: .now)
            await core.annotateTool(request.sessionID, messageID: messageID, callID: callID) { risk in
                // Keep the most informative approval for the call (a reviewer or grant decision over a routine read).
                if risk.autoApproval == nil || risk.autoApproval?.source == .policy { risk.autoApproval = approval }
            }
        }
        append(entry(context, .autoApproved, source: source, findings: [], code: code, text: text, model: model, started: started))
    }

    private func escalate(
        _ id: PermissionRequestID, _ context: AutoRequestContext, _ escalation: AutoEscalation, _ started: ContinuousClock.Instant,
        model: String? = nil
    ) async {
        await core.escalateAutoRequest(id, escalation)
        append(entry(context, .escalated, source: escalation.source, findings: escalation.findings, code: escalation.reasonCode, text: escalation.explanation, model: model, started: started))
    }

    private func escalation(findings: [RiskFinding] = [], source: AutoDecisionSource, code: String, text: String) -> AutoEscalation {
        AutoEscalation(findings: findings, source: source, reasonCode: code, explanation: text, policyVersion: RiskPolicy.version)
    }

    // MARK: Inputs

    static func policyContext(_ context: AutoRequestContext) -> RiskPolicy.Context {
        // The plan agent's own plan directory is writable by design (opencode's plan rules).
        let home = NSHomeDirectory()
        return RiskPolicy.Context(
            directory: context.session.directory, roots: context.roots + [home + "/.opencode/plan"], home: home, trusted: context.codeRoots)
    }

    static func action(_ context: AutoRequestContext) -> RiskPolicy.Action {
        let request = context.request
        var action = RiskPolicy.Action(action: request.action, resources: request.resources, tool: context.tool?.name)
        if let call = context.tool, let input = call.input.flatMap(RiskNoticeInput.object) {
            let fromTool = RiskPolicy.toolAction(tool: call.name, input: input)
            if fromTool.action == request.action || request.action == "external_directory" {
                action.command = fromTool.command
                action.paths = fromTool.paths
                action.urls = fromTool.urls
            }
        }
        return action
    }

    /// A non-mandatory request whose every resource a saved project grant matches (the person chose "Always").
    private func savedGrantCovers(_ context: AutoRequestContext) async -> Bool {
        let project = context.session.projectID
        let rules: [SavedPermission]
        if let cached = savedGrants[project], clock.now - cached.at < .seconds(30) {
            rules = cached.rules
        } else {
            guard let client = try? await core.currentClient(), let fetched = try? await client.savedPermissions(projectID: project.rawValue) else { return false }
            savedGrants[project] = (fetched, clock.now)
            rules = fetched
        }
        let request = context.request
        guard !request.resources.isEmpty else { return false }
        return request.resources.allSatisfy { resource in
            rules.contains { PermissionModeRules.wildcard($0.action, matches: request.action) && PermissionModeRules.wildcard($0.resource, matches: resource) }
        }
    }

    /// The person answered an Auto-escalated card with "Always": refresh the grant cache.
    public func grantsChanged(_ project: ProjectID) { savedGrants[project] = nil }

    // MARK: Notices

    private func record(_ events: [RiskNoticeEvent], dropped: Int) {
        droppedNotices += dropped
        var entries: [AutoAuditEntry] = []
        for event in events {
            var list = unreviewed[event.sessionID] ?? []
            for finding in event.findings {
                let id = "\(event.callID)|\(finding.category.rawValue)|\(finding.target)"
                let notice = Notice(id: id, sessionID: event.sessionID, messageID: event.messageID, callID: event.callID, tool: event.tool, finding: finding, stage: event.stage.rawValue, at: .now)
                if let index = list.firstIndex(where: { $0.id == id }) { list[index].stage = notice.stage } else { list.append(notice) }
                entries.append(
                    AutoAuditEntry(
                        id: "notice|" + id, sessionID: event.sessionID, projectDirectory: event.projectDirectory, kind: .notice, source: nil,
                        action: event.tool, toolCallID: event.callID, findings: [finding], reasonCode: finding.category.rawValue,
                        explanation: finding.noticeText, policyVersion: RiskPolicy.version, state: event.stage.rawValue, at: .now))
            }
            if list.count > Self.noticesPerThread { list.removeFirst(list.count - Self.noticesPerThread) }
            unreviewed[event.sessionID] = list
        }
        if unreviewed.count > 200, let oldest = unreviewed.min(by: { ($0.value.last?.at ?? .now) < ($1.value.last?.at ?? .now) })?.key {
            unreviewed[oldest] = nil
        }
        appendAll(entries)
    }

    /// Threads with unreviewed notices, most recent first (Needs you, after the blocking items).
    public var threadsToReview: [SessionID] {
        unreviewed.filter { !$0.value.isEmpty }.sorted { ($0.value.last?.at ?? .now) > ($1.value.last?.at ?? .now) }.map(\.key)
    }

    public func noticeCount(_ sessionID: SessionID) -> Int { unreviewed[sessionID]?.count ?? 0 }

    /// The person looked at them: they leave Needs you (the transcript and the audit log keep them).
    public func markReviewed(_ sessionID: SessionID) {
        unreviewed[sessionID] = nil
        if unreviewed.isEmpty { droppedNotices = 0 }
    }

    // MARK: Audit

    private func entry(
        _ context: AutoRequestContext, _ kind: AutoAuditEntry.Kind, source: AutoDecisionSource, findings: [RiskFinding], code: String, text: String,
        model: String? = nil, started: ContinuousClock.Instant
    ) -> AutoAuditEntry {
        let elapsed = clock.now - started
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return AutoAuditEntry(
            id: "\(context.request.id.rawValue)|\(kind.rawValue)", sessionID: context.session.id, projectDirectory: context.roots.dropFirst().first ?? context.session.directory,
            kind: kind, source: source, action: context.request.action, toolCallID: context.request.toolCallID, findings: findings,
            reasonCode: code, explanation: String(text.prefix(200)), model: model, policyVersion: RiskPolicy.version,
            latencyMilliseconds: milliseconds, at: .now)
    }

    private func append(_ entry: AutoAuditEntry) { appendAll([entry]) }

    private func appendAll(_ entries: [AutoAuditEntry]) {
        guard !entries.isEmpty else { return }
        for entry in entries {
            var list = audit[entry.sessionID] ?? []
            list.removeAll { $0.id == entry.id }
            list.insert(entry, at: 0)
            if list.count > ProjectionStore.autoAuditPerThread { list.removeLast(list.count - ProjectionStore.autoAuditPerThread) }
            audit[entry.sessionID] = list
        }
        // One writer at a time; entries queue (bounded) while it runs.
        pendingAudit += entries
        if pendingAudit.count > 2_000 { pendingAudit.removeFirst(pendingAudit.count - 2_000) }
        guard auditWriter == nil else { return }
        auditWriter = Task { [weak self] in
            while let self, !self.pendingAudit.isEmpty {
                let batch = self.pendingAudit
                self.pendingAudit.removeAll()
                do { try await self.store.appendAutoAudit(batch) } catch { self.log.error("auto audit write failed") }
            }
            self?.auditWriter = nil
        }
    }

    private var pendingAudit: [AutoAuditEntry] = []
    private var auditWriter: Task<Void, Never>?

    /// Loads a thread's audit log from the store (cached-first: what is in memory shows at once).
    public func loadAudit(_ sessionID: SessionID) async {
        guard let stored = try? await store.autoAudit(sessionID: sessionID) else { return }
        var merged = audit[sessionID] ?? []
        for entry in stored where !merged.contains(where: { $0.id == entry.id }) { merged.append(entry) }
        audit[sessionID] = merged.sorted { $0.at > $1.at }
    }

    // MARK: Tests and snapshots

    /// Records an entry directly (snapshot scenarios).
    func recordForTesting(_ entry: AutoAuditEntry) { append(entry) }
    func recordNoticesForTesting(_ events: [RiskNoticeEvent]) { record(events, dropped: 0) }
}
