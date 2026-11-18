import Foundation

// Calls used by the orchestration extras (docs/features/orchestration-extras.md), checked against
// Contracts/opencode-2.3.0/openapi.json and the real 2.3.0 binary.

struct SyntheticBody: Encodable, Sendable {
    var text: String
    var metadata: JSONValue?
    var resume: Bool
}

extension OpenCodeClient {
    /// `POST /api/session/{id}/synthetic` (session.synthetic): durably admits input that is not the person's message
    /// (shown as a system note) and starts a run unless `resume` is false. Used for PR-watch and secret wakes.
    public func postSynthetic(sessionID: String, text: String, metadata: JSONValue? = nil, resume: Bool = true) async throws {
        let request = try makeRequest(
            .post, ["api", "session", sessionID, "synthetic"], body: SyntheticBody(text: text, metadata: metadata, resume: resume))
        try await sendIgnoringBody("session.synthetic", request)
    }
}

struct GenerateBody: Encodable, Sendable {
    var prompt: String
}

struct GenerateResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable { var text: String }
    var data: Payload
}

extension OpenCodeClient {
    /// `POST /api/session/{id}/generate` (session.generate): transient text from the session's context and model,
    /// without changing its history (its tokens count toward the session). Used to propose a merge request's title and
    /// description.
    public func generate(sessionID: String, prompt: String) async throws -> String {
        let request = try makeRequest(.post, ["api", "session", sessionID, "generate"], body: GenerateBody(prompt: prompt))
        return try await send("session.generate", request, as: GenerateResponse.self).data.text
    }
}

struct SessionEnvironmentBody: Encodable, Sendable {
    var variables: [String: String]
}

extension OpenCodeClient {
    /// `PUT /api/session/{id}/environment` (session.environment): replaces the process environment opencode gives this
    /// session's shell commands (in memory; lost when the server restarts, so the app sets it again after a reconnect).
    /// The secret manager uses it for per-thread placeholders (docs/features/secrets.md); it never carries a hidden value.
    public func setSessionEnvironment(sessionID: String, variables: [String: String]) async throws {
        let request = try makeRequest(.put, ["api", "session", sessionID, "environment"], body: SessionEnvironmentBody(variables: variables))
        try await sendIgnoringBody("session.environment", request)
    }
}

struct SessionShellBody: Encodable, Sendable {
    var command: String
}

extension OpenCodeClient {
    /// `POST /api/session/{id}/shell` (session.shell): runs one command in the session's directory with the session's
    /// environment, recorded in its transcript as a shell message (the person's `!` command). The secret manager's end
    /// to end run uses it to prove placeholder delivery without a model.
    public func runSessionShell(sessionID: String, command: String) async throws {
        let request = try makeRequest(.post, ["api", "session", sessionID, "shell"], body: SessionShellBody(command: command))
        try await sendIgnoringBody("session.shell", request)
    }
}
