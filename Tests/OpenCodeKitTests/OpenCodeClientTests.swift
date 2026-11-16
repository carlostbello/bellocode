import Foundation
import Synchronization
import Testing
@testable import OpenCodeKit

/// Records requests and answers with canned responses.
final class FakeTransport: HTTPTransport {
    struct Response: Sendable {
        var status: Int
        var body: String
    }

    private let state = Mutex<(requests: [URLRequest], responses: [Response])>(([], []))

    init(_ responses: [Response]) {
        state.withLock { $0.responses = responses }
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = state.withLock { state -> Response in
            state.requests.append(request)
            return state.responses.isEmpty ? Response(status: 500, body: "") : state.responses.removeFirst()
        }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(response.body.utf8), http)
    }
}

@Suite("OpenCodeClient")
struct OpenCodeClientTests {
    private let connection = ServerConnection(
        baseURL: URL(string: "http://127.0.0.1:4096")!, credentials: ServerCredentials(password: "s3cret")
    )

    private func client(_ responses: FakeTransport.Response...) -> (OpenCodeClient, FakeTransport) {
        let transport = FakeTransport(responses)
        return (OpenCodeClient(connection: connection, transport: transport), transport)
    }

    @Test func sendsBasicAuthAndTimeout() async throws {
        let (client, transport) = client(.init(status: 200, body: #"{"version":"2.3.0","pid":42,"urls":[],"paths":{"tmp":"/tmp"}}"#))
        let info = try await client.info()
        #expect(info.pid == 42)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:4096/api/info")
        let expected = "Basic " + Data("opencode:s3cret".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == expected)
        #expect(request.timeoutInterval == 30)
    }

    @Test func credentialsAreRedactedInDescriptions() {
        #expect(!String(describing: connection).contains("s3cret"))
        #expect(!String(reflecting: connection).contains("s3cret"))
        #expect(!"\(connection.credentials)".contains("s3cret"))
    }

    @Test func locationIsSentAsEncodedDeepObjectQuery() async throws {
        let (client, transport) = client(.init(status: 200, body: #"{"location":{"directory":"/a b/c+d"},"data":[]}"#))
        _ = try await client.pendingPermissions(directory: "/a b/c+d")
        let url = try #require(transport.requests.first?.url?.absoluteString)
        #expect(url == "http://127.0.0.1:4096/api/permission/request?location%5Bdirectory%5D=%2Fa%20b%2Fc%2Bd")
    }

    @Test func sessionListQuery() async throws {
        let (client, transport) = client(.init(status: 200, body: #"{"data":[],"cursor":{"next":null}}"#))
        let page = try await client.sessions(SessionListQuery(directory: "/p", parent: .root, limit: 20, order: .descending))
        #expect(page.data.isEmpty)
        #expect(page.cursor.next == nil)
        let url = try #require(transport.requests.first?.url?.absoluteString)
        #expect(url == "http://127.0.0.1:4096/api/session?limit=20&order=desc&parentID=null&directory=%2Fp")
    }

    @Test func pathSegmentsAreEncoded() async throws {
        let (client, transport) = client(.init(status: 204, body: ""))
        try await client.deleteSession("ses_a/b")
        #expect(transport.requests.first?.url?.path(percentEncoded: true) == "/api/session/ses_a%2Fb")
        #expect(transport.requests.first?.httpMethod == "DELETE")
    }

    @Test func typedErrorBodyIsDecoded() async throws {
        let (client, _) = client(.init(status: 404, body: #"{"_tag":"SessionNotFoundError","sessionID":"ses_x","message":"Session not found: ses_x"}"#))
        do {
            _ = try await client.session("ses_x")
            Issue.record("expected an error")
        } catch let error as OpenCodeError {
            #expect(error.status == 404)
            #expect(error.tag == .sessionNotFound)
            if case .http(_, let body, let operation) = error {
                #expect(body?.fields["sessionID"]?.stringValue == "ses_x")
                #expect(operation == "session.get")
            }
        }
    }

    @Test func errorWithoutBodyStillCarriesStatus() async throws {
        let (client, _) = client(.init(status: 502, body: "<html>bad gateway</html>"))
        do {
            _ = try await client.projects()
            Issue.record("expected an error")
        } catch let OpenCodeError.http(status, body, _) {
            #expect(status == 502)
            #expect(body == nil)
        }
    }

    @Test func promptBodyEncodesAttachmentsAndDelivery() async throws {
        let (client, transport) = client(
            .init(status: 200, body: #"{"data":{"id":"msg_1","sessionID":"ses_1","time":{"created":1},"type":"user","payload":{"text":"hi"},"delivery":"queue"}}"#)
        )
        let item = try await client.prompt(
            sessionID: "ses_1",
            PromptRequest(
                text: "hi @a.swift", id: "msg_1",
                files: [
                    .init(uri: "file:///r/a.swift", name: "a.swift", source: .uri("file:///r/a.swift"),
                          mention: .init(start: 3, end: 11, text: "@a.swift")),
                    .init(uri: "file:///tmp/x.png"),
                ],
                agents: [.init(name: "plan")], skills: [], delivery: .queue)
        )
        #expect(item.delivery == .queue)
        let body = try #require(transport.requests.first?.httpBody)
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        // Shapes from Contracts/opencode-2.3.0 (PromptInput.FileAttachment, Prompt.FileSource, Prompt.Mention); an
        // empty list is left out.
        #expect(json == .object([
            "id": .string("msg_1"), "text": .string("hi @a.swift"), "delivery": .string("queue"),
            "files": .array([
                .object([
                    "uri": .string("file:///r/a.swift"), "name": .string("a.swift"),
                    "source": .object(["type": .string("uri"), "uri": .string("file:///r/a.swift")]),
                    "mention": .object(["start": .number(3), "end": .number(11), "text": .string("@a.swift")]),
                ]),
                .object(["uri": .string("file:///tmp/x.png")]),
            ]),
            "agents": .array([.object(["name": .string("plan")])]),
        ]))
    }

    @Test func permissionAndFormReplies() async throws {
        let (client, transport) = client(.init(status: 204, body: ""), .init(status: 204, body: ""))
        try await client.replyPermission(sessionID: "ses_1", requestID: "per_1", decision: .always)
        try await client.replyForm(sessionID: "ses_1", formID: "frm_1", answer: ["n": .number(2), "pick": .strings(["a"])])
        let requests = transport.requests
        #expect(requests[0].url?.path() == "/api/session/ses_1/permission/per_1/reply")
        #expect(try JSONDecoder().decode(JSONValue.self, from: requests[0].httpBody!) == .object(["decision": .string("always")]))
        #expect(requests[1].url?.path() == "/api/session/ses_1/form/frm_1/reply")
        #expect(
            try JSONDecoder().decode(JSONValue.self, from: requests[1].httpBody!)
                == .object(["answer": .object(["n": .number(2), "pick": .array([.string("a")])])])
        )
    }

    @Test func messagePageDecodesEveryKindTolerantly() async throws {
        let body = """
            {"data":[
              {"id":"msg_u","type":"user","time":{"created":1},"text":"hello"},
              {"id":"msg_a","type":"assistant","time":{"created":2,"completed":3},"agent":"build",
               "model":{"id":"big-pickle","providerID":"opencode"},"finish":"stop","cost":0,
               "content":[{"type":"reasoning","text":"think"},{"type":"text","text":"answer"},
                 {"type":"tool","id":"t1","name":"shell","time":{"created":2},
                  "state":{"status":"completed","input":{"command":"ls"},"content":[{"type":"text","text":"x"}]}},
                 {"type":"tool","id":"t2","name":"read","time":{"created":2},"state":{"status":"paused"}},
                 {"type":"hologram"}]},
              {"id":"msg_s","type":"shell","time":{"created":4},"shellID":"sh_1","command":"ls","status":"exited","exit":"NaN"},
              {"id":"msg_i","type":"idle","time":{"created":5},"outcome":"succeeded"},
              {"id":"msg_c","type":"compaction","status":"running","time":{"created":6}},
              {"id":"msg_z","type":"from-the-future","time":{"created":7}}
            ],"cursor":{"previous":"p1","next":null}}
            """
        let (client, transport) = client(.init(status: 200, body: body))
        let page = try await client.messages(sessionID: "ses_1", MessageListQuery(limit: 50, order: .ascending))
        #expect(transport.requests.first?.url?.query() == "limit=50&order=asc")
        #expect(page.data.map(\.id) == ["msg_u", "msg_a", "msg_s", "msg_i", "msg_c", "msg_z"])
        #expect(page.data.map(\.type) == ["user", "assistant", "shell", "idle", "compaction", "from-the-future"])
        #expect(page.cursor.previous == "p1")
        guard case .assistant(let assistant) = page.data[1] else {
            Issue.record("expected an assistant message")
            return
        }
        #expect(assistant.content.count == 5)
        #expect(assistant.content[0] == .reasoning("think"))
        #expect(assistant.content[1] == .text("answer"))
        if case .tool(let call) = assistant.content[2], case .completed(let input, let content, _) = call.state {
            #expect(input["command"]?.stringValue == "ls")
            #expect(content == [.text("x")])
        } else {
            Issue.record("expected a completed tool call")
        }
        if case .tool(let call) = assistant.content[3], case .unknown(let status, _) = call.state {
            #expect(status == "paused")
        } else {
            Issue.record("expected an unknown tool state")
        }
        if case .shell(let shell) = page.data[2] { #expect(shell.exit?.value.isNaN == true) }
    }

    @Test func transportErrorsAreTyped() async throws {
        struct FailingTransport: HTTPTransport {
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                throw URLError(.cannotConnectToHost)
            }
        }
        let client = OpenCodeClient(connection: connection, transport: FailingTransport())
        do {
            _ = try await client.info()
            Issue.record("expected an error")
        } catch let OpenCodeError.transport(operation, code) {
            #expect(operation == "server.info")
            #expect(code == .cannotConnectToHost)
        }
    }

    @Test func cancelledTransportBecomesCancellationError() async throws {
        struct CancelledTransport: HTTPTransport {
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                throw URLError(.cancelled)
            }
        }
        let client = OpenCodeClient(connection: connection, transport: CancelledTransport())
        await #expect(throws: CancellationError.self) { try await client.info() }
    }

    @Test func eventStreamRequestUsesRepeatedTypes() throws {
        let client = OpenCodeClient(connection: connection, transport: FakeTransport([]))
        let request = try client.eventStreamRequest(types: ["session.created", "permission.asked"])
        #expect(request.url?.query() == "types=session.created&types=permission.asked")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.timeoutInterval == 45)
    }
}
