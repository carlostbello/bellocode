import BelloCore
import Engine
import Foundation
import OpenCodeKit

/// `make e2e-containers` (`BELLOCODE_SMOKE_E2E=1 BelloCode --smoke-test`): after the smoke test's isolation check,
/// the real opencode binary through the app's launch path, in the temporary project's container:
/// 1. a script runs in Linux with a PATH that names no host runtime folder (and no bun or opencode in the image);
/// 2. a test fails, the file is fixed on the Mac (as the agent's file tools and the user's editor do), and the test
///    passes in the container;
/// 3. a dev server listening on the container's loopback is reached through the per-project loopback forward the
///    built-in browser uses;
/// 4. one prompt on a free built-in model makes the agent run a shell command, which lands in the container;
/// 5. a project MCP server (a Node echo server over stdio) is started inside the container through
///    `bellocode-exec --stdio`, and one more prompt makes the agent call its tool;
/// 6. a global image MCP server (Settings ▸ MCP Servers; the same image, the echo server as its entrypoint, a Keychain
///    secret) runs in its own container with no project folder mounted, and a third prompt makes the agent call it.
/// Prints derived results only (never command output or environment).
enum ContainerEndToEnd {
    @MainActor
    static func run(engine: Engine, client: OpenCodeClient, project: String, log: (String) -> Void) async -> Bool {
        var passed = true
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            log("  e2e: \(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
            passed = passed && ok
        }
        let add = URL(filePath: project).appending(path: "src/add.js")
        try? FileManager.default.createDirectory(at: add.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("module.exports = (a, b) => a - b;\n".utf8).write(to: add)
        try? Data("""
            const add = require('./src/add.js');
            if (add(2, 3) !== 5) { console.error('add is wrong'); process.exit(1); }
            console.log('tests pass');
            """.utf8).write(to: URL(filePath: project).appending(path: "test.js"))

        // 1 + 2a. PATH, runtimes, failing test.
        let first = await job(client, project, """
            uname -s; printf 'PATH=%s\\n' "$PATH"; for t in node bun opencode brew; do command -v $t >/dev/null && echo "has-$t" || echo "no-$t"; done; node test.js; echo "exit=$?"
            """)
        check("script runs in Linux", first.contains("Linux"))
        let path = first.split(separator: "\n").first { $0.hasPrefix("PATH=") }.map(String.init) ?? ""
        check("PATH names no host folder", !path.isEmpty && !path.contains("/opt/homebrew") && !path.contains("/Users/") && !path.contains("/Applications"),
              path.replacingOccurrences(of: "PATH=", with: ""))
        check("no bun, opencode or brew in the container", first.contains("no-bun") && first.contains("no-opencode") && first.contains("no-brew"))
        check("node comes from the image", first.contains("has-node"))
        check("test fails before the fix", first.contains("exit=1"))

        // 2b. Edit on the Mac, test in the container.
        let edited = ContinuousClock.now
        try? Data("module.exports = (a, b) => a + b;\n".utf8).write(to: add)
        let second = await job(client, project, "node test.js; echo \"exit=$?\"")
        check("host edit seen by the container test", second.contains("tests pass") && second.contains("exit=0"),
              "\(Int((ContinuousClock.now - edited).components.attoseconds / 1_000_000_000_000_000 + (ContinuousClock.now - edited).components.seconds * 1000)) ms to green")

        // 2c. File-watch bridge: a watcher in the container (inotify through Node's fs.watch) sees a host edit.
        let watcher = try? await client.createShellJob(
            command: "node -e \"const fs = require('fs'); fs.watch('src/add.js', () => { console.log('watch-fired file'); process.exit(0) }); fs.watch('src', () => { console.log('watch-fired folder'); process.exit(0) }); setTimeout(() => { console.log('watch-timeout'); process.exit(3) }, 8000)\"",
            cwd: project, timeout: 20_000)
        try? await Task.sleep(for: .milliseconds(700))
        let touched = ContinuousClock.now
        try? Data("module.exports = (a, b) => a + b; // edited on the Mac\n".utf8).write(to: add)
        var watched = ""
        if let watcher {
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(50))
                watched = (try? await client.shellJobOutput(watcher.id, directory: project))?.output ?? ""
                if watched.contains("watch-") { break }
            }
        }
        let watchLatency = Int((ContinuousClock.now - touched).components.seconds * 1000 + (ContinuousClock.now - touched).components.attoseconds / 1_000_000_000_000_000)
        engine.environments.refreshBridgeStats(project)
        let stats = engine.environments.environment(for: project).bridgeStats
        check("container watcher fires on a host edit (file-watch bridge)", watched.contains("watch-fired"),
              "\(watched.contains("folder") ? "folder watch" : watched.contains("file") ? "file watch" : "no event"), \(watchLatency) ms; bridge \(stats == nil ? "absent (\(engine.environments.environment(for: project).phase.label), \(engine.environments.environment(for: project).outdatedReason ?? "current"))" : "running"), events \(stats?.events ?? 0), batches \(stats?.batches ?? 0), failures \(stats?.failures ?? 0), paths \(stats?.paths ?? 0), last batch \(String(format: "%.1f", stats?.lastBatchMilliseconds ?? 0)) ms")

