import Foundation
import Testing
@testable import MockOpenCode

@Suite("Session control routes")
struct SessionControlRouteTests {
    @Test func viewAgentAndModelUpdateTheSessionAndPublishEvents() async throws {
        let server = MockOpenCodeServer(scenario: .empty(), options: .testing)
        let client = TestClient(try await server.start())
        let id = try await client.createSession()

        #expect(try await client.request("POST", "/api/session/\(id)/view", json: ["idle": .int(42)]).status == 204)
        #expect(try await client.request("POST", "/api/session/\(id)/agent", json: ["agent": "plan"]).status == 204)
        let model: JSONValue = ["model": ["id": "m1", "providerID": "p1"]]
        #expect(try await client.request("POST", "/api/session/\(id)/model", json: model).status == 204)
        #expect(try await client.request("POST", "/api/session/\(id)/view", json: [:]).status == 400)

        let session = try await client.get("/api/session/\(id)")["data"]
        #expect(session?["time"]?["viewed"]?.doubleValue == 42)
        #expect(session?["agent"]?.stringValue == "plan")
        #expect(session?["model"]?["id"]?.stringValue == "m1")
        let types = await server.publishedEvents().compactMap { $0["type"]?.stringValue }
        #expect(types.contains("session.viewed"))
        #expect(types.contains("session.agent.selected"))
        #expect(types.contains("session.model.selected"))
        await server.stop()
    }

    @Test func queuedPromptsCanBeSteeredOrCancelled() async throws {
        let server = MockOpenCodeServer(scenario: .empty(), options: .testing)
        let client = TestClient(try await server.start())
        let id = try await client.createSession()
        // The first turn blocks on a question, so later prompts stay in the inbox.
        await server.enqueueScript(TurnScript { TurnStep.question("Pick", options: ["a", "b"]) }, for: id)
        _ = try await client.prompt(id, "first")
        for _ in 0..<200 where await server.pendingForms().isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        _ = try await client.post("/api/session/\(id)/prompt", ["id": "msg_q1", "text": "later", "delivery": "queue"])
        _ = try await client.post("/api/session/\(id)/prompt", ["id": "msg_q2", "text": "drop", "delivery": "queue"])

        let patch = try await client.request("PATCH", "/api/session/\(id)/inbox/msg_q1", json: ["delivery": "steer"])
        #expect(patch.status == 204)
        #expect(try await client.request("DELETE", "/api/session/\(id)/inbox/msg_q2").status == 204)
        let inbox = try await client.get("/api/session/\(id)/inbox")["data"]?.arrayValue ?? []
        #expect(inbox.map { $0["id"]?.stringValue } == ["msg_q1"])
        #expect(inbox.first?["delivery"]?.stringValue == "steer")
        let missing = try await client.request("PATCH", "/api/session/\(id)/inbox/msg_q2", json: ["delivery": "steer"])
        #expect(missing.status == 409)

        let types = await server.publishedEvents().compactMap { $0["type"]?.stringValue }
        #expect(types.contains("session.inbox.cancelled"))
        #expect(types.contains("session.inbox.delivery.changed"))
        _ = try await client.request("POST", "/api/session/\(id)/interrupt")
        await server.stop()
    }
}
