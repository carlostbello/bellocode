import Engine
import Foundation
import Testing
import TranscriptKit
@testable import DiffKit

/// Git with no user config, for corpus comparisons.
enum TestGit {
    static let runner: GitRunner = {
        var environment = GitRunner.defaultEnvironment()
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        return GitRunner(environment: environment, writableRoots: [FileManager.default.temporaryDirectory.path], allowsLocalRemotes: true)
    }()

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "bellocode-diffkit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A small deterministic generator (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Diff algorithm against git")
struct LineDiffTests {
    /// Random edits of a text drawn from a small vocabulary (so repeated lines create ties).
    static func corpus(seed: UInt64, count: Int) -> [(String, String)] {
        var generator = SeededGenerator(state: seed)
        let vocabulary = ["{", "}", "", "return x", "let a = 1", "let b = 2", "func f() {", "// note", "x += 1", "if y {", "print(z)"]
        var pairs: [(String, String)] = []
        for _ in 0..<count {
            let length = Int.random(in: 0...60, using: &generator)
            var old = (0..<length).map { _ in vocabulary.randomElement(using: &generator)! }
            if Bool.random(using: &generator) { old += (0..<Int.random(in: 0...5, using: &generator)).map { "unique \($0) \(Int.random(in: 0...9, using: &generator))" } }
            var new = old
            for _ in 0..<Int.random(in: 0...12, using: &generator) {
                let operation = Int.random(in: 0...2, using: &generator)
                if operation == 0 || new.isEmpty {
                    new.insert(vocabulary.randomElement(using: &generator)!, at: Int.random(in: 0...new.count, using: &generator))
                } else if operation == 1 {
                    new.remove(at: Int.random(in: 0..<new.count, using: &generator))
                } else {
                    new[Int.random(in: 0..<new.count, using: &generator)] = "changed \(Int.random(in: 0...99, using: &generator))"
                }
            }
            let oldText = old.isEmpty ? "" : old.joined(separator: "\n") + "\n"
            let newText = new.isEmpty ? "" : new.joined(separator: "\n") + "\n"
            pairs.append((oldText, newText))
        }
        return pairs
    }

    @Test func countsMatchGitMinimalAndPatchesApply() async throws {
        let directory = try TestGit.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairs = Self.corpus(seed: 42, count: 120)
        var compared = 0
        for (index, (old, new)) in pairs.enumerated() {
            let a = directory.appending(path: "a\(index).txt")
            let b = directory.appending(path: "b\(index).txt")
            try Data(old.utf8).write(to: a)
            try Data(new.utf8).write(to: b)
            let numstat = try await TestGit.runner.run(
                ["diff", "--no-index", "--minimal", "--numstat", "--", a.lastPathComponent, b.lastPathComponent], in: directory.path, allowFailure: true
            ).text
            let parts = numstat.split(separator: "\t")
            let gitAdded = parts.count >= 2 ? Int(parts[0]) ?? -1 : 0
            let gitDeleted = parts.count >= 2 ? Int(parts[1]) ?? -1 : 0
            let hunks = LineDiff.hunks(old: LineDiff.lines(old), new: LineDiff.lines(new))
            let added = hunks.reduce(0) { $0 + $1.additions }
            let deleted = hunks.reduce(0) { $0 + $1.deletions }
            #expect(added == gitAdded && deleted == gitDeleted, "pair \(index): ours +\(added) -\(deleted), git +\(gitAdded) -\(gitDeleted)")
            // Our patch applies with git and produces the new text.
            if !hunks.isEmpty {
                let patch = PatchFile(oldPath: a.lastPathComponent, newPath: a.lastPathComponent, hunks: hunks).render()
                let patchURL = directory.appending(path: "p\(index).patch")
                try Data(patch.utf8).write(to: patchURL)
                _ = try await TestGit.runner.run(["apply", "--unsafe-paths", patchURL.lastPathComponent], in: directory.path)
                #expect(try String(contentsOf: a, encoding: .utf8) == new, "pair \(index) applies")
            }
            compared += 1
        }
        #expect(compared == 120)
    }

