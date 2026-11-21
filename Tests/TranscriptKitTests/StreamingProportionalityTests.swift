import AppKit
import BelloCore
import Foundation
import Testing

@testable import TranscriptKit

/// v1.0.0 reviews N20 and A28: streaming one long reply does work proportional to the new bytes, and never parses the
/// whole message on the main actor per tick (even when it quotes image syntax). Asserted by counters, not time.
@Suite(.serialized) @MainActor struct StreamingProportionalityTests {
    /// Streams `paragraphs` paragraphs in small chunks; returns the bytes the stream examined in all.
    static func scanned(paragraphs: Int, chunk: Int = 16) -> (scanned: Int, bytes: Int) {
        var text = ""
        for index in 0..<paragraphs { text += "Paragraph \(index) with `code`, a [link](https://example.invalid) and words.\n\n" }
        let bytes = Array(text.utf8)
        var stream = MarkdownStream()
        var end = 0
        while end < bytes.count {
            end = min(bytes.count, end + chunk)
            stream.update(String(decoding: bytes[..<end], as: UTF8.self))
        }
        stream.finish(text)
        #expect(stream.blocks == MarkdownParser.blocks(text), "the incremental result equals a one-shot parse")
        return (stream.scannedBytes, bytes.count)
    }

    /// A28: four times the text costs about four times the work (linear), not sixteen (quadratic).
    @Test func streamingWorkGrowsLinearlyWithTheReply() {
        let small = Self.scanned(paragraphs: 200)
        let large = Self.scanned(paragraphs: 800)
        let ratio = Double(large.scanned) / Double(small.scanned)
        #expect(ratio < 6, "bytes scanned: \(small.scanned) for \(small.bytes) B, \(large.scanned) for \(large.bytes) B (×\(ratio))")
    }

    /// A28: a replaced (not extended) source is still detected, at the latest by `finish`.
    @Test func aReplacedSourceIsReparsed() {
        var stream = MarkdownStream()
        let first = (0..<40).map { "First \($0).\n\n" }.joined()
        stream.update(first)
        let replaced = (0..<40).map { "Other \($0).\n\n" }.joined()
        stream.update(replaced)
        stream.finish(replaced)
        #expect(stream.blocks == MarkdownParser.blocks(replaced))
    }

    /// N20: a streaming reply that quotes image syntax is never parsed on the main actor while it streams.
    @Test func aStreamingReplyWithImageSyntaxIsNotParsedOnTheMainActor() async {
        let harness = ControllerTests.Harness(messages: ControllerTests.longTranscript(turns: 4))
        defer { harness.close() }
        await harness.settle()
        let controller = harness.controller
        let id = MessageID("msg_stream_image")
        var text = "Use `![alt](url)` for images, like ![diagram](https://example.invalid/d.png).\n\n"
        let before = controller.metrics.mainThreadParses
        for revision in 1...24 {
            text += "More words in revision \(revision), still about ![images](https://example.invalid/\(revision).png). "
            if revision % 5 == 0 { text += "\n\n" }
            let streaming = revision < 24
            let part = Part(id: Part.makeID(message: id, .text(ordinal: 0)), index: 0, content: .text(text), isStreaming: streaming)
            let message = Message(
                id: id, sessionID: TranscriptSamples.session, kind: .assistant(AssistantInfo(isOpen: streaming)),
                created: Timestamp(milliseconds: 1.9e12 + 1), parts: [part], revision: revision)
            let syncs = controller.metrics.syncs
            harness.source.update(message)
            let deadline = ContinuousClock.now + .seconds(30)
            while controller.metrics.syncs == syncs, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            await harness.settle()
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while !controller.streamingRowIDs.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        await harness.settle()
        #expect(controller.metrics.tailJobs > 0)
        #expect(controller.metrics.mainThreadParses == before, "main-actor parses: \(controller.metrics.mainThreadParses - before)")
    }
}
