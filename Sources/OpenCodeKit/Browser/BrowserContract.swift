import Foundation

// The desktop side of opencode's built-in browser plugin RPC, `experimental.browser` contract version 4, as pinned in
// opencode 2.3.0 (packages/plugin-browser/src/{rpc,connection,machine}.ts; docs/spikes/G3-browser-bridge.md).
// Every wire type of this contract version lives in this file, so a version bump is one reviewable change.

public enum BrowserContract {
    public static let rpcID = "experimental.browser"
    /// The contract version this build speaks. The server's schema pins it: any other value fails `attach`.
    public static let version = 4
    /// The RPC's `control` event on `/api/event`: `rpc.<rpcID>.<event>`.
    public static let controlEventType = "rpc.experimental.browser.control"
    /// The server fails a dispatched request after this long and sends `cancel`.
    public static let serverRequestTimeout: Duration = .seconds(60)
    /// Our own deadline for a command, so the agent gets our explanation before the server's generic timeout.
    public static let defaultCommandTimeout: Duration = .seconds(50)
    public static let maxText = 100_000
    public static let maxURL = 16_384
    public static let maxTitle = 2_048
    public static let maxFileBytes = 5 * 1024 * 1024
    /// The reference desktop refuses results larger than this many JSON characters (`too_large`).
    public static let maxResultCharacters = 512_000

    /// Operations whose meaning survives a document change; every other operation checks `command.generation`.
    public static let retainedOperations: Set<String> = [
        "navigate", "files.list", "files.get", "trace.stop", "trace.analyze", "cpu.stop", "cpu.analyze",
        "heap.summary", "heap.query", "heap.object", "heap.compare",
    ]

    public static func newTabID() -> String { "tab_\(UUID().uuidString.lowercased())" }
    public static func newFileID() -> String { "file_\(UUID().uuidString.lowercased())" }

    /// `^tab_[a-f0-9-]{36}$`, the server's tab ID pattern.
    public static func isTabID(_ value: String) -> Bool {
        value.hasPrefix("tab_") && value.count == 40
            && value.dropFirst(4).allSatisfy { $0 == "-" || ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// `Browser.Tab`: one tab of the published inventory.
public struct BrowserTabInfo: Sendable, Equatable {
    public var id: String
    public var url: String
    public var title: String
    public var loading: Bool
    public var loadError: String?
    public var canGoBack: Bool
    public var canGoForward: Bool
    /// The tab's document generation: bumped on every new main-frame document.
    public var generation: Int

    public init(
        id: String, url: String, title: String, loading: Bool, loadError: String? = nil, canGoBack: Bool,
        canGoForward: Bool, generation: Int
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.loading = loading
        self.loadError = loadError
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.generation = generation
    }

    public var json: JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id), "url": .string(String(url.prefix(BrowserContract.maxURL))),
            "title": .string(String(title.prefix(BrowserContract.maxTitle))), "loading": .bool(loading),
            "canGoBack": .bool(canGoBack), "canGoForward": .bool(canGoForward), "generation": .number(Double(generation)),
        ]
        if let loadError { fields["loadError"] = .string(String(loadError.prefix(BrowserContract.maxTitle))) }
        return .object(fields)
    }
}

/// `Browser.State`: the authoritative inventory the desktop publishes. The server resolves tab IDs only from it, so a
/// tab that is not published cannot be targeted at all.
public struct BrowserInventory: Sendable, Equatable {
    public var tabs: [BrowserTabInfo]
    public var focusedTabID: String?

    public init(tabs: [BrowserTabInfo] = [], focusedTabID: String? = nil) {
        self.tabs = tabs
        self.focusedTabID = focusedTabID
    }

    public var json: JSONValue {
        ["tabs": .array(tabs.map(\.json)), "focusedTabID": focusedTabID.map(JSONValue.string) ?? .null]
    }

