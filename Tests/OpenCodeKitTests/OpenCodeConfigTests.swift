import Darwin
import Foundation
import Testing
@testable import OpenCodeKit

/// The isolated directories, the CLI wrapper's plan, the connection and trust files, global-folder templates and the
/// repository-config policy in the server environment (docs/features/opencode-config.md).
@Suite("opencode config")
struct OpenCodeConfigTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-occ-\(UUID().uuidString)", directoryHint: .isDirectory)
    var directories: OpenCodeDirectories { OpenCodeDirectories(dataRoot: root) }
    let opencode = URL(fileURLWithPath: "/Applications/BelloCode.app/Contents/Helpers/opencode")
    let helpers = URL(fileURLWithPath: "/Applications/BelloCode.app/Contents/Helpers", isDirectory: true)
    var runningFile: CLIConnectionFile {
        CLIConnectionFile(url: URL(string: "http://127.0.0.1:50123")!, pid: getpid(), version: "2.3.2")
    }
    let running = OpenCodeCLI.ServerAvailability.running(url: URL(string: "http://127.0.0.1:50123")!, password: "per-launch-secret")

    private func plan(_ arguments: [String], caller: [String: String] = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
                      connection: OpenCodeCLI.ServerAvailability?) -> Result<OpenCodeCLI.Invocation, OpenCodeCLI.Refusal> {
        OpenCodeCLI.plan(arguments: arguments, callerEnvironment: caller, directories: directories, opencode: opencode,
                         helpersDirectory: helpers, server: { .success(connection ?? .offline) })
    }

    // MARK: Wrapper environment and routing

    @Test func wrapperEnvironmentIsIsolatedAndDropsRedirections() throws {
        let caller = [
            "PATH": "/opt/homebrew/bin:/usr/bin", "TERM": "xterm-256color", "HOME": "/Users/someone", "XDG_CONFIG_HOME": "/Users/someone/.config",
            "OPENCODE_CONFIG_DIR": "/elsewhere", "OPENCODE_DB": "/tmp/x.db", "OPENCODE_CONFIG_CONTENT": "{}", "OPENCODE_PASSWORD": "callers",
            "BUN_BE_BUN": "1", "EDITOR": "vim",
        ]
        let invocation = try plan(["auth", "list"], caller: caller, connection: running).get()
        let env = invocation.environment
        #expect(env["HOME"] == root.appending(path: "home").path)
        #expect(env["XDG_CONFIG_HOME"] == root.appending(path: "config").path)
        #expect(env["XDG_DATA_HOME"] == root.appending(path: "data").path)
        #expect(env["XDG_STATE_HOME"] == root.appending(path: "state").path)
        #expect(env["XDG_CACHE_HOME"] == root.appending(path: "cache").path)
        #expect(env["OPENCODE_DISABLE_AUTOUPDATE"] == "1")
        #expect(env["OPENCODE_DISABLE_PROJECT_CONFIG"] == "1")
        #expect(env["OPENCODE_DISABLE_CLAUDE_CODE"] == "1")
        #expect(env["OPENCODE_CONFIG_DIR"] == nil)
        #expect(env["OPENCODE_DB"] == nil)
        #expect(env["OPENCODE_CONFIG_CONTENT"] == nil)
        #expect(env["BUN_BE_BUN"] == nil)
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["EDITOR"] == "vim")
        #expect(env["PATH"] == "\(helpers.path):/opt/homebrew/bin:/usr/bin")
        // The running server's per-launch password, in the environment only.
        #expect(env["OPENCODE_PASSWORD"] == "per-launch-secret")
        #expect(!invocation.arguments.contains("per-launch-secret"))
        #expect(invocation.executable == opencode)
    }

    @Test func clientCommandsUseTheRunningServer() throws {
        #expect(try plan(["auth", "login", "openai"], connection: running).get().arguments
            == ["auth", "login", "--server", "http://127.0.0.1:50123", "openai"])
        #expect(try plan(["models"], connection: running).get().arguments == ["models", "--server", "http://127.0.0.1:50123"])
        #expect(try plan(["run", "hello", "world"], connection: running).get().arguments
            == ["run", "--server", "http://127.0.0.1:50123", "hello", "world"])
        #expect(try plan(["--log-level", "debug", "mcp", "list"], connection: running).get().arguments
            == ["--log-level", "debug", "mcp", "list", "--server", "http://127.0.0.1:50123"])
        // The interactive interface (no subcommand).
        #expect(try plan([], connection: running).get().arguments == ["--server", "http://127.0.0.1:50123"])
    }

    @Test func withoutBelloCodeOnlyManagementCommandsGetAPrivateServer() throws {
        let auth = try plan(["auth", "list"], connection: nil).get()
        #expect(auth.arguments == ["auth", "list", "--standalone"])
        #expect(auth.environment["OPENCODE_PASSWORD"] == nil)
        #expect(auth.notice != nil)
        #expect(try plan(["session", "list"], connection: nil).get().arguments == ["session", "list", "--standalone"])
        // An agent, MCP servers or arbitrary API calls would run on the Mac without BelloCode's container shell.
        for refused in [["run", "hi"], [], ["mini"], ["api", "session.list"], ["mcp", "list"], ["reload"]] {
            guard case .failure(let refusal) = plan(refused, connection: nil) else {
                Issue.record("\(refused) should need BelloCode"); continue
            }
            #expect(refusal.message.contains("needs BelloCode"))
        }
    }

    @Test func refusedAndDirectCommands() throws {
        for command in [["service", "start"], ["serve"], ["upgrade"], ["update"], ["uninstall"], ["pair"], ["acp"]] {
            guard case .failure = plan(command, connection: running) else { Issue.record("\(command) not refused"); continue }
        }
        // A second server on our database while BelloCode runs.
        guard case .failure = plan(["models", "--standalone"], connection: running) else { Issue.record("standalone allowed"); return }
        // File-only commands and help run as given.
        #expect(try plan(["mcp", "add", "x", "--", "docker", "run", "img"], connection: running).get().arguments
            == ["mcp", "add", "x", "--", "docker", "run", "img"])
        #expect(try plan(["plugin", "add", "some-plugin"], connection: nil).get().arguments == ["plugin", "add", "some-plugin"])
        #expect(try plan(["debug", "paths"], connection: nil).get().arguments == ["debug", "paths"])
        #expect(try plan(["auth", "--help"], connection: nil).get().arguments == ["auth", "--help"])
    }

    @Test func anExplicitServerNeverReceivesOurPassword() throws {
        let invocation = try plan(["auth", "list", "--server", "http://example.internal:4096"],
                                  caller: ["PATH": "/usr/bin", "OPENCODE_PASSWORD": "theirs"], connection: running).get()
        #expect(invocation.arguments == ["auth", "list", "--server", "http://example.internal:4096"])
        #expect(invocation.environment["OPENCODE_PASSWORD"] == "theirs")
    }

    // MARK: Connection file

    @Test func connectionFileIsPrivateAndChecked() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directories.connectionFile
        try runningFile.write(to: file)
        var info = stat()
        #expect(stat(file.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(stat(directories.runDirectory.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(try CLIConnectionFile.read(from: file) == runningFile)

        chmod(file.path, 0o644)
        #expect(throws: CLIConnectionFile.ReadError.self) { try CLIConnectionFile.read(from: file) }
        chmod(file.path, 0o600)

        // A dead pid: stale. Removal only for the matching pid.
        var stale = runningFile
        stale.pid = 999_999
        try stale.write(to: file)
        #expect(throws: CLIConnectionFile.ReadError.stale(pid: 999_999)) { try CLIConnectionFile.read(from: file) }
        CLIConnectionFile.remove(at: file, ifPID: 12)
        #expect(FileManager.default.fileExists(atPath: file.path))
        CLIConnectionFile.remove(at: file, ifPID: 999_999)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(throws: CLIConnectionFile.ReadError.missing) { try CLIConnectionFile.read(from: file) }
    }

    // MARK: Trust file

    @Test func trustFileRoundTripAndContainment() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let trust = ProjectTrustFile(trusted: ["/Users/me/Repos/b", "/Users/me/Repos/a", "/Users/me/Repos/a"])
        #expect(trust.trusted == ["/Users/me/Repos/a", "/Users/me/Repos/b"])
        try trust.write(to: directories.trustFile)
        let read = ProjectTrustFile.read(from: directories.trustFile)
        #expect(read == trust)
        #expect(read.isTrusted("/Users/me/Repos/a"))
        #expect(read.isTrusted("/Users/me/Repos/a/packages/web"))
        #expect(!read.isTrusted("/Users/me/Repos/ab"))
        #expect(!read.isTrusted("/Users/me/Repos"))
        #expect(ProjectTrustFile.read(from: root.appending(path: "missing.json")).trusted.isEmpty)
    }

    // MARK: Global folder

    @Test func templatesAreCreatedOnceAndNeverOverwrite() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = GlobalConfigFolder(directories: directories)
        #expect(folder.url == root.appending(path: "config/opencode", directoryHint: .isDirectory))
        let (config, created) = try folder.ensure(.config)
        #expect(created)
        #expect(JSONCheck.syntaxError(in: try Data(contentsOf: config)) == nil)
        let (agents, agentsCreated) = try folder.ensure(.instructions)
        #expect(agentsCreated)
        #expect(try String(contentsOf: agents, encoding: .utf8) == GlobalConfigFolder.template(for: .instructions))

        try Data("my own instructions\n".utf8).write(to: agents)
        let again = try folder.ensure(.instructions)
        #expect(!again.created)
        #expect(try String(contentsOf: agents, encoding: .utf8) == "my own instructions\n")
        for kind in GlobalConfigFolder.Folder.allCases {
            var isDirectory: ObjCBool = false
            let url = try folder.ensure(kind)
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        }
    }

    @Test func jsoncCheckReportsPosition() {
        #expect(JSONCheck.syntaxError(in: Data("{ // comment\n \"a\": [1, 2,], /* block */ \"b\": \"//not\",\n}".utf8)) == nil)
        let broken = JSONCheck.syntaxError(in: Data("{\n  \"agents\": { broken\n}".utf8))
        #expect(broken?.hasPrefix("opencode.json, line 2") == true)
        #expect(JSONCheck.syntaxError(in: Data("[1]".utf8))?.contains("JSON object") == true)
        #expect(JSONCheck.syntaxError(in: Data("  ".utf8))?.contains("empty") == true)
    }

    // MARK: Server environment

    @Test func repositoryConfigPolicyDrivesTheServerEnvironment() throws {
        var configuration = ServerConfiguration(
            executableURL: opencode, dataRoot: root, pluginDirectory: URL(fileURLWithPath: "/tmp/plugin", isDirectory: true))
        configuration.extraEnvironment = ["OPENCODE_DISABLE_PROJECT_CONFIG": "0"]
        var env = configuration.environment(credentials: ServerCredentials(password: "p"))
        #expect(env["OPENCODE_DISABLE_PROJECT_CONFIG"] == "1")
        let content = try #require(env["OPENCODE_CONFIG_CONTENT"])
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
        let projectConfig = parsed["plugins"]?[0]?["options"]?["projectConfig"]
        #expect(projectConfig?["mode"]?.stringValue == "bellocode")
        #expect(projectConfig?["trustFile"]?.stringValue == root.appending(path: "bellocode-trust.json").path)

        configuration.repositoryConfig = .native
        configuration.extraEnvironment = ["OPENCODE_DISABLE_PROJECT_CONFIG": "1"]
        env = configuration.environment(credentials: ServerCredentials(password: "p"))
        #expect(env["OPENCODE_DISABLE_PROJECT_CONFIG"] == nil)
        let native = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(env["OPENCODE_CONFIG_CONTENT"]).utf8))
        #expect(native["plugins"]?[0]?["options"]?["projectConfig"]?["mode"]?.stringValue == "native")
    }
}
