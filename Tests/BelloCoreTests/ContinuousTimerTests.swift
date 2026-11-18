import Foundation
import Synchronization
import Testing

@testable import BelloCore

/// Counts events and lets a test wait for a count without waking in between: the waiter is a continuation resumed by
/// the event itself or by a single ceiling deadline on `ContinuousClock`. The process is idle while it waits, which is
/// the condition under which uptime-clock timers were seen not to fire (macOS 27); a polling wait would hide that.
final class FireCounter: Sendable {
    private struct State {
        var count = 0
        var target = Int.max
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let state = Mutex(State())
    private let ceilingDeadline = ContinuousDeadline()

    func fire() {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            state.count += 1
            guard state.count >= state.target else { return nil }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: true)
    }

    var value: Int { state.withLock { $0.count } }

    /// Waits until `value >= target` or `ceiling` passes. Returns whether the target was reached. One waiter at a time.
    func wait(for target: Int = 1, ceiling: Duration = .seconds(10)) async -> Bool {
        let reached = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let done = state.withLock { state -> Bool in
                if state.count >= target { return true }
                state.target = target
                state.waiter = continuation
                return false
            }
            if done { continuation.resume(returning: true); return }
            ceilingDeadline.schedule(after: ceiling) { [weak self] in
                let waiter = self?.state.withLock { state -> CheckedContinuation<Bool, Never>? in
                    defer { state.waiter = nil }
                    return state.waiter
                }
                waiter?.resume(returning: false)
            }
        }
        ceilingDeadline.cancel()
        state.withLock { $0.target = .max }
        return reached
    }
}

@Suite("ContinuousClock timers", .timeLimit(.minutes(3)))
struct ContinuousTimerTests {
    @Test func deadlineFiresWhileTheProcessIsIdle() async {
        let fired = FireCounter()
        let deadline = ContinuousDeadline(after: .milliseconds(50)) { fired.fire() }
        #expect(await fired.wait())
        #expect(!deadline.isPending)
    }

    @Test func cancelledDeadlineNeverFires() async {
        let fired = FireCounter()
        let control = FireCounter()
        let deadline = ContinuousDeadline(after: .milliseconds(40)) { fired.fire() }
        deadline.cancel()
        #expect(!deadline.isPending)
        // A second deadline with a longer delay is the barrier: once it fired, the first one's time has long passed.
        let barrier = ContinuousDeadline(after: .milliseconds(120)) { control.fire() }
        #expect(await control.wait())
        #expect(fired.value == 0)
        _ = barrier
    }

    @Test func releasingADeadlineCancelsIt() async {
        let fired = FireCounter()
        let control = FireCounter()
        do { _ = ContinuousDeadline(after: .milliseconds(40)) { fired.fire() } }
        let barrier = ContinuousDeadline(after: .milliseconds(120)) { control.fire() }
        #expect(await control.wait())
        #expect(fired.value == 0)
        _ = barrier
    }

    @Test func reschedulingDebouncesOnTheTrailingEdge() async {
        let first = FireCounter()
        let second = FireCounter()
        let deadline = ContinuousDeadline()
        deadline.schedule(after: .milliseconds(40)) { first.fire() }
        deadline.schedule(after: .milliseconds(80)) { second.fire() }
        #expect(await second.wait())
        #expect(first.value == 0)
        #expect(!deadline.isPending)
    }

    @MainActor
    @Test func tickerTicksOnTheMainActorUntilStopped() async {
        let ticks = FireCounter()
        let ticker = ContinuousTicker(every: .milliseconds(20)) {
            MainActor.assertIsolated()
            ticks.fire()
        }
        #expect(await ticks.wait(for: 3))
        ticker.stop()
        #expect(!ticker.isRunning)
        let stoppedAt = ticks.value
        // At most one tick was already past its sleep when stop() ran; none after that.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(ticks.value <= stoppedAt + 1)
    }
}
