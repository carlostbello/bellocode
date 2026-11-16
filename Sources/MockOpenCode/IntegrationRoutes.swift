import Foundation

// Integration (provider login), credential, saved-permission and permission-evaluation routes (M1-D).
//
// Shapes follow Contracts/opencode-2.3.0/openapi.json and what the real 2.3.0 server answered in a sandbox:
// - `connect/key` stores the key without checking it with the provider (even an empty key is accepted); a missing
//   required form field is 400 `InvalidRequestError` with `kind: "integration_authorization"`.
// - Credential labels are the integration name, then "<name> 2", "<name> 3"…; the newest credential becomes active.
// - `GET /api/credential` returns secret values (as the real server does). Clients must not decode them.
// - "Always" saves a rule per project (`GET /api/permission/saved?projectID=`), shared by every session there.
// - `POST /api/session/{id}/permission` evaluates agent rules, then session rules, then saved rules (last match wins)
//   and creates a pending request only when the effect is `ask`.
// Divergences: OAuth attempts follow a scripted `MockOAuthBehaviour` instead of a real provider; connecting an
// integration "unlocks" the providers and models listed in its `MockIntegration` (the real server adds the provider
// to `/api/provider` and its models to `/api/model` the same way).

/// An integration the mock offers, with the catalog entries it unlocks once connected.
public struct MockIntegration: Sendable {
    public var id: String
    public var name: String
    /// `Integration.Method` values, as JSON.
    public var methods: [JSONValue]
    /// Providers and models that appear in the catalog while the integration has a credential.
    public var providers: [JSONValue]
    public var models: [JSONValue]

    public init(id: String, name: String, methods: [JSONValue], providers: [JSONValue] = [], models: [JSONValue] = []) {
        self.id = id
        self.name = name
        self.methods = methods
        self.providers = providers
        self.models = models
    }
}

/// How a scripted OAuth or command attempt ends.
public enum MockOAuthBehaviour: Sendable, Equatable {
    /// `auto` mode: completes on the n-th status poll (the browser callback arrived).
    case completeAfterPolls(Int)
    /// `code` mode: `complete` with exactly this code succeeds; any other code is 400.
    case code(String)
    /// The provider refused: the first poll reports `failed` with this message.
    case fail(String)
    /// The attempt expired before the user finished.
    case expire
    /// Stays pending until cancelled.
    case pending
}

struct MockCredential: Sendable {
    var id: String
    var integrationID: String
    var label: String
    var active: Bool
    var value: JSONValue
    var created: Int64

    var json: JSONValue {
        ["id": .string(id), "integrationID": .string(integrationID), "label": .string(label), "active": .bool(active),
         "value": value]
    }
}

struct MockAttempt: Sendable {
    var id: String
    var integrationID: String
    var methodID: String
    var label: String?
    var behaviour: MockOAuthBehaviour
    var polls = 0
    var status = "pending"
    var message: String?
    var created: Int64
    var expires: Int64

    var statusJSON: JSONValue {
        .compact([
            ("status", .string(status)), ("message", message.map(JSONValue.string)),
            ("time", ["created": .int(Int(created)), "expires": .int(Int(expires))]),
        ])
    }
}

struct MockSavedPermission: Sendable {
    var id: String
    var projectID: String
    var action: String
    var resource: String
    var created: Int64

    var json: JSONValue {
        ["id": .string(id), "projectID": .string(projectID), "action": .string(action), "resource": .string(resource),
         "time": ["created": .int(Int(created)), "updated": .int(Int(created))]]
    }
}

struct IntegrationState: Sendable {
    var integrations: [MockIntegration]
    var credentials: [MockCredential] = []
    var attempts: [String: MockAttempt] = [:]
    var behaviours: [String: MockOAuthBehaviour] = [:]
    var saved: [MockSavedPermission] = []
    /// Number of integration list calls that answer empty, like a cold location on the real server.
    var coldListCalls = 0
}

extension MockOpenCodeServer {
    // MARK: Public controls

    /// Scripts how OAuth (or command) attempts for `integrationID` and `methodID` end. Applies to attempts started later.
    public func setOAuthBehaviour(_ behaviour: MockOAuthBehaviour, integrationID: String, methodID: String) {
        integration.behaviours[integrationID + "/" + methodID] = behaviour
    }

