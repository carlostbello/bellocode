import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// A host with one shared tab that answers every command and records what it ran.
@MainActor
final class FakeBrowserHost: BrowserBridgeHost {
    var tabs: [BrowserTabInfo]
    var performed: [String] = []
    var delay: Duration?

    init(tabs: [BrowserTabInfo] = [FakeBrowserHost.tab]) { self.tabs = tabs }

    static let tab = BrowserTabInfo(
        id: "tab_00000000-0000-0000-0000-00000000000a", url: "http://127.0.0.1:1/", title: "Fixture", loading: false,
        canGoBack: false, canGoForward: false, generation: 1)

    func browserInventory() -> BrowserInventory { BrowserInventory(tabs: tabs, focusedTabID: tabs.first?.id) }

    func perform(_ command: BrowserCommand) async -> BrowserOutcome {
        performed.append(command.type)
        if let delay {
            do { try await Task.sleep(for: delay) } catch {
                return .failure(BrowserFailure(.cancelled, "cancelled"))
            }
        }
        return .success(BrowserResult(value: ["ran": .string(command.type)]))
    }
}

@MainActor
@Suite("Browser bridge service", .serialized)
struct BrowserBridgeServiceTests {
    @MainActor struct Fixture {
        let harness: MockHarness
        let engine: Engine
        let sessionID: SessionID

        static func start() async throws -> Fixture {
            let harness = try await MockHarness.start()
            let engine = try makeEngine(harness)
            await engine.start()
            try await waitUntil("live") { engine.root.connection == .live }
            let session = try await engine.createThread(in: "/tmp/mock-project", title: "browser")
            return Fixture(harness: harness, engine: engine, sessionID: session.id)
        }

        func stop() async {
            await engine.stop()
            await harness.stop()
        }
    }

    @Test func bindAttachesPublishesAndWritesGuidance() async throws {
        let fixture = try await Fixture.start()
        let host = FakeBrowserHost()
        let service = fixture.engine.browser
        service.bind(fixture.sessionID, directory: "/tmp/mock-project", host: host, guidance: "Use the WebKit browser.")
        let model = service.model(for: fixture.sessionID)
        try await waitUntil("attached") { model.status == .attached }
        let server = fixture.harness.server
        let sid = fixture.sessionID.rawValue
        try await waitFor("state published") { await server.browserAttachment(for: sid)?.state != nil }
        try await waitFor("guidance written") {
            await server.instructionEntries(for: sid)[BrowserBridgeService.guidanceKey] == .string("Use the WebKit browser.")
        }
        let outcome = await server.issueBrowserCommand(sessionID: sid, action: ["type": "snapshot", "tabID": .string(FakeBrowserHost.tab.id)])
        #expect(outcome.value?["ran"]?.stringValue == "snapshot")
        #expect(host.performed == ["snapshot"])
        #expect(model.commandCount == 1)

        // Turning control off detaches (the tools go away) and removes the guidance; the setting persists.
        service.setControlEnabled(false, for: fixture.sessionID)
        #expect(model.status == .disabled)
        try await waitFor("detached") { await server.browserAttachment(for: sid) == nil }
        try await waitFor("guidance removed") { await server.instructionEntries(for: sid).isEmpty }
        let notAttached = await server.issueBrowserCommand(sessionID: sid, action: ["type": "tabs.list"])
        #expect(notAttached == .notAttached)
        try await waitFor("setting saved") {
            (try? await fixture.engine.store.preference(BrowserBridgeService.disabledKey, as: [String].self)) == [sid]
        }
        service.setControlEnabled(true, for: fixture.sessionID)
        try await waitUntil("re-attached") { model.status == .attached }
        service.unbind(fixture.sessionID)
        #expect(model.status == .off)
        try await waitFor("unbind detaches") { await server.browserAttachment(for: sid) == nil }
        await fixture.stop()
    }

