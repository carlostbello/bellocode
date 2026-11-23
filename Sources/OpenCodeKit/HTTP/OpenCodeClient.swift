import Foundation

/// Typed HTTP client for one opencode server (Contracts/opencode-2.3.0/openapi.json).
///
/// Every request carries Basic auth. Location-scoped operations take a `directory` and send it as the contract's
/// `location[directory]` deep-object query parameter; session-scoped routes resolve the location from the session.
/// Requests time out after `requestTimeout` and are cancelled with the calling task (which then throws
/// `CancellationError`). The client is a value; build a new one when the server restarts on a new port.
public struct OpenCodeClient: Sendable {
    public let connection: ServerConnection
    public let transport: any HTTPTransport
    public var requestTimeout: Duration

    public init(
        connection: ServerConnection,
        transport: any HTTPTransport = URLSessionTransport.shared,
        requestTimeout: Duration = .seconds(30)
    ) {
        self.connection = connection
        self.transport = transport
        self.requestTimeout = requestTimeout
    }

    public init(endpoint: ServerEndpoint, transport: any HTTPTransport = URLSessionTransport.shared) {
        self.init(connection: endpoint.connection, transport: transport)
    }

    // MARK: - Request building

    enum Method: String {
        case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE", put = "PUT"
    }

    /// Builds an authenticated request. `path` segments are percent-encoded individually.
    func makeRequest(
        _ method: Method,
        _ path: [String],
        query: [(String, String)] = [],
        directory: String? = nil,
        body: (any Encodable & Sendable)? = nil,
        timeout: Duration? = nil
    ) throws -> URLRequest {
        var query = query
        if let directory { query.append(("location[directory]", directory)) }
        let url = Self.url(base: connection.baseURL, path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = (timeout ?? requestTimeout).seconds
        request.setValue(connection.credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            do {
                request.httpBody = try Self.encoder.encode(body)
            } catch {
                throw OpenCodeError.decoding(operation: path.joined(separator: "/"), reason: "could not encode body")
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    static func url(base: URL, path: [String], query: [(String, String)]) -> URL {
        var string = base.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        for segment in path { string += "/" + percentEncode(segment) }
        if !query.isEmpty {
            string += "?" + query.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
        }
        guard let url = URL(string: string) else { preconditionFailure("unencodable URL") }
        return url
    }

    /// Percent-encodes everything except RFC 3986 unreserved characters, so `+`, `&`, `=`, `[`, `]`, `/` and spaces
    /// in paths and IDs are always unambiguous.
    static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder = JSONDecoder()

    // MARK: - Sending

    /// Sends a request and decodes a JSON body.
    func send<T: Decodable & Sendable>(_ operation: String, _ request: URLRequest, as type: T.Type) async throws -> T {
        let data = try await perform(operation, request)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw OpenCodeError.decoding(operation: operation, reason: Self.describe(error))
        }
    }

    /// Sends a request whose success response has no body worth decoding (204).
    func sendIgnoringBody(_ operation: String, _ request: URLRequest) async throws {
        _ = try await perform(operation, request)
    }

    private func perform(_ operation: String, _ request: URLRequest) async throws -> Data {
        let signpost = Instrumentation.http.beginInterval("request", "\(operation, privacy: .public)")
        defer { Instrumentation.http.endInterval("request", signpost) }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw OpenCodeError.transport(operation: operation, code: error.code)
        }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            let body = try? Self.decoder.decode(ServerErrorBody.self, from: data)
            throw OpenCodeError.http(status: response.statusCode, body: body, operation: operation)
        }
        return data
    }

    /// A short, content-free description of a decoding error (the coding path, never the payload).
    static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return "\(type(of: error))" }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing \(path(context)).\(key.stringValue)"
        case .typeMismatch(_, let context): return "type mismatch at \(path(context))"
        case .valueNotFound(_, let context): return "null at \(path(context))"
        case .dataCorrupted(let context): return "corrupted at \(path(context))"
        @unknown default: return "decoding error"
        }
    }
}

// MARK: - Server

extension OpenCodeClient {
    /// `GET /api/info` (server.info). Answers 503 while the server is still starting.
    public func info() async throws -> ServerInfo {
        try await send("server.info", makeRequest(.get, ["api", "info"]), as: ServerInfo.self)
    }

    /// `GET /api/info`, retrying while the server answers 503 (starting), up to `attempts` times `interval` apart.
    public func waitForInfo(attempts: Int = 50, interval: Duration = .milliseconds(100)) async throws -> ServerInfo {
        var attempt = 0
        while true {
            do {
                return try await info()
            } catch let error as OpenCodeError where error.status == 503 && attempt + 1 < attempts {
                attempt += 1
                try await Task.sleep(for: interval)
            }
        }
    }
}

