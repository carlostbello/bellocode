// G1-A spike tests: workload determinism, streaming tail parser equivalence, chunked storage bookkeeping.

import AppKit
import Testing
@testable import TranscriptKit

@Test func workloadIsDeterministicAndHasTheRequiredMix() {
    let a = SpikeWorkload.generate(messageCount: 10_000)
    #expect(a.stats.messages == 10_000)
    #expect(a.stats.tables == 400)
    #expect(a.stats.codeBlocks == 1_500)
    #expect(a.stats.tools == 2_000)
    #expect(a.stats.reasoning == 300)
    #expect(a.stats.diffs == 200)
    #expect(a.stats.images == 100)
    #expect(a.stats.hugeCodeBlockBytes == 100 * 1_024)
    let b = SpikeWorkload.generate(messageCount: 10_000)
    #expect(a.messages.map(\.id) == b.messages.map(\.id))
    #expect(a.stats.totalUTF8Bytes == b.stats.totalUTF8Bytes)
}

/// Applies tail updates to a plain string the way the controller applies them to the text storage.
private func streamed(_ script: String, splits: [Int]) -> String {
    var parser = SpikeTailParser()
    var view = "" as NSString
    var source = ""
    var cursor = script.startIndex
    for size in splits {
        guard cursor < script.endIndex else { break }
        let end = script.index(cursor, offsetBy: size, limitedBy: script.endIndex) ?? script.endIndex
        source += script[cursor..<end]
        cursor = end
        let (from, rich) = parser.update(source: source)
        view = view.replacingCharacters(in: NSRange(location: from, length: view.length - from), with: rich.text) as NSString
    }
    if cursor < script.endIndex {
        source += script[cursor...]
        let (from, rich) = parser.update(source: source)
        view = view.replacingCharacters(in: NSRange(location: from, length: view.length - from), with: rich.text) as NSString
    }
    return view as String
}

@Test func streamingTailMatchesFullRenderAtEverySplitSize() {
    let script = SpikeWorkload.streamScript(bytes: 6_000)
    var full = SpikeRich()
    SpikeMarkdown.render(script, into: &full)
    for size in 1...16 {
        let result = streamed(script, splits: Array(repeating: size, count: script.count / size + 1))
        #expect(result == full.text, "split size \(size)")
    }
    var rng = SpikeRNG(seed: 99)
    let random = (0..<4_000).map { _ in rng.int(1...16) }
    #expect(streamed(script, splits: random) == full.text)
}

@Test @MainActor func chunkedStorageKeepsOffsetsAcrossInsertsAndEdits() {
    let storage = SpikeChunkedStorage()
    storage.insertChunks([NSAttributedString(string: "bbb"), NSAttributedString(string: "cc")], at: 0)
    storage.insertChunks([NSAttributedString(string: "a")], at: 0)
    storage.insertChunks([NSAttributedString(string: "dddd")], at: storage.chunkCount)
    #expect(storage.string == "abbbccdddd")
    #expect(storage.chunkRange(3) == NSRange(location: 6, length: 4))
    storage.replaceCharacters(in: NSRange(location: 7, length: 2), with: NSAttributedString(string: "XYZ"))
    #expect(storage.string == "abbbccdXYZd")
    #expect(storage.chunkRange(3) == NSRange(location: 6, length: 5))
    storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 2, length: 6))
    var range = NSRange()
    _ = storage.attribute(.foregroundColor, at: 5, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length))
    #expect(range == NSRange(location: 2, length: 6))
    #expect(storage.attribute(.foregroundColor, at: 10, effectiveRange: nil) == nil)
}