    @Test func replacedIsShownAndNotReclaimedUntilReconnect() async throws {
        let fixture = try await Fixture.start()
        let host = FakeBrowserHost()
        let service = fixture.engine.browser
        service.bind(fixture.sessionID, directory: "/tmp/mock-project", host: host)
        let model = service.model(for: fixture.sessionID)
        try await waitUntil("attached") { model.status == .attached }
        // Another desktop attaches to the same session.
        let client = fixture.harness.client
        let other = BrowserAttachment(
            sessionID: fixture.sessionID.rawValue, directory: "/tmp/mock-project", client: { client },
            inventory: { BrowserInventory() }, perform: { _ in .success(BrowserResult(value: "other")) })
        let attach = Task { try? await other.start(readyTimeout: .seconds(2)) }
        try await waitUntil("replaced") { model.status == .replaced }
        #expect(model.status.needsAttention)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.status == .replaced, "no automatic reclaim")
        await other.stop()
        attach.cancel()
        service.reconnect(fixture.sessionID)
        try await waitUntil("reconnected") { model.status == .attached }
        await fixture.stop()
    }

    @Test func serverCloseRetriesAndCancelReachesTheHost() async throws {
        let fixture = try await Fixture.start()
        let host = FakeBrowserHost()
        host.delay = .seconds(20)
        let service = fixture.engine.browser
        service.bind(fixture.sessionID, directory: "/tmp/mock-project", host: host)
        let model = service.model(for: fixture.sessionID)
        try await waitUntil("attached") { model.status == .attached }
        let server = fixture.harness.server
        let sid = fixture.sessionID.rawValue
        // The person presses Stop while a command runs: the agent gets `cancelled`.
        async let outcome = server.issueBrowserCommand(sessionID: sid, action: ["type": "click", "tabID": .string(FakeBrowserHost.tab.id), "ref": "e1"])
        try await waitUntil("running") { !model.running.isEmpty }
        service.cancelRunning(fixture.sessionID)
        #expect(await outcome.failureCode == "cancelled")
        try await waitUntil("idle") { model.running.isEmpty }
        // The plugin closes the attachment (for example after a reload): the service reattaches.
        await server.closeBrowserAttachment(sessionID: sid)
        try await waitUntil("retrying or attached again", timeout: .seconds(10)) {
            if case .retrying = model.status { return true }
            return false
        }
        try await waitUntil("attached again", timeout: .seconds(10)) { model.status == .attached }
        await fixture.stop()
    }

    @Test func incompatibleServerIsReportedAndNotRetried() async throws {
        let fixture = try await Fixture.start()
        await fixture.harness.server.setBrowserContractVersion(5)
        let service = fixture.engine.browser
        service.bind(fixture.sessionID, directory: "/tmp/mock-project", host: FakeBrowserHost())
        let model = service.model(for: fixture.sessionID)
        try await waitUntil("incompatible") {
            if case .incompatible = model.status { return true }
            return false
        }
        #expect(model.status.label == "Agent bridge incompatible")
        #expect(model.status.detail.contains("Browsing works"))
        await fixture.stop()
    }

    @Test func attachmentsAreBoundedAndTheOldestParks() async throws {
        let fixture = try await Fixture.start()
        let service = fixture.engine.browser
        var sessions: [SessionID] = []
        var hosts: [FakeBrowserHost] = []
        for index in 0...BrowserBridgeService.maxAttachments {
            let session = try await fixture.engine.createThread(in: "/tmp/mock-project", title: "b\(index)")
            let host = FakeBrowserHost()
            hosts.append(host)
            sessions.append(session.id)
            service.bind(session.id, directory: "/tmp/mock-project", host: host)
            try await Task.sleep(for: .milliseconds(5))
        }
        try await waitUntil("bounded") { service.attachedSessionIDs.count == BrowserBridgeService.maxAttachments }
        #expect(service.model(for: sessions[0]).status == .parked)
        // Showing the parked thread again reattaches it and parks the next oldest.
        service.bind(sessions[0], directory: "/tmp/mock-project", host: hosts[0])
        try await waitUntil("reattached") { service.model(for: sessions[0]).status == .attached }
        #expect(service.model(for: sessions[1]).status == .parked)
        await fixture.stop()
    }

    @Test func timeoutsStayBelowTheServerLimit() {
        #expect(BrowserBridgeService.timeout(for: BrowserCommand(action: ["type": "wait", "timeoutMs": 30_000])) == .seconds(35))
        #expect(BrowserBridgeService.timeout(for: BrowserCommand(action: ["type": "wait"])) == .seconds(15))
        #expect(BrowserBridgeService.timeout(for: BrowserCommand(action: ["type": "click"])) < BrowserContract.serverRequestTimeout)
    }
}
