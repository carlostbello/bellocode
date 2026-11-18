import BelloCore
import ContainerKit
import Darwin
import Foundation
import Testing

@testable import Engine
@testable import OpenCodeKit

/// A tiny MCP server over stdio (newline-delimited JSON-RPC), Node with no dependencies: `echo` answers with the text
/// and the operating system, and records each call in `mcp-called.txt`; start-up records where it runs in
/// `mcp-started.txt`. Shared by the live test and the app's container end-to-end run.
enum EchoMCPFixture {
    static let script = #"""
    const fs = require('fs'), os = require('os');
    fs.writeFileSync('mcp-started.txt', os.type() + (fs.existsSync('/.dockerenv') ? ' docker' : '') + '\n');
    let buffer = '';
    const send = (o) => process.stdout.write(JSON.stringify(o) + '\n');
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (d) => {
      buffer += d;
      let i;
      while ((i = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, i); buffer = buffer.slice(i + 1);
        if (line.trim()) handle(JSON.parse(line));
      }
    });
    process.stdin.on('end', () => process.exit(0));
    function handle(m) {
      if (m.id === undefined) return;
      if (m.method === 'initialize') send({ jsonrpc: '2.0', id: m.id, result: { protocolVersion: (m.params && m.params.protocolVersion) || '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'echo', version: '1.0.0' } } });
      else if (m.method === 'tools/list') send({ jsonrpc: '2.0', id: m.id, result: { tools: [{ name: 'echo', description: 'Echoes the text back and says which operating system it ran on.', inputSchema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] } }] } });
      else if (m.method === 'tools/call') { const t = ((m.params || {}).arguments || {}).text || ''; fs.writeFileSync('mcp-called.txt', t + ' ' + os.type() + '\n'); send({ jsonrpc: '2.0', id: m.id, result: { content: [{ type: 'text', text: 'echo: ' + t + ' (from ' + os.type() + ')' }] } }); }
      else if (m.method === 'ping') send({ jsonrpc: '2.0', id: m.id, result: {} });
      else send({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'no such method' } });
    }
    """#
}

/// The helper `make build` produced (`.build/debug/bellocode-exec`).
enum BuiltHelper {
    static var url: URL? {
        let url = EngineRepo.root.appending(path: ".build/debug/bellocode-exec")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}

/// Opt-in, against Rancher Desktop and the pinned opencode: `BELLOCODE_CONTAINER_TESTS=1 swift test --filter
/// LiveContainerMCP` (after `make build`, which builds the helper). A project MCP server (the echo fixture on the public
/// `node:22-bookworm-slim` image, never pulled) is registered through the engine, answers opencode's handshake through
/// `bellocode-exec --stdio`, and provably runs in the project's container; removing it ends its process there. No
/// prompt is sent. Isolated XDG directories; the project, container and volumes are removed afterwards.
@Suite(
    "Live container MCP", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["BELLOCODE_CONTAINER_TESTS"] == "1" && EngineRepo.vendoredOpencode != nil
            && BuiltHelper.url != nil,
        "set BELLOCODE_CONTAINER_TESTS=1, run Scripts/fetch-opencode.sh and make build"),
    .timeLimit(.minutes(10)))
@MainActor
struct LiveContainerMCPTests {
    static let image = "node:22-bookworm-slim"
    static var helper: URL? { BuiltHelper.url }

    @Test func projectServerAnswersThroughOpencodeFromTheContainer() async throws {
        let client = EngineClient(socketPath: NSHomeDirectory() + "/.rd/docker.sock")
        guard try await client.inspectImage(Self.image) != nil else {
            Issue.record("needs \(Self.image) present")
            return
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-mcp-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let project = URL(filePath: NSHomeDirectory() + "/Library/Caches/BelloCode/tests/mcp-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(EchoMCPFixture.script.utf8).write(to: project.appending(path: "echo-mcp.js"))
        let helper = try #require(Self.helper)
        let execConfig = root.appending(path: "exec/bellocode-exec.json")
        var server = ServerConfiguration(
            executableURL: try #require(EngineRepo.vendoredOpencode), dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
            expectedVersion: EngineRepo.pinnedVersion)
        server.containerExecution = ContainerExecution(helperURL: helper, execConfigURL: execConfig)
        let supervisor = ServerSupervisor(configuration: server)
        var configuration = EngineConfiguration(server: .supervised(supervisor), store: .inMemory)
        configuration.defaultDirectory = project.path
        configuration.containers = ContainerConfiguration(
            helperURL: helper, execConfigURL: execConfig, opencodeDataDirectory: server.dataDirectory, runtime: LiveWorkspaceRuntime(),
            registryVault: InMemorySecretVault())
        let engine = try Engine(configuration: configuration)
        await engine.start()
        await engine.addProject(directory: project.path)
        let environments = engine.environments
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try await waitUntil("live", timeout: .seconds(60)) { engine.root.connection == .live }
            try await waitUntil("runtime ready", timeout: .seconds(30)) { environments.runtime?.isReady == true }
            var settings = environments.environment(for: project.path).settings
            settings.image = Self.image
            settings.mcpServers = [MCPServerSetting(name: "echo", command: ["node", "echo-mcp.js"])]
            await environments.update(project.path, settings: settings)
            environments.activate(project.path)
            try await waitUntil("container ready", timeout: .seconds(120)) { environments.environment(for: project.path).phase == .ready }
            let model = environments.environment(for: project.path)
            let connected = await waitUntilAsync(timeout: .seconds(60)) {
                await environments.refreshMCPStatus(project.path)
                return model.mcpStatus.first { $0.name == "echo" }?.status == "connected"
            }
            #expect(connected, "echo: \(model.mcpStatus)")
            // The handshake (initialize, tools/list) crossed the relay; the process wrote where it runs.
            let started = (try? String(contentsOf: project.appending(path: "mcp-started.txt"), encoding: .utf8)) ?? ""
            #expect(started.hasPrefix("Linux docker"), "the MCP server process ran in the container: \(started)")

            // The self-check sees the server as routed and proves a fresh one lands in the container.
            let report = try #require(await environments.verifyIsolation(directory: project.path))
            let checks = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.name, $0.outcome) })
            #expect(checks["Local MCP servers"] == .container("routed into the project's container (bellocode-exec --stdio): echo"),
                    "\(String(describing: checks["Local MCP servers"]))")
            if case .container = checks["MCP server (stdio)"] {} else { Issue.record("MCP probe: \(String(describing: checks["MCP server (stdio)"]))") }
            #expect(checks["MCP servers added at runtime"] == nil)

            // Removing the server ends its process in the container (the helper's TERM reaches the group).
            let id = try #require(model.record.containerID)
            #expect(await relayedRunning(client, id) >= 1)
            settings.mcpServers = []
            await environments.update(project.path, settings: settings)
            let ended = await waitUntilAsync(timeout: .seconds(20)) { await relayedRunning(client, id) == 0 }
            #expect(ended, "the removed server's process still runs in the container")
        } catch {
            Issue.record(error)
        }
        if let storage = try? await environments.storageToPurge(project.path) { try? await environments.purge(project.path, confirmed: storage) }
        await engine.stop()
    }

    func relayedRunning(_ client: EngineClient, _ container: String) async -> Int {
        guard let inspect = try? await client.inspectContainer(container) else { return 0 }
        var count = 0
        for exec in inspect.execIDs ?? [] {
            if let state = try? await client.inspectExec(exec), state.running, state.isRelayedProgram { count += 1 }
        }
        return count
    }
}
