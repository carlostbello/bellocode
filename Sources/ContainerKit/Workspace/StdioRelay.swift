import Foundation
import os

private let signposter = OSSignposter(subsystem: "app.bellocode.ContainerKit", category: "stdio")

/// `bellocode-exec --stdio`: a local MCP server (or any program that speaks over stdin/stdout) runs in the project's
/// workspace container, and its stdin and stdout are relayed as a raw byte stream. No TTY (bytes pass unchanged, no
/// line discipline or echo), no line buffering (each read is forwarded as soon as it arrives), end of input is passed on
/// as end of input, and the program's exit code becomes the helper's. Buffers are bounded: one input chunk is in flight
/// at a time (the next read waits for the write), and output is pulled from the exec's stream (64 chunks at most).
public enum StdioRelay {
    /// `$0` of the in-container wrapper: marks the exec as a relayed program (`ExecInspect.isRelayedProgram`).
    public static let processName = "bellocode-stdio"

    /// The most bytes read from the host's stdin per write into the exec.
    public static let chunkSize = 64 * 1024

    /// The in-container wrapper. The program runs in the background with the exec's real stdin (an asynchronous list
    /// in a non-interactive shell would otherwise get /dev/null, so the descriptor is duplicated first); the exec's
    /// process (session and group leader) records its PID under `token` so the host can signal the whole group
    /// (`ExecWrapper.killSession`), passes TERM/INT/HUP on to the program, and when the program ends stops whatever it
    /// left running in the group and exits with its status.
    public static func wrapper(token: String, _ argv: [String]) -> [String] {
        let script = """
        umask 022
        mkdir -p /tmp/.bellocode 2>/dev/null; echo $$ > /tmp/.bellocode/\(token).pid 2>/dev/null
        exec 3<&0
        "$@" <&3 3<&- &
        c=$!
        exec 3<&- 0</dev/null
        trap 'kill -TERM $c 2>/dev/null' TERM INT HUP
        wait $c; s=$?
        while kill -0 $c 2>/dev/null; do wait $c; s=$?; done
        trap '' TERM
        rm -f /tmp/.bellocode/\(token).pid
        kill -TERM -$$ 2>/dev/null
        exit $s
        """
        return ["/bin/sh", "-c", script, processName] + argv
    }

    /// Relays until the program's output ends, then returns its exit code.
    ///
    /// - Parameters:
    ///   - readInput: the next bytes of the host's stdin (at most `chunkSize`); empty means end of input. Called again
    ///     only after the previous bytes were written into the exec, so at most one chunk is buffered.
    ///   - writeOutput: writes one output chunk to the host's stdout or stderr (blocking until written).
    public static func run(session: any StdioSession, readInput: @escaping @Sendable () async throws -> Data,
                           writeOutput: @escaping @Sendable (OutputChunk) throws -> Void) async throws -> Int {
        let state = signposter.beginInterval("stdio.relay")
        defer { signposter.endInterval("stdio.relay", state) }
        // Input: pumped until end of input, a failed write (the program exited and the exec closed) or cancellation.
        let pump = Task {
            while !Task.isCancelled {
                let data: Data
                do { data = try await readInput() } catch { break }
                if data.isEmpty { break }
                do { try await session.write(data) } catch { return }
            }
            session.closeStdin()
        }
        defer { pump.cancel() }
        for try await chunk in session.output() {
            try writeOutput(chunk)
        }
        return try await session.exitCode()
    }
}

/// What `bellocode-exec` was asked to do, from its arguments.
public enum HelperInvocation: Sendable, Equatable {
    case version
    /// `-c <command>` (nil: an interactive shell).
    case command(String?)
    /// `--stdio [--project DIR] -- program args…`: a program relayed over stdin/stdout (local MCP servers).
    case stdio(project: String?, argv: [String])
    /// `--stdio --refuse NAME`: a local MCP server BelloCode cannot place in a project's container (configured for all
    /// projects); the helper explains and runs nothing.
    case refuse(name: String)
    /// `--stdio --mcp ID [--project DIR]`: a global image-based MCP server (Settings ▸ MCP Servers), run in its own
    /// container from its image with no project folder mounted; `--project` names the connection's project.
    case globalMCP(id: String, project: String?)
    /// `--service NAME [--project DIR]`: an interactive shell in one of the project's service containers.
    case service(project: String?, name: String)

    public struct ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// Accepts what opencode and shells pass for the command forms (`-l`, `-i`, `+o nomatch`, then `-c command`) and
    /// BelloCode's own `--stdio` and `--service` forms.
    public static func parse(_ arguments: [String]) throws(ParseError) -> HelperInvocation {
        var arguments = arguments
        if arguments.first == "--version" { return .version }
        if arguments.first == "--stdio" {
            arguments.removeFirst()
            var project: String?
            var mcp: String?
            while let first = arguments.first, first != "--" {
                switch first {
                case "--project":
                    guard arguments.count >= 2 else { throw ParseError(description: "--project needs a folder.") }
                    project = arguments[1]
                    arguments.removeFirst(2)
                case "--refuse":
                    guard arguments.count >= 2 else { throw ParseError(description: "--refuse needs a server name.") }
                    return .refuse(name: arguments[1])
                case "--mcp":
                    guard arguments.count >= 2, !arguments[1].isEmpty else { throw ParseError(description: "--mcp needs a server id.") }
                    mcp = arguments[1]
                    arguments.removeFirst(2)
                default:
                    throw ParseError(description: "unsupported --stdio option \(first); use --stdio [--project DIR] -- program args….")
                }
            }
            if let mcp {
                guard arguments.isEmpty else { throw ParseError(description: "--stdio --mcp takes no program: the image runs.") }
                return .globalMCP(id: mcp, project: project)
            }
            guard arguments.first == "--", arguments.count >= 2 else {
                throw ParseError(description: "--stdio needs a program after --.")
            }
            return .stdio(project: project, argv: Array(arguments.dropFirst()))
        }
        if arguments.first == "--service" {
            guard arguments.count >= 2 else { throw ParseError(description: "--service needs a service name.") }
            let name = arguments[1]
            arguments.removeFirst(2)
            var project: String?
            if arguments.first == "--project", arguments.count >= 2 {
                project = arguments[1]
                arguments.removeFirst(2)
            }
            guard arguments.isEmpty else { throw ParseError(description: "unsupported arguments after --service.") }
            return .service(project: project, name: name)
        }
        while let first = arguments.first, first == "-l" || first == "--login" || first == "-i" { arguments.removeFirst() }
        if arguments.count >= 2, arguments[0] == "+o" { arguments.removeFirst(2) }
        if arguments.first == "-c" {
            guard arguments.count >= 2 else { throw ParseError(description: "-c needs a command.") }
            return .command(arguments[1])
        }
        if !arguments.isEmpty {
            throw ParseError(description: "unsupported arguments; use -c <command> or no arguments for an interactive shell.")
        }
        return .command(nil)
    }

    /// The message a refused local MCP server reports (on stderr; opencode shows it as the server's failure).
    public static func refusalMessage(server name: String) -> String {
        "the MCP server “\(name)” is configured for all projects in BelloCode's opencode configuration with a command, so it has no container to run in, and it never runs on this Mac. Add it as a container image in Settings ▸ MCP Servers (it then runs in its own container), or to a project: Project Settings ▸ Environment ▸ MCP servers."
    }
}
