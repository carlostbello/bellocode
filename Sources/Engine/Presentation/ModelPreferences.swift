import BelloCore
import Foundation
import Observation

/// The user's model picker preferences: favourites (pinned, in order), recently used and hidden models. Keys are
/// `ModelEntry.id` (`provider/model`). App-owned state, persisted in the projection store (`app_preference`).
public struct ModelPreferences: Hashable, Sendable, Codable {
    public var favourites: [String]
    /// Most recent first, at most `recentLimit`.
    public var recents: [String]
    public var hidden: Set<String>
    /// The last variant chosen per model, so re-selecting a model keeps its effort.
    public var variants: [String: String]

    public static let recentLimit = 8

    public init(favourites: [String] = [], recents: [String] = [], hidden: Set<String> = [], variants: [String: String] = [:]) {
        self.favourites = favourites
        self.recents = recents
        self.hidden = hidden
        self.variants = variants
    }

    public func isFavourite(_ id: String) -> Bool { favourites.contains(id) }

    public mutating func toggleFavourite(_ id: String) {
        if let index = favourites.firstIndex(of: id) { favourites.remove(at: index) } else { favourites.append(id) }
    }

    public mutating func recordUse(_ selection: ModelSelection) {
        let id = "\(selection.providerID)/\(selection.modelID)"
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        if recents.count > Self.recentLimit { recents.removeLast(recents.count - Self.recentLimit) }
        if let variant = selection.variant { variants[id] = variant } else { variants[id] = nil }
    }

    public mutating func setHidden(_ id: String, _ hidden: Bool) {
        if hidden { self.hidden.insert(id) } else { self.hidden.remove(id) }
    }
}

/// Observable, persisted `ModelPreferences`.
///
/// Threading: `@MainActor`. Changes apply at once and are written behind; a failed write keeps the in-memory value
/// (it is preference data, rewritten on the next change).
@MainActor
@Observable
public final class ModelPreferencesModel {
    public private(set) var value = ModelPreferences()
    public private(set) var isLoaded = false

    @ObservationIgnored private let store: ProjectionStore?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    static let key = "model-preferences"

    /// `store == nil` keeps preferences in memory only (previews, demos).
    public init(store: ProjectionStore?) {
        self.store = store
    }

    /// Reads the stored value once. Edits made before loading finishes win over the stored value.
    public func load() async {
        guard !isLoaded else { return }
        let before = generation
        let stored = try? await store?.preference(Self.key, as: ModelPreferences.self)
        if generation == before, let stored { value = stored }
        isLoaded = true
    }

    public func update(_ body: (inout ModelPreferences) -> Void) {
        var next = value
        body(&next)
        guard next != value else { return }
        value = next
        generation += 1
        guard let store else { return }
        let snapshot = next
        let previous = saveTask
        saveTask = Task {
            await previous?.value
            try? await store.setPreference(Self.key, snapshot)
        }
    }

    /// Waits for pending writes (tests, shutdown).
    public func flush() async { await saveTask?.value }
}
