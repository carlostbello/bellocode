import Darwin
import Foundation

/// The supervisor's observable state.
public enum ServerState: Sendable, Hashable, CustomStringConvertible {
    case stopped
    /// Launching attempt `attempt` (1 after a healthy run) and waiting for the ready line and identity check.
    case starting(attempt: Int)
    /// The child is listening and verified to be the process we launched.
    case ready(ServerEndpoint)
    /// The child exited or failed to start; the next attempt begins after `delay`.
    case restarting(attempt: Int, delay: Duration, reason: String)
    /// Gave up after repeated failures, or the executable is unusable. `start()` tries again.
    case failed(reason: String)

    public var endpoint: ServerEndpoint? {
        if case .ready(let endpoint) = self { endpoint } else { nil }
    }

    /// Never includes credentials.
    public var description: String {
        switch self {
        case .stopped: "stopped"
        case .starting(let attempt): "starting (attempt \(attempt))"
        case .ready(let endpoint): "ready \(endpoint.baseURL.absoluteString) pid \(endpoint.pid) v\(endpoint.version)"
        case .restarting(let attempt, let delay, let reason): "restarting (attempt \(attempt) in \(delay)): \(reason)"
        case .failed(let reason): "failed: \(reason)"
        }
    }
}

public enum ServerSupervisorError: Error, Sendable, Hashable, CustomStringConvertible {
    case executableMissing(path: String)
    case exitedBeforeReady(ProcessExit?)
    case invalidReadyLine
    case notLoopback(host: String)
    case identityMismatch(childPID: Int32, reportedPID: Int)
    case versionMismatch(expected: String, reported: String)
    /// `awaitReady()` was called while stopped or failed.
    case notRunning(String)
    /// Another process holds the data root's lease (`OpenCodeDataLock`): a `bellocode-opencode` command running its own
    /// private server. The supervisor waits for it, without counting a failure.
    case dataInUse

    public var description: String {
        switch self {
        case .executableMissing(let path): "no executable opencode at \(path)"
        case .exitedBeforeReady(let exit): "server \(exit.map(\.description) ?? "closed stdout") before it was ready"
        case .invalidReadyLine: "server printed an unexpected ready line"
        case .notLoopback(let host): "server is not on loopback (\(host))"
        case .identityMismatch(let child, let reported): "server info reports pid \(reported), not our child \(child)"
        case .versionMismatch(let expected, let reported): "server version \(reported), expected \(expected)"
        case .notRunning(let state): "server is not running (\(state))"
        case .dataInUse: "waiting for a bellocode-opencode command that is using opencode's data to finish"
        }
    }
}

