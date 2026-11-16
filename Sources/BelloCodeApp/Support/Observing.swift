import Foundation
import Observation
import Synchronization

/// Re-runs `apply` whenever an `@Observable` property it read changes, until the returned token is cancelled or
/// released. Changes are coalesced to one `apply` per main run-loop turn (Observation reports `willSet`; reading on
/// the next turn sees the new values and batches bursts).
///
/// Threading: `@MainActor`. `apply` must be cheap and idempotent (AGENTS.md rule 16).
@MainActor
final class ObservationLoop {
    private var isCancelled = false
    private var isScheduled = false
    private let apply: @MainActor () -> Void

    init(_ apply: @escaping @MainActor () -> Void) {
        self.apply = apply
        track()
    }

    func cancel() { isCancelled = true }

    private func track() {
        guard !isCancelled else { return }
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.reschedule() }
        }
    }

    private func reschedule() {
        guard !isCancelled, !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isScheduled = false
            self.track()
        }
    }
}

/// Waits until `condition` (which reads observable state) becomes true, or `timeout` passes. Returns whether it did.
@MainActor
func waitUntil(timeout: Duration, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
    if condition() { return true }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if Task.isCancelled { return false }
        let changed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let box = ResumeOnce(continuation)
            withObservationTracking {
                _ = condition()
            } onChange: {
                box.resume(true)
            }
            // Bounded wait per round so a missed change can never hang the caller.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                box.resume(false)
            }
        }
        _ = changed
        await Task.yield()
        if condition() { return true }
    }
    return condition()
}

/// Resumes a continuation exactly once from any thread.
private final class ResumeOnce: Sendable {
    private let state: Mutex<CheckedContinuation<Bool, Never>?>

    init(_ continuation: CheckedContinuation<Bool, Never>) { state = Mutex(continuation) }

    func resume(_ value: Bool) {
        state.withLock { continuation in
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
