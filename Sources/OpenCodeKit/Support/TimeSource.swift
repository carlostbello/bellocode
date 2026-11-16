import Foundation

/// Monotonic time and sleeping, injected so supervisor and event-hub timing is testable without real delays.
public protocol TimeSource: Sendable {
    /// Monotonic time since an arbitrary origin.
    func now() -> Duration
    /// Suspends for `duration`. Throws `CancellationError` when the task is cancelled.
    func sleep(for duration: Duration) async throws
}

/// `ContinuousClock`-backed time.
public struct SystemTimeSource: TimeSource {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() { origin = clock.now }

    public func now() -> Duration { clock.now - origin }

    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

/// Thrown by `withTimeout` when the deadline passes first.
public struct TimeoutError: Error, Sendable, CustomStringConvertible {
    public let operation: String
    public let limit: Duration
    public var description: String { "\(operation) timed out after \(limit)" }
}

/// Runs `operation`, cancelling it and throwing `TimeoutError` if it does not finish within `limit` on `time`.
func withTimeout<T: Sendable>(
    _ limit: Duration,
    on time: any TimeSource,
    operation name: String,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await time.sleep(for: limit)
            throw TimeoutError(operation: name, limit: limit)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}

extension Duration {
    /// Whole milliseconds, for measurements and logs.
    public var milliseconds: Int64 {
        components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }

    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
