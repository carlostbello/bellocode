import Foundation

/// The mutable data the server serves.
struct ServerState: Sendable {
    var defaultDirectory: String
    var projects: [MockProject]
    var sessions: [String: MockSession] = [:]
    var sessionOrder: [String] = []
    var messages: [String: [MockMessage]]
    var permissions: [MockPermission] = []
    var forms: [MockForm] = []
    var settledForms: Set<String> = []
    var catalog: MockCatalog
    var scripts: [String: TurnScript]
    var defaultScript: TurnScript
    var defaultAgent: String
    var defaultModel: ModelRef
    var sequences: [String: Int] = [:]
    /// Admitted inbox items per session, by id, for idempotent `prompt`.
    var inbox: [String: [String: JSONValue]] = [:]
    /// `always` replies: session id → "action\u{0}resource".
    var allowed: [String: Set<String>] = [:]

    init(scenario: Scenario) {
        defaultDirectory = scenario.defaultDirectory
        projects = scenario.projects
        messages = scenario.messages
        catalog = scenario.catalog
        scripts = scenario.scripts
        defaultScript = scenario.defaultScript
        defaultAgent = scenario.defaultAgent
        defaultModel = scenario.defaultModel
        for session in scenario.sessions {
            sessions[session.id] = session
            sessionOrder.append(session.id)
            // Preloaded sessions already have history, so their durable sequence does not start at zero.
            sequences[session.id] = (scenario.messages[session.id]?.count ?? 0) + 1
        }
    }

    mutating func nextSeq(_ aggregate: String) -> Int {
        let seq = sequences[aggregate] ?? 0
        sequences[aggregate] = seq + 1
        return seq
    }

    func project(containing directory: String) -> MockProject? {
        projects.filter { $0.contains(directory: directory) }.max { $0.directory.count < $1.directory.count }
    }
}

extension MockOpenCodeServer {
    // MARK: Routing

