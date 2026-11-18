import Foundation
import Synchronization
import Testing

@testable import ContainerKit

/// Global image MCP servers (`bellocode-exec --stdio --mcp`): the create body (no project mount, secrets only where
/// they belong), `docker run` argument semantics, and the lifecycle against the fake daemon: per-connection containers
/// attached before start, relayed unchanged, removed when they end; one shared container with an exec per connection.
@Suite("Global image MCP servers", .timeLimit(.minutes(3)))
struct ImageMCPTests {
    static let project = "/Users/someone/src/project"

    static func spec(shared: Bool = false) -> ImageMCPSpec {
        ImageMCPSpec(id: "abc123", name: "github", image: "ghcr.io/acme/github-mcp:1", args: ["stdio"],
                     environment: ["LOG_LEVEL": "info"], secretNames: ["GITHUB_TOKEN"],
                     mounts: [UserMount(path: "/Users/someone/shared-docs", readOnly: true)], shared: shared)
    }

    @Test func aConnectionContainerMountsNoProjectFolderAndCarriesItsSecretOnlyInTheCreate() throws {
        let body = Self.spec().createBody(imageID: "sha256:img", scope: "p1", secrets: ["GITHUB_TOKEN": "s3cret"])
        let mounts = body.hostConfig?.mounts ?? []
        #expect(mounts.map(\.source) == ["/Users/someone/shared-docs"], "only the explicit mount, never a project folder")
        #expect(mounts.first?.readOnly == true)
        #expect(!mounts.contains { ($0.source ?? "").hasPrefix(Self.project) })
        #expect(body.openStdin == true && body.stdinOnce == true && body.attachStdin == true, "docker run -i: stdin open once")
        #expect(body.tty == false, "no TTY: bytes pass unchanged")
        #expect(body.cmd == ["stdio"], "arguments replace the image's CMD")
        #expect(body.entrypoint == nil, "the image's entrypoint")
        #expect(body.env?.contains("GITHUB_TOKEN=s3cret") == true)
        #expect(body.env?.contains("LOG_LEVEL=info") == true)
        #expect(body.hostConfig?.capDrop == ["ALL"])
        #expect(body.hostConfig?.securityOpt == ["no-new-privileges:true"])
        #expect(body.hostConfig?.privileged == false)
        #expect(body.hostConfig?.networkMode == "bridge")
        #expect(body.labels?[ImageMCPSpec.label] == "abc123")
        #expect(body.labels?[ImageMCPSpec.labelScope] == "p1")
        #expect(Self.spec().containerName(scope: "p1") == "bellocode-mcp-abc123-p1")
    }

    @Test func aSharedContainerKeepsSecretsOutOfItsConfiguration() throws {
        let spec = Self.spec(shared: true)
        let body = spec.createBody(imageID: "sha256:img", scope: nil, secrets: ["GITHUB_TOKEN": "s3cret"])
        #expect(!(body.env ?? []).contains { $0.hasPrefix("GITHUB_TOKEN=") }, "secrets go per exec, never into a persisted configuration")
        #expect(body.entrypoint?.first == "/bin/sh", "a keep-alive; each connection is an exec")
        #expect(body.openStdin == nil)
        #expect(spec.containerName(scope: nil) == "bellocode-mcp-abc123")
        #expect(spec.configHash(imageID: "sha256:a") != spec.configHash(imageID: "sha256:b"))
    }

