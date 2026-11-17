// bellocode-exec: the "shell" BelloCode configures opencode with. It never runs anything on the Mac. It forwards the
// command (`-c <command>`) or an interactive shell (no arguments, stdin a terminal) into the project's workspace
// container through the Docker Engine API on Rancher Desktop's socket, relays output, stdin, window size and signals,
// and exits with the command's exit code.
//
// Exit codes of its own: 125 = the runtime or container is unavailable, 126 = the directory is not in a containerised
// project or the helper is not configured. Messages go to stderr and never include the command or its output.

import ContainerKit
import Darwin
import Dispatch
import Foundation

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data("bellocode-exec: \(message)\n".utf8))
    exit(code)
}

/// The command after `-c`, or nil for an interactive shell. Accepts what opencode and shells pass: `-l` (login),
/// `+o nomatch`, then `-c command`.
func parseCommand(_ all: [String]) -> String? {
    var arguments = Array(all.dropFirst())
    if arguments.first == "--version" {
        print("bellocode-exec 0.1 (G6 spike)")
        exit(0)
    }
    while let first = arguments.first, first == "-l" || first == "--login" || first == "-i" { arguments.removeFirst() }
    if arguments.count >= 2, arguments[0] == "+o" { arguments.removeFirst(2) }
    if arguments.first == "-c" {
        guard arguments.count >= 2 else { fail(2, "-c needs a command") }
        return arguments[1]
    }
    if !arguments.isEmpty { fail(2, "unsupported arguments; use -c <command> or no arguments for an interactive shell") }
    return nil
}
let command = parseCommand(CommandLine.arguments)

let environment = ProcessInfo.processInfo.environment
guard let configPath = environment["BELLOCODE_EXEC_CONFIG"], let configData = FileManager.default.contents(atPath: configPath),
      let config = try? JSONDecoder().decode(ExecHelperConfig.self, from: configData) else {
    fail(126, "not configured (BELLOCODE_EXEC_CONFIG); refusing to run anything on the host")
}
let cwd = FileManager.default.currentDirectoryPath
guard let workspace = config.workspace(for: cwd) else {
    fail(126, "\(cwd) is not inside a containerised project; refusing to run on the host")
}

let client = EngineClient(socketPath: config.socket)
let interactive = isatty(STDIN_FILENO) == 1
let forwarded = ExecHelperConfig.forwardedEnvironment(environment)
let token = UUID().uuidString.prefix(12).lowercased()

func windowSize() -> (rows: Int, cols: Int)? {
    var size = winsize()
    guard ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0 else { return nil }
    return (Int(size.ws_row), Int(size.ws_col))
}

func startSession() async throws -> ExecSession {
    let argv = command.map { [workspace.shell, "-c", $0] } ?? [workspace.shell, "-l"]
    let wrapped = interactive ? ExecWrapper.interactive(token: String(token), argv) : ExecWrapper.nonInteractive(argv)
    do {
        return try await ExecSession.start(client: client, container: workspace.container, argv: wrapped, workingDir: cwd,
                                           environment: forwarded, user: workspace.user, tty: interactive,
                                           size: interactive ? windowSize() : nil)
    } catch EngineError.conflict {
        // The container exists but is stopped (idle stop): start it and try once more.
        try await client.startContainer(workspace.container)
        return try await ExecSession.start(client: client, container: workspace.container, argv: wrapped, workingDir: cwd,
                                           environment: forwarded, user: workspace.user, tty: interactive,
                                           size: interactive ? windowSize() : nil)
    }
}

let session: ExecSession
do {
    session = try await startSession()
} catch let error as SocketError where error.isConnectionRefusedOrMissing {
    fail(125, "Rancher Desktop is not running (\(config.socket)); the command was not run")
} catch EngineError.notFound {
    fail(125, "the workspace container is missing; open the project in BelloCode to create it. The command was not run")
} catch {
    fail(125, "could not start the command in the container: \(error)")
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
                                               argv: ExecWrapper.killSession(token: String(token)), user: workspace.user, wrap: false)
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
    fail(125, "lost the connection to the container: \(error)")
}
let code = (try? await session.exitCode()) ?? 125
restoreTerminal()
if interactive {
    _ = try? await ExecSession.run(client: client, container: workspace.container, argv: ["rm", "-f", "/tmp/.bellocode/\(token).pid"],
                                   user: workspace.user, wrap: false)
}
exit(Int32(truncatingIfNeeded: code < 0 ? 125 : code))
