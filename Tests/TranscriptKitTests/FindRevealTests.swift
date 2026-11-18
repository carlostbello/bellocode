import AppKit
import BelloCore
import Foundation
import Testing

@testable import TranscriptKit

/// Review finding M4 (docs/reviews/M2-M4-review.md): revealing a find match in a large row that is neither parsed
/// nor laid out must not parse or lay it out on the main actor; late results are dropped after a rebind or a newer
/// reveal.
@Suite(.serialized) @MainActor struct FindRevealTests {
    /// A long history whose first reply is a very large message (prose and a long code fence) far above the viewport.
    static func messages(largeReplyBytes: Int = 200_000) -> [Message] {
        var builder = TranscriptSamples.Builder()
        builder.user("Generate the big file")
        var big = "Here is the generated module.\n\n```swift\n"
        var line = 0
        while big.utf8.count < largeReplyBytes {
            line += 1
            big += "let value\(line) = compute(\(line)) // filler line \(line)\n"
        }
        big += "```\n\nThe needle-in-haystack marker is here.\n"
        builder.assistant([.text(big)])
        for turn in 0..<60 {
            builder.user("Question \(turn)")
            builder.assistant([.text("Answer \(turn). " + String(repeating: "Words keep the rows tall. ", count: 8))])
        }
        return builder.messages
    }

    /// Waits (real time, bounded) for the find's matches: a fixed number of short sleeps runs out under load.
    static func waitForMatches(_ controller: TranscriptController, timeout: Duration = .seconds(30)) async {
        let deadline = ContinuousClock.now + timeout
        while controller.findMatches.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func revealingAnUncachedLargeRowParsesAndLaysOutOffMain() async {
        let harness = ControllerTests.Harness(messages: Self.messages(), size: NSSize(width: 800, height: 500))
        defer { harness.close() }
        await harness.settle()
        let controller = harness.controller
        let bigRow = try! #require(controller.rows.first { if case .markdown(let text, _) = $0.content { text.utf8.count > 100_000 } else { false } })
        // Build the find index, then forget the big row's parse and layout (as after eviction).
        controller.showFind()
        controller.setFindQuery("needle-in-haystack", debounce: false)
        await Self.waitForMatches(controller)
        controller.closeFind()
        controller.jumpToLatest()
        await harness.settle()
        #expect(!controller.scrollView.contentView.bounds.intersects(controller.rowRect(controller.rows.firstIndex { $0.id == bigRow.id }!)))
        controller.purge(.parse)
        controller.purge(.layouts)
        #expect(controller.blockCache.cachedBlocks(for: bigRow) == nil)
        controller.metrics.mainThreadParses = 0
        controller.metrics.findSyncLayouts = 0

        controller.showFind()
        controller.setFindQuery("needle-in-haystack", debounce: false)
        await Self.waitForMatches(controller)
        await harness.settle()
        #expect(controller.findMatches.count == 1)
        #expect(controller.findMatches.first?.rowID == bigRow.id)
        #expect(controller.metrics.mainThreadParses == 0, "parses on the main actor: \(controller.metrics.mainThreadParses)")
        #expect(controller.metrics.findSyncLayouts == 0, "synchronous layouts: \(controller.metrics.findSyncLayouts)")
        let rect = try! #require(controller.visibleRectOfCurrentMatch())
        #expect(controller.scrollView.bounds.intersects(rect), "the match is revealed once its layout arrives")
    }

    /// A reveal still waiting for its off-main parse is dropped when the thread switches; the new thread stays at the
    /// bottom, following.
    @Test func pendingRevealIsDroppedOnThreadSwitch() async {
        let harness = ControllerTests.Harness(messages: Self.messages(largeReplyBytes: 400_000), size: NSSize(width: 800, height: 500))
        defer { harness.close() }
        await harness.settle()
        let controller = harness.controller
        let bigRow = try! #require(controller.rows.first { if case .markdown(let text, _) = $0.content { text.utf8.count > 100_000 } else { false } })
        controller.purge(.parse)
        controller.purge(.layouts)
        controller.reveal(FindMatch(rowID: bigRow.id, block: 0, range: 0..<4))
        #expect(!controller.isSettled, "the reveal waits for its parse")
        let other = StaticTranscriptSource(messages: ControllerTests.longTranscript(turns: 30))
        controller.bind(other)
        await harness.settle()
        #expect(controller.isSettled)
        #expect(controller.following, "the late reveal did not scroll the new thread")
        #expect(abs(controller.distanceFromBottom) < 1)
        #expect(controller.metrics.findSyncLayouts == 0)
    }
}
