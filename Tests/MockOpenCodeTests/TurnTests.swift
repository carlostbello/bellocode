import Foundation
import Testing
@testable import MockOpenCode

@Suite("Scripted turns")
struct TurnTests {
    /// Starts a server and an event subscriber that has seen `server.connected`.
    func withStream(
        options: MockServerOptions = .testing,
        _ body: (MockOpenCodeServer, TestClient, EventReader) async throws -> Void
    ) async throws {
        let server = MockOpenCodeServer(scenario: .empty(), options: options)
        let client = TestClient(try await server.start())
        let reader = EventReader(client)
        do {
            try await reader.connected()
            try await body(server, client, reader)
        } catch {
            reader.cancel()
            await server.stop()
            throw error
        }
        reader.cancel()
        await server.stop()
    }

    @Test func greetingTurnMatchesRecordedOrder() async throws {
        try await withStream { server, client, reader in
            let session = try await client.createSession()
            let item = try await client.prompt(session, "hello")
            #expect(item["data"]?["type"] == "user")
            #expect(item["data"]?["delivery"] == "steer")
            #expect(item["data"]?["payload"]?["text"] == "hello")
            let events = try await reader.collect(until: isType("session.execution.succeeded"))
            let types = events.map(\.type).filter { $0 != "session.text.delta" }
            #expect(
                types == [
                    "session.created", "session.inbox.enqueued", "session.execution.started", "session.inbox.delivered",
                    "session.step.started", "session.step.first-token", "session.text.started", "session.text.ended",
                    "session.step.streamed", "session.step.ended", "session.usage.updated",
                    "session.execution.succeeded",
                ])
            let deltas = events.filter { $0.type == "session.text.delta" }.compactMap { $0["data"]?["delta"]?.stringValue }
            let ended = events.first { $0.type == "session.text.ended" }?["data"]?["text"]?.stringValue
            #expect(deltas.joined() == ended)
            #expect(deltas.count > 3)

            // Envelope: ids, created, location on session-scoped events, durable seq strictly increasing.
            for event in events { #expect(event["id"]?.stringValue?.hasPrefix("evt_") == true) }
            let seqs = events.filter { $0["data"]?["sessionID"]?.stringValue == session }.compactMap {
                $0["durable"]?["seq"]?.intValue
            }
            #expect(seqs == Array(0..<seqs.count))
            #expect(events.first { $0.type == "session.text.delta" }?["durable"] == nil)
            #expect(events.first { $0.type == "session.execution.started" }?["location"] == nil)
            #expect(events.first { $0.type == "session.step.started" }?["location"]?["directory"] == "/tmp/mock-project")

            // The projection matches the stream.
            await server.waitUntilIdle(session)
            let messages = try await client.get("/api/session/\(session)/message?order=asc")["data"]?.arrayValue ?? []
            #expect(messages.map(\.type) == ["user", "assistant"])
            #expect(messages[1]["content"]?[0]?["text"]?.stringValue == ended)
            #expect(messages[1]["finish"] == "stop")
            #expect(messages[1]["time"]?["completed"]?.intValue != nil)
            let info = try await client.get("/api/session/\(session)")["data"]
            #expect(info?["outcome"] == "succeeded")
            #expect(info?["time"]?["idle"]?.intValue != nil)
        }
    }

    @Test func permissionBlocksUntilReplied() async throws {
        try await withStream { server, client, reader in
            let session = try await client.createSession()
            await server.enqueueScript(
                TurnScript {
                    TurnStep.tool(
                        "edit", input: ["path": "a.txt"], output: "ok",
                        permission: PermissionAsk(action: "edit", resources: ["a.txt"]))
                    TurnStep.text("done")
                })
            _ = try await client.prompt(session, "edit it")
            let asked = try await reader.collect(until: isType("permission.asked")).last!
            let requestID = try #require(asked["data"]?["id"]?.stringValue)
            #expect(asked["data"]?["source"]?["type"] == "tool")
            #expect(asked["data"]?["action"] == "edit")

            // Blocked: listed as pending, and the turn does not progress however long we wait.
            let pending = try await client.get("/api/permission/request")["data"]?.arrayValue ?? []
            #expect(pending.map { $0["id"]?.stringValue } == [requestID])
            try await Task.sleep(for: .milliseconds(100))
            #expect(await server.publishedEvents().last?.type == "permission.asked")
            #expect(await server.session(session)?.busy != nil)

            let reply = try await client.request(
                "POST", "/api/session/\(session)/permission/\(requestID)/reply", json: ["decision": "once"])
            #expect(reply.status == 204)
            let rest = try await reader.collect(until: isType("session.execution.succeeded"))
            let types = rest.map(\.type)
            #expect(types.first == "permission.replied")
            #expect(types.contains("session.tool.success"))
            #expect(try await client.get("/api/permission/request")["data"] == [])
            let unknown = try await client.request(
                "POST", "/api/session/\(session)/permission/per_nope/reply", json: ["decision": "once"])
            #expect(unknown.status == 404)
            #expect(unknown.json["_tag"] == "PermissionNotFoundError")
        }
    }

