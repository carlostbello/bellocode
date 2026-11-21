import BelloCore
import ContainerKit
import Foundation
import Synchronization
import Testing

@testable import Engine

/// v1.0.0 review N12: the service's activity units (human control, live viewers) follow edges and never leak or go
/// negative, and a Keychain error is never taken for a missing packing key.
@Suite("Shared browser service activity", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct SharedBrowserServiceActivityTests {
    struct Fixture {
        let service: SharedBrowserService
        let supervisor: BrowserSupervisor
        let runtime: FakeBrowserRuntime
        let sleeper: ManualSleeper
        let defaults: UserDefaults
        let suite: String

        @MainActor static func make(runtime: FakeBrowserRuntime = FakeBrowserRuntime()) async throws -> Fixture {
            let suite = "bellocode.tests.browser-activity.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let service = SharedBrowserService(store: try ProjectionStore(location: .inMemory), configuration: nil, defaults: defaults)
            let sleeper = ManualSleeper()
            let supervisor = BrowserSupervisor(runtime: runtime, timing: .init(idle: .seconds(600)), viewerPassword: "pw", spec: { image, placement, seccomp in
                BrowserContainerSpec(image: image, seccompProfile: seccomp, network: placement.network, proxy: placement.proxy)
            }, sleep: { try await sleeper.sleep($0) })
            await service.attach(supervisor)
            return Fixture(service: service, supervisor: supervisor, runtime: runtime, sleeper: sleeper, defaults: defaults, suite: suite)
        }

        func cleanup() { defaults.removePersistentDomain(forName: suite) }
    }

    @Test func takingOverSeveralTabsAndGivingAllBackReleasesHumanActivity() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        await fixture.service.takeOver("tab-a")
        await fixture.service.takeOver("tab-b")
        #expect(await fixture.supervisor.activityCounts()[.human] == 1)
        await fixture.service.giveBack("*")
        #expect(await fixture.supervisor.activityCounts()[.human, default: 0] == 0, "idle stop can happen again")
    }

    @Test func aRestartReleasesHumanActivity() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        await fixture.service.takeOver("tab-a")
        fixture.runtime.state.withLock { $0.running = false; $0.exitCode = 137 }
        #expect(await fixture.sleeper.waitUntil(.seconds(2)))
        await fixture.sleeper.fire(.seconds(2))  // the monitor sees the crash; the service is told
        for _ in 0..<20_000 where await fixture.supervisor.activityCounts()[.human, default: 0] != 0 { await Task.yield() }
        #expect(fixture.service.humanControl.isEmpty)
        #expect(await fixture.supervisor.activityCounts()[.human, default: 0] == 0)
    }

    /// A viewer that disappears while the browser is still starting leaves no `.viewer` unit behind.
    @Test func aViewerThatDisappearsDuringTheStartLeavesNoActivity() async throws {
        let hold = ManualSleeper()
        let fixture = try await Fixture.make(runtime: FakeBrowserRuntime(imageHold: hold))
        defer { fixture.cleanup() }
        let appearing = Task { await fixture.service.viewerAppeared() }
        #expect(await hold.waitUntil(.seconds(3_600)), "the start is building the image")
        await fixture.service.viewerDisappeared()
        #expect(fixture.service.viewerSubscribers == 0)
        await hold.fire()
        await appearing.value
        #expect(fixture.service.viewerSubscribers == 0)
        #expect(await fixture.supervisor.activityCounts()[.viewer, default: 0] == 0)
    }

    /// A failed start never drives the viewer count below zero; the next appearance tries again.
    @Test func aFailedStartNeverMakesTheViewerCountNegative() async throws {
        let runtime = FakeBrowserRuntime()
        runtime.state.withLock { $0.startExit = 1 }
        let fixture = try await Fixture.make(runtime: runtime)
        defer { fixture.cleanup() }
        await fixture.service.viewerAppeared()
        #expect(fixture.service.viewerSubscribers == 1)
        await fixture.service.viewerDisappeared()
        #expect(fixture.service.viewerSubscribers == 0)
        await fixture.service.viewerDisappeared()
        #expect(fixture.service.viewerSubscribers == 0)
        runtime.state.withLock { $0.startExit = nil; $0.exists = false }
        await fixture.service.viewerAppeared()
        #expect(await fixture.supervisor.activityCounts()[.viewer] == 1)
        await fixture.service.viewerDisappeared()
        #expect(await fixture.supervisor.activityCounts()[.viewer, default: 0] == 0)
    }

    final class LockedVault: SecretVault {
        struct Locked: Error {}
        let stored = Mutex(0)
        func store(account: String, label: String, value: SecretValue) throws { stored.withLock { $0 += 1 } }
        func read(account: String) throws -> SecretValue? { throw Locked() }
        func delete(account: String) throws {}
    }

    /// A Keychain error is thrown, never answered with a new key that would replace the stored one.
    @Test func aKeychainErrorNeverReplacesThePackingKey() async throws {
        let vault = LockedVault()
        await #expect(throws: LockedVault.Locked.self) { _ = try await SharedBrowserService.packingKey(vault, account: "test") }
        #expect(vault.stored.withLock { $0 } == 0)
    }
}
