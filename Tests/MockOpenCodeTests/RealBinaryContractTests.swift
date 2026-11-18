import BelloCore
import Foundation
import Testing
@testable import MockOpenCode

/// Runs one request sequence against the pinned opencode binary and the mock, and compares response and event
/// shapes (keys and value kinds, not values). No model is prompted. The real server runs with every XDG directory and
/// HOME under a fresh temporary directory, so the user's own opencode config and data are never touched, and it exits
/// when the test closes its stdin.
///
/// Opt in with `BELLOCODE_CONTRACT_REAL=1 swift test --filter RealBinaryContract` after `Scripts/fetch-opencode.sh`.
@Suite("Real binary contract", .enabled(if: ProcessInfo.processInfo.environment["BELLOCODE_CONTRACT_REAL"] == "1"), .timeLimit(.minutes(10)))
struct RealBinaryContractTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The pinned binary (the candidate's under `make opencode-verify`, `BELLOCODE_OPENCODE_VERSION`).
    static func binary() throws -> URL {
        guard let binary = OpenCodePin.vendoredBinary(root: root) else { throw TestError("run Scripts/fetch-opencode.sh") }
        return binary
    }

    /// The pinned server in an isolated sandbox.
    final class RealServer {
        let process: Process
        let stdin: Pipe
        let endpoint: MockOpenCodeEndpoint
        let sandbox: URL

        init(project: URL, sandbox: URL) throws {
            let password = UUID().uuidString
            process = Process()
            process.executableURL = try RealBinaryContractTests.binary()
            process.arguments = ["serve", "--stdio", "--port", "0", "--hostname", "127.0.0.1"]
            process.currentDirectoryURL = project
            var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "OPENCODE_PASSWORD": password,
                               "OPENCODE_DISABLE_AUTOUPDATE": "1", "OPENCODE_CONFIG_CONTENT": "{}",
                               "HOME": sandbox.appendingPathComponent("home").path]
            for name in ["config", "data", "state", "cache"] {
                environment["XDG_\(name.uppercased())_HOME"] = sandbox.appendingPathComponent(name).path
            }
            process.environment = environment
            stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            self.sandbox = sandbox
            try process.run()
            var line = Data()
            while !line.contains(10) {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { throw TestError("opencode exited before printing its URL") }
                line.append(chunk)
            }
            let url = try JSONValue.parse(line.prefix { $0 != 10 })["url"]?.stringValue ?? ""
            endpoint = MockOpenCodeEndpoint(url: URL(string: url)!, username: "opencode", password: password)
        }

        func stop() {
            try? stdin.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
    }

    /// Keys and kinds, recursively; arrays by their first element.
    static func shape(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "bool"
        case .int, .double: "number"
        case .string: "string"
        case let .array(items): "[" + (items.first.map(shape) ?? "") + "]"
        case let .object(pairs): "{" + pairs.sorted { $0.0 < $1.0 }.map { "\($0.0):\(shape($0.1))" }.joined(separator: ",") + "}"
        }
    }

    /// One labelled request sequence. Returns label → response JSON, and every event seen.
    static func exercise(_ client: TestClient, directory: String) async throws -> (responses: [(String, JSONValue)], events: [JSONValue]) {
        let reader = EventReader(client)
        try await reader.connected()
        let header = ["x-opencode-directory": directory]
        var out: [(String, JSONValue)] = []
        func call(_ label: String, _ method: String, _ path: String, _ body: JSONValue? = nil) async throws -> JSONValue {
            let reply = try await client.request(method, path, json: body, headers: header)
            let json = reply.body.isEmpty ? JSONValue.string("<\(reply.status)>") : reply.json
            out.append(("\(label) \(reply.status)", json))
            return json
        }
        _ = try await call("info", "GET", "/api/info")
        // Loading the catalog first finishes the location's bootstrap; before that the real server may answer a
        // permission ask with `deny` because the agent rules are not loaded yet.
        _ = try await call("agent.list", "GET", "/api/agent")
        _ = try await call("provider.list", "GET", "/api/provider")
        _ = try await call("model.list", "GET", "/api/model")
        let session = try await call("session.create", "POST", "/api/session", ["title": "contract"])
        let id = session["data"]?["id"]?.stringValue ?? ""
        _ = try await call("session.create.child", "POST", "/api/session", ["title": "child", "parentID": .string(id)])
        _ = try await call("session.get", "GET", "/api/session/\(id)")
        _ = try await call("session.update", "PATCH", "/api/session/\(id)", ["title": "renamed", "metadata": ["k": "v"]])
        _ = try await call("session.list", "GET", "/api/session?limit=1")
        _ = try await call("session.list.top", "GET", "/api/session?parentID=null")
        _ = try await call("session.missing", "GET", "/api/session/ses_doesnotexist")
        _ = try await call("project.list", "GET", "/api/project")
        _ = try await call("message.list", "GET", "/api/session/\(id)/message")
        _ = try await call("message.list.badlimit", "GET", "/api/session/\(id)/message?limit=x")
        _ = try await call("inbox", "GET", "/api/session/\(id)/inbox")
        _ = try await call("interrupt.idle", "POST", "/api/session/\(id)/interrupt", [:])
        let permission = try await call(
            "permission.create", "POST", "/api/session/\(id)/permission", ["action": "read", "resources": ["secret.env"]])
        let permissionID = permission["data"]?["id"]?.stringValue ?? ""
        _ = try await call("permission.list", "GET", "/api/permission/request")
        _ = try await call("permission.get", "GET", "/api/session/\(id)/permission/\(permissionID)")
        _ = try await call("permission.reply", "POST", "/api/session/\(id)/permission/\(permissionID)/reply", ["decision": "once"])
        _ = try await call("permission.reply.again", "POST", "/api/session/\(id)/permission/\(permissionID)/reply", ["decision": "once"])
        let form = try await call(
            "form.create", "POST", "/api/session/\(id)/form",
            ["title": "Pick", "fields": [["key": "k", "title": "K", "type": "string"]]])
        let formID = form["data"]?["id"]?.stringValue ?? ""
        _ = try await call("form.list", "GET", "/api/form")
        _ = try await call("form.reply", "POST", "/api/session/\(id)/form/\(formID)/reply", ["answer": ["k": "v"]])
        _ = try await call("form.reply.again", "POST", "/api/session/\(id)/form/\(formID)/reply", ["answer": ["k": "v"]])
        _ = try await call("session.delete", "DELETE", "/api/session/\(id)")
        _ = try await call("session.deleted.get", "GET", "/api/session/\(id)")
        let unauthorized = try await client.request("GET", "/api/session", auth: false)
        out.append(("unauthorized \(unauthorized.status)", unauthorized.json))
        // Collect what the stream delivered.
        var events: [JSONValue] = []
        while let event = try? await reader.next(timeout: .milliseconds(1500)) { events.append(event) }
        reader.cancel()
        return (out, events)
    }

    @Test func shapesMatchTheRealServer() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("bellocode-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sandbox.appendingPathComponent("project"), withIntermediateDirectories: true)
        // The real server canonicalises its working directory (/var → /private/var); name it the same way.
        // (`resolvingSymlinksInPath` maps /private/var back to /var, so use realpath.)
        let raw = try #require(realpath(sandbox.appendingPathComponent("project").path, nil))
        let project = URL(fileURLWithPath: String(cString: raw))
        free(raw)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let real = try RealServer(project: project, sandbox: sandbox)
        let realResult: (responses: [(String, JSONValue)], events: [JSONValue])
        do {
            realResult = try await Self.exercise(TestClient(real.endpoint), directory: project.path)
        } catch {
            real.stop()
            throw error
        }
        real.stop()
        #expect(!real.process.isRunning)
        if ProcessInfo.processInfo.environment["BELLOCODE_CONTRACT_DUMP"] == "1" {
            for (label, json) in realResult.responses { print("REAL \(label): \(json.serialized.prefix(600))") }
            for event in realResult.events { print("REALEVENT \(event.serialized.prefix(600))") }
        }

        var scenario = Scenario.empty(directory: project.path)
        scenario.projects[0].vcs = nil  // a plain directory, as for the real server
        let mock = MockOpenCodeServer(scenario: scenario, options: .testing)
        let mockResult = try await Self.exercise(TestClient(try await mock.start()), directory: project.path)
        await mock.stop()

        // Responses: same labels and statuses, same shapes except where a divergence is documented.
        let skipShape: Set<String> = ["agent.list", "provider.list", "model.list", "info"]
        #expect(realResult.responses.map(\.0) == mockResult.responses.map(\.0))
        for ((label, realJSON), (_, mockJSON)) in zip(realResult.responses, mockResult.responses) {
            let name = String(label.split(separator: " ")[0])
            if skipShape.contains(name) { continue }
            let a = Self.shape(realJSON)
            let b = Self.shape(mockJSON)
            if a != b { print("SHAPE \(label)\n  real: \(a)\n  mock: \(b)") }
            #expect(a == b, "\(label)")
        }
        // Events: the same types in the same order, and the same shapes per type.
        let realTypes = realResult.events.map(\.type).filter { !Self.ambientEvents.contains($0) }
        let mockTypes = mockResult.events.map(\.type).filter { !Self.ambientEvents.contains($0) }
        if realTypes != mockTypes { print("EVENTS\n  real: \(realTypes)\n  mock: \(mockTypes)") }
        #expect(realTypes == mockTypes)
        for type in Set(realTypes) {
            let a = realResult.events.first { $0.type == type }.map(Self.eventShape) ?? ""
            let b = mockResult.events.first { $0.type == type }.map(Self.eventShape) ?? ""
            if a != b { print("EVENT \(type)\n  real: \(a)\n  mock: \(b)") }
            #expect(a == b, "\(type)")
        }
    }

    /// Location bootstrap noise the real server emits on first use of a directory; the mock does not model it.
    static let ambientEvents: Set<String> = [
        "worktree.resolved", "integration.updated", "provider.updated", "model.updated", "vcs.branch.updated",
        "agent.updated", "command.updated", "skill.updated", "websearch.updated", "reference.updated", "plugin.updated",
        "config.updated", "mcp.status.changed", "models-dev.refreshed", "project.updated",
        // 2.3.2 also announces its artifact providers when a location activates.
        "artifact.updated",
    ]

    static func eventShape(_ event: JSONValue) -> String {
        var copy = event
        copy["durable"] = copy["durable"].map { _ in "durable" }
        return shape(copy)
    }
}
