import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// Deep review 1, C2: a resync that cannot read one list is published as partial, keeps that list's last-known rows
/// and retries just that list while the stream stays connected.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct PartialResyncTests {
    @Test func aFailedPermissionListKeepsLastKnownRowsAndIsRetriedWithoutReconnecting() async throws {
        let harness = try await MockHarness.start()
        var configuration = EngineConfiguration(server: .fixed(harness.connection), store: .inMemory)
        configuration.eventBackoff = BackoffPolicy(initial: .milliseconds(20), maximum: .milliseconds(200))
        configuration.resyncRetryBackoff = BackoffPolicy(initial: .milliseconds(50), maximum: .milliseconds(100))
        configuration.writeInterval = .milliseconds(20)
        let engine = try Engine(configuration: configuration)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        let thread = engine.openThread(session.id)
        try await waitUntil("ready") { thread.phase == .ready }
        try await harness.client.updateSession(session.id.rawValue, SessionUpdateRequest(permissions: PermissionModeRules.rules(for: .ask)))

        // A request the app knows about.
        let known = try await harness.client.evaluatePermission(
            sessionID: session.id.rawValue, PermissionCreateRequest(action: "shell", resources: ["make"]))
        try await waitUntil("known request shown") { thread.pendingRequests.map(\.id) == [known.id] }

        // A gap: the known request is answered elsewhere and a new one arrives, neither seen as an event.
        await harness.server.holdEvents(types: ["permission.asked", "permission.replied"])
        let missed = try await harness.client.evaluatePermission(
            sessionID: session.id.rawValue, PermissionCreateRequest(action: "shell", resources: ["deploy"]))
        try await harness.client.replyPermission(sessionID: session.id.rawValue, requestID: known.id, decision: .once)

        // The reconnect resync cannot read the permission lists (questions and everything else read fine).
        await harness.server.injectHTTPFault(
            HTTPFault(method: "GET", pathPrefix: "/api/permission/request", action: .respond(status: 500, body: "{}", contentType: "application/json"), count: nil))
        let resyncsBefore = await engine.core.statistics.resyncs
        await harness.server.dropEventStreams()
        try await waitUntil("partial") {
            engine.root.connection == .live && !engine.root.syncGaps.permissionDirectories.isEmpty
        }
        #expect(engine.root.syncGaps.questionDirectories.isEmpty)
        #expect(engine.root.syncGaps.message?.contains("Retrying") == true)
        #expect(thread.pendingRequests.map(\.id) == [known.id], "the last-known row stays; nothing is resolved by a failed read")
        let subscribers = await harness.server.subscriberCount

        // The list recovers: the retry reads it without another disconnect or full resync.
        await harness.server.clearHTTPFaults()
        try await waitUntil("retried") { engine.root.syncGaps.isEmpty }
        try await waitUntil("missed request shown") { thread.pendingRequests.map(\.id) == [missed.id] }
        #expect(engine.root.connection == .live)
        #expect(await harness.server.subscriberCount == subscribers, "no reconnect")
        #expect(await engine.core.statistics.resyncs == resyncsBefore + 1, "only the reconnect's resync; the retry read one list")
        #expect(await engine.core.gapRetriesScheduled >= 1)
        thread.close()
        await engine.stop()
        await harness.stop()
    }

    @Test func aFailedInboxReadKeepsQueuedItems() async throws {
        let harness = try await MockHarness.start()
        var configuration = EngineConfiguration(server: .fixed(harness.connection), store: .inMemory)
        configuration.eventBackoff = BackoffPolicy(initial: .milliseconds(20), maximum: .milliseconds(200))
        configuration.resyncRetryBackoff = BackoffPolicy(initial: .seconds(30), maximum: .seconds(30))
        let engine = try Engine(configuration: configuration)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        let thread = engine.openThread(session.id)
        try await waitUntil("ready") { thread.phase == .ready }
        // A long turn, then a queued follow-up.
        await harness.server.enqueueScript(TurnScript(name: "slow") { TurnStep.text(String(repeating: "word ", count: 400), chunkSize: 4, rate: 40) }, for: session.id.rawValue)
        await thread.send("start")
        try await waitUntil("running") { thread.isRunning }
        await thread.send("follow-up", delivery: .queue)
        try await waitUntil("queued") { thread.queue.contains { $0.state == .queued } }
        let queued = thread.queue.map(\.id)

        await harness.server.injectHTTPFault(
            HTTPFault(method: "GET", pathPrefix: "/api/session/\(session.id.rawValue)/inbox", action: .respond(status: 500, body: "{}", contentType: "application/json"), count: nil))
        await harness.server.dropEventStreams()
        try await waitUntil("partial") { engine.root.connection == .live && engine.root.syncGaps.inboxSessions == [session.id] }
        #expect(thread.queue.map(\.id) == queued, "an unread inbox keeps its items")
        await harness.server.clearHTTPFaults()
        thread.close()
        await engine.stop()
        await harness.stop()
    }
}