    @Test func rejectedPermissionFailsTheTool() async throws {
        try await withStream { server, client, reader in
            let session = try await client.createSession()
            await server.enqueueScript(
                TurnScript {
                    TurnStep.tool("shell", input: ["command": "rm -rf /"], permission: PermissionAsk(action: "shell", resources: ["rm -rf /"]))
                })
            _ = try await client.prompt(session, "go")
            let asked = try await reader.collect(until: isType("permission.asked")).last!
            let id = asked["data"]!["id"]!.stringValue!
            _ = try await client.request("POST", "/api/session/\(session)/permission/\(id)/reply", json: ["decision": "reject"])
            let rest = try await reader.collect(until: isType("session.execution.succeeded"))
            let failed = try #require(rest.first { $0.type == "session.tool.failed" })
            #expect(failed["data"]?["error"]?["type"] == "permission")
        }
    }

    @Test func alwaysReplySkipsLaterAsks() async throws {
        try await withStream { server, client, reader in
            let session = try await client.createSession()
            let ask = PermissionAsk(action: "edit", resources: ["b.txt"])
            let script = TurnScript { TurnStep.tool("edit", input: ["path": "b.txt"], permission: ask) }
            await server.enqueueScript(script)
            await server.enqueueScript(script)
            _ = try await client.prompt(session, "one")
            let asked = try await reader.collect(until: isType("permission.asked")).last!
            _ = try await client.request(
                "POST", "/api/session/\(session)/permission/\(asked["data"]!["id"]!.stringValue!)/reply",
                json: ["decision": "always"])
            _ = try await reader.collect(until: isType("session.execution.succeeded"))
            _ = try await client.prompt(session, "two")
            let second = try await reader.collect(until: isType("session.execution.succeeded"))
            #expect(!second.contains { $0.type == "permission.asked" })
        }
    }

    @Test func questionFormIsAnswered() async throws {
        try await withStream { server, client, reader in
            let session = try await client.createSession()
            await server.enqueueScript(
                TurnScript { TurnStep.question("Pick one", key: "choice", options: ["a", "b"]) })
            _ = try await client.prompt(session, "ask me")
            let created = try await reader.collect(until: isType("form.created")).last!
            let form = try #require(created["data"]?["form"])
            let formID = try #require(form["id"]?.stringValue)
            #expect(form["fields"]?[0]?["key"] == "choice")
            #expect(try await client.get("/api/form")["data"]?.arrayValue?.count == 1)
            let reply = try await client.request(
                "POST", "/api/session/\(session)/form/\(formID)/reply", json: ["answer": ["choice": "b"]])
            #expect(reply.status == 204)
            let rest = try await reader.collect(until: isType("session.execution.succeeded"))
            #expect(rest.first?.type == "form.replied")
            let success = try #require(rest.first { $0.type == "session.tool.success" })
            #expect(success["data"]?["content"]?[0]?["text"] == "{\"choice\":\"b\"}")
            let again = try await client.request(
                "POST", "/api/session/\(session)/form/\(formID)/reply", json: ["answer": ["choice": "a"]])
            #expect(again.status == 409)
        }
    }

    @Test func fullTourCoversEveryPartKind() async throws {
        try await withStream { server, client, reader in
            let session = try await client.createSession()
            _ = try await client.prompt(session, "#script:full-tour please")
            var seen: [JSONValue] = []
            while true {
                let event = try #require(try await reader.next())
                seen.append(event)
                if event.type == "permission.asked" {
                    let id = event["data"]!["id"]!.stringValue!
                    _ = try await client.request("POST", "/api/session/\(session)/permission/\(id)/reply", json: ["decision": "once"])
                }
                if event.type == "form.created" {
                    let id = event["data"]!["form"]!["id"]!.stringValue!
                    _ = try await client.request("POST", "/api/session/\(session)/form/\(id)/reply", json: ["answer": ["runner": "swift test"]])
                }
                if event.type == "session.execution.succeeded", event["data"]?["sessionID"]?.stringValue == session { break }
            }
            let types = Set(seen.map(\.type))
            for expected in [
                "session.reasoning.started", "session.reasoning.delta", "session.reasoning.ended",
                "session.tool.input.started", "session.tool.input.delta", "session.tool.input.ended",
                "session.tool.called", "session.tool.progress", "session.tool.success", "permission.asked",
                "permission.replied", "form.created", "form.replied", "session.text.delta",
            ] {
                #expect(types.contains(expected), "missing \(expected)")
            }
            // Sub-agent: a child session that runs its own execution.
            let child = try #require(seen.first { $0.type == "session.created" && $0["data"]?["parentID"]?.stringValue == session })
            let childID = try #require(child["data"]?["sessionID"]?.stringValue)
            await server.waitUntilAllIdle()
            let childInfo = try await client.get("/api/session/\(childID)")["data"]
            #expect(childInfo?["parentID"]?.stringValue == session)
            #expect(childInfo?["outcome"] == "succeeded")
            let finishes = await server.messages(session).compactMap { message -> String? in
                if case let .assistant(a) = message.kind { return a.finish } else { return nil }
            }
            #expect(finishes.last == "stop")
            #expect(finishes.dropLast().allSatisfy { $0 == "tool-calls" })
        }
    }