// MARK: - Projects

extension OpenCodeClient {
    /// `GET /api/project` (project.list).
    public func projects(archived: Bool? = nil) async throws -> [Project] {
        let query = archived.map { [("archived", String($0))] } ?? []
        return try await send("project.list", makeRequest(.get, ["api", "project"], query: query), as: [Project].self)
    }
}

// MARK: - Sessions

extension OpenCodeClient {
    /// `GET /api/session` (session.list). Cursor paged; defaults to the newest 50.
    public func sessions(_ query: SessionListQuery = SessionListQuery()) async throws -> Page<SessionInfo> {
        var items: [(String, String)] = []
        if let limit = query.limit { items.append(("limit", String(limit))) }
        if let order = query.order { items.append(("order", order.rawValue)) }
        if let search = query.search { items.append(("search", search)) }
        switch query.parent {
        case .root: items.append(("parentID", "null"))
        case .session(let id): items.append(("parentID", id))
        case nil: break
        }
        if let archived = query.archived { items.append(("archived", String(archived))) }
        if let directory = query.directory { items.append(("directory", directory)) }
        if let project = query.project { items.append(("project", project)) }
        if let subpath = query.subpath { items.append(("subpath", subpath)) }
        if let cursor = query.cursor { items.append(("cursor", cursor)) }
        return try await send("session.list", makeRequest(.get, ["api", "session"], query: items), as: Page<SessionInfo>.self)
    }

    /// `POST /api/session` (session.create).
    public func createSession(_ body: SessionCreateRequest) async throws -> SessionInfo {
        let request = try makeRequest(.post, ["api", "session"], body: body)
        return try await send("session.create", request, as: DataEnvelope<SessionInfo>.self).data
    }

    /// `GET /api/session/{id}` (session.get).
    public func session(_ id: String) async throws -> SessionInfo {
        try await send("session.get", makeRequest(.get, ["api", "session", id]), as: DataEnvelope<SessionInfo>.self).data
    }

    /// `PATCH /api/session/{id}` (session.update). Returns 204; re-read the session or follow events for the result.
    public func updateSession(_ id: String, _ body: SessionUpdateRequest) async throws {
        try await sendIgnoringBody("session.update", makeRequest(.patch, ["api", "session", id], body: body))
    }

    /// `DELETE /api/session/{id}` (session.remove).
    public func deleteSession(_ id: String) async throws {
        try await sendIgnoringBody("session.remove", makeRequest(.delete, ["api", "session", id]))
    }

    /// `GET /api/session/{id}/message` (session.message.list). Cursor paged.
    public func messages(sessionID: String, _ query: MessageListQuery = MessageListQuery()) async throws -> Page<SessionMessage> {
        var items: [(String, String)] = []
        if let limit = query.limit { items.append(("limit", String(limit))) }
        if let order = query.order { items.append(("order", order.rawValue)) }
        if let cursor = query.cursor { items.append(("cursor", cursor)) }
        if let type = query.type { items.append(("type", type)) }
        let request = try makeRequest(.get, ["api", "session", sessionID, "message"], query: items)
        return try await send("session.message.list", request, as: Page<SessionMessage>.self)
    }

    /// `GET /api/session/{id}/message/{messageID}` (session.message.get).
    public func message(sessionID: String, messageID: String) async throws -> SessionMessage {
        let request = try makeRequest(.get, ["api", "session", sessionID, "message", messageID])
        return try await send("session.message.get", request, as: DataEnvelope<SessionMessage>.self).data
    }

    /// `GET /api/session/{id}/inbox` (session.inbox.list): admitted prompts not yet delivered.
    public func inbox(sessionID: String) async throws -> [InboxItem] {
        let request = try makeRequest(.get, ["api", "session", sessionID, "inbox"])
        return try await send("session.inbox.list", request, as: DataEnvelope<[InboxItem]>.self).data
    }

    /// `DELETE /api/session/{id}/inbox/{inboxID}` (session.inbox.cancel): withdraw a prompt before delivery.
    public func cancelInboxItem(sessionID: String, inboxID: String) async throws {
        try await sendIgnoringBody("session.inbox.cancel", makeRequest(.delete, ["api", "session", sessionID, "inbox", inboxID]))
    }

    /// `PATCH /api/session/{id}/inbox/{inboxID}` (session.inbox.update): change a pending prompt's delivery. 409 when it
    /// was already delivered.
    public func updateInboxItem(sessionID: String, inboxID: String, delivery: InboxDelivery) async throws {
        let request = try makeRequest(
            .patch, ["api", "session", sessionID, "inbox", inboxID], body: InboxUpdateBody(delivery: delivery))
        try await sendIgnoringBody("session.inbox.update", request)
    }

