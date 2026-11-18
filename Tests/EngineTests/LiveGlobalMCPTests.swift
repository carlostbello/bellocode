import BelloCore
import ContainerKit
import Darwin
import Foundation
import Testing

@testable import Engine
@testable import OpenCodeKit

/// Opt-in, against Rancher Desktop (and the pinned opencode for the first two): `BELLOCODE_CONTAINER_TESTS=1 swift test
/// --filter LiveGlobalMCP` after `make build`. Uses the public `node:22-bookworm-slim` image already on the Mac (never
/// pulled). Isolated XDG directories, in-memory store and Keychain; every container, network and volume made here is
/// labelled and removed. No prompt is sent (the agent's use of a global tool is in `make e2e-containers`).
@Suite(
    "Live global MCP and corporate network", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["BELLOCODE_CONTAINER_TESTS"] == "1" && EngineRepo.vendoredOpencode != nil
            && BuiltHelper.url != nil,
        "set BELLOCODE_CONTAINER_TESTS=1, run Scripts/fetch-opencode.sh and make build"),
    .timeLimit(.minutes(10)))
@MainActor
struct LiveGlobalMCPTests {
    static let image = "node:22-bookworm-slim"
    let client = EngineClient(socketPath: NSHomeDirectory() + "/.rd/docker.sock")

    struct Harness {
        var engine: Engine
        var root: URL
        var project: URL
        @MainActor var environments: EnvironmentService { engine.environments }
    }

    /// A real engine and opencode with container execution, one project on the test image.
    func makeHarness(certificates: [TrustedCertificate] = []) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-gmcp-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let project = URL(filePath: NSHomeDirectory() + "/Library/Caches/BelloCode/tests/gmcp-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let helper = try #require(BuiltHelper.url)
        let execConfig = root.appending(path: "exec/bellocode-exec.json")
        var server = ServerConfiguration(
            executableURL: try #require(EngineRepo.vendoredOpencode), dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
            expectedVersion: EngineRepo.pinnedVersion)
        server.containerExecution = ContainerExecution(helperURL: helper, execConfigURL: execConfig)
        var configuration = EngineConfiguration(server: .supervised(ServerSupervisor(configuration: server)), store: .inMemory)
        configuration.defaultDirectory = project.path
        var containers = ContainerConfiguration(
            helperURL: helper, execConfigURL: execConfig, opencodeDataDirectory: server.dataDirectory, runtime: LiveWorkspaceRuntime(),
            registryVault: InMemorySecretVault())
        containers.mcpVault = InMemorySecretVault()
        containers.mcpLogDirectory = root.appending(path: "mcp-logs", directoryHint: .isDirectory)
        containers.opencodeConfigDirectory = server.configDirectory
        containers.certificateSource = FakeCertificates(certificates: certificates)
        containers.certificateDirectory = URL(filePath: project.path + "-certs", directoryHint: .isDirectory)
        containers.managedNetwork = { nil }
        containers.systemProxy = { SystemProxySettings() }
        containers.stackDirectory = root.appending(path: "stacks", directoryHint: .isDirectory)
        configuration.containers = containers
        let engine = try Engine(configuration: configuration)
        await engine.start()
        await engine.addProject(directory: project.path)
        try await waitUntil("live", timeout: .seconds(60)) { engine.root.connection == .live }
        try await waitUntil("runtime ready", timeout: .seconds(30)) { engine.environments.runtime?.isReady == true }
        var settings = engine.environments.environment(for: project.path).settings
        settings.image = Self.image
        await engine.environments.update(project.path, settings: settings)
        return Harness(engine: engine, root: root, project: project)
    }

    func tearDown(_ harness: Harness, serverIDs: [String] = []) async {
        let environments = harness.environments
        for id in serverIDs { _ = await environments.removeGlobalMCP(id) }
        for id in serverIDs {
            for container in (try? await client.listContainers(labels: ["\(ImageMCPSpec.label)=\(id)"])) ?? [] {
                try? await client.removeContainer(container.id, force: true)
            }
            for container in (try? await client.listContainers(labels: ["\(EnvironmentService.stackLabel)=\(id)"])) ?? [] {
                try? await client.removeContainer(container.id, force: true)
            }
            let compose = "com.docker.compose.project=\(EnvironmentService.stackProject(id))"
            for container in (try? await client.listContainers(labels: [compose])) ?? [] { try? await client.removeContainer(container.id, force: true) }
            for network in (try? await client.listNetworks(labels: [compose])) ?? [] { try? await client.removeNetwork(network) }
            for volume in (try? await client.listVolumes(labels: [compose])) ?? [] { try? await client.removeVolume(volume, force: true) }
        }
        if let storage = try? await environments.storageToPurge(harness.project.path) { try? await environments.purge(harness.project.path, confirmed: storage) }
        await harness.engine.stop()
        try? FileManager.default.removeItem(at: harness.project)
        try? FileManager.default.removeItem(atPath: harness.project.path + "-certs")
        try? FileManager.default.removeItem(at: harness.root)
    }