    /// The next `count` integration list calls answer an empty list (a cold location), then `integration.updated`
    /// is published when the list fills.
    public func makeIntegrationsCold(calls count: Int) { integration.coldListCalls = count }

    /// Stored credentials as `(id, integrationID, label, active)`. Secrets are not returned.
    public func storedCredentials() -> [(id: String, integrationID: String, label: String, active: Bool)] {
        integration.credentials.map { ($0.id, $0.integrationID, $0.label, $0.active) }
    }

    /// Whether a stored key equals `key` (tests check that a key reached the server without reading it back).
    public func credential(_ integrationID: String, hasKey key: String) -> Bool {
        integration.credentials.contains { $0.integrationID == integrationID && $0.value["key"]?.stringValue == key }
    }

    /// Open attempts (OAuth and command), for tests asserting cancellation.
    public func openAttemptCount() -> Int { integration.attempts.values.filter { $0.status == "pending" }.count }

    // MARK: Routing

    /// Serves integration, credential, saved-permission and permission-evaluation routes; nil for anything else.
    func routeIntegrations(_ method: String, _ parts: [String], _ request: HTTPRequest) -> HTTPResponse? {
        guard parts.count >= 2, parts[0] == "api" else { return nil }
        switch (method, Array(parts.dropFirst())) {
        case ("GET", ["integration"]): return listIntegrations(request)
        case ("GET", let p) where p.count == 2 && p[0] == "integration":
            guard let item = integration.integrations.first(where: { $0.id == p[1] }) else { return Self.integrationNotFound(p[1]) }
            return located(request, integrationJSON(item))
        case ("POST", let p) where p.count == 4 && p[0] == "integration" && p[2] == "connect":
            switch p[3] {
            case "key": return connectKey(p[1], request)
            case "external": return connectExternal(p[1], request)
            case "oauth": return startAttempt(p[1], request, command: false)
            case "command": return startAttempt(p[1], request, command: true)
            default: return nil
            }
        case ("GET", let p) where p.count == 5 && p[0] == "integration" && p[2] == "connect":
            return attemptStatus(p[1], p[4], request)
        case ("DELETE", let p) where p.count == 5 && p[0] == "integration" && p[2] == "connect":
            integration.attempts[p[4]] = nil
            return .noContent()
        case ("POST", let p) where p.count == 6 && p[0] == "integration" && p[5] == "complete":
            return completeAttempt(p[1], p[4], request)
        case ("GET", ["credential"]):
            return .json(["data": .array(integration.credentials.map(\.json))])
        case ("PATCH", let p) where p.count == 2 && p[0] == "credential":
            guard let index = integration.credentials.firstIndex(where: { $0.id == p[1] }) else {
                return Self.invalid("Credential not found: \(p[1])", kind: "credential")
            }
            guard case let .success(body) = jsonBody(request), let label = body["label"]?.stringValue else {
                return Self.invalid("Missing key\n  at [\"label\"]")
            }
            integration.credentials[index].label = label
            publishCredentialUpdated(integration.credentials[index])
            return .noContent()
        case ("DELETE", let p) where p.count == 2 && p[0] == "credential":
            return removeCredential(p[1])
        case ("POST", let p) where p.count == 3 && p[0] == "credential" && p[2] == "activate":
            guard let credential = integration.credentials.first(where: { $0.id == p[1] }) else {
                return Self.invalid("Credential not found: \(p[1])", kind: "credential")
            }
            activate(credential.id, integrationID: credential.integrationID)
            return .noContent()
        case ("GET", ["permission", "saved"]):
            let projectID = request.queryValue("projectID")
            // The real server answers an empty list without a project filter.
            let saved = projectID.map { id in integration.saved.filter { $0.projectID == id } } ?? []
            return .json(["data": .array(saved.map(\.json))])
        case ("DELETE", let p) where p.count == 3 && p[0] == "permission" && p[1] == "saved":
            integration.saved.removeAll { $0.id == p[2] }
            return .noContent()
        default:
            return nil
        }
    }

    static func integrationNotFound(_ id: String) -> HTTPResponse {
        .error(404, tag: "IntegrationNotFoundError", message: "Integration not found: \(id)", extra: [("integrationID", .string(id))])
    }

    // MARK: Integrations

