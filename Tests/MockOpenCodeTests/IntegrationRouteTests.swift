import Foundation
import Testing
@testable import MockOpenCode

@Suite("Integration, credential and permission-evaluation routes", .timeLimit(.minutes(3)))
struct IntegrationRouteTests {
    @Test func keyConnectStoresActiveCredentialAndUnlocksModels() async throws {
        let server = MockOpenCodeServer(scenario: .empty(), options: .testing)
        let client = TestClient(try await server.start())
        let list = try await client.get("/api/integration")["data"]?.arrayValue ?? []
        #expect(list.count == MockIntegration.standard.count)
        let modelsBefore = try await client.get("/api/model")["data"]?.arrayValue?.count ?? 0

        #expect(try await client.request("POST", "/api/integration/anthropic/connect/key", json: ["key": "k1"]).status == 204)
        #expect(try await client.request("POST", "/api/integration/anthropic/connect/key", json: ["key": "k2"]).status == 204)
        let anthropic = try await client.get("/api/integration/anthropic")["data"]
        #expect(anthropic?["connections"]?.arrayValue?.compactMap { $0["label"]?.stringValue } == ["Anthropic 2", "Anthropic"])
        let stored = await server.storedCredentials()
        #expect(stored.map(\.active) == [false, true])
        #expect(await server.credential("anthropic", hasKey: "k2"))
        let modelsAfter = try await client.get("/api/model")["data"]?.arrayValue?.count ?? 0
        #expect(modelsAfter == modelsBefore + 2)

        // Activate the first, remove it: the other becomes active again; removing the last locks the models.
        #expect(try await client.request("POST", "/api/credential/\(stored[0].id)/activate").status == 204)
        #expect(await server.storedCredentials().map(\.active) == [true, false])
        #expect(try await client.request("DELETE", "/api/credential/\(stored[0].id)").status == 204)
        #expect(await server.storedCredentials().map(\.active) == [true])
        #expect(try await client.request("DELETE", "/api/credential/\(stored[1].id)").status == 204)
        #expect(try await client.get("/api/model")["data"]?.arrayValue?.count == modelsBefore)
        let types = await server.publishedEvents().compactMap { $0["type"]?.stringValue }
        #expect(types.contains("credential.updated"))
        #expect(types.contains("credential.switched"))
        #expect(types.contains("integration.updated"))
        await server.stop()
    }

    @Test func keyConnectValidatesRequiredAndConditionalFormFields() async throws {
        let server = MockOpenCodeServer(scenario: .empty(), options: .testing)
        let client = TestClient(try await server.start())
        let missing = try await client.request("POST", "/api/integration/azure/connect/key", json: ["key": "k"])
        #expect(missing.status == 400)
        #expect(missing.json["message"]?.stringValue == "Missing required form field: resourceName")
        #expect(missing.json["kind"]?.stringValue == "integration_authorization")
        let ok = try await client.request(
            "POST", "/api/integration/azure/connect/key", json: ["key": "k", "answer": ["resourceName": "r"]])
        #expect(ok.status == 204)
        // `enterpriseUrl` is required only when deploymentType == enterprise.
        let public_ = try await client.request(
            "POST", "/api/integration/github-copilot/connect/oauth",
            json: ["methodID": "device", "answer": ["deploymentType": "github.com"]])
        #expect(public_.status == 200)
        let enterprise = try await client.request(
            "POST", "/api/integration/github-copilot/connect/oauth",
            json: ["methodID": "device", "answer": ["deploymentType": "enterprise"]])
        #expect(enterprise.status == 400)
        #expect(try await client.request("POST", "/api/integration/nope/connect/key", json: ["key": "k"]).status == 404)
        await server.stop()
    }

