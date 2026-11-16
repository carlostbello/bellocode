import Foundation
import Testing
@testable import OpenCodeKit

/// Integration, credential and permission-evaluation calls (M1-D). Payloads are copied from the real 2.3.0 server.
@Suite("OpenCodeClient integrations and credentials")
struct IntegrationClientTests {
    private let connection = ServerConnection(
        baseURL: URL(string: "http://127.0.0.1:4096")!, credentials: ServerCredentials(password: "pw")
    )

    private func client(_ responses: FakeTransport.Response...) -> (OpenCodeClient, FakeTransport) {
        let transport = FakeTransport(responses)
        return (OpenCodeClient(connection: connection, transport: transport), transport)
    }

    private func body(_ request: URLRequest) -> String { String(decoding: request.httpBody ?? Data(), as: UTF8.self) }

    @Test func integrationListDecodesEveryMethodKind() async throws {
        let (client, transport) = client(.init(status: 200, body: #"""
            {"location":{"directory":"/p"},"data":[
             {"id":"github-copilot","name":"GitHub Copilot","methods":[{"type":"env","names":["GITHUB_TOKEN"]},
              {"id":"device","type":"oauth","label":"Login with GitHub Copilot","form":[
               {"key":"deploymentType","title":"Select GitHub deployment type","required":true,"type":"string",
                "options":[{"value":"github.com","label":"GitHub.com","description":"Public"}]},
               {"key":"enterpriseUrl","required":true,"when":[{"key":"deploymentType","op":"eq","value":"enterprise"}],
                "type":"string"}]}],
              "connections":[]},
             {"id":"openrouter","name":"OpenRouter","methods":[{"type":"key"},{"type":"env","names":["OPENROUTER_API_KEY"]}],
              "connections":[{"type":"credential","id":"cred_1","label":"OpenRouter","method":"key"},
               {"type":"env","name":"OPENROUTER_API_KEY","status":{"status":"needs_auth","message":"expired"}}]},
             {"id":"x","name":"X","methods":[{"id":"cli","type":"command","label":"Log in","command":["x","login"]},
              {"id":"p","type":"external","label":"Profile"},{"type":"future"}],"connections":[]}]}
            """#))
        let list = try await client.integrations(directory: "/p")
        #expect(list.map(\.id) == ["github-copilot", "openrouter", "x"])
        #expect(list[0].methods[1].type == .oauth)
        #expect(list[0].methods[1].form?.count == 2)
        #expect(list[0].methods[1].form?[1].when?.count == 1)
        #expect(list[1].connections[0].id == "cred_1")
        #expect(list[1].connections[1].status?.status == "needs_auth")
        #expect(list[2].methods.map(\.type) == [.command, .external, "future"])
        #expect(list[2].methods[0].command == ["x", "login"])
        #expect(transport.requests[0].url?.query()?.contains("location%5Bdirectory%5D=%2Fp") == true)
    }

    @Test func credentialListNeverDecodesSecrets() async throws {
        let (client, _) = client(.init(status: 200, body: #"""
            {"data":[{"id":"cred_1","integrationID":"openrouter","label":"Work","active":true,
              "value":{"type":"key","key":"sk-secret-value"}},
             {"id":"cred_2","integrationID":"openai","label":"ChatGPT","active":false,
              "value":{"type":"oauth","methodID":"chatgpt","refresh":"r-secret","access":"a-secret","expires":1}}]}
            """#))
        let credentials = try await client.credentials()
        #expect(credentials.map(\.id) == ["cred_1", "cred_2"])
        #expect(credentials[0].kind == "key")
        #expect(credentials[1].methodID == "chatgpt")
        // No stored property can hold a secret: the value's reflection mentions none of them.
        let dump = String(describing: credentials)
        #expect(!dump.contains("secret"))
    }

    @Test func connectKeyAndOAuthRoutes() async throws {
        let (client, transport) = client(
            .init(status: 204, body: ""),
            .init(status: 200, body: #"""
                {"location":{"directory":"/p"},"data":{"attemptID":"att_1","url":"https://example.com/auth",
                 "instructions":"Open the page","mode":"auto","paste":true,"time":{"created":1,"expires":"Infinity"}}}
                """#),
            .init(status: 200, body: #"{"location":{"directory":"/p"},"data":{"status":"failed","message":"denied","time":{"created":1,"expires":2}}}"#),
            .init(status: 204, body: ""), .init(status: 204, body: ""))
        try await client.connectKey(integrationID: "anthropic", key: "k", answer: ["a": .string("b")], directory: "/p")
        let attempt = try await client.startOAuth(integrationID: "openai", methodID: "browser", directory: "/p")
        let status = try await client.oauthStatus(integrationID: "openai", attemptID: attempt.attemptID, directory: "/p")
        try await client.completeOAuth(integrationID: "openai", attemptID: "att_1", code: "123", directory: "/p")
        try await client.cancelOAuth(integrationID: "openai", attemptID: "att_1", directory: "/p")
        #expect(attempt.mode == "auto")
        #expect(attempt.paste == true)
        #expect(attempt.time.expires.value == .infinity)
        #expect(status.status == .failed)
        #expect(status.message == "denied")
        let paths = transport.requests.map { "\($0.httpMethod!) \($0.url!.path())" }
        #expect(paths == [
            "POST /api/integration/anthropic/connect/key", "POST /api/integration/openai/connect/oauth",
            "GET /api/integration/openai/connect/oauth/att_1", "POST /api/integration/openai/connect/oauth/att_1/complete",
            "DELETE /api/integration/openai/connect/oauth/att_1",
        ])
        #expect(body(transport.requests[0]) == #"{"answer":{"a":"b"},"key":"k"}"#)
        #expect(body(transport.requests[1]) == #"{"methodID":"browser"}"#)
        #expect(body(transport.requests[3]) == #"{"code":"123"}"#)
    }

    @Test func credentialCommandsAndPermissionEvaluation() async throws {
        let (client, transport) = client(
            .init(status: 204, body: ""), .init(status: 204, body: ""), .init(status: 204, body: ""),
            .init(status: 200, body: #"{"data":{"id":"per_1","effect":"allow"}}"#),
            .init(status: 200, body: #"{"data":[{"id":"psv_1","projectID":"p1","action":"shell","resource":"npm *","time":{"created":1,"updated":1}}]}"#))
        try await client.renameCredential("cred_1", label: "Work")
        try await client.activateCredential("cred_1")
        try await client.removeCredential("cred_1")
        let effect = try await client.evaluatePermission(
            sessionID: "ses_1", PermissionCreateRequest(action: "shell", resources: ["ls"], agent: "build"))
        let saved = try await client.savedPermissions(projectID: "p1")
        #expect(effect.effect == .allow)
        #expect(saved.first?.resource == "npm *")
        #expect(body(transport.requests[0]) == #"{"label":"Work"}"#)
        #expect(transport.requests.map { "\($0.httpMethod!) \($0.url!.path())" } == [
            "PATCH /api/credential/cred_1", "POST /api/credential/cred_1/activate", "DELETE /api/credential/cred_1",
            "POST /api/session/ses_1/permission", "GET /api/permission/saved",
        ])
        #expect(transport.requests[4].url?.query() == "projectID=p1")
    }

    @Test func serverErrorsCarryTheTag() async throws {
        let (client, _) = client(
            .init(status: 400, body: #"{"_tag":"InvalidRequestError","message":"Missing required form field: resourceName","kind":"integration_authorization"}"#))
        await #expect(throws: OpenCodeError.self) {
            try await client.connectKey(integrationID: "azure", key: "k", directory: "/p")
        }
    }
}
