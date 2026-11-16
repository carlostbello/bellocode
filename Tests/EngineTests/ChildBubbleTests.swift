import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

@Suite("Child approval bubbles", .serialized)
@MainActor
struct ChildBubbleTests {
    @Test func childApprovalMarksTheParent() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        let thread = engine.openThread(session.id)
        try await waitUntil("ready") { thread.phase == .ready }
        await thread.setPermissionMode(.ask)
        await harness.server.enqueueScript(TurnScript {
            TurnStep.subagent(agent: "general", description: "Fix", prompt: "Fix it") {
                TurnStep.tool("edit", input: ["path": "a.md"], output: "ok", duration: 10,
                              permission: PermissionAsk(action: "edit", resources: ["a.md"]))
            }
        }, for: session.id.rawValue)
        await thread.send("go")
        try await waitUntil("child request shown in the parent") { thread.pendingRequests.contains { $0.sessionID != session.id } }
        try await Task.sleep(for: .milliseconds(300))
        let child = try #require(thread.pendingRequests.first?.sessionID)
        #expect(thread.status?.status == .awaitingApproval)
        #expect(thread.status?.blockingChildID == child)
        await engine.stop()
        await harness.stop()
    }
}
