import AppKit
import BelloCore
import Darwin
import Foundation
import Testing

@testable import TranscriptKit

/// Regression guards for M2-B (docs/features/transcript.md, "Memory and frame budget"): every transcript cache stays
/// within its budget, views are reused, find indexes off the main actor, and Use Selection for Find follows focus.
@Suite struct CacheBudgetTests {
    static func markdownRow(_ index: Int, version: Int = 1, bytes: Int = 400) -> TranscriptRow {
        let text = "Paragraph \(index) " + String(repeating: "word ", count: bytes / 5) + "\n\n```swift\nlet x = \(index)\n```"
        return TranscriptRow(
            id: RowID("p:\(index)"), messageID: MessageID("m\(index)"), turnID: nil, role: .assistant,
            content: .markdown(text: text, isStreaming: false), version: version, created: Timestamp(milliseconds: 0))
    }

    @Test func parseCacheHonoursCountAndCostBudgets() {
        let byCount = RenderBlockCache(countLimit: 10, costLimit: 1 << 30)
        for index in 0..<100 { _ = byCount.blocks(for: Self.markdownRow(index)) }
        #expect(byCount.statistics.entries <= 10)

        let byCost = RenderBlockCache(countLimit: 10_000, costLimit: 8_000)
        for index in 0..<100 { _ = byCost.blocks(for: Self.markdownRow(index)) }
        let stats = byCost.statistics
        #expect(stats.cost <= stats.costLimit)
        #expect(stats.entries > 0)
    }

    @Test func bulkReadsDoNotFillTheParseCache() {
        let cache = RenderBlockCache()
        let row = Self.markdownRow(1)
        #expect(cache.cachedBlocks(for: row) == nil)
        #expect(cache.statistics.entries == 0)
        _ = cache.blocks(for: row)
        #expect(cache.cachedBlocks(for: row) != nil)
        #expect(cache.cachedBlocks(for: Self.markdownRow(1, version: 2)) == nil, "a new version is a miss")
    }

    @Test func highlightCacheHonoursItsBudget() {
        let highlighter = TokenizerHighlighter(costLimit: 2_000)
        for index in 0..<200 {
            _ = highlighter.tokens(for: "func f\(index)(_ value: Int) -> Int { return value * \(index) } // \(index)", language: "swift")
        }
        #expect(highlighter.statistics.cost <= 2_000)
        highlighter.removeAll()
        #expect(highlighter.statistics.entries == 0)
    }

    @Test func findIndexKeepsOneStringPerBlock() {
        let entry = FindIndexEntry(rowID: RowID("a"), version: 1, blocks: ["Café STREAM", "ß is longer folded"])
        #expect(entry.texts.count == 2)
        #expect(entry.folded == [true, entry.texts[1] == FindSearch.fold("ß is longer folded")])
        #expect(entry.utf16Count == entry.texts.reduce(0) { $0 + $1.utf16.count })
        let matches = FindSearch.matches([entry], query: "cafe")
        #expect(matches == [FindMatch(rowID: RowID("a"), block: 0, range: 0..<4)])
    }
}

/// Main-thread CPU time of the calling thread, in milliseconds.
func threadCPUMilliseconds() -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let port = mach_thread_self()
    defer { mach_port_deallocate(mach_task_self_, port) }
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
    }
    guard result == KERN_SUCCESS else { return 0 }
    let user = Double(info.user_time.seconds) * 1000 + Double(info.user_time.microseconds) / 1000
    let system = Double(info.system_time.seconds) * 1000 + Double(info.system_time.microseconds) / 1000
    return user + system
}

/// Headless stress: the production controller in an offscreen window, traversed end to end.
@Suite(.serialized) @MainActor struct TranscriptStressTests {
    typealias Harness = ControllerTests.Harness

    /// Scrolls from top to bottom in viewport-sized steps, letting AppKit tile rows and layouts arrive.
    func traverse(_ harness: Harness, step: CGFloat = 450, check: () -> Void) async {
        let controller = harness.controller
        controller.noteUserScroll(deltaY: 1)
        controller.scrollTo(y: 0)
        var guardSteps = 0
        while controller.distanceFromBottom > 1, guardSteps < 5_000 {
            controller.userScroll(by: step)
            harness.window.contentView?.layoutSubtreeIfNeeded()
            controller.tableView.layoutSubtreeIfNeeded()
            if guardSteps % 8 == 0 { await controller.settle(timeout: .milliseconds(500)) }
            check()
            guardSteps += 1
        }
        await controller.settle()
    }

