import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// Deep review 1, C6: a delivery-unknown send survives a quit. It is recorded before its first dispatch, restored at
/// launch as a card, checked against the original ID once connected, and retried only under that ID.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct OutboxTests {
    struct Fixture {
        let harness: MockHarness
        let url: URL
        let box: EndpointBox
        var sessionID: SessionID

        @MainActor func engine() throws -> Engine {
            var configuration = EngineConfiguration(server: .dynamic { [box] in box.get() }, store: .file(url))
            configuration.eventBackoff = BackoffPolicy(initial: .milliseconds(20), maximum: .milliseconds(200))
            configuration.writeInterval = .milliseconds(20)
            return try Engine(configuration: configuration)
        }

        func remove() {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
    }

    static let attachment = PromptAttachments(files: [PromptAttachments.File(uri: "file:///tmp/bellocode-attachments/att_1/notes.txt", name: "notes.txt", mime: "text/plain")])

    /// First run: the send's answers are lost and opencode cannot be asked, then BelloCode quits.
    func firstRunWithUnknownSend(promptFault: HTTPFault.Action) async throws -> (Fixture, MessageID) {
        let harness = try await MockHarness.start()
        let url = FileManager.default.temporaryDirectory.appending(path: "outbox-\(UUID().uuidString).sqlite")
        let box = EndpointBox(harness.connection)
        var fixture = Fixture(harness: harness, url: url, box: box, sessionID: SessionID("ses_x"))
        let engine = try fixture.engine()
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        fixture.sessionID = session.id
        let thread = engine.openThread(session.id)
        try await waitUntil("ready") { thread.phase == .ready }
        let base = "/api/session/\(session.id.rawValue)"
        await harness.server.injectHTTPFault(HTTPFault(method: "POST", pathPrefix: "\(base)/prompt", action: promptFault, count: nil))
        await harness.server.injectHTTPFault(HTTPFault(method: "GET", pathPrefix: "\(base)/message/", action: .resetConnection, count: nil))
        await harness.server.injectHTTPFault(HTTPFault(method: "GET", pathPrefix: "\(base)/inbox", action: .resetConnection, count: nil))
        #expect(await thread.send("ship the release", attachments: Self.attachment) == nil)
        #expect(thread.lastError == .deliveryUnknown)
        let held = try #require(thread.unconfirmedSends.first)
        let stored = try await engine.store.outbox()
        #expect(stored.map(\.id) == [held.id])
        #expect(stored.first?.state == .unknown)
        #expect(stored.first?.attachmentFiles.map(\.path) == ["/tmp/bellocode-attachments/att_1/notes.txt"])
        thread.close()
        await engine.stop()
        await harness.server.clearHTTPFaults()
        return (fixture, held.id)
    }

    @Test func anAdmittedSendIsFoundUnderItsOriginalIDAfterRelaunch() async throws {
        let (fixture, id) = try await firstRunWithUnknownSend(promptFault: .dropResponse)
        defer { fixture.remove() }
        fixture.box.set(nil)  // relaunch with the server not reachable yet
        let engine = try fixture.engine()
        await engine.start()
        let thread = engine.openThread(fixture.sessionID)
        try await waitUntil("card restored") { thread.unconfirmedSends.map(\.id) == [id] }
        #expect(thread.unconfirmedSends.first?.state == .unknown)
        #expect(thread.unconfirmedSends.first?.text == "ship the release")
        #expect(await engine.outboxAttachmentFiles().map(\.path) == ["/tmp/bellocode-attachments/att_1/notes.txt"])
        // Connected: the check finds it admitted; no second send.
        fixture.box.set(fixture.harness.connection)
        try await waitUntil("settled", timeout: .seconds(30)) { thread.unconfirmedSends.isEmpty }
        #expect(try await engine.store.outbox().isEmpty)
        await fixture.harness.server.waitUntilIdle(fixture.sessionID.rawValue)
        let users = try await fixture.harness.listedMessages(fixture.sessionID).filter { $0.kind.typeName == "user" }
        #expect(users.map(\.id) == [id], "admitted once, under the original ID")
        thread.close()
        await engine.stop()
        await fixture.harness.stop()
    }

    @Test func aSendNeverAdmittedIsRetriedUnderItsOriginalIDAfterRelaunch() async throws {
        let (fixture, id) = try await firstRunWithUnknownSend(promptFault: .resetConnection)
        defer { fixture.remove() }
        let engine = try fixture.engine()
        await engine.start()
        let thread = engine.openThread(fixture.sessionID)
        try await waitUntil("live") { engine.root.connection == .live }
        try await waitUntil("checked, still unknown") { thread.unconfirmedSends.first?.state == .unknown }
        #expect(await fixture.harness.server.promptBodies().isEmpty, "a restored send is never resent on its own")
        let deadline = ContinuousClock.now + .seconds(10)
        while !thread.unconfirmedSends.isEmpty, ContinuousClock.now < deadline {
            if thread.unconfirmedSends.first?.state == .unknown { await thread.retryUnconfirmed(id) } else { await Task.yield() }
        }
        try await waitUntil("admitted") { thread.unconfirmedSends.isEmpty }
        #expect(try await engine.store.outbox().isEmpty)
        await fixture.harness.server.waitUntilIdle(fixture.sessionID.rawValue)
        let users = try await fixture.harness.listedMessages(fixture.sessionID).filter { $0.kind.typeName == "user" }
        #expect(users.map(\.id) == [id])
        thread.close()
        await engine.stop()
        await fixture.harness.stop()
    }

    @Test func aRefusedSendIsKeptAcrossRelaunchUntilDiscarded() async throws {
        let (fixture, id) = try await firstRunWithUnknownSend(promptFault: .resetConnection)
        defer { fixture.remove() }
        do {
            let engine = try fixture.engine()
            await engine.start()
            let thread = engine.openThread(fixture.sessionID)
            try await waitUntil("live") { engine.root.connection == .live }
            await fixture.harness.server.injectHTTPFault(
                .status(400, method: "POST", pathPrefix: "/api/session/\(fixture.sessionID.rawValue)/prompt", tag: "InvalidRequestError", count: nil))
            // The launch check may be running (the card shows "Checking…" and Retry is disabled): retry once it ends.
            func notSent() -> Bool { if case .notSent = thread.unconfirmedSends.first?.state { true } else { false } }
            let deadline = ContinuousClock.now + .seconds(10)
            while !notSent(), ContinuousClock.now < deadline {
                if thread.unconfirmedSends.first?.state == .unknown { await thread.retryUnconfirmed(id) } else { await Task.yield() }
            }
            #expect(notSent(), "not sent")
            thread.close()
            await engine.stop()
        }
        let engine = try fixture.engine()
        await engine.start()
        let thread = engine.openThread(fixture.sessionID)
        try await waitUntil("still shown as not sent") { if case .notSent = thread.unconfirmedSends.first?.state { true } else { false } }
        await thread.discardUnconfirmed(id)
        #expect(thread.unconfirmedSends.isEmpty)
        #expect(try await engine.store.outbox().isEmpty)
        thread.close()
        await engine.stop()
        await fixture.harness.stop()
    }

    @Test func anAdmittedSendLeavesNoOutboxEntry() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        let thread = engine.openThread(session.id)
        try await waitUntil("ready") { thread.phase == .ready }
        #expect(await thread.send("hello") != nil)
        #expect(try await engine.store.outbox().isEmpty)
        thread.close()
        await engine.stop()
        await harness.stop()
    }
}
