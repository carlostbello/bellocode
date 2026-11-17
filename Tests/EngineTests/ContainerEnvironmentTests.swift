import BelloCore
import ContainerKit
import Foundation
import OpenCodeKit
import Synchronization
import Testing

@testable import Engine

/// A runtime without Rancher Desktop: records what EnvironmentService asks of it.
final class FakeWorkspaceRuntime: WorkspaceRuntime {
    struct Exec: Sendable {
        var argv: [String]
        var workingDir: String?
        var environment: [String: String]
    }

    struct State: Sendable {
        var runtime: RuntimeState = .ready(.init(socketPath: "/tmp/fake.sock", engineVersion: "27.0", apiVersion: "1.47", arch: "aarch64"))
        var images: Set<String> = []
        var running: [String: String] = [:]  // container name -> config hash
        var ensureCount = 0
        var execs: [Exec] = []
        var output = Data("ok\n".utf8)
        var removed: [String] = []
    }

    let state = Mutex(State())
    var socketPath: String { "/tmp/fake.sock" }

    func detect() async -> RuntimeState { state.withLock { $0.runtime } }
    func image(_ reference: String) async throws -> ImageSummary? {
        guard state.withLock({ $0.images.contains(reference) }) else { return nil }
        return try JSONDecoder().decode(ImageSummary.self, from: Data(#"{"Id":"sha256:abc"}"#.utf8))
    }
    func pull(_ reference: String, auth: RegistryAuth?, progress: @escaping @Sendable (ProgressMessage) -> Void) async throws {
        _ = state.withLock { $0.images.insert(reference) }
    }
    func status(_ spec: WorkspaceSpec) async throws -> WorkspaceStatus {
        state.withLock { s in
            guard let hash = s.running[spec.containerName] else { return WorkspaceStatus(phase: .absent) }
            return hash == spec.configHash(imageID: "sha256:abc")
                ? WorkspaceStatus(phase: .running, containerID: spec.containerName, imageID: "sha256:abc")
                : WorkspaceStatus(phase: .outdated, containerID: spec.containerName, outdatedReason: "settings changed")
        }
    }
    func ensureRunning(_ spec: WorkspaceSpec) async throws -> String {
        state.withLock { s in
            s.ensureCount += 1
            s.running[spec.containerName] = spec.configHash(imageID: "sha256:abc")
        }
        return spec.containerName
    }
    func stop(container: String) async throws { _ = state.withLock { $0.running.removeValue(forKey: container) } }
    func start(container: String) async throws {}
    func restart(container: String) async throws {}
    func remove(projectKey: String, volumes: Bool) async throws {
        state.withLock { s in
            s.removed.append(projectKey)
            s.running = s.running.filter { !$0.key.hasSuffix(projectKey) }
        }
    }
    func removeContainer(_ id: String) async throws {}
    func managedContainers() async throws -> [ContainerSummary] { [] }
    func runningExecs(container: String) async -> Int { 0 }
    func listeningPorts(container: String, user: String) async throws -> [ListeningPort] { [] }
    func reap(container: String, user: String) async throws -> Int { 0 }
    func inventory(container: String, user: String) async throws -> ContainerProbes.ToolInventory {
        .init(os: "Debian", arch: "aarch64", tools: ["bash", "git"])
    }
    func touch(container: String, user: String, paths: [String]) async throws {}
    func run(container: String, argv: [String], workingDir: String?, environment: [String: String], user: String,
             timeout: Duration) async throws -> (exitCode: Int, stdout: Data, stderr: Data) {
        state.withLock { s in
            s.execs.append(Exec(argv: argv, workingDir: workingDir, environment: environment))
            return (0, s.output, Data())
        }
    }
    func logs(container: String, tail: Int) async throws -> Data { Data() }
    func events() -> AsyncStream<EngineMonitorEvent> { AsyncStream { _ in } }
    func makeForwarder(container: String, port: ListeningPort, hostPort: Int, user: String) throws -> PortForwarder {
        throw ContainerError.notFound("no forwarding in the fake")
    }
}

@MainActor
@Suite("Container environments", .timeLimit(.minutes(1)))
struct ContainerEnvironmentTests {
    let root: URL
    let project: String
    let runtime = FakeWorkspaceRuntime()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "bellocode-env-\(UUID().uuidString)", directoryHint: .isDirectory)
        project = root.appending(path: "project").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
    }

    func makeService(enabled: Bool = true) async throws -> EnvironmentService {
        let configuration = enabled
            ? ContainerConfiguration(
                helperURL: URL(filePath: "/Applications/BelloCode.app/Contents/Helpers/bellocode-exec"),
                execConfigURL: root.appending(path: "exec.json"), opencodeDataDirectory: nil, runtime: runtime,
                registryVault: InMemorySecretVault())
            : nil
        let service = EnvironmentService(configuration: configuration, store: try ProjectionStore(location: .inMemory))
        service.worktreeParent = { [root] directory in root.appending(path: "worktrees/\((directory as NSString).lastPathComponent)").path }
        await service.start()
        return service
    }