    func route(_ request: HTTPRequest, connectionID: Int) async -> ResponsePlan {
        let parts = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let method = request.method

        func match(_ pattern: String) -> [String]? {
            let expected = pattern.split(separator: "/").map(String.init)
            guard expected.count == parts.count else { return nil }
            var captures: [String] = []
            for (want, got) in zip(expected, parts) {
                if want.hasPrefix(":") { captures.append(got) } else if want != got { return nil }
            }
            return captures
        }

        if method == "GET", parts.isEmpty || parts == ["doc"] || parts == ["health"] {
            return .response(
                HTTPResponse(
                    status: 200, headers: [("content-type", "text/html; charset=utf-8")],
                    body: Data("<!doctype html><title>opencode (mock)</title>".utf8)))
        }
        if method == "GET", match("api/event") != nil {
            return .eventStream(subscriberID: openSubscriber(connectionID: connectionID, types: eventTypes(request)))
        }

        if let response = routeIntegrations(method, parts, request) { return .response(response) }
        if let response = routeWorkspace(method, parts, request) { return .response(response) }
        let response: HTTPResponse
        switch method {
        case "GET":
            if match("api/info") != nil {
                response = serverInfo()
            } else if match("api/project") != nil {
                response = listProjects(request)
            } else if match("api/session") != nil {
                response = listSessions(request)
            } else if let c = match("api/session/:id") {
                response = withSession(c[0]) { .json(["data": $0.json]) }
            } else if let c = match("api/session/:id/message") {
                response = listMessages(c[0], request)
            } else if let c = match("api/session/:id/inbox") {
                response = withSession(c[0]) { .json(["data": self.inboxJSON($0.id)]) }
            } else if let c = match("api/session/:id/message/:mid") {
                response = getMessage(c[0], c[1])
            } else if match("api/permission/request") != nil {
                response = listPermissions(request)
            } else if let c = match("api/session/:id/permission") {
                response = withSession(c[0]) { session in
                    .json(["data": .array(self.state.permissions.filter { $0.sessionID == session.id }.map(\.json))])
                }
            } else if let c = match("api/session/:id/permission/:rid") {
                response = withSession(c[0]) { _ in
                    guard let permission = self.state.permissions.first(where: { $0.id == c[1] }) else {
                        return Self.permissionNotFound(c[1])
                    }
                    return .json(["data": permission.json])
                }
            } else if match("api/form") != nil {
                response = listForms(request)
            } else if let c = match("api/session/:id/form") {
                response = withSession(c[0]) { session in
                    .json(["data": .array(self.state.forms.filter { $0.sessionID == session.id }.map(\.json))])
                }
            } else if let c = match("api/session/:id/form/:fid") {
                response = withSession(c[0]) { _ in
                    guard let form = self.state.forms.first(where: { $0.id == c[1] }) else {
                        return Self.formNotFound(c[1])
                    }
                    return .json(["data": form.json])
                }
            } else if match("api/provider") != nil {
                response = located(request, .array(state.catalog.providers))
            } else if let c = match("api/provider/:id") {
                response = catalogItem(request, state.catalog.providers, id: c[0], tag: "ProviderNotFoundError")
            } else if match("api/model") != nil {
                response = listModels(request)
            } else if match("api/model/default") != nil {
                let model = state.catalog.models.first { $0["id"]?.stringValue == state.catalog.defaultModelID }
                response = located(request, model ?? .null)
            } else if match("api/agent") != nil {
                response = located(request, .array(state.catalog.agents))
            } else if let c = match("api/agent/:id") {
                response = catalogItem(request, state.catalog.agents, id: c[0], tag: "AgentNotFoundError")
            } else {
                response = Self.notFound(request)
            }
        case "POST":
            if match("api/session") != nil {
                response = createSession(request)
            } else if let c = match("api/session/:id/prompt") {
                response = prompt(c[0], request)
            } else if let c = match("api/session/:id/interrupt") {
                response = withSession(c[0]) { session in
                    .json(["interrupted": .bool(self.interrupt(session.id, resume: request.queryValue("resume") == "true"))])
                }
            } else if let c = match("api/session/:id/permission") {
                response = createPermission(c[0], request)
            } else if let c = match("api/session/:id/permission/:rid/reply") {
                response = replyPermission(c[0], c[1], request)
            } else if let c = match("api/session/:id/form") {
                response = createForm(c[0], request)
            } else if let c = match("api/session/:id/form/:fid/reply") {
                response = replyForm(c[0], c[1], request)
            } else if let c = match("api/session/:id/view") {
                response = viewSession(c[0], request)
            } else if let c = match("api/session/:id/agent") {
                response = switchAgent(c[0], request)
            } else if let c = match("api/session/:id/model") {
                response = switchModel(c[0], request)
            } else {
                response = Self.notFound(request)
            }
        case "PATCH":
            if let c = match("api/session/:id") {
                response = updateSession(c[0], request)
            } else if let c = match("api/session/:id/inbox/:iid") {
                response = updateInboxItem(c[0], c[1], request)
            } else {
                response = Self.notFound(request)
            }
        case "DELETE":
            if let c = match("api/session/:id") {
                response = deleteSession(c[0])
            } else if let c = match("api/session/:id/form/:fid") {
                response = cancelForm(c[0], c[1])
            } else if let c = match("api/session/:id/inbox/:iid") {
                response = cancelInboxItem(c[0], c[1])
            } else {
                response = Self.notFound(request)
            }
        default:
            response = Self.notFound(request)
        }
        return .response(response)
    }

    // MARK: Helpers

    static func notFound(_ request: HTTPRequest) -> HTTPResponse {
        .error(404, tag: "NotFoundError", message: "No route for \(request.method) \(request.path)")
    }

    static func sessionNotFound(_ id: String) -> HTTPResponse {
        .error(404, tag: "SessionNotFoundError", message: "Session not found: \(id)", extra: [("sessionID", .string(id))])
    }

    static func permissionNotFound(_ id: String) -> HTTPResponse {
        .error(
            404, tag: "PermissionNotFoundError", message: "Permission request not found: \(id)",
            extra: [("requestID", .string(id))])
    }

    static func formNotFound(_ id: String) -> HTTPResponse {
        .error(404, tag: "FormNotFoundError", message: "Form not found: \(id)", extra: [("id", .string(id))])
    }