    @Test func hunkHeadersMatchGit() async throws {
        let cases: [(String, String)] = [
            ("a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n", "a\nb\nc\nd\nE\nf\ng\nh\ni\nj\n"),
            ("", "one\ntwo\n"),
            ("one\ntwo\n", ""),
            ("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n", "1\n2\nX\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\nY\n19\n20\n"),
            ("x\ny\n", "x\ny\nz\n"),
            ("head\nkeep\n", "keep\n"),
        ]
        let directory = try TestGit.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, (old, new)) in cases.enumerated() {
            try Data(old.utf8).write(to: directory.appending(path: "a"))
            try Data(new.utf8).write(to: directory.appending(path: "b"))
            let text = try await TestGit.runner.run(["diff", "--no-index", "--minimal", "-U3", "--", "a", "b"], in: directory.path, allowFailure: true).text
            let gitHeaders = text.split(separator: "\n").filter { $0.hasPrefix("@@") }.map(String.init)
            let ours = LineDiff.hunks(old: LineDiff.lines(old), new: LineDiff.lines(new)).map(\.header)
            #expect(ours == gitHeaders, "case \(index)")
        }
    }

    @Test func ignoringWhitespaceKeepsRealText() {
        let hunks = LineDiff.hunks(old: ["if x {", "  y()", "}"], new: ["if x {", "    y()", "}", "z"], ignoreWhitespace: true)
        #expect(hunks.count == 1 && hunks[0].additions == 1 && hunks[0].deletions == 0)
        #expect(hunks[0].lines.contains { $0.kind == .context && $0.text == "  y()" })
    }

    @Test func tenThousandChangedLinesIsBoundedAndCorrect() {
        let old = (0..<20_000).map { "line \($0) old" }.map { Substring($0) }
        var new = old
        for index in stride(from: 0, to: 20_000, by: 2) { new[index] = Substring("line \(index) new") }
        let start = ContinuousClock.now
        let hunks = LineDiff.hunks(old: old, new: new)
        let elapsed = ContinuousClock.now - start
        #expect(hunks.reduce(0) { $0 + $1.additions } == 10_000)
        #expect(hunks.reduce(0) { $0 + $1.deletions } == 10_000)
        #expect(elapsed < .seconds(10), "debug build: \(elapsed)")
        // A wholly different pair hits the budget and degrades to a replacement, never hangs.
        let a = (0..<3_000).map { _ in Int.random(in: 0..<1_000_000) }
        let b = (0..<3_000).map { _ in Int.random(in: 0..<1_000_000) }
        let changes = LineDiff.changes(a, b, budget: 1_000_000)
        #expect(changes.deleted.allSatisfy { $0 } || !changes.approximate)
    }
}

@Suite("Intra-line highlights, rows and syntax")
struct DiffRowTests {
    @Test func wordHighlightsAreLocalAndBounded() {
        let highlight = IntraLine.highlight(removed: "let value = compute(1, fast: true)", added: "let value = compute(2, fast: false)")
        #expect(highlight.removed == [NSRange(location: 20, length: 1), NSRange(location: 29, length: 4)])
        #expect(highlight.added == [NSRange(location: 20, length: 1), NSRange(location: 29, length: 5)])
        #expect(IntraLine.highlight(removed: "abc def", added: "xyz uvw").isEmpty, "mostly different: whole-line only")
        #expect(IntraLine.highlight(removed: String(repeating: "a", count: 3_000), added: "b").isEmpty)
        let emoji = IntraLine.highlight(removed: "say 👋 hello world", added: "say 👋 howdy world")
        #expect(emoji.added == [NSRange(location: 7, length: 5)], "UTF-16 offsets across a surrogate pair")
    }

    static let file: DiffFile = {
        let old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\n"
        let new = "a\nB1\nB2\nB3\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nn\n"
        return DiffFile.compute(path: "x.swift", old: old, new: new, context: 1)
    }()