    func config() throws -> ExecHelperConfig {
        try JSONDecoder().decode(ExecHelperConfig.self, from: Data(contentsOf: root.appending(path: "exec.json")))
    }

    func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func offWithoutConfigurationAndNeverTouchesARuntime() async throws {
        let service = try await makeService(enabled: false)
        #expect(!service.isEnabled)
        await service.writeConfigNow()
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "exec.json").path))
        await #expect(throws: (any Error).self) { _ = try await service.readyContainer(project) }
        service.stop()
    }

    @Test func noImageIsBlockedWithChooseAnImageAndNoPublicDefault() async throws {
        let service = try await makeService()
        defer { service.stop() }
        let model = service.environment(for: project)
        #expect(await waitFor { model.phase == .noImage })
        await service.writeConfigNow()
        let workspace = try #require(try config().workspace(for: project))
        #expect(workspace.blocked?.fix == EnvironmentFix.chooseImage.title)
        #expect(model.notice?.fix == .chooseImage)
        #expect(runtime.state.withLock { $0.ensureCount } == 0)
    }

    @Test func runtimeDownBlocksEveryCommandWithStartRancher() async throws {
        runtime.state.withLock { $0.runtime = .notRunning(socketPath: "/tmp/fake.sock") }
        let service = try await makeService()
        defer { service.stop() }
        #expect(await waitFor { service.runtime != nil })
        await service.writeConfigNow()
        let blocked = try #require(try config().runtimeBlocked)
        #expect(blocked.fix == EnvironmentFix.startRancher.title)
        await #expect(throws: (any Error).self) { _ = try await service.readyContainer(project) }
    }

    @Test func imageSettingRunsAndASettingChangeRecreates() async throws {
        runtime.state.withLock { $0.images = ["img:1", "img:2"] }
        let service = try await makeService()
        defer { service.stop() }
        #expect(await waitFor { service.runtime?.isReady == true })
        var settings = ProjectEnvironmentSettings()
        settings.image = "img:1"
        await service.update(project, settings: settings)
        let model = service.environment(for: project)
        #expect(await waitFor { model.phase == .idle })
        service.activate(project)
        #expect(await waitFor { model.phase == .ready })
        let first = runtime.state.withLock { $0.ensureCount }
        #expect(first >= 1)
        settings.image = "img:2"
        await service.update(project, settings: settings)
        #expect(await waitFor { runtime.state.withLock { $0.ensureCount } > first })
        // The helper's configuration names the container and mounts the project at the same path.
        await service.writeConfigNow()
        let workspace = try #require(try config().workspace(for: project + "/src"))
        #expect(workspace.roots.first == project)
        #expect(workspace.blocked == nil)
    }

    @Test func secretGoesOnlyIntoOneExecAndIsRedacted() async throws {
        runtime.state.withLock { $0.images = ["img:1"]; $0.output = Data("token=s3cr3t-value\n".utf8) }
        let service = try await makeService()
        defer { service.stop() }
        #expect(await waitFor { service.runtime?.isReady == true })
        var settings = ProjectEnvironmentSettings()
        settings.image = "img:1"
        await service.update(project, settings: settings)
        let result = try await service.runWithSecret(directory: project, command: "deploy", name: "API_TOKEN", secret: SecretValue("s3cr3t-value"))
        #expect(!result.output.contains("s3cr3t-value"))
        #expect(result.output.contains("<secret>"))
        _ = try await service.runSetup("make setup", in: project, projectDirectory: project)
        let execs = runtime.state.withLock { $0.execs }
        #expect(execs.filter { $0.environment.values.contains("s3cr3t-value") }.count == 1)
        #expect(execs.last?.environment["API_TOKEN"] == nil)
        // Never in the container's configuration or the helper's file.
        await service.writeConfigNow()
        let file = try String(contentsOf: root.appending(path: "exec.json"), encoding: .utf8)
        #expect(!file.contains("s3cr3t-value"))
    }

    @Test func setupScriptsRunInTheContainerInTheWorktree() async throws {
        runtime.state.withLock { $0.images = ["img:1"] }
        let service = try await makeService()
        defer { service.stop() }
        #expect(await waitFor { service.runtime?.isReady == true })
        var settings = ProjectEnvironmentSettings()
        settings.image = "img:1"
        await service.update(project, settings: settings)
        let worktree = root.appending(path: "worktrees/project/feature").path
        _ = try await service.runSetup("npm ci", in: worktree, projectDirectory: project)
        let exec = try #require(runtime.state.withLock { $0.execs.last })
        #expect(exec.workingDir == worktree)
        #expect(exec.argv.last == "npm ci")
        // A folder outside every mounted root is refused, never run on the host.
        await #expect(throws: (any Error).self) { _ = try await service.runSetup("x", in: "/opt/elsewhere", projectDirectory: project) }
    }
}

