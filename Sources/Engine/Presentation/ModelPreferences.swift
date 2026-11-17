import BelloCore
import Foundation
import Observation
import OpenCodeKit

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
/// Threading: `@MainActor`. Changes apply at once and are written behind, one write at a time with the latest value. A
/// failed write is not dropped: `saveFailed` turns true (the UI says changes are not being saved) and the latest value
/// is retried with backoff until a write succeeds; `flush()` tries once more.
@MainActor
@Observable
public final class ModelPreferencesModel {
    public private(set) var value = ModelPreferences()
    public private(set) var isLoaded = false
    /// The last write failed; the value is kept in memory and retried.
    public private(set) var saveFailed = false

    @ObservationIgnored private let store: ProjectionStore?
    @ObservationIgnored private let retryBackoff: BackoffPolicy
    @ObservationIgnored private let time: any TimeSource
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var savedGeneration = 0
    @ObservationIgnored private var failures = 0
    static let key = "model-preferences"

    /// `store == nil` keeps preferences in memory only (previews, demos).
    public init(
        store: ProjectionStore?, retryBackoff: BackoffPolicy = BackoffPolicy(initial: .milliseconds(250), maximum: .seconds(10)),
        time: any TimeSource = SystemTimeSource()
    ) {
        self.store = store
        self.retryBackoff = retryBackoff
        self.time = time
    }

    isolated deinit {
        retryTask?.cancel()
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
        save()
    }

    /// Writes the current value after any write in flight (one at a time; the newest value wins).
    private func save() {
        guard let store else { return }
        retryTask?.cancel()
        retryTask = nil
        let previous = saveTask
        saveTask = Task { [weak self] in
            await previous?.value
            guard let self, self.savedGeneration < self.generation else { return }
            let snapshot = self.value
            let generation = self.generation
            do {
                try await store.setPreference(Self.key, snapshot)
                self.savedGeneration = max(self.savedGeneration, generation)
                self.failures = 0
                if self.savedGeneration == self.generation { self.saveFailed = false }
            } catch {
                self.failures += 1
                self.saveFailed = true
                self.scheduleRetry()
            }
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        let delay = retryBackoff.delay(forAttempt: failures, random: Double.random(in: 0..<1))
        let time = self.time
        retryTask = Task { [weak self] in
            do { try await time.sleep(for: delay) } catch { return }
            self?.retryTask = nil
            self?.save()
        }
    }

    /// Waits for pending writes, retrying a failed one once (tests, shutdown).
    public func flush() async {
        await saveTask?.value
        if saveFailed {
            save()
            await saveTask?.value
        }
        retryTask?.cancel()
        retryTask = nil
    }
}
