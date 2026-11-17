import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Synchronization
import Testing

@testable import Engine

/// The mock's current endpoint, which changes when it restarts on a new port.
final class EndpointBox: Sendable {
    private let value: Mutex<ServerConnection?>
    init(_ connection: ServerConnection?) { value = Mutex(connection) }
    func set(_ connection: ServerConnection?) { value.withLock { $0 = connection } }
    func get() -> ServerConnection? { value.withLock { $0 } }
}

@MainActor
func makeEngine(
    _ harness: MockHarness, store: ProjectionStore.Location = .inMemory, box: EndpointBox? = nil
) throws -> Engine {
    let source: ServerSource
    if let box {
        source = .dynamic { box.get() }
    } else {
        source = .fixed(harness.connection)
    }
    var configuration = EngineConfiguration(server: source, store: store)
    configuration.eventBackoff = BackoffPolicy(initial: .milliseconds(20), maximum: .milliseconds(200))
    configuration.writeInterval = .milliseconds(20)
    return try Engine(configuration: configuration)
}

@MainActor
func waitUntil(
    _ message: String = "condition", timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else {
            Issue.record("timed out waiting for \(message)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
func userMessages(_ thread: ThreadModel) -> [Message] {
    thread.messageIDs.compactMap { thread.message($0)?.message }.filter { $0.kind.typeName == "user" }
}

@Suite("Engine flows against MockOpenCode", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct EngineFlowTests {
    @Test func scriptedTurnWithPermissionAndQuestion() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let project = try #require(engine.root.projects.first)
        #expect(project.directory == "/tmp/mock-project")

        let session = try await engine.createThread(in: project.directory, title: "Tour")
        let projectModel = await engine.project(session.projectID)
        try await waitUntil("row") { projectModel.sessionIDs.contains(session.id) }
        let thread = engine.openThread(session.id)
        try await waitUntil("thread ready") { thread.phase == .ready }
        func expect(_ ok: Bool, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) async {
            await check(ok, what, harness, engine, thread, sourceLocation: sourceLocation)
        }
        do {
            // Hold the prompt response so the optimistic message is observable before the server answers.
            await harness.server.injectHTTPFault(HTTPFault(method: "POST", pathPrefix: "/api/session/\(session.id.rawValue)/prompt", action: .delay(.milliseconds(300))))
            thread.draft = "Give me the tour #script:full-tour"
            let send = Task { await thread.send() }
            try await waitUntil("optimistic message") { userMessages(thread).count == 1 }
            await expect(userMessages(thread).first?.delivery == .sending, "not delivered before the server acknowledged")
            await expect(thread.draft.isEmpty, "thread.draft.isEmpty")
            let sentID = await send.value
            await expect(sentID != nil, "sentID != nil")

            try await waitUntil("approval pending") { !thread.pendingRequests.isEmpty }
            await expect(thread.status?.status == .awaitingApproval, "thread.status?.status == .awaitingApproval")
            // The thread and the root summary are separate subscribers (topics `.thread` and `.attention`), applied by
            // separate tasks: the summary follows within a turn of the main actor, not necessarily in the same one.
            try await waitUntil("approval counted") { engine.root.attention.counts.approvals == 1 }
            await expect(engine.root.attention.items.first?.sessionID == session.id, "engine.root.attention.items.first?.sessionID == session.id")
            guard case .permission(let permission) = thread.pendingRequests[0] else { Issue.record("expected a permission"); return }
            await expect(permission.action == "edit", "permission.action == 'edit'")
            await expect(permission.alwaysScopes == ["README.md"], "permission.alwaysScopes == ['README.md']")
            await thread.reply(to: permission.id, .once)
            await expect(thread.lastError == nil, "thread.lastError == nil")

            try await waitUntil("question pending") { thread.pendingRequests.contains { !$0.isPermission } }
            try await waitUntil("question counted") { engine.root.attention.counts.questions == 1 }
            guard case .question(let question) = thread.pendingRequests[0] else { Issue.record("expected a question"); return }
            await expect(question.fields.first?.options.map(\.value) == ["swift test", "make test"], "the question offers the two runners")
            await thread.answer(question.id, ["runner": .text("swift test")])
            await expect(thread.lastError == nil, "thread.lastError == nil")

            await harness.server.waitUntilAllIdle()
            try await waitUntil("turn finished") { thread.status?.status == .finishedUnread }
            try await waitUntil("unread counted") { engine.root.attention.counts.unread == 1 }
            await expect(thread.pendingRequests.isEmpty, "thread.pendingRequests.isEmpty")

            // Exactly one user message: the optimistic one, now delivered, under the server's ID.
            let users = userMessages(thread)
            await expect(users.count == 1, "users.count == 1")
            await expect(users.first?.id == sentID, "users.first?.id == sentID")
            await expect(users.first?.delivery == .delivered, "users.first?.delivery == .delivered")

            await thread.markViewed()
            try await waitUntil("viewed") { thread.status?.status == .idle }
            try await waitUntil("attention cleared") { engine.root.attention.items.isEmpty }

            // The live projection and the cache equal the list endpoints.
            await engine.flush()
            // The thread model applies changes on its own task: wait until it has applied everything flushed.
            try await threadBarrier(engine, thread)
            let listed = try await harness.listedMessages(session.id)
            let shown = thread.messageIDs.compactMap { thread.message($0)?.message }
            await expect(normalized(shown) == normalized(listed), "normalized(shown) == normalized(listed)")
            #expect(normalized(try await engine.store.allMessages(sessionID: session.id)) == normalized(listed))
        } catch {
            Issue.record(Comment(rawValue: "\(error)\n" + (await engineDiagnostics(harness, engine, thread))))
        }
        thread.close()
        await engine.stop()
        await harness.stop()
    }

    @Test func sendFailureRollsBackAndRestoresDraft() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        let thread = engine.openThread(session.id)
        try await waitUntil("ready") { thread.phase == .ready }
        await harness.server.injectHTTPFault(.status(500, method: "POST", pathPrefix: "/api/session/\(session.id.rawValue)/prompt"))
        thread.draft = "this will fail"
        let id = await thread.send()
        #expect(id == nil)
        #expect(thread.lastError == .server("Injected failure"))
        #expect(thread.draft == "this will fail")
        // The rollback reaches the model through the change bus: wait for it in order, not by luck.
        try await threadBarrier(engine, thread)
        #expect(userMessages(thread).isEmpty)
        #expect(thread.queue.isEmpty)
        thread.close()
        await engine.stop()
        await harness.stop()
    }

    @Test func queueSteerAndStopWhileRunning() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        let thread = engine.openThread(session.id)
        try await waitUntil("ready") { thread.phase == .ready }
        // A turn that blocks on a question keeps the session running.
        await harness.server.enqueueScript(TurnScript { TurnStep.question("Wait", options: ["ok"]) }, for: session.id.rawValue)
        await thread.send("first")
        try await waitUntil("running") { thread.isRunning && !thread.pendingRequests.isEmpty }
        #expect(thread.sendMode == .queue)

        let queued = await thread.send("second")
        let dropped = await thread.send("third")
        try await waitUntil("two queued") { thread.queue.count == 2 && thread.queue.allSatisfy { $0.state == .queued } }
        #expect(thread.queue.map(\.id) == [queued, dropped].compactMap { $0 })
        #expect(thread.queue.allSatisfy { $0.delivery == .queue })
        await thread.steer(queued!)
        #expect(thread.queue.first?.delivery == .steer)
        await thread.cancelQueued(dropped!)
        #expect(thread.queue.map(\.id) == [queued!])

        await thread.stop()
        #expect(thread.lastError == nil)
        try await waitUntil("stopped") { !thread.isRunning || thread.status?.status == .stopping }
        try await waitUntil("interrupt confirmed") { thread.status?.status != .stopping && thread.status?.status != .running }
        #expect(thread.pendingRequests.isEmpty, "the interrupted turn's question is withdrawn")
        thread.close()
        await engine.stop()
        await harness.stop()
    }

    @Test func renameArchiveDeleteAndModelAgentMode() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project", title: "Old")
        let projectModel = await engine.project(session.projectID)
        try await waitUntil("row") { projectModel.row(session.id) != nil }
        try await engine.renameThread(session.id, to: "New")
        try await waitUntil("renamed") { projectModel.row(session.id)?.session.title == "New" }
        try await engine.setModel(ModelSelection(providerID: "opencode", modelID: "big-pickle"), for: session.id)
        try await engine.setAgent("plan", for: session.id)
        try await engine.setPermissionMode(.autoEdit, for: session.id)
        try await waitUntil("server echo") { projectModel.row(session.id)?.session.agent == "plan" }
        let server = try await harness.client.session(session.id.rawValue)
        #expect(server.title == "New")
        #expect(server.agent == "plan")
        #expect(server.model?.id == "big-pickle")
        #expect(server.permissions.flatMap(PermissionModeRules.mode(from:)) == .autoEdit)

        // A failed rename rolls back.
        await harness.server.injectHTTPFault(.status(500, method: "PATCH", pathPrefix: "/api/session/\(session.id.rawValue)"))
        await #expect(throws: EngineError.self) { try await engine.renameThread(session.id, to: "Broken") }
        try await waitUntil("rolled back") { projectModel.row(session.id)?.session.title == "New" }

        try await engine.setArchived(session.id, true)
        try await waitUntil("archived") { projectModel.archivedSessionIDs.contains(session.id) }
        try await engine.deleteThread(session.id)
        try await waitUntil("row removed") { projectModel.row(session.id) == nil }
        #expect(try await harness.client.sessions().data.isEmpty)
        await engine.stop()
        await harness.stop()
    }

    @Test func childBlockerBubblesToParentInEngine() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        let script = TurnScript {
            TurnStep.subagent(agent: "explore", description: "Ask", prompt: "Ask the user") {
                TurnStep.question("Child asks", options: ["a"])
            }
        }
        await harness.server.enqueueScript(script, for: session.id.rawValue)
        _ = try await engine.send("go", to: session.id)
        try await waitUntil("child blocker") { engine.root.attention.counts.questions == 1 }
        let item = try #require(engine.root.attention.items.first)
        #expect(item.sessionID == session.id)
        #expect(item.status == .awaitingAnswer)
        let child = try #require(item.blockingChildID)
        let forms = await harness.server.pendingForms()
        try await engine.answer(QuestionID(forms[0].id), ["answer": .text("a")])
        try await waitUntil("cleared") { engine.root.attention.counts.questions == 0 }
        _ = child
        await harness.server.waitUntilAllIdle()
        await engine.stop()
        await harness.stop()
    }
}
