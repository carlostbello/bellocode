import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// Deep review 1, C7: launch catch-up must not consume due work before opencode is reachable.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct ScheduleLaunchTests {
    /// A runner that fails with a chosen error until told otherwise.
    final class ScriptedRunner: ScheduleRunner {
        var failure: (any Error)?
        var started = 0
        func startThread(
            directory: String, title: String, prompt: String, agent: String?, model: ModelSelection?, permissionMode: PermissionMode?
        ) async throws -> SessionID {
            if let failure { throw failure }
            started += 1
            return SessionID("ses_run\(started)")
        }
        func send(_ prompt: String, to thread: SessionID) async throws {}
        func threadExists(_ id: SessionID) -> Bool { true }
    }

    @Test func overdueOneOffWaitsForTheFirstReconcileThenRunsOnce() async throws {
        let harness = try await MockHarness.start()
        let box = EndpointBox(nil)  // the supervisor has not published an endpoint yet
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = ManualWallClock(now)
        var configuration = EngineConfiguration(server: .dynamic { box.get() }, store: .inMemory)
        configuration.eventBackoff = BackoffPolicy(initial: .milliseconds(20), maximum: .milliseconds(200))
        configuration.writeInterval = .milliseconds(20)
        configuration.wallClock = clock
        let engine = try Engine(configuration: configuration)
        let due = now.addingTimeInterval(-3_600)
        var task = ScheduledTask(
            name: "Overdue", prompt: "Summarise", rule: .once(due), directory: "/tmp/mock-project", created: now.addingTimeInterval(-7_200))
        task.nextRun = due
        try await engine.store.saveSchedule(task)

        await engine.start()
        // Shown at once, not run: no endpoint yet.
        let shown = try #require(engine.extras.schedules.task(task.id))
        #expect(!engine.extras.schedules.isDispatchArmed)
        #expect(shown.lastRun == nil)
        #expect(shown.enabled)
        #expect(shown.nextRun == due, "the original due occurrence is kept")
        #expect(await engine.extras.schedules.runs(task.id).isEmpty)

        box.set(harness.connection)
        try await waitUntil("live and run", timeout: .seconds(30)) {
            engine.root.connection == .live && engine.extras.schedules.task(task.id)?.lastRun != nil
        }
        let ran = try #require(engine.extras.schedules.task(task.id))
        guard case .started(let thread) = ran.lastRun?.outcome else {
            Issue.record("expected a started run, got \(String(describing: ran.lastRun?.outcome))")
            return
        }
        #expect(ran.lastRun?.due == due)
        #expect(!ran.enabled, "a one-off is done after its run")
        let created = try await harness.client.session(thread.rawValue)
        #expect(created.title?.hasPrefix("Overdue · ") == true)
        #expect(await engine.extras.schedules.runs(task.id).count == 1)
        await engine.stop()
        await harness.stop()
    }

    @Test func anOfflineFailureKeepsTheOccurrenceAndARejectionIsRecorded() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = ManualWallClock(start)
        let store = try ProjectionStore(location: .inMemory)
        let service = SchedulerService(store: store, clock: clock)
        let runner = ScriptedRunner()
        service.runner = runner
        await service.start()
        let task = try await service.create(
            ScheduledTask(name: "Once", prompt: "p", rule: .once(start.addingTimeInterval(60)), directory: "/r", created: start))
        let due = try #require(task.nextRun)
        runner.failure = EngineError.offline
        clock.advance(by: 60)
        await service.tick()
        var current = try #require(service.task(task.id))
        #expect(current.enabled && current.nextRun == due && current.lastRun == nil, "deferred, not consumed")
        #expect(service.deferred.contains(task.id))
        await service.tick()
        #expect(runner.started == 0)
        // Reachable again after the retry delay: the same occurrence runs.
        runner.failure = nil
        clock.advance(by: service.deferralRetry)
        await service.tick()
        current = try #require(service.task(task.id))
        #expect(runner.started == 1)
        #expect(current.lastRun?.due == due)
        #expect(!service.deferred.contains(task.id))

        // A permanent rejection is recorded (and a one-off then ends) as before.
        let other = try await service.create(
            ScheduledTask(name: "Rejected", prompt: "p", rule: .once(clock.now().addingTimeInterval(60)), directory: "/r", created: clock.now()))
        runner.failure = EngineError.rejected("bad agent")
        clock.advance(by: 60)
        await service.tick()
        let rejected = try #require(service.task(other.id))
        guard case .failed = rejected.lastRun?.outcome else {
            Issue.record("expected a failed run")
            return
        }
        #expect(!rejected.enabled)
        service.shutdown()
    }

    @Test func disarmedDispatchRunsNothingUntilArmed() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = ManualWallClock(start)
        let store = try ProjectionStore(location: .inMemory)
        var task = ScheduledTask(name: "Due", prompt: "p", rule: .interval(minutes: 30), directory: "/r", created: start.addingTimeInterval(-3_600))
        task.nextRun = start.addingTimeInterval(-60)
        try await store.saveSchedule(task)
        let service = SchedulerService(store: store, clock: clock)
        let runner = ScriptedRunner()
        service.runner = runner
        await service.start(armed: false)
        #expect(service.tasks.count == 1)
        await service.tick()
        #expect(runner.started == 0)
        await service.setDispatchArmed(true)
        #expect(runner.started == 1)
        service.shutdown()
    }
}
