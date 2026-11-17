import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// Follow-ups queued while a turn runs keep their order, their delivery (steer) and their withdrawal whatever order the
/// HTTP answer, the `session.inbox.*` events and a resync's inbox read arrive in. Each test forces one interleaving with
/// the mock's gates (held answers, held events), never with timing. These are the races behind the intermittent
/// `EngineFlowTests.queueSteerAndStopWhileRunning` failures.
@MainActor
@Suite("Queued follow-ups under reordered answers, events and resyncs", .timeLimit(.minutes(3)))
struct QueueOrderingTests {
    static let inboxEvents: Set<String> = ["session.inbox.enqueued", "session.inbox.delivery.changed", "session.inbox.cancelled"]

    /// An engine with an open thread whose turn is blocked on a question (so it stays running).
    func runningThread() async throws -> (MockHarness, Engine, ThreadModel, Session) {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        let thread = engine.openThread(session.id)
        try await waitUntil("ready") { thread.phase == .ready }
        await harness.server.enqueueScript(TurnScript { TurnStep.question("Wait", options: ["ok"]) }, for: session.id.rawValue)
        await thread.send("first")
        try await waitUntil("running") { thread.isRunning && !thread.pendingRequests.isEmpty }
        return (harness, engine, thread, session)
    }

    /// Waits until everything the server published before this call has been applied and reached the thread: SSE is
    /// ordered, so once a rename made now shows, every earlier (released) event has been reduced and published.
    func settle(_ harness: MockHarness, _ thread: ThreadModel, _ marker: String) async throws {
        try await harness.client.updateSession(thread.sessionID.rawValue, SessionUpdateRequest(title: marker))
        try await waitUntil("marker \(marker)") { thread.session?.title == marker }
    }

    func serverTimes(_ harness: MockHarness, _ session: Session) async throws -> [MessageID: Timestamp] {
        let items = try await harness.client.inbox(sessionID: session.id.rawValue)
        return Dictionary(uniqueKeysWithValues: items.map { (MessageID($0.id), Timestamp(milliseconds: $0.time.created)) })
    }

    /// The reported failure (2 issues: order, then steer on the wrong item). `inbox.enqueued` for "second" arrived
    /// before the HTTP answer; the answer was then ignored (the item was no longer `.sending`), so "second" kept the
    /// client's estimate of the server clock while "third" got the server's time. The estimate runs ahead of the mock's
    /// virtual clock by however much real time passed, so "third" sorted first.
    @Test func queuedItemsSortByServerTimeWhenTheEventBeatsTheAnswer() async throws {
        let (harness, engine, thread, session) = try await runningThread()
        // Not a race: real time passing makes the client's clock estimate run ahead of the virtual clock (no events
        // arrive meanwhile to correct it), which is what turns a kept estimate into a wrong order.
        try await Task.sleep(for: .milliseconds(20))
        await harness.server.injectHTTPFault(
            HTTPFault(method: "POST", pathPrefix: "/api/session/\(session.id.rawValue)/prompt", action: .holdResponse(gate: "second")))
        let sending = Task { await thread.send("second") }
        // The route ran and its event was applied; the answer is still held.
        try await waitUntil("event before answer") { thread.queue.contains { $0.text == "second" && $0.state == .queued } }
        #expect(await harness.server.heldResponseCount(gate: "second") == 1)
        let early = try #require(thread.queue.first { $0.text == "second" })
        #expect(try await serverTimes(harness, session)[early.id] == early.created, "the event's server time, not the estimate")

        await harness.server.releaseResponses(gate: "second")
        let second = try #require(await sending.value)
        let third = try #require(await thread.send("third"))
        try await waitUntil("two queued") { thread.queue.count == 2 && thread.queue.allSatisfy { $0.state == .queued } }
        #expect(thread.queue.map(\.id) == [second, third])
        let times = try await serverTimes(harness, session)
        #expect(thread.queue.map(\.created) == [times[second], times[third]])
        await thread.steer(second)
        #expect(thread.queue.first?.delivery == .steer)

        await thread.stop()
        thread.close()
        await engine.stop()
        await harness.stop()
    }

    /// The answers arrive first and the user steers one item and withdraws the other before the (late)
    /// `inbox.enqueued` events arrive. Those events must not put back the old delivery or the withdrawn item.
    @Test func lateEnqueuedEventsDoNotUndoSteerOrCancel() async throws {
        let (harness, engine, thread, _) = try await runningThread()
        func expect(_ ok: Bool, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) async {
            await check(ok, what, harness, engine, thread, sourceLocation: sourceLocation)
        }
        do {
            await harness.server.holdEvents(types: Self.inboxEvents)
            let second = try #require(await thread.send("second"))
            let third = try #require(await thread.send("third"))
            await expect(thread.queue.map(\.id) == [second, third], "both queued, in order")
            await thread.steer(second)
            await thread.cancelQueued(third)
            await expect(thread.lastError == nil, "no error")
            await expect(thread.queue.map(\.id) == [second], "withdrawn at once")
            await expect(thread.queue.first?.delivery == .steer, "steered at once")
            // enqueued(second), enqueued(third), delivery.changed(second), cancelled(third), in published order.
            await expect(await harness.server.heldEventCount == 4, "four inbox events held")

            // Only the two enqueued events: the confirmations of the edits are still on the way.
            await harness.server.releaseHeldEvents(count: 2)
            try await settle(harness, thread, "after enqueued")
            await expect(thread.queue.map(\.id) == [second], "a late enqueued event does not bring back a withdrawn item")
            await expect(thread.queue.first?.delivery == .steer, "a late enqueued event does not undo a steer")

            await harness.server.releaseHeldEvents()
            try await settle(harness, thread, "after all")
            await expect(thread.queue.map(\.id) == [second], "after all events: one item")
            await expect(thread.queue.first?.delivery == .steer, "after all events: steered")
            await expect(thread.queue.first?.state == .queued, "after all events: queued")
        } catch {
            Issue.record(Comment(rawValue: "\(error)\n" + (await engineDiagnostics(harness, engine, thread))))
        }

        await harness.server.holdEvents(types: [])
        await thread.stop()
        thread.close()
        await engine.stop()
        await harness.stop()
    }

