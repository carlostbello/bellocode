// bellocode-exec: the "shell" BelloCode configures opencode with (agent shell tool, `/api/shell`, `!`cmd`` in command
// templates, schedule conditions, terminals). It never runs anything on the Mac. It forwards the command
// (`-c <command>`) or an interactive shell (no arguments, stdin a terminal) into the project's workspace container
// through the Docker Engine API on Rancher Desktop's socket, relays output, stdin, window size and signals, and exits
// with the command's exit code.
//
// Exit codes of its own: 125 = the runtime or container is unavailable (the message says what to do), 126 = the
// directory is not in a containerised project or the helper is not configured. Messages go to stderr, start with
// "BelloCode:", end with "The command was not run.", and never include the command, its output or the environment.
//
// It never sets or forwards BUN_BE_BUN (or any BUN_* variable): the bundled opencode binary would run JavaScript on
// the host with it.

import ContainerKit
import Darwin
import Dispatch
import Foundation

let helperVersion = "bellocode-exec 1.0"

// `--git-credential <operation>`: BelloCode's git credential helper for its own git processes (GitCredentialHelper).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == GitCredentialHelper.modeArgument {
    GitCredentialHelper.main(arguments: Array(CommandLine.arguments.dropFirst(2)), environment: ProcessInfo.processInfo.environment)
}

// Invoked as `git` (the shim first on the server's PATH): opencode's own host git runs confined (HostGit), never
// unconfined and never in the container (its snapshots live outside the mounts).
if (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent }) == "git" {
    HostGit.shimMain(arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment)
}

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data("BelloCode: \(message) The command was not run.\n".utf8))
    exit(code)
}

let invocation: HelperInvocation
do {
    invocation = try HelperInvocation.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail(2, error.description)
}
if invocation == .version {
    print(helperVersion)
    exit(0)
}
if case .refuse(let name) = invocation { fail(125, HelperInvocation.refusalMessage(server: name)) }
/// `-c` command, interactive shell, or a program relayed over stdin/stdout (`--stdio`, local MCP servers).
let command: String? = if case .command(let value) = invocation { value } else { nil }
let stdioArgv: [String]? = if case .stdio(_, let argv) = invocation { argv } else { nil }
let serviceName: String? = if case .service(_, let name) = invocation { name } else { nil }
let projectOption: String? = switch invocation {
case .stdio(let project, _), .service(let project, _): project
default: nil
}

let environment = ProcessInfo.processInfo.environment
guard let configPath = environment["BELLOCODE_EXEC_CONFIG"] else {
    fail(126, "commands run only in a project's container, and this one is not configured (BELLOCODE_EXEC_CONFIG). Nothing runs on this Mac instead.")
}

/// Reads the configuration and the app's requirement. The app writes the requirement first, then the configuration:
/// a reader between the two sees a newer requirement and waits briefly (at most ~2 s) for the configuration; a failed
/// or missing write means refusal (fail closed), never a command run under an older policy (S4).
func loadAuthorisedConfig() -> ExecHelperConfig {
    let requirementURL = ExecHelperConfig.Requirement.url(forConfig: URL(filePath: configPath))
    var refusal = "commands run only in a project's container, and this one is not configured (BELLOCODE_EXEC_CONFIG). Nothing runs on this Mac instead."
    var code: Int32 = 126
    for attempt in 0..<20 {
        if attempt > 0 { usleep(100_000) }
        let requirement = FileManager.default.contents(atPath: requirementURL.path)
            .flatMap { try? JSONDecoder().decode(ExecHelperConfig.Requirement.self, from: $0) }
        let config = FileManager.default.contents(atPath: configPath).flatMap { try? JSONDecoder().decode(ExecHelperConfig.self, from: $0) }
        if let config {
            guard let message = config.refusal(requirement: requirement) else { return config }
            refusal = message
            code = 125
        }
        // Waiting helps only while the app is between writing a requirement and its configuration; without a
        // requirement nothing is on its way: refuse at once.
        if requirement == nil { break }
    }
    fail(code, refusal)
}
let config = loadAuthorisedConfig()
let hostDirectory = FileManager.default.currentDirectoryPath
if let blocked = config.runtimeBlocked { fail(125, blocked.message) }
if case .globalMCP(let id, let project) = invocation {
    await runGlobalMCP(id: id, project: project, config: config, environment: environment, hostDirectory: hostDirectory)
}
/// The project comes from `--project` when given (a local MCP server BelloCode routed: its working directory may be
/// anywhere opencode chose); the command runs in the current directory when that is inside the project, else at the
/// project's root.
func resolveWorkspace() -> (ExecHelperConfig.Workspace, String)? {
    guard let projectOption else { return config.resolve(directory: hostDirectory) }
    guard let (workspace, root) = config.resolve(directory: projectOption) else { return nil }
    if let (current, directory) = config.resolve(directory: hostDirectory), current.container == workspace.container { return (current, directory) }
    return (workspace, root)
}
guard let (workspace, cwd) = resolveWorkspace() else {
    fail(126, "\(projectOption ?? hostDirectory) is not inside a project with a container environment, so there is nowhere to run this. Open the folder as a BelloCode project, or run the command from the project folder.")
}
if let blocked = workspace.blocked { fail(125, blocked.message) }

