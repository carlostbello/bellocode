import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
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

    /// NF01: a first project added while connected gets the app and Shared Chrome tools, and a server restart (new
    /// port) re-hosts them on the new server instead of leaving the hosts dialling the old one.
    @Test func clientToolsFollowNewProjectsAndServerRestarts() async throws {
        var scenario = Scenario.empty()
        scenario.projects = []
        let harness = try await MockHarness.start(scenario)
        let box = EndpointBox(harness.connection)
        let engine = try makeEngine(harness, box: box)
        engine.sharedBrowser.forceAvailableForSnapshots = true
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        #expect(engine.root.projects.isEmpty)

        let directory = "/tmp/mock-first-project"
        func hosted() async -> Set<String> {
            Set(await harness.server.clientMCPConnections().filter { $0.directory == directory && $0.initialized }.map(\.name))
        }
        func waitHosted(_ expected: Set<String>, _ what: String) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(15)
            while await hosted() != expected {
                guard clock.now < deadline else {
                    Issue.record("timed out waiting for \(what): \(await hosted())")
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let names: Set<String> = [OrchestrationService.appServerName, SharedBrowserBroker.serverName]
        await engine.addProject(directory: directory)
        try await waitHosted(names, "first project hosted")

        let endpoint = try await harness.server.restart()
        box.set(ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? "")))
        // The old sockets died with the old server; only hosts dialling the new port can appear here.
        try await waitHosted([], "old sockets gone")
        try await waitUntil("live again") { engine.root.connection == .live }
        try await waitHosted(names, "hosted on the restarted server")
        let app = await harness.server.callClientMCPTool(name: OrchestrationService.appServerName, tool: AppTools.queue)
        #expect(app != nil, "the app tools answer on the new server")
        await engine.stop()
        await harness.stop()
    }
}