    private func integrationJSON(_ item: MockIntegration) -> JSONValue {
        let connections = integration.credentials.filter { $0.integrationID == item.id }.sorted { $0.created > $1.created }
            .map { credential -> JSONValue in
                ["type": "credential", "id": .string(credential.id), "label": .string(credential.label),
                 "method": .string(credential.value["type"]?.stringValue ?? "key")]
            }
        return ["id": .string(item.id), "name": .string(item.name), "methods": .array(item.methods),
                "connections": .array(connections)]
    }

    private func listIntegrations(_ request: HTTPRequest) -> HTTPResponse {
        if integration.coldListCalls > 0 {
            integration.coldListCalls -= 1
            if integration.coldListCalls == 0 { publish("integration.updated", ["id": "*"], location: location(request)) }
            return located(request, .array([]))
        }
        return located(request, .array(integration.integrations.map(integrationJSON)))
    }

    private func methodForm(_ item: MockIntegration, type: String, id: String?) -> [JSONValue]? {
        item.methods.first { $0["type"]?.stringValue == type && (id == nil || $0["id"]?.stringValue == id) }?["form"]?.arrayValue
    }

    /// Checks required visible form fields like the real server ("Missing required form field: <key>").
    private func validateAnswer(_ form: [JSONValue]?, _ answer: JSONValue?) -> HTTPResponse? {
        for field in form ?? [] where field["required"] == .bool(true) && field["hidden"] != .bool(true) {
            guard let key = field["key"]?.stringValue else { continue }
            if let conditions = field["when"]?.arrayValue, !conditions.allSatisfy({ condition in
                let actual = answer?[condition["key"]?.stringValue ?? ""]
                let equal = actual == condition["value"]
                return condition["op"]?.stringValue == "neq" ? !equal : equal
            }) {
                continue
            }
            let value = answer?[key]
            if value == nil || value == .string("") {
                return .error(
                    400, tag: "InvalidRequestError", message: "Missing required form field: \(key)",
                    extra: [("kind", "integration_authorization")])
            }
        }
        return nil
    }

    private func connectKey(_ id: String, _ request: HTTPRequest) -> HTTPResponse {
        guard let item = integration.integrations.first(where: { $0.id == id }) else { return Self.integrationNotFound(id) }
        let body: JSONValue
        switch jsonBody(request) {
        case let .failure(error): return error
        case let .success(value): body = value
        }
        guard let key = body["key"]?.stringValue else { return Self.invalid("Missing key\n  at [\"key\"]") }
        if let failure = validateAnswer(methodForm(item, type: "key", id: nil), body["answer"]) { return failure }
        store(item, value: ["type": "key", "key": .string(key)], label: body["label"]?.stringValue)
        return .noContent()
    }

    private func connectExternal(_ id: String, _ request: HTTPRequest) -> HTTPResponse {
        guard let item = integration.integrations.first(where: { $0.id == id }) else { return Self.integrationNotFound(id) }
        guard case let .success(body) = jsonBody(request), let methodID = body["methodID"]?.stringValue else {
            return Self.invalid("Missing key\n  at [\"methodID\"]")
        }
        if let failure = validateAnswer(methodForm(item, type: "external", id: methodID), body["answer"]) { return failure }
        store(item, value: ["type": "external", "methodID": .string(methodID)], label: body["label"]?.stringValue)
        return .noContent()
    }

