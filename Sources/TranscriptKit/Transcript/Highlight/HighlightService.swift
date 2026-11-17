import Foundation
import Synchronization

/// What a span of code is. Colours come from `DS.Syntax` (TranscriptTheme).
public enum TokenKind: UInt8, Sendable, Hashable {
    case keyword, type, string, comment, number, function, property, tag, attribute, variable, meta
    case diffAdded, diffRemoved, diffHunk, diffHeader
}

/// A highlighted span. Offsets are UTF-16 into the code string.
public struct TokenRun: Sendable, Hashable {
    public var location: Int
    public var length: Int
    public var kind: TokenKind

    public init(location: Int, length: Int, kind: TokenKind) {
        self.location = location
        self.length = length
        self.kind = kind
    }
}

/// Syntax highlighting behind a protocol, so a tree-sitter implementation can replace the tokenizer later.
///
/// Implementations are `Sendable`, run off the main actor, cache by content and stop early when the calling task is
/// cancelled (returning what they have, never a wrong result for the content they were given).
public protocol HighlightService: Sendable {
    /// Tokens for `code` in `language` (nil or unknown: no tokens, plain text). Runs on the caller's executor;
    /// call it from off-main work (layout).
    func tokens(for code: String, language: String?) -> [TokenRun]
    /// Whether `language` (or an alias) is supported.
    func supports(_ language: String?) -> Bool
}

extension HighlightService {
    /// Off-main entry point for callers on the main actor.
    @concurrent
    public func highlight(_ code: String, language: String?) async -> [TokenRun] {
        tokens(for: code, language: language)
    }
}

/// The built-in, dependency-free highlighter: a small tokenizer per language family with a bounded LRU cache.
public final class TokenizerHighlighter: HighlightService {
    public static let shared = TokenizerHighlighter()

    /// Code above this size is not highlighted (plain text), bounding the work per block.
    public static let maxCodeUTF16 = 2_000_000

    private struct Key: Hashable {
        var language: String
        var hash: Int
        var length: Int
    }

    private struct Cache {
        var entries: [Key: (runs: [TokenRun], tick: UInt64)] = [:]
        var tick: UInt64 = 0
        var cost = 0
    }

    private let cache = Mutex(Cache())
    /// Cache bound: total cached code length (UTF-16 units). Overflow evicts the least recently used entries.
    private let costLimit: Int

    public init(costLimit: Int = 2_000_000) { self.costLimit = costLimit }

    public func supports(_ language: String?) -> Bool { Languages.spec(for: language) != nil }

    public func tokens(for code: String, language: String?) -> [TokenRun] {
        guard let spec = Languages.spec(for: language) else { return [] }
        let units = code.utf16.count
        guard units > 0, units <= Self.maxCodeUTF16 else { return [] }
        let key = Key(language: spec.name, hash: code.hashValue, length: units)
        if let hit = cache.withLock({ cache -> [TokenRun]? in
            guard let entry = cache.entries[key] else { return nil }
            cache.tick += 1
            cache.entries[key] = (entry.runs, cache.tick)
            return entry.runs
        }) {
            return hit
        }
        let runs = Tokenizer.tokenize(Array(code.utf16), spec: spec)
        if Task.isCancelled { return runs }
        cache.withLock { cache in
            cache.tick += 1
            cache.entries[key] = (runs, cache.tick)
            cache.cost += units
            if cache.cost > costLimit {
                let ordered = cache.entries.sorted { $0.value.tick < $1.value.tick }
                for (oldKey, _) in ordered where cache.cost > costLimit * 3 / 4 {
                    cache.entries[oldKey] = nil
                    cache.cost -= oldKey.length
                }
            }
        }
        return runs
    }

    public func removeAll() { cache.withLock { $0 = Cache() } }

    public var statistics: (entries: Int, cost: Int) { cache.withLock { ($0.entries.count, $0.cost) } }

    /// For tests: number of cached entries.
    var cachedEntryCount: Int { cache.withLock { $0.entries.count } }
}
