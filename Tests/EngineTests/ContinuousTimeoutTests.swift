import CoreServices
import Foundation
import Synchronization
import Testing

import BelloCore
@testable import Engine

/// Counts events and lets a test wait for a count without waking in between: the waiter is a continuation resumed by
/// the event itself or by a single ceiling deadline on `ContinuousClock`. The process is idle while it waits, which is
/// the condition under which uptime-clock timers were seen not to fire (macOS 27); a polling wait would hide that.
final class IdleFireCounter: Sendable {
    private struct State {
        var count = 0
        var target = Int.max
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let state = Mutex(State())
    private let ceilingDeadline = ContinuousDeadline()

    func fire() {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            state.count += 1
            guard state.count >= state.target else { return nil }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: true)
    }

    var value: Int { state.withLock { $0.count } }

    /// Waits until `value >= target` or `ceiling` passes. Returns whether the target was reached. One waiter at a time.
    func wait(for target: Int = 1, ceiling: Duration = .seconds(10)) async -> Bool {
        let reached = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let done = state.withLock { state -> Bool in
                if state.count >= target { return true }
                state.target = target
                state.waiter = continuation
                return false
            }
            if done { continuation.resume(returning: true); return }
            ceilingDeadline.schedule(after: ceiling) { [weak self] in
                let waiter = self?.state.withLock { state -> CheckedContinuation<Bool, Never>? in
                    defer { state.waiter = nil }
                    return state.waiter
                }
                waiter?.resume(returning: false)
            }
        }
        ceilingDeadline.cancel()
        state.withLock { $0.target = .max }
        return reached
    }
}

/// Timeouts and flushes that once used uptime-clock `asyncAfter(deadline:)`. On macOS 27 such a timer was seen not to
/// fire while the process is otherwise idle, so with the old code these tests block on an idle wait and fail (the git
/// timeout returns only when `sleep 30` exits; the file flush never reaches the sink within the ceiling). Ceilings are
/// measured on `ContinuousClock`.
@Suite("ContinuousClock timeouts", .timeLimit(.minutes(3)))
struct ContinuousTimeoutTests {
    @Test func gitRunnerTimeoutStopsAHungProgramWhileIdle() async throws {
        let runner = GitRunner(environment: [:])
        let start = ContinuousClock.now
        await #expect(throws: GitError.timedOut(command: "sleep")) {
            _ = try await runner.runProgram(
                URL(filePath: "/bin/sleep"), ["30"], in: FileManager.default.temporaryDirectory.path, timeout: .milliseconds(200))
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func gitRunnerFinishesNormallyBeforeItsTimeout() async throws {
        let runner = GitRunner(environment: [:])
        let output = try await runner.runProgram(
            URL(filePath: "/bin/echo"), ["ok"], in: FileManager.default.temporaryDirectory.path, timeout: .seconds(30))
        #expect(output.status == 0)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "ok\n")
    }

    @Test func fileEventBridgeFlushesItsBatchWhileIdle() async throws {
        let received = Mutex<[[String]]>([])
        let flushed = IdleFireCounter()
        let collector = FileEventBridge.Collector(debounce: .milliseconds(50), maxBatch: 100) { batch in
            received.withLock { $0.append(batch) }
            flushed.fire()
        }
        defer { collector.stop() }
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        collector.received([("/work/a.txt", modified), ("/work/b.txt", modified)])
        #expect(await flushed.wait())
        #expect(received.withLock { $0 } == [["/work/a.txt", "/work/b.txt"]])
    }

    @Test func stoppedFileEventBridgeNeverFlushes() async throws {
        let received = Mutex(0)
        let collector = FileEventBridge.Collector(debounce: .milliseconds(30), maxBatch: 100) { _ in
            received.withLock { $0 += 1 }
        }
        collector.received([("/work/a.txt", FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified))])
        collector.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(received.withLock { $0 } == 0)
    }
}