// "Host shell, docker only": one plain docker command runs on the Mac, by absolute path, with BelloCode's filtered
// endpoint; anything else is refused (HostDockerCommand). The helper replaces itself with docker (no shell).
if workspace.mode == .hostDocker {
    guard let docker = workspace.docker, let binary = docker.binary, binary.hasPrefix("/"),
          FileManager.default.isExecutableFile(atPath: binary) else {
        fail(125, "this project runs in “Host shell, docker only” mode, but Rancher Desktop's docker (~/.rd/bin/docker) or BelloCode's filtered Docker endpoint is not available. Start Rancher Desktop, or switch the project to the shared workspace.")
    }
    let hostArgv: [String]
    do {
        if let command {
            hostArgv = try HostDockerCommand.argv(for: command, docker: binary, roots: workspace.roots, cwd: hostDirectory)
        } else if let stdioArgv, let program = stdioArgv.first, program == "docker" || program == binary {
            try HostDockerCommand.check(arguments: Array(stdioArgv.dropFirst()), roots: workspace.roots, cwd: hostDirectory)
            hostArgv = [binary] + stdioArgv.dropFirst()
        } else if let stdioArgv {
            throw HostDockerCommand.Refusal.notDocker(stdioArgv.first ?? "")
        } else if serviceName != nil {
            fail(126, "service shells are not available in “Host shell, docker only” mode. Use docker compose exec SERVICE sh, or switch the project to the shared workspace.")
        } else {
            fail(126, "terminals are not available in “Host shell, docker only” mode (a shell on this Mac is not allowed). Run docker commands one at a time, or switch the project to the shared workspace in Project Settings ▸ Environment.")
        }
    } catch let refusal as HostDockerCommand.Refusal {
        fail(126, refusal.description)
    } catch {
        fail(126, "the command could not be checked.")
    }
    var hostEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": environment["LANG"] ?? "en_US.UTF-8"]
    if let term = environment["TERM"] { hostEnvironment["TERM"] = term }
    hostEnvironment.merge(docker.environment) { _, new in new }
    // The client runs confined to the project's folders and the endpoint (N03, A06): whatever a Compose file or an
    // option names, it cannot read or write elsewhere on this Mac. No sandbox, no command.
    let paths = HostDockerSandbox.Paths(readWrite: workspace.roots,
                                        readOnly: HostDockerSandbox.installationFolders(docker: binary, configDirectory: docker.configDirectory))
    guard let port = HostDockerSandbox.port(dockerHost: docker.host),
          let confined = HostDockerSandbox.wrap(hostArgv, paths: paths, port: port) else {
        fail(126, HostDockerCommand.Refusal.unconfined.description)
    }
    let cArgs = confined.map { strdup($0) } + [nil]
    let cEnv = hostEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    execve(HostDockerSandbox.sandboxExec, cArgs, cEnv)
    fail(125, "could not start docker (\(String(cString: strerror(errno)))).")
}

