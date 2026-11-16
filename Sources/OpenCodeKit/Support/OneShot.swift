import Foundation
import Synchronization

/// A value that is set once and can be awaited by any number of tasks. Waiting honours task cancellation.
///
/// Used to bridge Foundation callbacks (process termination, the first stdout line) into async code without
/// spawning tasks.
public final class OneShot<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiters: [UInt64: CheckedContinuation<Value, any Error>] = [:]
        var nextToken: UInt64 = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Sets the value and wakes every waiter. Later calls are ignored; returns whether this call set the value.
    @discardableResult
    public func fulfill(_ value: Value) -> Bool {
        let waiters: [CheckedContinuation<Value, any Error>]? = state.withLock { state in
            guard state.value == nil else { return nil }
            state.value = value
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        guard let waiters else { return false }
        for waiter in waiters { waiter.resume(returning: value) }
        return true
    }

    /// The value if it has been set.
    public var current: Value? { state.withLock { $0.value } }

    /// Waits for the value. Throws `CancellationError` if the waiting task is cancelled first.
    public func value() async throws -> Value {
        let token = state.withLock { state -> UInt64 in
            state.nextToken += 1
            return state.nextToken
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                let immediate: Result<Value, any Error>? = state.withLock { state in
                    if let value = state.value { return .success(value) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.waiters[token] = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: token) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
