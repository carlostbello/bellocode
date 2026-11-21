import BelloCore
import Foundation

/// Which model each background task uses (docs/features/models.md). Pure functions over the catalog, unit-tested.
///
/// Order everywhere: the owner's setting (Settings ▸ Models), then the thread's model, then opencode's default, then a
/// fast catalogue fallback. A setting naming a model that is no longer usable (provider disconnected or disabled,
/// model disabled or gone) falls through to the next step; Settings ▸ Models shows it as unavailable.
///
/// Free models: opencode's free tier refuses background generation once its allowance is used ("Free usage limit
/// reached"). So when a connected provider offers a paid model, the reviewer's automatic steps (thread, server
/// default, fallback) never pick a free one, and the fallback prefers paid models. A free model the owner picked
/// explicitly is still used.
public enum BackgroundModelResolver {
    /// Where a resolved model came from (shown in Settings and the Auto audit).
    public enum Source: String, Sendable, Hashable {
        case owner, thread, serverDefault, small, fallback
    }

    public enum Resolution: Sendable, Hashable {
        /// The thread's own model through `session.generate` (keeps the thread's context; no model parameter exists).
        case thread
        /// A stateless `generate.text` with this model.
        case model(ModelSelection, Source)
        /// A stateless `generate.text` without a model: opencode uses its default.
        case serverDefault

        public var selection: ModelSelection? { if case .model(let selection, _) = self { selection } else { nil } }
    }

    public enum Availability: Sendable, Hashable {
        case available
        /// Listed, but cannot be used now (the reason is shown).
        case unavailable(String)
        /// Not in the catalog of connected providers.
        case missing
        /// No catalog yet (offline, loading).
        case unknown
    }

    // MARK: Catalog facts

    /// Models that can be used now: enabled, not deprecated, and their provider not disabled.
    public static func usable(_ catalog: Catalog?) -> [ModelEntry] {
        guard let catalog else { return [] }
        let disabled = Set(catalog.providers.filter { $0.activation == "disabled" }.map(\.id))
        return catalog.models.filter { $0.enabled && $0.status != "deprecated" && !disabled.contains($0.providerID) }
    }

    public static func availability(of selection: ModelSelection, in catalog: Catalog?) -> Availability {
        guard let catalog else { return .unknown }
        guard let entry = catalog.models.first(where: { $0.providerID == selection.providerID && $0.modelID == selection.modelID }) else {
            return .missing
        }
        if catalog.providers.first(where: { $0.id == entry.providerID })?.activation == "disabled" {
            return .unavailable("Provider disabled in opencode")
        }
        if !entry.enabled { return .unavailable("Disabled in opencode") }
        if entry.status == "deprecated" { return .unavailable("Deprecated") }
        return .available
    }

    static func isUsable(_ selection: ModelSelection?, _ catalog: Catalog?) -> Bool {
        guard let selection else { return false }
        return availability(of: selection, in: catalog) == .available
    }

    public static func entry(_ selection: ModelSelection?, in catalog: Catalog?) -> ModelEntry? {
        guard let selection else { return nil }
        return catalog?.models.first { $0.providerID == selection.providerID && $0.modelID == selection.modelID }
    }

    /// True when a connected provider offers a usable paid model.
    public static func hasPaid(_ catalog: Catalog?) -> Bool { usable(catalog).contains { !$0.isFree } }

    static func isFree(_ selection: ModelSelection, _ catalog: Catalog?) -> Bool { entry(selection, in: catalog)?.isFree ?? false }

    static let fastWords = ["nano", "mini", "flash", "haiku", "lite", "small", "fast", "instant"]
    /// opencode 2.3.2's own small-model families, in its order (`Model.small`).
    static let smallFamilies = ["gpt-luna", "gemini-flash-lite", "gemini-flash", "claude-haiku"]

    static func isFast(_ entry: ModelEntry) -> Bool {
        fastWords.contains { entry.modelID.lowercased().contains($0) || entry.name.lowercased().contains($0) }
    }

