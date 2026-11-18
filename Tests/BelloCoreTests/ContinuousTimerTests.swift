import Foundation
import Synchronization
import Testing

@testable import BelloCore

/// Counts events and lets a test wait for a count with a ceiling measured on `ContinuousClock`, so a timer that never
/// fires fails the test instead of hanging it. With uptime-clock timers on an idle process (macOS 27) these waits time
/// out; on `ContinuousClock` they finish in about the timer's interval.
final class FireCounter: Sendable {
    private let count = Mutex(0)

    func fire() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }

    /// Polls on `ContinuousClock` until `value >= target` or `ceiling` passes. Returns whether the target was reached.
    func wait(for target: Int = 1, ceiling: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + ceiling
        while value < target {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
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