    @Test func traversalKeepsEveryCacheWithinBudget() async {
        let harness = Harness(messages: ControllerTests.longTranscript(turns: 500), size: NSSize(width: 800, height: 600))
        defer { harness.close() }
        let controller = harness.controller
        controller.layoutCacheLimit = 40
        controller.layoutCacheCostLimit = 1_500
        controller.imageByteLimit = 1 << 20
        await harness.settle()
        #expect(controller.rows.count > 1_400)
        let rowViewsBefore = TranscriptRowView.liveCount.load(ordering: .relaxed)
        var worstOverCount = 0
        var worstGraveyard = 0
        await traverse(harness) {
            // Only layouts of rows AppKit displays may exceed the count bound (they are never evicted).
            let displayed = controller.availableCells().count
            worstOverCount = max(worstOverCount, controller.layouts.count - controller.layoutCacheLimit - displayed)
            worstGraveyard = max(worstGraveyard, controller.graveyard.count)
        }
        let report = controller.cacheReport()
        #expect(worstOverCount <= 0, "layout count exceeded its bound by \(worstOverCount)")
        #expect(worstGraveyard <= TranscriptController.graveyardLimit + 8)
        let displayedCost = controller.availableCells().compactMap { controller.layouts[controller.rows[$0.index].id]?.cost }.reduce(0, +)
        #expect(report.layoutCost <= controller.layoutCacheCostLimit + displayedCost)
        #expect(report.parseCacheCost <= report.parseCacheCostLimit)
        #expect(report.imageBytes <= controller.imageByteLimit)
        // Row views are reused: NSTableView's purgatory once kept one per row ever shown.
        let rowViews = TranscriptRowView.liveCount.load(ordering: .relaxed)
        #expect(rowViews - rowViewsBefore < 120, "row views grew by \(rowViews - rowViewsBefore) over \(controller.rows.count) rows")
        #expect(report.liveCellViews < 120)
        #expect(controller.metrics.asyncLayouts + controller.metrics.syncLayouts > 200, "the traversal laid rows out (not vacuous)")
    }

    @Test func memoryPressureDropsEverythingButWhatIsOnScreen() async {
        let harness = Harness(messages: ControllerTests.longTranscript(turns: 120))
        defer { harness.close() }
        let controller = harness.controller
        await harness.settle()
        await traverse(harness, step: 900) {}
        controller.showFind()
        await controller.updateFindIndex()
        #expect(!controller.findIndex.isEmpty)
        #expect(controller.layouts.count > controller.availableCells().count)
        controller.handleMemoryPressure(critical: true)
        let displayed = Set(controller.availableCells().map { controller.rows[$0.index].id })
        #expect(Set(controller.layouts.keys).isSubset(of: displayed))
        #expect(controller.blockCache.statistics.entries == 0)
        #expect(controller.findIndex.isEmpty)
        #expect(controller.graveyard.isEmpty)
    }

    @Test func imageCacheEvictsLeastRecentlyDrawnWithinBudget() async {
        let harness = Harness(messages: ControllerTests.longTranscript(turns: 10))
        defer { harness.close() }
        let controller = harness.controller
        await harness.settle()
        controller.imageByteLimit = 3 << 20
        func image() -> LoadedImage {
            let context = CGContext(
                data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return LoadedImage(image: context.makeImage()!, pixelSize: CGSize(width: 512, height: 512))
        }
        for index in 0..<8 {
            controller.imageArrived("img-\(index)", image())
            if index >= 1 { _ = controller.image("img-0") }  // img-0 keeps being drawn
        }
        #expect(controller.imageBytes <= controller.imageByteLimit)
        #expect(controller.isImageLoaded("img-0"), "the most recently drawn image survives")
        #expect(!controller.isImageLoaded("img-1"))
        #expect(controller.isImageLoaded("img-7"))
    }

    /// The first query of a long thread indexes it off the main actor: the main thread only merges entries.
    @Test func firstFindQueryCostsLittleMainThreadTime() async {
        let harness = Harness(messages: ControllerTests.longTranscript(turns: 1_500))
        defer { harness.close() }
        let controller = harness.controller
        await harness.settle()
        let deadline = ContinuousClock.now + .seconds(60)
        while !controller.measureAllComplete, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        await controller.settle()
        #expect(controller.findIndex.isEmpty)
        let cpu = threadCPUMilliseconds()
        controller.setFindQuery("Answer 1234.", debounce: false)
        while controller.findMatches.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        let mainMs = threadCPUMilliseconds() - cpu
        #expect(!controller.findMatches.isEmpty)
        #expect(controller.findIndex.count >= controller.rows.count - 1)
        #expect(mainMs < 50, "first query used \(mainMs) ms of main-thread time")
    }

    /// ⌘E uses the selection of what has focus: the composer's, not the transcript's.
    @Test func useSelectionForFindFollowsTheFirstResponder() async {
        let harness = Harness(messages: TranscriptSamples.mixed(), size: NSSize(width: 900, height: 1200))
        defer { harness.close() }
        let controller = harness.controller
        await harness.settle()
        let reply = try! #require(controller.rows.firstIndex { if case .markdown = $0.content { true } else { false } })
        let id = controller.rows[reply].id
        controller.select(from: TranscriptPosition(rowID: id, block: 0, offset: 0), to: TranscriptPosition(rowID: id, block: 0, offset: 5))
        let transcriptText = controller.selectedText()
        #expect(!transcriptText.isEmpty)

        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        composer.string = "alpha needle omega"
        harness.window.contentView?.addSubview(composer)
        #expect(harness.window.makeFirstResponder(composer))
        composer.setSelectedRange(NSRange(location: 6, length: 6))
        controller.useSelectionForFind()
        #expect(controller.findBarField.stringValue == "needle")

        // An empty composer selection does nothing (it does not fall back to the transcript's selection).
        composer.setSelectedRange(NSRange(location: 0, length: 0))
        controller.findBarField.stringValue = ""
        controller.useSelectionForFind()
        #expect(controller.findBarField.stringValue == "")

        // With the transcript focused, its own selection is used.
        #expect(harness.window.makeFirstResponder(controller.tableView))
        controller.useSelectionForFind()
        #expect(controller.findBarField.stringValue == transcriptText.trimmingCharacters(in: .whitespacesAndNewlines))
        controller.closeFind()
    }
}
