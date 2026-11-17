import Foundation

/// A tool the app hosts over client MCP (docs/features/orchestration.md, "Channels"). opencode lists it to the agent as
/// `<server name>_<tool name>` for the location the connection was opened for, only while the connection is open.
public struct ClientMCPTool: Sendable, Equatable {
    public var name: String
    public var description: String
    /// JSON Schema of the arguments (an object schema).
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// One `tools/call`, attributed to the calling session by opencode (`_meta["ai.opencode/sessionID"]`, set for every call
/// a session makes; verified in 2.3.0 source `core/src/mcp/client.ts`).
public struct ClientMCPCall: Sendable, Equatable {
    public var tool: String
    public var arguments: JSONValue
    /// The calling session. nil only if opencode did not attribute the call; providers must refuse such calls when the
    /// tool acts on a thread.
    public var sessionID: String?
    /// The location (directory) the connection serves.
    public var directory: String

    public init(tool: String, arguments: JSONValue, sessionID: String?, directory: String) {
        self.tool = tool
        self.arguments = arguments
        self.sessionID = sessionID
        self.directory = directory
    }
}

/// A tool result: text blocks, flagged as an error when the call was refused or failed (shown to the model, which can
/// correct itself; never a protocol error).
public struct ClientMCPResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public static func error(_ message: String) -> ClientMCPResult { ClientMCPResult(text: message, isError: true) }
}

/// What the app offers over client MCP. Implemented by Engine's `OrchestrationService` (UI tools); later packages add
/// HTML previews, secret requests and pull-request tools by adding tools here, without touching the transport.
public protocol ClientMCPToolProvider: Sendable {
    func tools(directory: String) async -> [ClientMCPTool]
    func call(_ call: ClientMCPCall) async -> ClientMCPResult
}

/// The MCP *server* side of JSON-RPC 2.0, one message per WebSocket text frame (opencode's `McpSocketClient` framing:
/// no batching). opencode is the MCP client: it sends `initialize`, `notifications/initialized`, `tools/list`,
/// `tools/call`, `ping` (sequence verified on the real 2.3.0 binary). Pure: no I/O, so it is unit-tested directly.
public struct MCPServerProtocol: Sendable {
    public static let sessionMetaKey = "ai.opencode/sessionID"
    /// Offered when the client asks for a version this code does not know (newest we were tested with).
    public static let fallbackProtocolVersion = "2025-11-25"

    public var serverName: String
    public var serverVersion: String

    public init(serverName: String, serverVersion: String) {
        self.serverName = serverName
        self.serverVersion = serverVersion
    }

    /// What to do with one inbound frame.
    public enum Action: Sendable, Equatable {
        /// Send this frame back now.
        case reply(String)
        /// List tools, then reply to request `id`.
        case listTools(id: JSONValue)
        /// Run the call, then reply to request `id` with `result(id:_:)`.
        case call(id: JSONValue, ClientMCPCall)
        case ignore
    }

    public func handle(_ frame: String, directory: String) -> Action {
        guard let data = frame.data(using: .utf8), let message = try? JSONValue.parse(data), case .object(let object) = message
        else { return .reply(Self.error(id: .null, code: -32700, message: "Parse error")) }
        guard let method = object["method"]?.stringValue else { return .ignore }  // a response to us; we send no requests
        guard let id = object["id"], id != .null else { return .ignore }  // notifications need no answer
        let params = object["params"] ?? .object([:])
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? Self.fallbackProtocolVersion
            return .reply(
                Self.response(
                    id: id,
                    result: .object([
                        "protocolVersion": .string(requested),
                        "capabilities": .object(["tools": .object(["listChanged": .bool(true)])]),
                        "serverInfo": .object(["name": .string(serverName), "version": .string(serverVersion)]),
                    ])))
        case "ping":
            return .reply(Self.response(id: id, result: .object([:])))
        case "tools/list":
            return .listTools(id: id)
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return .reply(Self.error(id: id, code: -32602, message: "Missing tool name"))
            }
            let session = params["_meta"]?[Self.sessionMetaKey]?.stringValue
            return .call(
                id: id,
                ClientMCPCall(tool: name, arguments: params["arguments"] ?? .object([:]), sessionID: session, directory: directory))
        default:
            return .reply(Self.error(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    public static func toolsList(id: JSONValue, _ tools: [ClientMCPTool]) -> String {
        response(
            id: id,
            result: .object([
                "tools": .array(
                    tools.map {
                        .object(["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema])
                    })
            ]))
    }

    public static func result(id: JSONValue, _ result: ClientMCPResult) -> String {
        response(
            id: id,
            result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string(result.text)])]),
                "isError": .bool(result.isError),
            ]))
    }

    public static let toolsChangedNotification = encode(
        .object(["jsonrpc": .string("2.0"), "method": .string("notifications/tools/list_changed")]))

    static func response(id: JSONValue, result: JSONValue) -> String {
        encode(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    static func error(id: JSONValue, code: Int, message: String) -> String {
        encode(
            .object([
                "jsonrpc": .string("2.0"), "id": id,
                "error": .object(["code": .number(Double(code)), "message": .string(message)]),
            ]))
    }

    static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
