import Foundation
import Synchronization
import os

/// The result of one git invocation.
public struct GitOutput: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public var text: String { String(decoding: stdout, as: UTF8.self) }
    /// The first line of stderr, trimmed (git's own message; may name paths, so never log it publicly).
    public var message: String {
        String(decoding: stderr, as: UTF8.self).split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// Why a git command failed.
public enum GitError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Exited with a non-zero status. `message` is git's first stderr line (display only; never log it publicly).
    case failed(command: String, status: Int32, message: String)
    case timedOut(command: String)
    /// Output exceeded the caller's limit; the process was stopped.
    case outputTooLarge(command: String)
    case launchFailed(String)
    case notARepository(String)

    public var description: String {
        switch self {
        case .failed(let command, let status, let message): "git \(command) failed (\(status)): \(message)"
        case .timedOut(let command): "git \(command) timed out"
        case .outputTooLarge(let command): "git \(command) produced too much output"
        case .launchFailed(let reason): "git could not start: \(reason)"
        case .notARepository: "Not a git repository"
        }
    }

    /// A short sentence for the UI.
    public var userMessage: String {
        switch self {
        case .failed(_, _, let message): message.isEmpty ? "Git reported an error." : message
        case .timedOut: "Git took too long and was stopped."
        case .outputTooLarge: "The result is too large to show."
        case .launchFailed: "Git could not be started. Install the Command Line Tools."
        case .notARepository: "This folder is not a git repository."
        }
    }

    /// Only the subcommand and status: safe for public logs.
    public var logSummary: String {
        switch self {
        case .failed(let command, let status, _): "git \(command) exit \(status)"
        case .timedOut(let command): "git \(command) timeout"
        case .outputTooLarge(let command): "git \(command) output limit"
        case .launchFailed: "git launch failed"
        case .notARepository: "not a repository"
        }
    }
}

/// Runs `git` as a child process off the main actor.
///
/// Both pipes are drained as data arrives (a full pipe never blocks the child), output is bounded, a timeout stops the
/// process, and cancelling the calling task terminates it. Git never prompts (`GIT_TERMINAL_PROMPT=0`), never takes
/// optional locks (`GIT_OPTIONAL_LOCKS=0`, so a status refresh does not contend with the user's own git), and quotes
/// no paths (`core.quotePath=false`; callers use `-z` where paths are parsed).
public struct GitRunner: Sendable {
    public var executable: URL
    public var environment: [String: String]
    public var defaultTimeout: Duration
    /// Default stdout limit (bytes).
    public var outputLimit: Int

    static let log = Logger(subsystem: "dev.bellocode.engine", category: "git")
    static let signposter = OSSignposter(subsystem: "dev.bellocode.engine", category: .pointsOfInterest)

    public init(
        executable: URL = URL(filePath: "/usr/bin/git"), environment: [String: String]? = nil, defaultTimeout: Duration = .seconds(30),
        outputLimit: Int = 128 << 20
    ) {
        self.executable = executable
        self.environment = environment ?? Self.defaultEnvironment()
        self.defaultTimeout = defaultTimeout
        self.outputLimit = outputLimit
    }