    @Test func oauthAttemptsFollowTheScriptedBehaviour() async throws {
        let server = MockOpenCodeServer(scenario: .empty(), options: .testing)
        let client = TestClient(try await server.start())
        // auto: completes on the second poll.
        let auto = try await client.post("/api/integration/openai/connect/oauth", ["methodID": "chatgpt-browser"])["data"]
        #expect(auto?["mode"]?.stringValue == "auto")
        let id = auto?["attemptID"]?.stringValue ?? ""
        #expect(try await client.get("/api/integration/openai/connect/oauth/\(id)")["data"]?["status"]?.stringValue == "pending")
        #expect(try await client.get("/api/integration/openai/connect/oauth/\(id)")["data"]?["status"]?.stringValue == "complete")
        #expect(await server.storedCredentials().first?.integrationID == "openai")

        // code: a wrong code is 400, the right one stores the credential.
        await server.setOAuthBehaviour(.code("GOOD"), integrationID: "gitlab", methodID: "pkce")
        let code = try await client.post("/api/integration/gitlab/connect/oauth", ["methodID": "pkce"])["data"]
        #expect(code?["mode"]?.stringValue == "code")
        let codeID = code?["attemptID"]?.stringValue ?? ""
        let path = "/api/integration/gitlab/connect/oauth/\(codeID)/complete"
        #expect(try await client.request("POST", path, json: ["code": "BAD"]).status == 400)
        #expect(try await client.request("POST", path, json: ["code": "GOOD"]).status == 204)

        // fail and expire.
        await server.setOAuthBehaviour(.fail("Access denied"), integrationID: "openai", methodID: "chatgpt-browser")
        let failing = try await client.post("/api/integration/openai/connect/oauth", ["methodID": "chatgpt-browser"])["data"]
        let failed = try await client.get("/api/integration/openai/connect/oauth/\(failing?["attemptID"]?.stringValue ?? "")")["data"]
        #expect(failed?["status"]?.stringValue == "failed")
        #expect(failed?["message"]?.stringValue == "Access denied")
        await server.setOAuthBehaviour(.expire, integrationID: "openai", methodID: "chatgpt-browser")
        let expiring = try await client.post("/api/integration/openai/connect/oauth", ["methodID": "chatgpt-browser"])["data"]
        let expiringID = expiring?["attemptID"]?.stringValue ?? ""
        #expect(try await client.get("/api/integration/openai/connect/oauth/\(expiringID)")["data"]?["status"]?.stringValue == "expired")

        // cancel releases the attempt.
        await server.setOAuthBehaviour(.pending, integrationID: "openai", methodID: "chatgpt-browser")
        let pending = try await client.post("/api/integration/openai/connect/oauth", ["methodID": "chatgpt-browser"])["data"]
        #expect(await server.openAttemptCount() == 1)
        let pendingID = pending?["attemptID"]?.stringValue ?? ""
        #expect(try await client.request("DELETE", "/api/integration/openai/connect/oauth/\(pendingID)").status == 204)
        #expect(await server.openAttemptCount() == 0)
        await server.stop()
    }

    @Test func permissionCreateEvaluatesAgentSessionAndSavedRules() async throws {
        let server = MockOpenCodeServer(scenario: .empty(), options: .testing)
        let client = TestClient(try await server.start())
        let ask: JSONValue = [["action": "edit", "resource": "*", "effect": "ask"], ["action": "shell", "resource": "*", "effect": "ask"]]
        let id = try await client.post("/api/session", ["agent": "build", "permissions": ask])["data"]?["id"]?.stringValue ?? ""
        func effect(_ action: String, _ resource: String, save: [String]? = nil) async throws -> (String, String) {
            let body: JSONValue = .compact([
                ("action", .string(action)), ("resources", [.string(resource)]),
                ("save", save.map { .array($0.map(JSONValue.string)) }),
            ])
            let data = try await client.post("/api/session/\(id)/permission", body)["data"]
            return (data?["effect"]?.stringValue ?? "", data?["id"]?.stringValue ?? "")
        }
        #expect(try await effect("read", "/p/a.ts").0 == "allow")
        #expect(try await effect("read", "/p/.env").0 == "ask")
        #expect(try await effect("read", "/p/.env.example").0 == "allow")
        let (shell, requestID) = try await effect("shell", "npm test", save: ["npm *"])
        #expect(shell == "ask")
        #expect(try await client.request("POST", "/api/session/\(id)/permission/\(requestID)/reply", json: ["decision": "always"]).status == 204)
        // Saved for the project: applies to another session too.
        let other = try await client.post("/api/session", ["agent": "build", "permissions": ask])["data"]?["id"]?.stringValue ?? ""
        let otherEffect = try await client.post(
            "/api/session/\(other)/permission", ["action": "shell", "resources": ["npm run build"]])["data"]?["effect"]
        #expect(otherEffect?.stringValue == "allow")
        let projectID = try await client.get("/api/session/\(id)")["data"]?["projectID"]?.stringValue ?? ""
        #expect(try await client.get("/api/permission/saved")["data"]?.arrayValue?.isEmpty == true)
        let saved = try await client.get("/api/permission/saved?projectID=\(projectID)")["data"]?.arrayValue ?? []
        #expect(saved.compactMap { $0["resource"]?.stringValue } == ["npm *"])
        // Children copy the parent's rules.
        let child = try await client.createSession(parentID: id)
        #expect(try await client.get("/api/session/\(child)")["data"]?["permissions"] == ask)
        await server.stop()
    }

    @Test func wildcardMatching() {
        #expect(MockOpenCodeServer.wildcard("*.env", matches: "/a/b/.env"))
        #expect(!MockOpenCodeServer.wildcard("*.env", matches: "/a/b/.env.local"))
        #expect(MockOpenCodeServer.wildcard("*.env.*", matches: "/a/.env.local"))
        #expect(MockOpenCodeServer.wildcard("npm *", matches: "npm run build"))
        #expect(MockOpenCodeServer.wildcard("*", matches: ""))
        #expect(!MockOpenCodeServer.wildcard("a?c", matches: "ac"))
    }
}
