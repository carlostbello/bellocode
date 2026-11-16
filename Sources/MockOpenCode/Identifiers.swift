import Foundation

/// SplitMix64: a tiny, fast, seedable generator. Same seed, same sequence, on every platform.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `range`, without the platform-dependent algorithm of `Int.random(in:using:)`.
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(next() % span)
    }

    public mutating func chance(_ probability: Double) -> Bool {
        Double(next() >> 11) / Double(1 << 53) < probability
    }

    public mutating func pick<T>(_ items: [T]) -> T { items[int(in: 0...(items.count - 1))] }
}

/// Generates opencode-shaped identifiers (`ses_…`, `msg_…`, `evt_…`, `per_…`, `frm_…`).
///
/// Real ids are a 12-hex-digit time/counter prefix plus 14 random base62 characters; session ids invert the prefix so
/// newer sessions sort first. The mock keeps that shape but draws the random part from a seeded generator, so a
/// scenario with a fixed seed and the virtual clock produces identical ids on every run.
public struct IdentifierGenerator: Sendable {
    private var random: SeededRandom
    private var counter: UInt64 = 0
    private var lastTime: Int64 = 0

    public init(seed: UInt64) { random = SeededRandom(seed: seed) }

    public mutating func make(_ prefix: String, time: Int64, descending: Bool = false) -> String {
        if time != lastTime {
            lastTime = time
            counter = 0
        }
        counter += 1
        let value = (UInt64(max(time, 0)) & 0xF_FFFF_FFFF) << 12 | (counter & 0xFFF)
        let ordered = descending ? 0xFFFF_FFFF_FFFF - value : value
        var hex = String(ordered, radix: 16)
        if hex.count < 12 { hex = String(repeating: "0", count: 12 - hex.count) + hex }
        return prefix + "_" + hex + randomSuffix(14)
    }

    public mutating func randomSuffix(_ length: Int) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        return String((0..<length).map { _ in alphabet[Int(random.next() % 62)] })
    }

    /// A 40-character lowercase hex string, the shape of a project id (a repository's root commit hash).
    public mutating func hash40() -> String {
        (0..<5).map { _ in
            let hex = String(random.next() & 0xFFFF_FFFF, radix: 16)
            return String(repeating: "0", count: 8 - hex.count) + hex
        }.joined()
    }
}
