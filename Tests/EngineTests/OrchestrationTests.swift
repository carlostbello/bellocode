import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

private func session(
    _ id: String, parent: String? = nil, project: String = "p1", busy: Int64? = nil, idle: Int64? = nil,
    outcome: BelloCore.SessionOutcome? = nil, metadata: String? = nil, created: Int64 = 1
) -> Session {
    Session(
        id: SessionID(id), projectID: ProjectID(project), parentID: parent.map { SessionID($0) }, title: id,
        directory: "/p/\(project)", created: Timestamp(milliseconds: Double(created)), updated: Timestamp(milliseconds: Double(created)),
        busySince: busy.map { Timestamp(milliseconds: Double($0)) }, idleAt: idle.map { Timestamp(milliseconds: Double($0)) },
        outcome: outcome, metadata: metadata.map { RawJSON($0) })
}

private func attention(_ id: String, _ status: BelloCore.SessionStatus, blockingChild: String? = nil) -> SessionAttention {
    SessionAttention(
        sessionID: SessionID(id), projectID: ProjectID("p1"), status: status, since: Timestamp(milliseconds: 5),
        blockingChildID: blockingChild.map { SessionID($0) })
}

@Suite("Orchestration: task state machine and graph", .timeLimit(.minutes(3)))
struct TaskGraphTests {
    @Test func ownStatusFromRunStateAndAttention() {
        let running = session("a", busy: 10)
        #expect(TaskStateMachine.ownStatus(session: running, attention: nil) == .running)
        #expect(TaskStateMachine.ownStatus(session: session("a", busy: 1, idle: 2, outcome: .succeeded), attention: nil) == .done)
        #expect(TaskStateMachine.ownStatus(session: session("a", busy: 1, idle: 2, outcome: .interrupted), attention: nil) == .stopped)
        #expect(TaskStateMachine.ownStatus(session: session("a", busy: 1, idle: 2, outcome: .failed), attention: nil) == .failed)
        #expect(TaskStateMachine.ownStatus(session: session("a"), attention: nil) == .idle)
        #expect(TaskStateMachine.ownStatus(session: running, attention: attention("a", .awaitingApproval)) == .needsApproval)
        #expect(TaskStateMachine.ownStatus(session: running, attention: attention("a", .awaitingAnswer)) == .needsAnswer)
        #expect(TaskStateMachine.ownStatus(session: running, attention: attention("a", .stopping)) == .stopping)
        // A blocker that bubbled up from a child is the child's, not this session's.
        let bubbled = attention("a", .awaitingApproval, blockingChild: "c")
        #expect(TaskStateMachine.ownStatus(session: session("a", busy: 1, idle: 2, outcome: .succeeded), attention: bubbled) == .done)
        // Seen or unseen, a finished run is done.
        #expect(TaskStateMachine.ownStatus(session: session("a", busy: 1, idle: 2, outcome: .succeeded), attention: attention("a", .finishedUnread)) == .done)
    }

    @Test func parentThatFinishedWhileChildrenRunIsWaitingNotDone() {
        #expect(TaskStateMachine.status(own: .done, children: [.running]) == .waitingOnChildren)
        #expect(TaskStateMachine.status(own: .idle, children: [.needsApproval]) == .waitingOnChildren)
        #expect(TaskStateMachine.status(own: .done, children: [.done, .failed]) == .done)
        #expect(TaskStateMachine.status(own: .running, children: [.running]) == .running)
        #expect(TaskStateMachine.status(own: .needsAnswer, children: [.running]) == .needsAnswer)
        #expect(TaskStateMachine.status(own: .stopped, children: [.running]) == .stopping)
        #expect(TaskStateMachine.status(own: .stopped, children: [.stopped]) == .stopped)
        #expect(TaskStateMachine.status(own: .waitingOnChildren, children: []) == .done)
    }

    @Test func kindsFromParentLinksAndPluginMetadata() {
        let delegated = #"{"bellocode":{"kind":"delegated","by":"root","description":"Fix it","summary":"Fixed."}}"#
        let created = #"{"bellocode":{"kind":"created","by":"root","group":"grp_1"}}"#
        #expect(TaskStateMachine.kind(session: session("t"), metadata: nil) == .thread)
        #expect(TaskStateMachine.kind(session: session("c", parent: "t"), metadata: nil) == .subagent)
        #expect(TaskStateMachine.kind(session: session("c", parent: "t"), metadata: OrchestrationMetadata.from(RawJSON(delegated))) == .delegated)
        #expect(TaskStateMachine.kind(session: session("n"), metadata: OrchestrationMetadata.from(RawJSON(created))) == .created)
        #expect(OrchestrationMetadata.from(RawJSON(delegated))?.summary == "Fixed.")
        #expect(OrchestrationMetadata.from(RawJSON("not json")) == nil)
        #expect(OrchestrationMetadata.from(nil) == nil)
    }

