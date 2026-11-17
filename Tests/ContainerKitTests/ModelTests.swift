import Foundation
import Testing

@testable import ContainerKit

struct FakeProbeEnvironment: RuntimeProbeEnvironment {
    var files: Set<String> = []
    var contents: [String: Data] = [:]
    var result: Result<EngineVersion, SocketError> = .failure(.system(operation: "connect", errno: ECONNREFUSED))
    var parseFailure = false

    func fileExists(_ path: String) -> Bool { files.contains(path) || contents[path] != nil }
    func readFile(_ path: String) -> Data? { contents[path] }
    func probe(socketPath: String) async throws -> EngineVersion {
        if parseFailure { throw HTTPParseError.unexpectedEnd }
        return try result.get()
    }
}

@Suite("Runtime state model")
struct RuntimeDiscoveryTests {
    let home = "/Users/test"
    func discovery(_ environment: FakeProbeEnvironment) -> RuntimeDiscovery { RuntimeDiscovery(home: home, environment: environment) }
    func version(_ api: String = "1.56", os: String = "linux") -> EngineVersion {
        EngineVersion(version: "29.9.2", apiVersion: api, minAPIVersion: "1.41", os: os, arch: "arm64", kernelVersion: nil)
    }
    var settingsPath: String { home + "/Library/Preferences/rancher-desktop/settings.json" }

    @Test func notInstalled() async {
        #expect(await discovery(FakeProbeEnvironment()).detect() == .notInstalled)
    }

    @Test func containerdIsTheWrongEngine() async {
        var env = FakeProbeEnvironment(files: ["/Applications/Rancher Desktop.app", home + "/.rd/docker.sock"])
        env.contents[settingsPath] = Data(#"{"containerEngine":{"name":"containerd"}}"#.utf8)
        env.result = .success(version())
        let state = await discovery(env).detect()
        #expect(state == .wrongEngine(engine: "containerd"))
        #expect(state.userMessage.contains("dockerd"))
    }

    @Test func socketMissingOrRefusedOrSilentIsNotRunning() async {
        var env = FakeProbeEnvironment(files: ["/Applications/Rancher Desktop.app"])
        env.contents[settingsPath] = Data(#"{"containerEngine":{"name":"moby"}}"#.utf8)
        #expect(await discovery(env).detect() == .notRunning(socketPath: home + "/.rd/docker.sock"))
        env.files.insert(home + "/.rd/docker.sock")
        #expect(await discovery(env).detect() == .notRunning(socketPath: home + "/.rd/docker.sock"))
        env.parseFailure = true  // Lima accepts and closes while the VM starts
        #expect(await discovery(env).detect() == .notRunning(socketPath: home + "/.rd/docker.sock"))
    }

    @Test func readyAndTooOld() async {
        var env = FakeProbeEnvironment(files: [home + "/.rd", home + "/.rd/docker.sock"])
        env.result = .success(version())
        guard case .ready(let ready) = await discovery(env).detect() else { Issue.record("not ready"); return }
        #expect(ready.apiVersion == "1.56")
        env.result = .success(version("1.40"))
        if case .unsupported = await discovery(env).detect() {} else { Issue.record("old API accepted") }
        env.result = .success(version(os: "windows"))
        if case .unsupported = await discovery(env).detect() {} else { Issue.record("windows engine accepted") }
    }

    @Test func versionComparison() {
        #expect(RuntimeDiscovery.compare("1.56", "1.44") == 1)
        #expect(RuntimeDiscovery.compare("1.44", "1.44") == 0)
        #expect(RuntimeDiscovery.compare("1.9", "1.44") == -1)
    }
}

@Suite("Workspace spec and helper config")
struct WorkspaceModelTests {
    @Test func configHashChangesWithImageAndSetting() {
        let a = WorkspaceSpec(projectRoot: "/p", image: "img", user: "1:1")
        #expect(a.configHash(imageID: "sha256:1") == a.configHash(imageID: "sha256:1"))
        #expect(a.configHash(imageID: "sha256:1") != a.configHash(imageID: "sha256:2"), "rebuilt image → recreate")
        var b = a
        b.memoryBytes = 1 << 30
        #expect(a.configHash(imageID: "x") != b.configHash(imageID: "x"))
        #expect(a.containerName == b.containerName, "same project, same name")
    }

    @Test func noSecretsOrHostPathsBeyondTheProject() {
        let spec = WorkspaceSpec(projectRoot: "/Users/me/p", extraMounts: ["/Users/me/wt"], image: "img", user: "1:1", network: .none,
                                 publishedPorts: [3000])
        let body = spec.createBody(imageID: nil)
        let sources = body.hostConfig?.mounts?.filter { $0.type == .bind }.map(\.source) ?? []
        #expect(sources == ["/Users/me/p", "/Users/me/wt"])
        #expect(!(body.hostConfig?.mounts ?? []).contains { $0.source?.contains("docker.sock") == true })
        #expect(body.hostConfig?.portBindings == nil, "no published ports without a network")
        #expect(body.hostConfig?.networkMode == "none")
        #expect(body.hostConfig?.securityOpt == ["no-new-privileges:true"])
        #expect(body.env?.contains("HOME=/home/bellocode") == true)
    }

    @Test func containsMatchesWholePathComponents() {
        let spec = WorkspaceSpec(projectRoot: "/Users/me/app", image: "i")
        #expect(spec.contains("/Users/me/app"))
        #expect(spec.contains("/Users/me/app/src"))
        #expect(!spec.contains("/Users/me/app-other"))
    }

    @Test func helperPicksTheLongestRootAndRefusesOthers() {
        let config = ExecHelperConfig(socket: "/s", workspaces: [
            .init(roots: ["/Users/me/app"], container: "a"),
            .init(roots: ["/Users/me/app/vendor/sub"], container: "b"),
        ])
        #expect(config.workspace(for: "/Users/me/app/src")?.container == "a")
        #expect(config.workspace(for: "/Users/me/app/vendor/sub/x")?.container == "b")
        #expect(config.workspace(for: "/Users/me/app/../other") == nil)
        #expect(config.workspace(for: "/tmp") == nil)
    }

    @Test func hostOnlyVariablesAreNotForwarded() {
        let forwarded = ExecHelperConfig.forwardedEnvironment([
            "PATH": "/opt/homebrew/bin", "HOME": "/Users/me", "TMPDIR": "/var/folders/x", "XDG_DATA_HOME": "/d",
            "OPENCODE_PASSWORD": "p", "SSH_AUTH_SOCK": "/s", "TERM": "xterm-256color", "OPENCODE_TERMINAL": "1",
            "API_TOKEN": "from-session-environment", "LANG": "en_US.UTF-8", "BELLOCODE_EXEC_CONFIG": "/c",
        ])
        #expect(Set(forwarded.keys) == ["TERM", "OPENCODE_TERMINAL", "API_TOKEN", "LANG"])
    }

    @Test func wrappersQuoteTheCommandAsArguments() {
        let argv = ExecWrapper.nonInteractive(["/bin/bash", "-c", "echo 'a b' \"$HOME\""])
        #expect(argv.prefix(2) == ["/bin/sh", "-c"])
        #expect(argv.suffix(3) == ["/bin/bash", "-c", "echo 'a b' \"$HOME\""], "the command is an argument, never spliced into the script")
    }
}
