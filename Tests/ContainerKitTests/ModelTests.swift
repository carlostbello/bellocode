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
        b.resources.memoryBytes = 1 << 30
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

    @Test func resolvedWorkingDirectoryMapsBackToTheMountedPath() throws {
        // A shell's current directory is resolved (/private/var/…) while the project was opened as /var/….
        let base = FileManager.default.temporaryDirectory.appending(path: "bc-resolve-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base + "/src", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let config = ExecHelperConfig(socket: "/s", workspaces: [.init(roots: [base], container: "a")])
        let resolved = (base as NSString).resolvingSymlinksInPath + "/src"
        let match = try #require(config.resolve(directory: resolved))
        #expect(match.workspace.container == "a")
        #expect(match.directory == base + "/src")
        #expect(config.resolve(directory: "/usr/bin") == nil)
    }

    @Test func hostOnlyVariablesAreNotForwarded() {
        let forwarded = ExecHelperConfig.forwardedEnvironment([
            "PATH": "/opt/homebrew/bin", "HOME": "/Users/me", "TMPDIR": "/var/folders/x", "XDG_DATA_HOME": "/d",
            "OPENCODE_PASSWORD": "p", "SSH_AUTH_SOCK": "/s", "TERM": "xterm-256color", "OPENCODE_TERMINAL": "1",
            "API_TOKEN": "from-session-environment", "LANG": "en_US.UTF-8", "BELLOCODE_EXEC_CONFIG": "/c",
        ])
        #expect(Set(forwarded.keys) == ["TERM", "OPENCODE_TERMINAL", "API_TOKEN", "LANG"])
        let bun = ExecHelperConfig.forwardedEnvironment(["BUN_BE_BUN": "1", "BUN_INSTALL": "/x", "GIT_CONFIG_COUNT": "1", "BELLOCODE_X": "1"])
        #expect(bun.isEmpty, "BUN_BE_BUN never reaches anything; host git policy and BelloCode variables stay on the host")
    }

    @Test func wrappersQuoteTheCommandAsArguments() {
        let argv = ExecWrapper.nonInteractive(["/bin/bash", "-c", "echo 'a b' \"$HOME\""])
        #expect(argv.prefix(2) == ["/bin/sh", "-c"])
        #expect(argv.suffix(3) == ["/bin/bash", "-c", "echo 'a b' \"$HOME\""], "the command is an argument, never spliced into the script")
    }
}

@Suite("Runtime version policy")
struct RuntimePolicyTests {
    func version(_ api: String, min: String? = "1.24", os: String = "linux") -> EngineVersion {
        EngineVersion(version: "29.9.2", apiVersion: api, minAPIVersion: min, os: os, arch: "arm64", kernelVersion: "6.18")
    }

    @Test func driftIsDetected() {
        #expect(RuntimeDiscovery.evaluate(version("1.56"), socketPath: "/s", rancherVersion: "1.25.0").isReady)
        if case .unsupported(let reason) = RuntimeDiscovery.evaluate(version("1.43"), socketPath: "/s", rancherVersion: nil) {
            #expect(reason.contains("older"))
        } else { Issue.record("API 1.43 accepted") }
        if case .unsupported(let reason) = RuntimeDiscovery.evaluate(version("1.60", min: "1.50"), socketPath: "/s", rancherVersion: nil) {
            #expect(reason.contains("no longer accepts"))
        } else { Issue.record("a daemon that dropped 1.44 accepted") }
        guard case .ready(let ready) = RuntimeDiscovery.evaluate(version("1.56"), socketPath: "/s", rancherVersion: "1.31.2") else {
            Issue.record("newer Rancher refused"); return
        }
        #expect(ready.notes.first?.contains("newer than the tested") == true)
    }

    @Test func everyStateHasAFixAndText() {
        let states: [RuntimeState] = [.notInstalled, .notRunning(socketPath: "/s"), .wrongEngine(engine: "containerd"),
                                      .unsupported(reason: "x")]
        #expect(states.map(\.fix) == [.installRancher, .startRancher, .switchEngine, .updateRuntime])
        #expect(states.allSatisfy { !$0.userMessage.isEmpty && !$0.shortLabel.isEmpty })
        #expect(RuntimeState.notRunning(socketPath: "/s").userMessage.contains("nothing runs on this Mac"))
    }

    @Test func rancherVersionComesFromItsInfoPlist() async {
        var env = FakeProbeEnvironment(files: ["/Applications/Rancher Desktop.app", "/Users/t/.rd/docker.sock"])
        env.contents["/Applications/Rancher Desktop.app/Contents/Info.plist"] = try? PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "1.25.0"], format: .xml, options: 0)
        env.result = .success(version("1.56"))
        guard case .ready(let ready) = await RuntimeDiscovery(home: "/Users/t", environment: env).detect() else {
            Issue.record("not ready"); return
        }
        #expect(ready.rancherVersion == "1.25.0")
    }
}

