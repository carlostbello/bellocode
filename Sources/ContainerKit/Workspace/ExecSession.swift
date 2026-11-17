import Foundation
import os

private let signposter = OSSignposter(subsystem: "app.bellocode.ContainerKit", category: "exec")

/// In-container wrappers. Both are POSIX `sh`, so any image with `/bin/sh` works.
public enum ExecWrapper {
    /// Non-interactive commands. The command runs in the exec's own session (Docker makes the exec process a session
    /// and group leader), with stdin from /dev/null. A watcher holds the exec's real stdin: when BelloCode closes it
    /// (cancel, timeout) or the connection drops (the forwarding helper was killed), the watcher sends SIGTERM to the
    /// whole process group, then SIGKILL two seconds later, so a cancelled command leaves nothing behind. Like opencode's
    /// own spawner, what a finished command left running in its group (`cmd &`) is stopped when it exits. The watcher's
    /// output goes to /dev/null: Docker keeps an exec's stream open while anything holds its stdout.
    public static func nonInteractive(_ argv: [String]) -> [String] {
        let script = """
        umask 022
        exec 3<&0 </dev/null
        ( trap '' TERM INT HUP; while IFS= read -r _ <&3; do :; done; kill -TERM -$$ 2>/dev/null; sleep 2; kill -KILL -$$ 2>/dev/null ) >/dev/null 2>&1 &
        w=$!
        "$@" &
        c=$!
        wait $c; s=$?
        kill -KILL $w 2>/dev/null
        trap '' TERM
        kill -TERM -$$ 2>/dev/null
        exit $s
        """
        return ["/bin/sh", "-c", script, "bellocode-exec"] + argv
    }

    /// Interactive (TTY) sessions: record the session leader's PID under a token so a hang-up on the host can signal
    /// the whole session (`killSession`), then become the requested program.
    public static func interactive(token: String, _ argv: [String]) -> [String] {
        let script = "umask 022; mkdir -p /tmp/.bellocode 2>/dev/null; echo $$ > /tmp/.bellocode/\(token).pid 2>/dev/null; exec \"$@\""
        return ["/bin/sh", "-c", script, "bellocode-exec"] + argv
    }

    public static func killSession(token: String, signal: String = "HUP") -> [String] {
        ["/bin/sh", "-c", "f=/tmp/.bellocode/\(token).pid; [ -f $f ] && kill -\(signal) -- -$(cat $f) 2>/dev/null; sleep 1; [ -f $f ] && kill -KILL -- -$(cat $f) 2>/dev/null; rm -f $f"]
    }
}

/// One process running in a workspace container through `POST /exec`.
public final class ExecSession: Sendable {
    public let client: EngineClient
    public let execID: String
    public let tty: Bool
    public let connection: HTTPConnection

    init(client: EngineClient, execID: String, tty: Bool, connection: HTTPConnection) {
        self.client = client
        self.execID = execID
        self.tty = tty
        self.connection = connection
    }

    /// Creates and starts the exec. stdin is always attached: it carries keystrokes in TTY mode and the cancel signal in
    /// non-TTY mode (see `ExecWrapper`).
    public static func start(client: EngineClient, container: String, argv: [String], workingDir: String?,
                             environment: [String: String], user: String? = nil, tty: Bool,
                             size: (rows: Int, cols: Int)? = nil) async throws -> ExecSession {
        let state = signposter.beginInterval("exec.start")
        defer { signposter.endInterval("exec.start", state) }
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let config = ExecConfig(cmd: argv, env: env.isEmpty ? nil : env, workingDir: workingDir, user: user, tty: tty,
                                attachStdin: true, consoleSize: tty ? size : nil)
        let id = try await client.createExec(container, config)
        let connection = try await client.startExec(id, tty: tty, consoleSize: tty ? size : nil)
        return ExecSession(client: client, execID: id, tty: tty, connection: connection)
    }

    /// Output in arrival order: raw bytes as `.stdout` in TTY mode, demultiplexed otherwise. Pull-driven.
    public func output() -> AsyncThrowingStream<OutputChunk, any Error> {
        let connection = connection
        return EngineClient.outputStream(tty: tty, next: {
            let data = try await connection.readRaw()
            return data.isEmpty ? nil : data
        }, cancel: {})
    }

    public func write(_ data: Data) async throws { try await connection.write(data) }

    /// End of input. In non-TTY mode this cancels the command (the wrapper kills its process group).
    public func closeStdin() { connection.closeWrite() }

    public func resize(rows: Int, cols: Int) async throws {
        try await client.resizeExec(execID, rows: rows, cols: cols)
    }

    /// Exit code after the output ended. The daemon can report `Running` for a moment after the stream closes.
    public func exitCode() async throws -> Int {
        for attempt in 0..<200 {
            let inspect = try await client.inspectExec(execID)
            if !inspect.running { return inspect.exitCode ?? -1 }
            try await Task.sleep(for: .milliseconds(attempt < 20 ? 2 : 20))
        }
        return -1
    }

    public func close() { connection.cancel() }

    /// Runs a non-interactive command to completion, keeping at most `limit` bytes of each stream (the tail).
    public static func run(client: EngineClient, container: String, argv: [String], workingDir: String? = nil,
                           environment: [String: String] = [:], user: String? = nil, wrap: Bool = true,
                           limit: Int = 1 << 20) async throws -> (exitCode: Int, stdout: Data, stderr: Data) {
        let session = try await start(client: client, container: container, argv: wrap ? ExecWrapper.nonInteractive(argv) : argv,
                                      workingDir: workingDir, environment: environment, user: user, tty: false)
        defer { session.close() }
        var out = Data(), err = Data()
        for try await chunk in session.output() {
            switch chunk.stream {
            case .stderr, .system: err.append(chunk.bytes); if err.count > limit { err = err.suffix(limit) }
            default: out.append(chunk.bytes); if out.count > limit { out = out.suffix(limit) }
            }
        }
        return (try await session.exitCode(), out, err)
    }
}