    private func startAttempt(_ id: String, _ request: HTTPRequest, command: Bool) -> HTTPResponse {
        guard let item = integration.integrations.first(where: { $0.id == id }) else { return Self.integrationNotFound(id) }
        guard case let .success(body) = jsonBody(request), let methodID = body["methodID"]?.stringValue else {
            return Self.invalid("Missing key\n  at [\"methodID\"]")
        }
        let type = command ? "command" : "oauth"
        guard item.methods.contains(where: { $0["type"]?.stringValue == type && $0["id"]?.stringValue == methodID }) else {
            return .error(
                404, tag: "IntegrationMethodNotFoundError", message: "Integration method not found: \(methodID)",
                extra: [("integrationID", .string(id)), ("methodID", .string(methodID))])
        }
        if !command, let failure = validateAnswer(methodForm(item, type: "oauth", id: methodID), body["answer"]) { return failure }
        let behaviour = integration.behaviours[id + "/" + methodID] ?? .completeAfterPolls(2)
        let attempt = MockAttempt(
            id: makeID("att"), integrationID: id, methodID: methodID, label: body["label"]?.stringValue,
            behaviour: behaviour, created: now(), expires: now() + 600_000)
        integration.attempts[attempt.id] = attempt
        let time: JSONValue = ["created": .int(Int(attempt.created)), "expires": .int(Int(attempt.expires))]
        if command { return located(request, ["attemptID": .string(attempt.id), "time": time]) }
        let isCode = if case .code = behaviour { true } else { false }
        return located(
            request,
            .compact([
                ("attemptID", .string(attempt.id)),
                ("url", .string("https://auth.example.invalid/\(id)/authorize?attempt=\(attempt.id)")),
                ("instructions", .string(isCode ? "Sign in, then paste the code shown." : "Finish signing in in your browser.")),
                ("mode", .string(isCode ? "code" : "auto")), ("paste", isCode ? nil : .bool(true)), ("time", time),
            ]))
    }

    private func attemptStatus(_ id: String, _ attemptID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard var attempt = integration.attempts[attemptID], attempt.integrationID == id else {
            return .error(
                404, tag: "IntegrationAttemptNotFoundError", message: "Attempt not found: \(attemptID)",
                extra: [("integrationID", .string(id)), ("attemptID", .string(attemptID))])
        }
        if attempt.status == "pending" {
            attempt.polls += 1
            switch attempt.behaviour {
            case .completeAfterPolls(let count) where attempt.polls >= count:
                attempt.status = "complete"
                finish(attempt)
            case .fail(let message):
                attempt.status = "failed"
                attempt.message = message
            case .expire:
                attempt.status = "expired"
            default:
                break
            }
            integration.attempts[attemptID] = attempt
        }
        return located(request, attempt.statusJSON)
    }

    private func completeAttempt(_ id: String, _ attemptID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard var attempt = integration.attempts[attemptID], attempt.integrationID == id else {
            return .error(
                404, tag: "IntegrationAttemptNotFoundError", message: "Attempt not found: \(attemptID)",
                extra: [("integrationID", .string(id)), ("attemptID", .string(attemptID))])
        }
        let code = (try? jsonBody(request, allowEmpty: true).get())?["code"]?.stringValue
        switch attempt.behaviour {
        case .code(let expected):
            guard code == expected else {
                return .error(400, tag: "InvalidRequestError", message: "The code was not accepted.", extra: [("kind", "integration_authorization")])
            }
        case .expire:
            return .error(400, tag: "InvalidRequestError", message: "The attempt expired.", extra: [("kind", "integration_authorization")])
        default:
            break
        }
        attempt.status = "complete"
        integration.attempts[attemptID] = attempt
        finish(attempt)
        return .noContent()
    }

    private func finish(_ attempt: MockAttempt) {
        guard let item = integration.integrations.first(where: { $0.id == attempt.integrationID }) else { return }
        store(
            item,
            value: ["type": "oauth", "methodID": .string(attempt.methodID), "refresh": "mock-refresh", "access": "mock-access",
                    "expires": .int(Int(now() + 3_600_000))],
            label: attempt.label)
    }

    // MARK: Credentials

    private func store(_ item: MockIntegration, value: JSONValue, label: String?) {
        let existing = integration.credentials.filter { $0.integrationID == item.id }
        let label = label ?? (existing.isEmpty ? item.name : "\(item.name) \(existing.count + 1)")
        let credential = MockCredential(
            id: makeID("cred"), integrationID: item.id, label: label, active: true, value: value, created: now())
        for index in integration.credentials.indices where integration.credentials[index].integrationID == item.id {
            integration.credentials[index].active = false
        }
        integration.credentials.append(credential)
        let wasLocked = existing.isEmpty
        if wasLocked { unlock(item) }
        publishCredentialUpdated(credential)
        publish(
            "credential.switched", ["integrationID": .string(item.id), "credentialID": .string(credential.id)])
        publish("integration.updated", ["id": .string(item.id)], location: state.defaultDirectory)
    }

    private func activate(_ id: String, integrationID: String) {
        for index in integration.credentials.indices where integration.credentials[index].integrationID == integrationID {
            integration.credentials[index].active = integration.credentials[index].id == id
        }
        publish("credential.switched", ["integrationID": .string(integrationID), "credentialID": .string(id)])
    }

