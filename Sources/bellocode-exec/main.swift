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

// Invoked as `git` (the shim first on the server's PATH): opencode's own host git runs confined (HostGit), never
// unconfined and never in the container (its snapshots live outside the mounts).
if (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent }) == "git" {
    HostGit.shimMain(arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment)
}

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data("BelloCode: \(message) The command was not run.\n".utf8))
    exit(code)
}

/// The command after `-c`, or nil for an interactive shell. Accepts what opencode and shells pass: `-l` (login),
/// `+o nomatch`, then `-c command`.
func parseCommand(_ all: [String]) -> String? {
    var arguments = Array(all.dropFirst())
    if arguments.first == "--version" {
        print(helperVersion)
        exit(0)
    }
    while let first = arguments.first, first == "-l" || first == "--login" || first == "-i" { arguments.removeFirst() }
    if arguments.count >= 2, arguments[0] == "+o" { arguments.removeFirst(2) }
    if arguments.first == "-c" {
        guard arguments.count >= 2 else { fail(2, "-c needs a command.") }
        return arguments[1]
    }
    if !arguments.isEmpty { fail(2, "unsupported arguments; use -c <command> or no arguments for an interactive shell.") }
    return nil
}
let command = parseCommand(CommandLine.arguments)

let environment = ProcessInfo.processInfo.environment
guard let configPath = environment["BELLOCODE_EXEC_CONFIG"], let configData = FileManager.default.contents(atPath: configPath),
      let config = try? JSONDecoder().decode(ExecHelperConfig.self, from: configData) else {
    fail(126, "commands run only in a project's container, and this one is not configured (BELLOCODE_EXEC_CONFIG). Nothing runs on this Mac instead.")
}
let hostDirectory = FileManager.default.currentDirectoryPath
if let blocked = config.runtimeBlocked { fail(125, blocked.message) }
guard let (workspace, cwd) = config.resolve(directory: hostDirectory) else {
    fail(126, "\(hostDirectory) is not inside a project with a container environment, so there is nowhere to run this. Open the folder as a BelloCode project, or run the command from the project folder.")
}
if let blocked = workspace.blocked { fail(125, blocked.message) }

let client = EngineClient(socketPath: config.socket)
let interactive = isatty(STDIN_FILENO) == 1
let forwarded = ExecHelperConfig.forwardedEnvironment(environment)
let token = UUID().uuidString.prefix(12).lowercased()

func windowSize() -> (rows: Int, cols: Int)? {
    var size = winsize()
    guard ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0 else { return nil }
    return (Int(size.ws_row), Int(size.ws_col))
}

let argv = command.map { [workspace.shell, "-c", $0] } ?? [workspace.shell, "-l"]
let wrapped = interactive ? ExecWrapper.interactive(token: String(token), argv) : ExecWrapper.nonInteractive(argv)

func startSession() async throws -> ExecSession {
    try await ExecSession.start(client: client, container: workspace.container, argv: wrapped, workingDir: cwd,
                                environment: forwarded, user: workspace.user, tty: interactive,
                                size: interactive ? windowSize() : nil)
}

/// Creates or starts the container on first use (or after an idle stop, or when the project folder was replaced),
/// then starts the command. Never pulls: a missing image is the app's to fetch, with progress and credentials.
func ensureAndStart() async throws -> ExecSession {
    guard let spec = workspace.spec else { throw ContainerError.notFound(workspace.container) }
    _ = try await WorkspaceManager(client: client).ensureRunning(spec, pull: false)
    return try await startSession()
}

let session: ExecSession
do {
    // The project folder was replaced (deleted and re-cloned) since the container was created: its bind mount pins the
    // old directory, so let ensureRunning recreate the container before running anything.
    let replaced = workspace.spec.map { spec in workspace.mountIdentity.map { $0 != spec.mountIdentity() } ?? false } ?? false
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
for sig in [SIGTERM, SIGINT, SIGHUP, SIGWINCH] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    source.setEventHandler {
        if sig == SIGWINCH {
            if let size = windowSize() { Task { try? await session.resize(rows: size.rows, cols: size.cols) } }
            return
        }
        if interactive {
            // Hang up the whole session in the container, then leave.
            Task {
                _ = try? await ExecSession.run(client: client, container: workspace.container,
                                               argv: ExecWrapper.killSession(token: String(token)), user: workspace.user, wrap: false,
                                               timeout: .seconds(5))
                restoreTerminal()
                exit(128 + sig)
            }
        } else {
            // End of stdin makes the in-container wrapper kill the command's process group (TERM, then KILL).
            session.closeStdin()
            signalQueue.asyncAfter(deadline: .now() + 4) { exit(128 + sig) }
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
    _ = try? await ExecSession.run(client: client, container: workspace.container, argv: ["rm", "-f", "/tmp/.bellocode/\(token).pid"],
                                   user: workspace.user, wrap: false, timeout: .seconds(5))
}
exit(Int32(truncatingIfNeeded: code < 0 ? 125 : code))
