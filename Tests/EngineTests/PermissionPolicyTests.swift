import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// S2 and Q1 (docs/reviews/deep-review-1.md): the chosen permission mode is part of thread creation and confirmed by
/// the server before the first prompt; agent and mode changes are serialised per thread, rolled back on failure, and a
/// state the server does not confirm blocks sending.
@Suite("Permission policy acknowledgement", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct PermissionPolicyTests {
    static let project = "/tmp/mock-policy"

    func start() async throws -> (MockHarness, Engine) {
        try FileManager.default.createDirectory(atPath: Self.project, withIntermediateDirectories: true)
        let harness = try await MockHarness.start(.empty(directory: Self.project))
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        return (harness, engine)
    }

    /// Waits until a request is held at `gate` (a barrier, not a sleep on the outcome).
    func held(_ harness: MockHarness, _ gate: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while await harness.server.heldResponseCount(gate: gate) == 0 {
            guard clock.now < deadline else {
                Issue.record("nothing held at \(gate)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func prompts(_ harness: MockHarness) async -> Int {
        await harness.server.recordedRequests().filter { $0.hasPrefix("POST") && $0.hasSuffix("/prompt") }.count
    }

    func serverRules(_ harness: MockHarness, _ id: SessionID) async throws -> [PermissionRule]? {
        try await harness.client.session(id.rawValue).permissions
    }

    func agentRules(_ harness: MockHarness, _ agent: String) async throws -> [PermissionRule] {
        try await harness.client.agent(agent, directory: Self.project).permissions
    }

    @Test func theModeIsPartOfCreationAndNoPatchIsNeeded() async throws {
        let (harness, engine) = try await start()
        defer { Task { await engine.stop(); await harness.stop() } }
        let session = try await engine.createThread(in: Self.project, title: "t", agent: "build", permissionMode: .ask)
        let expected = PermissionModeRules.rules(for: .ask, agentRules: try await agentRules(harness, "build"))
        #expect(try await serverRules(harness, session.id) == expected)
        #expect(await harness.server.recordedRequests().filter { $0.hasPrefix("PATCH") }.isEmpty, "no second, separate step")
        #expect((await engine.core.knownSession(session.id))?.permissionMode == .ask)
    }

    @Test func aRejectedCreationSendsNothingForTheScheduler() async throws {
        let (harness, engine) = try await start()
        defer { Task { await engine.stop(); await harness.stop() } }
        await harness.server.injectHTTPFault(
            HTTPFault(method: "POST", pathPrefix: "/api/session", action: .respond(status: 400, body: #"{"error":"bad rules"}"#, contentType: "application/json")))
        await #expect(throws: (any Error).self) {
            _ = try await engine.extras.startThread(
                directory: Self.project, title: "Scheduled", prompt: "do it", agent: "build", model: nil, permissionMode: .ask)
        }
        #expect(await prompts(harness) == 0, "the scheduled prompt is never sent when the mode was not applied")
    }

    @Test func rulesTheServerDoesNotConfirmBlockSendingUntilTheModeIsChosenAgain() async throws {
        let (harness, engine) = try await start()
        defer { Task { await engine.stop(); await harness.stop() } }
        let session = try await engine.createThread(in: Self.project, title: "t", agent: "build", permissionMode: .ask)
        // The update is answered as accepted but not applied: the read-back disagrees.
        await harness.server.injectHTTPFault(HTTPFault(method: "PATCH", pathPrefix: "/api/session/\(session.id.rawValue)",
                                                       action: .respond(status: 204, body: "", contentType: "application/json")))
        await #expect(throws: EngineError.self) { try await engine.setPermissionMode(.fullAccess, for: session.id) }
        #expect((await engine.core.knownSession(session.id))?.permissionMode == .ask, "the server's actual mode is shown")
        await #expect(throws: EngineError.self) { _ = try await engine.send("hello", to: session.id) }
        #expect(await prompts(harness) == 0)
        // Choosing the mode again (confirmed this time) unblocks sending.
        try await engine.setPermissionMode(.autoEdit, for: session.id)
        _ = try await engine.send("hello", to: session.id)
        #expect(await prompts(harness) == 1)
    }

    @Test func aFailedRulesUpdateRollsTheAgentBack() async throws {
        let (harness, engine) = try await start()
        defer { Task { await engine.stop(); await harness.stop() } }
        let session = try await engine.createThread(in: Self.project, title: "t", agent: "build", permissionMode: .ask)
        let before = try await serverRules(harness, session.id)
        await harness.server.injectHTTPFault(HTTPFault(method: "PATCH", pathPrefix: "/api/session/\(session.id.rawValue)",
                                                       action: .respond(status: 500, body: #"{"error":"no"}"#, contentType: "application/json")))
        await #expect(throws: EngineError.self) { try await engine.setAgent("plan", for: session.id) }
        let server = try await harness.client.session(session.id.rawValue)
        #expect(server.agent == "build", "the agent switch was undone on the server")
        #expect(server.permissions == before, "the old agent keeps the rules computed for it")
        #expect((await engine.core.knownSession(session.id))?.agent == "build")
        _ = try await engine.send("still fine", to: session.id)
        #expect(await prompts(harness) == 1, "a cleanly rolled-back thread can still send")
    }

    @Test func agentAndModeChangesAreSerialisedPerThread() async throws {
        let (harness, engine) = try await start()
        defer { Task { await engine.stop(); await harness.stop() } }
        let session = try await engine.createThread(in: Self.project, title: "t", agent: "build", permissionMode: .ask)
        await harness.server.injectHTTPFault(
            HTTPFault(method: "POST", pathPrefix: "/api/session/\(session.id.rawValue)/agent", action: .holdRequest(gate: "agent")))
        let agentChange = Task { try await engine.setAgent("plan", for: session.id) }
        try await held(harness, "agent")
        let modeChange = Task { try await engine.setPermissionMode(.fullAccess, for: session.id) }
        let send = Task { _ = try await engine.send("after both", to: session.id) }
        // Neither the mode's PATCH nor the prompt may overtake the agent transition.
        for _ in 0..<50 { await Task.yield() }
        #expect(await harness.server.recordedRequests().filter { $0.hasPrefix("PATCH") }.isEmpty)
        #expect(await prompts(harness) == 0)
        await harness.server.releaseResponses(gate: "agent")
        try await agentChange.value
        try await modeChange.value
        try await send.value
        let server = try await harness.client.session(session.id.rawValue)
        #expect(server.agent == "plan")
        #expect(server.permissions == PermissionModeRules.rules(for: .fullAccess, agentRules: try await agentRules(harness, "plan")),
                "the last choice applies, computed for the agent in force")
        let log = await harness.server.recordedRequests()
        let promptIndex = try #require(log.lastIndex { $0.hasSuffix("/prompt") })
        let lastPatch = try #require(log.lastIndex { $0.hasPrefix("PATCH") })
        #expect(lastPatch < promptIndex, "the prompt went out after the rules were confirmed")
    }

    @Test func aFailedModelChangeRollsBackOnlyThatField() async throws {
        let (harness, engine) = try await start()
        defer { Task { await engine.stop(); await harness.stop() } }
        let session = try await engine.createThread(in: Self.project, title: "old title", agent: "build")
        let before = (await engine.core.knownSession(session.id))?.model
        let model = ModelSelection(providerID: "opencode", modelID: "other-model")
        await harness.server.injectHTTPFault(
            HTTPFault(method: "POST", pathPrefix: "/api/session/\(session.id.rawValue)/model", action: .holdRequest(gate: "model")))
        let change = Task { try await engine.setModel(model, for: session.id) }
        try await held(harness, "model")
        try await engine.renameThread(session.id, to: "new title")
        await harness.server.injectHTTPFault(HTTPFault(method: "POST", pathPrefix: "/api/session/\(session.id.rawValue)/model",
                                                       action: .respond(status: 500, body: #"{"error":"no"}"#, contentType: "application/json")))
        await harness.server.releaseResponses(gate: "model")
        await #expect(throws: (any Error).self) { try await change.value }
        let local = try #require((await engine.core.knownSession(session.id)))
        #expect(local.model == before, "the rejected model is not left displayed")
        #expect(local.title == "new title", "an unrelated change made meanwhile is kept")
    }
}