    static func invalid(_ message: String, kind: String = "Payload") -> HTTPResponse {
        .json(["_tag": "InvalidRequestError", "message": .string(message), "kind": .string(kind)], status: 400)
    }

    func withSession(_ id: String, _ body: (MockSession) -> HTTPResponse) -> HTTPResponse {
        guard let session = state.sessions[id] else { return Self.sessionNotFound(id) }
        return body(session)
    }

    /// Parses a JSON object body; an empty body counts as `{}` only when `allowEmpty`.
    func jsonBody(_ request: HTTPRequest, allowEmpty: Bool = false) -> Result<JSONValue, HTTPResponse> {
        if request.body.isEmpty, allowEmpty { return .success([:]) }
        guard let value = try? JSONValue.parse(request.body), value.objectValue != nil else {
            return .failure(Self.invalid("Expected a valid JSON body"))
        }
        return .success(value)
    }

    /// The location a request names: `location[directory]` query, else `x-opencode-directory`, else the default.
    func location(_ request: HTTPRequest) -> String {
        if let directory = request.queryValue("location[directory]"), !directory.isEmpty { return directory }
        if let header = request.headers["x-opencode-directory"], !header.isEmpty {
            return header.removingPercentEncoding ?? header
        }
        return state.defaultDirectory
    }

    func located(_ request: HTTPRequest, _ data: JSONValue) -> HTTPResponse {
        .json(["location": ["directory": .string(location(request))], "data": data])
    }

    func catalogItem(_ request: HTTPRequest, _ items: [JSONValue], id: String, tag: String) -> HTTPResponse {
        guard let item = items.first(where: { $0["id"]?.stringValue == id }) else {
            return .error(404, tag: tag, message: "Not found: \(id)")
        }
        return located(request, item)
    }

    func eventTypes(_ request: HTTPRequest) -> Set<String>? {
        // Repeated `types=a&types=b` (the OpenAPI form style); comma-separated values are accepted too.
        let values = request.queryValues("types").flatMap { $0.split(separator: ",").map(String.init) }
        return values.isEmpty ? nil : Set(values)
    }

    // MARK: Server, projects, catalog

    func serverInfo() -> HTTPResponse {
        let url = endpoint?.url.absoluteString ?? ""
        return .json([
            "version": .string(options.version), "pid": .int(Int(ProcessInfo.processInfo.processIdentifier) + pidGeneration * 100_000),
            "hostname": "mock.local", "urls": [.string(url)],
            "paths": ["tmp": .string(FileManager.default.temporaryDirectory.appendingPathComponent("opencode").path)],
            "capabilities": ["persistentPty": true],
        ])
    }

    func listProjects(_ request: HTTPRequest) -> HTTPResponse {
        .json(.array(state.projects.map(\.json)))
    }

    func listModels(_ request: HTTPRequest) -> HTTPResponse {
        let types = Set(request.queryValues("types"))
        let models = types.isEmpty
            ? state.catalog.models
            : state.catalog.models.filter { types.contains($0["type"]?.stringValue ?? "chat") }
        return located(request, .array(models))
    }

    // MARK: Paging

    /// Anchor-based paging like the real server: `cursor.next` continues after the last item, `cursor.previous`
    /// before the first. Both are `null` for an empty page.
    func page(
        _ ids: [String], request: HTTPRequest, extra: [(String, JSONValue)] = [],
        anchorTime: (String) -> Int64? = { _ in nil }
    ) -> Result<(page: [String], cursor: JSONValue), HTTPResponse> {
        var limit: Int?
        if let raw = request.queryValue("limit") {
            guard let value = Int(raw), value >= 0 else {
                return .failure(Self.invalid("Expected an integer\n  at [\"limit\"]", kind: "Query"))
            }
            limit = value
        }
        var window = ids[...]
        if let raw = request.queryValue("cursor") {
            guard let anchor = Self.decodeCursor(raw), let id = anchor["id"]?.stringValue,
                let direction = anchor["direction"]?.stringValue
            else {
                return .failure(.json(["_tag": "InvalidCursorError", "message": "Invalid cursor"], status: 400))
            }
            let index = ids.firstIndex(of: id)
            if direction == "previous" {
                let before = index.map { ids[..<$0] } ?? []
                window = limit.map { before.suffix($0) } ?? before
            } else {
                window = index.map { ids[ids.index(after: $0)...] } ?? []
            }
        }
        let page = Array(limit.map { window.prefix($0) } ?? window)
        guard let first = page.first, let last = page.last else {
            return .success((page, ["previous": .null, "next": .null]))
        }
        func cursor(_ id: String, _ direction: String) -> JSONValue {
            let time = anchorTime(id).map { [("time", JSONValue.int(Int($0)))] } ?? []
            let anchor: JSONValue = .object(
                extra + [("anchor", .object([("id", .string(id))] + time + [("direction", .string(direction))]))])
            return .string(Self.encodeCursor(anchor))
        }
        return .success((page, ["previous": cursor(first, "previous"), "next": cursor(last, "next")]))
    }