// `--service NAME`: an interactive shell in one of the project's service containers (as the image's user), never the
// workspace's; only services the app lists for the project.
if let serviceName, !(workspace.services ?? []).contains(serviceName) {
    fail(126, "this project has no service named “\(serviceName)”. Services are listed in Project Settings ▸ Environment ▸ Services.")
}
let targetContainer = serviceName.map {
    ServiceLabels.containerName(projectKey: WorkspaceSpec.projectKey(for: workspace.roots.first ?? ""), service: $0)
} ?? workspace.container
let targetUser: String? = serviceName == nil ? workspace.user : nil
let targetDirectory: String? = serviceName == nil ? cwd : nil

let client = EngineClient(socketPath: config.socket)
// A relayed program is never given a terminal, whatever stdin is: its bytes must pass unchanged.
let interactive = stdioArgv == nil && isatty(STDIN_FILENO) == 1
let forwarded = ExecHelperConfig.forwardedEnvironment(environment).merging(workspace.docker?.environment ?? [:]) { _, new in new }
let token = UUID().uuidString.prefix(12).lowercased()

func windowSize() -> (rows: Int, cols: Int)? {
    var size = winsize()
    guard ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0 else { return nil }
    return (Int(size.ws_row), Int(size.ws_col))
}

let serviceShell = ["/bin/sh", "-c", "if command -v bash >/dev/null 2>&1; then exec bash -l; else exec sh -l; fi"]
let argv = stdioArgv ?? (serviceName != nil ? serviceShell : nil) ?? command.map { [workspace.shell, "-c", $0] } ?? [workspace.shell, "-l"]
let wrapped = stdioArgv != nil ? StdioRelay.wrapper(token: String(token), argv)
    : interactive ? ExecWrapper.interactive(token: String(token), argv) : ExecWrapper.nonInteractive(argv)

func startSession() async throws -> ExecSession {
    try await ExecSession.start(client: client, container: targetContainer, argv: wrapped, workingDir: targetDirectory,
                                environment: forwarded, user: targetUser, tty: interactive,
                                size: interactive ? windowSize() : nil)
}

/// Creates or starts the container on first use (or after an idle stop, or when the project folder was replaced),
/// then starts the command. Never pulls: a missing image is the app's to fetch, with progress and credentials.
func ensureAndStart() async throws -> ExecSession {
    if let serviceName {
        fail(125, "the service “\(serviceName)” is not running. It starts with the project's container; check Project Settings ▸ Environment ▸ Services.")
    }
    guard let spec = workspace.spec else { throw ContainerError.notFound(workspace.container) }
    _ = try await WorkspaceManager(client: client).ensureRunning(spec, pull: false)
    return try await startSession()
}

let session: ExecSession
do {
    // The project folder was replaced (deleted and re-cloned) since the container was created: its bind mount pins the
    // old directory, so let ensureRunning recreate the container before running anything.
    let replaced = serviceName == nil && (workspace.spec.map { spec in workspace.mountIdentity.map { $0 != spec.mountIdentity() } ?? false } ?? false)
    if replaced {
        session = try await ensureAndStart()
    } else {
        do {
            session = try await startSession()
        } catch ContainerError.notFound, ContainerError.conflict {
            // Not created yet, or stopped when idle.
            session = try await ensureAndStart()
        }
    }
} catch let error as SocketError where error.isConnectionRefusedOrMissing {
    fail(125, RuntimeState.notRunning(socketPath: config.socket).userMessage)
} catch ContainerError.unreachable, ContainerError.timedOut {
    fail(125, RuntimeState.notRunning(socketPath: config.socket).userMessage)
} catch let error as WorkspaceError {
    fail(125, error.description)
} catch {
    fail(125, "could not start the command in the project's container (\(ContainerError.from(error).description)). Retry; if it persists, open Project Settings ▸ Environment.")
}

// Terminal state (interactive only): raw mode while we relay, restored on every exit path.
let savedTermios: termios? = {
    var value = termios()
    guard interactive, tcgetattr(STDIN_FILENO, &value) == 0 else { return nil }
    var raw = value
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    return value
}()
@Sendable func restoreTerminal() {
    if var saved = savedTermios { tcsetattr(STDIN_FILENO, TCSANOW, &saved) }
}

