import AppKit
import ContainerKit
import Foundation
import Synchronization
import Testing

@testable import BelloCodeApp
@testable import Engine

/// v1.0.1 AF23 (third round), at the app's surfaces: when a failed start leaves Chrome running (Failed) or a stop cannot
/// be confirmed (Stop not confirmed), Browser ▸ Stop Shared Chrome (and its Command Palette entry) is enabled, the
/// panel offers Stop, and invoking the command reaches the supervisor and stops the container.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct SharedChromeStopCommandTests {
    /// A container runtime held in memory: the viewer password fails (so a start fails after the container runs), and
    /// stop can be made to fail.
    final class Runtime: BrowserRuntime {
        struct State {
            var running = false
            var exists = false
            var configHash: String?
            var stopFails = false
            var stops = 0
        }
        let state = Mutex(State())

        func prepareImage(progress: @escaping @Sendable (String) -> Void) async throws -> String { "bellocode-browser:test" }
        func prepareNetwork() async throws -> BrowserNetworkPlacement { BrowserNetworkPlacement(network: "net", proxy: "http://proxy:3128") }
        func inspect() async throws -> BrowserContainerState? {
            state.withLock { $0.exists ? BrowserContainerState(running: $0.running, configHash: $0.configHash, exitCode: $0.running ? nil : 0) : nil }
        }
        func createAndStart(_ spec: BrowserContainerSpec) async throws {
            state.withLock { $0.exists = true; $0.running = true; $0.configHash = spec.configHash }
        }
        func start() async throws { state.withLock { $0.running = true } }
        struct Refused: Error {}
        func stop(timeout: Int) async throws {
            try state.withLock { state in
                state.stops += 1
                if state.stopFails { throw Refused() }
                state.running = false
            }
        }
        func remove() async throws { state.withLock { $0.exists = false; $0.running = false } }
        func removeProfile() async throws {}
        func status() async throws -> BrowserRuntimeStatus? {
            BrowserRuntimeStatus(sandbox: "ok", relay: "up", extension: "connected", paired: true, chromiumRestarts: 0)
        }
        func setViewerPassword(_ password: String) async throws { throw Refused() }
        func seccompProfile() throws -> String { "{}" }
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<20_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    @Test func stopIsEnabledAndStopsTheContainerInFailedAndStopNotConfirmed() async throws {
        let suite = "bellocode.tests.chrome-stop.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SharedBrowserService(store: try ProjectionStore(location: .inMemory), configuration: nil, defaults: defaults)
        let runtime = Runtime()
        let supervisor = BrowserSupervisor(runtime: runtime, timing: .init(idle: .seconds(600)), viewerPassword: "pw", spec: { image, placement, seccomp in
            BrowserContainerSpec(image: image, seccompProfile: seccomp, network: placement.network, proxy: placement.proxy)
        }, sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        await service.attach(supervisor)
        #expect(!SharedChromeMenuRouter.isEnabled(.stop, service: service), "nothing to stop yet")

        // A start that fails after the container runs, whose cleanup stop also fails: Stop not confirmed.
        runtime.state.withLock { $0.stopFails = true }
        await service.startBrowser()
        #expect(await eventually { service.phase.isStopUnconfirmed }, "\(service.phase.title)")
        #expect(runtime.state.withLock { $0.running })
        #expect(SharedChromeMenuRouter.isEnabled(.stop, service: service), "Browser ▸ Stop is disabled in Stop not confirmed")
        #expect(SharedChromePlaceholder.offersStop(service.phase), "the panel offers no Stop")
        // The person's Stop (the menu item's and palette's action) retries; this time the container stops.
        runtime.state.withLock { $0.stopFails = false }
        await SharedChromeMenuRouter.run(.stop, in: nil, service: service)?.value
        #expect(await eventually { service.phase == .stopped }, "\(service.phase.title)")
        #expect(!runtime.state.withLock { $0.running })

        // A failed start whose cleanup stop worked, then the container runs again behind BelloCode's back: Failed.
        await service.startBrowser()
        #expect(await eventually { if case .failed = service.phase { true } else { false } }, "\(service.phase.title)")
        #expect(SharedChromeMenuRouter.isEnabled(.stop, service: service), "Browser ▸ Stop is disabled in Failed")
        #expect(SharedChromePlaceholder.offersStop(service.phase), "the panel offers no Stop")
        runtime.state.withLock { $0.running = true }
        let stopsBefore = runtime.state.withLock { $0.stops }
        await SharedChromeMenuRouter.run(.stop, in: nil, service: service)?.value
        #expect(runtime.state.withLock { $0.stops } > stopsBefore, "Stop in Failed did not reach the container")
        #expect(await eventually { service.phase == .stopped }, "\(service.phase.title)")
        #expect(!runtime.state.withLock { $0.running }, "the signed-in browser still runs")
    }
}
