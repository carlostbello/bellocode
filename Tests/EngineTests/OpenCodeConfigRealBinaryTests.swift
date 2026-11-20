import BelloCore
import Darwin
import Foundation
@testable import OpenCodeKit
import Synchronization
import Testing

@testable import Engine

/// opencode configuration against the pinned binary with the bellocode plugin (docs/features/opencode-config.md).
/// Opt-in: `BELLOCODE_CONFIG_REAL=1 swift test --filter OpenCodeConfigRealBinary`. No network: the model is a local
/// mock OpenAI-compatible provider that records each request. HOME and XDG directories in a fresh temporary directory
/// (never the user's opencode data); the server is stopped before each test returns.
@Suite(
    "opencode config real binary", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["BELLOCODE_CONFIG_REAL"] == "1" && EngineRepo.vendoredOpencode != nil,
        "set BELLOCODE_CONFIG_REAL=1 and run Scripts/fetch-opencode.sh"),
    .timeLimit(.minutes(10)))
@MainActor
struct OpenCodeConfigRealBinaryTests {
    nonisolated static let repoMarker = "REPO-AGENTS-MD-7c1f: answer in haiku."
    nonisolated static let globalMarker = "GLOBAL-AGENTS-MD-91ab: be brief."

    @MainActor struct Sandbox {
        let root: URL
        let project: URL
        let directories: OpenCodeDirectories
        let supervisor: ServerSupervisor
        let engine: Engine
        let llm: MockLLMServer

        static func start(_ name: String) async throws -> Sandbox {
            let executable = try #require(EngineRepo.vendoredOpencode)
            let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-occ-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
            let project = root.appending(path: "repo", directoryHint: .isDirectory)
            let directories = OpenCodeDirectories(dataRoot: root.appending(path: "server", directoryHint: .isDirectory))
            let llm = try MockLLMServer()
            try Self.writeFixtures(project: project, global: directories.globalConfigFolder, llmPort: llm.port)
            let supervisor = ServerSupervisor(
                configuration: ServerConfiguration(
                    executableURL: executable, dataRoot: directories.dataRoot, expectedVersion: EngineRepo.pinnedVersion,
                    pluginDirectory: OrchestrationRealBinaryTests.pluginDirectory))
            var configuration = EngineConfiguration(server: .supervised(supervisor), store: .inMemory)
            configuration.defaultDirectory = project.path
            let engine = try Engine(configuration: configuration)
            await engine.start()
            await engine.addProject(directory: project.path)
            try await waitUntil("live", timeout: .seconds(30)) { engine.root.connection == .live }
            return Sandbox(root: root, project: project, directories: directories, supervisor: supervisor, engine: engine, llm: llm)
        }

        static func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        static func writeFixtures(project: URL, global: URL, llmPort: UInt16) throws {
            // A real repository: opencode's project detection and the plugin's root walk both use git.
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["init", "-q", project.path]
            git.standardInput = FileHandle.nullDevice
            git.standardOutput = FileHandle.nullDevice
            git.standardError = FileHandle.nullDevice
            try git.run()
            git.waitUntilExit()
            // Global folder: a custom agent and skill, global instructions and the mock provider.
            try write(
                """
                {"providers": {"mock": {"name": "Mock", "package": "@ai-sdk/openai-compatible",
                  "settings": {"baseURL": "http://127.0.0.1:\(llmPort)/v1", "apiKey": "none"},
                  "models": {"m1": {"name": "m1"}, "m2": {"name": "m2"}, "m-limited": {"name": "m-limited"}}}}}
                """, to: global.appending(path: "opencode.json"))
            try write(OpenCodeConfigRealBinaryTests.globalMarker, to: global.appending(path: "AGENTS.md"))
            try write("---\ndescription: Global test agent\nmode: subagent\n---\nYou are the global test agent.\n",
                      to: global.appending(path: "agents/t-global-agent.md"))
            try write("---\nname: t-global-skill\ndescription: Global test skill\n---\nGlobal skill body.\n",
                      to: global.appending(path: "skills/t-global-skill/SKILL.md"))
            // Repository: instructions (text: always loaded), .opencode text config (trusted only), opencode.json (never
            // in the default mode: it is configuration opencode would apply).
            try write(OpenCodeConfigRealBinaryTests.repoMarker, to: project.appending(path: "AGENTS.md"))
            try write("---\ndescription: Project test agent\nmode: subagent\n---\nYou are the project test agent.\n",
                      to: project.appending(path: ".opencode/agents/t-project-agent.md"))
            try write("---\ndescription: Project test command\n---\nRun the project check on $ARGUMENTS\n",
                      to: project.appending(path: ".opencode/commands/t-project-command.md"))
            try write("---\nname: t-project-skill\ndescription: Project test skill\n---\nProject skill body.\n",
                      to: project.appending(path: ".opencode/skills/t-project-skill/SKILL.md"))
            try write("{\"agents\": {\"t-json-agent\": {\"description\": \"must not load\", \"mode\": \"subagent\"}}}",
                      to: project.appending(path: "opencode.json"))
        }

