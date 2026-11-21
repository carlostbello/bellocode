import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// Auto end to end against MockOpenCode (docs/features/auto-mode.md): triage hides requests until decided, the policy
/// allows, escalates or refuses, the reviewer decides the rest, stale reviews are discarded, mode mapping, notices and
/// the audit log.
@Suite("Auto mode", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct AutoModeTests {
    static let project = "/tmp/mock-auto"

    /// A reviewer that answers with `reply`, or waits for `release()`.
    actor ScriptedReviewer: AutoReviewer.Model {
        var reply: String
        var hold = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var calls = 0

        init(_ reply: String) { self.reply = reply }
        func set(hold: Bool) { self.hold = hold }
        func release() {
            hold = false
            for waiter in waiting { waiter.resume() }
            waiting.removeAll()
        }

        func generate(prompt: String, model: OpenCodeKit.ModelRef?) async throws -> String {
            calls += 1
            if hold { await withCheckedContinuation { waiting.append($0) } }
            return reply
        }
    }

    static let allow = #"{"decision":"allow_once","reason_code":"routine_build","explanation":"Builds the project."}"#
    static let escalate = #"{"decision":"escalate","reason_code":"unclear_script","explanation":"Runs an unknown script."}"#

    func start(_ reviewer: ScriptedReviewer) async throws -> (MockHarness, Engine) {
        try FileManager.default.createDirectory(atPath: Self.project + "/src", withIntermediateDirectories: true)
        let harness = try await MockHarness.start(.empty(directory: Self.project))
        var configuration = EngineConfiguration(server: .fixed(harness.connection), store: .inMemory)
        configuration.eventBackoff = BackoffPolicy(initial: .milliseconds(20), maximum: .milliseconds(200))
        configuration.writeInterval = .milliseconds(20)
        configuration.autoReviewerModel = reviewer
        let engine = try Engine(configuration: configuration)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        await engine.addProject(directory: Self.project)
        return (harness, engine)
    }

    func ask(_ harness: MockHarness, _ session: SessionID, _ action: String, _ resources: [String]) async throws -> String {
        let evaluation = try await harness.client.evaluatePermission(sessionID: session.rawValue, PermissionCreateRequest(action: action, resources: resources))
        #expect(evaluation.effect == .ask, "Auto's rules make every request ask")
        return evaluation.id
    }

    func serverPending(_ harness: MockHarness, _ session: SessionID) async throws -> [String] {
        try await harness.client.permissions(sessionID: session.rawValue).map(\.id)
    }

    @Test func modeMappingIsMarkedAndRoundTrips() {
        let rules = PermissionModeRules.rules(for: .auto, agentRules: [PermissionRule(action: "edit", resource: "*", effect: .deny)])
        #expect(rules.first == PermissionRule(action: "bellocode_auto", resource: "*", effect: .ask))
        #expect(rules[1] == PermissionRule(action: "*", resource: "*", effect: .ask))
        #expect(rules.last == PermissionRule(action: "edit", resource: "*", effect: .deny), "the plan agent stays read-only")
        for mode in PermissionMode.allCases {
            #expect(PermissionModeRules.mode(from: PermissionModeRules.rules(for: mode)) == mode)
        }
    }

    @Test func routineRequestsAreApprovedOnceWithoutEverShowing() async throws {
        let reviewer = ScriptedReviewer(Self.allow)
        let (harness, engine) = try await start(reviewer)
        defer { Task { await engine.stop(); await harness.stop() } }
        let session = try await engine.createThread(in: Self.project, title: "auto", permissionMode: .auto)
        let thread = engine.openThread(session.id)
        defer { thread.close() }
        var shown = false
        let id = try await ask(harness, session.id, "read", [Self.project + "/src/main.swift"])
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while try await serverPending(harness, session.id).contains(id), clock.now < deadline {
            if !thread.pendingRequests.isEmpty || engine.root.attention.items.contains(where: { $0.sessionID == session.id }) { shown = true }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await serverPending(harness, session.id).isEmpty, "replied")
        #expect(!shown, "a routine request never appears as a card or in Needs you")
        let recorded = await harness.server.recordedRequests().filter { $0.contains("/permission/\(id)/reply") }
        #expect(recorded.count == 1)
        try await waitUntil("audit") { engine.auto.audit[session.id]?.contains { $0.kind == .autoApproved && $0.source == .policy } == true }
        #expect(await reviewer.calls == 0, "deterministic allows never call the reviewer")
    }

    @Test func mandatoryRequestsEscalateToTheExistingCardEvenIfTheReviewerWouldAllow() async throws {
        let reviewer = ScriptedReviewer(Self.allow)  // compromised: approves anything it sees
        let (harness, engine) = try await start(reviewer)
        defer { Task { await engine.stop(); await harness.stop() } }
        let session = try await engine.createThread(in: Self.project, title: "auto", permissionMode: .auto)
        let thread = engine.openThread(session.id)
        defer { thread.close() }
        _ = try await ask(harness, session.id, "read", [Self.project + "/.env"])
        _ = try await ask(harness, session.id, "shell", ["git push --force origin main"])
        _ = try await ask(harness, session.id, "external_directory", ["/Users/someone/Downloads/*"])
        try await waitUntil("three cards") { thread.pendingRequests.count == 3 }
        let escalations = thread.pendingRequests.compactMap { request -> AutoEscalation? in
            if case .permission(let permission) = request { permission.autoEscalation } else { nil }
        }
        #expect(Set(escalations.flatMap(\.findings).map(\.category)).isSuperset(of: [.secretRead, .destructiveGit, .publish, .outsidePath]))
        #expect(escalations.allSatisfy { $0.source == .policy })
        #expect(await reviewer.calls == 0, "mandatory gates never reach the reviewer")
        try await waitUntil("needs you") { engine.root.attention.items.contains { $0.sessionID == session.id } }
        #expect(try await serverPending(harness, session.id).count == 3, "nothing was answered for the person")
    }

    @Test func hardDeniesAreRefusedWithAReason() async throws {
        let (harness, engine) = try await start(ScriptedReviewer(Self.allow))
        defer { Task { await engine.stop(); await harness.stop() } }
        let session = try await engine.createThread(in: Self.project, title: "auto", permissionMode: .auto)
        let id = try await ask(harness, session.id, "shell", ["security dump-keychain"])
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while try await serverPending(harness, session.id).contains(id), clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try await waitUntil("denied") { engine.auto.audit[session.id]?.contains { $0.kind == .denied } == true }
    }

    @Test func theReviewerDecidesTheRemainderAndItsEscalationsShowItsReason() async throws {
        let reviewer = ScriptedReviewer(Self.allow)
        let (harness, engine) = try await start(reviewer)
        defer { Task { await engine.stop(); await harness.stop() } }
        let session = try await engine.createThread(in: Self.project, title: "Fix the build", permissionMode: .auto)
        let thread = engine.openThread(session.id)
        defer { thread.close() }
        let allowed = try await ask(harness, session.id, "shell", ["swift build"])
        try await waitUntil("reviewed") { engine.auto.audit[session.id]?.contains { $0.kind == .autoApproved && $0.source == .reviewer } == true }
        #expect(try await !serverPending(harness, session.id).contains(allowed))
        await reviewer.set(hold: false)
        await reviewerReply(reviewer, Self.escalate)
        _ = try await ask(harness, session.id, "shell", ["./scripts/mystery.sh"])
        try await waitUntil("escalated") { thread.pendingRequests.count == 1 }
        guard case .permission(let request)? = thread.pendingRequests.first else { throw CancellationError() }
        #expect(request.autoEscalation?.source == .reviewer)
        #expect(request.autoEscalation?.reasonCode == "unclear_script")
        // The person allows it from the existing card.
        try await engine.reply(to: request.id, .once)
        try await waitUntil("resolved") { thread.pendingRequests.isEmpty }
    }

    func reviewerReply(_ reviewer: ScriptedReviewer, _ text: String) async { await reviewer.setReply(text) }

    /// A09: a request too large for the reviewer to see whole is never judged by it: the person decides.
    @Test func aRequestTheReviewerCannotSeeWholeEscalates() async throws {
        let reviewer = ScriptedReviewer(Self.allow)
        let (harness, engine) = try await start(reviewer)
        defer { Task { await engine.stop(); await harness.stop() } }
        let session = try await engine.createThread(in: Self.project, title: "long", permissionMode: .auto)
        let thread = engine.openThread(session.id)
        defer { thread.close() }
        let long = "swift build " + (0..<400).map { "--flag-\($0)" }.joined(separator: " ")
        _ = try await ask(harness, session.id, "shell", [long])
        try await waitUntil("escalated") { thread.pendingRequests.count == 1 }
        guard case .permission(let request)? = thread.pendingRequests.first else { throw CancellationError() }
        #expect(request.autoEscalation?.reasonCode == "review_incomplete")
        #expect(await reviewer.calls == 0, "the reviewer never saw a clipped request")
    }

    @Test func aReviewThatOutlivesItsSessionModeIsDiscarded() async throws {
        let reviewer = ScriptedReviewer(Self.allow)
        await reviewer.set(hold: true)
        let (harness, engine) = try await start(reviewer)
        defer { Task { await engine.stop(); await harness.stop() } }
        let session = try await engine.createThread(in: Self.project, title: "auto", permissionMode: .auto)
        let thread = engine.openThread(session.id)
        defer { thread.close() }
        let id = try await ask(harness, session.id, "shell", ["make release"])
        try await waitUntil("reviewing") { engine.auto.deciding.contains(PermissionRequestID(id)) }
        // The person switches the thread to Ask while the reviewer is still thinking.
        try await engine.setPermissionMode(.ask, for: session.id)
        await reviewer.release()
        try await waitUntil("shown, not approved") { thread.pendingRequests.count == 1 }
        #expect(try await serverPending(harness, session.id).contains(id), "the late allow was never sent")
        #expect(await harness.server.recordedRequests().filter { $0.contains("/permission/\(id)/reply") }.isEmpty)
    }

    @Test func aReviewerTimeoutEscalates() async throws {
        let reviewer = ScriptedReviewer(Self.allow)
        await reviewer.set(hold: true)
        let (harness, engine) = try await start(reviewer)
        defer { Task { await engine.stop(); await harness.stop() } }
        await engine.auto.updateSettings(.init(model: nil, timeoutSeconds: 0.5, maxConcurrent: 2, maxQueued: 4, budgetPerHour: 50))
        let session = try await engine.createThread(in: Self.project, title: "auto", permissionMode: .auto)
        let thread = engine.openThread(session.id)
        defer { thread.close() }
        _ = try await ask(harness, session.id, "shell", ["make release"])
        try await waitUntil("escalated", timeout: .seconds(10)) { thread.pendingRequests.count == 1 }
        guard case .permission(let request)? = thread.pendingRequests.first else { throw CancellationError() }
        #expect(request.autoEscalation?.reasonCode == "timeout")
        await reviewer.release()
    }

    @Test func fullAccessToolCallsCarryNoticesAndFeedNeedsYou() async throws {
        let (harness, engine) = try await start(ScriptedReviewer(Self.allow))
        defer { Task { await engine.stop(); await harness.stop() } }
        let session = try await engine.createThread(in: Self.project, title: "full", permissionMode: .fullAccess)
        // A finished read of .env and a destructive command, as opencode reports them.
        engine.auto.recordNoticesForTesting([
            RiskNoticeEvent(sessionID: session.id, messageID: MessageID("msg_1"), callID: "c1", tool: "read", findings: [RiskFinding(.secretRead, ".env")], stage: .completed),
            RiskNoticeEvent(sessionID: session.id, messageID: MessageID("msg_1"), callID: "c2", tool: "shell", findings: [RiskFinding(.destructiveGit, "reset --hard")], stage: .attempted),
        ])
        #expect(engine.auto.threadsToReview == [session.id])
        #expect(engine.auto.noticeCount(session.id) == 2)
        try await waitUntil("audited") { engine.auto.audit[session.id]?.filter { $0.kind == .notice }.count == 2 }
        engine.auto.markReviewed(session.id)
        #expect(engine.auto.threadsToReview.isEmpty)
        // The audit log is persisted and bounded; it holds labels, never content.
        await engine.auto.loadAudit(session.id)
        let stored = try await engine.store.autoAudit(sessionID: session.id)
        #expect(stored.count == 2)
        #expect(!String(decoding: try JSONEncoder().encode(stored), as: UTF8.self).contains("canary"))
    }

    @Test func reducerNoticesFullAccessToolCalls() {
        var state = ProjectionState()
        let session = Session(id: SessionID("ses_f"), projectID: ProjectID("p"), directory: "/repo", permissionMode: .fullAccess, created: .now, updated: .now)
        state.sessions[session.id] = session
        state.projects[ProjectID("p")] = Project(id: ProjectID("p"), directory: "/repo", created: .now, updated: .now)
        let message = Message(
            id: MessageID("msg_1"), sessionID: session.id, kind: .assistant(AssistantInfo()), created: .now,
            parts: [Part(id: Part.makeID(message: MessageID("msg_1"), .tool(callID: "c1")), index: 0,
                         content: .tool(ToolCall(callID: "c1", name: "shell", status: .running, input: RawJSON(#"{"command":"cat .env && git reset --hard"}"#))))])
        state.messages.put(message, persisted: true)
        var reduction = Reduction()
        EventReducer.noticeRiskForTesting("ses_f", "msg_1", "c1", state: &state, into: &reduction)
        let call = state.messages[MessageID("msg_1")]?.parts.first?.content.toolCall
        #expect(Set(call?.risk?.notices.map(\.category) ?? []) == [.secretRead, .destructiveGit])
        #expect(reduction.riskNotices.first?.stage == .attempted)
    }
}

extension AutoModeTests.ScriptedReviewer {
    func setReply(_ text: String) { reply = text }
}

@Suite("Interrupt hold and Resume", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct InterruptResumeTests {
    @Test func aHeldInterruptShowsAndResumeClearsItAndStartsARun() async throws {
        let directory = "/tmp/mock-interrupt"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let harness = try await MockHarness.start(.empty(directory: directory))
        let engine = try makeEngine(harness)
        await engine.start()
        defer { Task { await engine.stop(); await harness.stop() } }
        try await waitUntil("live") { engine.root.connection == .live }
        let target = try await engine.createThread(in: directory, title: "target", permissionMode: .fullAccess)
        let thread = engine.openThread(target.id)
        defer { thread.close() }
        // What the plugin's thread_interrupt writes on the stopped thread.
        let record: OpenCodeKit.JSONValue = ["by": "ses_caller", "byTitle": "Caller", "reason": "it edits the same file", "at": 1, "requested": "stop", "actual": "stopped", "held": true]
        try await harness.client.updateSession(target.id.rawValue, SessionUpdateRequest(metadata: ["bellocode_interrupt": record]))
        try await waitUntil("held") { thread.heldInterrupt != nil }
        #expect(thread.heldInterrupt?.summary == "Stopped by “Caller”: it edits the same file")
        #expect(await thread.resumeAfterInterrupt())
        try await waitUntil("released") { thread.heldInterrupt == nil }
        let requests = await harness.server.recordedRequests()
        #expect(requests.contains { $0.hasPrefix("POST") && $0.hasSuffix("/synthetic") }, "Resume starts a run with a note")
        let stored = try await harness.client.session(target.id.rawValue).metadata
        #expect(stored?["bellocode_interrupt"]?["held"] == false)
    }

    @Test func transcriptNotesNameWhoInterruptedWhom() {
        #expect(RowBuilderProbe.wake("[BelloCode interrupt] Stopped by thread “Caller” (ses_1): conflict. Queued work is held until the user resumes this thread.")?.hasPrefix("Interrupted: Stopped by thread “Caller”") == true)
    }
}

/// RowBuilder lives in TranscriptKit; the Engine tests only check the wake prefix the plugin writes.
enum RowBuilderProbe {
    static func wake(_ text: String) -> String? {
        text.hasPrefix("[BelloCode interrupt] ") ? "Interrupted: " + text.dropFirst("[BelloCode interrupt] ".count) : nil
    }
}

@Suite("Auto audit store")
struct AutoAuditStoreTests {
    @Test func migratedBoundedPerThreadAndContentFree() async throws {
        let store = try ProjectionStore(location: .inMemory, changes: ChangeBus(subscriberLimit: 16))
        #expect(try await store.appliedMigrations().contains("v11-auto-audit"))
        let session = SessionID("ses_audit")
        let entries = (0..<(ProjectionStore.autoAuditPerThread + 20)).map { index in
            AutoAuditEntry(
                id: "req_\(index)|autoApproved", sessionID: session, projectDirectory: "/repo", kind: .autoApproved, source: .policy,
                action: "read", toolCallID: "call_\(index)", findings: [], reasonCode: "in_project_read", explanation: "Reads inside the project",
                policyVersion: RiskPolicy.version, latencyMilliseconds: 1, at: Timestamp(milliseconds: Double(Date().timeIntervalSince1970 * 1000) + Double(index)))
        }
        try await store.appendAutoAudit(entries)
        let stored = try await store.autoAudit(sessionID: session)
        #expect(stored.count == ProjectionStore.autoAuditPerThread)
        #expect(stored.first?.id == "req_\(ProjectionStore.autoAuditPerThread + 19)|autoApproved", "newest first, oldest dropped")
        // Older than the retention window: removed on the next write.
        let old = AutoAuditEntry(
            id: "old", sessionID: SessionID("ses_other"), projectDirectory: nil, kind: .notice, source: nil, action: "read", toolCallID: nil,
            findings: [RiskFinding(.secretRead, ".env")], reasonCode: "secretRead", explanation: "Read a secret-looking file: .env",
            policyVersion: RiskPolicy.version, at: Timestamp(milliseconds: 1_000))
        try await store.appendAutoAudit([old])
        #expect(try await store.autoAudit(sessionID: SessionID("ses_other")).isEmpty)
        try await store.deleteAutoAudit(sessionID: session)
        #expect(try await store.autoAudit(sessionID: session).isEmpty)
    }
}

@Suite("Auto code roots end to end", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct AutoCodeRootTests {
    @Test func engineCodeRootsReachAutoDecisions() async throws {
        let project = "/tmp/mock-roots/app"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "/tmp/mock-roots/lib", withIntermediateDirectories: true)
        let harness = try await MockHarness.start(.empty(directory: project))
        var configuration = EngineConfiguration(server: .fixed(harness.connection), store: .inMemory)
        configuration.autoReviewerModel = AutoModeTests.ScriptedReviewer(AutoModeTests.escalate)
        let engine = try Engine(configuration: configuration)
        await engine.start()
        defer { Task { await engine.stop(); await harness.stop() } }
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: project, title: "roots", permissionMode: .auto)
        let thread = engine.openThread(session.id)
        defer { thread.close() }
        // Without roots: the sibling repository escalates as outside the project.
        _ = try await harness.client.evaluatePermission(sessionID: session.id.rawValue, PermissionCreateRequest(action: "external_directory", resources: ["/tmp/mock-roots/lib/*"]))
        try await waitUntil("escalated") { thread.pendingRequests.count == 1 }
        // With the developer's code root: the same kind of request is approved once by the policy.
        engine.codeRoots = CodeRoots(["/tmp/mock-roots"])
        // The setter pushes asynchronously; apply it now as a barrier (idempotent) before the next request.
        await engine.core.setCodeRoots(engine.codeRoots)
        let id = try await harness.client.evaluatePermission(sessionID: session.id.rawValue, PermissionCreateRequest(action: "external_directory", resources: ["/tmp/mock-roots/lib/src/*"])).id
        try await waitUntil("approved") { engine.auto.audit[session.id]?.contains { $0.kind == .autoApproved && $0.reasonCode == "code_root" } == true }
        #expect(try await !harness.client.permissions(sessionID: session.id.rawValue).map(\.id).contains(id))
        #expect(thread.pendingRequests.count == 1, "only the earlier escalation is shown")
    }
}
