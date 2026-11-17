import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// Engine fixes found while integrating the app (M1-E): subfolder projects, sign-in lists refreshed by server events,
/// and the "Status unknown" turns after a server restart.
@Suite("Engine integration fixes", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct IntegrationFixesTests {
    @Test func subfolderOfARepositoryListsTheRepositorysThreads() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-repo")
        let repoID = session.projectID

        await engine.addProject(directory: "/tmp/mock-repo/Sources/App")
        try await waitUntil("subfolder resolved to the repository's project") {
            engine.root.projects.first { $0.directory == "/tmp/mock-repo/Sources/App" }?.projectID == repoID
        }
        let item = try #require(engine.root.projects.first { $0.directory == "/tmp/mock-repo/Sources/App" })
        #expect(item.name == "App", "a subfolder keeps its own name")
        try await waitUntil("its threads are listed") { engine.root.project(repoID)?.sessionIDs.contains(session.id) ?? false }
        await engine.stop()
        await harness.stop()
    }

    @Test func signInListsRefreshOnServerEvents() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let auth = engine.makeAuthService(openURL: { _ in })
        await auth.refresh()
        let before = auth.credentials.count
        let integration = try #require(auth.integrations.first { $0.methods.contains { $0.kind == .key } })
        // Another client signs in: only the server's events tell this app.
        try await harness.client.connectKey(integrationID: integration.id, key: "sk-test", directory: nil)
        try await waitUntil("credentials refreshed without an AuthService action") { auth.credentials.count == before + 1 }
        auth.shutdown()
        await engine.stop()
        await harness.stop()
    }

    @Test func unknownStatusAfterARestartOffersStopAndResume() async throws {
        // Real time, so the scripted 30 s pause keeps the turn running until the simulated crash.
        let harness = try await MockHarness.start(options: MockServerOptions(clock: .realTime))
        let box = EndpointBox(harness.connection)
        let engine = try makeEngine(harness, box: box)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        let thread = engine.openThread(session.id)
        try await waitUntil("ready") { thread.phase == .ready }
        await harness.server.enqueueScript(
            TurnScript(steps: [.text("Working on it…"), .delay(milliseconds: 30_000)]), for: session.id.rawValue)
        await thread.send("Start a long task")
        try await waitUntil("running") { thread.isRunning }

        // The server process dies mid-turn; a new one serves the same data and still lists the session as busy.
        let endpoint = try await harness.server.crashAndRestart()
        box.set(ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? "")))
        try await waitUntil("live with status unknown") { engine.root.connection == .live && thread.isStatusUnknown }
        #expect(await engine.core.isOrphaned(session.id))
        #expect(!thread.isRunning, "an orphaned turn is not presented as running")
        #expect(thread.session?.isRunning == true, "the server still says busy; nothing was done silently")

        // Stop: settles it as interrupted, and it stays settled across another resync.
        await thread.settleUnknownStatus()
        #expect(thread.lastError == nil)
        try await waitUntil("settled") { thread.status?.status != .unknown && !(thread.session?.isRunning ?? true) }
        #expect(thread.session?.outcome == .interrupted)
        let resyncsBefore = await engine.core.statistics.resyncs
        let again = try await harness.server.restart()
        box.set(ServerConnection(baseURL: again.url, credentials: ServerCredentials(password: again.password ?? "")))
        try await waitUntil("live again") { engine.root.connection == .live }
        // Barriers instead of a fixed sleep: the restart's resync has completed in the engine, and the thread model
        // has applied everything it published.
        let deadline = ContinuousClock.now + .seconds(15)
        while await engine.core.statistics.resyncs <= resyncsBefore || engine.root.connection != .live {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!(await engine.core.isOrphaned(session.id)))
        try await threadBarrier(engine, thread)
        #expect(!thread.isStatusUnknown && !(thread.session?.isRunning ?? true), "a resync does not bring it back")

        // Resume on another orphan: settles it and sends a continue prompt that runs.
        await harness.server.enqueueScript(TurnScript(steps: [.text("Still going"), .delay(milliseconds: 30_000)]), for: session.id.rawValue)
        await thread.send("Another long task")
        try await waitUntil("running again") { thread.isRunning }
        let third = try await harness.server.crashAndRestart()
        box.set(ServerConnection(baseURL: third.url, credentials: ServerCredentials(password: third.password ?? "")))
        try await waitUntil("unknown again") { engine.root.connection == .live && thread.isStatusUnknown }
        await harness.server.enqueueScript(TurnScript(steps: [.text("Resumed.")]), for: session.id.rawValue)
        let resumed = await thread.resumeAfterRestart()
        #expect(resumed != nil, "resume sent: \(thread.lastError?.userMessage ?? "")")
        try await waitUntil("resumed turn finished") {
            !thread.isRunning && thread.messageIDs.compactMap { thread.message($0)?.message.searchableText }.contains { $0.contains("Resumed.") }
        }
        thread.close()
        await engine.stop()
        await harness.stop()
    }
}