        func client() async throws -> OpenCodeClient { try await engine.core.currentClient() }

        /// Lists until the location has activated (the first answers can be empty).
        func inventory() async throws -> OpenCodeInventory {
            let service = engine.openCodeConfig!
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(30)
            while true {
                await service.refresh(directory: project.path)
                if let inventory = service.inventory, inventory.agents.contains(where: { $0.name == "t-global-agent" }) { return inventory }
                guard clock.now < deadline else { throw EventuallyTimeoutError(what: "inventory: \(service.refreshError ?? "no global agent")") }
                try await Task.sleep(for: .milliseconds(200))
            }
        }

        func stop() async {
            let pid = await supervisor.childPID
            await engine.stop()
            llm.stop()
            if let pid { #expect(kill(pid, 0) != 0, "server child \(pid) still running") }
            try? FileManager.default.removeItem(at: root)
        }
    }

    struct EventuallyTimeoutError: Error { var what: String }

    @Test func globalAgentAndSkillAreListedAndRepositoryConfigWaitsForTrust() async throws {
        let sandbox = try await Sandbox.start("inventory")
        do {
            var inventory = try await sandbox.inventory()
            #expect(inventory.agents.first { $0.name == "t-global-agent" }?.source == .global)
            #expect(inventory.skills.first { $0.name == "t-global-skill" }?.source == .global)
            #expect(inventory.agents.first { $0.name == "build" }?.source == .builtIn)
            #expect(inventory.pluginProblem == nil)
            // Untrusted: no repository agents, commands or skills; never the repository opencode.json.
            #expect(!inventory.agents.contains { $0.name == "t-project-agent" })
            #expect(!inventory.skills.contains { $0.name == "t-project-skill" })
            #expect(!inventory.agents.contains { $0.name == "t-json-agent" })

            // Trust applies without a restart.
            let pid = await sandbox.supervisor.childPID
            let service = try #require(sandbox.engine.openCodeConfig)
            #expect(await service.setTrusted(sandbox.project.path, true) == nil)
            #expect(!service.trustPending)
            inventory = try #require(service.inventory)
            #expect(inventory.agents.first { $0.name == "t-project-agent" }?.source == .project)
            #expect(inventory.commands.first { $0.name == "t-project-command" }?.source == .project)
            #expect(inventory.skills.first { $0.name == "t-project-skill" }?.source == .project)
            #expect(!inventory.agents.contains { $0.name == "t-json-agent" })
            #expect(await sandbox.supervisor.childPID == pid)

            await service.setTrusted(sandbox.project.path, false)
            inventory = try #require(service.inventory)
            #expect(!inventory.agents.contains { $0.name == "t-project-agent" })
            #expect(!inventory.skills.contains { $0.name == "t-project-skill" })

            // The CLI connection file exists while the server runs, private, naming this server.
            let connection = try CLIConnectionFile.read(from: sandbox.directories.connectionFile)
            #expect(connection.pid == pid)
            #expect(connection.version == EngineRepo.pinnedVersion)
        } catch {
            await sandbox.stop()
            throw error
        }
        let file = sandbox.directories.connectionFile
        await sandbox.stop()
        #expect(!FileManager.default.fileExists(atPath: file.path), "connection file left after stop")
    }

