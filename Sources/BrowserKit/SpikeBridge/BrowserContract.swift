// SPIKE (gate G3). The `experimental.browser` v4 contract of opencode 2.3.0, as far as the desktop side needs it.
// Source of truth: packages/plugin-browser/src/rpc.ts at tag v2.3.0. See docs/spikes/G3-browser-bridge.md.

import Foundation

public enum BrowserContract {
    public static let rpcID = "experimental.browser"
    public static let version = 4
    /// Event type on `/api/event` for the RPC's `control` event: `rpc.<rpcID>.<event>`.
    public static let controlEventType = "rpc.experimental.browser.control"
    /// The server times a dispatched request out after this long and then sends `cancel`.
    public static let serverRequestTimeout: Duration = .seconds(60)
    public static let maxText = 100_000
    public static let maxFileBytes = 5 * 1024 * 1024
    /// The reference desktop refuses results larger than this many JSON characters.
    public static let maxResultCharacters = 512_000

    /// Operations whose meaning survives a document change; all others check `command.generation`.
    public static let retainedOperations: Set<String> = [
        "navigate", "files.list", "files.get", "trace.stop", "trace.analyze", "cpu.stop", "cpu.analyze",
        "heap.summary", "heap.query", "heap.object", "heap.compare",
    ]

    public static func newTabID() -> String { "tab_\(UUID().uuidString.lowercased())" }
    public static func newFileID() -> String { "file_\(UUID().uuidString.lowercased())" }
}

/// `Browser.Tab`.
public struct BrowserTab: Sendable, Equatable {
    public var id: String
    public var url: String
    public var title: String
    public var loading: Bool
    public var loadError: String?
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var generation: Int

    public var json: JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id), "url": .string(String(url.prefix(16_384))), "title": .string(String(title.prefix(2_048))),
            "loading": .bool(loading), "canGoBack": .bool(canGoBack), "canGoForward": .bool(canGoForward),
            "generation": .number(Double(generation)),
        ]
        if let loadError { fields["loadError"] = .string(String(loadError.prefix(2_048))) }
        return .object(fields)
    }
}

/// `Browser.State`: the authoritative tab inventory the desktop publishes.
public struct BrowserState: Sendable, Equatable {
    public var tabs: [BrowserTab]
    public var focusedTabID: String?

    public init(tabs: [BrowserTab], focusedTabID: String?) {
        self.tabs = tabs
        self.focusedTabID = focusedTabID
    }

    public var json: JSONValue {
        ["tabs": .array(tabs.map(\.json)), "focusedTabID": focusedTabID.map(JSONValue.string) ?? .null]
    }
}

/// `Browser.File` (bytes travel base64-encoded).
public struct BrowserFile: Sendable {
    public var id: String
    public var name: String
    public var mime: String
    public var data: Data

    public init(id: String = BrowserContract.newFileID(), name: String, mime: String, data: Data) {
        self.id = id
        self.name = name
        self.mime = mime
        self.data = data
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.string, let name = json["name"]?.string, let mime = json["mime"]?.string,
              let encoded = json["data"]?.string, let data = Data(base64Encoded: encoded) else { return nil }
        self.init(id: id, name: name, mime: mime, data: data)
    }

    public var json: JSONValue {
        ["id": .string(id), "name": .string(name), "mime": .string(mime), "data": .string(data.base64EncodedString())]
    }
}

/// `Browser.Command`, as returned by the `command` method.
public struct BrowserCommand: Sendable {
    public var action: JSONValue
    public var generation: Int?
    public var files: [BrowserFile]
    public var inspect: Bool
    public var target: JSONValue?

    public var type: String { action["type"]?.string ?? "" }
    public var tabID: String? { action["tabID"]?.string }

    public init(action: JSONValue, generation: Int? = nil, files: [BrowserFile] = [], inspect: Bool = false, target: JSONValue? = nil) {
        self.action = action
        self.generation = generation
        self.files = files
        self.inspect = inspect
        self.target = target
    }

    public init(json: JSONValue) throws {
        guard let action = json["action"], action["type"]?.string != nil else {
            throw BrowserFailure("unsupported", "Command has no action type.")
        }
        self.init(
            action: action,
            generation: json["generation"]?.int,
            files: (json["files"]?.array ?? []).compactMap(BrowserFile.init(json:)),
            inspect: json["inspect"]?.bool ?? false,
            target: json["target"]
        )
    }
}

/// `Browser.Result`.
public struct BrowserResult: Sendable {
    public var value: JSONValue
    public var files: [BrowserFile]

    public init(value: JSONValue, files: [BrowserFile] = []) {
        self.value = value
        self.files = files
    }
}

/// The failure arm of `Browser.Outcome`. The server prefixes the code: the agent sees `[browser.<code>] <message>`.
public struct BrowserFailure: Error, Sendable, CustomStringConvertible {
    public var code: String
    public var message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = String(message.prefix(2_048))
    }

    public var description: String { "[browser.\(code)] \(message)" }
}

/// `Browser.Outcome`.
public enum BrowserOutcome: Sendable {
    case success(BrowserResult)
    case failure(BrowserFailure)

    public var json: JSONValue {
        switch self {
        case .success(let result):
            ["type": "success", "result": ["value": result.value, "files": .array(result.files.map(\.json))]]
        case .failure(let failure):
            ["type": "failure", "code": .string(failure.code), "message": .string(failure.message)]
        }
    }
}

/// `Browser.Control`, the event the server emits on `/api/event` as `rpc.experimental.browser.control`.
public enum BrowserControl: Sendable, Equatable {
    case attached(connectionID: String, version: Int)
    case command(connectionID: String, requestID: String)
    case cancel(connectionID: String, requestID: String)
    /// A newer server may add control types; an attachment keeps working without them.
    case unrecognized(connectionID: String?, type: String)

    public init?(json: JSONValue) {
        guard let type = json["type"]?.string else { return nil }
        let connectionID = json["connectionID"]?.string
        switch type {
        case "attached":
            guard let connectionID else { return nil }
            self = .attached(connectionID: connectionID, version: json["version"]?.int ?? 0)
        case "command", "cancel":
            guard let connectionID, let requestID = json["requestID"]?.string else { return nil }
            self = type == "command" ? .command(connectionID: connectionID, requestID: requestID) : .cancel(connectionID: connectionID, requestID: requestID)
        default:
            self = .unrecognized(connectionID: connectionID, type: type)
        }
    }

    public var connectionID: String? {
        switch self {
        case .attached(let id, _), .command(let id, _), .cancel(let id, _): id
        case .unrecognized(let id, _): id
        }
    }
}

/// How an `attach` call ended.
public enum AttachOutcome: String, Sendable {
    case closed
    case replaced
    /// The call failed (transport loss, or the server could not grant permissions). Not part of the RPC's output.
    case unavailable
}
