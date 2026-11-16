import Foundation

/// Capped exponential backoff with symmetric jitter.
///
/// `delay(forAttempt: n)` is `min(maximum, initial * multiplier^(n-1))` scaled by a factor in
/// `[1 - jitter, 1 + jitter]` and then capped again at `maximum`.
public struct BackoffPolicy: Sendable, Hashable {
    public var initial: Duration
    public var maximum: Duration
    public var multiplier: Double
    /// Fraction of the delay to randomise, 0...1.
    public var jitter: Double

    public init(initial: Duration, maximum: Duration, multiplier: Double = 2, jitter: Double = 0.2) {
        precondition(initial > .zero && maximum >= initial && multiplier >= 1 && (0...1).contains(jitter))
        self.initial = initial
        self.maximum = maximum
        self.multiplier = multiplier
        self.jitter = jitter
    }

    /// Delay before attempt `attempt` (1-based). `random` must return a value in `0..<1`.
    public func delay(forAttempt attempt: Int, random: Double) -> Duration {
        let exponent = Double(max(0, attempt - 1))
        let base = min(maximum.seconds, initial.seconds * pow(multiplier, exponent))
        let factor = 1 + jitter * (2 * random - 1)
        let seconds = min(maximum.seconds, max(0, base * factor))
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }
}

/// Source of uniformly distributed values in `0..<1`, injected for deterministic jitter in tests.
public typealias RandomUnit = @Sendable () -> Double

public let systemRandomUnit: RandomUnit = { Double.random(in: 0..<1) }