    private func removeCredential(_ id: String) -> HTTPResponse {
        guard let index = integration.credentials.firstIndex(where: { $0.id == id }) else { return .noContent() }
        let removed = integration.credentials.remove(at: index)
        let rest = integration.credentials.filter { $0.integrationID == removed.integrationID }
        if removed.active, let next = rest.max(by: { $0.created < $1.created }) {
            activate(next.id, integrationID: removed.integrationID)
        } else if rest.isEmpty {
            publish("credential.switched", ["integrationID": .string(removed.integrationID), "credentialID": .null])
            if let item = integration.integrations.first(where: { $0.id == removed.integrationID }) { lock(item) }
        }
        publish("integration.updated", ["id": .string(removed.integrationID)], location: state.defaultDirectory)
        return .noContent()
    }

    private func publishCredentialUpdated(_ credential: MockCredential) {
        publish("credential.updated", ["integrationID": .string(credential.integrationID), "credentialID": .string(credential.id)])
    }

    private func unlock(_ item: MockIntegration) {
        let providerIDs = Set(state.catalog.providers.compactMap { $0["id"]?.stringValue })
        let newProviders = item.providers.filter { !providerIDs.contains($0["id"]?.stringValue ?? "") }
        guard !newProviders.isEmpty else { return }
        state.catalog.providers += newProviders
        state.catalog.models += item.models
        publish("provider.updated", ["id": .string(item.id)], location: state.defaultDirectory)
    }

    private func lock(_ item: MockIntegration) {
        let ids = Set(item.providers.compactMap { $0["id"]?.stringValue })
        guard !ids.isEmpty else { return }
        state.catalog.providers.removeAll { ids.contains($0["id"]?.stringValue ?? "") }
        state.catalog.models.removeAll { ids.contains($0["providerID"]?.stringValue ?? "") }
        publish("provider.updated", ["id": .string(item.id)], location: state.defaultDirectory)
    }

    // MARK: Permission evaluation

    /// Agent rules, then the session's rules, then saved project rules; the last match wins; no match asks.
    func evaluate(action: String, resources: [String], session: MockSession, agent: String?) -> String {
        let agentID = agent ?? session.agent ?? state.defaultAgent
        let agentRules = state.catalog.agents.first { $0["id"]?.stringValue == agentID }?["permissions"]?.arrayValue ?? []
        let sessionRules = session.permissions?.arrayValue ?? []
        let saved = integration.saved.filter { $0.projectID == session.projectID }.map { saved -> JSONValue in
            ["action": .string(saved.action), "resource": .string(saved.resource), "effect": "allow"]
        }
        let rules = agentRules + sessionRules + saved
        var effects: [String] = []
        for resource in resources.isEmpty ? ["*"] : resources {
            var effect = "ask"
            for rule in rules {
                guard let ruleAction = rule["action"]?.stringValue, let pattern = rule["resource"]?.stringValue,
                    let ruleEffect = rule["effect"]?.stringValue
                else { continue }
                if Self.wildcard(ruleAction, matches: action), Self.wildcard(pattern, matches: resource) { effect = ruleEffect }
            }
            effects.append(effect)
        }
        if effects.contains("deny") { return "deny" }
        if effects.contains("ask") { return "ask" }
        return "allow"
    }

    /// `*` matches any run of characters (including `/`), `?` one character.
    static func wildcard(_ pattern: String, matches value: String) -> Bool {
        let p = Array(pattern)
        let v = Array(value)
        var pi = 0, vi = 0, star = -1, mark = 0
        while vi < v.count {
            if pi < p.count, p[pi] == "?" || p[pi] == v[vi] {
                pi += 1
                vi += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = vi
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                vi = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Records an "always" reply as saved project rules (one per `save` pattern, else per resource).
    func saveAlways(action: String, patterns: [String], sessionID: String) {
        guard let projectID = state.sessions[sessionID]?.projectID else { return }
        for pattern in patterns where !integration.saved.contains(where: {
            $0.projectID == projectID && $0.action == action && $0.resource == pattern
        }) {
            integration.saved.append(
                MockSavedPermission(id: makeID("psv"), projectID: projectID, action: action, resource: pattern, created: now()))
        }
    }
}
