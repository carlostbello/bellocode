import ContainerKit
import Foundation
import os

/// What the supervisor needs from Docker (production: `DockerBrowserRuntime`; tests: a recording fake).
public protocol BrowserRuntime: Sendable {
    /// Makes sure the image exists (building it when its inputs changed); returns its tag.
    func prepareImage(progress: @escaping @Sendable (String) -> Void) async throws -> String
    /// Network, gateway and certificates for the egress `browser` scope; returns (network, proxy, certificate folder).
    func prepareNetwork() async throws -> BrowserNetworkPlacement
    /// Current container, if any.
    func inspect() async throws -> BrowserContainerState?
    /// Creates (replacing a container with another configuration) and starts the container.
    func createAndStart(_ spec: BrowserContainerSpec) async throws
    func start() async throws
    /// Orderly stop: Docker sends SIGTERM; the entrypoint asks Chromium to quit (SIGINT commits cookies) and waits.
    func stop(timeout: Int) async throws
    func remove() async throws
    func removeProfile() async throws
    func status() async throws -> BrowserRuntimeStatus?
    func setViewerPassword(_ password: String) async throws
    func seccompProfile() throws -> String
}

public struct BrowserNetworkPlacement: Sendable, Equatable {
    public var network: String?
    public var proxy: String?
    public var certificateDirectory: String?
    public init(network: String? = nil, proxy: String? = nil, certificateDirectory: String? = nil) {
        self.network = network
        self.proxy = proxy
        self.certificateDirectory = certificateDirectory
    }
}

public struct BrowserContainerState: Sendable, Equatable {
    public var running: Bool
    public var configHash: String?
    public var exitCode: Int?
    public init(running: Bool, configHash: String?, exitCode: Int?) {
        self.running = running
        self.configHash = configHash
        self.exitCode = exitCode
    }
}

/// Where the shared browser stands (shown in the Chrome panel, Settings ▸ Browser and the Containers view).
public enum BrowserPhase: Sendable, Equatable {
    case stopped
    case preparingImage(String)
    case starting
    case ready
    case stopping(String)
    /// Restarting after an unexpected exit (generation already advanced).
    case recovering(String)
    case failed(String)
    case sandboxUnavailable
    /// A stop was asked for but the container could not be confirmed stopped (the runtime request failed and it still
    /// runs, or its state could not be read). Monitoring continues; Stop retries; tabs are still valid (A19).
    case stopUnconfirmed(String)

    public var title: String {
        switch self {
        case .stopped: "Stopped"
        case .preparingImage: "Building image"
        case .starting: "Starting"
        case .ready: "Running"
        case .stopping: "Stopping"
        case .recovering: "Restarting"
        case .failed: "Failed"
        case .sandboxUnavailable: "Sandbox unavailable"
        case .stopUnconfirmed: "Stop not confirmed"
        }
    }

    public var isReady: Bool { self == .ready }
}

