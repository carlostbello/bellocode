import BelloCore
import Darwin
import Foundation
import OpenCodeKit
import Testing

@testable import Engine

/// Auto mode's hook contract (docs/features/auto-mode.md) against the pinned opencode with the bellocode plugin loaded.
/// Opt-in: `BELLOCODE_AUTO_REAL=1 swift test --filter AutoHookRealBinary`. `BELLOCODE_AUTO_BINARY=/path/opencode` runs
/// the same suite against another build (2.3.2 was checked this way before the pin moved). HOME and XDG live in a fresh
/// temporary directory (never the user's opencode config or data). Prompts on the zero-cost default model: one here
/// (tool hooks), one child + MCP probe, one reviewer generation; the Auto end-to-end and interrupt suites add their own.
enum AutoRealBinary {
    static var binary: URL? {
        if let path = ProcessInfo.processInfo.environment["BELLOCODE_AUTO_BINARY"], FileManager.default.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        return EngineRepo.vendoredOpencode
    }

    static var expectedVersion: String? {
        ProcessInfo.processInfo.environment["BELLOCODE_AUTO_BINARY"] == nil ? EngineRepo.pinnedVersion : nil
    }

    static var enabled: Bool { ProcessInfo.processInfo.environment["BELLOCODE_AUTO_REAL"] == "1" && binary != nil }
}

@Suite(
    "Auto hook contract real binary", .serialized,
    .enabled(
        if: AutoRealBinary.enabled,
        "set BELLOCODE_AUTO_REAL=1 and run Scripts/fetch-opencode.sh"),
    .timeLimit(.minutes(10)))
@MainActor
struct AutoHookRealBinaryTests {
    @MainActor struct Sandbox {
        let root: URL
        let project: URL
        let supervisor: ServerSupervisor
        let engine: Engine

