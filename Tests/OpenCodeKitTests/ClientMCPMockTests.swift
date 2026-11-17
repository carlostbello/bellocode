import Foundation
import MockOpenCode
import Testing

@testable import OpenCodeKit

private struct AttributedEcho: ClientMCPToolProvider {
    func tools(directory: String) async -> [ClientMCPTool] {
        [ClientMCPTool(name: "echo", description: "Echo", inputSchema: .object(["type": .string("object")]))]
    }
    func call(_ call: ClientMCPCall) async -> ClientMCPResult {
        ClientMCPResult(text: "\(call.arguments["text"]?.stringValue ?? "")@\(call.sessionID ?? "-")@\(call.directory)")
    }
}

private actor States {
    var all: [ClientMCPHost.State] = []
    func add(_ state: ClientMCPHost.State) { all.append(state) }
}

/// The production host and WebSocket dialer against the mock's client-MCP route (the mock plays opencode's MCP
/// client: initialize, initialized, tools/list, tools/call with `_meta` attribution).
@Suite("Client MCP host against MockOpenCode")
struct ClientMCPMockTests {
    @Test func hostConnectsOnceListsToolsAndServesAttributedCalls() async throws {
        let server = MockOpenCodeServer(scenario: .empty(), options: .testing)
        let endpoint = try await server.start()
        let connection = ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? ""))
        let host = ClientMCPHost(
            name: "bellocode_app", directory: "/tmp/mock-project", dialer: WebSocketClientMCPDialer(connection: connection),
            provider: AttributedEcho())
        let states = States()
        await host.observeState { state in Task { await states.add(state) } }
        await host.start()

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while await server.clientMCPConnections().first?.tools != ["echo"] {
            guard clock.now < deadline else {
                Issue.record("the host never listed its tools to the mock")
                break
            }
            await Task.yield()
        }
        let connections = await server.clientMCPConnections()
        #expect(connections == [MockClientMCPConnection(name: "bellocode_app", directory: "/tmp/mock-project", initialized: true, tools: ["echo"])])
        #expect(await host.state == .connected)

        let result = await server.callClientMCPTool(
            name: "bellocode_app", tool: "echo", arguments: ["text": "hi"], sessionID: "ses_caller")
        #expect(result?["content"]?[0]?["text"]?.stringValue == "hi@ses_caller@/tmp/mock-project")
        #expect(result?["isError"] == .bool(false))

        // Connected once: no failed opens, no backoff.
        #expect(!(await states.all).contains { if case .waiting = $0 { true } else { false } })

        await host.stop()
        while await !server.clientMCPConnections().isEmpty {
            guard clock.now < deadline else {
                Issue.record("the mock kept the socket after stop")
                break
            }
            await Task.yield()
        }
        await server.stop()
    }

    @Test func routeRefusesAPlainRequestAndAMissingName() async throws {
        let server = MockOpenCodeServer(scenario: .empty(), options: .testing)
        let endpoint = try await server.start()
        let auth = ServerCredentials(password: endpoint.password ?? "").authorizationHeader
        for query in ["name=x", ""] {
            var request = URLRequest(url: URL(string: "\(endpoint.url.absoluteString)/api/experimental/client-mcp?\(query)")!)
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 400)
        }
        await server.stop()
    }
}