    static func encodeCursor(_ value: JSONValue) -> String {
        value.data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The order of a list request: the `order` parameter, else the order the cursor was created with (a cursor must
    /// not be combined with `order`, so following one keeps the first page's direction), else `desc`.
    func listOrder(_ request: HTTPRequest) -> String {
        if let order = request.queryValue("order") { return order }
        if let raw = request.queryValue("cursor"), let order = Self.decodeCursorEnvelope(raw)?["order"]?.stringValue {
            return order
        }
        return "desc"
    }

    static func decodeCursorEnvelope(_ text: String) -> JSONValue? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONValue.parse(data)
    }

    static func decodeCursor(_ text: String) -> JSONValue? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), let value = try? JSONValue.parse(data) else { return nil }
        return value["anchor"]
    }

    // MARK: Sessions

    func listSessions(_ request: HTTPRequest) -> HTTPResponse {
        var sessions = state.sessionOrder.compactMap { state.sessions[$0] }
        if let parent = request.queryValue("parentID") {
            sessions = sessions.filter { parent == "null" ? $0.parentID == nil : $0.parentID == parent }
        }
        if let archived = request.queryValue("archived") {
            sessions = sessions.filter { ($0.archived != nil) == (archived == "true") }
        }
        if let directory = request.queryValue("directory") {
            sessions = sessions.filter { $0.directory == directory }
        }
        if let project = request.queryValue("project") {
            sessions = sessions.filter { $0.projectID == project }
        }
        if let search = request.queryValue("search")?.lowercased(), !search.isEmpty {
            sessions = sessions.filter { ($0.title ?? "").lowercased().contains(search) }
        }
        // The real server orders by last update (verified against 2.3.0), newest first unless `order=asc`.
        let ascending = listOrder(request) == "asc"
        let position = Dictionary(uniqueKeysWithValues: state.sessionOrder.enumerated().map { ($1, $0) })
        sessions.sort {
            let a = ($0.updated, position[$0.id] ?? 0)
            let b = ($1.updated, position[$1.id] ?? 0)
            return ascending ? a < b : a > b
        }
        var extra: [(String, JSONValue)] = []
        if let parent = request.queryValue("parentID") { extra.append(("parentID", .string(parent))) }
        if ascending { extra.append(("order", "asc")) }
        let updated = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.updated) })
        switch page(sessions.map(\.id), request: request, extra: extra, anchorTime: { updated[$0] }) {
        case let .failure(error): return error
        case let .success((ids, cursor)):
            return .json(["data": .array(ids.compactMap { state.sessions[$0]?.json }), "cursor": cursor])
        }
    }

    func createSession(_ request: HTTPRequest) -> HTTPResponse {
        let body: JSONValue
        switch jsonBody(request, allowEmpty: true) {
        case let .failure(error): return error
        case let .success(value): body = value
        }
        let parentID = body["parentID"]?.stringValue
        if let parentID, state.sessions[parentID] == nil { return Self.sessionNotFound(parentID) }
        let directory =
            body["location"]?["directory"]?.stringValue
            ?? parentID.flatMap { state.sessions[$0]?.directory } ?? location(request)
        var model: ModelRef?
        if let ref = body["model"], let id = ref["id"]?.stringValue, let provider = ref["providerID"]?.stringValue {
            model = ModelRef(id: id, providerID: provider, variant: ref["variant"]?.stringValue)
        }
        let session = makeSession(
            id: body["id"]?.stringValue, parentID: parentID, directory: directory, title: body["title"]?.stringValue,
            agent: body["agent"]?.stringValue, model: model,
            metadata: body["metadata"].flatMap { $0.isNull ? nil : $0 },
            permissions: body["permissions"].flatMap { $0.isNull ? nil : $0 })
        return .json(["data": session.json])
    }

    /// Creates a session (and its project if the directory is new) and publishes `session.created`.
    @discardableResult
    func makeSession(
        id: String? = nil, parentID: String?, directory: String, title: String?, agent: String? = nil,
        model: ModelRef? = nil, metadata: JSONValue? = nil, permissions: JSONValue? = nil
    ) -> MockSession {
        let project: MockProject
        if let existing = state.project(containing: directory) {
            project = existing
        } else {
            project = MockProject(id: ids.hash40(), directory: directory, time: now())
            state.projects.append(project)
            publish("project.updated", project.json, location: directory)
        }
        let sessionID = id ?? makeID("ses", descending: true)
        let slug = Self.slugs[sessionID.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.slugs.count]
        var session = MockSession(
            id: sessionID, parentID: parentID, projectID: project.id, directory: directory,
            slug: slug, title: title, agent: agent, model: model, time: now(), metadata: metadata)
        // A child session starts with a copy of its parent's rules (verified on 2.3.0).
        session.permissions = permissions ?? parentID.flatMap { state.sessions[$0]?.permissions }
        state.sessions[sessionID] = session
        state.sessionOrder.append(sessionID)
        state.messages[sessionID] = state.messages[sessionID] ?? []
        publish(
            "session.created",
            .compact([
                ("sessionID", .string(sessionID)), ("slug", .string(slug)), ("version", .string(options.version)),
                ("projectID", .string(project.id)), ("location", ["directory": .string(directory)]),
                ("subpath", ""), ("parentID", parentID.map(JSONValue.string)), ("title", title.map(JSONValue.string)),
                ("agent", agent.map(JSONValue.string)), ("model", model?.json), ("metadata", metadata),
                ("permissions", session.permissions),
            ]), location: directory, durable: sessionID)
        return session
    }

    static let slugs = [
        "silent-otter", "clever-canyon", "playful-knight", "brave-comet", "quiet-harbor", "amber-falcon",
        "rapid-willow", "gentle-summit",
    ]

    func updateSession(_ id: String, _ request: HTTPRequest) -> HTTPResponse {
        guard var session = state.sessions[id] else { return Self.sessionNotFound(id) }
        let body: JSONValue
        switch jsonBody(request) {
        case let .failure(error): return error
        case let .success(value): body = value
        }
        let time = now()
        if let title = body["title"]?.stringValue {
            session.title = title
            publish("session.renamed", ["sessionID": .string(id), "title": .string(title)], durable: id)
        }
        if let metadata = body["metadata"], !metadata.isNull {
            session.metadata = metadata
            publish("session.metadata.updated", ["sessionID": .string(id), "metadata": metadata], durable: id)
        }
        if let permissions = body["permissions"], !permissions.isNull {
            session.permissions = permissions
            publish("session.permissions", ["sessionID": .string(id), "permissions": permissions], durable: id)
        }
        if let archived = body["archived"]?.boolValue {
            session.archived = archived ? time : nil
            publish(archived ? "session.archived" : "session.unarchived", ["sessionID": .string(id)], durable: id)
        }
        session.updated = time
        state.sessions[id] = session
        return .noContent()
    }

    func deleteSession(_ id: String) -> HTTPResponse {
        guard state.sessions[id] != nil else { return Self.sessionNotFound(id) }
        // Children go with their parent.
        var doomed = [id]
        var index = 0
        while index < doomed.count {
            let parent = doomed[index]
            doomed += state.sessionOrder.filter { state.sessions[$0]?.parentID == parent }
            index += 1
        }
        for sessionID in doomed.reversed() {
            _ = interrupt(sessionID, resume: false)
            pendingInbox[sessionID] = nil
            state.sessions[sessionID] = nil
            state.sessionOrder.removeAll { $0 == sessionID }
            state.messages[sessionID] = nil
            state.permissions.removeAll { $0.sessionID == sessionID }
            state.forms.removeAll { $0.sessionID == sessionID }
            publish("session.deleted", ["sessionID": .string(sessionID)], durable: sessionID, version: 2)
        }
        return .noContent()
    }

    // MARK: Messages

    func listMessages(_ sessionID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard state.sessions[sessionID] != nil else { return Self.sessionNotFound(sessionID) }
        var messages = state.messages[sessionID] ?? []
        if let type = request.queryValue("type") { messages = messages.filter { $0.type == type } }
        let order = listOrder(request)
        if order != "asc" { messages.reverse() }
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        switch page(messages.map(\.id), request: request, extra: [("order", .string(order))]) {
        case let .failure(error): return error
        case let .success((ids, cursor)):
            return .json(["data": .array(ids.compactMap { byID[$0]?.json }), "cursor": cursor])
        }
    }

    func getMessage(_ sessionID: String, _ messageID: String) -> HTTPResponse {
        guard state.sessions[sessionID] != nil else { return Self.sessionNotFound(sessionID) }
        guard let message = state.messages[sessionID]?.first(where: { $0.id == messageID }) else {
            return .error(
                404, tag: "MessageNotFoundError", message: "Message not found: \(messageID)",
                extra: [("messageID", .string(messageID))])
        }
        return .json(["data": message.json])
    }

    // MARK: Prompt

    func prompt(_ sessionID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard state.sessions[sessionID] != nil else { return Self.sessionNotFound(sessionID) }
        let body: JSONValue
        switch jsonBody(request) {
        case let .failure(error): return error
        case let .success(value): body = value
        }
        guard let text = body["text"]?.stringValue else { return Self.invalid("Missing key\n  at [\"text\"]") }
        if let id = body["id"]?.stringValue, let existing = state.inbox[sessionID]?[id] {
            return .json(["data": existing])
        }
        let delivery = body["delivery"]?.stringValue ?? "steer"
        recordedPrompts.append(body)
        let item = admit(
            sessionID: sessionID, id: body["id"]?.stringValue, text: text, delivery: delivery,
            script: selectScript(sessionID: sessionID, text: text), attachments: Self.echoedAttachments(body))
        return .json(["data": item])
    }

    // MARK: Permissions

    func listPermissions(_ request: HTTPRequest) -> HTTPResponse {
        let directory = location(request)
        let permissions = state.permissions.filter { state.sessions[$0.sessionID]?.directory == directory }
        return located(request, .array(permissions.map(\.json)))
    }

    func createPermission(_ sessionID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard let session = state.sessions[sessionID] else { return Self.sessionNotFound(sessionID) }
        let body: JSONValue
        switch jsonBody(request) {
        case let .failure(error): return error
        case let .success(value): body = value
        }
        guard let action = body["action"]?.stringValue else { return Self.invalid("Missing key\n  at [\"action\"]") }
        guard let resources = body["resources"]?.arrayValue?.compactMap(\.stringValue) else {
            return Self.invalid("Missing key\n  at [\"resources\"]")
        }
        var source: (messageID: String, toolID: String)?
        if let raw = body["source"], let message = raw["messageID"]?.stringValue, let tool = raw["id"]?.stringValue {
            source = (message, tool)
        }
        // Like the real server: evaluate the rules first; only `ask` creates a pending request.
        let effect = evaluate(action: action, resources: resources, session: session, agent: body["agent"]?.stringValue)
        guard effect == "ask" else {
            return .json(["data": ["id": .string(body["id"]?.stringValue ?? makeID("per")), "effect": .string(effect)]])
        }
        let permission = MockPermission(
            id: body["id"]?.stringValue ?? makeID("per"), sessionID: sessionID, action: action, resources: resources,
            save: body["save"]?.arrayValue?.compactMap(\.stringValue), metadata: body["metadata"], source: source,
            message: nil)
        state.permissions.append(permission)
        publish("permission.asked", permission.json, location: session.directory)
        return .json(["data": ["id": .string(permission.id), "effect": "ask"]])
    }

    func replyPermission(_ sessionID: String, _ requestID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard let session = state.sessions[sessionID] else { return Self.sessionNotFound(sessionID) }
        guard let index = state.permissions.firstIndex(where: { $0.id == requestID && $0.sessionID == sessionID })
        else { return Self.permissionNotFound(requestID) }
        let body: JSONValue
        switch jsonBody(request) {
        case let .failure(error): return error
        case let .success(value): body = value
        }
        guard let decision = body["decision"]?.stringValue, ["once", "always", "reject"].contains(decision) else {
            return Self.invalid("Expected \"once\" | \"always\" | \"reject\"\n  at [\"decision\"]")
        }
        let permission = state.permissions.remove(at: index)
        if decision == "always" {
            for resource in permission.save ?? permission.resources {
                state.allowed[sessionID, default: []].insert(permission.action + "\u{0}" + resource)
            }
            saveAlways(action: permission.action, patterns: permission.save ?? permission.resources, sessionID: sessionID)
        }
        publish(
            "permission.replied",
            ["sessionID": .string(sessionID), "requestID": .string(requestID), "reply": .string(decision)],
            location: session.directory)
        resumeWaiter(requestID, with: .reply(.string(decision), message: body["message"]?.stringValue))
        return .noContent()
    }

    // MARK: Forms

    func listForms(_ request: HTTPRequest) -> HTTPResponse {
        let directory = location(request)
        let forms = state.forms.filter { state.sessions[$0.sessionID]?.directory == directory }
        return located(request, .array(forms.map(\.json)))
    }

    func createForm(_ sessionID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard let session = state.sessions[sessionID] else { return Self.sessionNotFound(sessionID) }
        let body: JSONValue
        switch jsonBody(request) {
        case let .failure(error): return error
        case let .success(value): body = value
        }
        guard let title = body["title"]?.stringValue, let fields = body["fields"], fields.arrayValue != nil else {
            return Self.invalid("Missing key\n  at [\"title\"]")
        }
        let form = MockForm(
            id: body["id"]?.stringValue ?? makeID("frm"), sessionID: sessionID, title: title,
            metadata: body["metadata"], fields: fields)
        state.forms.append(form)
        publish("form.created", ["form": form.json], location: session.directory)
        return .json(["data": form.json])
    }

    func replyForm(_ sessionID: String, _ formID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard let session = state.sessions[sessionID] else { return Self.sessionNotFound(sessionID) }
        if state.settledForms.contains(formID) {
            return .error(
                409, tag: "FormAlreadySettledError", message: "Form already settled: \(formID)",
                extra: [("id", .string(formID))])
        }
        guard let index = state.forms.firstIndex(where: { $0.id == formID && $0.sessionID == sessionID }) else {
            return Self.formNotFound(formID)
        }
        let body: JSONValue
        switch jsonBody(request) {
        case let .failure(error): return error
        case let .success(value): body = value
        }
        guard let answer = body["answer"], answer.objectValue != nil else {
            return Self.invalid("Missing key\n  at [\"answer\"]")
        }
        state.forms.remove(at: index)
        state.settledForms.insert(formID)
        publish(
            "form.replied", ["id": .string(formID), "sessionID": .string(sessionID), "answer": answer],
            location: session.directory)
        resumeWaiter(formID, with: .reply(answer, message: nil))
        return .noContent()
    }

    func cancelForm(_ sessionID: String, _ formID: String) -> HTTPResponse {
        guard let session = state.sessions[sessionID] else { return Self.sessionNotFound(sessionID) }
        guard let index = state.forms.firstIndex(where: { $0.id == formID && $0.sessionID == sessionID }) else {
            return Self.formNotFound(formID)
        }
        state.forms.remove(at: index)
        state.settledForms.insert(formID)
        publish("form.cancelled", ["id": .string(formID), "sessionID": .string(sessionID)], location: session.directory)
        resumeWaiter(formID, with: .cancelled)
        return .noContent()
    }
}