    @Test func graphPropagatesStatusUpAndCountsDescendants() {
        var graph = TaskGraph()
        // Children before parents (resync order is not guaranteed).
        graph.apply(sessions: [
            session("c2", parent: "c1", busy: 10, created: 3),
            session("c1", parent: "root", busy: 1, idle: 2, outcome: .succeeded, created: 2),
            session("root", busy: 1, idle: 2, outcome: .succeeded, created: 1),
            session("c3", parent: "root", busy: 1, idle: 2, outcome: .failed, created: 4),
        ])
        #expect(graph.nodes[SessionID("c2")]?.status == .running)
        #expect(graph.nodes[SessionID("c1")]?.status == .waitingOnChildren)
        #expect(graph.nodes[SessionID("root")]?.status == .waitingOnChildren)
        #expect(graph.rows(under: SessionID("root")).map { "\($0.id.rawValue):\($0.depth)" } == ["root:0", "c1:1", "c2:2", "c3:1"])
        #expect(graph.root(of: SessionID("c2")) == SessionID("root"))
        #expect(graph.ancestors(of: SessionID("c2")) == [SessionID("c1"), SessionID("root")])
        let aggregate = graph.aggregate(under: SessionID("root"))
        #expect(aggregate.total == 3)
        #expect(aggregate.text == "2 running · 1 failed")

        // The grandchild asks for approval: bubbled to the root by the attention model; counted once as "needs you".
        let changed = graph.apply(
            sessions: [], statuses: [attention("c2", .awaitingApproval), attention("root", .awaitingApproval, blockingChild: "c2")])
        #expect(graph.nodes[SessionID("c2")]?.status == .needsApproval)
        #expect(graph.nodes[SessionID("root")]?.blockingChildID == SessionID("c2"))
        #expect(graph.nodes[SessionID("root")]?.ownStatus == .done)
        #expect(changed.roots == [SessionID("root")])
        #expect(graph.aggregate(under: SessionID("root")).text == "1 running · 1 needs you · 1 failed")

        // Everything settles: the parent is done, not waiting.
        graph.apply(
            sessions: [session("c2", parent: "c1", busy: 10, idle: 20, outcome: .succeeded, created: 3)],
            statuses: [attention("c2", .idle), attention("root", .finishedUnread)])
        #expect(graph.nodes[SessionID("c1")]?.status == .done)
        #expect(graph.nodes[SessionID("root")]?.status == .done)
        #expect(graph.aggregate(under: SessionID("root")).text == "1 failed")

        graph.apply(sessions: [], removed: [SessionID("c1")])
        #expect(graph.children[SessionID("root")] == [SessionID("c3")])
    }

    @Test func aggregateTextUsesWordsAndPlurals() {
        var aggregate = LineageAggregate()
        #expect(aggregate.text.isEmpty)
        aggregate.add(.done)
        aggregate.add(.done)
        #expect(aggregate.text == "2 done")
        aggregate.add(.needsAnswer)
        aggregate.add(.needsApproval)
        #expect(aggregate.text == "2 need you")
    }
}

@MainActor
@Suite("Orchestration service against the mock", .serialized, .timeLimit(.minutes(3)))
struct OrchestrationServiceTests {
    @MainActor struct Fixture {
        let harness: MockHarness
        let engine: Engine

        /// `realTime`: scripted delays really wait (needed to observe a child while it runs).
        static func start(store: ProjectionStore.Location = .inMemory, realTime: Bool = false) async throws -> Fixture {
            let harness = try await MockHarness.start(
                options: realTime ? MockServerOptions(clock: .realTime, heartbeatInterval: nil) : .testing)
            await harness.server.setChildReports(true)
            let engine = try makeEngine(harness, store: store)
            await engine.start()
            try await waitUntil("live") { engine.root.connection == .live }
            return Fixture(harness: harness, engine: engine)
        }

        func stop() async {
            await engine.stop()
            await harness.stop()
        }
    }

    /// A parent that delegates one task; the child replies after `childDelay` ms; the woken parent replies "GOT".
    private static func delegateScripts(childDelay: Int, childSteps: [TurnStep] = []) -> (parent: TurnScript, wake: TurnScript) {
        let parent = TurnScript(steps: [
            .text("Delegating."),
            .delegate(description: "Count files", task: "Count the Swift files.") {
                TurnStep.delay(childDelay)
                childSteps
                TurnStep.text("There are 42 Swift files.")
            },
            .text("Started a child task."),
        ])
        return (parent, TurnScript(steps: [.text("GOT 42")]))
    }

