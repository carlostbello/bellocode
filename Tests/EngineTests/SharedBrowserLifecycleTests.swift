import ContainerKit
import Foundation
import Synchronization
import Testing

@testable import Engine

/// A sleeper the test releases by hand (no wall-clock waits): `sleep` parks until `fire` or cancellation.
actor ManualSleeper {
    private var waiters: [(id: Int, duration: Duration, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextID = 0
    private(set) var history: [Duration] = []

    nonisolated func sleep(_ duration: Duration) async throws {
        let id = await register()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { await self.park(id, duration, continuation) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func register() -> Int {
        nextID += 1
        return nextID
    }

    private func park(_ id: Int, _ duration: Duration, _ continuation: CheckedContinuation<Void, any Error>) {
        history.append(duration)
        waiters.append((id, duration, continuation))
    }

    private func cancel(_ id: Int) {
        if let index = waiters.firstIndex(where: { $0.id == id }) { waiters.remove(at: index).continuation.resume(throwing: CancellationError()) }
    }

    func pending(_ duration: Duration? = nil) -> Int { waiters.filter { duration == nil || $0.duration == duration }.count }

    /// Resumes every sleeper of `duration` (all when nil).
    func fire(_ duration: Duration? = nil) {
        let matching = waiters.filter { duration == nil || $0.duration == duration }
        waiters.removeAll { entry in matching.contains { $0.id == entry.id } }
        for entry in matching { entry.continuation.resume() }
    }

    /// Waits (yielding, bounded by iterations, not time) until a sleeper of `duration` is parked.
    func waitFor(_ duration: Duration, count: Int = 1) async -> Bool {
        for _ in 0..<20_000 {
            if pending(duration) >= count { return true }
            await Task.yield()
        }
        return false
    }
}

extension ManualSleeper {
    nonisolated func waitUntil(_ duration: Duration, count: Int = 1) async -> Bool {
        for _ in 0..<20_000 {
            if await pending(duration) >= count { return true }
            await Task.yield()
        }
        return false
    }
}

/// A recording runtime: every Docker step is logged in order; state is scripted.
final class FakeBrowserRuntime: BrowserRuntime {
    struct State {
        var log: [String] = []
        var running = false
        var exists = false
        var configHash: String?
        var exitCode: Int?
        var statusReady = true
        var sandbox = "ok"
        var startExit: Int?
        var chromiumRestarts = 0
        var creates = 0
    }
    let state = Mutex(State())
    func log(_ entry: String) { state.withLock { $0.log.append(entry) } }
    var entries: [String] { state.withLock { $0.log } }

    func prepareImage(progress: @escaping @Sendable (String) -> Void) async throws -> String { log("image"); return "bellocode-browser:test" }
    func prepareNetwork() async throws -> BrowserNetworkPlacement { log("network"); return BrowserNetworkPlacement(network: "bellocode-egress-browser", proxy: "http://bellocode-proxy:3128") }
    func inspect() async throws -> BrowserContainerState? {
        state.withLock { $0.exists ? BrowserContainerState(running: $0.running, configHash: $0.configHash, exitCode: $0.exitCode) : nil }
    }
    func createAndStart(_ spec: BrowserContainerSpec) async throws {
        log("createAndStart")
        state.withLock {
            $0.creates += 1
            $0.exists = true
            $0.configHash = spec.configHash
            if let exit = $0.startExit { $0.running = false; $0.exitCode = exit } else { $0.running = true }
        }
    }
    func start() async throws {
        log("start")
        state.withLock { $0.running = true; $0.exitCode = nil }
    }
    func stop(timeout: Int) async throws {
        log("stop(\(timeout))")
        state.withLock { $0.running = false; $0.exitCode = 0 }
    }
    func remove() async throws { log("remove"); state.withLock { $0.exists = false; $0.running = false } }
    func removeProfile() async throws { log("removeProfile") }
    func status() async throws -> BrowserRuntimeStatus? {
        state.withLock {
            BrowserRuntimeStatus(sandbox: $0.sandbox, relay: $0.statusReady ? "up" : "down", extension: $0.statusReady ? "connected" : "disconnected",
                                 paired: $0.statusReady, chromiumRestarts: $0.chromiumRestarts)
        }
    }
    func setViewerPassword(_ password: String) async throws { log("viewer-password") }
    func seccompProfile() throws -> String { "{}" }
}

@Suite("Shared browser lifecycle", .timeLimit(.minutes(3)))
struct SharedBrowserLifecycleTests {
    func make(_ runtime: FakeBrowserRuntime, _ sleeper: ManualSleeper, idle: Duration = .seconds(600)) -> BrowserSupervisor {
        var timing = BrowserSupervisor.Timing(idle: idle)
        timing.drainLimit = .seconds(30)
        timing.pollInterval = .seconds(2)
        return BrowserSupervisor(runtime: runtime, timing: timing, viewerPassword: "pw", spec: { image, placement, seccomp in
            BrowserContainerSpec(image: image, seccompProfile: seccomp, network: placement.network, proxy: placement.proxy)
        }, sleep: { try await sleeper.sleep($0) })
    }

    @Test func lazyStartIsSingleFlight() async throws {
        let runtime = FakeBrowserRuntime()
        let sleeper = ManualSleeper()
        let supervisor = make(runtime, sleeper)
        #expect(await supervisor.phase == .stopped)
        #expect(runtime.entries.isEmpty, "nothing starts before first use")
        async let a: Void = supervisor.begin(.call)
        async let b: Void = supervisor.begin(.call)
        _ = try await (a, b)
        #expect(await supervisor.phase == .ready)
        #expect(runtime.state.withLock { $0.creates } == 1)
        #expect(runtime.entries == ["image", "network", "createAndStart", "viewer-password"])
        #expect(await supervisor.activityCounts()[.call] == 2)
    }

    @Test func idleStopRunsTheFlushInOrder() async throws {
        let runtime = FakeBrowserRuntime()
        let sleeper = ManualSleeper()
        let supervisor = make(runtime, sleeper, idle: .seconds(600))
        try await supervisor.begin(.call)
        await supervisor.end(.call)
        #expect(await sleeper.waitUntil(.seconds(600)), "idle timer armed at zero activity")
        await sleeper.fire(.seconds(600))
        for _ in 0..<20_000 where await supervisor.phase != .stopped { await Task.yield() }
        #expect(await supervisor.phase == .stopped)
        let journal = await supervisor.journal
        let tail = Array(journal.suffix(5))
        #expect(tail == ["idle", "close-admission", "orderly-stop", "generation 1", "stopped"], "\(journal)")
        #expect(runtime.entries.last == "stop(30)", "orderly stop with time for Chromium to commit cookies")
        #expect(!runtime.entries.contains("remove"), "an idle stop keeps the container and profile")
    }

    @Test func stopWaitsForRunningCallsBeforeStoppingChromium() async throws {
        let runtime = FakeBrowserRuntime()
        let sleeper = ManualSleeper()
        let supervisor = make(runtime, sleeper)
        try await supervisor.begin(.call)
        try await supervisor.begin(.call)
        let stopping = Task { await supervisor.stop(reason: "test") }
        // The drain is waiting: Chromium must not be stopped while calls run.
        for _ in 0..<20_000 where await !(supervisor.journal.contains("drain")) { await Task.yield() }
        #expect(await supervisor.journal.contains("drain"))
        #expect(!runtime.entries.contains("stop(30)"))
        #expect(await supervisor.isAdmitting == false, "admission closed first")
        await supervisor.end(.call)
        #expect(!runtime.entries.contains("stop(30)"))
        await supervisor.end(.call)
        await stopping.value
        let journal = await supervisor.journal
        #expect(journal.firstIndex(of: "close-admission")! < journal.firstIndex(of: "drain")!)
        #expect(journal.firstIndex(of: "drain")! < journal.firstIndex(of: "orderly-stop")!)
        #expect(runtime.entries.last == "stop(30)")
        #expect(await supervisor.phase == .stopped)
    }

    @Test func callDuringStopRestartsAfterIt() async throws {
        let runtime = FakeBrowserRuntime()
        let sleeper = ManualSleeper()
        let supervisor = make(runtime, sleeper)
        try await supervisor.begin(.call)
        await supervisor.end(.call)
        await supervisor.stop(reason: "test")
        try await supervisor.begin(.call)
        #expect(await supervisor.phase == .ready)
        #expect(runtime.entries.suffix(2) == ["start", "viewer-password"], "same configuration: started, not recreated")
    }

    @Test func viewerAndHumanControlKeepItAwake() async throws {
        let runtime = FakeBrowserRuntime()
        let sleeper = ManualSleeper()
        let supervisor = make(runtime, sleeper, idle: .seconds(600))
        try await supervisor.begin(.viewer)
        try await supervisor.begin(.call)
        await supervisor.end(.call)
        #expect(await sleeper.pending(.seconds(600)) == 0, "no idle timer while a viewer is visible")
        try await supervisor.begin(.human)
        await supervisor.end(.viewer)
        #expect(await sleeper.pending(.seconds(600)) == 0, "no idle timer while the person has control")
        await supervisor.end(.human)
        #expect(await sleeper.waitUntil(.seconds(600)))
    }

    @Test func crashAdvancesTheGenerationTellsEveryoneAndRestarts() async throws {
        let runtime = FakeBrowserRuntime()
        let sleeper = ManualSleeper()
        let supervisor = make(runtime, sleeper)
        let notices = Mutex<[String]>([])
        await supervisor.observe({ _, _, _ in }, onRestart: { generation, reason in notices.withLock { $0.append("\(generation): \(reason)") } })
        try await supervisor.begin(.call)
        runtime.state.withLock { $0.running = false; $0.exitCode = 137 }
        #expect(await sleeper.waitUntil(.seconds(2)))
        await sleeper.fire(.seconds(2))  // monitor tick sees the exit
        #expect(await sleeper.waitUntil(.seconds(1)), "first backoff")
        #expect(await supervisor.generation == 1)
        #expect(notices.withLock { $0.first?.contains("exit 137") == true })
        await sleeper.fire(.seconds(1))
        for _ in 0..<20_000 where await supervisor.phase != .ready { await Task.yield() }
        #expect(await supervisor.phase == .ready)
        #expect(runtime.entries.contains("start"))
    }

    @Test func chromiumRestartInsideTheContainerIsAGenerationToo() async throws {
        let runtime = FakeBrowserRuntime()
        let sleeper = ManualSleeper()
        let supervisor = make(runtime, sleeper)
        try await supervisor.begin(.call)
        runtime.state.withLock { $0.chromiumRestarts = 1 }
        for _ in 0..<5 {
            #expect(await sleeper.waitUntil(.seconds(2)))
            await sleeper.fire(.seconds(2))
        }
        for _ in 0..<20_000 where await supervisor.generation == 0 { await Task.yield() }
        #expect(await supervisor.generation == 1)
        #expect(await supervisor.phase == .ready)
    }

    @Test func sandboxFailureIsNeverRetried() async throws {
        let runtime = FakeBrowserRuntime()
        runtime.state.withLock { $0.startExit = 78 }
        let sleeper = ManualSleeper()
        let supervisor = make(runtime, sleeper)
        await #expect(throws: BrowserStartError.sandboxUnavailable) { try await supervisor.begin(.call) }
        #expect(await supervisor.phase == .sandboxUnavailable)
        await #expect(throws: BrowserStartError.sandboxUnavailable) { try await supervisor.begin(.call) }
        #expect(runtime.state.withLock { $0.creates } == 1)
        #expect(await supervisor.activityCounts()[.call] == 0)
    }

    @Test func clearingTheProfileStopsInOrderThenRemovesIt() async throws {
        let runtime = FakeBrowserRuntime()
        let sleeper = ManualSleeper()
        let supervisor = make(runtime, sleeper)
        try await supervisor.begin(.call)
        await supervisor.end(.call)
        try await supervisor.clearProfile()
        let entries = runtime.entries
        let stop = entries.firstIndex(of: "stop(30)")!
        #expect(stop < entries.firstIndex(of: "remove")!)
        #expect(entries.firstIndex(of: "remove")! < entries.firstIndex(of: "removeProfile")!)
        #expect(await supervisor.generation == 2, "the stop closed the tabs; clearing also tells threads their sign-ins are gone")
    }
}
