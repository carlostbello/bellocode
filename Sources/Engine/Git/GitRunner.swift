import BelloCore
import ContainerKit
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
    /// HTTPS authentication to a GitLab instance failed; the sentence says why (never contains the token).
    case authenticationFailed(String)

    public var description: String {
        switch self {
        case .failed(let command, let status, let message): "git \(command) failed (\(status)): \(message)"
        case .timedOut(let command): "git \(command) timed out"
        case .outputTooLarge(let command): "git \(command) produced too much output"
        case .launchFailed(let reason): "git could not start: \(reason)"
        case .notARepository: "Not a git repository"
        case .authenticationFailed(let reason): "git authentication failed: \(reason)"
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
        case .authenticationFailed(let reason): reason
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
        case .authenticationFailed: "authentication failed"
        }
    }
}

/// Runs `git` as a child process off the main actor, always confined (`HostGit`, docs/features/containers.md "Host
/// git"): a sandbox lets git execute only itself (no fsmonitor, filters, diff drivers, hooks, helpers or pagers from a
/// repository's configuration), with no network except for fetch/push and writes only inside the repository; when the
/// sandbox is unavailable git is not run (`GitError.launchFailed`).
///
/// Both pipes are drained as data arrives (a full pipe never blocks the child), output is bounded, a timeout stops the
/// process, and cancelling the calling task terminates it. Git never prompts (`GIT_TERMINAL_PROMPT=0`), never takes
/// optional locks (`GIT_OPTIONAL_LOCKS=0`, so a status refresh does not contend with the user's own git), and quotes
/// no paths (`core.quotePath=false`; callers use `-z` where paths are parsed).
public struct GitRunner: Sendable {
    /// The caller's environment; `HostGit` keeps only an allowlist of it and adds the confinement settings.
    public var environment: [String: String]
    /// Extra places git may write besides the repository (a local remote in tests, a worktree parent).
    public var writableRoots: [String]
    /// Lets fetch/push use local-path remotes (`protocol.file`). Off in the app; tests use local bare repositories.
    public var allowsLocalRemotes: Bool
    public var defaultTimeout: Duration
    /// Default stdout limit (bytes).
    public var outputLimit: Int
    /// The app's GitLab credentials for HTTPS remotes (nil: git uses only the person's own helpers).
    public var credentials: GitCredentials?

    static let log = Logger(subsystem: "dev.bellocode.engine", category: "git")
    static let signposter = OSSignposter(subsystem: "dev.bellocode.engine", category: .pointsOfInterest)

    public init(
        environment: [String: String]? = nil, writableRoots: [String] = [], allowsLocalRemotes: Bool = false,
        defaultTimeout: Duration = .seconds(30), outputLimit: Int = 128 << 20
    ) {
        self.environment = environment ?? Self.defaultEnvironment()
        self.writableRoots = writableRoots
        self.allowsLocalRemotes = allowsLocalRemotes
        self.defaultTimeout = defaultTimeout
        self.outputLimit = outputLimit
    }