    @Test func delegatedChildWakesParentExactlyOnceAndCardsFollowTheChild() async throws {
        let fixture = try await Fixture.start(realTime: true)
        defer { Task { await fixture.stop() } }
        let engine = fixture.engine
        let parent = try await engine.createThread(in: "/tmp/mock-orch", title: "parent")
        let scripts = Self.delegateScripts(childDelay: 3_000)  // long enough to observe the running child on a loaded machine
        await fixture.harness.server.enqueueScript(scripts.parent, for: parent.id.rawValue)
        await fixture.harness.server.enqueueScript(scripts.wake, for: parent.id.rawValue)
        let thread = engine.openThread(parent.id)
        defer { thread.close() }
        try await waitUntil("thread ready") { thread.phase == .ready }
        _ = try await engine.send("Delegate the count", to: parent.id)

        let orchestration = engine.orchestration!
        try await waitUntil("child appears") { !orchestration.children(of: parent.id).isEmpty }
        let child = try #require(orchestration.children(of: parent.id).first)
        try await waitUntil("parent waits on its child") { orchestration.status(of: parent.id) == .waitingOnChildren }
        #expect(orchestration.isWaitingOnChildren(parent.id))
        #expect(orchestration.node(child)?.node.kind == .delegated)
        #expect(orchestration.lineage(containing: child).rootID == parent.id)
        #expect(orchestration.aggregate(under: parent.id).text == "1 running")

        // The transcript card for delegate_task points at the child and shows its live state.
        func card() -> SubagentReference? {
            for id in thread.messageIDs {
                for part in thread.message(id)?.message.parts ?? [] {
                    if case .subagent(let reference) = part.content { return reference }
                }
            }
            return nil
        }
        try await waitUntil("card shows running") { card()?.liveStatus == .running }
        #expect(card()?.childSessionID == child)
        #expect(card()?.call.name == OrchestrationContract.Tool.delegateTask)

        await fixture.harness.server.waitUntilAllIdle()
        try await waitUntil("parent done") { orchestration.status(of: parent.id) == .done }
        try await waitUntil("card shows done") { card()?.liveStatus == .done }
        try await waitUntil("summary") { orchestration.node(child)?.node.summary == "There are 42 Swift files." }

        let reports = await fixture.harness.server.messages(parent.id.rawValue).filter {
            if case .raw(let type, _) = $0.kind { type == "synthetic" } else { false }
        }
        #expect(reports.count == 1)
        let replies = await fixture.harness.server.messages(parent.id.rawValue).compactMap { message -> String? in
            guard case .assistant(let assistant) = message.kind else { return nil }
            return assistant.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
        }
        #expect(replies.filter { $0 == "GOT 42" }.count == 1)
    }

    @Test func stoppingAParentCascadesWithoutRestartingIt() async throws {
        let fixture = try await Fixture.start(realTime: true)
        defer { Task { await fixture.stop() } }
        let engine = fixture.engine
        let parent = try await engine.createThread(in: "/tmp/mock-orch", title: "parent")
        let scripts = Self.delegateScripts(childDelay: 30_000)
        await fixture.harness.server.enqueueScript(scripts.parent, for: parent.id.rawValue)
        _ = try await engine.send("Delegate", to: parent.id)
        let orchestration = engine.orchestration!
        try await waitUntil("child running") {
            orchestration.children(of: parent.id).first.flatMap { orchestration.status(of: $0) } == .running
        }
        let child = try #require(orchestration.children(of: parent.id).first)
        try await orchestration.stopTree(parent.id)
        try await waitUntil("child stopped") { orchestration.status(of: child) == .stopped }
        try await waitUntil("parent settled") {
            let status = orchestration.status(of: parent.id)
            return status == .stopped || status == .done
        }
        try await Task.sleep(for: .milliseconds(200))
        let session = await fixture.harness.server.session(parent.id.rawValue)
        #expect(session?.busy == nil)
        #expect(orchestration.status(of: parent.id) != .running)
    }

