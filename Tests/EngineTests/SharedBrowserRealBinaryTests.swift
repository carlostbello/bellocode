import BelloCore
import ContainerKit
import Foundation
import OpenCodeKit
import Testing

@testable import Engine

/// End to end with the real opencode (docs/features/shared-browser.md "Verification"): a sandboxed opencode (temporary
/// HOME/XDG), the real `chrome` client-MCP provider and pooled `browse mcp`, the real browser container (no network: a
/// fixture served on the container's loopback), two threads on the zero-cost default model, one short prompt each,
/// run at the same time. Opt-in: `BELLOCODE_CONTAINER_TESTS=1 BELLOCODE_BROWSER_REAL=1`.
@Suite(
    "Shared browser real binary", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["BELLOCODE_BROWSER_REAL"] == "1" && ProcessInfo.processInfo.environment["BELLOCODE_CONTAINER_TESTS"] == "1"
            && EngineRepo.vendoredOpencode != nil,
        "set BELLOCODE_CONTAINER_TESTS=1 BELLOCODE_BROWSER_REAL=1 and run Scripts/fetch-opencode.sh"),
    .timeLimit(.minutes(10)))
@MainActor
struct SharedBrowserRealBinaryTests {
    @Test func twoThreadsUseTheSharedChromeInTheirOwnGroups() async throws {
        let socket = NSHomeDirectory() + "/.rd/docker.sock"
        let client = EngineClient(socketPath: socket)
        let key = "rb" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let names = (container: "bellocode-test-browser-\(key)", volume: "bellocode-test-browser-\(key)")
        let executable = try #require(EngineRepo.vendoredOpencode)
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-browser-real-\(key)", directoryHint: .isDirectory)
        let project = root.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "browser sandbox\n".write(to: project.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let supervisorServer = ServerSupervisor(configuration: ServerConfiguration(
            executableURL: executable, dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
            expectedVersion: EngineRepo.pinnedVersion, pluginDirectory: OrchestrationRealBinaryTests.pluginDirectory))
        var configuration = EngineConfiguration(server: .supervised(supervisorServer), store: .inMemory)
        configuration.defaultDirectory = project.path
        configuration.secretVault = InMemorySecretVault()
        let engine = try Engine(configuration: configuration)
        await engine.start()
        await engine.addProject(directory: project.path)
        try await waitUntil("live", timeout: .seconds(30)) { engine.root.connection == .live }

        let pem = try BrowserExtensionKey.generatePEM()
        let runtime = DockerBrowserRuntime(socketPath: socket, docker: BrowserImageBuilder.rancherDocker(), contextDirectory: LiveSharedBrowserTests.context,
                                           configDirectory: root.appending(path: "docker"), key: { pem }, network: nil,
                                           containerName: names.container, volume: names.volume, extraLabels: LiveSharedBrowserTests.label)
        let browser = BrowserSupervisor(runtime: runtime, timing: .init(idle: .seconds(600)), spec: { image, _, seccomp in
            BrowserContainerSpec(image: image, seccompProfile: seccomp, volume: names.volume, name: names.container, extraLabels: LiveSharedBrowserTests.label)
        })
        let host = LiveBrowserHost(supervisor: browser, socket: socket, container: names.container)
        let broker = SharedBrowserBroker(host: host)
        var transcripts: [String] = []
        var listing = ""
        do {
            // The browser and a fixture on its loopback (no network in this test).
            try await browser.begin(.call)
            let fixture = """
                import http.server
                class H(http.server.BaseHTTPRequestHandler):
                    def do_GET(s):
                        name = {'/a': 'Alpha page', '/b': 'Beta page'}.get(s.path, 'Index')
                        s.send_response(200); s.send_header('Content-Type', 'text/html'); s.end_headers()
                        s.wfile.write(('<html><head><title>' + name + '</title></head><body><h1>' + name + '</h1></body></html>').encode())
                    def log_message(s, *a): pass
                http.server.HTTPServer(('127.0.0.1', 8000), H).serve_forever()
                """
            _ = try await ExecSession.run(client: client, container: names.container,
                                          argv: ["/bin/sh", "-c", "nohup python3 -I -c \"$0\" >/dev/null 2>&1 &", fixture], wrap: false, timeout: .seconds(20))
            await browser.end(.call)

            let connection = try await engine.core.currentClient().connection
            let mcp = ClientMCPHost(name: SharedBrowserBroker.serverName, directory: project.path, dialer: WebSocketClientMCPDialer(connection: connection),
                                    provider: broker, maxConcurrentCalls: 16)
            await mcp.start()
            let one = try await engine.createThread(in: project.path, title: "chrome alpha")
            let two = try await engine.createThread(in: project.path, title: "chrome beta")
            try await waitUntil("graph") { engine.orchestration.node(one.id) != nil && engine.orchestration.node(two.id) != nil }
            try await Task.sleep(for: .seconds(2))  // the client-MCP socket attaches the chrome_* tools
            let prompt = { (path: String) in
                "Use the chrome_navigate tool to open http://127.0.0.1:8000\(path) (do not use bash or any other browser), then reply with only the page's main heading."
            }
            _ = try await engine.send(prompt("/a"), to: one.id)
            _ = try await engine.send(prompt("/b"), to: two.id)
            for id in [one.id, two.id] {
                try await waitUntil("started", timeout: .seconds(60)) { engine.orchestration.node(id)?.node.ownStatus == .running }
            }
            for id in [one.id, two.id] {
                try await waitUntil("finished", timeout: .seconds(240)) { engine.orchestration.node(id)?.node.ownStatus != .running }
            }
            for id in [one.id, two.id] {
                let page = try await engine.core.currentClient().messages(sessionID: id.rawValue, MessageListQuery(limit: 200))
                transcripts.append(page.data.map { String(describing: $0) }.joined(separator: "\n"))
            }
            // What the browser itself holds: one group per thread.
            let transport = try await ExecBrowseTransport(client: client, container: names.container)
            let inspector = BrowseMCPClient(transport: transport)
            _ = try await inspector.start()
            listing = try await inspector.call("tabs", arguments: .object(["action": .string("list")])).text
            await inspector.close()
            await mcp.stop()
        } catch {
            Issue.record("real binary: \(error)")
        }
        let refused = transcripts.contains { $0.contains("usage limit") || $0.contains("rate limit") || $0.contains("FreeUsageLimitError") }
        print("shared browser real: refused by provider \(refused); listing \(listing.prefix(600))")
        if refused {
            print("shared browser real: the free tier refused the model run; the non-model evidence stands")
        } else if transcripts.count == 2 {
            #expect(transcripts[0].contains("Alpha page"), "thread one read its page")
            #expect(transcripts[1].contains("Beta page"), "thread two read its page")
            #expect(transcripts.allSatisfy { $0.contains("chrome_navigate") || $0.contains("chrome_") }, "the chrome_* tools were used")
            let groups = Set(listing.components(separatedBy: "\"group\":\"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) })
            #expect(groups.filter { $0.hasPrefix("bc-") }.count >= 2, "each thread worked in its own group: \(groups)")
        }
        await broker.shutdown()
        await browser.stop(reason: "test end")
        try? await client.removeContainer(names.container, force: true)
        try? await client.removeVolume(names.volume, force: true)
        if let tag = try? await runtime.expectedTag() { try? await client.removeImage(tag, force: true) }
        await engine.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

