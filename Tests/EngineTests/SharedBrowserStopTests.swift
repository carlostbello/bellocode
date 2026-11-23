import ContainerKit
import Foundation
import Synchronization
import Testing

@testable import Engine

/// v1.0.0 reviews A19 and N11: a stop that cannot be confirmed is not shown as a stop, and a stop during crash
/// recovery wins over the restart.
@Suite("Shared browser stop and recovery", .timeLimit(.minutes(3)))
struct SharedBrowserStopTests {
    func make(_ runtime: FakeBrowserRuntime, _ sleeper: ManualSleeper) -> BrowserSupervisor {
        var timing = BrowserSupervisor.Timing(idle: .seconds(600))
        timing.pollInterval = .seconds(2)
        return BrowserSupervisor(runtime: runtime, timing: timing, viewerPassword: "pw", spec: { image, placement, seccomp in
            BrowserContainerSpec(image: image, seccompProfile: seccomp, network: placement.network, proxy: placement.proxy)
        }, sleep: { try await sleeper.sleep($0) })
    }

    /// A19: the runtime's stop fails while Chrome still runs: the phase says so, tabs stay valid, Stop retries, and
    /// monitoring completes the stop once the container is seen stopped.
    @Test func aFailedStopIsNotShownAsStopped() async throws {
        let runtime = FakeBrowserRuntime()
        let sleeper = ManualSleeper()
        let supervisor = make(runtime, sleeper)
        try await supervisor.begin(.call)
        await supervisor.end(.call)
        runtime.state.withLock { $0.stopFails = true }
        await supervisor.stop(reason: "test")
        #expect(await supervisor.phase.isStopUnconfirmed)
        #expect(await supervisor.generation == 0, "tabs were not closed")
        // Retry: still failing, still unconfirmed (the Stop guard admits it).
        await supervisor.stop(reason: "test")
        #expect(runtime.entries.filter { $0 == "stop(30)" }.count == 2)
        #expect(await supervisor.phase.isStopUnconfirmed)
        // The container stops on its own; the monitor sees it and completes the stop.
        runtime.state.withLock { $0.running = false; $0.exitCode = 0 }
        #expect(await sleeper.waitUntil(.seconds(2)))
        await sleeper.fire(.seconds(2))
        for _ in 0..<20_000 where await supervisor.phase != .stopped { await Task.yield() }
        #expect(await supervisor.phase == .stopped)
        #expect(await supervisor.generation == 1)
    }

    /// A19: a failed stop request whose container is in fact stopped is a stop.
    @Test func aFailedStopRequestOfAStoppedContainerIsAStop() async throws {
        let runtime = FakeBrowserRuntime()
        let sleeper = ManualSleeper()
        let supervisor = make(runtime, sleeper)
        try await supervisor.begin(.call)
        await supervisor.end(.call)
        runtime.state.withLock { $0.stopFails = true; $0.running = false }
        await supervisor.stop(reason: "test")
        #expect(await supervisor.phase == .stopped)
    }

    /// N11: Stop arrives while the crash recovery is restarting the container: the recovery is cancelled, stops the
    /// container it restarted, and never publishes Ready after Stop returned.
    @Test func aStopDuringCrashRecoveryWins() async throws {
        let startHold = ManualSleeper()
        let runtime = FakeBrowserRuntime(startHold: startHold)
        let sleeper = ManualSleeper()
        let supervisor = make(runtime, sleeper)
        try await supervisor.begin(.call)
        await supervisor.end(.call)
        runtime.state.withLock { $0.running = false; $0.exitCode = 137 }
        #expect(await sleeper.waitUntil(.seconds(2)))
        await sleeper.fire(.seconds(2))  // the monitor sees the exit
        #expect(await sleeper.waitUntil(.seconds(1)), "backoff")
        await sleeper.fire(.seconds(1))
        #expect(await startHold.waitUntil(.seconds(7_200)), "the restart is in progress")
        await supervisor.stop(reason: "BelloCode quit")
        #expect(await supervisor.phase == .stopped)
        #expect(!runtime.state.withLock { $0.running }, "the container the recovery restarted is stopped")
        // Nothing the recovery does afterwards can bring it back.
        await startHold.fire()
        for _ in 0..<200 { await Task.yield() }
        #expect(await supervisor.phase == .stopped)
        #expect(await sleeper.pending(.seconds(2)) == 0, "no monitor runs after the stop")
    }

