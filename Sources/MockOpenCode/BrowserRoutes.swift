import Foundation

// A scripted simulation of opencode 2.3.0's built-in browser plugin RPC (`experimental.browser`, contract version 4;
// docs/spikes/G3-browser-bridge.md), so a desktop browser bridge can be tested offline:
//
// - `attach` stays pending (a long poll) until the attachment is replaced, closed or abandoned by the client, and
//   emits the `attached` control first; a second attach for the same session returns `replaced` to the first;
// - `state` stores the published inventory; `command` hands out a pending request; `result` settles it;
// - tests play the agent with `issueBrowserCommand`, which emits a `command` control and waits for the result, a
//   timeout (then a `cancel` control, like the server's 60 s limit) or a disconnect;
// - `setBrowserContractVersion` simulates a server that speaks another version (attach fails schema validation).
//
// Session instruction entries (`/api/experimental/session/{id}/instructions/entries`) are served too.

/// The mock's view of one desktop attachment.
public struct MockBrowserAttachment: Sendable, Equatable {
    public var sessionID: String
    public var connectionID: String
    /// The last inventory the desktop published (`Browser.State`), nil before the first `state`.
    public var state: JSONValue?
    public var stateCount: Int
}

/// What the simulated agent got back for one browser command.
public enum MockBrowserOutcome: Sendable, Equatable {
    case success(value: JSONValue, fileCount: Int)
    case failure(code: String, message: String)
    /// No result within the timeout; the mock sent `cancel`.
    case timedOut
    /// The test cancelled it (the agent's turn was interrupted); the mock sent `cancel`.
    case cancelled
    /// The attachment closed or was replaced while the request was pending.
    case disconnected
    /// No desktop is attached to the session: nothing was dispatched.
    case notAttached

    public var failureCode: String? {
        if case .failure(let code, _) = self { code } else { nil }
    }

    public var value: JSONValue? {
        if case .success(let value, _) = self { value } else { nil }
    }
}

struct MockBrowserState {
    struct Attachment {
        var sessionID: String
        var connectionID: String
        var pollID: Int
        var state: JSONValue?
        var stateCount = 0
    }

    struct Pending {
        var sessionID: String
        var connectionID: String
        var command: JSONValue
        var continuation: CheckedContinuation<MockBrowserOutcome, Never>?
    }

    var attachments: [String: Attachment] = [:]
    var polls: [Int: CheckedContinuation<HTTPResponse?, Never>] = [:]
    /// Responses decided before the connection task started waiting.
    var settledPolls: [Int: HTTPResponse?] = [:]
    var pollSessions: [Int: String] = [:]
    var nextPollID = 0
    var pending: [String: Pending] = [:]
    var issued: [String] = []
    var expectedVersion = 4
    /// Overrides the version announced in the `attached` control (a server that accepted attach but speaks another).
    var announcedVersion: Int?
    /// Session instruction entries, by session then key.
    var instructionEntries: [String: [String: JSONValue]] = [:]
}

extension MockOpenCodeServer {
    // MARK: Test controls

    public func browserAttachment(for sessionID: String) -> MockBrowserAttachment? {
        browser.attachments[sessionID].map {
            MockBrowserAttachment(sessionID: $0.sessionID, connectionID: $0.connectionID, state: $0.state, stateCount: $0.stateCount)
        }
    }

    /// The contract version the simulated plugin's schema accepts (4 in opencode 2.3.0).
    public func setBrowserContractVersion(_ version: Int) { browser.expectedVersion = version }

    /// Announces this version in the `attached` control instead of the accepted one (nil: the accepted one).
    public func setBrowserAnnouncedVersion(_ version: Int?) { browser.announcedVersion = version }

    /// The instruction entries stored for a session.
    public func instructionEntries(for sessionID: String) -> [String: JSONValue] { browser.instructionEntries[sessionID] ?? [:] }

    /// Request IDs of every command issued so far, oldest first.
    public func issuedBrowserRequests() -> [String] { browser.issued }