@MainActor
@Suite("Container secret references")
struct ContainerSecretReferenceTests {
    @Test func oneUseOneThreadAndExpiry() throws {
        let references = ContainerSecretReferences()
        let now = Date()
        let reference = references.issue(account: "a", label: "Token", for: SessionID("s1"), now: now)
        #expect(ContainerSecretReferences.isContainerReference(reference))
        #expect(throws: ExtrasError.self) { try references.redeem(reference, by: SessionID("s2"), now: now) }
        #expect(try references.redeem(reference, by: SessionID("s1"), now: now).account == "a")
        #expect(throws: ExtrasError.self) { try references.redeem(reference, by: SessionID("s1"), now: now) }
        let late = references.issue(account: "b", label: "B", for: SessionID("s1"), now: now)
        #expect(throws: ExtrasError.self) { try references.redeem(late, by: SessionID("s1"), now: now.addingTimeInterval(3_601)) }
    }

    @Test func variableNamesExcludeReservedAndRuntimeSwitches() throws {
        #expect(try SecretVariableName.validate("NPM_TOKEN") == "NPM_TOKEN")
        for bad in ["", "PATH", "BUN_BE_BUN", "BELLOCODE_X", "1A", "A-B", "A B"] {
            #expect(throws: ExtrasError.self) { try SecretVariableName.validate(bad) }
        }
    }
}

@Suite("Container interception configuration")
struct ContainerInterceptionTests {
    let execution = ContainerExecution(
        helperURL: URL(filePath: "/App/Contents/Helpers/bellocode-exec"), execConfigURL: URL(filePath: "/data/bellocode-exec.json"))

    @Test func serverEnvironmentRoutesTheShellAndNeverSetsTheJavaScriptRuntimeSwitch() {
        var configuration = ServerConfiguration(executableURL: URL(filePath: "/App/opencode"), dataRoot: URL(filePath: "/data"))
        configuration.containerExecution = execution
        configuration.extraEnvironment = ["BUN_BE_BUN": "1", "BUN_OPTIONS": "x"]
        let environment = configuration.environment(credentials: ServerCredentials(password: "p"))
        #expect(environment["SHELL"] == "/App/Contents/Helpers/bellocode-exec")
        #expect(environment["OPENCODE_DISABLE_PROJECT_CONFIG"] == "1")
        #expect(environment["GIT_CONFIG_KEY_0"] == "core.hooksPath")
        #expect(environment.keys.allSatisfy { !$0.hasPrefix("BUN_") })
        let content = environment["OPENCODE_CONFIG_CONTENT"] ?? ""
        #expect(content.contains("bellocode-exec"))
        #expect(content.contains(#""formatter":false"#) || content.contains(#""formatter" : false"#))
    }

    @Test func hostGitNeverRunsHooks() throws {
        let runner = GitRunner()
        let invocation = try #require(runner.invocation(["status"], in: NSTemporaryDirectory(), writableRoots: [], trusted: .init()))
        #expect(invocation.executable == HostGit.sandboxExecutable)
        let environment = invocation.environment
        let pairs = (0..<(Int(environment["GIT_CONFIG_COUNT"] ?? "0") ?? 0)).map { (environment["GIT_CONFIG_KEY_\($0)"], environment["GIT_CONFIG_VALUE_\($0)"]) }
        #expect(pairs.contains { $0.0 == "core.hooksPath" && $0.1 == "/dev/null" })
    }

    @Test func configurationScanFlagsEveryHostPath() {
        let entries: [JSONValue] = [
            .object(["shell": .string("/bin/zsh"), "formatter": .bool(true),
                     "mcp": .object(["servers": .object(["db": .object(["type": .string("local")])])])]),
        ]
        let checks = IsolationCheck.configurationChecks(entries, projects: [], helperPath: "/App/Contents/Helpers/bellocode-exec", guardInstalled: false)
        let byName = Dictionary(uniqueKeysWithValues: checks.map { ($0.name, $0.outcome) })
        #expect(byName["Configured shell"]?.isProblem == true)
        #expect(byName["Formatters"]?.isProblem == true)
        #expect(byName["Local MCP servers"]?.isProblem == true)
        #expect(byName["Plugin guard"]?.isProblem == true)
        let clean = IsolationCheck.configurationChecks(
            [.object(["shell": .string("/App/Contents/Helpers/bellocode-exec"), "formatter": .bool(false), "lsp": .bool(false)])],
            projects: [], helperPath: "/App/Contents/Helpers/bellocode-exec", guardInstalled: true)
        #expect(clean.allSatisfy { !$0.outcome.isProblem })
    }

    @Test func terminalsOpenTheHelperWithoutTheMacEnvironment() {
        let launch = TerminalLaunch.container(
            helper: URL(filePath: "/App/Contents/Helpers/bellocode-exec"), execConfig: URL(filePath: "/data/x.json"),
            processEnvironment: ["SSH_AUTH_SOCK": "/tmp/agent", "PATH": "/opt/homebrew/bin:/usr/bin", "LANG": "en_US.UTF-8"])
        #expect(launch.isContainer)
        #expect(launch.args.isEmpty)
        #expect(launch.environment["SSH_AUTH_SOCK"] == nil)
        #expect(launch.environment["PATH"] == "/usr/bin:/bin")
        #expect(launch.environment["BELLOCODE_EXEC_CONFIG"] == "/data/x.json")
    }
}
