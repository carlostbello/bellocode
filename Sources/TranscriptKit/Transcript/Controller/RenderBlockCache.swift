import Foundation
import Synchronization

/// Parsed blocks by (row ID, version), shared by off-main layout and main-actor copy, find and selection, so a
/// finished message is parsed once. Bounded by entry count and total text; overflow evicts the least recently used
/// entries (they are re-parsed on demand).
public final class RenderBlockCache: Sendable {
    private struct Entry {
        var version: Int
        var blocks: [RenderBlock]
        var cost: Int
        var tick: UInt64
    }

    private struct State {
        var entries: [RowID: Entry] = [:]
        var tick: UInt64 = 0
        var cost = 0
    }

    private let state = Mutex(State())
    private let countLimit: Int
    private let costLimit: Int

    public init(countLimit: Int = 4_096, costLimit: Int = 24 << 20) {
        self.countLimit = countLimit
        self.costLimit = costLimit
    }

    /// The blocks of `row`, parsed now if not cached.
    public func blocks(for row: TranscriptRow) -> [RenderBlock] {
        if let hit = state.withLock({ state -> [RenderBlock]? in
            guard var entry = state.entries[row.id], entry.version == row.version else { return nil }
            state.tick += 1
            entry.tick = state.tick
            state.entries[row.id] = entry
            return entry.blocks
        }) {
            return hit
        }
        let blocks = RenderBlocks.blocks(for: row)
        store(blocks, for: row)
        return blocks
    }

    /// Stores blocks computed elsewhere (the streaming tail's reconciled parse).
    public func store(_ blocks: [RenderBlock], for row: TranscriptRow) {
        let cost = Self.cost(row)
        state.withLock { state in
            state.tick += 1
            if let old = state.entries[row.id] { state.cost -= old.cost }
            state.entries[row.id] = Entry(version: row.version, blocks: blocks, cost: cost, tick: state.tick)
            state.cost += cost
            guard state.entries.count > countLimit || state.cost > costLimit else { return }
            let ordered = state.entries.sorted { $0.value.tick < $1.value.tick }
            for (id, entry) in ordered {
                guard state.entries.count > countLimit * 3 / 4 || state.cost > costLimit * 3 / 4 else { break }
                state.entries[id] = nil
                state.cost -= entry.cost
            }
        }
    }

    public var count: Int { state.withLock { $0.entries.count } }

    public func removeAll() { state.withLock { $0 = State() } }

    private static func cost(_ row: TranscriptRow) -> Int {
        switch row.content {
        case .markdown(let text, _): text.utf8.count
        case .reasoning(let reasoning): reasoning.text.utf8.count
        case .work(let group): group.items.reduce(64) { $0 + $1.input.utf8.count + $1.output.utf8.count }
        case .user(let user): user.text.utf8.count
        default: 64
        }
    }
}
