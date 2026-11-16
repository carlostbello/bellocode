import Foundation

// MARK: - Integrations (provider login)

extension OpenCodeClient {
    /// `GET /api/integration` (integration.list). A cold location may answer an empty list until it has activated;
    /// follow `integration.updated` or retry.
    public func integrations(directory: String?) async throws -> [IntegrationInfo] {
        let request = try makeRequest(.get, ["api", "integration"], directory: directory, timeout: .seconds(60))
        return try await send("integration.list", request, as: LocatedList<IntegrationInfo>.self).data
    }

    /// `GET /api/integration/{id}` (integration.get).
    public func integration(_ id: String, directory: String?) async throws -> IntegrationInfo {
        let request = try makeRequest(.get, ["api", "integration", id], directory: directory)
        return try await send("integration.get", request, as: LocatedData<IntegrationInfo>.self).data
    }

    /// `POST /api/integration/{id}/connect/key` (integration.connect.key). The server stores the key as the active
    /// credential without checking it with the provider (2.3.0 accepts even an empty key), so validate input first.
    public func connectKey(
        integrationID: String, key: String, answer: [String: FormValue]? = nil, label: String? = nil,
        directory: String?
    ) async throws {
        let request = try makeRequest(
            .post, ["api", "integration", integrationID, "connect", "key"], directory: directory,
            body: ConnectKeyBody(key: key, answer: answer, label: label))
        try await sendIgnoringBody("integration.connect.key", request)
    }

    /// `POST /api/integration/{id}/connect/external` (integration.connect.external).
    public func connectExternal(
        integrationID: String, methodID: String, answer: [String: FormValue]? = nil, label: String? = nil,
        directory: String?
    ) async throws {
        let request = try makeRequest(
            .post, ["api", "integration", integrationID, "connect", "external"], directory: directory,
            body: ConnectMethodBody(methodID: methodID, answer: answer, label: label))
        try await sendIgnoringBody("integration.connect.external", request)
    }

    /// `POST /api/integration/{id}/connect/oauth` (integration.oauth.connect): starts an attempt.
    public func startOAuth(
        integrationID: String, methodID: String, answer: [String: FormValue]? = nil, label: String? = nil,
        directory: String?
    ) async throws -> OAuthAttempt {
        let request = try makeRequest(
            .post, ["api", "integration", integrationID, "connect", "oauth"], directory: directory,
            body: ConnectMethodBody(methodID: methodID, answer: answer, label: label), timeout: .seconds(60))
        return try await send("integration.oauth.connect", request, as: LocatedData<OAuthAttempt>.self).data
    }

    /// `GET /api/integration/{id}/connect/oauth/{attemptID}` (integration.oauth.status).
    public func oauthStatus(integrationID: String, attemptID: String, directory: String?) async throws -> AttemptStatus {
        let request = try makeRequest(
            .get, ["api", "integration", integrationID, "connect", "oauth", attemptID], directory: directory)
        return try await send("integration.oauth.status", request, as: LocatedData<AttemptStatus>.self).data
    }

    /// `POST …/connect/oauth/{attemptID}/complete` (integration.oauth.complete): a pasted code, or the redirect URL for
    /// an `auto` attempt with `paste`.
    public func completeOAuth(integrationID: String, attemptID: String, code: String?, directory: String?) async throws {
        let request = try makeRequest(
            .post, ["api", "integration", integrationID, "connect", "oauth", attemptID, "complete"],
            directory: directory, body: OAuthCompleteBody(code: code), timeout: .seconds(60))
        try await sendIgnoringBody("integration.oauth.complete", request)
    }

    /// `DELETE …/connect/oauth/{attemptID}` (integration.oauth.cancel).
    public func cancelOAuth(integrationID: String, attemptID: String, directory: String?) async throws {
        let request = try makeRequest(
            .delete, ["api", "integration", integrationID, "connect", "oauth", attemptID], directory: directory)
        try await sendIgnoringBody("integration.oauth.cancel", request)
    }

