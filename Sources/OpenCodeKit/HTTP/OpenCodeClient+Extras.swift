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

struct GenerateTextBody: Encodable, Sendable {
    var prompt: String
    var model: ModelRef?
}

extension OpenCodeClient {
    /// `POST /api/experimental/generate/text` (generate.text): one stateless generation with the server's base
    /// configuration (no session, no history, no tools; nothing is stored). Verified on 2.3.0: it creates no session.
    /// BelloCode Auto's reviewer (docs/features/auto-mode.md). Cancelling the calling task cancels the request.
    public func generateText(prompt: String, model: ModelRef?, timeout: Duration? = nil) async throws -> String {
        let request = try makeRequest(
            .post, ["api", "experimental", "generate", "text"], body: GenerateTextBody(prompt: prompt, model: model),
            timeout: timeout)
        return try await send("generate.text", request, as: GenerateResponse.self).data.text
    }
}