    /// Plays the agent: dispatches `action` (`{type, tabID?, …}`) to the session's desktop and waits for its result.
    /// `generation` defaults to the target tab's published generation.
    public func issueBrowserCommand(
        sessionID: String, action: JSONValue, generation: Int? = nil, files: [JSONValue] = [], timeout: Duration = .seconds(60)
    ) async -> MockBrowserOutcome {
        guard let attachment = browser.attachments[sessionID] else { return .notAttached }
        let requestID = UUID().uuidString.lowercased()
        var command: [(String, JSONValue)] = [("action", action), ("files", .array(files))]
        let tabID = action["tabID"]?.stringValue
        let published = attachment.state?["tabs"]?.arrayValue?.first { $0["id"]?.stringValue == tabID }
        if let generation = generation ?? published?["generation"]?.intValue { command.append(("generation", .int(generation))) }
        browser.issued.append(requestID)
        if browser.issued.count > 500 { browser.issued.removeFirst(100) }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.endBrowserRequest(requestID, with: .timedOut, sendCancel: true)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            browser.pending[requestID] = MockBrowserState.Pending(
                sessionID: sessionID, connectionID: attachment.connectionID, command: .object(command), continuation: continuation)
            publishBrowserControl([
                ("type", "command"), ("connectionID", .string(attachment.connectionID)), ("requestID", .string(requestID)),
            ])
        }
    }

    /// Cancels every pending command of a session, like an interrupted agent turn (emits `cancel` controls).
    public func cancelBrowserCommands(sessionID: String) {
        for (id, request) in browser.pending where request.sessionID == sessionID {
            endBrowserRequest(id, with: .cancelled, sendCancel: true)
        }
    }

    /// Ends a session's attachment from the server side (`attach` returns `closed`), as on session delete or plugin
    /// disposal.
    public func closeBrowserAttachment(sessionID: String) {
        guard let attachment = browser.attachments.removeValue(forKey: sessionID) else { return }
        settlePoll(attachment.pollID, output: "closed")
        failPending(connectionID: attachment.connectionID)
        revokeBrowserPermissions(sessionID)
    }

    // MARK: Routes

    func routeBrowser(_ method: String, _ parts: [String], _ request: HTTPRequest) -> ResponsePlan? {
        if parts.count == 4, parts[0] == "api", parts[1] == "rpc", method == "POST" {
            if parts[2] == "bellocode" { return orchestrationRPC(parts[3], directory: request.query.first { $0.name == "location[directory]" }?.value) }
            guard parts[2] == "experimental.browser" else {
                return .response(.error(400, tag: "RpcError", message: "No RPC is registered for \(parts[2]).", extra: [("type", "unavailable")]))
            }
            return browserRPC(parts[3], request)
        }
        if parts.count >= 6, parts[0] == "api", parts[1] == "experimental", parts[2] == "session", parts[4] == "instructions",
            parts[5] == "entries"
        {
            return .response(instructionRoute(method, sessionID: parts[3], key: parts.count == 7 ? parts[6] : nil, request))
        }
        return nil
    }

    private func browserRPC(_ name: String, _ request: HTTPRequest) -> ResponsePlan {
        let input: JSONValue
        switch jsonBody(request) {
        case .failure(let error): return .response(error)
        case .success(let body): input = body["input"] ?? .null
        }
        guard let sessionID = input["sessionID"]?.stringValue, let connectionID = input["connectionID"]?.stringValue else {
            return .response(.error(400, tag: "InvalidRequestError", message: "Expected sessionID and connectionID"))
        }
        switch name {
        case "attach":
            guard input["version"]?.intValue == browser.expectedVersion else {
                // The real server's answer (opencode 2.3.0): schema validation of the RPC input.
                return .response(.error(
                    400, tag: "RpcError", message: "Expected \(browser.expectedVersion)\n  at [\"version\"]", extra: [("type", "rpc.invalid_input")]))
            }
            guard state.sessions[sessionID] != nil else { return .response(Self.unavailable("Session not found.")) }
            if let previous = browser.attachments[sessionID] {
                settlePoll(previous.pollID, output: "replaced")
                failPending(connectionID: previous.connectionID)
            }
            browser.nextPollID += 1
            let pollID = browser.nextPollID
            browser.attachments[sessionID] = MockBrowserState.Attachment(sessionID: sessionID, connectionID: connectionID, pollID: pollID)
            browser.pollSessions[pollID] = sessionID
            grantBrowserPermissions(sessionID)
            publishBrowserControl([
                ("type", "attached"), ("connectionID", .string(connectionID)),
                ("version", .int(browser.announcedVersion ?? browser.expectedVersion)),
            ])
            return .longPoll(id: pollID)
        case "state":
            guard var attachment = browser.attachments[sessionID], attachment.connectionID == connectionID else {
                return .response(Self.unavailable("Browser is unavailable."))
            }
            attachment.state = input["state"]
            attachment.stateCount += 1
            browser.attachments[sessionID] = attachment
            return .response(.json([:]))
        case "command":
            guard let requestID = input["requestID"]?.stringValue, let pending = browser.pending[requestID],
                pending.connectionID == connectionID, browser.attachments[sessionID]?.connectionID == connectionID
            else { return .response(Self.unavailable("Browser request is no longer available.")) }
            return .response(.json(["output": pending.command]))
        case "result":
            guard browser.attachments[sessionID]?.connectionID == connectionID else {
                return .response(Self.unavailable("Browser is unavailable."))
            }
            if let requestID = input["requestID"]?.stringValue, browser.pending[requestID]?.connectionID == connectionID {
                let outcome = input["outcome"] ?? .null
                let settled: MockBrowserOutcome = outcome["type"]?.stringValue == "success"
                    ? .success(value: outcome["result"]?["value"] ?? .null, fileCount: outcome["result"]?["files"]?.arrayValue?.count ?? 0)
                    : .failure(code: outcome["code"]?.stringValue ?? "", message: outcome["message"]?.stringValue ?? "")
                endBrowserRequest(requestID, with: settled, sendCancel: false)
            }
            return .response(.json([:]))
        default:
            return .response(.error(400, tag: "InvalidRequestError", message: "Unknown method \(name)"))
        }
    }

    static func unavailable(_ message: String) -> HTTPResponse {
        .error(400, tag: "RpcError", message: message, extra: [("type", "unavailable")])
    }

    private func instructionRoute(_ method: String, sessionID: String, key: String?, _ request: HTTPRequest) -> HTTPResponse {
        guard state.sessions[sessionID] != nil else { return Self.sessionNotFound(sessionID) }
        if let key {
            guard key.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil else {
                return Self.invalid("Invalid instruction entry key")
            }
            switch method {
            case "PUT":
                switch jsonBody(request) {
                case .failure(let error): return error
                case .success(let body):
                    guard let value = body["value"] else { return Self.invalid("Expected value") }
                    browser.instructionEntries[sessionID, default: [:]][key] = value
                    return .noContent()
                }
            case "DELETE":
                browser.instructionEntries[sessionID]?[key] = nil
                return .noContent()
            default:
                return Self.notFound(request)
            }
        }
        guard method == "GET" else { return Self.notFound(request) }
        let entries = (browser.instructionEntries[sessionID] ?? [:]).sorted { $0.key < $1.key }
        return .json(["data": .array(entries.map { ["key": .string($0.key), "value": $0.value] })])
    }

    // MARK: Long polls

    /// Waits for the long-poll response; nil when the client went away first.
    func longPollResponse(_ id: Int) async -> HTTPResponse? {
        if let settled = browser.settledPolls.removeValue(forKey: id) { return settled }
        return await withCheckedContinuation { browser.polls[id] = $0 }
    }

    /// The client closed the connection of a pending long poll: the attachment ends (the real server detaches).
    func abandonLongPoll(_ id: Int) {
        if let waiter = browser.polls.removeValue(forKey: id) { waiter.resume(returning: nil) } else if browser.settledPolls[id] == nil {
            browser.settledPolls[id] = .some(nil)
        }
        guard let sessionID = browser.pollSessions.removeValue(forKey: id), let attachment = browser.attachments[sessionID],
            attachment.pollID == id
        else { return }
        browser.attachments[sessionID] = nil
        failPending(connectionID: attachment.connectionID)
        revokeBrowserPermissions(sessionID)
    }

    private func settlePoll(_ id: Int, output: String) {
        browser.pollSessions[id] = nil
        let response = HTTPResponse.json(["output": .string(output)])
        if let waiter = browser.polls.removeValue(forKey: id) { waiter.resume(returning: response) } else {
            browser.settledPolls[id] = response
        }
    }

    private func failPending(connectionID: String) {
        for (id, request) in browser.pending where request.connectionID == connectionID {
            endBrowserRequest(id, with: .disconnected, sendCancel: false)
        }
    }

    private func endBrowserRequest(_ requestID: String, with outcome: MockBrowserOutcome, sendCancel: Bool) {
        guard let request = browser.pending.removeValue(forKey: requestID) else { return }
        if sendCancel {
            publishBrowserControl([
                ("type", "cancel"), ("connectionID", .string(request.connectionID)), ("requestID", .string(requestID)),
            ])
        }
        request.continuation?.resume(returning: outcome)
    }

    private func publishBrowserControl(_ pairs: [(String, JSONValue)]) {
        publish("rpc.experimental.browser.control", .object(pairs))
    }

    // MARK: Permissions (the plugin appends allow rules on attach and removes them on detach)

    private static let browserRules: [JSONValue] = [
        ["action": "browser", "resource": "*", "effect": "allow"], ["action": "skill", "resource": "browser", "effect": "allow"],
    ]

    private func grantBrowserPermissions(_ sessionID: String) {
        guard var session = state.sessions[sessionID] else { return }
        var rules = session.permissions?.arrayValue ?? []
        rules.removeAll { Self.browserRules.contains($0) }
        rules += Self.browserRules
        session.permissions = .array(rules)
        state.sessions[sessionID] = session
    }

    private func revokeBrowserPermissions(_ sessionID: String) {
        guard var session = state.sessions[sessionID], let rules = session.permissions?.arrayValue else { return }
        session.permissions = .array(rules.filter { !Self.browserRules.contains($0) })
        state.sessions[sessionID] = session
    }
}
