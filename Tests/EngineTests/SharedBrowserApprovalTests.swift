import BelloCore
import Foundation
import OpenCodeKit
import Synchronization
import Testing

@testable import Engine

/// The person's approvals for the shared Chrome at the service level: Allow Once advertises the tools (R19), a card
/// restored after relaunch is still answered (R20), and a revocation survives a failed write (R21).
@Suite("Shared browser approvals", .timeLimit(.minutes(3)))
@MainActor
struct SharedBrowserApprovalTests {
    static let directory = "/p/atlas"

    struct Fixture {
        let store: ProjectionStore
        let defaults: UserDefaults
        let suite: String

        static func make(subscriberLimit: Int = 4096) throws -> Fixture {
            let suite = "bellocode.tests.browser.\(UUID().uuidString)"
            return Fixture(store: try ProjectionStore(location: .inMemory, changes: ChangeBus(subscriberLimit: subscriberLimit)),
                           defaults: UserDefaults(suiteName: suite)!, suite: suite)
        }

        /// A fresh service on the same store and defaults: what a relaunch sees.
        @MainActor func service() async -> SharedBrowserService {
            let service = SharedBrowserService(store: store, configuration: nil, defaults: defaults)
            service.forceAvailableForSnapshots = true
            await service.start()
            return service
        }

        func cleanup() { defaults.removePersistentDomain(forName: suite) }
    }

    /// The card exactly as `requestAccess` makes it (durable: only this survives a relaunch).
    static func card(_ directory: String = directory) -> AppApproval {
        AppApproval(action: .browserMCP, title: "Let agents use the shared Chrome", detail: "", scope: directory,
                    subjectID: AppRequest.makeID("chrome"), allowsAlways: true, digest: SHA256Hex.of("browserMCP\n" + directory))
    }

    static let navigate = ClientMCPTool(name: "navigate", description: "Go", inputSchema: .object(["type": .string("object")]))

