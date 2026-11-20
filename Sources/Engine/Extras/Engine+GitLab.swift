import BelloCore
import Foundation
import OpenCodeKit

extension Engine {
    /// Commit messages, branch names and merge request text (docs/features/models.md): the model Settings ▸ Models ▸
    /// Git & GitLab writing names (`BackgroundModelResolver.gitText`). "Same as thread" asks the thread's model with its
    /// context (opencode `session.generate`, history unchanged); a chosen model or the small model answers statelessly
    /// (`generate.text` with that model, no thread context), from `statelessPrompt` when the prompt relies on the
    /// conversation. A provider refusal (usage limit, sign-in, model gone) throws `BackgroundModelError` naming the
    /// model and Settings ▸ Models.
    public func generateText(in sessionID: SessionID, prompt: String, statelessPrompt: String? = nil, task: String = "Git writing") async throws -> String {
        let session = await core.knownSession(sessionID)
        let catalog = session.flatMap { root.catalog.catalog(for: $0.directory) } ?? root.catalog.current
        let resolution = BackgroundModelResolver.gitText(
            choice: models?.background.gitText ?? .sameAsThread, thread: session?.model, hasThread: true,
            small: models?.configuredSmall, catalog: catalog)
        return try await generate(resolution, sessionID: sessionID, session: session, catalog: catalog, prompt: prompt, statelessPrompt: statelessPrompt, task: task)
    }

    /// The model `generateText(in:)` would use for this thread now, as "Provider · Model" (shown beside Generate).
    public func gitTextModelLabel(for sessionID: SessionID?) -> String {
        let session = sessionID.flatMap { loadedThread($0)?.session }
        let catalog = session.flatMap { root.catalog.catalog(for: $0.directory) } ?? root.catalog.current
        let resolution = BackgroundModelResolver.gitText(
            choice: models?.background.gitText ?? .sameAsThread, thread: session?.model, hasThread: sessionID != nil,
            small: models?.configuredSmall, catalog: catalog)
        switch resolution {
        case .thread:
            let model = session?.model ?? catalog?.defaultModel
            return model.map { BackgroundModelResolver.label($0, in: catalog) + " (thread)" } ?? "the thread's model"
        case .model(let selection, _): return BackgroundModelResolver.label(selection, in: catalog)
        case .serverDefault: return "opencode's default"
        }
    }

    func generate(
        _ resolution: BackgroundModelResolver.Resolution, sessionID: SessionID, session: Session?, catalog: Catalog?, prompt: String,
        statelessPrompt: String?, task: String
    ) async throws -> String {
        let label: String?
        switch resolution {
        case .thread: label = (session?.model ?? catalog?.defaultModel).map { BackgroundModelResolver.label($0, in: catalog) }
        case .model(let selection, _): label = BackgroundModelResolver.label(selection, in: catalog)
        case .serverDefault: label = catalog?.defaultModel.map { BackgroundModelResolver.label($0, in: catalog) }
        }
        do {
            let client = try await core.currentClient()
            switch resolution {
            case .thread:
                return try await client.generate(sessionID: sessionID.rawValue, prompt: prompt)
            case .model(let selection, _):
                let model = ModelRef(id: selection.modelID, providerID: selection.providerID, variant: selection.variant)
                return try await client.generateText(prompt: statelessPrompt ?? prompt, model: model, timeout: .seconds(120))
            case .serverDefault:
                return try await client.generateText(prompt: statelessPrompt ?? prompt, model: nil, timeout: .seconds(120))
            }
        } catch {
            if let refusal = BackgroundModelError.from(error, model: label, task: task) { throw refusal }
            throw EngineError.from(error)
        }
    }
}
