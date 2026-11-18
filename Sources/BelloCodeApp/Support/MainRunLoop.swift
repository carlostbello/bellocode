import Foundation

/// Runs the main run loop for a while from synchronous main-thread code (the shell driver's `settle`, snapshots).
///
/// A run-loop deadline alone is a timer on the uptime clock, and those were seen never to fire on macOS 27 while the
/// process is otherwise idle: `RunLoop.main.run(until:)` then returned only when something unrelated woke the main
/// thread (tens of seconds in tests). A task sleeping on `ContinuousClock` wakes the run loop at the deadline, and the
/// run loop, finding its deadline passed, returns. The wake is a run-loop wake-up, not a main-queue block, because a
/// nested run loop cannot drain the main queue while a main-actor task is running on it.
enum MainRunLoop {
    @MainActor
    static func run(for interval: Duration) {
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        let wake = scheduleWake(after: interval)
        defer { wake.cancel() }
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private nonisolated static func scheduleWake(after interval: Duration) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: interval, clock: .continuous) } catch { return }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}
