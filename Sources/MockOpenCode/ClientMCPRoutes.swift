import Foundation

// `GET /api/experimental/client-mcp?name=…&location[directory]=…` (operation `experimental.mcp.client`, x-websocket):
// the client hosts an MCP server over the socket and opencode is its MCP client. Like 2.3.0, the mock sends
// `initialize`, then `notifications/initialized` and `tools/list` once initialized, lists again on
// `notifications/tools/list_changed`, and answers `ping`. Tests call the listed tools through
// `callClientMCPTool(name:tool:arguments:sessionID:)`, attributed the way opencode does (`_meta`).

/// One client-MCP socket as the mock sees it.
public struct MockClientMCPConnection: Sendable, Equatable {
    public var name: String
    public var directory: String?
    /// `initialize` answered and `notifications/initialized` sent.
    public var initialized: Bool
    /// Tool names from the latest `tools/list` answer.
    public var tools: [String]

    public init(name: String, directory: String?, initialized: Bool, tools: [String]) {
        self.name = name
        self.directory = directory
        self.initialized = initialized
        self.tools = tools
    }
}

struct ClientMCPPeer: Sendable {
    var info: MockClientMCPConnection
    var nextID = 1
    var initializeID: Int?
    var listID: Int?
    var calls: [Int: CheckedContinuation<JSONValue?, Never>] = [:]
}

struct MockClientMCPState: Sendable {
    /// Open sockets by PTY-plumbing subscriber ID (the socket transport is shared with PTY attachments).
    var peers: [Int: ClientMCPPeer] = [:]
    /// Protocol version the mock offers in `initialize`.
    static let protocolVersion = "2025-06-18"
}

extension MockOpenCodeServer {
    func routeClientMCP(_ method: String, _ parts: [String], _ request: HTTPRequest, connectionID: Int) -> ResponsePlan? {
        guard method == "GET", parts == ["api", "experimental", "client-mcp"] else { return nil }
        guard let name = request.queryValue("name"), !name.isEmpty else {
            return .response(.error(400, tag: "InvalidRequestError", message: "Missing name"))
        }
        guard WebSocket.isUpgrade(request), let key = request.headers["sec-websocket-key"] else {
            return .response(.error(400, tag: "InvalidRequestError", message: "Expected a WebSocket upgrade"))
        }
        pty.nextSubscriberID += 1
        let subscriberID = pty.nextSubscriberID
        pty.subscribers[subscriberID] = PTYSubscriber(ptyID: "", connectionID: connectionID, attachmentID: "client-mcp", role: .observer)
        let directory = request.queryValue("location[directory]") ?? request.queryValue("directory")
        var peer = ClientMCPPeer(info: MockClientMCPConnection(name: name, directory: directory, initialized: false, tools: []))
        let id = peer.nextID
        peer.nextID += 1
        peer.initializeID = id
        clientMCP.peers[subscriberID] = peer
        sendClientMCP(
            [
                "jsonrpc": "2.0", "id": .int(id), "method": "initialize",
                "params": [
                    "protocolVersion": .string(MockClientMCPState.protocolVersion), "capabilities": [:],
                    "clientInfo": ["name": "opencode", "version": "2.3.0"],
                ],
            ], to: subscriberID)
        return .ptySocket(subscriberID: subscriberID, handshake: WebSocket.handshake(key: key))
    }

    /// A text frame from the app's MCP server.
    func clientMCPFrame(_ subscriberID: Int, _ text: String) {
        guard var peer = clientMCP.peers[subscriberID], let message = try? JSONValue.parse(Data(text.utf8)) else { return }
        if let method = message["method"]?.stringValue {
            if method == "notifications/tools/list_changed" {
                clientMCP.peers[subscriberID] = peer
                listClientMCPTools(subscriberID)
            } else if method == "ping", let id = message["id"] {
                sendClientMCP(["jsonrpc": "2.0", "id": id, "result": [:]], to: subscriberID)
            }
            return
        }
        guard let id = message["id"]?.intValue else { return }
        if id == peer.initializeID {
            peer.initializeID = nil
            peer.info.initialized = message["result"] != nil
            clientMCP.peers[subscriberID] = peer
            guard peer.info.initialized else { return }
            sendClientMCP(["jsonrpc": "2.0", "method": "notifications/initialized"], to: subscriberID)
            listClientMCPTools(subscriberID)
        } else if id == peer.listID {
            peer.listID = nil
            peer.info.tools = (message["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
            clientMCP.peers[subscriberID] = peer
        } else if let waiter = peer.calls.removeValue(forKey: id) {
            clientMCP.peers[subscriberID] = peer
            waiter.resume(returning: message["result"] ?? message["error"])
        }
    }

    private func listClientMCPTools(_ subscriberID: Int) {
        guard var peer = clientMCP.peers[subscriberID] else { return }
        let id = peer.nextID
        peer.nextID += 1
        peer.listID = id
        clientMCP.peers[subscriberID] = peer
        sendClientMCP(["jsonrpc": "2.0", "id": .int(id), "method": "tools/list", "params": [:]], to: subscriberID)
    }

    private func sendClientMCP(_ message: JSONValue, to subscriberID: Int) {
        enqueuePTYFrame(WebSocket.text(message.serialized), to: subscriberID)
    }

    /// The socket closed: pending calls end without a result.
    func clientMCPClosed(_ subscriberID: Int) {
        guard let peer = clientMCP.peers.removeValue(forKey: subscriberID) else { return }
        for waiter in peer.calls.values { waiter.resume(returning: nil) }
    }

    // MARK: Test control

    /// Open client-MCP sockets, oldest first.
    public func clientMCPConnections() -> [MockClientMCPConnection] {
        clientMCP.peers.sorted { $0.key < $1.key }.map(\.value.info)
    }

    /// Calls `tool` on the newest socket named `name`, as opencode does for a session's tool call. Returns the
    /// `result` (or `error`) object, or nil if no such socket is open or it closes first.
    public func callClientMCPTool(name: String, tool: String, arguments: JSONValue = [:], sessionID: String? = nil) async -> JSONValue? {
        guard let subscriberID = clientMCP.peers.filter({ $0.value.info.name == name && $0.value.info.initialized }).keys.max(),
            var peer = clientMCP.peers[subscriberID]
        else { return nil }
        let id = peer.nextID
        peer.nextID += 1
        clientMCP.peers[subscriberID] = peer
        var params: [(String, JSONValue)] = [("name", .string(tool)), ("arguments", arguments)]
        if let sessionID { params.append(("_meta", .object([("ai.opencode/sessionID", .string(sessionID))]))) }
        return await withCheckedContinuation { continuation in
            clientMCP.peers[subscriberID]?.calls[id] = continuation
            sendClientMCP(["jsonrpc": "2.0", "id": .int(id), "method": "tools/call", "params": .object(params)], to: subscriberID)
        }
    }
}