    /// `POST /api/session/{id}/view` (session.view): mark the idle transition at `idle` (epoch ms) as seen.
    public func viewSession(_ sessionID: String, idle: Double) async throws {
        let request = try makeRequest(.post, ["api", "session", sessionID, "view"], body: SessionViewBody(idle: idle))
        try await sendIgnoringBody("session.view", request)
    }

    /// `POST /api/session/{id}/agent` (session.switchAgent).
    public func switchAgent(sessionID: String, agent: String) async throws {
        let request = try makeRequest(.post, ["api", "session", sessionID, "agent"], body: SwitchAgentBody(agent: agent))
        try await sendIgnoringBody("session.switchAgent", request)
    }

    /// `POST /api/session/{id}/model` (session.switchModel).
    public func switchModel(sessionID: String, model: ModelRef) async throws {
        let request = try makeRequest(.post, ["api", "session", sessionID, "model"], body: SwitchModelBody(model: model))
        try await sendIgnoringBody("session.switchModel", request)
    }

    /// `POST /api/session/{id}/prompt` (session.prompt). Returns once the prompt is admitted; the turn is observed
    /// through events. Admission is idempotent on `body.id`.
    public func prompt(sessionID: String, _ body: PromptRequest) async throws -> InboxUserItem {
        let request = try makeRequest(.post, ["api", "session", sessionID, "prompt"], body: body)
        return try await send("session.prompt", request, as: DataEnvelope<InboxUserItem>.self).data
    }

    /// `POST /api/session/{id}/interrupt` (session.interrupt). This is opencode's abort. Returns whether an active
    /// execution was interrupted.
    @discardableResult
    public func interrupt(sessionID: String, resume: Bool? = nil) async throws -> Bool {
        let query = resume.map { [("resume", String($0))] } ?? []
        let request = try makeRequest(.post, ["api", "session", sessionID, "interrupt"], query: query)
        return try await send("session.interrupt", request, as: InterruptResult.self).interrupted
    }
}

// MARK: - Permissions

extension OpenCodeClient {
    /// `GET /api/permission/request` (permission.request.list): pending requests in one location. Always pass the
    /// directory: without it the server uses its own working directory and misses other projects' requests.
    public func pendingPermissions(directory: String) async throws -> [PermissionRequest] {
        let request = try makeRequest(.get, ["api", "permission", "request"], directory: directory)
        return try await send("permission.request.list", request, as: LocatedList<PermissionRequest>.self).data
    }

    /// `GET /api/session/{id}/permission` (session.permission.list).
    public func permissions(sessionID: String) async throws -> [PermissionRequest] {
        let request = try makeRequest(.get, ["api", "session", sessionID, "permission"])
        return try await send("session.permission.list", request, as: DataEnvelope<[PermissionRequest]>.self).data
    }

    /// `POST /api/session/{id}/permission/{requestID}/reply` (session.permission.reply).
    public func replyPermission(
        sessionID: String, requestID: String, decision: PermissionDecision, message: String? = nil
    ) async throws {
        let request = try makeRequest(
            .post, ["api", "session", sessionID, "permission", requestID, "reply"],
            body: PermissionReplyBody(decision: decision, message: message)
        )
        try await sendIgnoringBody("session.permission.reply", request)
    }
}

// MARK: - Forms (questions)

extension OpenCodeClient {
    /// `GET /api/form` (form.list): pending forms in one location.
    public func pendingForms(directory: String) async throws -> [FormInfo] {
        let request = try makeRequest(.get, ["api", "form"], directory: directory)
        return try await send("form.list", request, as: LocatedList<FormInfo>.self).data
    }

    /// `GET /api/session/{id}/form` (session.form.list).
    public func forms(sessionID: String) async throws -> [FormInfo] {
        let request = try makeRequest(.get, ["api", "session", sessionID, "form"])
        return try await send("session.form.list", request, as: DataEnvelope<[FormInfo]>.self).data
    }

    /// `POST /api/session/{id}/form/{formID}/reply` (session.form.reply). `answer` is keyed by field `key`.
    public func replyForm(sessionID: String, formID: String, answer: [String: FormValue]) async throws {
        let request = try makeRequest(
            .post, ["api", "session", sessionID, "form", formID, "reply"], body: FormReplyBody(answer: answer)
        )
        try await sendIgnoringBody("session.form.reply", request)
    }

