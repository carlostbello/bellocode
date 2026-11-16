import Foundation
import Testing
@testable import MockOpenCode

@Suite("Routes and auth")
struct RouteTests {
    func withServer(
        _ scenario: Scenario = .empty(), _ body: (MockOpenCodeServer, TestClient) async throws -> Void
    ) async throws {
        let server = MockOpenCodeServer(scenario: scenario, options: .testing)
        let endpoint = try await server.start()
        let client = TestClient(endpoint)
        do {
            try await body(server, client)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test func bindsLoopbackOnEphemeralPort() async throws {
        try await withServer { _, client in
            #expect(client.endpoint.url.host == "127.0.0.1")
            #expect((client.endpoint.url.port ?? 0) > 0)
            #expect(client.endpoint.username == "opencode")
        }
    }

    @Test func basicAuthIsRequired() async throws {
        try await withServer { _, client in
            let denied = try await client.request("GET", "/api/session", auth: false)
            #expect(denied.status == 401)
            #expect(denied.json["_tag"] == "UnauthorizedError")
            #expect(denied.headers["www-authenticate"]?.hasPrefix("Basic") == true)

            let wrong = try await client.request(
                "GET", "/api/session", auth: false,
                headers: ["Authorization": "Basic " + Data("opencode:nope".utf8).base64EncodedString()])
            #expect(wrong.status == 401)

            #expect(try await client.request("GET", "/api/session").status == 200)
            // The root page is public on the real server.
            #expect(try await client.request("GET", "/", auth: false).status == 200)
        }
    }

    @Test func serverInfoShape() async throws {
        try await withServer { _, client in
            let info = try await client.get("/api/info")
            #expect(info["version"] == "2.3.0")
            #expect(info["pid"]?.intValue != nil)
            #expect(info["urls"]?[0]?.stringValue == client.endpoint.url.absoluteString)
            #expect(info["capabilities"]?["persistentPty"] == true)
        }
    }

    @Test func projectList() async throws {
        try await withServer { _, client in
            let projects = try await client.get("/api/project")
            let first = try #require(projects[0])
            #expect(first["id"]?.stringValue?.count == 40)
            #expect(first["canonical"] == "/tmp/mock-project")
            #expect(first["vcs"] == "git")
            #expect(first["time"]?["created"]?.intValue != nil)
            #expect(first["sandboxes"] == [])
        }
    }

    @Test func sessionLifecycle() async throws {
        try await withServer { _, client in
            let created = try await client.post("/api/session", ["title": "first"])["data"]
            let id = try #require(created?["id"]?.stringValue)
            #expect(id.hasPrefix("ses_"))
            #expect(created?["location"]?["directory"] == "/tmp/mock-project")
            #expect(created?["tokens"]?["cache"]?["read"] == 0)
            #expect(created?["cost"] == 0)

            let fetched = try await client.get("/api/session/\(id)")["data"]
            #expect(fetched?["title"] == "first")

            let patch = try await client.request("PATCH", "/api/session/\(id)", json: ["title": "renamed", "archived": true])
            #expect(patch.status == 204)
            let renamed = try await client.get("/api/session/\(id)")["data"]
            #expect(renamed?["title"] == "renamed")
            #expect(renamed?["time"]?["archived"]?.intValue != nil)

            let child = try await client.createSession(title: "child", parentID: id)
            let top = try await client.get("/api/session?parentID=null")["data"]?.arrayValue ?? []
            #expect(top.map { $0["id"]?.stringValue } == [id])
            let children = try await client.get("/api/session?parentID=\(id)")["data"]?.arrayValue ?? []
            #expect(children.map { $0["id"]?.stringValue } == [child])
            #expect(children.first?["parentID"]?.stringValue == id)

            #expect(try await client.request("DELETE", "/api/session/\(id)").status == 204)
            let gone = try await client.request("GET", "/api/session/\(child)")
            #expect(gone.status == 404)
            #expect(gone.json["_tag"] == "SessionNotFoundError")
            #expect(gone.json["sessionID"]?.stringValue == child)
        }
    }

    @Test func sessionListPagesWithCursor() async throws {
        try await withServer { _, client in
            var ids: [String] = []
            for index in 0..<5 { ids.append(try await client.createSession(title: "s\(index)")) }
            let first = try await client.get("/api/session?limit=2")
            let page1 = first["data"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
            #expect(page1 == Array(ids.reversed().prefix(2)))
            let next = try #require(first["cursor"]?["next"]?.stringValue)
            let second = try await client.get("/api/session?limit=2&cursor=\(next)")
            let page2 = second["data"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
            #expect(page2 == Array(ids.reversed().dropFirst(2).prefix(2)))

            let bad = try await client.request("GET", "/api/session?limit=x")
            #expect(bad.status == 400)
            #expect(bad.json["_tag"] == "InvalidRequestError")
        }
    }

    @Test func messageListOrderAndPaging() async throws {
        try await withServer(.demo()) { server, client in
            let sessions = try await client.get("/api/session?parentID=null")["data"]?.arrayValue ?? []
            let id = try #require(sessions.first?["id"]?.stringValue)
            let count = await server.messages(id).count
            #expect(count > 2)
            let desc = try await client.get("/api/session/\(id)/message?limit=2")
            let asc = try await client.get("/api/session/\(id)/message?order=asc&limit=2")
            let all = await server.messages(id).map(\.id)
            #expect(desc["data"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == Array(all.reversed().prefix(2)))
            #expect(asc["data"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == Array(all.prefix(2)))
            let users = try await client.get("/api/session/\(id)/message?type=user")["data"]?.arrayValue ?? []
            #expect(!users.isEmpty && users.allSatisfy { $0["type"] == "user" })
            let one = try await client.get("/api/session/\(id)/message/\(all[0])")["data"]
            #expect(one?["id"]?.stringValue == all[0])
        }
    }

    @Test func catalogAndAgents() async throws {
        try await withServer { _, client in
            let providers = try await client.get("/api/provider")
            #expect(providers["location"]?["directory"] == "/tmp/mock-project")
            #expect(providers["data"]?.arrayValue?.contains { $0["id"] == "opencode" } == true)
            let models = try await client.get("/api/model")["data"]?.arrayValue ?? []
            #expect(models.contains { $0["id"] == "big-pickle" })
            let defaultModel = try await client.get("/api/model/default")["data"]
            #expect(defaultModel?["id"] == "big-pickle")
            let agents = try await client.get("/api/agent")["data"]?.arrayValue ?? []
            #expect(agents.contains { $0["id"] == "build" })
            #expect(agents.contains { $0["id"] == "plan" })
            let missing = try await client.request("GET", "/api/agent/nope")
            #expect(missing.status == 404)
        }
    }

    @Test func locationHeaderSelectsDirectory() async throws {
        try await withServer { _, client in
            let reply = try await client.request(
                "GET", "/api/agent", headers: ["x-opencode-directory": "/tmp/other%20dir"])
            #expect(reply.json["location"]?["directory"] == "/tmp/other dir")
            let query = try await client.get("/api/agent?location%5Bdirectory%5D=/tmp/q")
            #expect(query["location"]?["directory"] == "/tmp/q")
        }
    }

    @Test func unknownRouteAndBadBody() async throws {
        try await withServer { _, client in
            let missing = try await client.request("GET", "/api/nothing")
            #expect(missing.status == 404)
            var request = URLRequest(url: client.endpoint.url.appendingPathComponent("api/session"))
            request.httpMethod = "POST"
            request.httpBody = Data("{not json".utf8)
            request.setValue(client.endpoint.authorizationHeader, forHTTPHeaderField: "Authorization")
            let (data, response) = try await client.session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 400)
            #expect(try JSONValue.parse(data)["_tag"] == "InvalidRequestError")
        }
    }

    @Test func keepAliveServesManyRequestsConcurrently() async throws {
        try await withServer { _, client in
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<40 { group.addTask { try await client.request("GET", "/api/agent").status } }
                for try await status in group { #expect(status == 200) }
            }
        }
    }
}
