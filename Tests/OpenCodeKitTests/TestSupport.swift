import BelloCore
import Foundation
import Synchronization
import Testing
@testable import OpenCodeKit

/// Paths into the repository, resolved from this file's location.
enum Repo {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `Contracts/opencode-<pin>` (the candidate's under `make opencode-verify`).
    static var contracts: URL { OpenCodePin.contractsDirectory(root: root) ?? root.appending(path: "Contracts") }

    static var eventsSample: Data {
        get throws { try Data(contentsOf: contracts.appending(path: "events-sample.sse")) }
    }

    /// The 2.3.0 recording, kept as a fixed fixture for tests that assert its exact content (text, IDs, usage).
    static var fixtureSample: Data {
        get throws { try Data(contentsOf: root.appending(path: "Contracts/opencode-2.3.0/events-sample.sse")) }
    }

    /// Frames (blank-line separated blocks with a `data:` line) and `:` comment lines in a recording, counted
    /// naively so the parser's own count can be checked against it.
    static func naiveCounts(_ sample: Data) -> (frames: Int, comments: Int) {
        let text = String(decoding: sample, as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        let comments = lines.filter { $0.hasPrefix(":") }.count
        let frames = text.components(separatedBy: "\n\n").filter { block in
            block.components(separatedBy: "\n").contains { $0.hasPrefix("data:") }
        }.count
        return (frames, comments)
    }

    static var pinnedVersion: String? { OpenCodePin.repositoryVersion(root: root) }

    /// The vendored opencode binary, if `Scripts/fetch-opencode.sh` has run in this checkout.
    static var vendoredOpencode: URL? { OpenCodePin.vendoredBinary(root: root) }
}

/// A clock that only moves when the test advances it.
final class ManualTimeSource: TimeSource {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Duration = .zero
        var sleepers: [UInt64: Sleeper] = [:]
        var nextID: UInt64 = 0
        var requested: [Duration] = []
    }

    private let state = Mutex(State())

    func now() -> Duration { state.withLock { $0.now } }

    /// Every duration passed to `sleep`, in order.
    var requestedSleeps: [Duration] { state.withLock { $0.requested } }

    var pendingSleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(for duration: Duration) async throws {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    state.requested.append(duration)
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if duration <= .zero { return .success(()) }
                    state.sleepers[id] = Sleeper(deadline: state.now + duration, continuation: continuation)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now += duration
            let due = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in due.keys { state.sleepers[id] = nil }
            return due.values.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Waits (in real time, briefly) until at least `count` sleepers are pending.
    func waitForSleepers(_ count: Int = 1, timeout: Duration = .seconds(5)) async throws {
        try await eventually(timeout: timeout) { self.pendingSleeperCount >= count }
    }
}

struct EventuallyTimeout: Error, CustomStringConvertible {
    let description = "condition not met in time"
}

/// Polls `condition` every few milliseconds of real time until it holds.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !(await condition()) {
        guard clock.now < deadline else { throw EventuallyTimeout() }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// Runs `operation` with a real-time limit.
func within<T: Sendable>(
    _ limit: Duration, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withTimeout(limit, on: SystemTimeSource(), operation: "test step", operation)
}

/// Reads messages from a subscription until `predicate` matches, returning everything read.
func collect(
    _ iterator: inout EventSubscription.Iterator, until predicate: (EventHubMessage) -> Bool
) async -> [EventHubMessage] {
    var messages: [EventHubMessage] = []
    while let message = await iterator.next() {
        messages.append(message)
        if predicate(message) { break }
    }
    return messages
}

extension EventHubMessage {
    var envelope: OpenCodeEventEnvelope? {
        if case .event(let envelope) = self { envelope } else { nil }
    }

    var isResync: Bool {
        if case .resync = self { true } else { false }
    }
}
