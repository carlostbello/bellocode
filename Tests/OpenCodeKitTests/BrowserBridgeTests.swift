import Foundation
import MockOpenCode
import Synchronization
import Testing

@testable import OpenCodeKit

private typealias JSON = OpenCodeKit.JSONValue

@Suite("Browser contract wire format", .timeLimit(.minutes(3)))
struct BrowserContractTests {
    @Test func controlEventsDecode() {
        #expect(BrowserControl(json: ["type": "attached", "connectionID": "c", "version": 4]) == .attached(connectionID: "c", version: 4))
        #expect(BrowserControl(json: ["type": "command", "connectionID": "c", "requestID": "r"]) == .command(connectionID: "c", requestID: "r"))
        #expect(BrowserControl(json: ["type": "cancel", "connectionID": "c", "requestID": "r"]) == .cancel(connectionID: "c", requestID: "r"))
        #expect(BrowserControl(json: ["type": "future", "connectionID": "c"]) == .unrecognized(connectionID: "c", type: "future"))
        #expect(BrowserControl(json: ["type": "command", "connectionID": "c"]) == nil)
        let frame = Data(#"{"id":"evt_1","type":"rpc.experimental.browser.control","data":{"type":"attached","connectionID":"x","version":4}}"#.utf8)
        #expect(BrowserControl(eventJSON: frame) == .attached(connectionID: "x", version: 4))
        let envelope = OpenCodeEventDecoder().decode(frame)
        #expect(envelope.browserControl == .attached(connectionID: "x", version: 4))
    }

    @Test func outcomesEncodeToTheContractShape() throws {
        let file = BrowserFile(id: "file_00000000-0000-0000-0000-000000000000", name: "s.png", mime: "image/png", data: Data([1, 2]))
        let success = BrowserOutcome.success(BrowserResult(value: ["generation": 3], files: [file]))
        #expect(success.json == [
            "type": "success",
            "result": ["value": ["generation": 3], "files": [["id": "file_00000000-0000-0000-0000-000000000000", "name": "s.png", "mime": "image/png", "data": "AQI="]]],
        ])
        #expect(BrowserOutcome(json: success.json) == success)
        // Integers stay integers on the wire: the plugin validates Schema.Int fields.
        #expect(String(decoding: try JSON.number(3).encodedData(), as: UTF8.self) == "3")
        let failure = BrowserOutcome.failure(BrowserFailure(.unsupported, "no"))
        #expect(failure.json == ["type": "failure", "code": "unsupported", "message": "no"])
        let command = try BrowserCommand(json: ["action": ["type": "click", "tabID": "tab_x", "ref": "e1"], "generation": 2, "files": []])
        #expect(command.type == "click" && command.tabID == "tab_x" && command.generation == 2)
        #expect(throws: BrowserFailure.self) { try BrowserCommand(json: ["files": []]) }
    }

    @Test func tabIDsMatchTheContractPattern() {
        let id = BrowserContract.newTabID()
        #expect(id.wholeMatch(of: /tab_[a-f0-9-]{36}/) != nil)
        #expect(BrowserContract.isTabID(id))
        #expect(!BrowserContract.isTabID("tab_XYZ"))
        #expect(BrowserContract.newFileID().wholeMatch(of: /file_[a-f0-9-]{36}/) != nil)
    }

    @Test func inventoryRoundTripsAndBoundsStrings() {
        let tab = BrowserTabInfo(
            id: "tab_1", url: String(repeating: "u", count: 20_000), title: "T", loading: false, canGoBack: true,
            canGoForward: false, generation: 2)
        let inventory = BrowserInventory(tabs: [tab], focusedTabID: "tab_1")
        #expect(inventory.json["tabs"]?.arrayValue?.first?["url"]?.stringValue?.count == BrowserContract.maxURL)
        let decoded = BrowserInventory(json: inventory.json)
        #expect(decoded?.focusedTabID == "tab_1" && decoded?.tabs.first?.generation == 2)
        #expect(BrowserInventory().json["focusedTabID"] == .null)
    }

    @Test func oversizedResultsBecomeTooLarge() {
        let big = BrowserOutcome.success(BrowserResult(value: .string(String(repeating: "x", count: BrowserContract.maxResultCharacters + 10))))
        #expect(BrowserAttachment.bounded(big, operation: "snapshot").failure?.code == .tooLarge)
        let small = BrowserOutcome.success(BrowserResult(value: "ok"))
        #expect(BrowserAttachment.bounded(small, operation: "snapshot") == small)
    }

    @Test func rpcErrorsMapToAttachmentEnds() {
        #expect(BrowserAttachment.endReason(for: .transport("x")) == .unavailable(message: "The server is not reachable.", retryable: true))
        if case .incompatible = BrowserAttachment.endReason(for: .rejected(status: 400, tag: "InvalidRequestError", message: "Expected 4, got 5")) {} else {
            Issue.record("a schema rejection is a version mismatch")
        }
        if case .unavailable(_, false) = BrowserAttachment.endReason(for: .rpc(type: "unavailable", message: "Session not found.")) {} else {
            Issue.record("a plugin refusal is not retried")
        }
        #expect(BrowserAttachment.endReason(for: .cancelled) == .closed)
        // The real 2.3.0 answer to another contract version (seen in BrowserDemo --e2e).
        let real = BrowserAttachment.endReason(for: .rpc(type: "rpc.invalid_input", message: "Expected 4\n  at [\"version\"]"))
        if case .incompatible(let version, _) = real { #expect(version == 4) } else { Issue.record("expected incompatible, got \(real)") }
    }
}

