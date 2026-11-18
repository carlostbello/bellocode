import BelloCore
import ContainerKit
import Foundation
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