    @Test func dockerRunArgumentSemanticsAreKept() {
        var spec = Self.spec()
        #expect(spec.resolvedArgv(imageEntrypoint: ["/server"], imageCmd: ["--default"]) == ["/server", "stdio"])
        spec.args = []
        #expect(spec.resolvedArgv(imageEntrypoint: ["/server"], imageCmd: ["--default"]) == ["/server", "--default"])
        spec.entrypoint = ["/other"]
        #expect(spec.resolvedArgv(imageEntrypoint: ["/server"], imageCmd: ["--default"]) == ["/other"],
                "overriding the entrypoint drops the image's CMD, as docker run --entrypoint does")
    }

    @Test func networkNoneAndCorporateCertificatesApply() {
        var spec = Self.spec()
        spec.network = .none
        spec.corporateNetwork = CorporateNetwork(certificateDirectory: "/Users/someone/certs", certificateFingerprint: "ff00")
        let body = spec.createBody(imageID: nil, scope: "p1")
        #expect(body.hostConfig?.networkMode == "none")
        #expect(body.hostConfig?.mounts?.contains { $0.target == CorporateNetwork.containerDirectory && $0.readOnly == true } == true)
        #expect(body.env?.contains("NODE_EXTRA_CA_CERTS=\(CorporateNetwork.containerEnterprise)") == true)
    }

    // MARK: Lifecycle against the fake daemon

    final class Daemon: Sendable {
        struct State {
            var creates: [Data] = []
            var removed: [String] = []
            var started: [String] = []
            var sharedCreated = false
            var execEnv: [[String]] = []
            var attachedBeforeStart = false
        }
        let state = Mutex(State())
    }

    static func daemon(_ daemon: Daemon, exitCode: Int = 0) throws -> FakeEngineServer {
        try FakeEngineServer { request, stream in
            let path = request.path
            if path.contains("/images/"), path.hasSuffix("/json") {
                try await stream.respond(200, json: #"{"Id":"sha256:img","Config":{"Entrypoint":["/server"],"Cmd":["--default"]}}"#)
            } else if path.hasSuffix("/containers/create") {
                let shared = String(decoding: request.body, as: UTF8.self).contains("bellocode-mcp\"")
                daemon.state.withLock { s in
                    s.creates.append(request.body)
                    if shared { s.sharedCreated = true }
                }
                try await stream.respond(201, json: shared ? #"{"Id":"c-shared"}"# : #"{"Id":"c-mcp"}"#)
            } else if path.contains("/containers/bellocode-mcp-abc123/json") || path.contains("/containers/c-shared/json") {
                if daemon.state.withLock({ $0.sharedCreated }) {
                    try await stream.respond(200, json: #"{"Id":"c-shared","Name":"/bellocode-mcp-abc123","Image":"sha256:img","State":{"Status":"running","Running":true},"Config":{"Labels":{"app.bellocode.mcp":"abc123","app.bellocode.config":"\#(ImageMCPTests.spec(shared: true).configHash(imageID: "sha256:img"))"}}}"#)
                } else {
                    try await stream.respond(404, json: #"{"message":"No such container"}"#)
                }
            } else if path.contains("/containers/bellocode-mcp-"), path.hasSuffix("/json") {
                try await stream.respond(404, json: #"{"message":"No such container"}"#)
            } else if path.hasSuffix("/attach") || path.hasSuffix("/start") && path.contains("/exec/") {
                if path.hasSuffix("/attach") {
                    daemon.state.withLock { $0.attachedBeforeStart = $0.started.isEmpty }
                }
                try await stream.write(Data("HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n".utf8))
                while let data = try? await stream.read(), !data.isEmpty {
                    try await stream.write(StreamDemuxer.frame(.stdout, data))
                }
                try await stream.write(StreamDemuxer.frame(.stderr, Data("bye\n".utf8)))
            } else if path.hasSuffix("/start") {
                daemon.state.withLock { $0.started.append(path) }
                try await stream.respond(204)
            } else if path.hasSuffix("/wait") {
                try await stream.respond(200, json: #"{"StatusCode":\#(exitCode)}"#)
            } else if request.method == "DELETE" {
                daemon.state.withLock { $0.removed.append(path) }
                try await stream.respond(204)
            } else if path.hasSuffix("/exec") {
                let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
                daemon.state.withLock { $0.execEnv.append(object?["Env"] as? [String] ?? []) }
                try await stream.respond(201, json: #"{"Id":"exec1"}"#)
            } else if path.contains("/exec/"), path.hasSuffix("/json") {
                try await stream.respond(200, json: #"{"ID":"exec1","Running":false,"ExitCode":\#(exitCode),"Pid":9}"#)
            } else {
                try await stream.respond(404, json: #"{"message":"?"}"#)
            }
        }
    }

    @Test func aConnectionRunsLikeDockerRunInteractiveAndIsRemovedWhenItEnds() async throws {
        let daemon = Daemon()
        let server = try Self.daemon(daemon, exitCode: 3)
        defer { server.stop() }
        let session = try await ImageMCPRunner(client: server.client).start(Self.spec(), scope: "p1", secrets: ["GITHUB_TOKEN": "s3cret"], token: "t")
        #expect(session is AttachSession)
        let message = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8) + Data([10])
        let feeder = StdioRelayTests.Feeder([message])
        let sink = StdioRelayTests.Sink()
        let code = try await StdioRelay.run(session: session, readInput: feeder.next, writeOutput: sink.write)
        #expect(code == 3, "the program's exit status")
        #expect(sink.stdout.withLock { $0 } == message, "bytes cross unchanged")
        #expect(String(decoding: sink.stderr.withLock { $0 }, as: UTF8.self) == "bye\n")
        let state = daemon.state.withLock { $0 }
        #expect(state.attachedBeforeStart, "attached before start, so no output is lost")
        #expect(state.removed.contains { $0.hasSuffix("/containers/c-mcp") }, "removed after it ended (--rm)")
        let create = String(decoding: state.creates.first ?? Data(), as: UTF8.self)
        #expect(!create.contains(Self.project))
        #expect(create.contains("GITHUB_TOKEN=s3cret"))
    }

    @Test func aSharedServerIsCreatedOnceAndEachConnectionIsAnExecWithItsSecret() async throws {
        let daemon = Daemon()
        let server = try Self.daemon(daemon)
        defer { server.stop() }
        let runner = ImageMCPRunner(client: server.client)
        for _ in 0..<2 {
            let session = try await runner.start(Self.spec(shared: true), scope: nil, secrets: ["GITHUB_TOKEN": "s3cret"], token: "t")
            #expect(session is ExecSession)
            let sink = StdioRelayTests.Sink()
            _ = try await StdioRelay.run(session: session, readInput: StdioRelayTests.Feeder([Data("x\n".utf8)]).next, writeOutput: sink.write)
            #expect(sink.stdout.withLock { $0 } == Data("x\n".utf8))
        }
        let state = daemon.state.withLock { $0 }
        #expect(state.creates.count == 1, "one container for every project")
        #expect(state.execEnv.count == 2)
        #expect(state.execEnv.allSatisfy { $0.contains("GITHUB_TOKEN=s3cret") }, "the secret travels with each exec")
        #expect(!String(decoding: state.creates[0], as: UTF8.self).contains("s3cret"))
    }

    @Test func aMissingImageIsReportedNeverPulled() async throws {
        let server = try FakeEngineServer { request, stream in
            if request.path.contains("/images/") { try await stream.respond(404, json: #"{"message":"No such image"}"#) } else {
                try await stream.respond(500, json: #"{"message":"unexpected"}"#)
            }
        }
        defer { server.stop() }
        await #expect(throws: ImageMCPError.imageMissing("ghcr.io/acme/github-mcp:1")) {
            _ = try await ImageMCPRunner(client: server.client).start(Self.spec(), scope: "p1", secrets: [:], token: "t")
        }
        #expect(!server.requests.withLock { $0 }.contains { $0.path.contains("/images/create") }, "the helper never pulls")
    }

    @Test func helperArgumentsForAGlobalImageServer() throws {
        #expect(try HelperInvocation.parse(["--stdio", "--mcp", "abc123", "--project", "/p"]) == .globalMCP(id: "abc123", project: "/p"))
        #expect(try HelperInvocation.parse(["--stdio", "--mcp", "abc123"]) == .globalMCP(id: "abc123", project: nil))
        #expect(throws: HelperInvocation.ParseError.self) { try HelperInvocation.parse(["--stdio", "--mcp", "abc", "--", "sh"]) }
    }

    @Test func theHelperConfigurationNamesSecretsButNeverHoldsValues() throws {
        let config = ExecHelperConfig(socket: "/s", workspaces: [], mcpServers: [Self.spec()], mcpLogDirectory: "/logs")
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(text.contains("GITHUB_TOKEN"))
        #expect(!text.contains("s3cret"))
        let decoded = try JSONDecoder().decode(ExecHelperConfig.self, from: try config.encoded())
        #expect(decoded.mcpServers == [Self.spec()])
        #expect(decoded.mcpLogDirectory == "/logs")
    }

    @Test func theLogKeepsItsNewestPartWithinItsBound() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "bc-log-\(UUID().uuidString)/x.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = BoundedLogFile(url: url, limit: 1000)
        for index in 0..<120 { log.append(Data("line \(index) ........\n".utf8)) }
        let text = log.read()
        #expect(text.utf8.count <= 1000)
        #expect(text.contains("line 119"))
        #expect(!text.contains("line 0 "))
    }
}
