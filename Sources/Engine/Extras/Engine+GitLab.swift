import BelloCore
import Foundation

extension Engine {
    /// The thread's model proposes text from its context without adding to its history (opencode `session.generate`).
    /// Used for the create-merge-request form's title and description.
    public func generateText(in sessionID: SessionID, prompt: String) async throws -> String {
        try await core.generate(sessionID, prompt: prompt)
    }
}