    @Test func childApprovalBubblesToTheParentAndItsAggregate() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let engine = fixture.engine
        let parent = try await engine.createThread(in: "/tmp/mock-orch", title: "parent")
        let scripts = Self.delegateScripts(
            childDelay: 10,
            childSteps: [.tool("shell", input: ["command": "rm -rf build"], output: "ok", permission: PermissionAsk(action: "shell", resources: ["rm -rf build"]))])
        await fixture.harness.server.enqueueScript(scripts.parent, for: parent.id.rawValue)
        let thread = engine.openThread(parent.id)
        defer { thread.close() }
        _ = try await engine.send("Delegate", to: parent.id)
        let orchestration = engine.orchestration!
        try await waitUntil("parent sees the child's approval") { !thread.pendingRequests.isEmpty }
        let child = try #require(orchestration.children(of: parent.id).first)
        try await waitUntil("child needs approval") { orchestration.status(of: child) == .needsApproval }
        #expect(orchestration.aggregate(under: parent.id).needsYou == 1)
        // The root summary is its own subscriber (topic `.attention`); it follows the thread within a main-actor turn.
        try await waitUntil("root summary names the blocking child") {
            engine.root.attention.items.contains { $0.sessionID == parent.id && $0.blockingChildID == child }
        }
        let request = try #require(thread.pendingRequests.first)
        guard case .permission(let permission) = request else { Issue.record("expected a permission"); return }
        try await engine.reply(to: permission.id, .reject)
        try await waitUntil("approval resolved") { thread.pendingRequests.isEmpty }
    }

    @Test func pluginStatusComesFromBellocodeInfo() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let orchestration = fixture.engine.orchestration!
        try await waitUntil("plugin ready") { orchestration.pluginStatus.isReady }
        #expect(orchestration.pluginStatus == .ready(tools: OrchestrationContract.Tool.all.count))
        await fixture.harness.server.setOrchestrationPlugin(false)
        await orchestration.checkPlugin(directory: "/tmp/mock-orch")
        #expect(orchestration.pluginStatus == .unavailable("the bellocode plugin is not loaded"))
    }

    @Test func appToolsAreScopedToTheCallersProject() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let engine = fixture.engine
        let orchestration = engine.orchestration!
        let caller = try await engine.createThread(in: "/tmp/mock-orch-a", title: "caller")
        let sibling = try await engine.createThread(in: "/tmp/mock-orch-a", title: "sibling")
        let foreign = try await engine.createThread(in: "/tmp/mock-orch-b", title: "foreign")
        try await waitUntil("graph has all three") { orchestration.node(foreign.id) != nil && orchestration.node(sibling.id) != nil }
        var revealed: [SessionID] = []
        orchestration.revealThread = { revealed.append($0); return true }

        func call(_ tool: String, _ arguments: OpenCodeKit.JSONValue, session: String?) async -> ClientMCPResult {
            await orchestration.handleAppTool(ClientMCPCall(tool: tool, arguments: arguments, sessionID: session, directory: "/tmp/mock-orch-a"))
        }
        let unattributed = await call(AppTools.openThread, OpenCodeKit.JSONValue.object(["threadID": .string(sibling.id.rawValue)]), session: nil)
        #expect(unattributed.isError)
        let ok = await call(AppTools.openThread, OpenCodeKit.JSONValue.object(["threadID": .string(sibling.id.rawValue)]), session: caller.id.rawValue)
        #expect(!ok.isError)
        #expect(revealed == [sibling.id])
        let refused = await call(AppTools.openThread, OpenCodeKit.JSONValue.object(["threadID": .string(foreign.id.rawValue)]), session: caller.id.rawValue)
        #expect(refused.isError)
        #expect(refused.text.contains("another project"))
        let queue = await call(AppTools.queue, OpenCodeKit.JSONValue.object(["action": .string("list")]), session: caller.id.rawValue)
        #expect(queue.text.contains("No queued messages"))
        let badAction = await call(AppTools.queue, OpenCodeKit.JSONValue.object(["action": .string("explode")]), session: caller.id.rawValue)
        #expect(badAction.isError)
    }

    @Test func treeIsRebuiltFromTheCacheOnRelaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "orch-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try await Fixture.start(store: .file(url))
        let engine = fixture.engine
        let parent = try await engine.createThread(in: "/tmp/mock-orch", title: "parent")
        let scripts = Self.delegateScripts(childDelay: 10)
        await fixture.harness.server.enqueueScript(scripts.parent, for: parent.id.rawValue)
        _ = try await engine.send("Delegate", to: parent.id)
        await fixture.harness.server.waitUntilAllIdle()
        let orchestration = engine.orchestration!
        try await waitUntil("child with summary") {
            orchestration.children(of: parent.id).first.flatMap { orchestration.node($0)?.node.summary } != nil
        }
        let child = try #require(orchestration.children(of: parent.id).first)
        await engine.flush()
        await fixture.stop()

        // Relaunch with no server at all: the tree comes from the cache.
        var configuration = EngineConfiguration(server: .dynamic { nil }, store: .file(url))
        configuration.writeInterval = .milliseconds(20)
        let relaunched = try Engine(configuration: configuration)
        await relaunched.start()
        defer { Task { await relaunched.stop() } }
        try await waitUntil("tree from cache") { relaunched.orchestration.children(of: parent.id) == [child] }
        #expect(relaunched.orchestration.node(child)?.node.kind == .delegated)
        #expect(relaunched.orchestration.node(child)?.node.summary == "There are 42 Swift files.")
    }
}