// Signals: a cancelled or timed-out command gets SIGTERM from opencode's process daemon (SIGKILL 3 s later).
// Main queue: these handlers touch main-actor state; Swift 6 traps if they run elsewhere.
let signalQueue = DispatchQueue.main
var sources: [any DispatchSourceSignal] = []
signal(SIGPIPE, SIG_IGN)
for sig in [SIGTERM, SIGINT, SIGHUP, SIGWINCH] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    source.setEventHandler {
        if sig == SIGWINCH {
            if let size = windowSize() { Task { try? await session.resize(rows: size.rows, cols: size.cols) } }
            return
        }
        if stdioArgv != nil {
            // A relayed program (MCP server): end its input, then signal its whole group in the container (TERM, then
            // KILL a second later), then leave. The wrapper also passes the TERM to the program.
            session.closeStdin()
            Task {
                _ = try? await ExecSession.run(client: client, container: targetContainer,
                                               argv: ExecWrapper.killSession(token: String(token), signal: "TERM"), user: targetUser,
                                               wrap: false, timeout: .seconds(5))
                exit(128 + sig)
            }
            signalQueue.asyncAfter(wallDeadline: .now() + 6) { exit(128 + sig) }
        } else if interactive {
            // Hang up the whole session in the container, then leave.
            Task {
                _ = try? await ExecSession.run(client: client, container: targetContainer,
                                               argv: ExecWrapper.killSession(token: String(token)), user: targetUser, wrap: false,
                                               timeout: .seconds(5))
                restoreTerminal()
                exit(128 + sig)
            }
        } else {
            // End of stdin makes the in-container wrapper kill the command's process group (TERM, then KILL).
            session.closeStdin()
            // Wall deadline: an uptime-clock `asyncAfter(deadline:)` may not fire while the process is idle (macOS 27).
            signalQueue.asyncAfter(wallDeadline: .now() + 4) { exit(128 + sig) }
        }
    }
    source.resume()
    sources.append(source)
}

if interactive {
    let input = FileStream(fd: STDIN_FILENO, owned: false, isSocket: false)
    Task {
        while let data = try? await input.read(maxLength: 16 * 1024), !data.isEmpty {
            if (try? await session.write(data)) == nil { break }
        }
    }
}

let stdoutStream = FileStream(fd: STDOUT_FILENO, owned: false, isSocket: false)
let stderrStream = FileStream(fd: STDERR_FILENO, owned: false, isSocket: false)
if stdioArgv != nil {
    let input = FileStream(fd: STDIN_FILENO, owned: false, isSocket: false)
    let code: Int
    do {
        code = try await StdioRelay.run(
            session: session, readInput: { try await input.read(maxLength: StdioRelay.chunkSize) },
            writeOutput: { chunk in
                switch chunk.stream {
                case .stderr, .system: try stderrStream.writeAllBlocking(chunk.bytes)
                default: try stdoutStream.writeAllBlocking(chunk.bytes)
                }
            })
    } catch {
        // The reader went away (stdout closed) or the connection to the container dropped: stop the program there.
        _ = try? await ExecSession.run(client: client, container: targetContainer,
                                       argv: ExecWrapper.killSession(token: String(token), signal: "TERM"), user: targetUser,
                                       wrap: false, timeout: .seconds(5))
        FileHandle.standardError.write(Data("BelloCode: the relayed program's stream ended unexpectedly; it was stopped in the container.\n".utf8))
        exit(125)
    }
    exit(Int32(truncatingIfNeeded: code < 0 ? 125 : code))
}
do {
    for try await chunk in session.output() {
        switch chunk.stream {
        case .stderr, .system: try stderrStream.writeAllBlocking(chunk.bytes)
        default: try stdoutStream.writeAllBlocking(chunk.bytes)
        }
    }
} catch {
    restoreTerminal()
    FileHandle.standardError.write(Data("BelloCode: lost the connection to the project's container; the command may have stopped.\n".utf8))
    exit(125)
}
let code = (try? await session.exitCode()) ?? 125
restoreTerminal()
if interactive {
    _ = try? await ExecSession.run(client: client, container: targetContainer, argv: ["rm", "-f", "/tmp/.bellocode/\(token).pid"],
                                   user: targetUser, wrap: false, timeout: .seconds(5))
}
exit(Int32(truncatingIfNeeded: code < 0 ? 125 : code))