    @Test func failureEndsTheExecution() async throws {
        try await withStream { _, client, reader in
            let session = try await client.createSession()
            _ = try await client.prompt(session, "#script:failure")
            let events = try await reader.collect(until: isType("session.execution.failed"))
            let stepFailed = try #require(events.first { $0.type == "session.step.failed" })
            #expect(stepFailed["data"]?["error"]?["status"] == 429)
            #expect(events.last?["data"]?["error"]?["message"] == "Rate limit exceeded")
            let info = try await client.get("/api/session/\(session)")["data"]
            #expect(info?["outcome"] == "failed")
        }
    }

    @Test func interruptStopsAPausedTurn() async throws {
        try await withStream(options: MockServerOptions(clock: .realTime, heartbeatInterval: nil)) { server, client, reader in
            let session = try await client.createSession()
            await server.enqueueScript(
                TurnScript {
                    TurnStep.text(String(repeating: "slow ", count: 400), chunkSize: 1, rate: 50)
                })
            _ = try await client.prompt(session, "go slowly")
            _ = try await reader.collect(until: isType("session.text.delta"))
            let reply = try await client.post("/api/session/\(session)/interrupt", [:])
            #expect(reply["interrupted"] == true)
            let rest = try await reader.collect(until: isType("session.execution.interrupted"))
            #expect(rest.contains { $0.type == "session.text.ended" })
            #expect(rest.contains { $0.type == "session.step.failed" })
            #expect(rest.last?["data"]?["reason"] == "user")
            await server.waitUntilIdle(session)
            #expect(try await client.post("/api/session/\(session)/interrupt", [:])["interrupted"] == false)
            #expect(try await client.get("/api/session/\(session)")["data"]?["outcome"] == "interrupted")
        }
    }

    @Test func interruptReleasesABlockedPermission() async throws {
        try await withStream { server, client, reader in
            let session = try await client.createSession()
            await server.enqueueScript(
                TurnScript { TurnStep.tool("edit", permission: PermissionAsk(action: "edit", resources: ["x"])) })
            _ = try await client.prompt(session, "go")
            _ = try await reader.collect(until: isType("permission.asked"))
            _ = try await client.post("/api/session/\(session)/interrupt", [:])
            let rest = try await reader.collect(until: isType("session.execution.interrupted"))
            #expect(rest.contains { $0.type == "permission.replied" && $0["data"]?["reply"] == "reject" })
            #expect(rest.contains { $0.type == "session.tool.failed" })
            #expect(await server.pendingPermissions().isEmpty)
        }
    }

    @Test func scriptedInterruptStep() async throws {
        try await withStream { server, client, reader in
            let session = try await client.createSession()
            await server.enqueueScript(TurnScript { TurnStep.text("partial"); TurnStep.interrupt })
            _ = try await client.prompt(session, "x")
            let events = try await reader.collect(until: isType("session.execution.interrupted"))
            #expect(!events.contains { $0.type == "session.execution.succeeded" })
        }
    }

