import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// v1.0.0 review N31: stopping the engine core cancels and clears its policy-transition gates, so a send waiting
/// behind an in-flight permission change does not outlive stop().
@Suite("EngineCore stop and policy chains", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct EngineStopPolicyTests {
    @Test func stopReleasesSendsWaitingBehindAPolicyTransition() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let project = try #require(engine.root.projects.first)
        let session = try await engine.createThread(in: project.directory, title: "Policy")
        // The permission change's PATCH is held: the transition stays in flight.
        await harness.server.injectHTTPFault(HTTPFault(method: "PATCH", pathPrefix: "/api/session/\(session.id.rawValue)", action: .holdRequest(gate: "policy")))
        let core = engine.core
        let transition = Task { try? await core.setPermissionMode(session.id, mode: .autoEdit) }
        for _ in 0..<20_000 where await core.policyChainCount == 0 { await Task.yield() }
        #expect(await core.policyChainCount == 1)
        let send = Task { try? await core.sendPrompt(session.id, text: "hello", delivery: nil) }
        for _ in 0..<2_000 { await Task.yield() }
        await core.stop()
        #expect(await core.policyChainCount == 0)
        // The waiting send returns (it fails: the core stopped) without the held transition finishing first.
        _ = await send.value
        await harness.server.releaseResponses(gate: "policy")
        _ = await transition.value
        await engine.stop()
    }
}
