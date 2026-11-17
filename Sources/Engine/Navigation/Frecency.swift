import BelloCore
import Foundation
import Observation

/// Frecency (frequency + recency) of palette picks, and the pick remembered per query for three weeks (as T3 Code).
/// Pure value; bounded (AGENTS.md rule 5): the lowest-scoring entries and the oldest query picks are dropped.
///
/// Keys are stable identities chosen by the caller: `"thread:<session ID>"`, `"project:<directory>"`,
/// `"command:<raw value>"`, `"file:<directory>/<path>"`.
public struct FrecencyIndex: Hashable, Sendable, Codable {
    public struct Entry: Hashable, Sendable, Codable {
        /// The most recent visits, newest last (at most `visitSample`).
        public var visits: [Timestamp]
        public var count: Int
    }

    public struct Pick: Hashable, Sendable, Codable {
        public var key: String
        public var at: Timestamp
    }

    public static let entryLimit = 1_000
    public static let pickLimit = 300
    public static let visitSample = 10
    public static let pickLifetime: Double = 21 * 86_400_000

    public private(set) var entries: [String: Entry] = [:]
    public private(set) var picks: [String: Pick] = [:]

    public init() {}

    /// Records that `key` was opened, after typing `query` (empty: picked from the recent list).
    public mutating func record(_ key: String, query: String = "", now: Timestamp) {
        var entry = entries[key] ?? Entry(visits: [], count: 0)
        entry.count += 1
        entry.visits.append(now)
        if entry.visits.count > Self.visitSample { entry.visits.removeFirst(entry.visits.count - Self.visitSample) }
        entries[key] = entry
        let normalized = Self.normalize(query)
        if !normalized.isEmpty { picks[normalized] = Pick(key: key, at: now) }
        trim(now: now)
    }

    /// Mozilla-style frecency: each sampled visit weighs by its age, scaled to the total visit count.
    public func score(_ key: String, now: Timestamp) -> Double {
        guard let entry = entries[key], !entry.visits.isEmpty else { return 0 }
        let day = 86_400_000.0
        let weights = entry.visits.reduce(0.0) { total, visit in
            let age = (now.milliseconds - visit.milliseconds) / day
            let weight: Double = switch age {
            case ..<(4.0 / 24): 100
            case ..<1: 80
            case ..<4: 60
            case ..<14: 40
            case ..<31: 20
            case ..<90: 10
            default: 5
            }
            return total + weight
        }
        return weights * Double(entry.count) / Double(entry.visits.count)
    }

    /// The key picked last time this query (or a query it extends) was typed, within three weeks.
    public func pick(for query: String, now: Timestamp) -> String? {
        let normalized = Self.normalize(query)
        guard !normalized.isEmpty, let pick = picks[normalized], now.milliseconds - pick.at.milliseconds < Self.pickLifetime else { return nil }
        return pick.key
    }

    /// The most frecent keys with a prefix ("thread:"), best first.
    public func top(prefix: String = "", limit: Int, now: Timestamp) -> [String] {
        entries.keys.filter { $0.hasPrefix(prefix) }
            .map { ($0, score($0, now: now)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(limit).map(\.0)
    }

    public mutating func remove(_ key: String) {
        entries[key] = nil
        picks = picks.filter { $0.value.key != key }
    }

    static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private mutating func trim(now: Timestamp) {
        if entries.count > Self.entryLimit {
            let ranked = entries.keys.map { ($0, score($0, now: now)) }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 > $1.0 }
            for (key, _) in ranked.prefix(entries.count - Self.entryLimit) { entries[key] = nil }
        }
        picks = picks.filter { now.milliseconds - $0.value.at.milliseconds < Self.pickLifetime }
        if picks.count > Self.pickLimit {
            let oldest = picks.sorted { $0.value.at < $1.value.at }.prefix(picks.count - Self.pickLimit).map(\.key)
            for key in oldest { picks[key] = nil }
        }
    }
}

/// The app's frecency index, loaded from and saved to the store (`app_preference`, write-behind 1 s).
///
/// Threading: `@MainActor`, `@Observable` (`index`). Owned by `Engine` (shared by every window).
@MainActor
@Observable
public final class FrecencyModel {
    public private(set) var index = FrecencyIndex()
    @ObservationIgnored private let store: ProjectionStore?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var dirty = false
    static let key = "palette-frecency"

    public init(store: ProjectionStore?) { self.store = store }

    public func load() async {
        guard !isLoaded else { return }
        isLoaded = true
        if !dirty, let stored = try? await store?.preference(Self.key, as: FrecencyIndex.self) { index = stored }
    }

    public func record(_ key: String, query: String = "", now: Timestamp = .now) {
        index.record(key, query: query, now: now)
        dirty = true
        scheduleSave()
    }

    public func remove(_ key: String) {
        index.remove(key)
        dirty = true
        scheduleSave()
    }

    private func scheduleSave() {
        guard let store, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.saveTask = nil
            try? await store.setPreference(Self.key, self.index)
        }
    }

    /// Writes now (shutdown, tests).
    public func flush() async {
        saveTask?.cancel()
        saveTask = nil
        guard dirty, let store else { return }
        try? await store.setPreference(Self.key, index)
    }
}