    /// A resync reads the inbox, then (before it applies the snapshot) the user steers one item, withdraws another and
    /// queues a new one. The older snapshot must not undo the edits or drop the newly admitted item.
    @Test func resyncWithAnOlderInboxKeepsEditsMadeMeanwhile() async throws {
        let (harness, engine, thread, session) = try await runningThread()
        let second = try #require(await thread.send("second"))
        let third = try #require(await thread.send("third"))
        try await waitUntil("two queued") { thread.queue.count == 2 && thread.queue.allSatisfy { $0.state == .queued } }
        try await settle(harness, thread, "before resync")

        await harness.server.holdEvents(types: Self.inboxEvents)
        await harness.server.injectHTTPFault(
            HTTPFault(method: "GET", pathPrefix: "/api/session/\(session.id.rawValue)/inbox", action: .holdResponse(gate: "inbox")))
        let resyncs = await engine.core.statistics.resyncs
        await harness.server.dropEventStreams()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        while await harness.server.heldResponseCount(gate: "inbox") == 0 {
            guard clock.now < deadline else { Issue.record("the resync never read the inbox"); return }
            await Task.yield()
        }
        // The resync holds an inbox listing [second, third], both "queue".
        await thread.steer(second)
        await thread.cancelQueued(third)
        let fourth = try #require(await thread.send("fourth"))
        #expect(thread.lastError == nil)
        await harness.server.releaseResponses(gate: "inbox")
        while await engine.core.statistics.resyncs == resyncs || engine.root.connection != .live {
            guard clock.now < deadline else { Issue.record("the resync did not finish"); return }
            await Task.yield()
        }
        try await settle(harness, thread, "after resync")
        #expect(thread.queue.map(\.id) == [second, fourth], "withdrawn stays withdrawn; admitted meanwhile stays")
        #expect(thread.queue.first?.delivery == .steer, "the steer survives the older snapshot")

        await harness.server.releaseHeldEvents()
        try await settle(harness, thread, "after events")
        #expect(thread.queue.map(\.id) == [second, fourth])
        #expect(thread.queue.map(\.delivery) == [.steer, .queue])

        await harness.server.holdEvents(types: [])
        await thread.stop()
        thread.close()
        await engine.stop()
        await harness.stop()
    }

    /// The user withdraws an item, the server delivers it before the DELETE reaches it, and the DELETE fails (the
    /// connection drops; 2.3.0 answers a DELETE of a delivered item with 204, so a failure is the only refusal). The
    /// rollback must not put the delivered item back in the queue, where it would stay until the next resync.
    @Test func refusedCancelOfADeliveredItemDoesNotRequeueIt() async throws {
        let (harness, engine, thread, session) = try await runningThread()
        let second = try #require(await thread.send("second"))
        try await waitUntil("queued") { thread.queue.first?.state == .queued }
        await harness.server.injectHTTPFault(
            HTTPFault(method: "DELETE", pathPrefix: "/api/session/\(session.id.rawValue)/inbox", action: .holdRequest(gate: "cancel")))
        let cancelling = Task { await thread.cancelQueued(second) }
        try await waitUntil("withdrawn locally") { thread.queue.isEmpty }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        while await harness.server.heldResponseCount(gate: "cancel") == 0 {
            guard clock.now < deadline else { Issue.record("the DELETE never arrived"); return }
            await Task.yield()
        }
        // Meanwhile the turn ends and the server delivers "second".
        let forms = await harness.server.pendingForms()
        try await engine.answer(QuestionID(forms[0].id), ["answer": .text("ok")])
        try await waitUntil("delivered") { thread.messageIDs.contains(second) }
        await harness.server.injectHTTPFault(
            HTTPFault(method: "DELETE", pathPrefix: "/api/session/\(session.id.rawValue)/inbox", action: .resetConnection))
        await harness.server.releaseResponses(gate: "cancel")
        await cancelling.value
        #expect(thread.lastError != nil, "the failure is reported")
        try await settle(harness, thread, "after refusal")
        #expect(thread.queue.isEmpty, "a delivered item is not queued again")
        await harness.server.waitUntilAllIdle()
        thread.close()
        await engine.stop()
        await harness.stop()
    }
}
