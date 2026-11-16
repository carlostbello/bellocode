import Darwin
import Foundation
import Synchronization

/// What to launch: a fully explicit executable, arguments, environment and working directory.
public struct LaunchSpec: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    /// The complete child environment; nothing is inherited from the app.
    public var environment: [String: String]
    public var workingDirectory: URL
    /// Receives everything the child writes to stdout (after the ready line) and stderr.
    public var log: BoundedLog

    public init(
        executableURL: URL, arguments: [String], environment: [String: String], workingDirectory: URL, log: BoundedLog
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.log = log
    }
}

/// How a child ended.
public struct ProcessExit: Sendable, Hashable, CustomStringConvertible {
    public enum Reason: Sendable, Hashable { case exited, signaled }

    public var reason: Reason
    /// Exit status, or the signal number when `reason == .signaled`.
    public var status: Int32

    public init(reason: Reason, status: Int32) {
        self.reason = reason
        self.status = status
    }

    public var description: String {
        reason == .exited ? "exited with status \(status)" : "killed by signal \(status)"
    }
}

/// A launched child process, owned by whoever launched it.
public protocol ServerProcess: Sendable {
    var pid: Int32 { get }
    /// The first line the child writes to stdout, or nil if stdout closed first.
    func readyLine() async throws -> String?
    /// Waits for the child to exit.
    func waitForExit() async throws -> ProcessExit
    /// The exit, if the child has already exited.
    var exitStatus: ProcessExit? { get }
    /// Releases the stdin lease. `opencode serve --stdio` exits when its stdin closes.
    func closeStdin()
    /// Sends `signal` only if this child has not exited yet (so a recycled pid is never signalled).
    func signal(_ signal: Int32)
}

/// Starts server processes. Injected so the supervisor's state machine can be tested without real processes.
public protocol ServerProcessLauncher: Sendable {
    func launch(_ spec: LaunchSpec) async throws -> any ServerProcess
}

/// Launches children with Foundation's `Process`.
public struct FoundationProcessLauncher: ServerProcessLauncher {
    public init() {}

    public func launch(_ spec: LaunchSpec) async throws -> any ServerProcess {
        try FoundationServerProcess(spec)
    }
}

/// A `Process` child with all three pipes managed. stdout and stderr are drained continuously by pipe callbacks, so
/// the child can never block on a full pipe. stdin stays open (the lease) until `closeStdin()` or until this object and
/// the app go away.
final class FoundationServerProcess: ServerProcess {
    let pid: Int32
    private let process: Mutex<Process>
    private let stdin: FileHandle
    private let ready = OneShot<String?>()
    private let exit = OneShot<ProcessExit>()

    init(_ spec: LaunchSpec) throws {
        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = spec.workingDirectory

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let ready = self.ready
        let exit = self.exit
        let log = spec.log

        process.terminationHandler = { process in
            let reason: ProcessExit.Reason = process.terminationReason == .uncaughtSignal ? .signaled : .exited
            exit.fulfill(ProcessExit(reason: reason, status: process.terminationStatus))
        }
        let stdoutReader = StdoutReader(ready: ready, log: log)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutReader.close()
            } else {
                stdoutReader.consume(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                log.flush(.stderr)
            } else {
                log.append(data, from: .stderr)
            }
        }

        try process.run()
        // The parent's copies of the child's ends are no longer needed.
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        self.pid = process.processIdentifier
        self.stdin = stdinPipe.fileHandleForWriting
        self.process = Mutex(process)
    }

    func readyLine() async throws -> String? { try await ready.value() }

    func waitForExit() async throws -> ProcessExit { try await exit.value() }

    var exitStatus: ProcessExit? { exit.current }

    func closeStdin() {
        try? stdin.close()
    }

    func signal(_ signal: Int32) {
        // Holding the lock serialises with other signals; the exit check excludes a reaped (recyclable) pid.
        process.withLock { process in
            guard exit.current == nil, process.isRunning else { return }
            Darwin.kill(pid, signal)
        }
    }
}

/// Splits the child's stdout: the first line is the ready line, everything after it goes to the log.
private final class StdoutReader: Sendable {
    private struct State {
        var buffer: [UInt8] = []
        var sawFirstLine = false
    }

    private static let maxReadyLineBytes = 64 * 1024

    private let state = Mutex(State())
    private let ready: OneShot<String?>
    private let log: BoundedLog

    init(ready: OneShot<String?>, log: BoundedLog) {
        self.ready = ready
        self.log = log
    }

    func consume(_ data: Data) {
        let (line, rest): (String?, [UInt8]) = state.withLock { state in
            guard !state.sawFirstLine else { return (nil, Array(data)) }
            state.buffer.append(contentsOf: data)
            guard let newline = state.buffer.firstIndex(of: UInt8(ascii: "\n")) else {
                guard state.buffer.count > Self.maxReadyLineBytes else { return (nil, []) }
                // Not a ready line: give up on it; the supervisor rejects the empty line.
                state.sawFirstLine = true
                defer { state.buffer.removeAll() }
                return ("", state.buffer)
            }
            state.sawFirstLine = true
            let line = String(decoding: state.buffer[..<newline], as: UTF8.self)
            let rest = Array(state.buffer[(newline + 1)...])
            state.buffer.removeAll()
            return (line, rest)
        }
        if let line { ready.fulfill(line) }
        if !rest.isEmpty { log.append(rest, from: .stdout) }
    }

    func close() {
        log.flush(.stdout)
        ready.fulfill(nil)
    }
}