    /// Settings ▸ Models (docs/features/models.md): the default and small model written to the isolated global
    /// opencode.json are what opencode applies after the reload; generate.text uses the model it is given; a quota
    /// refusal comes back in a shape BelloCode maps to "usage limit".
    @Test func modelsPaneSettingsAreAppliedByOpencode() async throws {
        let sandbox = try await Sandbox.start("models")
        defer { Task { await sandbox.stop() } }
        _ = try await sandbox.inventory()
        let models = try #require(sandbox.engine.models)
        #expect(models.folder?.url == sandbox.directories.globalConfigFolder)
        #expect(await models.setDefaultModel(ModelSelection(providerID: "mock", modelID: "m2")) == nil)
        #expect(await models.setSmallModel(ModelSelection(providerID: "mock", modelID: "m1")) == nil)
        let text = try String(contentsOf: sandbox.directories.globalConfigFolder.appending(path: "opencode.json"), encoding: .utf8)
        #expect(text.contains("\"providers\""), "the rest of the file is kept")
        let client = try await sandbox.client()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        var defaultID: String?
        var titleModel: ModelRef?
        while clock.now < deadline {
            defaultID = try? await client.defaultModel(directory: sandbox.project.path)?.id
            titleModel = (try? await client.agents(directory: sandbox.project.path))?.first { $0.id == "title" }?.model
            if defaultID == "m2", titleModel?.id == "m1" { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(defaultID == "m2", "model.default after the reload")
        #expect(titleModel == ModelRef(id: "m1", providerID: "mock"), "the title agent's model (thread titles)")
        // The catalog the pane and the composer read follows.
        try await waitUntil("catalog default", timeout: .seconds(30)) {
            sandbox.engine.root.catalog.catalog(for: sandbox.project.path)?.defaultModel?.modelID == "m2"
        }

        // generate.text with a chosen model reaches that model.
        let before = sandbox.llm.bodies.count
        let reply = try await client.generateText(prompt: "Say ok", model: ModelRef(id: "m2", providerID: "mock"), timeout: .seconds(60))
        #expect(reply.contains("ok"))
        #expect(sandbox.llm.bodies.dropFirst(before).contains { $0.contains("\"m2\"") })

        // A provider's quota refusal maps to "usage limit" (not a generic failure).
        do {
            _ = try await client.generateText(prompt: "Say ok", model: ModelRef(id: "m-limited", providerID: "mock"), timeout: .seconds(90))
            Issue.record("expected a refusal")
        } catch {
            let summary = (error as? OpenCodeError)?.logSummary ?? String(describing: type(of: error))
            print("MODELS real refusal: \(summary)")
            #expect(BackgroundModelError.classify(error) == .quota, "classified as \(String(describing: BackgroundModelError.classify(error))) from \(summary)")
        }
    }

    @Test func repositoryAgentsMdReachesTheSystemPromptOfAnUntrustedProject() async throws {
        let sandbox = try await Sandbox.start("prompt")
        defer { Task { await sandbox.stop() } }
        _ = try await sandbox.inventory()
        #expect(!sandbox.engine.openCodeConfig.isTrusted(sandbox.project.path))
        let client = try await sandbox.client()
        let session = try await client.createSession(
            SessionCreateRequest(directory: sandbox.project.path, model: ModelRef(id: "m1", providerID: "mock")))
        _ = try await client.prompt(sessionID: session.id, PromptRequest(text: "hello"))
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(60)
        var system = ""
        while clock.now < deadline {
            // The turn's request carries the agent's system prompt (the title request is short and has neither marker).
            if let request = sandbox.llm.bodies.first(where: { $0.contains(Self.globalMarker) }) {
                system = request
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(system.contains(Self.globalMarker), "global AGENTS.md missing from the system prompt")
        #expect(system.contains(Self.repoMarker), "repository AGENTS.md missing from the system prompt")
        let entries = try await client.instructionEntries(sessionID: session.id)
        #expect(entries.contains { $0.key == OrchestrationContract.projectInstructionsKey })
    }
}

/// A loopback OpenAI-compatible chat endpoint: records each request body and streams a one-word reply.
final class MockLLMServer: Sendable {
    let port: UInt16
    private let socket: Int32
    private let recorded = Mutex<[String]>([])

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        socket = fd
        let server = self
        Thread.detachNewThread { server.acceptLoop() }
    }

    var bodies: [String] { recorded.withLock { $0 } }

    func stop() { shutdown(socket, SHUT_RDWR); close(socket) }

    private func acceptLoop() {
        while true {
            let client = accept(socket, nil, nil)
            if client < 0 { return }
            let server = self
            Thread.detachNewThread { server.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var data = Data()
        let separator = Data("\r\n\r\n".utf8)
        while data.range(of: separator) == nil {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { return }
            data.append(contentsOf: buffer[0..<count])
        }
        let headEnd = data.range(of: separator)!
        let head = String(decoding: data[..<headEnd.lowerBound], as: UTF8.self)
        let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        while data.count - headEnd.upperBound < length {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        let body = String(decoding: data[headEnd.upperBound...], as: UTF8.self)
        let response: String
        if head.hasPrefix("POST"), body.contains("\"m-limited\"") {
            // An exhausted allowance as OpenAI-compatible providers report it (Settings ▸ Models maps it).
            recorded.withLock { $0.append(body) }
            let json = #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","code":"insufficient_quota"}}"#
            response = "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
        } else if head.hasPrefix("POST") {
            recorded.withLock { $0.append(body) }
            let chunk = #"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m1","choices":[{"index":0,"delta":{"role":"assistant","content":"ok"},"finish_reason":null}]}"#
            let done = #"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}"#
            let stream = "data: \(chunk)\n\ndata: \(done)\n\ndata: [DONE]\n\n"
            response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(stream.utf8.count)\r\nConnection: close\r\n\r\n\(stream)"
        } else {
            let json = #"{"object":"list","data":[{"id":"m1","object":"model"}]}"#
            response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
        }
        _ = response.withCString { write(client, $0, strlen($0)) }
    }
}