/// A lock-protected value shared with sendable closures.
private final class Locked<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>
    init(_ value: Value) { storage = Mutex(value) }
    func withLock<R: Sendable>(_ body: (inout Value) -> R) -> R { storage.withLock { body(&$0) } }
}

/// One mock server, a client, a session, an event hub routing browser controls to registered attachments.
private final class BridgeHarness: Sendable {
    let server: MockOpenCodeServer
    let client: OpenCodeClient
    let sessionID: String
    let hub: EventHub
    let routes: Locked<[String: BrowserAttachment]>
    let events = Locked<[BrowserAttachmentEvent]>([])
    let pump: Task<Void, Never>

    private init(server: MockOpenCodeServer, client: OpenCodeClient, sessionID: String, hub: EventHub, subscription: EventSubscription, routes: Locked<[String: BrowserAttachment]>) {
        self.server = server
        self.client = client
        self.sessionID = sessionID
        self.hub = hub
        self.routes = routes
        pump = Task { [routes] in
            for await message in subscription {
                guard case .event(let envelope) = message, let control = envelope.browserControl, let id = control.connectionID,
                    let attachment = routes.withLock({ $0[id] })
                else { continue }
                await attachment.receive(control)
            }
        }
    }

    static func start() async throws -> BridgeHarness {
        let server = MockOpenCodeServer(scenario: .empty(), options: .testing)
        let endpoint = try await server.start()
        let client = OpenCodeClient(
            connection: ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? "")))
        let session = try await client.createSession(SessionCreateRequest(directory: "/tmp/mock-project", title: "browser"))
        let hub = EventHub(connector: URLSessionEventStreamConnector { client })
        let subscription = await hub.subscribe(.types([BrowserContract.controlEventType]))
        await hub.start()
        // Wait for the stream to open so no control is missed.
        for _ in 0..<200 {
            if case .connected = await hub.connectionState { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let routes = Locked<[String: BrowserAttachment]>([:])
        return BridgeHarness(server: server, client: client, sessionID: session.id, hub: hub, subscription: subscription, routes: routes)
    }

    func attachment(
        tabs: [BrowserTabInfo] = [], timeout: Duration = BrowserContract.defaultCommandTimeout,
        perform: @escaping BrowserAttachment.Perform
    ) -> BrowserAttachment {
        let inventory = BrowserInventory(tabs: tabs, focusedTabID: tabs.first?.id)
        let client = self.client
        let attachment = BrowserAttachment(
            sessionID: sessionID, directory: "/tmp/mock-project", client: { client }, inventory: { inventory }, perform: perform,
            observer: { [events] event in events.withLock { $0.append(event) } }, commandTimeout: { _ in timeout })
        routes.withLock { $0[attachment.connectionID] = attachment }
        return attachment
    }

    func stop() async {
        pump.cancel()
        await hub.stop()
        await server.stop()
    }
}