    /// N11: Stop during the backoff sleep cancels it; no restart follows.
    @Test func aStopDuringTheBackoffCancelsTheRestart() async throws {
        let runtime = FakeBrowserRuntime()
        let sleeper = ManualSleeper()
        let supervisor = make(runtime, sleeper)
        try await supervisor.begin(.call)
        await supervisor.end(.call)
        runtime.state.withLock { $0.running = false; $0.exitCode = 137 }
        #expect(await sleeper.waitUntil(.seconds(2)))
        await sleeper.fire(.seconds(2))
        #expect(await sleeper.waitUntil(.seconds(1)), "backoff")
        await supervisor.stop(reason: "test")
        #expect(await supervisor.phase == .stopped)
        #expect(await sleeper.pending(.seconds(1)) == 0, "the backoff sleep was cancelled")
        #expect(!runtime.entries.contains("start"), "no restart")
    }

    /// v1.0.1 AF23: a browser left running by a previous launch is adopted by a start; Stop during its readiness wait
    /// stops it in order instead of showing Stopped while it keeps running.
    @Test func aStopDuringReadinessOfAnAdoptedBrowserStopsIt() async throws {
        let runtime = FakeBrowserRuntime()
        let sleeper = ManualSleeper()
        let supervisor = make(runtime, sleeper)
        adoptRunningBrowser(runtime)
        let start = Task { try await supervisor.begin(.call) }
        #expect(await sleeper.waitUntil(.milliseconds(150)), "waiting for readiness")
        #expect(!runtime.entries.contains("createAndStart") && !runtime.entries.contains("start"), "adopted, not started")
        await supervisor.stop(reason: "test")
        await #expect(throws: (any Error).self) { try await start.value }
        #expect(runtime.entries.contains("stop(30)"), "\(runtime.entries)")
        #expect(!runtime.state.withLock { $0.running })
        #expect(await supervisor.phase == .stopped)
    }

    /// AF23: the same Stop while the runtime cannot stop it is shown as unconfirmed, never as Stopped.
    @Test func aStopDuringReadinessThatCannotStopTheAdoptedBrowserIsUnconfirmed() async throws {
        let runtime = FakeBrowserRuntime()
        let sleeper = ManualSleeper()
        let supervisor = make(runtime, sleeper)
        adoptRunningBrowser(runtime)
        runtime.state.withLock { $0.stopFails = true }
        let start = Task { try await supervisor.begin(.call) }
        #expect(await sleeper.waitUntil(.milliseconds(150)))
        await supervisor.stop(reason: "test")
        _ = try? await start.value
        #expect(await supervisor.phase.isStopUnconfirmed)
        #expect(runtime.state.withLock { $0.running })
    }

    /// AF23: Stop during image preparation with no container at all is a plain stop (nothing to stop).
    @Test func aStopBeforeAnyContainerIsAPlainStop() async throws {
        let hold = ManualSleeper()
        let runtime = FakeBrowserRuntime(imageHold: hold)
        let supervisor = make(runtime, ManualSleeper())
        let start = Task { try await supervisor.begin(.call) }
        #expect(await hold.waitUntil(.seconds(3_600)))
        await supervisor.stop(reason: "test")
        _ = try? await start.value
        #expect(await supervisor.phase == .stopped)
        #expect(!runtime.entries.contains("stop(30)"))
        #expect(await supervisor.generation == 0)
    }

    /// AF23: a start that fails readiness and cannot stop the container it started says so instead of Failed.
    @Test func aFailedStartWhoseCleanupStopFailsIsUnconfirmed() async throws {
        let runtime = FakeBrowserRuntime()
        runtime.state.withLock { $0.stopFails = true }
        var timing = BrowserSupervisor.Timing(idle: .seconds(600))
        timing.readyTimeout = .zero
        let supervisor = BrowserSupervisor(runtime: runtime, timing: timing, viewerPassword: "pw", spec: { image, placement, seccomp in
            BrowserContainerSpec(image: image, seccompProfile: seccomp, network: placement.network, proxy: placement.proxy)
        }, sleep: { try await ManualSleeper().sleep($0) })
        await #expect(throws: BrowserStartError.timedOut) { try await supervisor.begin(.call) }
        #expect(await supervisor.phase.isStopUnconfirmed)
        #expect(runtime.state.withLock { $0.running })
    }

    /// The container a previous launch left running, with the configuration this start wants, not yet ready.
    private func adoptRunningBrowser(_ runtime: FakeBrowserRuntime) {
        let wanted = BrowserContainerSpec(image: "bellocode-browser:test", seccompProfile: "{}", network: "bellocode-egress-browser",
                                          proxy: "http://bellocode-proxy:3128")
        runtime.state.withLock {
            $0.exists = true
            $0.running = true
            $0.configHash = wanted.configHash
            $0.statusReady = false
        }
    }
}
