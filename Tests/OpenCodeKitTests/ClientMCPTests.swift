import Foundation
import Testing

@testable import OpenCodeKit

private struct EchoProvider: ClientMCPToolProvider {
    var delay: Duration = .zero
    func tools(directory: String) async -> [ClientMCPTool] {
        [ClientMCPTool(name: "echo", description: "Echo", inputSchema: .object(["type": .string("object")]))]
    }
    func call(_ call: ClientMCPCall) async -> ClientMCPResult {
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard let session = call.sessionID else { return .error("unattributed") }
        return ClientMCPResult(text: "\(call.tool):\(call.arguments["text"]?.stringValue ?? "")@\(session)@\(call.directory)")
    }
}

private func json(_ text: String) -> JSONValue { (try? JSONValue.parse(Data(text.utf8))) ?? .null }

/// Collects frames the host sends.
private actor Inbox {
    var frames: [JSONValue] = []
    func add(_ value: JSONValue) { frames.append(value) }
}

private func collect(_ channel: InMemoryClientMCPChannel) -> (Inbox, Task<Void, Never>) {
    let inbox = Inbox()
    let task = Task { for await frame in channel.sent { await inbox.add(json(frame)) } }
    return (inbox, task)
}

private func waitFor(_ inbox: Inbox, count: Int) async -> [JSONValue] {
    for _ in 0..<200 {
        let frames = await inbox.frames
        if frames.count >= count { return frames }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await inbox.frames
}

@Suite("Client MCP")
struct ClientMCPTests {
    let handler = MCPServerProtocol(serverName: "bellocode_app", serverVersion: "1")

    @Test func initializeEchoesTheClientVersionAndAdvertisesTools() {
        let action = handler.handle(
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"#,
            directory: "/p")
        guard case .reply(let text) = action else { Issue.record("expected a reply"); return }
        let reply = json(text)
        #expect(reply["id"] == .number(0))
        #expect(reply["result"]?["protocolVersion"]?.stringValue == "2025-11-25")
        #expect(reply["result"]?["capabilities"]?["tools"]?["listChanged"] == .bool(true))
        #expect(reply["result"]?["serverInfo"]?["name"]?.stringValue == "bellocode_app")
    }

    @Test func notificationsAndResponsesNeedNoAnswer() {
        #expect(handler.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, directory: "/p") == .ignore)
        #expect(handler.handle(#"{"jsonrpc":"2.0","id":3,"result":{}}"#, directory: "/p") == .ignore)
    }

    @Test func malformedAndUnknownFramesGetJSONRPCErrors() {
        guard case .reply(let parse) = handler.handle("{nope", directory: "/p") else { Issue.record("no reply"); return }
        #expect(json(parse)["error"]?["code"] == .number(-32700))
        guard case .reply(let unknown) = handler.handle(#"{"jsonrpc":"2.0","id":"a","method":"resources/list"}"#, directory: "/p")
        else { Issue.record("no reply"); return }
        #expect(json(unknown)["error"]?["code"] == .number(-32601))
        #expect(json(unknown)["id"]?.stringValue == "a")
        guard case .reply(let missing) = handler.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#, directory: "/p")
        else { Issue.record("no reply"); return }
        #expect(json(missing)["error"]?["code"] == .number(-32602))
    }

    @Test func toolCallsCarryTheCallingSession() {
        let frame = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"},"_meta":{"ai.opencode/sessionID":"ses_1"}}}"#
        guard case .call(let id, let call) = handler.handle(frame, directory: "/proj") else { Issue.record("expected a call"); return }
        #expect(id == .number(7))
        #expect(call == ClientMCPCall(tool: "echo", arguments: .object(["text": .string("hi")]), sessionID: "ses_1", directory: "/proj"))
        let result = json(MCPServerProtocol.result(id: id, .error("no")))
        #expect(result["result"]?["isError"] == .bool(true))
        #expect(result["result"]?["content"]?[0]?["text"]?.stringValue == "no")
    }

    @Test func hostServesASessionAndReconnectsAfterADrop() async throws {
        let first = InMemoryClientMCPChannel()
        let second = InMemoryClientMCPChannel()
        let dialer = InMemoryClientMCPDialer([first, second])
        let host = ClientMCPHost(
            name: "bellocode_app", directory: "/proj", dialer: dialer, provider: EchoProvider(),
            backoff: BackoffPolicy(initial: .milliseconds(10), maximum: .milliseconds(20)))
        let (inbox, collector) = collect(first)
        await host.start()
        first.deliver(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#)
        first.deliver(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        first.deliver(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        first.deliver(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"a"},"_meta":{"ai.opencode/sessionID":"ses_x"}}}"#)
        first.deliver(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"b"}}}"#)
        let frames = await waitFor(inbox, count: 4)
        #expect(frames.count == 4)
        let byID = Dictionary(frames.compactMap { frame in frame["id"].map { ($0, frame) } }, uniquingKeysWith: { a, _ in a })
        #expect(byID[.number(1)]?["result"]?["tools"]?[0]?["name"]?.stringValue == "echo")
        #expect(byID[.number(2)]?["result"]?["content"]?[0]?["text"]?.stringValue == "echo:a@ses_x@/proj")
        #expect(byID[.number(3)]?["result"]?["isError"] == .bool(true))
        #expect(await host.state == .connected)

        let (secondInbox, secondCollector) = collect(second)
        first.peerClose()
        for _ in 0..<100 where await dialer.opened.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await dialer.opened.count == 2)
        second.deliver(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#)
        let pong = await waitFor(secondInbox, count: 1)
        #expect(pong.first?["id"] == .number(9))
        await host.stop()
        #expect(await host.state == .stopped)
        collector.cancel()
        secondCollector.cancel()
    }

    @Test func concurrentCallsAreBounded() async throws {
        let channel = InMemoryClientMCPChannel()
        let host = ClientMCPHost(
            name: "bellocode_app", directory: "/proj", dialer: InMemoryClientMCPDialer([channel]),
            provider: EchoProvider(delay: .milliseconds(300)), maxConcurrentCalls: 2)
        let (inbox, collector) = collect(channel)
        await host.start()
        for id in 1...3 {
            channel.deliver(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"echo","arguments":{},"_meta":{"ai.opencode/sessionID":"s"}}}"#)
        }
        let first = await waitFor(inbox, count: 1)
        #expect(first.first?["id"] == .number(3))
        #expect(first.first?["result"]?["isError"] == .bool(true))
        let all = await waitFor(inbox, count: 3)
        #expect(all.count == 3)
        await host.stop()
        collector.cancel()
    }

    @Test func serverConfigListsThePluginAndAlignsSubagentDepth() throws {
        let text = OrchestrationContract.serverConfig(pluginDirectory: URL(fileURLWithPath: "/App.app/Contents/Resources/opencode-plugin"))
        let config = json(text)
        #expect(config["plugins"]?[0]?["package"]?.stringValue == "/App.app/Contents/Resources/opencode-plugin")
        #expect(config["plugins"]?[0]?["options"]?["limits"]?["maxDepth"] == .number(2))
        #expect(config["experimental"]?["subagent_depth"] == .number(2))
        let environment = ServerConfiguration(
            executableURL: URL(fileURLWithPath: "/x/opencode"), dataRoot: URL(fileURLWithPath: "/tmp/r"),
            pluginDirectory: URL(fileURLWithPath: "/plugin")
        ).environment(credentials: ServerCredentials(password: "p"))
        #expect(environment["OPENCODE_CONFIG_CONTENT"]?.contains("/plugin") == true)
    }
}