    @Test func steerAndQueueDelivery() async throws {
        try await withStream(options: MockServerOptions(clock: .realTime, heartbeatInterval: nil)) { server, client, reader in
            let session = try await client.createSession()
            await server.enqueueScript(TurnScript { TurnStep.delay(150); TurnStep.text("first") })
            await server.enqueueScript(TurnScript { TurnStep.text("steered") })
            await server.enqueueScript(TurnScript { TurnStep.text("queued") })
            _ = try await client.prompt(session, "one")
            _ = try await reader.collect(until: isType("session.inbox.delivered"))
            _ = try await client.prompt(session, "two", delivery: "steer")
            _ = try await client.prompt(session, "three", delivery: "queue")
            let pending = try await client.get("/api/session/\(session)/inbox")["data"]?.arrayValue ?? []
            #expect(pending.count == 2)
            let first = try await reader.collect(until: isType("session.execution.succeeded"))
            // The steered prompt joins the running execution; the queued one waits for the next.
            #expect(first.filter { $0.type == "session.inbox.delivered" }.count == 1)
            let second = try await reader.collect(until: isType("session.execution.succeeded"))
            #expect(second.contains { $0.type == "session.execution.started" })
            await server.waitUntilIdle(session)
            let users = await server.messages(session).filter { $0.type == "user" }.count
            #expect(users == 3)
        }
    }

    /// A client mints prompt IDs from its estimate of the server clock (the engine extrapolates from event timestamps).
    /// Against the virtual clock, which stands still between sleeps, that estimate runs ahead, so a prompt ID can sort
    /// after the ID of the step that answers it. Clients order messages by (created, id); the step must therefore be
    /// created strictly after the prompt it answers, or the order depends on how much real time the client took.
    @Test func answerSortsAfterPromptWhenClientIDsRunAhead() async throws {
        try await withStream { server, client, reader in
            let session = try await client.createSession()
            await server.enqueueScript(TurnScript { TurnStep.question("Go on?", key: "go", options: ["yes", "no"]) })
            await server.enqueueScript(TurnScript { TurnStep.text("steered") })
            var ahead = IdentifierGenerator(seed: 99)
            func futureID() async -> String { ahead.make("msg", time: await server.now() + 60_000) }

            _ = try await client.post("/api/session/\(session)/prompt", ["id": .string(await futureID()), "text": "one"])
            let created = try await reader.collect(until: isType("form.created")).last!
            let formID = try #require(created["data"]?["form"]?["id"]?.stringValue)
            // Steered while the first step waits: delivered at the step boundary, then answered by a new step.
            _ = try await client.post(
                "/api/session/\(session)/prompt", ["id": .string(await futureID()), "text": "two", "delivery": "steer"])
            let reply = try await client.request(
                "POST", "/api/session/\(session)/form/\(formID)/reply", json: ["answer": ["go": "yes"]])
            #expect(reply.status == 204)
            await server.waitUntilIdle(session)

            let messages = try await client.get("/api/session/\(session)/message?order=asc")["data"]?.arrayValue ?? []
            let sorted = messages.sorted { a, b in
                let (ca, cb) = (a["time"]?["created"]?.intValue ?? 0, b["time"]?["created"]?.intValue ?? 0)
                return ca == cb ? (a["id"]?.stringValue ?? "") < (b["id"]?.stringValue ?? "") : ca < cb
            }
            let order = sorted.map { message in
                message.type == "user" ? message["text"]?.stringValue ?? "?" : "assistant"
            }
            #expect(order == ["one", "assistant", "two", "assistant"])
        }
    }

    @Test func idempotentPromptAdmission() async throws {
        try await withStream { server, client, _ in
            let session = try await client.createSession()
            let a = try await client.post("/api/session/\(session)/prompt", ["id": "msg_fixed", "text": "hi"])
            let b = try await client.post("/api/session/\(session)/prompt", ["id": "msg_fixed", "text": "hi"])
            #expect(a == b)
            await server.waitUntilIdle(session)
            #expect(await server.messages(session).filter { $0.type == "user" }.count == 1)
        }
    }

    @Test func virtualClockIsDeterministic() async throws {
        func run() async throws -> [JSONValue] {
            let server = MockOpenCodeServer(scenario: .empty(), options: .testing)
            let client = TestClient(try await server.start())
            let session = try await client.createSession()
            _ = try await client.prompt(session, "#script:burst")
            await server.waitUntilIdle(session)
            let events = await server.publishedEvents()
            await server.stop()
            return events
        }
        let clock = ContinuousClock()
        let start = clock.now
        let a = try await run()
        let elapsed = clock.now - start
        let b = try await run()
        #expect(a.count > 500)
        #expect(a == b)
        // About 1,000 deltas at 200 per second would take over 5 s in real time.
        #expect(elapsed < .seconds(3))
    }

    @Test func turnScriptJSONRoundTrip() throws {
        let data = try TurnScript.fullTour.jsonData()
        let decoded = try JSONDecoder().decode(TurnScript.self, from: data)
        #expect(decoded == TurnScript.fullTour)
    }

    @Test func fixtureScriptsLoad() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/scripts")
        let library = try TurnScript.loadLibrary(directory: directory)
        #expect(library.count >= 3)
        for (name, script) in library { #expect(!script.steps.isEmpty, "\(name) is empty") }
    }
}
