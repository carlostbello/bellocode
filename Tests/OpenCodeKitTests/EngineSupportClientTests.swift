import Foundation
import Testing
@testable import OpenCodeKit

/// Client calls added for the Engine (M1-A): inbox, single message, view, agent and model switches.
@Suite("OpenCodeClient engine calls")
struct EngineSupportClientTests {
    private let connection = ServerConnection(
        baseURL: URL(string: "http://127.0.0.1:4096")!, credentials: ServerCredentials(password: "pw")
    )

    private func client(_ responses: FakeTransport.Response...) -> (OpenCodeClient, FakeTransport) {
        let transport = FakeTransport(responses)
        return (OpenCodeClient(connection: connection, transport: transport), transport)
    }

    private func body(_ request: URLRequest) -> String { String(decoding: request.httpBody ?? Data(), as: UTF8.self) }

    @Test func inboxListDecodesTextAndDelivery() async throws {
        let (client, transport) = client(.init(status: 200, body: #"""
            {"data":[{"id":"msg_1","sessionID":"ses_1","time":{"created":5},"type":"user","delivery":"queue",
            "payload":{"text":"next","files":[]}},
            {"id":"msg_2","sessionID":"ses_1","time":{"created":6},"type":"compaction","delivery":"steer","payload":{}}]}
            """#))
        let items = try await client.inbox(sessionID: "ses_1")
        #expect(items.map(\.id) == ["msg_1", "msg_2"])
        #expect(items[0].text == "next")
        #expect(items[0].delivery == .queue)
        #expect(items[1].text == nil)
        #expect(transport.requests[0].url?.path() == "/api/session/ses_1/inbox")
    }

    @Test func inboxCancelAndUpdate() async throws {
        let (client, transport) = client(.init(status: 204, body: ""), .init(status: 204, body: ""))
        try await client.cancelInboxItem(sessionID: "ses_1", inboxID: "msg_1")
        try await client.updateInboxItem(sessionID: "ses_1", inboxID: "msg_1", delivery: .steer)
        #expect(transport.requests[0].httpMethod == "DELETE")
        #expect(transport.requests[0].url?.path() == "/api/session/ses_1/inbox/msg_1")
        #expect(transport.requests[1].httpMethod == "PATCH")
        #expect(body(transport.requests[1]) == #"{"delivery":"steer"}"#)
    }

    @Test func viewAgentAndModel() async throws {
        let (client, transport) = client(
            .init(status: 204, body: ""), .init(status: 204, body: ""), .init(status: 204, body: ""))
        try await client.viewSession("ses_1", idle: 1234)
        try await client.switchAgent(sessionID: "ses_1", agent: "plan")
        try await client.switchModel(sessionID: "ses_1", model: ModelRef(id: "m", providerID: "p"))
        #expect(transport.requests.map { $0.url?.path() } == [
            "/api/session/ses_1/view", "/api/session/ses_1/agent", "/api/session/ses_1/model",
        ])
        #expect(body(transport.requests[0]) == #"{"idle":1234}"#)
        #expect(body(transport.requests[1]) == #"{"agent":"plan"}"#)
        #expect(body(transport.requests[2]) == #"{"model":{"id":"m","providerID":"p"}}"#)
    }

    @Test func singleMessage() async throws {
        let (client, transport) = client(.init(status: 200, body: #"""
            {"data":{"id":"msg_1","type":"user","time":{"created":1},"text":"hi"}}
            """#))
        let message = try await client.message(sessionID: "ses_1", messageID: "msg_1")
        guard case .user(let user) = message else { Issue.record("not a user message"); return }
        #expect(user.text == "hi")
        #expect(transport.requests[0].url?.path() == "/api/session/ses_1/message/msg_1")
    }

    @Test func inboxEnqueuedCarriesPromptText() {
        let frame = #"""
            {"id":"evt_1","created":1,"type":"session.inbox.enqueued","data":{"sessionID":"ses_1","inboxID":"msg_1",
            "item":{"type":"user","payload":{"text":"hello"},"delivery":"queue"}}}
            """#
        let envelope = OpenCodeEventDecoder().decode(Data(frame.utf8))
        guard case .inboxEnqueued(let payload) = envelope.event else { Issue.record("wrong case"); return }
        #expect(payload.item.text == "hello")
        #expect(payload.item.delivery == .queue)
    }
}