@Suite("Probes, registry auth and helper config")
struct ProbeParsingTests {
    @Test func listeningPortsWithOwners() {
        let output = """
        #tcp
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000   501        0 4242 1 0000000000000000 100 0 0 10 0
           1: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000   501        0 4343 1 0000000000000000 100 0 0 10 0
           2: 0100007F:1F90 0100007F:D431 01 00000000:00000000 00:00000000 00000000   501        0 4444 1 0000000000000000 100 0 0 10 0
        #tcp6
          sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000000000000000000001000000:1435 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000   501        0 5151 1 0000000000000000 100 0 0 10 0
        #fd
        77 [4242] python3
        90 [5151] node
        """
        let ports = ContainerProbes.parseListeningPorts(output)
        #expect(ports == [
            ListeningPort(port: 3000, address: "0.0.0.0"),
            ListeningPort(port: 5173, address: "::1", pid: 90, process: "node"),
            ListeningPort(port: 8080, address: "127.0.0.1", pid: 77, process: "python3"),
        ])
        #expect(ports[1].relayHost == "::1" && ports[2].relayHost == "127.0.0.1")
        #expect(ports[0].isWildcard)
    }

    @Test func processesAndInventory() {
        let processes = ContainerProbes.parseProcesses("1 0 /sbin/docker-init -- sleep infinity\n7 1 sleep infinity\n40 1 node server.js\n")
        #expect(processes.map(\.pid) == [1, 7, 40] && processes[2].ppid == 1 && processes[2].command == "node server.js")
        let inventory = ContainerProbes.parseInventory("os=Debian GNU/Linux 12 (bookworm)\narch=aarch64\ntool=bash\ntool=node\n")
        #expect(inventory == .init(os: "Debian GNU/Linux 12 (bookworm)", arch: "aarch64", tools: ["bash", "node"]))
    }

    @Test func touchAndRelayPassPathsAsArguments() {
        let argv = ContainerProbes.touchScript(["/p/a b.ts", "/p/$(x)"])
        #expect(argv.suffix(2) == ["/p/a b.ts", "/p/$(x)"], "paths are arguments, never spliced into the script")
        let relay = ContainerProbes.relayScript(host: "::1", port: 5173)
        #expect(relay.suffix(2) == ["::1", "5173"])
    }

    @Test func registryAuthIsBase64URLAndNeverPrinted() throws {
        let auth = RegistryAuth(username: "dev", password: "hunter2/+", serverAddress: "registry.corp.example")
        #expect(!auth.headerValue.contains("+") && !auth.headerValue.contains("/") && !auth.headerValue.contains("="))
        var base64 = auth.headerValue.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        let decoded = try JSONSerialization.jsonObject(with: try #require(Data(base64Encoded: base64))) as? [String: String]
        #expect(decoded?["password"] == "hunter2/+")
        #expect(!"\(auth)".contains("hunter2") && !String(reflecting: auth).contains("hunter2"))
        #expect(RegistryAuth.registry(of: "registry.corp.example:5000/team/img:1") == "registry.corp.example:5000")
        #expect(RegistryAuth.registry(of: "node:22") == "docker.io")
        #expect(RegistryAuth.registry(of: "library/node@sha256:abc") == "docker.io")
    }

    @Test func helperConfigV1StillDecodesAndV2RoundTrips() throws {
        let v1 = Data(#"{"socket":"/s","workspaces":[{"roots":["/p"],"container":"c","shell":"/bin/sh"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(ExecHelperConfig.self, from: v1)
        #expect(decoded.version == 1 && decoded.workspaces.first?.blocked == nil)
        let spec = WorkspaceSpec(projectRoot: "/p", image: "img", user: "1:1")
        var config = ExecHelperConfig(socket: "/s", workspaces: [
            .init(roots: ["/p"], container: spec.containerName, user: "1:1", blocked: .init(message: "No image", fix: "Choose an image"),
                  spec: spec, mountIdentity: "1:2"),
        ])
        config.runtimeBlocked = nil
        let url = FileManager.default.temporaryDirectory.appending(path: "bc-exec-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try config.write(to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try JSONDecoder().decode(ExecHelperConfig.self, from: Data(contentsOf: url)) == config)
    }

    @Test func rancherSharesOnlyItsFolders() {
        #expect(RancherFileSharing.isShared("/Users/t/src/app", home: "/Users/t"))
        #expect(RancherFileSharing.isShared("/Volumes/Work/app", home: "/Users/t"))
        #expect(!RancherFileSharing.isShared("/opt/src/app", home: "/Users/t"))
        #expect(!RancherFileSharing.isShared("/Users/tom/app", home: "/Users/t"))
        let spec = WorkspaceSpec(projectRoot: "/opt/nowhere-\(UUID().uuidString)", image: "i")
        #expect(spec.unmountablePaths() == [spec.projectRoot])
    }

    @Test func userMountsAreReadOnlyByDefaultAndNotWorkspaces() {
        let spec = WorkspaceSpec(projectRoot: "/Users/me/p", userMounts: [UserMount(path: "/Users/me/data")], image: "i", user: "1:1")
        let mount = spec.createBody(imageID: nil).hostConfig?.mounts?.first { $0.source == "/Users/me/data" }
        #expect(mount?.readOnly == true)
        #expect(!spec.contains("/Users/me/data/x"), "commands do not run in data folders")
    }
}