        static func start(_ name: String) async throws -> Sandbox {
            let executable = try #require(AutoRealBinary.binary)
            let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-auto-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
            let project = root.appending(path: "project", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try "auto sandbox\n".write(to: project.appending(path: "README.md"), atomically: true, encoding: .utf8)
            try "TOKEN=bellocode-canary-not-a-secret\n".write(to: project.appending(path: ".env"), atomically: true, encoding: .utf8)
            let supervisor = ServerSupervisor(
                configuration: ServerConfiguration(
                    executableURL: executable, dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
                    expectedVersion: AutoRealBinary.expectedVersion,
                    pluginDirectory: OrchestrationRealBinaryTests.pluginDirectory))
            var configuration = EngineConfiguration(server: .supervised(supervisor), store: .inMemory)
            configuration.defaultDirectory = project.path
            let engine = try Engine(configuration: configuration)
            await engine.start()
            await engine.addProject(directory: project.path)
            try await waitUntil("live", timeout: .seconds(30)) { engine.root.connection == .live }
            return Sandbox(root: root, project: project, supervisor: supervisor, engine: engine)
        }

        func client() async throws -> OpenCodeClient { try await engine.core.currentClient() }

        /// The plugin's hook trace (names, effects and counts only), retried while the location's RPC activates.
        func trace(_ sessionID: String? = nil) async throws -> [JSONValue] {
            let client = try await client()
            var input: [String: JSONValue] = [:]
            if let sessionID { input["sessionID"] = .string(sessionID) }
            for attempt in 0..<20 {
                do {
                    let output = try await client.pluginRPC("bellocode", "trace", input: .object(input), directory: project.path)
                    if let error = output["error"]?.stringValue { Issue.record("trace failed in the plugin: \(error)") }
                    return output["entries"]?.arrayValue ?? []
                } catch {
                    if attempt == 19 { print("AUTO trace error: \(error)"); throw error }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            return []
        }

        func stop() async {
            let pid = await supervisor.childPID
            await engine.stop()
            if let pid { #expect(kill(pid, 0) != 0, "server child \(pid) still running") }
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Polls the server until the session has run and is idle again.
    static func waitIdle(_ sandbox: Sandbox, _ id: String, timeout: Duration = .seconds(180)) async throws {
        let client = try await sandbox.client()
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let session = try? await client.session(id), let busy = session.time.busy, let idle = session.time.idle, idle > busy { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        Issue.record("session \(id) did not finish")
        throw CancellationError()
    }

    static let autoRules = [
        PermissionRule(action: "bellocode_auto", resource: "*", effect: .ask), PermissionRule(action: "*", resource: "*", effect: .ask),
    ]

    private func session(_ sandbox: Sandbox, _ title: String, rules: [PermissionRule]) async throws -> String {
        let client = try await sandbox.client()
        let created = try await client.createSession(
            SessionCreateRequest(directory: sandbox.project.path, title: title, permissions: rules))
        return created.id
    }

    private func label(_ entry: JSONValue) -> String {
        [entry["hook"]?.stringValue, entry["tool"]?.stringValue, entry["action"]?.stringValue].compactMap { $0 }.joined(separator: ":")
    }

    /// No prompts: rule order, saved grants against the hook, configured denies, an awaited async hook, Full access,
    /// and an Auto request left unanswered (the app is away).
    @Test func evaluateHookAgainstSavedGrantsDeniesAndAsyncWaits() async throws {
        let sandbox = try await Sandbox.start("evaluate")
        defer { Task { await sandbox.stop() } }
        let client = try await sandbox.client()
        _ = try await sandbox.trace()  // waits for the plugin's RPC

        // An Ask session: the shell asks; "always" saves a project grant; then the same command is allowed.
        let ask = try await session(sandbox, "ask", rules: [PermissionRule(action: "shell", resource: "*", effect: .ask)])
        let first = try await client.evaluatePermission(
            sessionID: ask, PermissionCreateRequest(action: "shell", resources: ["echo hook"], save: ["echo hook"]))
        #expect(first.effect == .ask)
        try await client.replyPermission(sessionID: ask, requestID: first.id, decision: .always)
        let granted = try await client.evaluatePermission(sessionID: ask, PermissionCreateRequest(action: "shell", resources: ["echo hook"]))
        #expect(granted.effect == .allow, "the saved grant applies in a non-Auto session")

        // An Auto session in the same project: the saved grant still applies before the hook, and the hook turns it into ask.
        let auto = try await session(sandbox, "auto", rules: Self.autoRules)
        let reviewed = try await client.evaluatePermission(sessionID: auto, PermissionCreateRequest(action: "shell", resources: ["echo hook"]))
        #expect(reviewed.effect == .ask, "Auto keeps a saved grant from skipping review")
        let autoTrace = try await sandbox.trace(auto)
        #expect(autoTrace.contains { $0["action"]?.stringValue == "shell" && $0["effectIn"]?.stringValue == "allow" && $0["effectOut"]?.stringValue == "ask" })

        // A configured deny returns before the hook: the hook never sees it.
        let denied = try await session(sandbox, "deny", rules: Self.autoRules + [PermissionRule(action: "shell", resource: "*", effect: .deny)])
        let refusal = try await client.evaluatePermission(sessionID: denied, PermissionCreateRequest(action: "shell", resources: ["echo hook"]))
        #expect(refusal.effect == .deny)
        #expect(try await sandbox.trace(denied).isEmpty, "a configured deny is decided before the plugin hook")

        // Promise hooks are awaited: the probe sleeps 400 ms, then decides. It can also lower ask to allow (unused).
        let clock = ContinuousClock()
        let started = clock.now
        let probe = try await client.evaluatePermission(
            sessionID: auto,
            PermissionCreateRequest(action: "bellocode_contract_probe", resources: ["*"], metadata: ["delayMs": 400, "effect": "deny"]))
        let waited = clock.now - started
        #expect(probe.effect == .deny)
        #expect(waited >= .milliseconds(400))
        let lowered = try await client.evaluatePermission(
            sessionID: auto,
            PermissionCreateRequest(action: "bellocode_contract_probe", resources: ["*"], metadata: ["delayMs": 0, "effect": "allow"]))
        #expect(lowered.effect == .allow)

        // Full access: allowed and recorded (no ask).
        let full = try await session(sandbox, "full", rules: [PermissionRule(action: "*", resource: "*", effect: .allow)])
        let read = try await client.evaluatePermission(sessionID: full, PermissionCreateRequest(action: "read", resources: [sandbox.project.appending(path: ".env").path]))
        #expect(read.effect == .allow)
        #expect(try await sandbox.trace(full).contains { $0["mode"]?.stringValue == "full" && $0["action"]?.stringValue == "read" })

        // Nobody answers the Auto request (the app is away): it stays pending on the server, never allowed.
        try await Task.sleep(for: .seconds(2))
        let pending = try await client.permissions(sessionID: auto)
        #expect(pending.contains { $0.id == reviewed.id })
        print("AUTO contract: grant→Auto ask ok; deny before hook ok; async hook waited \(waited); pending kept \(pending.count)")
    }

    /// One prompt in Full access: hook order around the shell and read tools, and the evaluations stamped on the result.
    @Test func toolHooksOrderAndResultMetadataInFullAccess() async throws {
        let sandbox = try await Sandbox.start("tools")
        defer { Task { await sandbox.stop() } }
        let engine = sandbox.engine
        let thread = try await engine.createThread(in: sandbox.project.path, title: "tool hooks", permissionMode: .fullAccess)
        _ = try await sandbox.trace()
        _ = try await engine.send(
            "Run the shell command `echo bellocode-hook` with your shell tool. Then read the file .env with your read tool. "
                + "Then reply with exactly: DONE", to: thread.id)
        try await Self.waitIdle(sandbox, thread.id.rawValue)
        let entries = try await sandbox.trace(thread.id.rawValue)
        let labels = entries.map(label)
        print("AUTO contract trace: \(labels)")
        for tool in ["shell", "read"] {
            let before = entries.firstIndex { $0["hook"]?.stringValue == "execute.before" && $0["tool"]?.stringValue == tool }
            let evaluate = entries.firstIndex { $0["hook"]?.stringValue == "evaluate" && $0["action"]?.stringValue == tool }
            let after = entries.firstIndex { $0["hook"]?.stringValue == "execute.after" && $0["tool"]?.stringValue == tool }
            #expect(before != nil && evaluate != nil && after != nil, "\(tool): before, evaluate and after all ran")
            if let before, let evaluate, let after { #expect(before < evaluate && evaluate < after) }
        }
        // The shell job's create hook runs after the shell tool's permission (BelloCode's container helper is set there).
        let all = try await sandbox.trace()
        print("AUTO contract full trace: \(all.map(label))")
        let evaluate = all.firstIndex { $0["action"]?.stringValue == "shell" && $0["sessionID"]?.stringValue == thread.id.rawValue }
        let after = all.firstIndex { $0["hook"]?.stringValue == "execute.after" && $0["tool"]?.stringValue == "shell" }
        if let evaluate, let after {
            #expect(all[evaluate..<after].contains { $0["hook"]?.stringValue == "shell.create.before" },
                    "the shell job is created (helper substituted) between the permission and the result")
        } else {
            Issue.record("no shell evaluation/result in the trace")
        }
        // The read's evaluations reach the app through the tool result's metadata.
        let messages = try await sandbox.client().messages(sessionID: thread.id.rawValue, MessageListQuery(limit: 50)).data
        let stamped = messages.contains { message in
            guard case .assistant(let assistant) = message else { return false }
            return assistant.content.contains { content in
                guard case .tool(let tool) = content, tool.name == "read" else { return false }
                if case .completed(_, _, let metadata) = tool.state { return metadata?["bellocode_permissions"] != nil }
                return false
            }
        }
        #expect(stamped, "execute.after's result metadata is kept")
    }

    /// One prompt in Auto (the test replies as the app would): MCP (client-hosted app tool) and child-session coverage.
    @Test func autoCoversMCPToolsAndChildSessions() async throws {
        let sandbox = try await Sandbox.start("coverage")
        defer { Task { await sandbox.stop() } }
        let engine = sandbox.engine
        await engine.orchestration.hostAppTools(directories: [sandbox.project.path])
        let client = try await sandbox.client()
        let parent = try await session(sandbox, "coverage", rules: Self.autoRules)
        _ = try await sandbox.trace()
        _ = try await client.prompt(
            sessionID: parent,
            PromptRequest(
                text: "Call the bellocode_app_queue tool once with action list. Then call delegate_task once with description "
                    + "'probe' and task 'Reply with exactly: CHILD-OK'. Then end your turn."))
        var seen: [(session: String, action: String)] = []
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(180)
        var childID: String?
        while clock.now < deadline {
            let sessions = [parent] + (childID.map { [$0] } ?? [])
            for id in sessions {
                for request in (try? await client.permissions(sessionID: id)) ?? [] {
                    seen.append((id, request.action))
                    try? await client.replyPermission(sessionID: id, requestID: request.id, decision: .once)
                }
            }
            if childID == nil {
                childID = try? await client.sessions(SessionListQuery(parent: .session(parent))).data.first?.id
            }
            if let childID, let child = try? await client.session(childID), child.time.idle != nil,
                (child.time.idle ?? 0) > (child.time.busy ?? 0), seen.contains(where: { $0.session == childID })
            {
                break
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        print("AUTO contract coverage: \(seen.map { "\($0.session == parent ? "parent" : "child"):\($0.action)" })")
        #expect(seen.contains { $0.session == parent && $0.action.hasPrefix("bellocode_app") }, "a client MCP tool asserts its own action")
        #expect(seen.contains { $0.session == parent && $0.action == "subagent" } || childID != nil)
        let child = try #require(childID)
        let childTrace = try await sandbox.trace(child)
        #expect(childTrace.contains { $0["mode"]?.stringValue == "auto" }, "the child inherits Auto")
        _ = try? await client.interrupt(sessionID: parent)
    }

    /// The reviewer's endpoint: stateless (no session created), plain text back, cancellable.
    @Test func generateTextIsStatelessAndCancellable() async throws {
        let sandbox = try await Sandbox.start("generate")
        defer { Task { await sandbox.stop() } }
        let client = try await sandbox.client()
        let before = try await client.sessions(SessionListQuery(limit: 50)).data.count
        let model = try await client.defaultModel(directory: sandbox.project.path)
        let ref = model.map { ModelRef(id: $0.id, providerID: $0.providerID) }
        let clock = ContinuousClock()
        let started = clock.now
        let text = try await client.generateText(
            prompt: #"Reply with only this JSON object and nothing else: {"decision":"escalate","reason_code":"probe","explanation":"contract probe"}"#,
            model: ref, timeout: .seconds(60))
        let latency = clock.now - started
        let after = try await client.sessions(SessionListQuery(limit: 50)).data.count
        print("AUTO contract reviewer: model \(ref.map { "\($0.providerID)/\($0.id)" } ?? "-") latency \(latency) text \(text.prefix(200))")
        #expect(after == before, "generate.text creates no session")
        #expect(!text.isEmpty)
        // Cancellation: the task ends promptly with a cancellation, the server stays healthy.
        let task = Task { try await client.generateText(prompt: "Count slowly from 1 to 400.", model: ref, timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.result
        if case .success = result { Issue.record("a cancelled generation still returned") }
        _ = try await client.info()
    }

    /// One prompt in Auto, through the real engine: an in-project read is approved once by the policy (never shown) and
    /// the `.env` read is escalated to the existing card (then denied here).
    @Test func autoApprovesARoutineReadAndEscalatesASecret() async throws {
        let sandbox = try await Sandbox.start("auto-e2e")
        defer { Task { await sandbox.stop() } }
        let engine = sandbox.engine
        let thread = try await engine.createThread(in: sandbox.project.path, title: "auto e2e", permissionMode: .auto)
        let model = engine.openThread(thread.id)
        defer { model.close() }
        _ = try await engine.send(
            "Do these steps one at a time, in order. 1. Read the file README.md with your read tool. 2. Run the shell command `mkdir -p out` with your shell tool. "
                + "3. Read the file .env with your read tool. Then reply with exactly: DONE", to: thread.id)
        // Act as the person: any escalation that is not the secret is allowed once (and recorded); stop at the secret.
        var personAllowed: [String] = []
        var secret: BelloCore.PermissionRequest?
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(180)
        while secret == nil, clock.now < deadline {
            for request in model.pendingRequests {
                guard case .permission(let permission) = request else { continue }
                if permission.autoEscalation?.findings.contains(where: { $0.category == .secretRead }) == true {
                    secret = permission
                } else if !personAllowed.contains(permission.id.rawValue) {
                    personAllowed.append(permission.id.rawValue)
                    print("AUTO e2e escalated to the person: \(permission.action) \(permission.resources) \(permission.autoEscalation?.reasonCode ?? "-"): \(permission.autoEscalation?.explanation ?? "-")")
                    try? await engine.reply(to: permission.id, .once)
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        defer {
            let audit = engine.auto.audit[thread.id] ?? []
            print("AUTO e2e audit (final): \(audit.map { "\($0.kind.rawValue):\($0.action):\($0.source?.rawValue ?? "-"):\($0.reasonCode):\($0.model ?? "-"):\($0.latencyMilliseconds ?? -1)ms" })")
            // A provider refusal (the free tier's usage limit) ends the turn before any tool runs: say so.
            print("AUTO e2e turn error: \(model.session?.lastError?.message ?? "none")")
        }
        #expect(secret != nil, "the .env read was escalated")
        try? await waitUntil("README approved", timeout: .seconds(60)) {
            engine.auto.audit[thread.id]?.contains { $0.kind == .autoApproved && $0.action == "read" } == true
        }
        let audit = engine.auto.audit[thread.id] ?? []
        print("AUTO e2e audit: \(audit.map { "\($0.kind.rawValue):\($0.action):\($0.source?.rawValue ?? "-"):\($0.reasonCode):\($0.model ?? "-"):\($0.latencyMilliseconds ?? -1)ms" })")
        print("AUTO e2e reviewer model: \(engine.auto.reviewerModel.map { "\($0.providerID)/\($0.id)" } ?? "server default")")
        #expect(audit.contains { $0.kind == .autoApproved && $0.action == "read" })
        guard let request = secret else { return }
        try await engine.reply(to: request.id, .reject, message: "Not the secrets, please.")
        _ = try? await sandbox.client().interrupt(sessionID: thread.id.rawValue)
    }

    /// Two prompts: one thread runs long, another stops it with thread_interrupt (same project, no approval).
    @Test func sameProjectInterruptIsAttributedAndHeld() async throws {
        let sandbox = try await Sandbox.start("interrupt")
        defer { Task { await sandbox.stop() } }
        let engine = sandbox.engine
        let target = try await engine.createThread(in: sandbox.project.path, title: "long runner", permissionMode: .fullAccess)
        let caller = try await engine.createThread(in: sandbox.project.path, title: "supervisor", permissionMode: .fullAccess)
        let model = engine.openThread(target.id)
        defer { model.close() }
        _ = try await engine.send("Write the numbers from 1 to 400 in words, one per line. Do not use tools.", to: target.id)
        try await waitUntil("target running", timeout: .seconds(60)) { engine.orchestration.status(of: target.id)?.isActive == true }
        _ = try await engine.send(
            "Call the thread_interrupt tool exactly once with threadID \(target.id.rawValue) and reason 'contract test of interrupts'. Then reply with exactly: STOPPED",
            to: caller.id)
        try await waitUntil("held", timeout: .seconds(180)) { model.heldInterrupt != nil }
        let record = try #require(model.heldInterrupt)
        print("AUTO e2e interrupt: \(record)")
        #expect(record.by == caller.id.rawValue)
        #expect(record.reason == "contract test of interrupts")
        #expect(record.actual == "stopped" || record.actual == "still_running")
        let client = try await sandbox.client()
        // Nobody approved anything: no permission request was raised in the caller.
        #expect(try await client.permissions(sessionID: caller.id.rawValue).isEmpty)
        // The stopped thread's attributed note is parked in its inbox (non-waking input waits for the next run, verified
        // by probeSyntheticWithoutResume) and it is not running again.
        let inbox = try await client.inbox(sessionID: target.id.rawValue)
        #expect(inbox.contains { ($0.text ?? "").hasPrefix("[BelloCode interrupt]") && ($0.text ?? "").contains("supervisor") })
        #expect(engine.orchestration.status(of: target.id)?.isActive != true)
    }

    /// No prompt: where a non-waking synthetic note lands (message list or inbox) on an idle session.
    @Test func probeSyntheticWithoutResume() async throws {
        let sandbox = try await Sandbox.start("synthetic")
        defer { Task { await sandbox.stop() } }
        let client = try await sandbox.client()
        let id = try await session(sandbox, "probe", rules: [PermissionRule(action: "*", resource: "*", effect: .allow)])
        try await client.postSynthetic(sessionID: id, text: "[BelloCode interrupt] probe", resume: false)
        try await Task.sleep(for: .seconds(1))
        let messages = try await client.messages(sessionID: id, MessageListQuery(limit: 20)).data
        let inbox = try await client.inbox(sessionID: id)
        print("AUTO probe synthetic: messages \(messages.map(\.type)) inbox \(inbox.count)")
        let busy = try await client.session(id).time.busy
        print("AUTO probe synthetic: busy \(busy ?? -1)")
    }
}