    /// The parent's PATH, HOME and SSH agent (push needs them), plus non-interactive settings.
    public static func defaultEnvironment() -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["PATH", "HOME", "USER", "LOGNAME", "SSH_AUTH_SOCK", "TMPDIR", "LANG"] { environment[key] = parent[key] }
        environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["GIT_EDITOR"] = "true"
        environment["LC_ALL"] = "C"
        // Repository hooks (husky, pre-commit…) would run project code on the Mac: host git never runs them
        // (docs/features/containers.md). Commits that need hooks run git inside the project's container.
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = "core.hooksPath"
        environment["GIT_CONFIG_VALUE_0"] = "/dev/null"
        return environment
    }

    /// Runs git in `directory`. Throws `GitError.failed` for a non-zero exit unless `allowFailure`.
    @concurrent
    public func run(
        _ arguments: [String], in directory: String, input: Data? = nil, timeout: Duration? = nil, outputLimit: Int? = nil,
        allowFailure: Bool = false
    ) async throws -> GitOutput {
        try Task.checkCancellation()
        let name = arguments.first(where: { !$0.hasPrefix("-") && !$0.contains("=") }) ?? "git"
        let interval = Self.signposter.beginInterval("git", "\(name, privacy: .public)")
        defer { Self.signposter.endInterval("git", interval) }
        let output = try await execute(
            executable, ["-c", "core.quotePath=false", "-c", "color.ui=false"] + arguments, in: directory, input: input,
            timeout: timeout ?? defaultTimeout, limit: outputLimit ?? self.outputLimit, name: name)
        if output.status != 0, !allowFailure {
            if output.message.contains("not a git repository") { throw GitError.notARepository(directory) }
            throw GitError.failed(command: name, status: output.status, message: output.message)
        }
        return output
    }

    /// Runs another program (a setup script's shell) with the same draining, limits, timeout and cancellation. A
    /// non-zero exit is returned, not thrown.
    @concurrent
    public func runProgram(
        _ program: URL, _ arguments: [String], in directory: String, environment extra: [String: String] = [:], timeout: Duration,
        outputLimit: Int = 4 << 20
    ) async throws -> GitOutput {
        var runner = self
        runner.environment.merge(extra) { _, new in new }
        return try await runner.execute(program, arguments, in: directory, input: nil, timeout: timeout, limit: outputLimit, name: program.lastPathComponent)
    }

    private func execute(
        _ executable: URL, _ arguments: [String], in directory: String, input: Data?, timeout: Duration, limit: Int, name: String
    ) async throws -> GitOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(filePath: directory, directoryHint: .isDirectory)
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let collector = Collector(limit: limit)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitOutput, any Error>) in
                collector.setContinuation(continuation)
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if collector.append(data, toStdout: true) { process.terminate() }
                    if data.isEmpty { handle.readabilityHandler = nil }
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    _ = collector.append(data, toStdout: false)
                    if data.isEmpty { handle.readabilityHandler = nil }
                }
                process.terminationHandler = { process in collector.terminated(status: process.terminationStatus, name: name) }
                do {
                    try process.run()
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    collector.fail(GitError.launchFailed(String(describing: type(of: error))))
                    return
                }
                collector.setProcess(process)
                if let input {
                    let writer = stdin.fileHandleForWriting
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? writer.write(contentsOf: input)
                        try? writer.close()
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.seconds) {
                    if collector.markTimedOut() { process.terminate() }
                }
            }
        } onCancel: {
            collector.cancel()
        }
    }

    /// Accumulates output and resumes the continuation once stdout and stderr reached EOF and the process exited.
    private final class Collector: Sendable {
        struct State {
            var stdout = Data()
            var stderr = Data()
            var stdoutDone = false
            var stderrDone = false
            var status: Int32?
            var name = "git"
            var overflow = false
            var timedOut = false
            var cancelled = false
            var finished = false
            var continuation: CheckedContinuation<GitOutput, any Error>?
            var process: Process?
        }

        let limit: Int
        let state = Mutex(State())

        init(limit: Int) { self.limit = limit }

        func setContinuation(_ continuation: CheckedContinuation<GitOutput, any Error>) {
            state.withLock { $0.continuation = continuation }
        }

        func setProcess(_ process: Process) {
            let cancelled = state.withLock { state -> Bool in
                state.process = process
                return state.cancelled
            }
            if cancelled { process.terminate() }
        }

        /// Returns true when the process must be stopped (output limit).
        func append(_ data: Data, toStdout: Bool) -> Bool {
            let (stop, resume) = state.withLock { state -> (Bool, (CheckedContinuation<GitOutput, any Error>, Result<GitOutput, any Error>)?) in
                if toStdout {
                    if data.isEmpty { state.stdoutDone = true } else if !state.overflow {
                        state.stdout.append(data)
                        if state.stdout.count > limit {
                            state.overflow = true
                            state.stdout = Data()
                        }
                    }
                } else if data.isEmpty {
                    state.stderrDone = true
                } else if state.stderr.count < 64 << 10 {
                    state.stderr.append(data)
                }
                return (state.overflow && !data.isEmpty && toStdout, Self.completion(&state))
            }
            if let (continuation, result) = resume { continuation.resume(with: result) }
            return stop
        }

        func terminated(status: Int32, name: String) {
            let resume = state.withLock { state in
                state.status = status
                state.name = name
                return Self.completion(&state)
            }
            if let (continuation, result) = resume { continuation.resume(with: result) }
        }

        func fail(_ error: any Error) {
            let continuation = state.withLock { state -> CheckedContinuation<GitOutput, any Error>? in
                guard !state.finished else { return nil }
                state.finished = true
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(throwing: error)
        }

        func markTimedOut() -> Bool {
            state.withLock { state in
                guard !state.finished else { return false }
                state.timedOut = true
                return true
            }
        }

        func cancel() {
            let process = state.withLock { state -> Process? in
                state.cancelled = true
                return state.finished ? nil : state.process
            }
            process?.terminate()
        }

        private static func completion(_ state: inout State) -> (CheckedContinuation<GitOutput, any Error>, Result<GitOutput, any Error>)? {
            guard !state.finished, state.stdoutDone, state.stderrDone, let status = state.status, let continuation = state.continuation else {
                return nil
            }
            state.finished = true
            state.continuation = nil
            let result: Result<GitOutput, any Error>
            if state.cancelled {
                result = .failure(CancellationError())
            } else if state.timedOut {
                result = .failure(GitError.timedOut(command: state.name))
            } else if state.overflow {
                result = .failure(GitError.outputTooLarge(command: state.name))
            } else {
                result = .success(GitOutput(status: status, stdout: state.stdout, stderr: state.stderr))
            }
            return (continuation, result)
        }
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
