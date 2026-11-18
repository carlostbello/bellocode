import Synchronization

// Timers on ContinuousClock.
//
// On macOS 27 (Darwin 27.0) timers on the system's uptime clock were seen not to fire while the process is otherwise
// idle: `DispatchQueue.asyncAfter(deadline:)`, dispatch timer sources, `Timer`, `RunLoop.run(until:)`,
// `perform(_:afterDelay:)`, `SuspendingClock` and `Task.sleep(nanoseconds:)`. A `Task.sleep` on `ContinuousClock` (the
// default clock of `Task.sleep(for:)`) does fire. Every timeout, debounce, retry and periodic refresh in BelloCode
// therefore sleeps on `ContinuousClock`, through these two types or a `Task.sleep(for:)` in an owned task.
// `Tests/BelloCoreTests/TimerGuardTests.swift` fails when production code uses an uptime-clock timer.

/// A cancellable one-shot deadline on `ContinuousClock`: runs `action` once `delay` has passed unless cancelled or
/// rescheduled first. Owned by the object whose work it times; releasing the deadline cancels it.
///
/// `action` runs on the global concurrent executor; hop to the queue or actor that owns the state (for example
/// `queue.async { ... }` or `await MainActor.run { ... }`). Use it for timeouts, debounces and delayed retries that a
/// dispatch callback or a non-async caller needs; inside an async function a plain `Task.sleep(for:)` is simpler.
public final class ContinuousDeadline: Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var generation = 0
    }

    private let state = Mutex(State())

    /// An idle deadline; arm it with `schedule(after:_:)`.
    public init() {}

    /// A deadline armed at once.
    public convenience init(after delay: Duration, _ action: @escaping @Sendable () async -> Void) {
        self.init()
        schedule(after: delay, action)
    }

    deinit { state.withLock { $0.task?.cancel() } }

    /// Arms the deadline, replacing (cancelling) any pending one, so repeated calls debounce on the trailing edge.
    public func schedule(after delay: Duration, _ action: @escaping @Sendable () async -> Void) {
        state.withLock { state in
            state.task?.cancel()
            state.generation &+= 1
            let generation = state.generation
            state.task = Task { [weak self] in
                do { try await Task.sleep(for: delay, clock: .continuous) } catch { return }
                // A cancel or reschedule that raced the wake-up wins.
                guard let self, self.claim(generation) else { return }
                await action()
            }
        }
    }

    /// Cancels a pending deadline. A no-op if it already fired or was never armed.
    public func cancel() {
        state.withLock { state in
            state.task?.cancel()
            state.task = nil
            state.generation &+= 1
        }
    }

    /// Whether a deadline is armed and has not fired yet.
    public var isPending: Bool { state.withLock { $0.task != nil } }

    private func claim(_ generation: Int) -> Bool {
        state.withLock { state in
            guard state.generation == generation, !Task.isCancelled else { return false }
            state.task = nil
            return true
        }
    }
}

/// A repeating main-actor tick on `ContinuousClock`, every `interval` after the previous tick (a slow tick delays the
/// next one; ticks never pile up). Starts when created; `stop()` or releasing the ticker ends it.
@MainActor
public final class ContinuousTicker {
    private let task: Task<Void, Never>

    /// - Parameters:
    ///   - interval: The time between the end of one tick and the start of the next.
    ///   - tolerance: Leeway the system may add to each wake-up, for coalescing (nil: none requested).
    ///   - tick: Runs on the main actor. Capture its owner weakly.
    public init(every interval: Duration, tolerance: Duration? = nil, _ tick: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            while true {
                do { try await Task.sleep(for: interval, tolerance: tolerance, clock: .continuous) } catch { return }
                if Task.isCancelled { return }
                tick()
            }
        }
    }

    deinit { task.cancel() }

    public func stop() { task.cancel() }

    public var isRunning: Bool { !task.isCancelled }
}
