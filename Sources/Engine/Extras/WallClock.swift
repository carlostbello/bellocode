import Foundation
import Synchronization

/// Calendar time and sleeping until a date, injected so the scheduler and the PR poller are tested without real waits.
public protocol WallClock: Sendable {
    func now() -> Date
    /// Returns at `date` (or at once if it passed). Throws `CancellationError` when the task is cancelled.
    func sleep(until date: Date) async throws
}

/// The system clock. Sleeps in slices of at most a minute, so a changed system time or time zone is noticed.
public struct SystemWallClock: WallClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(until date: Date) async throws {
        while true {
            let remaining = date.timeIntervalSinceNow
            if remaining <= 0 { return }
            try await Task.sleep(for: .seconds(min(remaining, 60)))
        }
    }
}

/// A clock tests move by hand. `advance(to:)` wakes every sleeper whose date has come.
public final class ManualWallClock: WallClock {
    private struct Sleeper {
        var id: Int
        var date: Date
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var sleepers: [Sleeper] = []
        var nextID = 0
    }

    private let state: Mutex<State>

    public init(_ start: Date) { state = Mutex(State(now: start)) }

    public func now() -> Date { state.withLock { $0.now } }

    /// Sleepers waiting now (tests wait for a loop to go back to sleep).
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func advance(by interval: TimeInterval) { advance(to: now().addingTimeInterval(interval)) }

    public func advance(to date: Date) {
        let due: [Sleeper] = state.withLock { state in
            state.now = max(state.now, date)
            let now = state.now
            let due = state.sleepers.filter { $0.date <= now }
            state.sleepers.removeAll { $0.date <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    public func sleep(until date: Date) async throws {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool = state.withLock { state in
                    if date <= state.now || Task.isCancelled { return true }
                    state.sleepers.append(Sleeper(id: id, date: date, continuation: continuation))
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            try Task.checkCancellation()
        } onCancel: {
            let cancelled = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }
}