    public init?(json: JSONValue) {
        guard let tabs = json["tabs"]?.arrayValue else { return nil }
        self.tabs = tabs.compactMap { tab in
            guard let id = tab["id"]?.stringValue else { return nil }
            return BrowserTabInfo(
                id: id, url: tab["url"]?.stringValue ?? "", title: tab["title"]?.stringValue ?? "",
                loading: tab["loading"]?.boolValue ?? false, loadError: tab["loadError"]?.stringValue,
                canGoBack: tab["canGoBack"]?.boolValue ?? false, canGoForward: tab["canGoForward"]?.boolValue ?? false,
                generation: tab["generation"]?.intValue ?? 0)
        }
        focusedTabID = json["focusedTabID"]?.stringValue
    }
}

/// `Browser.File`. Bytes travel base64-encoded and are bounded by `BrowserContract.maxFileBytes`.
public struct BrowserFile: Sendable, Equatable {
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
        guard let id = json["id"]?.stringValue, let name = json["name"]?.stringValue, let mime = json["mime"]?.stringValue,
            let encoded = json["data"]?.stringValue, let data = Data(base64Encoded: encoded)
        else { return nil }
        self.init(id: id, name: name, mime: mime, data: data)
    }

    public var json: JSONValue {
        ["id": .string(id), "name": .string(name), "mime": .string(mime), "data": .string(data.base64EncodedString())]
    }
}

/// `Browser.Command`, fetched with the `command` method after a `command` control names its request.
public struct BrowserCommand: Sendable, Equatable {
    /// `{type: <operation>, tabID?, …}`; the rest is operation-specific and already validated by the server.
    public var action: JSONValue
    /// The target tab's published generation when the command was issued.
    public var generation: Int?
    public var files: [BrowserFile]
    /// A permission-layer inspection request: answer with target metadata only and run nothing (unused by 2.3.0).
    public var inspect: Bool
    public var target: JSONValue?

    public init(action: JSONValue, generation: Int? = nil, files: [BrowserFile] = [], inspect: Bool = false, target: JSONValue? = nil) {
        self.action = action
        self.generation = generation
        self.files = files
        self.inspect = inspect
        self.target = target
    }

    public init(json: JSONValue) throws(BrowserFailure) {
        guard let action = json["action"], action["type"]?.stringValue != nil else {
            throw BrowserFailure(.unsupported, "The command has no action type. Check desktop and server plugin versions.")
        }
        self.init(
            action: action, generation: json["generation"]?.intValue,
            files: (json["files"]?.arrayValue ?? []).compactMap(BrowserFile.init(json:)),
            inspect: json["inspect"]?.boolValue ?? false, target: json["target"])
    }

    public var json: JSONValue {
        var fields: [String: JSONValue] = ["action": action, "files": .array(files.map(\.json))]
        if let generation { fields["generation"] = .number(Double(generation)) }
        if inspect { fields["inspect"] = true }
        if let target { fields["target"] = target }
        return .object(fields)
    }

    /// The operation name, such as `click` or `tabs.open`.
    public var type: String { action["type"]?.stringValue ?? "" }
    public var tabID: String? { action["tabID"]?.stringValue }
}

/// `Browser.Result`.
public struct BrowserResult: Sendable, Equatable {
    public var value: JSONValue
    public var files: [BrowserFile]

    public init(value: JSONValue, files: [BrowserFile] = []) {
        self.value = value
        self.files = files
    }
}