    @Test func splitRowsAlignChangeBlocks() {
        var options = DiffRowOptions()
        options.layout = .split
        let rows = DiffRowBuilder.build([Self.file], options: options)
        let lines = rows.rows.filter { if case .line = $0.kind { true } else { false } }
        // Hunk 1: a | b→B1,B2,B3 | c. Split: 1 context + 3 aligned rows (1 pair, 2 right-only) + 1 context.
        let first = Array(lines.prefix(5))
        #expect(first.map { $0.left?.text } == ["a", "b", nil, nil, "c"])
        #expect(first.map { $0.right?.text } == ["a", "B1", "B2", "B3", "c"])
        #expect(first[1].pairIndex == 0 && first[2].pairIndex == nil)
        #expect(first[4].left?.number == 3 && first[4].right?.number == 5)
        #expect(rows.hunkHeaderRows.count == 2)
        #expect(rows.rows.contains { if case .gap(let hidden, true) = $0.kind { hidden == 8 } else { false } })
        // Row IDs are unique and stable across rebuilds.
        #expect(Set(rows.rows.map(\.id)).count == rows.rows.count)
        #expect(DiffRowBuilder.build([Self.file], options: options).rows.map(\.id) == rows.rows.map(\.id))
    }

    @Test func unifiedRowsAndGapExpansion() {
        var options = DiffRowOptions()
        let rows = DiffRowBuilder.build([Self.file], options: options)
        let changed = rows.rows.compactMap(\.cell).filter { $0.kind != .context }
        #expect(changed.map(\.kind) == [.removed, .added, .added, .added, .removed])
        let gapCount = rows.rows.count
        options.expansions[GapKey(path: "x.swift", beforeHunk: 1)] = GapExpansion(top: 2, bottom: 3)
        let expanded = DiffRowBuilder.build([Self.file], options: options)
        #expect(expanded.rows.count == gapCount + 5)
        #expect(expanded.rows.contains { if case .gap(let hidden, _) = $0.kind { hidden == 3 } else { false } })
        options.expansions[GapKey(path: "x.swift", beforeHunk: 1)] = GapExpansion(top: 100, bottom: 0)
        let all = DiffRowBuilder.build([Self.file], options: options)
        #expect(!all.rows.contains { if case .gap(_, true) = $0.kind { $0.hunkIndex == 1 } else { false } })
        options.collapsedFiles = ["x.swift"]
        #expect(DiffRowBuilder.build([Self.file], options: options).rows.count == 1, "only the header")
    }

    @Test func binaryImageAndLargeFiles() {
        let binary = DiffFile.from(PatchFile(oldPath: "lib.a", newPath: "lib.a", isBinary: true))
        let image = DiffFile.from(PatchFile(oldPath: "icon.png", newPath: "icon.png", isBinary: true))
        let rows = DiffRowBuilder.build([binary, image], options: DiffRowOptions())
        #expect(rows.rows.filter { $0.kind == .notice }.map(\.text) == ["Binary file not shown", "Image changed (PNG). Open it to view."])
        let big = DiffFile.compute(path: "big.txt", old: nil, new: (0..<70_000).map { "l\($0)" }.joined(separator: "\n") + "\n")
        #expect(big.isLarge)
        let bigRows = DiffRowBuilder.build([big], options: DiffRowOptions())
        #expect(bigRows.pairs.isEmpty && bigRows.rows.count == 70_000 + 3)
    }

    @Test func syntaxRunsMapToLines() {
        let file = DiffFile.compute(path: "a.swift", old: "let a = 1\n", new: "/* start\nstill comment */\nlet a = \"two\"\n")
        let syntax = DiffSyntax.compute(for: file)
        #expect(syntax.new[1]?.first?.kind == .comment)
        #expect(syntax.new[2]?.first?.kind == .comment, "a block comment colours its second line")
        #expect(syntax.new[3]?.contains { $0.kind == .string && $0.location == 8 } == true)
        #expect(syntax.old[1]?.first?.kind == .keyword)
        #expect(DiffSyntax.language(forPath: "README.md") == nil && DiffSyntax.language(forPath: "x/y.tsx") == "typescript")
    }
}
