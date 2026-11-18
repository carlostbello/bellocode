import Foundation
import Testing

@testable import OpenCodeKit

@Suite("Local MCP servers under container execution")
struct MCPRoutingTests {
    let helper = "/Applications/BelloCode.app/Contents/Helpers/bellocode-exec"

    @Test func projectServersAreRoutedThroughTheHelper() throws {
        let config = MCPRouting.projectServerConfig(helper: helper, project: "/Users/a/p", argv: ["node", "mcp.js"], environment: ["MODE": "x"])
        let command = try #require(config["command"]).arrayValue?.compactMap(\.stringValue) ?? []
        #expect(command == [helper, "--stdio", "--project", "/Users/a/p", "--", "node", "mcp.js"])
        #expect(config["cwd"]?.stringValue == "/Users/a/p")
        #expect(config["environment"]?["MODE"]?.stringValue == "x")
        #expect(MCPRouting.route(of: command, helper: helper) == .container(project: "/Users/a/p"))
        #expect(MCPRouting.route(of: ["npx", "server"], helper: helper) == .host("npx"))
        #expect(MCPRouting.route(of: [helper, "-c", "x"], helper: helper) == .host(helper), "the shell form is not a stdio relay")
        #expect(MCPRouting.route(of: MCPRouting.refusedCommand(helper: helper, name: "g"), helper: helper) == .refused)
    }

    @Test func globalServersInTheIsolatedConfigurationAreRefused() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "opencode")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
        // global servers (JSONC)
        {
          "mcp": { "servers": {
            "tools": { "type": "local", "command": ["npx", "-y", "tools"], /* inline */ "environment": { "URL": "http://x//y" }, },
            "off": { "type": "local", "command": ["x"], "disabled": true },
            "remote": { "type": "remote", "url": "https://example.com/mcp" },
          } },
        }
        """.utf8).write(to: folder.appending(path: "opencode.jsonc"))
        try Data("{ not json".utf8).write(to: folder.appending(path: "config.json"))
        let (servers, problems) = MCPRouting.globalOverrides(configDirectory: root, helper: helper)
        #expect(Set(servers.keys) == ["tools", "off"], "remote servers run nothing on the Mac")
        #expect(servers["tools"]?["command"]?.arrayValue?.compactMap(\.stringValue) == [helper, "--stdio", "--refuse", "tools"])
        #expect(servers["off"]?["disabled"]?.boolValue == true)
        #expect(problems == [folder.appending(path: "config.json").path], "an unreadable file is reported, not ignored")

        let content = OrchestrationContract.serverConfig(
            pluginDirectory: nil, container: ContainerExecution(helperURL: URL(filePath: helper), execConfigURL: URL(filePath: "/tmp/c.json")),
            mcpServers: servers)
        let parsed = try JSONValue.parse(Data(content.utf8))
        #expect(parsed["mcp"]?["servers"]?["tools"]?["command"]?.arrayValue?.first?.stringValue == helper)
    }

    @Test func serverEnvironmentCarriesTheRefusalsForTheIsolatedConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "config/opencode"), withIntermediateDirectories: true)
        try Data(#"{"mcp":{"servers":{"g":{"type":"local","command":["python3","s.py"]}}}}"#.utf8)
            .write(to: root.appending(path: "config/opencode/opencode.json"))
        var configuration = ServerConfiguration(executableURL: URL(filePath: "/x/opencode"), dataRoot: root)
        configuration.containerExecution = ContainerExecution(helperURL: URL(filePath: helper), execConfigURL: URL(filePath: "/tmp/c.json"))
        let environment = configuration.environment(credentials: ServerCredentials(password: "p"))
        let content = try JSONValue.parse(Data(try #require(environment["OPENCODE_CONFIG_CONTENT"]).utf8))
        #expect(content["mcp"]?["servers"]?["g"]?["command"]?.arrayValue?.compactMap(\.stringValue) == [helper, "--stdio", "--refuse", "g"])
    }

    @Test func jsoncStripsCommentsAndTrailingCommasOutsideStrings() throws {
        let text = #"{ "a": "x // not a comment", /* c */ "b": [1, 2,], // end"# + "\n}"
        let value = try JSONValue.parse(Data(JSONC.strip(text).utf8))
        #expect(value["a"]?.stringValue == "x // not a comment")
        #expect(value["b"]?.arrayValue?.count == 2)
    }
}
