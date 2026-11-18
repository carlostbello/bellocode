import Foundation

// What the orchestration extras use beyond M3-A (docs/features/orchestration-extras.md), as opencode 2.3.0 does it:
// `POST /api/session/{id}/synthetic` (a labelled wake that starts a run) and `PUT /api/session/{id}/environment`.
// Session metadata (`bellocode_prs`) already round-trips through PATCH. The app tools themselves are hosted by the app
// (client MCP), which the mock does not route; scripted tool calls (`TurnStep.tool`) simulate their transcript side.

extension MockOpenCodeServer {
    func routeExtras(_ method: String, _ parts: [String], _ request: HTTPRequest) -> HTTPResponse? {
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
            return withSession(id) { _ in
                guard case .success(let body) = self.jsonBody(request), body["prompt"]?.stringValue != nil else {
                    return .error(400, tag: "InvalidRequestError", message: "Missing key prompt")
                }
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

    /// Synthetic texts admitted so far (tests: what woke a thread, and that no secret value was ever posted).
    public var syntheticTexts: [String] { state.syntheticLog }

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
