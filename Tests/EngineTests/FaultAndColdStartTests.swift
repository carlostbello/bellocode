import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// Message content without IDs, for comparing two runs whose IDs differ.
func signature(_ messages: [Message]) -> [String] {
    normalized(messages).map { message in
        "\(message.kind) \(message.detail) " + message.parts.map(\.summary).joined(separator: " | ")
    }
}

@Suite("Faults and cold start", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct FaultAndColdStartTests {
    static func script(faults: Bool) -> TurnScript {
        var steps: [TurnStep] = [
            .reasoning("Plan the work carefully.", chunkSize: 3, rate: 200),
            .text("First part of the answer, streamed in small pieces. ", chunkSize: 3, rate: 200),
        ]
        if faults { steps.append(.duplicateNextEvent) }
        steps.append(.text("Second part, with émoji 🚀 and accents.", chunkSize: 2, rate: 200))
        if faults { steps.append(.dropEventStreams) }
        steps.append(.text("Third part, written while the stream was down.", chunkSize: 3, rate: 200))
        steps.append(
            .tool(
                "edit", input: ["path": "a.txt"], output: "Edited a.txt",
                permission: PermissionAsk(action: "edit", resources: ["a.txt"], save: ["a.txt"])))
        steps.append(.question("Proceed?", key: "go", options: ["yes", "no"]))
        if faults { steps.append(.duplicateNextEvent) }
        steps.append(.text(String(repeating: "Closing words streamed fast. ", count: 20), chunkSize: 4, rate: 200))
        return TurnScript(name: faults ? "faulty" : "clean", steps: steps)
    }

    /// Runs the scripted turn through the engine; with `faults`, the event stream is cut into random pieces, two events
    /// are duplicated, the stream drops mid-text, and the server restarts on a new port while a permission is pending.
    func run(faults: Bool) async throws -> (shown: [Message], cached: [Message], listed: [Message], engine: Engine, harness: MockHarness) {
        let harness = try await MockHarness.start()
        let box = EndpointBox(harness.connection)
        let engine = try makeEngine(harness, box: box)
        if faults { await harness.server.setEventSplitting(.seeded(seed: 7, maxPiece: 5)) }
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        let thread = engine.openThread(session.id)
        try await waitUntil("ready") { thread.phase == .ready }
        await harness.server.enqueueScript(Self.script(faults: faults), for: session.id.rawValue)
        await thread.send("Please edit a.txt")

        try await waitUntil("permission") { thread.pendingRequests.contains { $0.isPermission } }
        if faults {
            let endpoint = try await harness.server.restart()
            box.set(ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? "")))
            try await waitUntil("resynced after restart") { engine.root.connection == .live && thread.pendingRequests.contains { $0.isPermission } }
        }
        guard case .permission(let permission) = thread.pendingRequests.first(where: \.isPermission) else { throw CancellationError() }
        await thread.reply(to: permission.id, .once)
        #expect(thread.lastError == nil)
        try await waitUntil("question") { thread.pendingRequests.contains { !$0.isPermission } }
        guard case .question(let question) = thread.pendingRequests.first(where: { !$0.isPermission }) else { throw CancellationError() }
        await thread.answer(question.id, ["go": .text("yes")])
        await harness.server.waitUntilAllIdle()
        try await waitUntil("finished") { thread.status?.status == .finishedUnread }
        await engine.flush()
        let listed = try await HarnessView(harness: harness, box: box).listedMessages(session.id)
        let shown = thread.messageIDs.compactMap { thread.message($0)?.message }
        let cached = try await engine.store.allMessages(sessionID: session.id)
        thread.close()
        return (shown, cached, listed, engine, harness)
    }

    @Test func faultyRunEndsIdenticalToFaultFreeRun() async throws {
        let clean = try await run(faults: false)
        #expect(normalized(clean.shown) == normalized(clean.listed))
        #expect(normalized(clean.cached) == normalized(clean.listed))
        await clean.engine.stop()
        await clean.harness.stop()

        let faulty = try await run(faults: true)
        #expect(normalized(faulty.shown) == normalized(faulty.listed), "no lost or duplicated messages after resync")
        #expect(normalized(faulty.cached) == normalized(faulty.listed))
        #expect(signature(faulty.listed) == signature(clean.listed))
        #expect(signature(faulty.shown) == signature(clean.shown))
        let statistics = await faulty.engine.core.statistics
        #expect(statistics.resyncs >= 3, "initial connect, the dropped stream and the restart")
        #expect(statistics.duplicatesDropped >= 1)
        #expect(faulty.engine.root.attention.counts.approvals == 0)
        await faulty.engine.stop()
        await faulty.harness.stop()
    }

    /// The flake behind `faultyRunEndsIdenticalToFaultFreeRun`: the engine mints the prompt ID from the server clock
    /// extrapolated with real time, while the mock's virtual clock stands still between events. Real time passing
    /// before a send (load) put the prompt ID ahead of the answering step's ID; with equal `created` the answer sorted
    /// above the prompt. Waiting here guarantees the ID runs ahead (no events arrive while the session is idle).
    @Test func promptStaysAboveItsAnswerWhenTheClockEstimateRunsAhead() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        let thread = engine.openThread(session.id)
        try await waitUntil("ready") { thread.phase == .ready }
        try await Task.sleep(for: .milliseconds(20))
        await thread.send("hello #script:greeting")
        await harness.server.waitUntilAllIdle()
        try await waitUntil("finished") { thread.status?.status == .finishedUnread }
        await engine.flush()
        try await threadBarrier(engine, thread)
        let shown = thread.messageIDs.compactMap { thread.message($0)?.message }
        #expect(shown.map(\.kind.typeName) == ["user", "assistant"])
        #expect(normalized(shown) == normalized(try await harness.listedMessages(session.id)))
        thread.close()
        await engine.stop()
        await harness.stop()
    }

    @Test func coldStartShowsCachedContentBeforeTheServerIsReady() async throws {
        let directory = Fixtures.temporaryDirectory()
        let url = directory.appending(path: "projection.sqlite")
        let harness = try await MockHarness.start()

        // First launch: create a thread and run a turn, then quit.
        let first = try makeEngine(harness, store: .file(url))
        await first.start()
        try await waitUntil("live") { first.root.connection == .live }
        let session = try await first.createThread(in: "/tmp/mock-project", title: "Cached thread")
        let thread = first.openThread(session.id)
        thread.draft = "unsent words"
        await thread.send("hello #script:greeting")
        await harness.server.waitUntilAllIdle()
        try await waitUntil("reply") { thread.status?.status == .finishedUnread }
        thread.draft = "unsent words"
        let expected = thread.messageIDs
        #expect(expected.compactMap { thread.message($0)?.message.kind.typeName } == ["user", "assistant"])
        thread.close()
        await first.stop()

        // Second launch with no server reachable.
        let box = EndpointBox(nil)
        let second = try makeEngine(harness, store: .file(url), box: box)
        let clock = ContinuousClock()
        let launchStart = clock.now
        await second.start()
        let launch = clock.now - launchStart
        #expect(second.root.connection == .cached || second.root.connection == .connecting)
        #expect(second.root.projects.map(\.directory) == ["/tmp/mock-project"])
        let projectModel = try #require(second.root.project(session.projectID))
        #expect(projectModel.sessionIDs == [session.id])
        #expect(projectModel.row(session.id)?.session.title == "Cached thread")
        #expect(projectModel.row(session.id)?.status?.status == .finishedUnread)
        #expect(second.root.attention.counts.unread == 1)

        let openStart = clock.now
        let cached = second.openThread(session.id)
        try await waitUntil("cached thread") { cached.phase == .ready }
        let open = clock.now - openStart
        #expect(cached.messageIDs == expected)
        #expect(cached.draft == "unsent words")
        try await waitUntil("connecting") { second.root.connection == .connecting }
        print("cold start: launch snapshot \(launch), open cached thread \(open)")

        // The server comes up: the engine connects and reconciles without changing what is shown.
        box.set(harness.connection)
        try await waitUntil("live") { second.root.connection == .live }
        await second.flush()
        #expect(cached.messageIDs == expected)
        #expect(normalized(cached.messageIDs.compactMap { cached.message($0)?.message }) == normalized(try await harness.listedMessages(session.id)))
        cached.close()
        await second.stop()
        await harness.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Lists messages from whichever endpoint the mock currently serves (it moves on restart).
struct HarnessView {
    let harness: MockHarness
    let box: EndpointBox

    func listedMessages(_ sessionID: SessionID) async throws -> [Message] {
        guard let connection = box.get() else { return [] }
        let client = OpenCodeClient(connection: connection)
        var messages: [Message] = []
        var cursor: String?
        repeat {
            let page = try await client.messages(
                sessionID: sessionID.rawValue, MessageListQuery(limit: 200, order: cursor == nil ? .ascending : nil, cursor: cursor))
            messages += page.data.map { Mapping.message($0, sessionID: sessionID) }
            cursor = page.data.count < 200 ? nil : page.cursor.next
        } while cursor != nil
        return messages
    }
}