    /// `DELETE /api/session/{id}/form/{formID}` (session.form.cancel): dismiss without answering.
    public func cancelForm(sessionID: String, formID: String, message: String? = nil) async throws {
        let query = message.map { [("message", $0)] } ?? []
        let request = try makeRequest(.delete, ["api", "session", sessionID, "form", formID], query: query)
        try await sendIgnoringBody("session.form.cancel", request)
    }
}

// MARK: - Catalog

extension OpenCodeClient {
    /// `GET /api/model` (model.list). The first call for a location can take seconds while it activates.
    public func models(directory: String?, types: [String]? = nil) async throws -> [ModelInfo] {
        let query = (types ?? []).map { ("types", $0) }
        let request = try makeRequest(.get, ["api", "model"], query: query, directory: directory, timeout: .seconds(60))
        return try await send("model.list", request, as: LocatedList<ModelInfo>.self).data
    }

    /// `GET /api/model/default` (model.default).
    public func defaultModel(directory: String?) async throws -> ModelInfo? {
        let request = try makeRequest(.get, ["api", "model", "default"], directory: directory, timeout: .seconds(60))
        return try await send("model.default", request, as: DefaultModelResponse.self).data
    }

    /// `GET /api/provider` (provider.list).
    public func providers(directory: String?) async throws -> [ProviderInfo] {
        let request = try makeRequest(.get, ["api", "provider"], directory: directory, timeout: .seconds(60))
        return try await send("provider.list", request, as: LocatedList<ProviderInfo>.self).data
    }

    /// `GET /api/agent` (agent.list).
    public func agents(directory: String?) async throws -> [AgentInfo] {
        let request = try makeRequest(.get, ["api", "agent"], directory: directory)
        return try await send("agent.list", request, as: LocatedList<AgentInfo>.self).data
    }
}

// MARK: - Event stream

extension OpenCodeClient {
    /// The `GET /api/event` (event.subscribe) request. `idleTimeout` bounds silence between bytes; the server sends a
    /// heartbeat comment every 15 s, so a longer silence means the connection is dead (for example after sleep).
    public func eventStreamRequest(types: [String]? = nil, idleTimeout: Duration = .seconds(45)) throws -> URLRequest {
        let query = (types ?? []).map { ("types", $0) }
        var request = try makeRequest(.get, ["api", "event"], query: query, timeout: idleTimeout)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }
}

// MARK: - Commands, skills, files, locations

extension OpenCodeClient {
    /// `GET /api/command` (command.list).
    public func commands(directory: String?) async throws -> [CommandInfo] {
        let request = try makeRequest(.get, ["api", "command"], directory: directory)
        return try await send("command.list", request, as: LocatedList<CommandInfo>.self).data
    }

    /// `POST /api/session/{id}/command` (session.command): 204 once the command ran or was admitted.
    public func runCommand(sessionID: String, _ body: CommandRequest) async throws {
        let request = try makeRequest(.post, ["api", "session", sessionID, "command"], body: body, timeout: .seconds(120))
        try await sendIgnoringBody("session.command", request)
    }

    /// `GET /api/skill` (skill.list).
    public func skills(directory: String?) async throws -> [SkillInfo] {
        let request = try makeRequest(.get, ["api", "skill"], directory: directory)
        return try await send("skill.list", request, as: LocatedList<SkillInfo>.self).data
    }

    /// `GET /api/fs/find` (fs.find): ranked entries below the location whose path matches `query`.
    public func findFiles(
        directory: String?, query: String, type: FileSystemEntry.Kind? = .file, limit: Int = 50
    ) async throws -> [FileSystemEntry] {
        var parameters: [(String, String)] = [("query", query), ("limit", String(limit))]
        if let type { parameters.append(("type", type.rawValue)) }
        let request = try makeRequest(.get, ["api", "fs", "find"], query: parameters, directory: directory)
        return try await send("fs.find", request, as: LocatedList<FileSystemEntry>.self).data
    }

    /// `GET /api/location` (location.get): the project a directory belongs to.
    public func location(directory: String) async throws -> LocationInfo {
        let request = try makeRequest(.get, ["api", "location"], directory: directory)
        return try await send("location.get", request, as: LocationInfo.self)
    }

    /// `GET /api/debug/location` (debug.location.list): the directories of the locations the server has loaded now.
    public func loadedLocations() async throws -> [String] {
        let request = try makeRequest(.get, ["api", "debug", "location"])
        return try await send("debug.location.list", request, as: [LoadedLocation].self).map(\.directory)
    }

    /// `Location.PublicRef`.
    struct LoadedLocation: Decodable, Sendable { var directory: String }
}
