import BelloCore
import Foundation
import MockOpenCode
import Testing

@testable import Engine

/// Every live-engine test hosts the app tools; against the mock that used to be a 404 and a background retry loop
/// (500 ms doubling to 30 s) for the whole test. The mock now serves the route as 2.3.0 does.
@MainActor
@Suite("Engine app tools against MockOpenCode", .timeLimit(.minutes(3)))
struct ClientMCPEngineTests {
    @Test func engineHostsTheAppToolsOnceWithoutRetrying() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        _ = try await engine.createThread(in: "/tmp/mock-project")
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        var connections: [MockClientMCPConnection] = []
        while connections.first?.tools.isEmpty ?? true {
            guard clock.now < deadline else { break }
            await Task.yield()
            connections = await harness.server.clientMCPConnections()
        }
        let app = connections.filter { $0.name == OrchestrationService.appServerName }
        #expect(app.count == 1, "one socket per location, not a stack of retries")
        #expect(app.first?.initialized == true)
        #expect(app.first?.tools.contains("open_thread") == true)
        await engine.stop()
        await harness.stop()
    }
}
