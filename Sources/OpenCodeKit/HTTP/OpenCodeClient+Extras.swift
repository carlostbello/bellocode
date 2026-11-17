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