        // 3. Dev server through the loopback forward.
        let server = try? await client.createShellJob(
            command: "node -e \"require('http').createServer((q, r) => r.end('hello-from-container')).listen(5173, '127.0.0.1')\"",
            cwd: project, timeout: 60_000)
        var body = ""
        var forwarded: URL?
        for _ in 0..<40 where body.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
            await engine.environments.refreshPorts(project)
            guard engine.environments.environment(for: project).ports.contains(where: { $0.port == 5173 }) else { continue }
            forwarded = await engine.environments.browserURL(for: URL(string: "http://localhost:5173/")!, directory: project)
            if let forwarded, let (data, _) = try? await URLSession.shared.data(from: forwarded) { body = String(decoding: data, as: UTF8.self) }
        }
        check("dev server reached through the loopback forward", body == "hello-from-container", forwarded?.absoluteString ?? "no forward")
        check("forward is loopback only", forwarded?.host == "127.0.0.1")
        engine.environments.stopForward(project, port: 5173)
        if let server { try? await client.deleteShellJob(server.id, directory: project) }
        let reaped = await engine.environments.cleanUpProcesses(project)
        log("  e2e: stray processes cleaned after the dev server: \(reaped)")

        // 4. One prompt on a free model: the agent's shell tool lands in the container.
        if ProcessInfo.processInfo.environment["BELLOCODE_E2E_SKIP_PROMPT"] == "1" {
            log("  e2e: SKIP agent prompt (BELLOCODE_E2E_SKIP_PROMPT=1)")
            return passed
        }
        let free = (engine.root.catalog.current?.models ?? []).filter(\.isFree)
        guard let model = free.first(where: { $0.modelID.contains("pickle") }) ?? free.first else {
            log("  e2e: SKIP agent prompt: no free model in the catalog")
            return passed
        }
        let marker = URL(filePath: project).appending(path: "agent-ran.txt")
        do {
            let session = try await client.createSession(SessionCreateRequest(
                directory: project, title: "BelloCode container e2e", model: ModelRef(id: model.modelID, providerID: model.providerID),
                permissions: [PermissionRule(action: "shell", resource: "*", effect: .allow)]))
            _ = try await client.prompt(sessionID: session.id, PromptRequest(
                text: "Use your shell tool to run exactly this command once, then reply with the single word done: uname -s > agent-ran.txt"))
            var text = ""
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(500))
                text = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
                if !text.isEmpty { break }
            }
            check("agent shell tool ran in the container (\(model.providerID)/\(model.modelID))", text.contains("Linux"),
                  text.isEmpty ? "no file within 120 s" : "")
            try? await client.interrupt(sessionID: session.id)
            try? await client.deleteSession(session.id)
        } catch {
            check("agent prompt", false, "\(error)")
        }
        passed = await mcpServer(engine: engine, client: client, project: project, model: model, check: check) && passed
        passed = await globalImageServer(engine: engine, client: client, project: project, model: model, check: check) && passed
        return passed
    }

    /// 6. A global image MCP server in its own container (no project mount), used by the agent. Its stderr (the helper's
    /// bounded log) reports where it runs, whether the project folder exists there and whether the secret arrived (never
    /// the value).
    @MainActor
    private static func globalImageServer(engine: Engine, client: OpenCodeClient, project: String, model: ModelEntry,
                                          check: (String, Bool, String) -> Void) async -> Bool {
        let environments = engine.environments
        guard let image = environments.environment(for: project).settings.image else {
            check("global image MCP server", false, "the project has no image")
            return false
        }
        let id = "e2eglobal01"
        let server = GlobalMCPServer(id: id, name: "globecho", kind: .image, image: ImageMCPSetting(
            image: image, entrypoint: ["node", "-e", globalEchoMCPServer],
            environment: [MCPKeyValue(name: "PROBE_PROJECT", value: project), MCPKeyValue(name: "GLOBAL_ECHO_TOKEN", secret: true)]))
        do {
            try await environments.saveGlobalMCP(environments.globalMCP.servers + [server], secrets: [
                GlobalMCPSecrets.account(server: id, variable: "GLOBAL_ECHO_TOKEN"): SecretValue("e2e-\(UUID().uuidString)")])
        } catch {
            check("global image MCP server saved", false, "\(error)")
            return false
        }
        environments.projectInUse(project)
        let environment = environments.environment(for: project)
        var status = ""
        var log = ""
        for _ in 0..<120 {
            await environments.refreshMCPStatus(project)
            status = environment.mcpStatus.first { $0.name == "globecho" }?.status ?? ""
            log = await environments.globalMCPLogs(id)
            if status == "connected", log.contains("bellocode-started") { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let started = log.split(separator: "\n").first { $0.hasPrefix("bellocode-started") }.map(String.init) ?? ""
        check("global image MCP server runs in its own container with no project mount",
              status == "connected" && started == "bellocode-started Linux docker project-absent token-present",
              "status \(status.isEmpty ? "none" : status), reported \(started.isEmpty ? "nothing" : started)")
        var called = ""
        do {
            let session = try await client.createSession(SessionCreateRequest(
                directory: project, title: "BelloCode global MCP e2e", model: ModelRef(id: model.modelID, providerID: model.providerID),
                permissions: [PermissionRule(action: "*", resource: "*", effect: .allow)]))
            _ = try await client.prompt(sessionID: session.id, PromptRequest(
                text: "Call the echo tool of the globecho MCP server once with the text bellocode-global-ok, then reply with the single word done."))
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(500))
                called = (await environments.globalMCPLogs(id)).split(separator: "\n").first { $0.hasPrefix("bellocode-called") }.map(String.init) ?? ""
                if !called.isEmpty { break }
            }
            try? await client.interrupt(sessionID: session.id)
            try? await client.deleteSession(session.id)
        } catch {
            check("global MCP prompt", false, "\(error)")
        }
        check("agent used the global image server's tool from its own container",
              called == "bellocode-called bellocode-global-ok Linux docker project-absent token-present", called.isEmpty ? "no call within 120 s" : called)
        _ = await environments.removeGlobalMCP(id)
        return status == "connected" && called.contains("project-absent")
    }

    /// The global image server's program (Node, no dependencies, given to `node -e`): an echo MCP server that reports on
    /// stderr where it runs, whether `PROBE_PROJECT` exists there and whether `GLOBAL_ECHO_TOKEN` arrived.
    static let globalEchoMCPServer = #"""
    const fs = require('fs'), os = require('os');
    const where = os.type() + (fs.existsSync('/.dockerenv') ? ' docker' : '') + (fs.existsSync(process.env.PROBE_PROJECT || '/nonexistent') ? ' project-visible' : ' project-absent') + (process.env.GLOBAL_ECHO_TOKEN ? ' token-present' : ' token-missing');
    process.stderr.write('bellocode-started ' + where + '\n');
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
      if (m.method === 'initialize') send({ jsonrpc: '2.0', id: m.id, result: { protocolVersion: (m.params && m.params.protocolVersion) || '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'globecho', version: '1.0.0' } } });
      else if (m.method === 'tools/list') send({ jsonrpc: '2.0', id: m.id, result: { tools: [{ name: 'echo', description: 'Echoes the text back and says where it ran.', inputSchema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] } }] } });
      else if (m.method === 'tools/call') { const t = ((m.params || {}).arguments || {}).text || ''; process.stderr.write('bellocode-called ' + t + ' ' + where + '\n'); send({ jsonrpc: '2.0', id: m.id, result: { content: [{ type: 'text', text: 'echo: ' + t + ' (' + where + ')' }] } }); }
      else if (m.method === 'ping') send({ jsonrpc: '2.0', id: m.id, result: {} });
      else send({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'no such method' } });
    }
    """#

    /// 5. A project MCP server in the container, used by the agent.
    @MainActor
    private static func mcpServer(engine: Engine, client: OpenCodeClient, project: String, model: ModelEntry,
                                  check: (String, Bool, String) -> Void) async -> Bool {
        let environments = engine.environments
        try? Data(echoMCPServer.utf8).write(to: URL(filePath: project).appending(path: "echo-mcp.js"))
        var settings = environments.environment(for: project).settings
        settings.mcpServers = [MCPServerSetting(name: "echo", command: ["node", "echo-mcp.js"])]
        await environments.update(project, settings: settings)
        environments.activate(project)
        let model0 = environments.environment(for: project)
        var status = ""
        for _ in 0..<120 {
            await environments.refreshMCPStatus(project)
            status = model0.mcpStatus.first { $0.name == "echo" }?.status ?? ""
            if status == "connected" { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let started = (try? String(contentsOf: URL(filePath: project).appending(path: "mcp-started.txt"), encoding: .utf8)) ?? ""
        check("project MCP server started inside the container", status == "connected" && started.hasPrefix("Linux docker"),
              "status \(status.isEmpty ? "none" : status), process reported \(started.trimmingCharacters(in: .whitespacesAndNewlines))")
        let called = URL(filePath: project).appending(path: "mcp-called.txt")
        var text = ""
        do {
            let session = try await client.createSession(SessionCreateRequest(
                directory: project, title: "BelloCode MCP e2e", model: ModelRef(id: model.modelID, providerID: model.providerID),
                permissions: [PermissionRule(action: "*", resource: "*", effect: .allow)]))
            _ = try await client.prompt(sessionID: session.id, PromptRequest(
                text: "Call the echo tool of the echo MCP server once with the text bellocode-mcp-ok, then reply with the single word done."))
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(500))
                text = (try? String(contentsOf: called, encoding: .utf8)) ?? ""
                if !text.isEmpty { break }
            }
            try? await client.interrupt(sessionID: session.id)
            try? await client.deleteSession(session.id)
        } catch {
            check("MCP prompt", false, "\(error)")
            return false
        }
        check("agent used the MCP server's tool in the container", text.contains("bellocode-mcp-ok") && text.contains("Linux"),
              text.isEmpty ? "no call within 120 s" : "")
        settings.mcpServers = []
        await environments.update(project, settings: settings)
        return status == "connected" && text.contains("Linux")
    }

    /// A tiny MCP server over stdio (newline-delimited JSON-RPC, Node, no dependencies): `echo` answers with the text
    /// and records the call in `mcp-called.txt`; start-up records where it runs in `mcp-started.txt`.
    static let echoMCPServer = #"""
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

    private static func job(_ client: OpenCodeClient, _ directory: String, _ command: String) async -> String {
        guard let job = try? await client.createShellJob(command: command, cwd: directory, timeout: 60_000) else { return "" }
        var current = job
        for _ in 0..<300 where !current.isFinished {
            try? await Task.sleep(for: .milliseconds(100))
            if let next = try? await client.shellJob(job.id, directory: directory) { current = next }
        }
        return (try? await client.shellJobOutput(job.id, directory: directory))?.output ?? ""
    }
}
