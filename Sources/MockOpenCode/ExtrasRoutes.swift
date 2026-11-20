import Foundation

// What the orchestration extras use beyond M3-A (docs/features/orchestration-extras.md), as opencode 2.3.0 does it:
// `POST /api/session/{id}/synthetic` (a labelled wake that starts a run) and `PUT /api/session/{id}/environment`.
// Session metadata (`bellocode_prs`) already round-trips through PATCH. The app tools themselves are hosted by the app
// (client MCP), which the mock does not route; scripted tool calls (`TurnStep.tool`) simulate their transcript side.

extension MockOpenCodeServer {
    func routeExtras(_ method: String, _ parts: [String], _ request: HTTPRequest) -> HTTPResponse? {
        // `POST /api/experimental/generate/text` (generate.text, stateless): BelloCode Auto's reviewer. Answers like a
        // careful reviewer: escalate when the prompt's untrusted payload mentions a script it cannot see, else allow.
        if method == "POST", parts == ["api", "experimental", "generate", "text"] {
            guard case .success(let body) = jsonBody(request), let prompt = body["prompt"]?.stringValue else {
                return .error(400, tag: "InvalidRequestError", message: "Missing key prompt")
            }
            recordedGenerations.append(body)
            if let failure = generateTextFailure, failure.modelIDs.isEmpty || failure.modelIDs.contains(body["model"]?["id"]?.stringValue ?? "") {
                return .error(failure.status, tag: failure.tag, message: failure.message, extra: failure.extra)
            }
            if !prompt.contains("BelloCode Auto's safety reviewer") {
                return .json(["data": ["text": .string("Add launch checklist\n\nGenerated statelessly.")]])
            }
            let payload = prompt.components(separatedBy: "\n\n").last ?? ""
            let text = payload.contains(".sh") || payload.contains("mystery")
                ? #"{"decision":"escalate","reason_code":"opaque_script","explanation":"Runs a script whose contents were not shown."}"#
                : #"{"decision":"allow_once","reason_code":"routine_build","explanation":"Builds and tests the project inside its container."}"#
            return .json(["data": ["text": .string(text)]])
        }
        // `POST /api/location/reload` (location.reload): every location re-reads its configuration (the mock has
        // none to read; Settings ▸ Models only needs the call to succeed).
        if method == "POST", parts == ["api", "location", "reload"] { return .noContent() }
        guard parts.count == 4, parts[0] == "api", parts[1] == "session" else { return nil }
        let id = parts[2]
        switch (method, parts[3]) {
        case ("POST", "synthetic"):
            return withSession(id) { session in
                let body: JSONValue
                switch self.jsonBody(request) {
                case .failure(let error): return error
                case .success(let value): body = value
                }
                guard let text = body["text"]?.stringValue, !text.isEmpty else {
                    return .error(400, tag: "InvalidRequestError", message: "Missing key text")
                }
                let hold = body["resume"]?.boolValue == false
                let inboxID = self.admitSynthetic(
                    to: session.id, text: text, description: nil, metadata: body["metadata"] ?? .object([]), hold: hold)
                return .json(["data": ["id": .string(inboxID), "sessionID": .string(session.id), "type": "synthetic"]])
            }
        case ("POST", "generate"):
            // session.generate: a fixed, recognisable proposal (title line, blank line, description).
            return withSession(id) { session in
                guard case .success(let body) = self.jsonBody(request), body["prompt"]?.stringValue != nil else {
                    return .error(400, tag: "InvalidRequestError", message: "Missing key prompt")
                }
                self.recordedSessionGenerations.append(session.id)
                let text = "Parser: precedence climbing for binary operators\n\nReplaces the recursive-descent expression parser with precedence climbing.\n\n- Operators keep their associativity\n- Tested with the parser suite"
                return .json(["data": ["text": .string(text), "tokens": ["input": 0, "output": 0], "cost": 0]])
            }
        case ("PUT", "environment"):
            return withSession(id) { session in
                guard case .success(let body) = self.jsonBody(request), let variables = body["variables"]?.objectEntries else {
                    return .error(400, tag: "InvalidRequestError", message: "Missing key variables")
                }
                self.state.environments[session.id] = variables.compactMapValues(\.stringValue)
                return .noContent()
            }
        default:
            return nil
        }
    }

    /// Sets one top-level metadata key on a session and publishes the change, as a plugin's `session.update` does
    /// (snapshots: the bellocode plugin's `bellocode_interrupt` record).
    public func setSessionMetadataKey(_ sessionID: String, _ key: String, _ value: JSONValue) {
        guard var session = state.sessions[sessionID] else { return }
        var pairs: [(String, JSONValue)] = []
        if case .object(let existing)? = session.metadata { pairs = existing.filter { $0.0 != key } }
        pairs.append((key, value))
        session.metadata = .object(pairs)
        state.sessions[sessionID] = session
        publish("session.metadata.updated", ["sessionID": .string(sessionID), "metadata": .object(pairs)], durable: sessionID)
    }

    /// Synthetic texts admitted so far (tests: what woke a thread, and that no secret value was ever posted).
    public var syntheticTexts: [String] { state.syntheticLog }

    /// Every session environment set through `PUT /api/session/{id}/environment` (tests: what agent shells receive).
    public var environmentText: String { String(describing: state.environments) }

    /// Every message text the mock holds, joined (tests scan it for secret values).
    public func allMessageText() -> String {
        var out: [String] = []
        for (_, messages) in state.messages {
            for message in messages { out.append(String(describing: message)) }
        }
        out.append(contentsOf: state.syntheticLog)
        for session in state.sessions.values { out.append(String(describing: session.metadata ?? .null)) }
        return out.joined(separator: "\n")
    }
}

/// A failure `generate.text` answers with (tests of provider refusals), for every model or only the listed model IDs.
public struct GenerateTextFailure: Sendable {
    public var status: Int
    public var tag: String
    public var message: String
    public var extra: [(String, JSONValue)]
    public var modelIDs: Set<String>

    public init(status: Int, tag: String, message: String, extra: [(String, JSONValue)] = [], modelIDs: Set<String> = []) {
        self.status = status
        self.tag = tag
        self.message = message
        self.extra = extra
        self.modelIDs = modelIDs
    }

    /// opencode's answer when the free tier's allowance is used up (`ProviderRequestError`, 502).
    public static func freeUsageLimit(modelIDs: Set<String> = []) -> GenerateTextFailure {
        GenerateTextFailure(
            status: 502, tag: "ProviderRequestError", message: "Free usage limit reached. Add credits or use your own provider.",
            extra: [("providerID", .string("opencode")), ("reason", .string("rate_limit")), ("status", .int(429))], modelIDs: modelIDs)
    }
}
