import BelloCore
import Foundation
import OpenCodeKit

/// A background generation (Auto's reviewer, commit message, branch name, merge request text) that a provider
/// refused, in words the owner can act on: which model, what happened, and where to change it (Settings ▸ Models).
///
/// Built from opencode's typed errors (`ProviderRequestError` with `reason`, `ModelNotFoundError`,
/// `ProviderNotFoundError`, `UnsupportedModelError`; Contracts/opencode-2.3.2/openapi.json) and, for the untyped
/// errors `session.generate` passes through, from the provider's own wording. Only the kind is kept: the provider's
/// message is never stored or logged.
public struct BackgroundModelError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        /// Usage allowance, quota, credits or budget used up (opencode's free tier: "Free usage limit reached").
        case quota
        /// Too many requests now; it may work again shortly.
        case rateLimited
        /// The provider refused the credentials.
        case authentication
        /// The provider or model is not available (removed, disconnected, unsupported).
        case unavailable
        /// The provider is overloaded.
        case overloaded
    }

    public var kind: Kind
    /// "OpenCode Zen · Big Pickle", or nil when the server picked the model.
    public var model: String?
    /// "Auto's reviewer", "Commit message", "Merge request text"…
    public var task: String

    public init(kind: Kind, model: String?, task: String) {
        self.kind = kind
        self.model = model
        self.task = task
    }

    /// Reason code for the Auto audit.
    public var reasonCode: String {
        switch kind {
        case .quota: "provider_limit"
        case .rateLimited: "provider_rate_limited"
        case .authentication: "provider_auth"
        case .unavailable: "model_unavailable"
        case .overloaded: "provider_overloaded"
        }
    }

    /// One sentence naming the model and the fix (at most ~200 characters, the audit's limit).
    public var message: String {
        let subject = model.map { "\(task) model \($0)" } ?? "\(task) model (opencode's default)"
        switch kind {
        case .quota:
            return "\(subject) hit its provider's usage limit. Choose a paid model in Settings ▸ Models."
        case .rateLimited:
            return "\(subject) is rate limited by its provider. Try again shortly, or choose another in Settings ▸ Models."
        case .authentication:
            return "\(subject) was refused: its provider rejected the sign-in. Reconnect it, or choose another in Settings ▸ Models."
        case .unavailable:
            return "\(subject) is not available. Choose another in Settings ▸ Models."
        case .overloaded:
            return "\(subject) is overloaded. Try again shortly, or choose another in Settings ▸ Models."
        }
    }

    public var description: String { message }

    /// Wording providers use for an exhausted allowance (lowercased match). opencode's own set of codes
    /// (`insufficient_quota`, `freeusagelimiterror`, …) is included.
    static let quotaWords = [
        "usage limit", "quota", "insufficient_quota", "usage_not_included", "billing", "credit", "budget", "allowance",
        "freeusagelimit", "gousagelimit", "creditlimitexceeded", "exceeded your", "out of credits", "payment required",
    ]

    /// The kind of provider failure in `error`, or nil for anything else (transport, decoding, a server bug).
    public static func classify(_ error: any Error) -> Kind? {
        if let engine = error as? EngineError {
            // Already translated (its text is the server's sanitised message): only the wording is left.
            switch engine {
            case .server(let text), .rejected(let text):
                return quotaWords.contains { text.lowercased().contains($0) } ? .quota : nil
            default:
                return nil
            }
        }
        guard let openCode = error as? OpenCodeError, case .http(let status, let body, _) = openCode else { return nil }
        let message = (body?.message ?? "").lowercased()
        let mentionsQuota = quotaWords.contains { message.contains($0) }
        switch body?.tag.rawValue {
        case "ProviderRequestError":
            if mentionsQuota { return .quota }
            switch body?.fields["reason"]?.stringValue {
            case "rate_limit": return .rateLimited
            case "authentication": return .authentication
            case "overloaded": return .overloaded
            default: return status == 402 ? .quota : status == 429 ? .rateLimited : nil
            }
        case "ModelNotFoundError", "ProviderNotFoundError", "UnsupportedModelError":
            return .unavailable
        default:
            if mentionsQuota || status == 402 { return .quota }
            if status == 429 { return .rateLimited }
            return nil
        }
    }

    /// The owner-facing error for `error`, or nil when it is not a provider refusal.
    public static func from(_ error: any Error, model: String?, task: String) -> BackgroundModelError? {
        if let mapped = error as? BackgroundModelError { return mapped }
        return classify(error).map { BackgroundModelError(kind: $0, model: model, task: task) }
    }
}

extension BackgroundModelResolver {
    /// "Provider · Model" for a selection, from the catalog when it lists it.
    public static func label(_ selection: ModelSelection, in catalog: Catalog?) -> String {
        let provider = catalog?.providers.first { $0.id == selection.providerID }?.name ?? selection.providerID
        let model = entry(selection, in: catalog)?.name ?? selection.modelID
        return "\(provider) · \(model)"
    }
}

/// Opens Settings ▸ Models from any surface that shows a `BackgroundModelError` (set by the app at launch; nil in
/// tests and demos, where the button is not shown).
@MainActor
public enum ModelSettingsLink {
    public static var open: (@MainActor () -> Void)?
    public static let title = "Open Settings ▸ Models…"
}
