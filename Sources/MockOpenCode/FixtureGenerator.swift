import Foundation

/// Deterministic, seeded generator for large scenarios. (Checkpoint stub; filled in by a later commit.)
public struct FixtureGenerator: Sendable {
    public let seed: UInt64

    public init(seed: UInt64) { self.seed = seed }

    public func workspace(projectCount: Int, sessionCount: Int, messagesPerSession: Int) -> Scenario {
        Scenario.empty(seed: seed)
    }

    public func addLargeSession(to scenario: inout Scenario, messageCount: Int) {}
}
