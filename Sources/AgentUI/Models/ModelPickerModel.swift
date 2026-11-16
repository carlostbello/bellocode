import BelloCore
import Engine
import Foundation
import Observation

/// State of the model picker: filtered, grouped rows built from the cached catalog (no network to open), keyboard
/// highlight, per-model variant choice, favourites/recents/hidden from `ModelPreferencesModel`, and optimistic apply
/// with rollback.
@MainActor
@Observable
public final class ModelPickerModel {
    public enum RowKind: Hashable, Sendable {
        case model(ModelEntry, providerName: String)
        /// A provider that is not connected: shown disabled with a direct "Connect…".
        case connect(integrationID: String, name: String)
        case connectOther
    }

    public struct Row: Hashable, Sendable, Identifiable {
        public var id: String
        public var kind: RowKind
        public var isEnabled: Bool
        /// Why a model row is disabled.
        public var disabledReason: String?

        public var model: ModelEntry? { if case .model(let model, _) = kind { model } else { nil } }
    }

    public struct Section: Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var rows: [Row]
    }

    // Inputs
    @ObservationIgnored private let catalog: @MainActor () -> Catalog?
    @ObservationIgnored private let current: @MainActor () -> ModelSelection?
    @ObservationIgnored private let apply: @MainActor (ModelSelection) async -> String?
    @ObservationIgnored private let integrations: @MainActor () -> [IntegrationItem]
    @ObservationIgnored private let reload: @MainActor () async -> Void
    /// Opens the provider connection UI (nil: let the user pick a provider).
    @ObservationIgnored public var onConnect: @MainActor (String?) -> Void
    public let preferences: ModelPreferencesModel

    // State
    public var query = "" {
        didSet { if query != oldValue { highlightedID = selectableRows.first?.id } }
    }
    public var highlightedID: String?
    /// The variant picked in the picker per model ID (nil entry: the model's default).
    public var variantChoice: [String: String] = [:]
    public var showsHidden = false
    /// Shown while the server has not confirmed a selection.
    public private(set) var pending: ModelSelection?
    public private(set) var error: String?
    public private(set) var isRefreshing = false

    /// - Parameters:
    ///   - apply: sets the model and returns an error message on failure (the engine already rolled back).
    ///   - integrations: sign-in state for "Not connected" rows (empty when no AuthService is mounted).
    public init(
        catalog: @escaping @MainActor () -> Catalog?, current: @escaping @MainActor () -> ModelSelection?,
        preferences: ModelPreferencesModel, apply: @escaping @MainActor (ModelSelection) async -> String?,
        integrations: @escaping @MainActor () -> [IntegrationItem] = { [] },
        reload: @escaping @MainActor () async -> Void = {}, onConnect: @escaping @MainActor (String?) -> Void = { _ in }
    ) {
        self.catalog = catalog
        self.current = current
        self.preferences = preferences
        self.apply = apply
        self.integrations = integrations
        self.reload = reload
        self.onConnect = onConnect
    }

    /// The selection to show: the optimistic one while pending, else the thread's.
    public var selection: ModelSelection? { pending ?? current() }

    public var selectedModel: ModelEntry? {
        guard let selection else { return nil }
        return catalog()?.models.first { $0.providerID == selection.providerID && $0.modelID == selection.modelID }
    }

    /// Incremented by `requestOpen()`; the button opens its popover when it changes (menu item "Choose Model…").
    public private(set) var openRequests = 0

    /// Asks the model button to open its popover.
    public func requestOpen() { openRequests += 1 }

    /// Called when the popover opens: highlight the current model, clear the query.
    public func prepareForOpen() {
        query = ""
        error = nil
        let id = selection.map { "\($0.providerID)/\($0.modelID)" }
        highlightedID = selectableRows.first { $0.model?.id == id }?.id ?? selectableRows.first?.id
        if let selection, let variant = selection.variant { variantChoice[id ?? ""] = variant }
    }

    // MARK: Rows

    public var sections: [Section] {
        guard let catalog = catalog() else { return connectSections(matching: query) }
        let names = Dictionary(catalog.providers.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let disabledProviders = Set(catalog.providers.filter { $0.activation == "disabled" }.map(\.id))
        let prefs = preferences.value
        func row(_ model: ModelEntry, section: String) -> Row {
            let reason: String? =
                disabledProviders.contains(model.providerID) ? "Provider disabled in opencode"
                : !model.enabled ? "Disabled in opencode" : nil
            return Row(
                id: "\(section)|\(model.id)", kind: .model(model, providerName: names[model.providerID] ?? model.providerID),
                isEnabled: reason == nil, disabledReason: reason)
        }
        let models = catalog.models
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let ranked = models.compactMap { model -> (ModelEntry, Int)? in
                if prefs.hidden.contains(model.id), !showsHidden { return nil }
                let provider = names[model.providerID] ?? model.providerID
                guard let score = FuzzyMatcher.score(
                    trimmed, fields: [model.name, model.modelID, "\(provider) \(model.name)", model.family ?? ""])
                else { return nil }
                let bonus = (prefs.isFavourite(model.id) ? 6 : 0) + (prefs.recents.contains(model.id) ? 3 : 0)
                return (model, score + bonus)
            }.sorted { $0.1 > $1.1 }
            var sections: [Section] = []
            if !ranked.isEmpty {
                sections.append(Section(id: "results", title: "Models", rows: ranked.prefix(80).map { row($0.0, section: "results") }))
            }
            return sections + connectSections(matching: trimmed)
        }

        let byID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var sections: [Section] = []
        let favourites = prefs.favourites.compactMap { byID[$0] }
        if !favourites.isEmpty {
            sections.append(Section(id: "favourites", title: "Favourites", rows: favourites.map { row($0, section: "favourites") }))
        }
        let recents = prefs.recents.filter { !prefs.isFavourite($0) }.compactMap { byID[$0] }.prefix(5)
        if !recents.isEmpty {
            sections.append(Section(id: "recent", title: "Recent", rows: recents.map { row($0, section: "recent") }))
        }
        var providerOrder: [String] = []
        for model in models where !providerOrder.contains(model.providerID) { providerOrder.append(model.providerID) }
        for provider in providerOrder {
            let visible = models.filter { $0.providerID == provider && (showsHidden || !prefs.hidden.contains($0.id)) }
            guard !visible.isEmpty else { continue }
            sections.append(Section(
                id: "provider-\(provider)", title: names[provider] ?? provider, rows: visible.map { row($0, section: provider) }))
        }
        return sections + connectSections(matching: "")
    }

    /// Providers that are not connected yet, featured first; matching the query when there is one.
    private func connectSections(matching query: String) -> [Section] {
        let connectedProviders = Set(catalog()?.providers.map { $0.integrationID ?? $0.id } ?? [])
        let candidates = integrations().filter { !$0.isConnected && !connectedProviders.contains($0.id) && !$0.interactiveMethods.isEmpty }
        let shown: [IntegrationItem]
        if query.isEmpty {
            shown = AuthService.featured.compactMap { id in candidates.first { $0.id == id } }
        } else {
            shown = candidates.compactMap { item in FuzzyMatcher.score(query, fields: [item.name, item.id]).map { (item, $0) } }
                .sorted { $0.1 > $1.1 }.prefix(5).map(\.0)
        }
        var rows = shown.map { Row(id: "connect|\($0.id)", kind: .connect(integrationID: $0.id, name: $0.name), isEnabled: true) }
        if query.isEmpty || rows.isEmpty {
            rows.append(Row(id: "connect|*", kind: .connectOther, isEnabled: true))
        }
        return [Section(id: "connect", title: "Not connected", rows: rows)]
    }

    /// Rows the keyboard can land on, in display order.
    public var selectableRows: [Row] { sections.flatMap(\.rows).filter(\.isEnabled) }

    public var highlightedRow: Row? {
        let rows = selectableRows
        return rows.first { $0.id == highlightedID } ?? rows.first
    }

    // MARK: Keyboard

    public func moveHighlight(_ delta: Int) {
        let rows = selectableRows
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == highlightedRow?.id } ?? 0
        highlightedID = rows[max(0, min(rows.count - 1, index + delta))].id
    }

    /// Cycles the highlighted model's variant (effort): default, then each variant the catalog lists.
    public func cycleVariant(_ delta: Int) {
        guard let model = highlightedRow?.model, !model.variants.isEmpty else { return }
        let options: [String?] = [nil] + model.variants.map(Optional.some)
        let currentVariant = variant(for: model)
        let index = options.firstIndex(of: currentVariant) ?? 0
        variantChoice[model.id] = options[(index + delta + options.count) % options.count]
    }

    /// The variant that choosing `model` would apply.
    public func variant(for model: ModelEntry) -> String? {
        if let chosen = variantChoice[model.id] { return model.variants.contains(chosen) ? chosen : nil }
        if let selection, selection.providerID == model.providerID, selection.modelID == model.modelID {
            return selection.variant
        }
        return preferences.value.variants[model.id].flatMap { model.variants.contains($0) ? $0 : nil }
    }

    public func setVariant(_ variant: String?, for model: ModelEntry) {
        variantChoice[model.id] = variant
    }

    // MARK: Actions

    /// Chooses a row: a model applies (optimistically), a connect row opens the connection UI. Returns whether the
    /// popover should close.
    @discardableResult
    public func choose(_ row: Row) -> Bool {
        guard row.isEnabled else { return false }
        switch row.kind {
        case .model(let model, _):
            let selection = ModelSelection(providerID: model.providerID, modelID: model.modelID, variant: variant(for: model))
            select(selection)
            return true
        case .connect(let integrationID, _):
            onConnect(integrationID)
            return true
        case .connectOther:
            onConnect(nil)
            return true
        }
    }

    public func chooseHighlighted() -> Bool {
        guard let row = highlightedRow else { return false }
        return choose(row)
    }

    @ObservationIgnored private var applyTask: Task<Void, Never>?

    /// Applies at once (shown as `pending`), confirms with the server, and rolls back with a visible error on failure.
    public func select(_ selection: ModelSelection) {
        guard selection != current() else { return }
        pending = selection
        error = nil
        let previous = applyTask
        applyTask = Task {
            await previous?.value
            let failure = await apply(selection)
            guard pending == selection else { return }
            pending = nil
            if let failure {
                error = failure
            } else {
                preferences.update { $0.recordUse(selection) }
            }
        }
    }

    public func toggleFavourite(_ model: ModelEntry) { preferences.update { $0.toggleFavourite(model.id) } }

    public func setHidden(_ model: ModelEntry, _ hidden: Bool) { preferences.update { $0.setHidden(model.id, hidden) } }

    public func refresh() async {
        isRefreshing = true
        await reload()
        isRefreshing = false
    }

    /// Waits for an in-flight apply (tests, demos).
    public func settle() async { await applyTask?.value }

    // MARK: Formatting

    /// "200K", "1M".
    public static func contextLabel(_ tokens: Int) -> String? {
        guard tokens > 0 else { return nil }
        if tokens >= 1_000_000 {
            let value = Double(tokens) / 1_000_000
            return value.rounded() == value ? "\(Int(value))M" : String(format: "%.1fM", value)
        }
        return "\(tokens / 1000)K"
    }

    /// "Free", or "$3 / $15" (USD per million input / output tokens).
    public static func costLabel(_ model: ModelEntry) -> String? {
        if model.isFree { return "Free" }
        guard let input = model.inputCost, let output = model.outputCost else { return nil }
        func money(_ value: Double) -> String {
            value >= 10 || value.rounded() == value ? "$\(Int(value.rounded()))" : String(format: "$%.2f", value)
        }
        return "\(money(input)) / \(money(output))"
    }
}