    func status(_ harness: Harness, _ name: String) async -> String {
        await harness.environments.refreshMCPStatus(harness.project.path)
        return harness.environments.environment(for: harness.project.path).mcpStatus.first { $0.name == name }?.status ?? ""
    }

    // MARK: Image server

    @Test func anImageServerAnswersThroughOpencodeFromItsOwnContainerWithNoProjectMount() async throws {
        guard try await client.inspectImage(Self.image) != nil else {
            Issue.record("needs \(Self.image) present")
            return
        }
        let harness = try await makeHarness()
        let id = "livegimg01"
        do {
            let environments = harness.environments
            let server = GlobalMCPServer(id: id, name: "globecho", kind: .image, image: ImageMCPSetting(
                image: Self.image, entrypoint: ["node", "-e", GlobalEchoFixture.script],
                environment: [MCPKeyValue(name: "PROBE_PROJECT", value: harness.project.path), MCPKeyValue(name: "GLOBAL_ECHO_TOKEN", secret: true)]))
            try await environments.saveGlobalMCP([server], secrets: [GlobalMCPSecrets.account(server: id, variable: "GLOBAL_ECHO_TOKEN"): SecretValue("live-token")])
            environments.projectInUse(harness.project.path)
            let connected = await waitUntilAsync(timeout: .seconds(90)) { await status(harness, "globecho") == "connected" }
            #expect(connected, "globecho: \(environments.environment(for: harness.project.path).mcpStatus)")
            let log = await environments.globalMCPLogs(id)
            #expect(log.contains("bellocode-started Linux docker project-absent token-present"), "reported: \(log)")

            // The connection's container: BelloCode's labels, no project folder among its mounts, nothing privileged.
            let key = WorkspaceSpec.projectKey(for: harness.project.path)
            let inspect = try #require(try await client.inspectContainer("bellocode-mcp-\(id)-\(key)"))
            #expect(inspect.state.running)
            #expect(inspect.config.labels?[ImageMCPSpec.label] == id)
            let mounts = inspect.hostConfig?.mounts ?? []
            #expect(!mounts.contains { ($0.source ?? "").hasPrefix(harness.project.path) }, "mounts: \(mounts.map(\.source))")
            #expect(inspect.hostConfig?.capDrop == ["ALL"] && inspect.hostConfig?.privileged != true)

            // The self-check registers a scratch image server the same way and proves where it ran.
            environments.activate(harness.project.path)
            try await waitUntil("container ready", timeout: .seconds(120)) { environments.environment(for: harness.project.path).phase == .ready }
            let report = try #require(await environments.verifyIsolation(directory: harness.project.path))
            let checks = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.name, $0.outcome) })
            if case .container(let detail)? = checks["Global MCP server (image)"] {
                #expect(detail.contains("no project folder"))
            } else {
                Issue.record("image check: \(String(describing: checks["Global MCP server (image)"]))")
            }
            #expect(checks["MCP servers added at runtime"] == nil, "the global server is accounted for")

            // Removing the server ends the connection and its container.
            _ = await environments.removeGlobalMCP(id)
            let gone = await waitUntilAsync(timeout: .seconds(30)) {
                ((try? await client.listContainers(labels: ["\(ImageMCPSpec.label)=\(id)"])) ?? [ContainerSummary.placeholder]).isEmpty
            }
            let left = ((try? await client.listContainers(labels: ["\(ImageMCPSpec.label)=\(id)"])) ?? []).map { "\($0.name) \($0.state)" }
            var after = await status(harness, "globecho")
            if after == "connected", let opencode = try? await environments.isolationContext?.client() {
                do { try await opencode.removeMCPServer("globecho", directory: harness.project.path); after += " (manual remove ok)" } catch { after += " (manual remove: \(error))" }
                after += " then " + (await status(harness, "globecho"))
            }
            #expect(gone, "the per-connection container is removed with the connection: \(left); registered \(environments.registeredMCPNames(harness.project.path)); status \(after)")
        } catch {
            Issue.record(error)
        }
        await tearDown(harness, serverIDs: [id])
    }

    // MARK: Compose stack

    /// A streamable-HTTP MCP server for the stack (Node, no dependencies): its tool reports a value from the stack's
    /// `env_file`.
    static let stackServer = #"""
    const http = require('http'), os = require('os');
    http.createServer((req, res) => {
      if (req.method !== 'POST') { res.writeHead(405); return res.end(); }
      let body = ''; req.on('data', (d) => body += d);
      req.on('end', () => {
        const m = JSON.parse(body || '{}');
        if (m.id === undefined) { res.writeHead(202); return res.end(); }
        let result;
        if (m.method === 'initialize') result = { protocolVersion: (m.params && m.params.protocolVersion) || '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'stack', version: '1' } };
        else if (m.method === 'tools/list') result = { tools: [{ name: 'where', description: 'Says where it runs.', inputSchema: { type: 'object', properties: {} } }] };
        else if (m.method === 'tools/call') result = { content: [{ type: 'text', text: os.type() + ' ' + process.env.GREETING }] };
        else if (m.method === 'ping') result = {};
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result ? { jsonrpc: '2.0', id: m.id, result } : { jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'no' } }));
      });
    }).listen(8080, () => console.log('stack mcp listening'));
    """#

    @Test func aComposeStackFromAFileWithABuildIsForwardedToLoopbackAndRegisteredAsRemote() async throws {
        guard try await client.inspectImage(Self.image) != nil, ComposeCLI.rancherExecutable() != nil else {
            Issue.record("needs \(Self.image) present and Rancher Desktop's docker-compose")
            return
        }
        let harness = try await makeHarness()
        let id = "livegstk02"
        let folder = URL(filePath: harness.project.path + "-stack", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            // Features the old subset refused: build from a Dockerfile, env_file, a published port, depends_on.
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(Self.stackServer.utf8).write(to: folder.appending(path: "server.js"))
            try Data("FROM \(Self.image)\nCOPY server.js /server.js\nCMD [\"node\", \"/server.js\"]\n".utf8).write(to: folder.appending(path: "Dockerfile"))
            try Data("GREETING=from-env-file\n".utf8).write(to: folder.appending(path: "mcp.env"))
            try Data("""
                services:
                  mcp:
                    build: .
                    ports: ["8080:8080"]
                    env_file: [mcp.env]
                    depends_on: [helper]
                  helper:
                    image: \(Self.image)
                    command: ["node", "-e", "setInterval(() => {}, 1000)"]
                """.utf8).write(to: folder.appending(path: "compose.yaml"))
            let environments = harness.environments
            let server = GlobalMCPServer(id: id, name: "stacktools", kind: .stack,
                                         stack: StackMCPSetting(composeFile: folder.appending(path: "compose.yaml").path, service: "mcp", port: 8080))
            #expect(server.validationErrors().isEmpty, "\(server.validationErrors())")
            try await environments.saveGlobalMCP([server])
            try await waitUntil("forwarded", timeout: .seconds(60)) { environments.globalMCPStates[id]?.hostPort != nil || environments.globalMCPStates[id]?.problem != nil }
            #expect(environments.globalMCPStates[id]?.problem == nil, "\(environments.globalMCPStates[id]?.problem ?? "")")
            let port = try #require(environments.globalMCPStates[id]?.hostPort)
            #expect(try await client.listContainers(labels: ["\(EnvironmentService.stackLabel)=\(id)"]).isEmpty, "nothing runs before first use")
            environments.projectInUse(harness.project.path)
            let connected = await waitUntilAsync(timeout: .seconds(300)) { await status(harness, "stacktools") == "connected" }
            let stackLog = await environments.globalMCPLogs(id)
            #expect(connected, "stacktools: \(environments.environment(for: harness.project.path).mcpStatus) \(stackLog.suffix(400))")
            #expect(environments.registeredMCP[harness.project.path]?["stacktools"]?["url"]?.stringValue == "http://127.0.0.1:\(port)/mcp")
            let containers = try await client.listContainers(labels: ["\(EnvironmentService.stackLabel)=\(id)"])
            #expect(Set(containers.map(\.name)) == ["\(EnvironmentService.stackProject(id))-mcp-1", "\(EnvironmentService.stackProject(id))-helper-1"])
            let endpoint = try #require(try await client.inspectContainer("\(EnvironmentService.stackProject(id))-mcp-1"))
            #expect((endpoint.ports ?? [:]).values.allSatisfy { ($0 ?? []).isEmpty }, "the file's published port was reset: nothing on the Mac's interfaces")
            #expect(endpoint.config.env?.contains("GREETING=from-env-file") == true, "env_file honoured")
            environments.refreshStack(id)
            try await waitUntil("stack status", timeout: .seconds(20)) { environments.globalMCPStates[id]?.services.contains { $0.name == "mcp" && $0.phase == .running } == true }
            let logs = await environments.globalMCPLogs(id)
            #expect(logs.contains("stack mcp listening"), "\(logs.suffix(300))")
        } catch {
            Issue.record(error)
        }
        await tearDown(harness, serverIDs: [id])
        for image in (try? await client.listImages()) ?? [] where image.repoTags.contains(where: { $0.hasPrefix(EnvironmentService.stackProject(id)) }) {
            try? await client.removeImage(image.id, force: true)
        }
    }

    // MARK: Corporate network

    /// A test root CA and a server certificate for `tls` signed by it (made with macOS's LibreSSL, in a scratch folder).
    static func makeTestCA(in folder: URL) throws -> (caDER: Data, serverKey: String, serverCert: String) {
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.standardInput = FileHandle.nullDevice
            process.executableURL = URL(filePath: "/usr/bin/openssl")
            process.arguments = arguments
            process.currentDirectoryURL = folder
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ContainerError.http(status: 500, message: "openssl \(arguments.first ?? "") failed") }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("subjectAltName=DNS:tls\nbasicConstraints=CA:FALSE\n".utf8).write(to: folder.appending(path: "ext.cnf"))
        try Data("[req]\ndistinguished_name=dn\n[dn]\n[ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n".utf8)
            .write(to: folder.appending(path: "ca.cnf"))
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "2",
                 "-subj", "/CN=BelloCode Test Enterprise Root", "-config", "ca.cnf", "-extensions", "ca"])
        try run(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "tls.key", "-out", "tls.csr", "-subj", "/CN=tls", "-config", "ca.cnf"])
        try run(["x509", "-req", "-in", "tls.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "tls.pem", "-days", "2",
                 "-extfile", "ext.cnf"])
        try run(["x509", "-in", "ca.pem", "-outform", "DER", "-out", "ca.der"])
        return (try Data(contentsOf: folder.appending(path: "ca.der")),
                try String(contentsOf: folder.appending(path: "tls.key"), encoding: .utf8),
                try String(contentsOf: folder.appending(path: "tls.pem"), encoding: .utf8))
    }

    static func indent(_ text: String, _ spaces: Int) -> String {
        text.split(separator: "\n").map { String(repeating: " ", count: spaces) + $0 }.joined(separator: "\n")
    }

    @Test func aTestRootCAIsTrustedInsideTheContainerAndDiagnosticsSeeIt() async throws {
        guard try await client.inspectImage(Self.image) != nil else {
            Issue.record("needs \(Self.image) present")
            return
        }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "bellocode-ca-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let ca = try Self.makeTestCA(in: scratch)
        let root = TrustedCertificate(der: ca.caDER, subject: "BelloCode Test Enterprise Root", domain: .admin, isSelfSigned: true,
                                      isCertificateAuthority: true)
        let harness = try await makeHarness(certificates: [root])
        do {
            let environments = harness.environments
            #expect(environments.network.trustEnabled && environments.network.selected == [root.fingerprint])
            // An HTTPS server signed by the test CA, as a project service on the project's network (`tls:8443`).
            var settings = environments.environment(for: harness.project.path).settings
            settings.servicesYAML = """
                services:
                  tls:
                    image: node:22-bookworm-slim
                    command: ["node", "-e", "eval(process.env.TLS_JS)"]
                    ports: ["8443"]
                    environment:
                      TLS_JS: "require('https').createServer({ key: process.env.SERVER_KEY, cert: process.env.SERVER_CERT }, (q, s) => { s.setHeader('Via', '1.1 bellocode-test-proxy'); s.end('ok'); }).listen(8443)"
                      SERVER_KEY: |
                \(Self.indent(ca.serverKey, 8))
                      SERVER_CERT: |
                \(Self.indent(ca.serverCert, 8))
                """
            await environments.update(harness.project.path, settings: settings)
            environments.activate(harness.project.path)
            try await waitUntil("container ready", timeout: .seconds(120)) { environments.environment(for: harness.project.path).phase == .ready }
            try await waitUntil("tls service", timeout: .seconds(60)) {
                environments.environment(for: harness.project.path).services.first { $0.name == "tls" }?.phase == .running
            }
            let model = environments.environment(for: harness.project.path)
            let container = try #require(model.record.containerID)
            let inspect = try #require(try await client.inspectContainer(container))
            #expect(inspect.config.env?.contains("NODE_EXTRA_CA_CERTS=\(CorporateNetwork.containerEnterprise)") == true)
            #expect(inspect.hostConfig?.mounts?.contains { $0.target == CorporateNetwork.containerDirectory && $0.readOnly == true } == true)

            let fetch = #"require('https').get('https://tls:8443', (r) => { console.log('status ' + r.statusCode); }).on('error', (e) => { console.log('error ' + e.code); })"#
            var trusted = ""
            for _ in 0..<20 {
                let result = try await environments.activeRuntime.run(container: container, argv: ["node", "-e", fetch], workingDir: nil, environment: [:],
                                                                      user: "\(getuid()):\(getgid())", timeout: .seconds(30))
                trusted = String(decoding: result.stdout, as: UTF8.self)
                if trusted.contains("status") { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(trusted.contains("status 200"), "with the bundle: \(trusted)")
            // Control: without the variable, the same fetch fails on the certificate.
            let control = try await environments.activeRuntime.run(
                container: container, argv: ["env", "-u", "NODE_EXTRA_CA_CERTS", "node", "-e", fetch], workingDir: nil, environment: [:],
                user: "\(getuid()):\(getgid())", timeout: .seconds(30))
            #expect(String(decoding: control.stdout, as: UTF8.self).contains("error"), "without the bundle the test CA is not trusted")

            // Network diagnostics from the container: reached, the test CA as issuer, the proxy header, interception named.
            var networkSettings = await environments.networkSettings()
            networkSettings.diagnosticsURLs = ["https://tls:8443"]
            await environments.setNetworkSettings(networkSettings)
            await environments.runNetworkDiagnostics(directory: harness.project.path)
            let run = try #require(environments.network.diagnostics)
            let result = try #require(run.container.first)
            #expect(result.ok, "\(result)")
            #expect(result.issuer?.contains("BelloCode Test Enterprise Root") == true, "issuer: \(result.issuer ?? "none")")
            #expect(result.proxyHeaders.contains { $0.lowercased().hasPrefix("via:") })
            #expect(run.interceptedBy.contains { $0.contains("BelloCode Test Enterprise Root") })
            #expect(run.mac.count == 1, "the Mac side ran too (tls is not a Mac host name, so it fails there)")

            // An image build: a RUN step fetching from the test CA's server succeeds with the instrumented Dockerfile and
            // fails without it (the image-build feature's path: context entries, instrumented Dockerfile, build args).
            let (build, noProxy) = environments.imageBuildNetwork(for: harness.project.path)
            #expect(build.hasCertificates && noProxy == ["tls"])
            let dockerfile = """
                FROM \(Self.image)
                RUN node -e "require('https').get('https://tls:8443', (r) => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', (e) => { console.error(e.code); process.exit(1) })"
                """
            let network = ServiceLabels.networkName(projectKey: WorkspaceSpec.projectKey(for: harness.project.path), offline: false)
            let tag = "bellocode-test-build:\(UUID().uuidString.prefix(8).lowercased())"
            func context(_ text: String) throws -> Data {
                var tar = TarArchive(try build.contextEntries())
                tar.add("Dockerfile", text)
                return tar.data()
            }
            let built = try await client.buildImage(context: try context(build.instrument(dockerfile: dockerfile)), tag: tag,
                                                    labels: ["app.bellocode.test": "1"], buildArgs: build.buildArgs(noProxyExtra: noProxy),
                                                    networkMode: network)
            #expect(built != nil, "the build trusted the test CA")
            if built != nil { try? await client.removeImage(tag, force: true) }
            await #expect(throws: (any Error).self, "without the certificates the same RUN fails") {
                _ = try await client.buildImage(context: try context(dockerfile), tag: tag + "x", labels: ["app.bellocode.test": "1"], networkMode: network)
            }
            try? await client.removeImage(tag + "x", force: true)
        } catch {
            Issue.record(error)
        }
        await tearDown(harness)
    }
}

extension ContainerSummary {
    /// A stand-in meaning "could not list" (keeps a wait from passing on an engine error).
    static var placeholder: ContainerSummary {
        try! JSONDecoder().decode(ContainerSummary.self, from: Data(#"{"Id":"x","Names":["/x"],"Image":"x","State":"running","Status":"","Labels":{}}"#.utf8))
    }
}

/// The global image server's program (same as `ContainerEndToEnd.globalEchoMCPServer`): an echo MCP server that
/// reports on stderr where it runs, whether `PROBE_PROJECT` exists there and whether `GLOBAL_ECHO_TOKEN` arrived.
enum GlobalEchoFixture {
    static let script = #"""
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
}