    /// `POST /api/integration/{id}/connect/command` (integration.command.connect).
    public func startCommand(integrationID: String, methodID: String, label: String? = nil, directory: String?) async throws
        -> CommandAttempt
    {
        let request = try makeRequest(
            .post, ["api", "integration", integrationID, "connect", "command"], directory: directory,
            body: ConnectCommandBody(methodID: methodID, label: label))
        return try await send("integration.command.connect", request, as: LocatedData<CommandAttempt>.self).data
    }

    /// `GET …/connect/command/{attemptID}` (integration.command.status).
    public func commandStatus(integrationID: String, attemptID: String, directory: String?) async throws -> AttemptStatus {
        let request = try makeRequest(
            .get, ["api", "integration", integrationID, "connect", "command", attemptID], directory: directory)
        return try await send("integration.command.status", request, as: LocatedData<AttemptStatus>.self).data
    }

    /// `DELETE …/connect/command/{attemptID}` (integration.command.cancel).
    public func cancelCommand(integrationID: String, attemptID: String, directory: String?) async throws {
        let request = try makeRequest(
            .delete, ["api", "integration", integrationID, "connect", "command", attemptID], directory: directory)
        try await sendIgnoringBody("integration.command.cancel", request)
    }
}

// MARK: - Credentials

extension OpenCodeClient {
    /// `GET /api/credential` (credential.list), reduced to non-secret fields. The response body contains every secret;
    /// it is decoded once into `CredentialSummary` values and dropped. Never log or cache the raw response.
    public func credentials() async throws -> [CredentialSummary] {
        let request = try makeRequest(.get, ["api", "credential"])
        return try await send("credential.list", request, as: DataList<CredentialSummary>.self).data
    }

    /// `PATCH /api/credential/{id}` (credential.update): renames.
    public func renameCredential(_ id: String, label: String) async throws {
        let request = try makeRequest(.patch, ["api", "credential", id], body: CredentialLabelBody(label: label))
        try await sendIgnoringBody("credential.update", request)
    }

    /// `DELETE /api/credential/{id}` (credential.remove). Not undoable.
    public func removeCredential(_ id: String) async throws {
        try await sendIgnoringBody("credential.remove", makeRequest(.delete, ["api", "credential", id]))
    }

    /// `POST /api/credential/{id}/activate` (credential.activate).
    public func activateCredential(_ id: String) async throws {
        try await sendIgnoringBody("credential.activate", makeRequest(.post, ["api", "credential", id, "activate"]))
    }
}

// MARK: - Permission evaluation and saved rules

extension OpenCodeClient {
    /// `POST /api/session/{id}/permission` (session.permission.create): evaluates the session's rules and creates a
    /// pending request only when the effect is `ask`.
    public func evaluatePermission(sessionID: String, _ body: PermissionCreateRequest) async throws -> PermissionEvaluation {
        let request = try makeRequest(.post, ["api", "session", sessionID, "permission"], body: body)
        return try await send("session.permission.create", request, as: DataEnvelope<PermissionEvaluation>.self).data
    }

    /// `GET /api/permission/saved?projectID=` (permission.saved.list). Without a project ID the 2.3.0 server answers
    /// an empty list, so always pass one.
    public func savedPermissions(projectID: String) async throws -> [SavedPermission] {
        let request = try makeRequest(.get, ["api", "permission", "saved"], query: [("projectID", projectID)])
        return try await send("permission.saved.list", request, as: DataList<SavedPermission>.self).data
    }

    /// `DELETE /api/permission/saved/{id}` (permission.saved.remove).
    public func removeSavedPermission(_ id: String) async throws {
        try await sendIgnoringBody("permission.saved.remove", makeRequest(.delete, ["api", "permission", "saved", id]))
    }

    /// `GET /api/agent/{id}` (agent.get).
    public func agent(_ id: String, directory: String?) async throws -> AgentInfo {
        let request = try makeRequest(.get, ["api", "agent", id], directory: directory)
        return try await send("agent.get", request, as: LocatedData<AgentInfo>.self).data
    }
}

/// `{ location, data: T }`.
struct LocatedData<T: Decodable & Sendable>: Decodable, Sendable {
    let location: LocationRef
    let data: T
}