    /// A fast catalogue model for background work: paid models first when any is connected, then free ones; within
    /// each, fast-sounding names first. Nil when nothing is usable.
    public static func fallback(_ catalog: Catalog?) -> ModelSelection? {
        let models = usable(catalog).filter(\.supportsText)
        let paid = models.filter { !$0.isFree }
        let pool = paid.isEmpty ? models.filter(\.isFree) : paid
        let ordered = pool.sorted { ($0.providerID, $0.name) < ($1.providerID, $1.name) }
        let pick = ordered.first(where: { smallFamilies.contains($0.family ?? "") }) ?? ordered.first(where: isFast) ?? ordered.first
        return pick?.selection
    }

    /// The small model: the owner's (opencode's `title` agent model) when usable, else opencode's choice for the
    /// provider (`Model.small`: a known fast family of that provider), else the catalogue fallback.
    public static func small(configured: ModelSelection?, provider: String?, catalog: Catalog?) -> ModelSelection? {
        if isUsable(configured, catalog) { return configured }
        if let provider {
            let mine = usable(catalog).filter { $0.providerID == provider && $0.supportsText }
            for family in smallFamilies {
                if let entry = mine.first(where: { $0.family == family }) { return entry.selection }
            }
        }
        return fallback(catalog)
    }

    // MARK: Tasks

    /// Auto's reviewer. `thread` is the thread's model (nil: it runs on the default).
    public static func reviewer(choice: ModelChoice, thread: ModelSelection?, catalog: Catalog?) -> Resolution {
        if case .specific(let selection) = choice, isUsable(selection, catalog) { return .model(selection, .owner) }
        let avoidFree = hasPaid(catalog)
        func acceptable(_ selection: ModelSelection?) -> ModelSelection? {
            guard let selection, isUsable(selection, catalog) else { return nil }
            return avoidFree && isFree(selection, catalog) ? nil : selection
        }
        if case .serverDefault = choice {
            if let server = catalog?.defaultModel, isUsable(server, catalog) { return .model(server, .serverDefault) }
            return .serverDefault
        }
        if let thread = acceptable(thread) { return .model(thread, .thread) }
        if let server = acceptable(catalog?.defaultModel) { return .model(server, .serverDefault) }
        if let fallback = fallback(catalog) { return .model(fallback, .fallback) }
        return .serverDefault
    }

    /// Commit messages, branch names, merge request title and description. `hasThread`: a thread exists to ask with
    /// its own context. `small`: the owner's small model.
    public static func gitText(
        choice: ModelChoice, thread: ModelSelection?, hasThread: Bool, small configured: ModelSelection?, catalog: Catalog?
    ) -> Resolution {
        switch choice {
        case .specific(let selection) where isUsable(selection, catalog):
            return .model(selection, .owner)
        case .smallModel:
            let provider = (thread ?? catalog?.defaultModel)?.providerID
            if let small = small(configured: configured, provider: provider, catalog: catalog) { return .model(small, .small) }
        case .serverDefault:
            if let server = catalog?.defaultModel, isUsable(server, catalog) { return .model(server, .serverDefault) }
            return .serverDefault
        case .sameAsThread, .specific:
            break
        }
        if hasThread { return .thread }
        if let thread, isUsable(thread, catalog) { return .model(thread, .thread) }
        if let server = catalog?.defaultModel, isUsable(server, catalog) { return .model(server, .serverDefault) }
        return .serverDefault
    }

    /// A delegated child thread or a scheduled run that names no model (its agent has none either). Nil: opencode's
    /// default.
    /// `small` is the owner's configured small model (used for `.smallModel`).
    public static func child(choice: ModelChoice, parent: ModelSelection?, catalog: Catalog?, small configured: ModelSelection? = nil) -> ModelSelection? {
        switch choice {
        case .specific(let selection): return isUsable(selection, catalog) || catalog == nil ? selection : parent
        case .serverDefault: return nil
        case .sameAsThread: return parent
        case .smallModel: return small(configured: configured, provider: parent?.providerID, catalog: catalog) ?? parent
        }
    }
}

extension ModelEntry {
    /// Accepts text in and out (an empty list means unknown: assumed yes).
    var supportsText: Bool { inputModalities.isEmpty || inputModalities.contains("text") }
}
