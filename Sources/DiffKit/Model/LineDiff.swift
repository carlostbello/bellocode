import Engine
import Foundation

/// Line diffs: Myers' O(ND) algorithm in linear space (the middle-snake recursion GNU diff uses), on interned lines,
/// with common prefix/suffix trimming and a cost budget. When the budget runs out the remaining region is reported as
/// wholly replaced (still a correct diff, just not minimal), so pathological inputs stay bounded.
///
/// Pure and `Sendable`; run it off the main actor.
public enum LineDiff {
    /// Interns lines to integers (equal text, equal id). With `ignoreWhitespace`, lines that differ only in
    /// whitespace get the same id.
    public static func intern(_ a: [Substring], _ b: [Substring], ignoreWhitespace: Bool = false) -> ([Int], [Int]) {
        var table: [Substring: Int] = [:]
        table.reserveCapacity(a.count + b.count)
        func id(_ line: Substring) -> Int {
            let key = ignoreWhitespace ? Substring(line.filter { !$0.isWhitespace }) : line
            if let existing = table[key] { return existing }
            let next = table.count
            table[key] = next
            return next
        }
        return (a.map(id), b.map(id))
    }

    /// Splits text into lines (no terminators; a final newline does not start an empty line).
    public static func lines(_ text: String) -> [Substring] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") || text.isEmpty { lines.removeLast() }
        return lines
    }

    /// Which lines changed: `deleted[i]` for old line i, `inserted[j]` for new line j.
    public struct Changes: Sendable, Equatable {
        public var deleted: [Bool]
        public var inserted: [Bool]
        /// The budget ran out somewhere (the result is correct but may not be minimal).
        public var approximate: Bool
    }

    /// Marks changed lines. `budget` bounds the inner-loop work (≈ (N+M)·D); the default allows a few hundred million
    /// steps.
    public static func changes(_ a: [Int], _ b: [Int], budget: Int = 300_000_000) -> Changes {
        // Lines that occur on one side only cannot be matched: mark them changed and diff the rest (GNU diff's
        // discarding; the result stays minimal). This turns typical large edits into small problems.
        var inB = Set<Int>()
        inB.reserveCapacity(b.count)
        for id in b { inB.insert(id) }
        var inA = Set<Int>()
        inA.reserveCapacity(a.count)
        for id in a { inA.insert(id) }
        var keptA: [Int] = []
        var mapA: [Int] = []
        var deleted = Array(repeating: false, count: a.count)
        for (index, id) in a.enumerated() {
            if inB.contains(id) {
                keptA.append(id)
                mapA.append(index)
            } else {
                deleted[index] = true
            }
        }
        var keptB: [Int] = []
        var mapB: [Int] = []
        var inserted = Array(repeating: false, count: b.count)
        for (index, id) in b.enumerated() {
            if inA.contains(id) {
                keptB.append(id)
                mapB.append(index)
            } else {
                inserted[index] = true
            }
        }
        var state = State(a: keptA, b: keptB, budget: budget)
        state.compare(0, keptA.count, 0, keptB.count)
        for (index, flag) in state.deleted.enumerated() where flag { deleted[mapA[index]] = true }
        for (index, flag) in state.inserted.enumerated() where flag { inserted[mapB[index]] = true }
        return Changes(deleted: deleted, inserted: inserted, approximate: state.budget <= 0)
    }

    private struct State {
        let a: [Int]
        let b: [Int]
        var deleted: [Bool]
        var inserted: [Bool]
        var forward: [Int]
        var backward: [Int]
        var budget: Int
        let offset: Int

        init(a: [Int], b: [Int], budget: Int) {
            self.a = a
            self.b = b
            deleted = Array(repeating: false, count: a.count)
            inserted = Array(repeating: false, count: b.count)
            let size = a.count + b.count + 3
            forward = Array(repeating: 0, count: 2 * size + 1)
            backward = Array(repeating: 0, count: 2 * size + 1)
            offset = size
            self.budget = budget
        }

        mutating func compare(_ aLow: Int, _ aHigh: Int, _ bLow: Int, _ bHigh: Int) {
            var aLow = aLow, aHigh = aHigh, bLow = bLow, bHigh = bHigh
            while aLow < aHigh, bLow < bHigh, a[aLow] == b[bLow] {
                aLow += 1
                bLow += 1
            }
            while aLow < aHigh, bLow < bHigh, a[aHigh - 1] == b[bHigh - 1] {
                aHigh -= 1
                bHigh -= 1
            }
            if aLow == aHigh {
                for j in bLow..<bHigh { inserted[j] = true }
                return
            }
            if bLow == bHigh {
                for i in aLow..<aHigh { deleted[i] = true }
                return
            }
            if budget <= 0 {
                for i in aLow..<aHigh { deleted[i] = true }
                for j in bLow..<bHigh { inserted[j] = true }
                return
            }
            guard let (x, y) = middleSnake(aLow, aHigh, bLow, bHigh), (x, y) != (aLow, bLow), (x, y) != (aHigh, bHigh) else {
                for i in aLow..<aHigh { deleted[i] = true }
                for j in bLow..<bHigh { inserted[j] = true }
                return
            }
            compare(aLow, x, bLow, y)
            compare(x, aHigh, y, bHigh)
        }

        /// A point (x, y) on an optimal path through the box, splitting it into two smaller problems.
        mutating func middleSnake(_ aLow: Int, _ aHigh: Int, _ bLow: Int, _ bHigh: Int) -> (Int, Int)? {
            let n = aHigh - aLow
            let m = bHigh - bLow
            let delta = n - m
            let odd = delta & 1 != 0
            let maxD = (n + m + 1) / 2
            // forward[k] = furthest x on diagonal k (k = x - y, relative to the box); backward likewise from the end.
            forward[offset + 1] = 0
            backward[offset + 1] = 0
            for d in 0...maxD {
                budget -= 2 * d + 1
                if budget <= 0 { return nil }
                var k = -d
                while k <= d {
                    var x: Int
                    if k == -d || (k != d && forward[offset + k - 1] < forward[offset + k + 1]) {
                        x = forward[offset + k + 1]
                    } else {
                        x = forward[offset + k - 1] + 1
                    }
                    var y = x - k
                    while x < n, y < m, a[aLow + x] == b[bLow + y] {
                        x += 1
                        y += 1
                    }
                    forward[offset + k] = x
                    if odd, k - delta >= -(d - 1), k - delta <= d - 1, x + backward[offset + delta - k] >= n {
                        return (aLow + x, bLow + y)
                    }
                    k += 2
                }
                k = -d
                while k <= d {
                    var x: Int
                    if k == -d || (k != d && backward[offset + k - 1] < backward[offset + k + 1]) {
                        x = backward[offset + k + 1]
                    } else {
                        x = backward[offset + k - 1] + 1
                    }
                    var y = x - k
                    while x < n, y < m, a[aHigh - 1 - x] == b[bHigh - 1 - y] {
                        x += 1
                        y += 1
                    }
                    backward[offset + k] = x
                    if !odd, delta - k >= -d, delta - k <= d, x + forward[offset + delta - k] >= n {
                        return (aHigh - x, bHigh - y)
                    }
                    k += 2
                }
            }
            return nil
        }
    }

    // MARK: Hunks

    /// Unified-diff hunks for two texts' lines, with `context` unchanged lines around each change (hunks closer than
    /// 2 × context merge). Line text is kept as given (whitespace-insensitive comparison still shows real text).
    public static func hunks(
        old: [Substring], new: [Substring], context: Int = 3, ignoreWhitespace: Bool = false, budget: Int = 300_000_000
    ) -> [PatchHunk] {
        let (a, b) = intern(old, new, ignoreWhitespace: ignoreWhitespace)
        let changes = changes(a, b, budget: budget)
        return hunks(old: old, new: new, changes: changes, context: context)
    }

    /// git's default hunk section: the nearest line above the hunk that starts with a letter, `_` or `$` (80
    /// characters at most). Scans at most 10,000 lines back.
    static func section(_ lines: [Substring], before index: Int) -> String {
        var line = index - 1
        var scanned = 0
        while line >= 0, scanned < 10_000 {
            if let first = lines[line].unicodeScalars.first, first == "_" || first == "$" || CharacterSet.letters.contains(first) {
                var text = String(lines[line])
                while text.last?.isWhitespace == true { text.removeLast() }
                return String(text.prefix(80))
            }
            line -= 1
            scanned += 1
        }
        return ""
    }

    /// Hunks from precomputed changes.
    public static func hunks(old: [Substring], new: [Substring], changes: Changes, context: Int = 3) -> [PatchHunk] {
        // Walk both sequences, collecting change blocks as (oldStart, oldEnd, newStart, newEnd).
        var blocks: [(Int, Int, Int, Int)] = []
        var i = 0
        var j = 0
        let n = old.count
        let m = new.count
        while i < n || j < m {
            if i < n, j < m, !changes.deleted[i], !changes.inserted[j] {
                i += 1
                j += 1
                continue
            }
            let startI = i
            let startJ = j
            while i < n, changes.deleted[i] { i += 1 }
            while j < m, changes.inserted[j] { j += 1 }
            if i == startI, j == startJ {
                // Defensive: unequal tails without flags (cannot happen for a valid change set).
                if i < n { i += 1 }
                if j < m { j += 1 }
            }
            blocks.append((startI, i, startJ, j))
        }
        guard !blocks.isEmpty else { return [] }
        var hunks: [PatchHunk] = []
        var group: [(Int, Int, Int, Int)] = [blocks[0]]
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let lead = min(context, first.0, first.2)
            let oldStart = first.0 - lead
            let newStart = first.2 - lead
            let trail = min(context, n - last.1, m - last.3)
            let oldEnd = last.1 + trail
            var lines: [PatchLine] = []
            var oi = oldStart
            var nj = newStart
            for block in group {
                while oi < block.0 {
                    lines.append(PatchLine(.context, String(old[oi])))
                    oi += 1
                    nj += 1
                }
                for index in block.0..<block.1 { lines.append(PatchLine(.removed, String(old[index]))) }
                for index in block.2..<block.3 { lines.append(PatchLine(.added, String(new[index]))) }
                oi = block.1
                nj = block.3
            }
            while oi < oldEnd {
                lines.append(PatchLine(.context, String(old[oi])))
                oi += 1
                nj += 1
            }
            let oldCount = lines.count { $0.kind != .added }
            let newCount = lines.count { $0.kind != .removed }
            // Unified convention: a zero-length side starts at the line before it.
            hunks.append(
                PatchHunk(
                    oldStart: oldCount == 0 ? oldStart : oldStart + 1, oldCount: oldCount,
                    newStart: newCount == 0 ? newStart : newStart + 1, newCount: newCount, section: section(old, before: oldStart), lines: lines))
        }
        for block in blocks.dropFirst() {
            if let last = group.last, block.0 - last.1 <= 2 * context {
                group.append(block)
            } else {
                flush()
                group = [block]
            }
        }
        flush()
        return hunks
    }
}