    /// The parent's HOME and identity, the SSH agent (passed to network operations only), plus non-interactive
    /// settings. `HostGit` fixes PATH, disables hooks and the rest (docs/features/containers.md).
    public static func defaultEnvironment() -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "SSH_AUTH_SOCK", "TMPDIR", "LANG", "DEVELOPER_DIR"] { environment[key] = parent[key] }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        return environment
    }

    /// The confined launch for `arguments` (nil when the sandbox or git is unavailable).
    func invocation(
        _ arguments: [String], in directory: String, writableRoots extra: [String], trusted: HostGit.TrustedConfiguration,
        credentials setup: GitCredentialSetup? = nil
    ) -> HostGit.Invocation? {
        var environment = environment
        if allowsLocalRemotes {
            let count = Int(environment["GIT_CONFIG_COUNT"] ?? "0") ?? 0
            environment["GIT_CONFIG_KEY_\(count)"] = "protocol.file.allow"
            environment["GIT_CONFIG_VALUE_\(count)"] = "always"
            environment["GIT_CONFIG_COUNT"] = String(count + 1)
        }
        return HostGit.invocation(
            arguments: arguments, directory: directory, mode: Self.mode(of: arguments), environment: environment,
            writableRoots: writableRoots + extra, trusted: trusted, credentials: setup)
    }

    /// Network for fetch/push/clone/ls-remote and remote updates; local for everything else.
    static func mode(of arguments: [String]) -> HostGit.Mode {
        guard let index = arguments.firstIndex(where: { !$0.hasPrefix("-") && !$0.contains("=") }) else { return .local }
        let subcommand = arguments[index]
        if subcommand == "remote" {
            let next = arguments.dropFirst(index + 1).first { !$0.hasPrefix("-") }
            return ["update", "prune", "show", "set-head"].contains(next ?? "") ? .network : .local
        }
        return HostGit.networkSubcommands.contains(subcommand) ? .network : .local
    }

    /// Runs git in `directory`. Throws `GitError.failed` for a non-zero exit unless `allowFailure`.
    @concurrent
    public func run(
        _ arguments: [String], in directory: String, input: Data? = nil, timeout: Duration? = nil, outputLimit: Int? = nil,
        allowFailure: Bool = false, writableRoots extra: [String] = []
    ) async throws -> GitOutput {
        try Task.checkCancellation()
        let name = arguments.first(where: { !$0.hasPrefix("-") && !$0.contains("=") }) ?? "git"
        let interval = Self.signposter.beginInterval("git", "\(name, privacy: .public)")
        defer { Self.signposter.endInterval("git", interval) }
        var trusted = HostGit.TrustedConfiguration()
        if Self.mode(of: arguments) == .network {
            // The user's own credential helpers and ssh command (never the repository's), read confined.
            if let query = invocation(HostGit.trustedQuery, in: directory, writableRoots: [], trusted: trusted),
               let output = try? await execute(
                URL(filePath: query.executable), query.arguments, environment: query.environment, in: directory, input: nil,
                timeout: .seconds(10), limit: 64 << 10, name: "config")
            {
                trusted = HostGit.parseTrusted(output.stdout)
            }
        }
        // The app's GitLab remotes in this repository (and URLs on the command line) authenticate with the token.
        var grant: GitCredentialBroker.Grant?
        var setup: GitCredentialSetup?
        if Self.mode(of: arguments) == .network, let credentials {
            let targets = await authenticationTargets(arguments, in: directory, broker: credentials.broker)
            if !targets.urls.isEmpty {
                let origins = Set(targets.urls.compactMap { url in
                    credentials.broker.instance(forURL: url).flatMap(GitCredentialBroker.Origin.init(instance:))
                })
                let granted = credentials.broker.grant(origins: origins)
                grant = granted
                setup = GitCredentialSetup(
                    helperPath: credentials.helperPath, socketPath: credentials.broker.socketPath, grant: granted.identifier,
                    urls: targets.urls, remoteNames: targets.remotes)
            }
        }
        defer { if let grant, let credentials { credentials.broker.revoke(grant) } }
        guard let launch = invocation(
            ["-c", "core.quotePath=false", "-c", "color.ui=false"] + arguments, in: directory, writableRoots: extra, trusted: trusted,
            credentials: setup)
        else { throw GitError.launchFailed("the git sandbox is unavailable") }
        let broker = credentials?.broker
        let boundGrant = grant
        let output = try await execute(
            URL(filePath: launch.executable), launch.arguments, environment: launch.environment, in: directory, input: input,
            timeout: timeout ?? defaultTimeout, limit: outputLimit ?? self.outputLimit, name: name,
            onLaunch: { pid in if let boundGrant { broker?.bind(boundGrant, pid: pid) } })
        if output.status != 0, let grant, let broker {
            let outcomes = broker.outcomes(grant)
            if outcomes.contains(.rejected) {
                throw GitError.authenticationFailed(
                    "GitLab rejected your token. It may have expired or lack the read_repository/write_repository scope; replace it in Settings ▸ GitLab.")
            }
            for case .refused(let reason) in outcomes {
                throw GitError.authenticationFailed("BelloCode did not send your GitLab token (\(reason)).")
            }
        }
        if output.status != 0, !allowFailure {
            if output.message.contains("not a git repository") { throw GitError.notARepository(directory) }
            throw GitError.failed(command: name, status: output.status, message: output.message)
        }
        return output
    }

    /// Runs another program (isolation probes, tests) with the same draining, limits, timeout and cancellation. A
    /// non-zero exit is returned, not thrown.
    @concurrent
    public func runProgram(
        _ program: URL, _ arguments: [String], in directory: String, environment extra: [String: String] = [:], timeout: Duration,
        outputLimit: Int = 4 << 20
    ) async throws -> GitOutput {
        var environment = environment
        environment["PATH"] = HostGit.fixedPath
        environment.merge(extra) { _, new in new }
        return try await execute(program, arguments, environment: environment, in: directory, input: nil, timeout: timeout, limit: outputLimit, name: program.lastPathComponent)
    }

    private func execute(
        _ executable: URL, _ arguments: [String], environment: [String: String], in directory: String, input: Data?, timeout: Duration, limit: Int,
        name: String, onLaunch: (@Sendable (pid_t) -> Void)? = nil
    ) async throws -> GitOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(filePath: directory, directoryHint: .isDirectory)
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        // Writing input to a git that already exited must fail with EPIPE, not deliver SIGPIPE to the process.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let collector = Collector(limit: limit)
        // The timeout sleeps on ContinuousClock (an uptime-clock `asyncAfter` may not fire while the process is idle).
        defer { collector.deadline.cancel() }

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
                onLaunch?(process.processIdentifier)
                collector.setProcess(process)
                if let input {
                    let writer = stdin.fileHandleForWriting
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? writer.write(contentsOf: input)
                        try? writer.close()
                    }
                }
                collector.deadline.schedule(after: timeout) {
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
        /// The run's timeout; cancelled when `execute` returns.
        let deadline = ContinuousDeadline()

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

/// The app's side of HTTPS authentication for host git: the broker and the helper's path (`bellocode-exec`).
public struct GitCredentials: Sendable {
    public var broker: GitCredentialBroker
    public var helperPath: String
    public init(broker: GitCredentialBroker, helperPath: String) {
        self.broker = broker
        self.helperPath = helperPath
    }
}

extension GitRunner {
    /// Remote URLs (fetch and push, from the repository's configuration) and URL arguments that are on a configured
    /// GitLab instance over HTTPS, with the names of those remotes. Read confined, without the network.
    func authenticationTargets(_ arguments: [String], in directory: String, broker: GitCredentialBroker) async -> (urls: [String], remotes: [String]) {
        var urls: [String] = []
        var remotes: [String] = []
        for argument in arguments where argument.lowercased().hasPrefix("https://") && broker.instance(forURL: argument) != nil {
            urls.append(argument)
        }
        let query = ["config", "-z", "--get-regexp", #"^remote\..*\.(url|pushurl)$"#]
        if FileManager.default.fileExists(atPath: directory),
           let launch = invocation(query, in: directory, writableRoots: [], trusted: HostGit.TrustedConfiguration()),
           let output = try? await execute(
            URL(filePath: launch.executable), launch.arguments, environment: launch.environment, in: directory, input: nil,
            timeout: .seconds(10), limit: 256 << 10, name: "config"), output.status == 0
        {
            for entry in output.stdout.split(separator: 0) {
                let text = String(decoding: entry, as: UTF8.self)
                guard let newline = text.firstIndex(of: "\n") else { continue }
                let key = text[..<newline]
                let url = String(text[text.index(after: newline)...])
                guard broker.instance(forURL: url) != nil, key.hasPrefix("remote.") else { continue }
                let name = key.dropFirst(7).split(separator: ".").dropLast().joined(separator: ".")
                urls.append(url)
                if !name.isEmpty { remotes.append(name) }
            }
        }
        var seen: Set<String> = []
        return (urls.filter { seen.insert($0).inserted }.prefix(16).map { $0 }, Array(Set(remotes)).sorted())
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
