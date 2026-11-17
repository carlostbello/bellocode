import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// A change and the statuses derived from it reach subscribers together. Before, `EngineCore.commit` published the
/// reduction, then derived attention and published the statuses separately: a subscriber parked on its mailbox was woken
/// by the first publish alone, so a thread could show a pending approval while its status still said "running" (the
/// intermittent `scriptedTurnWithPermissionAndQuestion` failure on a loaded machine). No timing here: the subscriber is
/// parked whenever an event arrives, so every pending request is checked against the set that delivered it.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AttentionPublishTests {
    @Test func pendingRequestAndItsStatusArriveInOneChangeSet() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        let subscription = engine.store.changes.subscribe(.thread(session.id))
        let watcher = Task { () -> [String] in
            var problems: [String] = []
            var seen: Set<String> = []
            for await set in subscription {
                for (id, request) in set.pending where request.sessionID == session.id && seen.insert(id).inserted {
                    let expected: BelloCore.SessionStatus = request.isPermission ? .awaitingApproval : .awaitingAnswer
                    let status = set.statuses[session.id]?.status
                    if status != expected {
                        problems.append("\(id) arrived with status \(String(describing: status)), expected \(expected)")
                    }
                }
                if seen.count >= 2 { break }
            }
            return problems
        }
        let thread = engine.openThread(session.id)
        try await waitUntil("ready") { thread.phase == .ready }
        await thread.send("Give me the tour #script:full-tour")
        try await waitUntil("approval pending") { !thread.pendingRequests.isEmpty }
        guard case .permission(let permission) = thread.pendingRequests[0] else { Issue.record("expected a permission"); return }
        await thread.reply(to: permission.id, .once)
        try await waitUntil("question pending") { thread.pendingRequests.contains { !$0.isPermission } }
        let problems = await watcher.value
        #expect(problems.isEmpty, "\(problems)")
        guard case .question(let question) = thread.pendingRequests[0] else { Issue.record("expected a question"); return }
        await thread.answer(question.id, ["runner": .text("swift test")])
        await harness.server.waitUntilAllIdle()
        subscription.cancel()
        thread.close()
        await engine.stop()
        await harness.stop()
    }
}