/// Supervises the one shared browser container (docs/features/shared-browser.md "Lifecycle and flush"):
/// - **lazy start**, single-flight: the first call or visible viewer starts it; everyone waits for the same start;
/// - **activity**: calls, visible viewers, handoffs and human control are counted; at zero an idle timer starts;
/// - **idle stop**, in a fixed order: close admission → wait for running calls to finish (bounded) → orderly stop
///   (Chromium quits with SIGINT, which commits the cookie store) → stopped. New calls during a stop wait for it and
///   start the browser again;
/// - **crash**: an exit nobody asked for advances the generation (every outstanding call fails "outcome unknown", every
///   thread is told), then restarts with capped backoff; five failures in five minutes stop retrying (circuit breaker);
/// - a sandbox failure (exit 78) is never retried: it needs a person.
public actor BrowserSupervisor {
    public struct Timing: Sendable {
        public var idle: Duration
        public var drainLimit: Duration = .seconds(30)
        public var pollInterval: Duration = .seconds(2)
        public var readyTimeout: Duration = .seconds(90)
        public var backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)]
        public var stopTimeoutSeconds = 30
        public init(idle: Duration) { self.idle = idle }
    }

    public enum Activity: String, Sendable, CaseIterable { case call, viewer, handoff, human }

    public typealias Observer = @Sendable (BrowserPhase, Int, BrowserRuntimeStatus?) -> Void
    public typealias RestartNotice = @Sendable (_ generation: Int, _ reason: String) -> Void

    private let runtime: any BrowserRuntime
    public private(set) var timing: Timing
    private var spec: (@Sendable (String, BrowserNetworkPlacement, String) -> BrowserContainerSpec)
    public private(set) var phase: BrowserPhase = .stopped
    public private(set) var generation = 0
    public private(set) var lastStatus: BrowserRuntimeStatus?
    private var starting: Task<Void, any Error>?
    private var stopping: Task<Void, Never>?
    private var activity: [Activity: Int] = [:]
    private var idleTask: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    /// The restart after a crash: owned here (not by the monitor), so a stop cancels and waits for it (N11).
    private var recovering: Task<Void, Never>?
    private var failures: [ContinuousClock.Instant] = []
    private var stopRequested = false
    private var admissionClosed = false
    private var drainWaiters: [(id: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var nextDrainID = 0
    private var observer: Observer?
    private var onRestart: RestartNotice?
    private var knownChromiumRestarts = 0
    private var viewerPassword: String
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Every step, in order (tests assert the flush ordering; never contains secrets).
    public private(set) var journal: [String] = []
    private static let log = Logger(subsystem: "app.bellocode", category: "shared-browser")

    public init(runtime: any BrowserRuntime, timing: Timing, viewerPassword: String = UUID().uuidString,
                spec: @escaping @Sendable (String, BrowserNetworkPlacement, String) -> BrowserContainerSpec,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.runtime = runtime
        self.timing = timing
        self.spec = spec
        self.viewerPassword = viewerPassword
        self.sleep = sleep
    }

    public func observe(_ observer: @escaping Observer, onRestart: @escaping RestartNotice) {
        self.observer = observer
        self.onRestart = onRestart
        observer(phase, generation, lastStatus)
    }

    public func setIdle(_ idle: Duration) {
        timing.idle = idle
        if total == 0 { armIdle() }
    }

    public func setSpecBuilder(_ builder: @escaping @Sendable (String, BrowserNetworkPlacement, String) -> BrowserContainerSpec) {
        spec = builder
    }

    public var password: String { viewerPassword }

    private func set(_ next: BrowserPhase) {
        phase = next
        observer?(phase, generation, lastStatus)
    }

    private func note(_ step: String) {
        journal.append(step)
        if journal.count > 200 { journal.removeFirst(journal.count - 200) }
    }

    // MARK: Activity

    private var total: Int { activity.values.reduce(0, +) }

    /// Counts one unit of activity; starts the browser when needed. Throws when it cannot start.
    public func begin(_ kind: Activity) async throws {
        activity[kind, default: 0] += 1
        idleTask?.cancel()
        idleTask = nil
        do {
            try await ensureRunning()
        } catch {
            end(kind)
            throw error
        }
    }

    public func end(_ kind: Activity) {
        guard let count = activity[kind], count > 0 else { return }
        activity[kind] = count - 1
        if kind == .call, (activity[.call] ?? 0) == 0 {
            let waiters = drainWaiters
            drainWaiters = []
            waiters.forEach { $0.continuation.resume() }
        }
        if total == 0 { armIdle() }
    }

    public func activityCounts() -> [Activity: Int] { activity }

    private func armIdle() {
        idleTask?.cancel()
        guard phase == .ready else { return }
        let idle = timing.idle
        let sleep = self.sleep
        idleTask = Task { [weak self] in
            do { try await sleep(idle) } catch { return }
            await self?.idleExpired()
        }
    }

    private func idleExpired() async {
        guard total == 0, phase == .ready else { return }
        note("idle")
        await stop(reason: "idle")
    }

    // MARK: Start

    public func ensureRunning() async throws {
        if let stopping { await stopping.value }
        // A restart after a crash is already under way: wait for it instead of starting a second one (N11).
        if let recovering { await recovering.value }
        if phase == .ready { return }
        if case .sandboxUnavailable = phase { throw BrowserStartError.sandboxUnavailable }
        if let starting { return try await starting.value }
        let task = Task { try await self.startNow() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func startNow() async throws {
        // A container whose stop was not confirmed is reconciled by this start (an unchanged running one is reused).
        monitor?.cancel()
        monitor = nil
        stopRequested = false
        admissionClosed = false
        set(.preparingImage("Checking the browser image"))
        note("prepare-image")
        var touchedContainer = false
        do {
            let tag = try await runtime.prepareImage { [weak self] line in Task { await self?.progress(line) } }
            set(.starting)
            note("prepare-network")
            let placement = try await runtime.prepareNetwork()
            let wanted = spec(tag, placement, try runtime.seccompProfile())
            let current = try await runtime.inspect()
            if let current, current.configHash == wanted.configHash {
                // A running container with this configuration (left by a previous launch) is adopted: from here on it
                // is this start's to stop if the start fails, exactly like one it started (AF23).
                touchedContainer = true
                if !current.running {
                    note("start")
                    try await runtime.start()
                } else {
                    note("adopt")
                }
            } else {
                note(current == nil ? "create" : "recreate")
                touchedContainer = true
                try await runtime.createAndStart(wanted)
            }
            try await waitReady()
            note("viewer-password")
            try await runtime.setViewerPassword(viewerPassword)
            // A Stop that arrived during the start wins: never publish Ready for a start that was cancelled (R23).
            if stopRequested || Task.isCancelled { throw CancellationError() }
            knownChromiumRestarts = lastStatus?.chromiumRestarts ?? 0
            set(.ready)
            note("ready")
            startMonitor()
            if total == 0 { armIdle() }
        } catch let error as BrowserStartError where error == .sandboxUnavailable {
            set(.sandboxUnavailable)
            throw error
        } catch {
            // Stop won: `stop` reconciles the container's actual state, whether this attempt started it or adopted one
            // already running, and stops it in order with its confirmation (AF23).
            if stopRequested {
                note("start-cancelled")
                throw error
            }
            // The container this attempt created, started or adopted is ours to stop: a failed start (readiness timeout,
            // viewer password) never leaves it running behind a Failed or Stopped phase (R23, AF23), and a stop that
            // cannot be confirmed is shown as such (A19).
            if touchedContainer {
                note("cleanup-stop")
                do { try await runtime.stop(timeout: timing.stopTimeoutSeconds) } catch _ {
                    note("cleanup-stop-error")
                    if await !confirmedStopped() {
                        set(.stopUnconfirmed("The shared Chrome did not start (\(Self.describe(error))) and BelloCode could not confirm it stopped. It may still be running; Stop again to retry."))
                        startStopConfirmation(reason: "it did not start")
                        throw error
                    }
                }
            }
            set(error is CancellationError ? .stopped : .failed(Self.describe(error)))
            throw error
        }
    }

    private func progress(_ line: String) {
        if case .preparingImage = phase { set(.preparingImage(line)) }
    }

    private func waitReady() async throws {
        let deadline = ContinuousClock.now + timing.readyTimeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let state = try await runtime.inspect(), !state.running {
                if state.exitCode == 78 { throw BrowserStartError.sandboxUnavailable }
                throw BrowserStartError.exited(state.exitCode ?? -1)
            }
            if let status = try? await runtime.status() {
                lastStatus = status
                if status.sandbox == "failed" { throw BrowserStartError.sandboxUnavailable }
                if status.isReady { return }
            }
            try await sleep(.milliseconds(150))
        }
        throw BrowserStartError.timedOut
    }

    // MARK: Stop (orderly, with the cookie flush)

    /// Idle stop, Settings, quit: close admission → drain running calls (bounded) → orderly stop (SIGINT to Chromium
    /// inside, cookies committed) → stopped.
    public func stop(reason: String) async {
        if let stopping { return await stopping.value }
        if let starting {
            // Stop during a start (image build, network, readiness): cancel it and wait until it has cleaned up the
            // container it touched, so Stop never returns while a start is still going (R23).
            stopRequested = true
            note("cancel-start")
            starting.cancel()
            _ = try? await starting.value
            // A cancelled start leaves its phase as it was: reconcile with the container's actual state. One already
            // running (adopted from a previous launch, or started by this attempt) gets the orderly stop below (AF23).
            switch phase {
            case .preparingImage, .starting:
                if await confirmedStopped() {
                    note("start-cancelled-stopped")
                    set(.stopped)
                    return
                }
                set(.starting)
            default:
                break
            }
        }
        if case .failed = phase {
            // Failed is not proof of stopped (a recovery whose cleanup stop failed, a container started behind
            // BelloCode's back): only a container verifiably not running is Stopped; otherwise the orderly stop below
            // runs, with its confirmation (AF23).
            if await confirmedStopped() {
                note("failed-stopped")
                set(.stopped)
                return
            }
            note("failed-still-running")
        } else if !(phase == .ready || phase == .starting || phase.isRecovering || phase.isStopUnconfirmed) {
            return
        }
        let task = Task { await self.stopNow(reason: reason) }
        stopping = task
        await task.value
        stopping = nil
    }

    private func stopNow(reason: String) async {
        stopRequested = true
        admissionClosed = true
        monitor?.cancel()
        monitor = nil
        idleTask?.cancel()
        idleTask = nil
        // A restart after a crash is cancelled and waited for: it must not publish Ready after this stop (N11).
        if let recovering {
            note("cancel-recovery")
            recovering.cancel()
            await recovering.value
            self.recovering = nil
        }
        set(.stopping(reason))
        note("close-admission")
        if (activity[.call] ?? 0) > 0 {
            note("drain")
            // Both waiters end on cancellation, so the drain limit is honoured even while a call runs for minutes (R23).
            let limit = timing.drainLimit
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.waitForDrain() }
                group.addTask { try? await self.sleep(limit) }
                await group.next()
                group.cancelAll()
            }
            if (activity[.call] ?? 0) > 0 { note("drain-timeout") }
        }
        note("orderly-stop")
        var stopError: (any Error)?
        do { try await runtime.stop(timeout: timing.stopTimeoutSeconds) } catch {
            note("stop-error")
            stopError = error
        }
        // A failed request is not a stop: reconcile with the container's actual state (A19).
        if let stopError, await !confirmedStopped() {
            note("stop-unconfirmed")
            admissionClosed = false
            set(.stopUnconfirmed("BelloCode could not confirm the shared Chrome stopped (\(Self.describe(stopError))). It may still be running; Stop again to retry."))
            startStopConfirmation(reason: reason)
            return
        }
        finishStop(reason: reason)
    }

    /// Whether the container is verifiably not running (absent or exited). Unknown counts as not confirmed.
    private func confirmedStopped() async -> Bool {
        do {
            // Gone counts as stopped.
            guard let state = try await runtime.inspect() else { return true }
            return !state.running
        } catch {
            // The inspection itself failed: unknown.
            return false
        }
    }

    private func finishStop(reason: String) {
        // Tabs do not survive a browser stop (sign-ins do): handles from before are stale for every thread.
        advanceGeneration(reason: reason == "idle"
            ? "The shared Chrome was stopped after being idle; its tabs were closed (sign-ins are kept)."
            : "The shared Chrome was stopped (\(reason)); its tabs were closed (sign-ins are kept).")
        note("stopped")
        admissionClosed = false
        set(.stopped)
    }

    /// Keeps watching a container whose stop was not confirmed: once it is seen stopped, the stop completes.
    private func startStopConfirmation(reason: String) {
        monitor?.cancel()
        let interval = timing.pollInterval
        let sleep = self.sleep
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard let self else { return }
                if await self.checkStopConfirmed(reason: reason) { return }
            }
        }
    }

    private func checkStopConfirmed(reason: String) async -> Bool {
        guard phase.isStopUnconfirmed else { return true }
        guard await confirmedStopped() else { return false }
        note("stop-confirmed")
        monitor = nil
        finishStop(reason: reason)
        return true
    }

    /// Returns when no call is running, or as soon as the waiting task is cancelled.
    private func waitForDrain() async {
        nextDrainID += 1
        let id = nextDrainID
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if (activity[.call] ?? 0) == 0 || Task.isCancelled { continuation.resume() } else { drainWaiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelDrainWaiter(id) }
        }
    }

    private func cancelDrainWaiter(_ id: Int) {
        guard let index = drainWaiters.firstIndex(where: { $0.id == id }) else { return }
        drainWaiters.remove(at: index).continuation.resume()
    }

    public var isAdmitting: Bool { !admissionClosed }

    /// Restart from Settings or the Containers view: orderly stop, then start.
    public func restart() async throws {
        await stop(reason: "restart")
        try await ensureRunning()
    }

    /// Clear cookies and site data: orderly stop, remove the container and the profile volume, start fresh.
    public func clearProfile() async throws {
        await stop(reason: "clear data")
        note("remove-container")
        try? await runtime.remove()
        note("remove-profile")
        try await runtime.removeProfile()
        advanceGeneration(reason: "Its cookies and site data were cleared, so every site is signed out.")
    }

    /// The image must be rebuilt (Settings ▸ Rebuild Image): stop, remove the container; the next start builds.
    public func dropContainer() async {
        await stop(reason: "rebuild")
        try? await runtime.remove()
    }

    // MARK: Crash detection

    private func startMonitor() {
        monitor?.cancel()
        let interval = timing.pollInterval
        let sleep = self.sleep
        monitor = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                ticks += 1
                guard let self else { return }
                if await !self.check(fullStatus: ticks % 5 == 0) { return }
            }
        }
    }

    /// One monitor tick; false ends the loop.
    private func check(fullStatus: Bool) async -> Bool {
        guard phase == .ready, !stopRequested else { return false }
        let state = try? await runtime.inspect()
        if state?.running != true {
            guard phase == .ready, !stopRequested else { return false }
            monitor = nil
            let exit = state?.exitCode
            recovering = Task { await self.crashed(exit: exit) }
            return false
        }
        if fullStatus, let status = try? await runtime.status() {
            lastStatus = status
            if status.chromiumRestarts > knownChromiumRestarts {
                knownChromiumRestarts = status.chromiumRestarts
                advanceGeneration(reason: "Chrome itself restarted inside the container (it exited unexpectedly), so its tabs were closed.")
            }
            observer?(phase, generation, lastStatus)
        }
        return true
    }

    private func advanceGeneration(reason: String) {
        generation += 1
        note("generation \(generation)")
        onRestart?(generation, reason)
        observer?(phase, generation, lastStatus)
    }

    /// Runs as `recovering`: a stop cancels it and waits, and it re-checks for a stop after every suspension.
    private func crashed(exit: Int?) async {
        defer { recovering = nil }
        if exit == 78 {
            set(.sandboxUnavailable)
            advanceGeneration(reason: "Chromium's sandbox became unavailable, so the browser stopped.")
            return
        }
        let reason = "The shared Chrome stopped unexpectedly (exit \(exit.map(String.init) ?? "unknown")) and is restarting; its tabs were closed and calls in progress may or may not have taken effect."
        advanceGeneration(reason: reason)
        let now = ContinuousClock.now
        failures = failures.filter { now - $0 < .seconds(300) } + [now]
        guard failures.count <= timing.backoff.count else {
            set(.failed("The shared Chrome keeps stopping (\(failures.count) times in 5 minutes). Restart it from Settings ▸ Browser after checking its logs."))
            return
        }
        let delay = timing.backoff[min(failures.count - 1, timing.backoff.count - 1)]
        set(.recovering("restarting in \(delay.components.seconds) s"))
        note("backoff")
        do { try await sleep(delay) } catch { return }
        guard !stopRequested, !Task.isCancelled else { return }
        var touched = false
        do {
            note("restart")
            touched = true
            try await runtime.start()
            try await waitReady()
            try await runtime.setViewerPassword(viewerPassword)
            // A stop that arrived while restarting wins: never publish Ready after it (N11).
            if stopRequested || Task.isCancelled { throw CancellationError() }
            knownChromiumRestarts = lastStatus?.chromiumRestarts ?? 0
            set(.ready)
            startMonitor()
            if total == 0 { armIdle() }
        } catch {
            // The restarted container is ours: never leave it running behind Failed or a stop (R23, N11).
            if touched { try? await runtime.stop(timeout: timing.stopTimeoutSeconds) }
            if error is CancellationError || stopRequested || Task.isCancelled {
                note("recovery-cancelled")
            } else {
                set(.failed(Self.describe(error)))
            }
        }
    }

    /// Used by the broker's restart notices and tests: refreshes the status now.
    public func refreshStatus() async -> BrowserRuntimeStatus? {
        guard phase == .ready, let status = try? await runtime.status() else { return lastStatus }
        lastStatus = status
        observer?(phase, generation, lastStatus)
        return status
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? BrowserStartError { return error.description }
        return String(describing: error)
    }
}

extension BrowserPhase {
    var isRecovering: Bool { if case .recovering = self { true } else { false } }
    public var isStopUnconfirmed: Bool { if case .stopUnconfirmed = self { true } else { false } }
}

public enum BrowserStartError: Error, Sendable, Equatable, CustomStringConvertible {
    case sandboxUnavailable
    case exited(Int)
    case timedOut
    case unavailable(String)

    public var description: String {
        switch self {
        case .sandboxUnavailable:
            "Chromium's sandbox is unavailable in this container runtime (user namespaces are refused), so BelloCode will not start the shared Chrome without it."
        case .exited(let code): "The shared Chrome exited while starting (exit \(code)). See its logs in Window ▸ Containers."
        case .timedOut: "The shared Chrome did not become ready within 90 seconds."
        case .unavailable(let message): message
        }
    }
}