/// The failure arm of `Browser.Outcome`. The server prefixes the code: the agent reads `[browser.<code>] <message>`,
/// so every message names the next step to take.
public struct BrowserFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// Failure codes. The first group is the reference desktop's; the rest are this desktop's, each documented in
    /// docs/features/browser.md.
    public struct Code: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }

        public static let disconnected: Code = "disconnected"
        public static let tabUnavailable: Code = "tab_unavailable"
        public static let timeout: Code = "timeout"
        public static let unsupported: Code = "unsupported"
        public static let cancelled: Code = "cancelled"
        public static let tooLarge: Code = "too_large"
        public static let documentChanged: Code = "document_changed"
        public static let targetChanged: Code = "target_changed"
        // This desktop's codes.
        public static let staleRef: Code = "stale_ref"
        public static let frameUnavailable: Code = "frame_unavailable"
        public static let dialogOpen: Code = "dialog_open"
        public static let noDialog: Code = "no_dialog"
        public static let invalidURL: Code = "invalid_url"
        public static let invalidKey: Code = "invalid_key"
        public static let invalidArguments: Code = "invalid_arguments"
        public static let invalidState: Code = "invalid_state"
        public static let invalidValue: Code = "invalid_value"
        public static let navigationFailed: Code = "navigation_failed"
        public static let notVisible: Code = "not_visible"
        public static let notEditable: Code = "not_editable"
        public static let scriptError: Code = "script_error"
        public static let operationFailed: Code = "operation_failed"
        public static let fileUnavailable: Code = "file_unavailable"
        public static let requestUnavailable: Code = "request_unavailable"
        /// The user paused the agent on this tab by interacting with it.
        public static let userControl: Code = "user_control"
        /// The tab is private or not shared with this thread.
        public static let notShared: Code = "not_shared"
        /// The person turned browser control off for this thread.
        public static let controlDisabled: Code = "control_disabled"
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = String(message.prefix(2_048))
    }

    public var description: String { "[browser.\(code.rawValue)] \(message)" }
}

/// `Browser.Outcome`.
public enum BrowserOutcome: Sendable, Equatable {
    case success(BrowserResult)
    case failure(BrowserFailure)

    public var json: JSONValue {
        switch self {
        case .success(let result):
            ["type": "success", "result": ["value": result.value, "files": .array(result.files.map(\.json))]]
        case .failure(let failure):
            ["type": "failure", "code": .string(failure.code.rawValue), "message": .string(failure.message)]
        }
    }

    public init?(json: JSONValue) {
        switch json["type"]?.stringValue {
        case "success":
            let result = json["result"] ?? .null
            self = .success(BrowserResult(
                value: result["value"] ?? .null, files: (result["files"]?.arrayValue ?? []).compactMap(BrowserFile.init(json:))))
        case "failure":
            self = .failure(BrowserFailure(.init(rawValue: json["code"]?.stringValue ?? ""), json["message"]?.stringValue ?? ""))
        default:
            return nil
        }
    }

    public var failure: BrowserFailure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}

/// `Browser.Control`: `{type, connectionID, requestID?, version?}` on `/api/event`.
public enum BrowserControl: Sendable, Equatable {
    /// The readiness barrier: permissions were granted and commands may follow.
    case attached(connectionID: String, version: Int)
    /// A request is ready; its arguments come from the `command` method.
    case command(connectionID: String, requestID: String)
    case cancel(connectionID: String, requestID: String)
    /// A newer server may add control types; an attachment keeps working without them.
    case unrecognized(connectionID: String?, type: String)

    public init?(json: JSONValue) {
        guard let type = json["type"]?.stringValue else { return nil }
        let connectionID = json["connectionID"]?.stringValue
        switch type {
        case "attached":
            guard let connectionID else { return nil }
            self = .attached(connectionID: connectionID, version: json["version"]?.intValue ?? 0)
        case "command", "cancel":
            guard let connectionID, let requestID = json["requestID"]?.stringValue else { return nil }
            self = type == "command"
                ? .command(connectionID: connectionID, requestID: requestID)
                : .cancel(connectionID: connectionID, requestID: requestID)
        default:
            self = .unrecognized(connectionID: connectionID, type: type)
        }
    }

    /// Decodes the control carried by an `/api/event` frame (`{type: "rpc.experimental.browser.control", data}`).
    public init?(eventJSON: Data) {
        guard let event = try? JSONValue.parse(eventJSON), event["type"]?.stringValue == BrowserContract.controlEventType,
            let data = event["data"]
        else { return nil }
        self.init(json: data)
    }

    public var connectionID: String? {
        switch self {
        case .attached(let id, _), .command(let id, _), .cancel(let id, _): id
        case .unrecognized(let id, _): id
        }
    }
}

extension OpenCodeEventEnvelope {
    /// The browser control this frame carries, if it is one (`OpenCodeEvent` models it as `.unknown`).
    public var browserControl: BrowserControl? {
        guard type == BrowserContract.controlEventType, case .unknown(_, let raw) = event else { return nil }
        return BrowserControl(eventJSON: raw)
    }
}
