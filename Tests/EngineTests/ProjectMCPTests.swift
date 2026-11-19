import BelloCore
import ContainerKit
import Foundation
import Synchronization
import OpenCodeKit
import Testing

@testable import Engine

/// Local MCP servers: the configuration scan's verdict per route, and the project setting.
@Suite("Project MCP servers")
struct ProjectMCPTests {
    let helper = "/App/Contents/Helpers/bellocode-exec"

    func server(_ command: [String], disabled: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string("local"), "command": .array(command.map(JSONValue.string))]
        if disabled { object["disabled"] = .bool(true) }
        return .object(object)
    }

    func outcome(_ entries: [JSONValue]) -> IsolationReport.Outcome? {
        IsolationCheck.configurationChecks(entries, projects: [], helperPath: helper, guardInstalled: true)
            .first { $0.name == "Local MCP servers" }?.outcome
    }

    @Test func routedServersAreReportedAsRunningInTheContainer() {
        let routed = server(MCPRouting.routedCommand(helper: helper, project: "/p", argv: ["node", "m.js"]))
        let result = outcome([.object(["mcp": .object(["servers": .object(["echo": routed])])])])
        #expect(result == .container("routed into the project's container (bellocode-exec --stdio): echo"))
    }

    @Test func aLaterRefusalReplacesAFilesHostCommand() {
        // The file (lower priority) names npx; OPENCODE_CONFIG_CONTENT (higher) replaces the entry with the refusal.
        let file: JSONValue = .object(["info": .object(["mcp": .object(["servers": .object(["g": server(["npx", "g"])])])])])
        let content: JSONValue = .object(["info": .object(["mcp": .object(["servers": .object([
            "g": server(MCPRouting.refusedCommand(helper: helper, name: "g"))])])])])
        #expect(outcome([file, content])?.isProblem == false)
        #expect(outcome([file, content])?.detail.contains("refused (configured for all projects): g") == true)
        #expect(outcome([content, file])?.isProblem == true, "a host command with the higher priority is an escape")
        #expect(outcome([.object(["mcp": .object(["servers": .object(["x": server(["npx"], disabled: true)])])])]) == .off("none configured"))
    }

    @Test func serversAddedOutsideBelloCodeAreNotAccountedFor() {
        let listed = [MCPServerStatus(name: "echo", status: "connected"), MCPServerStatus(name: "stranger", status: "connected"),
                      MCPServerStatus(name: IsolationCheck.verifyMCPName, status: "failed")]
        let entries: [JSONValue] = [.object(["info": .object(["mcp": .object(["servers": .object(["remote": .object([:])])])])])]
        #expect(IsolationCheck.unaccountedMCP(listed: listed, entries: entries, registered: ["echo"]) == ["stranger"])
    }

    @Test func settingSplitsCommandLinesAndValidatesNames() throws {
        #expect(MCPServerSetting.split(commandLine: #"node "my tool.js" --flag='a b' x\ y"#) == ["node", "my tool.js", "--flag=a b", "x y"])
        let setting = MCPServerSetting(name: "echo", command: ["node", "my tool.js"])
        #expect(MCPServerSetting.split(commandLine: setting.commandLine) == setting.command)
        #expect(setting.validationErrors().isEmpty)
        #expect(!MCPServerSetting(name: "bad name", command: ["x"]).validationErrors().isEmpty)
        #expect(!MCPServerSetting(name: "e", command: []).validationErrors().isEmpty)
        #expect(!MCPServerSetting(name: "e", command: ["x"], environment: ["BUN_BE_BUN": "1"]).validationErrors().isEmpty)
        var settings = ProjectEnvironmentSettings(mcpServers: [setting, setting])
        #expect(settings.validationErrors().contains { $0.contains("Two MCP servers") })
        settings.mcpServers = [setting]
        let decoded = try JSONDecoder().decode(ProjectEnvironmentSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        let old = try JSONDecoder().decode(ProjectEnvironmentSettings.self, from: Data(#"{"image":"x"}"#.utf8))
        #expect(old.mcpServers.isEmpty, "rows saved before MCP servers existed still load")
    }
}

/// opencode's MCP endpoints, scripted: servers per location, and DELETEs that fail (server kept) while `failing` > 0.
final class FakeMCPTransport: HTTPTransport {
    struct State {
        var servers: [String: String] = [:]  // name → status
        var failing = 0
        var deletes = 0
    }

    let state = Mutex(State())

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        var status = 200
        var body = "{}"
        state.withLock { state in
            if method == "GET", path == "/api/mcp" {
                let data = state.servers.sorted { $0.key < $1.key }.map { #"{"name":"\#($0.key)","status":{"status":"\#($0.value)"}}"# }
                body = #"{"location":{"directory":"/p"},"data":[\#(data.joined(separator: ","))]}"#
            } else if path.hasPrefix("/api/experimental/mcp/") {
                let name = String(path.dropFirst("/api/experimental/mcp/".count))
                if method == "PUT" {
                    state.servers[name] = "connected"
                } else if method == "DELETE" {
                    state.deletes += 1
                    if state.failing > 0 {
                        state.failing -= 1
                        status = 500
                        body = #"{"message":"busy"}"#
                    } else {
                        state.servers[name] = nil
                    }
                }
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}

/// R30: turning a server off keeps it "removing" until opencode confirms it is gone; failed removals are retried.
@MainActor
@Suite("Project MCP server removal", .timeLimit(.minutes(1)))
struct ProjectMCPRemovalTests {
    @Test func aRefusedRemovalStaysPendingAndIsRetriedUntilOpencodeConfirms() async throws {
        let base = NSTemporaryDirectory() + "bc-mcprm-\(UUID().uuidString.prefix(8))"
        let project = base + "/project"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let runtime = FakeWorkspaceRuntime()
        runtime.state.withLock { $0.images = ["own:1"] }
        let configuration = ContainerConfiguration(
            helperURL: URL(filePath: "/Applications/BelloCode.app/Contents/Helpers/bellocode-exec"),
            execConfigURL: URL(filePath: base + "/exec.json"), opencodeDataDirectory: nil, runtime: runtime, registryVault: InMemorySecretVault())
        let service = EnvironmentService(configuration: configuration, store: try ProjectionStore(location: .inMemory))
        service.worktreeParent = { directory in base + "/worktrees/" + (directory as NSString).lastPathComponent }
        let transport = FakeMCPTransport()
        let connection = ServerConnection(baseURL: URL(string: "http://127.0.0.1:4096")!, credentials: ServerCredentials(password: "p"))
        service.isolationContext = IsolationCheck.Context(client: { OpenCodeClient(connection: connection, transport: transport) },
                                                          helperPath: "/Applications/BelloCode.app/Contents/Helpers/bellocode-exec", terminalEnvironment: [:])
        service.mcpRemovalRetryDelay = { _ in .milliseconds(50) }
        await service.start()
        defer { service.stop() }
        var settings = ProjectEnvironmentSettings(image: "own:1", executionMode: .projectContainer)
        settings.mcpServers = [MCPServerSetting(name: "tools", command: ["node", "mcp.js"])]
        await service.update(project, settings: settings)
        let model = service.environment(for: project)
        service.activate(project)
        func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
            for _ in 0..<250 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }
        #expect(await waitFor { transport.state.withLock { $0.servers["tools"] } == "connected" }, "\(model.phase)")

        // opencode refuses the first two removals: the server stays listed, BelloCode keeps it pending and retries.
        transport.state.withLock { $0.failing = 2 }
        settings.mcpServers[0].enabled = false
        await service.update(project, settings: settings)
        #expect(await waitFor { model.mcpPendingRemoval.contains("tools") }, "shown as removing while opencode still lists it")
        #expect(await waitFor { transport.state.withLock { $0.servers["tools"] } == nil }, "retried until removed")
        #expect(await waitFor { model.mcpPendingRemoval.isEmpty }, "cleared only once opencode confirms")
        #expect(transport.state.withLock { $0.deletes } >= 3)
        #expect(!service.registeredMCPNames(project).contains("tools"))
    }
}