/// Owns the bundled `opencode serve --stdio --port 0` child.
///
/// - Launches with an explicit environment: isolated XDG and HOME directories, a random per-launch password, PATH
///   with the helpers directory first.
/// - Holds the child's stdin open as its lifetime lease (opencode exits when stdin closes, even if the app crashes).
/// - Reads the JSON ready line, then verifies identity: `GET /api/info` with Basic auth must report our child's pid.
/// - Drains stdout and stderr continuously into a bounded, password-redacted log.
/// - Restarts after a crash with capped, jittered backoff; gives up in `.failed` after repeated failures.
/// - `stop()` closes stdin, waits, then escalates to SIGTERM and SIGKILL, signalling only our own unexited child.
public actor ServerSupervisor {
    public nonisolated let configuration: ServerConfiguration

    public private(set) var state = ServerState.stopped

    private let launcher: any ServerProcessLauncher
    private let probe: any ServerInfoProbe
    private let time: any TimeSource
    private let random: RandomUnit

    private var runTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var stopping = false
    private var current: (any ServerProcess)?
    private var currentLog: BoundedLog?
    private var previousLog: BoundedLog?
    private var generation = 0
    private var observers: [UInt64: AsyncStream<ServerState>.Continuation] = [:]
    /// The data root's lease, held from before a launch until that child has exited (A13).
    private var dataLock: OpenCodeDataLock?
    /// Hands the current server's password to `bellocode-opencode` (A03); one per launch.
    private var passwordBroker: CLIPasswordBroker?
    private var nextObserverID: UInt64 = 0

    public init(
        configuration: ServerConfiguration,
        launcher: any ServerProcessLauncher = FoundationProcessLauncher(),
        probe: any ServerInfoProbe = HTTPServerInfoProbe(),
        time: any TimeSource = SystemTimeSource(),
        random: @escaping RandomUnit = systemRandomUnit
    ) {
        self.configuration = configuration
        self.launcher = launcher
        self.probe = probe
        self.time = time
        self.random = random
    }

    // MARK: - Public API

    /// Starts the server if it is stopped or failed. Idempotent.
    public func start() {
        guard runTask == nil, !stopping else { return }
        runTask = Task { await self.run() }
    }

    /// Stops the server and waits until the child has exited. Concurrent calls share one stop.
    public func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard runTask != nil || current != nil else {
            publish(.stopped)
            return
        }
        let task = Task { await self.performStop() }
        stopTask = task
        await task.value
        stopTask = nil
    }

    /// Stops the child (stdin lease, then signals) and starts a fresh one with a new password and the configuration's
    /// current launch values (`repositoryConfigProvider`, `launchEnvironment`). Clients reconnect and resync.
    public func restart() async {
        await stop()
        start()
    }

    /// State changes, starting with the current state. States are snapshots, so a consumer that falls more than 32
    /// changes behind sees the newest ones only.
    ///
    /// An observer is removed as soon as its stream terminates (the consumer stops iterating or drops it), not at the
    /// next state change, so waiting repeatedly while the state is stable does not accumulate observers.
    public func states() -> AsyncStream<ServerState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ServerState.self, bufferingPolicy: .bufferingNewest(32))
        nextObserverID += 1
        let id = nextObserverID
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        continuation.yield(state)
        return stream
    }

    private func removeObserver(_ id: UInt64) { observers[id] = nil }

    /// For tests and diagnostics: live `states()` streams.
    var observerCount: Int { observers.count }

    /// The verified endpoint. Waits while starting or restarting; throws if stopped or failed, or when cancelled.
    public func awaitReady() async throws -> ServerEndpoint {
        // Ready now: no subscription at all.
        if case .ready(let endpoint) = state { return endpoint }
        for await state in states() {
            switch state {
            case .ready(let endpoint): return endpoint
            case .stopped, .failed: throw ServerSupervisorError.notRunning(state.description)
            case .starting, .restarting: continue
            }
        }
        throw CancellationError()
    }

    /// The current endpoint, if ready.
    public var endpoint: ServerEndpoint? { state.endpoint }

    /// The pid of the running child, if any.
    public var childPID: Int32? { current?.pid }

    /// The current child's recent output (password redacted), or the previous child's if none is running.
    public func recentLog() -> [BoundedLog.Line] {
        (currentLog ?? previousLog)?.lines ?? []
    }

    // MARK: - Run loop

    private func run() async {
        var failures = 0
        while !Task.isCancelled, !stopping {
            publish(.starting(attempt: failures + 1))
            var reason: String
            var readyAt: Duration?
            do {
                (reason, readyAt) = try await runOnce()
            } catch is CancellationError {
                break
            } catch ServerSupervisorError.dataInUse {
                // Not a failure: a private CLI server is running on this data. Try again shortly.
                if stopping || Task.isCancelled { break }
                let delay = Duration.seconds(1)
                publish(.restarting(attempt: failures + 1, delay: delay, reason: ServerSupervisorError.dataInUse.description))
                do { try await time.sleep(for: delay) } catch { break }
                continue
            } catch let error as ServerSupervisorError {
                if case .executableMissing = error {
                    publish(.failed(reason: error.description))
                    break
                }
                reason = error.description
            } catch {
                reason = describeError(error)
            }
            if stopping || Task.isCancelled { break }

            if let readyAt, time.now() - readyAt >= configuration.healthyAfter { failures = 0 }
            failures += 1
            Instrumentation.serverLog.error("opencode server failure \(failures): \(reason, privacy: .public)")
            if failures >= configuration.maxConsecutiveFailures {
                publish(.failed(reason: reason))
                break
            }
            let delay = configuration.restartBackoff.delay(forAttempt: failures, random: random())
            publish(.restarting(attempt: failures, delay: delay, reason: reason))
            do { try await time.sleep(for: delay) } catch { break }
        }
        runTask = nil
    }

    /// Launches one child, verifies it, publishes `.ready`, and returns when it exits (reason, time it became ready).
    private func runOnce() async throws -> (String, Duration?) {
        let path = configuration.executableURL.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ServerSupervisorError.executableMissing(path: path)
        }
        try configuration.prepareDirectories()
        // One server per data root, whoever starts it: the app or a private `bellocode-opencode` server (A13).
        if configuration.publishesCLIConnection {
            // A lock that cannot be opened is a failure (counted, shown); a lock held by someone else is a wait. A few
            // short retries first: a process being spawned (here or by any library) briefly holds a copy of the lock's
            // descriptor until its exec closes it.
            var lock = try OpenCodeDataLock.tryAcquire(configuration.directories)
            for _ in 0..<25 where lock == nil {
                try await Task.sleep(for: .milliseconds(10))
                lock = try OpenCodeDataLock.tryAcquire(configuration.directories)
            }
            guard let lock else { throw ServerSupervisorError.dataInUse }
            dataLock = lock
        }
        defer {
            dataLock?.release()
            dataLock = nil
        }
        let credentials = ServerCredentials.random()
        let log = BoundedLog(redactions: [credentials.password])
        let spec = LaunchSpec(
            executableURL: configuration.executableURL,
            arguments: configuration.arguments,
            environment: configuration.environment(credentials: credentials),
            workingDirectory: configuration.dataRoot,
            log: log
        )

        let signpost = Instrumentation.server.beginInterval("start")
        let child = try await launcher.launch(spec)
        if let currentLog { previousLog = currentLog }
        current = child
        currentLog = log
        defer { current = nil }

        if stopping || Task.isCancelled {
            Instrumentation.server.endInterval("start", signpost)
            child.closeStdin()
            child.signal(SIGKILL)
            throw CancellationError()
        }

        let launchedAt = time.now()
        let connection: ServerConnection
        let info: ServerInfo
        do {
            (connection, info) = try await verify(child, credentials: credentials)
            Instrumentation.server.endInterval("start", signpost)
        } catch {
            Instrumentation.server.endInterval("start", signpost)
            // Never verified, or hung: it is our own child, so kill it outright.
            child.closeStdin()
            child.signal(SIGKILL)
            throw error
        }
        if stopping || Task.isCancelled { throw CancellationError() }

        generation += 1
        let endpoint = ServerEndpoint(connection: connection, info: info, generation: generation)
        let readyAt = time.now()
        Instrumentation.serverLog.info(
            "opencode ready pid \(info.pid, privacy: .public) in \((readyAt - launchedAt).milliseconds, privacy: .public) ms"
        )
        publishCLIConnection(endpoint: endpoint, credentials: credentials, pid: child.pid)
        publish(.ready(endpoint))

        let exit: ProcessExit
        do {
            exit = try await child.waitForExit()
        } catch {
            withdrawCLIConnection(pid: child.pid)
            throw error
        }
        withdrawCLIConnection(pid: child.pid)
        return ("server \(exit)", readyAt)
    }

    /// Reads the ready line and checks identity, racing the start timeout and the child's exit.
    private nonisolated func verify(
        _ child: any ServerProcess, credentials: ServerCredentials
    ) async throws -> (ServerConnection, ServerInfo) {
        let probe = self.probe
        let time = self.time
        let configuration = self.configuration
        return try await withThrowingTaskGroup(of: (ServerConnection, ServerInfo)?.self) { group in
            group.addTask {
                guard let line = try await child.readyLine() else {
                    throw ServerSupervisorError.exitedBeforeReady(child.exitStatus)
                }
                guard let ready = try? JSONDecoder().decode(ServerReadyLine.self, from: Data(line.utf8)) else {
                    throw ServerSupervisorError.invalidReadyLine
                }
                let host = ready.url.host() ?? ""
                guard ["127.0.0.1", "::1", "localhost"].contains(host) else {
                    throw ServerSupervisorError.notLoopback(host: host)
                }
                let connection = ServerConnection(baseURL: ready.url, credentials: credentials)
                let info = try await probe.info(for: connection)
                guard info.pid == Int(child.pid) else {
                    throw ServerSupervisorError.identityMismatch(childPID: child.pid, reportedPID: info.pid)
                }
                if let expected = configuration.expectedVersion, info.version != expected {
                    throw ServerSupervisorError.versionMismatch(expected: expected, reported: info.version)
                }
                return (connection, info)
            }
            group.addTask {
                let exit = try await child.waitForExit()
                throw ServerSupervisorError.exitedBeforeReady(exit)
            }
            group.addTask {
                try await time.sleep(for: configuration.startTimeout)
                throw TimeoutError(operation: "server start", limit: configuration.startTimeout)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next(), let result else { throw CancellationError() }
            return result
        }
    }

    // MARK: - Stopping

    private func performStop() async {
        stopping = true
        if let child = current {
            // `bellocode-opencode` must not reach a server that is going away (or fall back to a stale address).
            withdrawCLIConnection(pid: child.pid)
            await shutDown(child)
        }
        runTask?.cancel()
        await runTask?.value
        runTask = nil
        stopping = false
        publish(.stopped)
    }

    /// Closes the stdin lease, then escalates to SIGTERM and SIGKILL, each after the grace period.
    private func shutDown(_ child: any ServerProcess) async {
        let grace = configuration.stopGracePeriod
        child.closeStdin()
        if await waitForExit(child, within: grace) { return }
        Instrumentation.serverLog.error("opencode did not exit after closing stdin; sending SIGTERM")
        child.signal(SIGTERM)
        if await waitForExit(child, within: grace) { return }
        Instrumentation.serverLog.error("opencode did not exit after SIGTERM; sending SIGKILL")
        child.signal(SIGKILL)
        _ = await waitForExit(child, within: grace)
    }

    private func waitForExit(_ child: any ServerProcess, within limit: Duration) async -> Bool {
        if child.exitStatus != nil { return true }
        do {
            _ = try await withTimeout(limit, on: time, operation: "server exit") { try await child.waitForExit() }
            return true
        } catch {
            return false
        }
    }

    // MARK: - CLI connection (docs/features/opencode-config.md)

    /// Starts the password broker, then writes `run/server.json` (0600, no secret) so `bellocode-opencode` uses this
    /// server; failures only disable the CLI path.
    private func publishCLIConnection(endpoint: ServerEndpoint, credentials: ServerCredentials, pid: Int32) {
        guard configuration.publishesCLIConnection else { return }
        passwordBroker?.stop()
        passwordBroker = nil
        do {
            passwordBroker = try CLIPasswordBroker(
                directories: configuration.directories, pid: pid, password: credentials.password, allowedPeers: configuration.cliPeerExecutables)
            try CLIConnectionFile(url: endpoint.baseURL, pid: pid, version: endpoint.version).write(to: configuration.directories.connectionFile)
        } catch {
            Instrumentation.serverLog.error("could not publish the CLI connection: \(String(describing: error), privacy: .public)")
        }
    }

    private func withdrawCLIConnection(pid: Int32) {
        guard configuration.publishesCLIConnection else { return }
        CLIConnectionFile.remove(at: configuration.directories.connectionFile, ifPID: pid)
        passwordBroker?.stop()
        passwordBroker = nil
    }

    // MARK: - Observation

    private func publish(_ newState: ServerState) {
        guard newState != state else { return }
        state = newState
        Instrumentation.serverLog.info("opencode server \(newState.description, privacy: .public)")
        for (id, observer) in observers {
            if case .terminated = observer.yield(newState) { observers[id] = nil }
        }
    }
}