    @Test func allowOnceAdvertisesTheToolsAndStillChecksTheExactThread() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let service = await fixture.service()
        try #require(service.settings.enabled, "a fresh defaults suite has the shared Chrome on")
        let broker = SharedBrowserBroker(host: ServiceHost(service: service), cachedTools: [Self.navigate])
        #expect(await broker.tools(directory: Self.directory).map(\.name) == [SharedBrowserBroker.requestAccessTool])
        try await service.answerApproval(Self.card(), session: SessionID("ses_a"), approved: true, always: false)
        let tools = await broker.tools(directory: Self.directory).map(\.name)
        #expect(tools.contains("navigate"), "Allow Once must advertise the chrome_* tools in the thread's directory: \(tools)")
        #expect(tools.contains(SharedBrowserBroker.requestAccessTool), "other threads there can still ask")
        // Enforced per call on the exact session and directory.
        #expect(service.access(session: "ses_a", directory: Self.directory) == .allowed)
        #expect(service.access(session: "ses_b", directory: Self.directory) == .needsApproval)
        #expect(service.access(session: "ses_a", directory: "/p/other") == .needsApproval)
        #expect(await broker.tools(directory: "/p/other").map(\.name) == [SharedBrowserBroker.requestAccessTool])
        let refused = await broker.call(ClientMCPCall(tool: "navigate", arguments: .object([:]), sessionID: "ses_b", directory: Self.directory))
        #expect(refused.isError && refused.text.contains("approval"))
    }

    @Test func aCardAnsweredAfterRelaunchIsStillApplied() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let card = Self.card()
        _ = await fixture.service()  // the launch that raised the card
        let relaunched = await fixture.service()
        try await relaunched.answerApproval(card, session: SessionID("ses_a"), approved: true, always: true)
        #expect(relaunched.approvedProjects.contains(Self.directory))
        #expect(try await fixture.store.grants(.browserMCP).contains(Self.directory))
        // Allow Once after a relaunch: the thread from the durable request.
        let other = Self.card("/p/beta")
        try await relaunched.answerApproval(other, session: SessionID("ses_b"), approved: true, always: false)
        #expect(relaunched.approvedSessions["ses_b"] == "/p/beta")
    }

    @Test func anAlwaysThatCannotBeStoredKeepsTheCard() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let service = await fixture.service()
        await fixture.store.setWriteHook { _ in throw CancellationError() }
        await #expect(throws: (any Error).self) {
            try await service.answerApproval(Self.card(), session: SessionID("ses_a"), approved: true, always: true)
        }
        #expect(!service.approvedProjects.contains(Self.directory))
        // A forged or stale card (digest for another scope) applies nothing.
        await fixture.store.setWriteHook(nil)
        var forged = Self.card()
        forged.scope = "/p/elsewhere"
        await #expect(throws: (any Error).self) {
            try await service.answerApproval(forged, session: SessionID("ses_a"), approved: true, always: true)
        }
        #expect(service.approvedProjects.isEmpty)
    }

    /// N24: the decision is recorded but the thread cannot be woken (opencode offline): the answer throws so the
    /// card stays, and answering it again once opencode is back wakes the thread.
    @Test func aFailedWakeKeepsTheCardAndCanBeAnsweredAgain() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let service = await fixture.service()
        struct Offline: Error {}
        service.wake = { _, _, _ in throw Offline() }
        await #expect(throws: Offline.self) {
            try await service.answerApproval(Self.card(), session: SessionID("ses_a"), approved: true, always: false)
        }
        let woken = Mutex<[String]>([])
        service.wake = { session, _, _ in woken.withLock { $0.append(session.rawValue) } }
        try await service.answerApproval(Self.card(), session: SessionID("ses_a"), approved: true, always: false)
        #expect(woken.withLock { $0 } == ["ses_a"])
        #expect(service.approvedSessions["ses_a"] == Self.directory)
    }

    @Test func aRevocationThatCannotBeSavedStaysInForceAcrossRelaunch() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let service = await fixture.service()
        try await service.answerApproval(Self.card(), session: SessionID("ses_a"), approved: true, always: true)
        try #require(service.settings.enabled, "a fresh defaults suite has the shared Chrome on")
        #expect(service.access(session: "ses_x", directory: Self.directory) == .allowed)
        await fixture.store.setWriteHook { _ in throw CancellationError() }
        let saved = await service.revokeProject(Self.directory)
        #expect(!saved, "the failure is reported")
        #expect(service.lastError != nil)
        #expect(service.pendingRevocations.contains(Self.directory))
        #expect(!service.approvedProjects.contains(Self.directory))
        #expect(service.access(session: "ses_x", directory: Self.directory) == .needsApproval)
        #expect(try await fixture.store.grants(.browserMCP).contains(Self.directory), "the stored grant is still there")
        // Relaunch with a still-failing store: the grant is not reloaded.
        let stillFailing = await fixture.service()
        #expect(!stillFailing.approvedProjects.contains(Self.directory))
        #expect(stillFailing.pendingRevocations.contains(Self.directory))
        // Relaunch once writes work again: the delete is retried and the pending record cleared.
        await fixture.store.setWriteHook(nil)
        let healed = await fixture.service()
        #expect(!healed.approvedProjects.contains(Self.directory))
        #expect(healed.pendingRevocations.isEmpty)
        #expect(try await fixture.store.grants(.browserMCP).isEmpty)
    }

    /// NF10: settings and the tools cache live in the injected defaults, never `UserDefaults.standard`.
    @Test func settingsAndToolsCacheUseTheInjectedDefaults() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        var off = SharedBrowserSettings()
        off.enabled = false
        off.idleMinutes = 37
        off.save(fixture.defaults)
        let service = await fixture.service()
        #expect(service.settings == off, "read from the injected suite")
        var changed = off
        changed.idleMinutes = 41
        await service.update(changed)
        #expect(SharedBrowserSettings.load(fixture.defaults).idleMinutes == 41, "written to the injected suite")
        SharedBrowserService.saveCachedTools([Self.navigate], to: fixture.defaults)
        #expect(SharedBrowserService.loadCachedTools(from: fixture.defaults).map(\.name) == ["navigate"])
    }

    /// NF11: archiving a thread closes the tabs it opened (not the one it shares) when the setting is on; off, nothing.
    @Test func archivingAThreadClosesItsTabs() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let service = await fixture.service()
        let closing = Mutex<[[String]]>([])
        let (closed, closedNow) = AsyncStream.makeStream(of: Void.self)
        service.closeThreadTabs = { tabs, _, _ in
            closing.withLock { $0.append(tabs) }
            closedNow.yield()
            return tabs
        }
        var binding = BrowserBinding(sessionID: "ses_a", project: Self.directory, group: BrowserNaming.group(sessionID: "ses_a"))
        binding.remember("\(binding.group)-2")
        binding.remember("\(binding.group)-3")
        binding.selectedTab = "\(binding.group)-2"
        await service.save(binding)
        await service.share(tab: "\(binding.group)-3", from: "ses_a", to: "ses_b")
        func session(_ id: String, archived: Bool) -> Session {
            Session(id: SessionID(id), projectID: ProjectID("p"), directory: Self.directory, created: Timestamp(milliseconds: 0),
                    updated: Timestamp(milliseconds: archived ? 2 : 1), archivedAt: archived ? Timestamp(milliseconds: 2) : nil)
        }
        var batch = StoreBatch()
        batch.sessions = [session("ses_a", archived: false)]
        try await fixture.store.apply(batch)
        batch.sessions = [session("ses_a", archived: true)]
        try await fixture.store.apply(batch)
        var events = closed.makeAsyncIterator()
        _ = await events.next()  // archived: the tabs are being closed
        #expect(closing.withLock { $0 } == [[binding.mainTab, "\(binding.group)-2"]])
        // The binding is saved right after (the same main-actor step once the close returns).
        for _ in 0..<1_000 where service.bindings["ses_a"]?.tabs.count == 3 { await Task.yield() }
        #expect(service.bindings["ses_a"]?.tabs == [binding.mainTab, "\(binding.group)-3"])
        #expect(service.bindings["ses_a"]?.selectedTab == binding.mainTab)
        // Turned off: an archived thread keeps its tabs.
        var settings = service.settings
        settings.closeTabsWhenDone = false
        await service.update(settings)
        batch.sessions = [session("ses_c", archived: false)]
        try await fixture.store.apply(batch)
        await service.save(BrowserBinding(sessionID: "ses_c", project: Self.directory, group: BrowserNaming.group(sessionID: "ses_c")))
        batch.sessions = [session("ses_c", archived: true)]
        try await fixture.store.apply(batch)
        await service.threadEnded("ses_c")
        #expect(closing.withLock { $0.count } == 1)
    }

    // MARK: NF11 residuals (v1.0.1 verification)

    static func session(_ id: String, archived: Bool, updated: Double = 1) -> Session {
        Session(id: SessionID(id), projectID: ProjectID("p"), directory: directory, created: Timestamp(milliseconds: 0),
                updated: Timestamp(milliseconds: archived ? updated + 1 : updated), archivedAt: archived ? Timestamp(milliseconds: updated + 1) : nil)
    }

    /// Records closes and lets the test wait for each one.
    final class CloseRecorder: Sendable {
        let closing = Mutex<[String: [String]]>([:])
        let stream: AsyncStream<String>
        let continuation: AsyncStream<String>.Continuation
        init() { (stream, continuation) = AsyncStream.makeStream(of: String.self) }
        @MainActor func install(on service: SharedBrowserService) {
            service.closeThreadTabs = { [self] tabs, session, _ in
                closing.withLock { $0[session] = tabs }
                continuation.yield(session)
                return tabs
            }
        }
    }

    @MainActor func boundService(_ fixture: Fixture, sessions: [String]) async -> (SharedBrowserService, CloseRecorder) {
        let service = await fixture.service()
        let recorder = CloseRecorder()
        recorder.install(on: service)
        for id in sessions {
            await service.save(BrowserBinding(sessionID: id, project: Self.directory, group: BrowserNaming.group(sessionID: id)))
        }
        // The tracker is seeded from the store before it follows changes.
        for _ in 0..<20_000 where service.threadEnds.isEmpty { await Task.yield() }
        return (service, recorder)
    }

    /// NF11: threads already in the store at launch (loaded from the cache, so they emit no change until they change)
    /// close their tabs when archived or deleted afterwards.
    @Test func threadsThatExistedBeforeLaunchCloseTheirTabsWhenArchivedOrDeleted() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        var batch = StoreBatch()
        batch.sessions = [Self.session("ses_a", archived: false), Self.session("ses_b", archived: false)]
        try await fixture.store.apply(batch)
        let (service, recorder) = await boundService(fixture, sessions: ["ses_a", "ses_b"])
        #expect(!service.threadEnds.isEmpty, "seeded")
        var events = recorder.stream.makeAsyncIterator()
        batch = StoreBatch()
        batch.sessions = [Self.session("ses_a", archived: true)]
        try await fixture.store.apply(batch)
        #expect(await events.next() == "ses_a")
        batch = StoreBatch()
        batch.removedSessions = [SessionID("ses_b")]
        try await fixture.store.apply(batch)
        #expect(await events.next() == "ses_b")
        #expect(recorder.closing.withLock { $0["ses_b"] } == [BrowserNaming.mainTab(group: BrowserNaming.group(sessionID: "ses_b"))])
    }

    /// NF11: an archive lost in a change-stream overflow is found by reconciling with every thread.
    @Test func anArchiveLostInAnOverflowStillClosesTheTabs() async throws {
        let fixture = try Fixture.make(subscriberLimit: 4)
        defer { fixture.cleanup() }
        var batch = StoreBatch()
        batch.sessions = [Self.session("ses_a", archived: false)]
        try await fixture.store.apply(batch)
        let (service, recorder) = await boundService(fixture, sessions: ["ses_a"])
        var events = recorder.stream.makeAsyncIterator()
        // More distinct threads in one change than a subscriber holds: the change set is replaced by "overflowed".
        batch = StoreBatch()
        batch.sessions = [Self.session("ses_a", archived: true)]
            + (0..<(fixture.store.changes.subscriberLimit + 1)).map { Self.session("ses_fill\($0)", archived: false) }
        try await fixture.store.apply(batch)
        #expect(await events.next() == "ses_a")
        withExtendedLifetime(service) {}
    }

    /// NF11: after shutdown, a new start follows thread ends again (the follower flag is reset).
    @Test func aRestartedServiceFollowsThreadEndsAgain() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        var batch = StoreBatch()
        batch.sessions = [Self.session("ses_a", archived: false)]
        try await fixture.store.apply(batch)
        let (service, recorder) = await boundService(fixture, sessions: ["ses_a"])
        await service.shutdown()
        #expect(service.threadEnds.isEmpty)
        await service.start()
        for _ in 0..<20_000 where service.threadEnds.isEmpty { await Task.yield() }
        var events = recorder.stream.makeAsyncIterator()
        batch = StoreBatch()
        batch.sessions = [Self.session("ses_a", archived: true)]
        try await fixture.store.apply(batch)
        #expect(await events.next() == "ses_a")
    }
}
