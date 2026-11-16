import Foundation

// Session control routes added for the Engine (M1-A): view, agent/model switch, inbox cancel and delivery change.
// Event shapes follow Contracts/opencode-2.3.0/openapi.json. Divergence: the real server also appends
// `agent-switched` / `model-switched` messages; the mock only publishes the `*.selected` events.

extension MockOpenCodeServer {
    /// `POST /api/session/{id}/view {idle}`: records the idle transition as seen and publishes `session.viewed`.
    func viewSession(_ id: String, _ request: HTTPRequest) -> HTTPResponse {
        guard var session = state.sessions[id] else { return Self.sessionNotFound(id) }
        let body: JSONValue
        switch jsonBody(request) {
        case let .failure(error): return error
        case let .success(value): body = value
        }
        guard let idle = body["idle"]?.doubleValue else { return Self.invalid("Missing key\n  at [\"idle\"]") }
        session.viewed = Int64(idle)
        state.sessions[id] = session
        publish("session.viewed", ["sessionID": .string(id), "idle": .int(Int(idle))], location: session.directory, durable: id)
        return .noContent()
    }

    /// `POST /api/session/{id}/agent {agent}`.
    func switchAgent(_ id: String, _ request: HTTPRequest) -> HTTPResponse {
        guard var session = state.sessions[id] else { return Self.sessionNotFound(id) }
        let body: JSONValue
        switch jsonBody(request) {
        case let .failure(error): return error
        case let .success(value): body = value
        }
        guard let agent = body["agent"]?.stringValue else { return Self.invalid("Missing key\n  at [\"agent\"]") }
        let previous = session.agent
        session.agent = agent
        session.updated = now()
        state.sessions[id] = session
        publish(
            "session.agent.selected",
            .compact([("sessionID", .string(id)), ("agent", .string(agent)), ("previous", previous.map(JSONValue.string))]),
            location: session.directory, durable: id)
        return .noContent()
    }

    /// `POST /api/session/{id}/model {model}`.
    func switchModel(_ id: String, _ request: HTTPRequest) -> HTTPResponse {
        guard var session = state.sessions[id] else { return Self.sessionNotFound(id) }
        let body: JSONValue
        switch jsonBody(request) {
        case let .failure(error): return error
        case let .success(value): body = value
        }
        guard let ref = body["model"], let modelID = ref["id"]?.stringValue, let provider = ref["providerID"]?.stringValue
        else { return Self.invalid("Missing key\n  at [\"model\"]") }
        let model = ModelRef(id: modelID, providerID: provider, variant: ref["variant"]?.stringValue)
        let previous = session.model
        session.model = model
        session.updated = now()
        state.sessions[id] = session
        publish(
            "session.model.selected",
            .compact([("sessionID", .string(id)), ("model", model.json), ("previous", previous?.json)]),
            location: session.directory, durable: id)
        return .noContent()
    }

    /// `DELETE /api/session/{id}/inbox/{inboxID}`: withdraws an undelivered prompt (`session.inbox.cancelled`). An
    /// unknown or already delivered item is a no-op, as the contract lists no 404 for it.
    func cancelInboxItem(_ sessionID: String, _ inboxID: String) -> HTTPResponse {
        guard let session = state.sessions[sessionID] else { return Self.sessionNotFound(sessionID) }
        guard var pending = pendingInbox[sessionID], let index = pending.firstIndex(where: { $0.id == inboxID }) else {
            return .noContent()
        }
        pending.remove(at: index)
        pendingInbox[sessionID] = pending.isEmpty ? nil : pending
        publish(
            "session.inbox.cancelled", ["sessionID": .string(sessionID), "inboxID": .string(inboxID)],
            location: session.directory, durable: sessionID)
        return .noContent()
    }

    /// `PATCH /api/session/{id}/inbox/{inboxID} {delivery}`: 409 once the item was delivered.
    func updateInboxItem(_ sessionID: String, _ inboxID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard let session = state.sessions[sessionID] else { return Self.sessionNotFound(sessionID) }
        let body: JSONValue
        switch jsonBody(request) {
        case let .failure(error): return error
        case let .success(value): body = value
        }
        guard let delivery = body["delivery"]?.stringValue, delivery == "steer" || delivery == "queue" else {
            return Self.invalid("Expected \"steer\" | \"queue\"\n  at [\"delivery\"]")
        }
        guard var pending = pendingInbox[sessionID], let index = pending.firstIndex(where: { $0.id == inboxID }) else {
            return .error(409, tag: "ConflictError", message: "Inbox item is no longer pending: \(inboxID)")
        }
        pending[index].delivery = delivery
        if case let .object(pairs) = pending[index].json {
            pending[index].json = .object(pairs.map { $0.0 == "delivery" ? ($0.0, .string(delivery)) : $0 })
        }
        pendingInbox[sessionID] = pending
        publish(
            "session.inbox.delivery.changed",
            ["sessionID": .string(sessionID), "inboxID": .string(inboxID), "delivery": .string(delivery)],
            location: session.directory, durable: sessionID)
        return .noContent()
    }
}