private let sampleTab = BrowserTabInfo(
    id: "tab_00000000-0000-0000-0000-000000000001", url: "http://127.0.0.1:1/form.html", title: "Form", loading: false,
    canGoBack: false, canGoForward: false, generation: 1)

@Suite("Browser attachment against the mock", .serialized, .timeLimit(.minutes(3)))
struct BrowserAttachmentTests {
    @Test func attachPublishesStateAndRunsCommands() async throws {
        let harness = try await BridgeHarness.start()
        let attachment = harness.attachment(tabs: [sampleTab]) { command in
            .success(BrowserResult(value: ["echo": .string(command.type), "generation": .number(Double(command.generation ?? -1))]))
        }
        try await attachment.start()
        #expect(await attachment.isAttached)
        let mock = await harness.server.browserAttachment(for: harness.sessionID)
        #expect(mock?.connectionID == attachment.connectionID)
        #expect(mock?.state?["tabs"]?.arrayValue?.first?["id"]?.stringValue == sampleTab.id)
        // The plugin grants the browser tools on attach.
        let permissions = await harness.server.session(harness.sessionID)?.permissions?.arrayValue ?? []
        #expect(permissions.contains { $0["action"]?.stringValue == "browser" && $0["effect"]?.stringValue == "allow" })

        let outcome = await harness.server.issueBrowserCommand(
            sessionID: harness.sessionID, action: ["type": "snapshot", "tabID": .string(sampleTab.id)])
        #expect(outcome.value?["echo"]?.stringValue == "snapshot")
        #expect(outcome.value?["generation"]?.intValue == 1, "the command carries the published generation")

        await attachment.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await harness.server.browserAttachment(for: harness.sessionID) == nil, "closing attach detaches")
        let after = await harness.server.session(harness.sessionID)?.permissions?.arrayValue ?? []
        #expect(!after.contains { $0["action"]?.stringValue == "browser" }, "detaching revokes the tools")
        await harness.stop()
    }

    @Test func serverCancelStopsTheCommandWithoutAReply() async throws {
        let harness = try await BridgeHarness.start()
        let started = Locked(false)
        let sawCancellation = Locked(false)
        let attachment = harness.attachment(tabs: [sampleTab]) { _ in
            started.withLock { $0 = true }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                sawCancellation.withLock { $0 = true }
            }
            return .success(BrowserResult(value: "late"))
        }
        try await attachment.start()
        let outcome = await harness.server.issueBrowserCommand(
            sessionID: harness.sessionID, action: ["type": "wait", "tabID": .string(sampleTab.id)], timeout: .milliseconds(400))
        #expect(outcome == .timedOut)
        try await Task.sleep(for: .milliseconds(200))
        #expect(started.withLock { $0 })
        #expect(sawCancellation.withLock { $0 }, "the server's cancel control cancels the running task")
        #expect(await attachment.runningRequestIDs.isEmpty)
        await attachment.stop()
        await harness.stop()
    }

    @Test func localCancelAnswersCancelled() async throws {
        let harness = try await BridgeHarness.start()
        let attachment = harness.attachment(tabs: [sampleTab]) { _ in
            try? await Task.sleep(for: .seconds(30))
            return .success(BrowserResult(value: "late"))
        }
        try await attachment.start()
        async let outcome = harness.server.issueBrowserCommand(sessionID: harness.sessionID, action: ["type": "click", "tabID": .string(sampleTab.id), "ref": "e1"])
        try await eventually(timeout: .seconds(30)) { await !attachment.runningRequestIDs.isEmpty }
        await attachment.cancelAll()
        let result = await outcome
        #expect(result.failureCode == "cancelled")
        if case .failure(_, let message) = result { #expect(message.contains("user stopped")) } else {
            Issue.record("expected a failure, got \(result)")
        }
        await attachment.stop()
        await harness.stop()
    }

    @Test func ourDeadlineAnswersTimeoutBeforeTheServer() async throws {
        let harness = try await BridgeHarness.start()
        let attachment = harness.attachment(tabs: [sampleTab], timeout: .milliseconds(150)) { _ in
            try? await Task.sleep(for: .seconds(30))
            return .success(BrowserResult(value: "late"))
        }
        try await attachment.start()
        let outcome = await harness.server.issueBrowserCommand(
            sessionID: harness.sessionID, action: ["type": "wait", "tabID": .string(sampleTab.id)], timeout: .seconds(5))
        #expect(outcome.failureCode == "timeout")
        await attachment.stop()
        await harness.stop()
    }

    @Test func secondAttachReplacesTheFirst() async throws {
        let harness = try await BridgeHarness.start()
        let first = harness.attachment(tabs: [sampleTab]) { _ in .success(BrowserResult(value: "first")) }
        try await first.start()
        let second = harness.attachment(tabs: [sampleTab]) { _ in .success(BrowserResult(value: "second")) }
        try await second.start()
        try await eventually(timeout: .seconds(30)) { await first.end != nil }
        #expect(await first.end == .replaced)
        #expect(await second.isAttached)
        let outcome = await harness.server.issueBrowserCommand(sessionID: harness.sessionID, action: ["type": "tabs.list"])
        #expect(outcome.value == "second")
        await second.stop()
        await harness.stop()
    }

    @Test func serverCloseEndsTheAttachmentAndFailsPendingWork() async throws {
        let harness = try await BridgeHarness.start()
        let attachment = harness.attachment(tabs: [sampleTab]) { _ in
            try? await Task.sleep(for: .seconds(30))
            return .success(BrowserResult(value: "late"))
        }
        try await attachment.start()
        async let pending = harness.server.issueBrowserCommand(sessionID: harness.sessionID, action: ["type": "tabs.list"])
        try await eventually(timeout: .seconds(30)) { await !attachment.runningRequestIDs.isEmpty }
        await harness.server.closeBrowserAttachment(sessionID: harness.sessionID)
        #expect(await pending == .disconnected)
        try await eventually(timeout: .seconds(30)) { await attachment.end != nil }
        #expect(await attachment.end == .closed)
        #expect(await attachment.runningRequestIDs.isEmpty, "ending cancels running work")
        await harness.stop()
    }

    @Test func versionMismatchIsIncompatible() async throws {
        let harness = try await BridgeHarness.start()
        await harness.server.setBrowserContractVersion(5)
        let attachment = harness.attachment { _ in .success(BrowserResult(value: "x")) }
        do {
            try await attachment.start(readyTimeout: .seconds(5))
            Issue.record("attach should fail")
        } catch {
            if case .incompatible = error {} else { Issue.record("expected incompatible, got \(error)") }
        }
        // A server that accepts attach but announces another version.
        await harness.server.setBrowserContractVersion(4)
        await harness.server.setBrowserAnnouncedVersion(5)
        let announced = harness.attachment { _ in .success(BrowserResult(value: "x")) }
        do {
            try await announced.start(readyTimeout: .seconds(5))
            Issue.record("attach should fail")
        } catch {
            #expect(error == .incompatible(serverVersion: 5, message: "The server's browser plugin speaks contract version 5; this BelloCode speaks 4."))
        }
        await harness.stop()
    }

    @Test func unknownSessionIsUnavailableAndNotRetryable() async throws {
        let harness = try await BridgeHarness.start()
        let client = harness.client
        let attachment = BrowserAttachment(
            sessionID: "ses_missing", directory: "/tmp/mock-project", client: { client }, inventory: { BrowserInventory() },
            perform: { _ in .success(BrowserResult(value: "x")) })
        do {
            try await attachment.start(readyTimeout: .seconds(5))
            Issue.record("attach should fail")
        } catch {
            #expect(error == .unavailable(message: "Session not found.", retryable: false))
        }
        await harness.stop()
    }

    @Test func instructionEntriesRoundTrip() async throws {
        let harness = try await BridgeHarness.start()
        try await harness.client.putInstructionEntry(sessionID: harness.sessionID, key: "bellocode.browser", value: "guidance")
        let entries = try await harness.client.instructionEntries(sessionID: harness.sessionID)
        #expect(entries == [InstructionEntry(key: "bellocode.browser", value: "guidance")])
        try await harness.client.deleteInstructionEntry(sessionID: harness.sessionID, key: "bellocode.browser")
        #expect(try await harness.client.instructionEntries(sessionID: harness.sessionID).isEmpty)
        await harness.stop()
    }
}
