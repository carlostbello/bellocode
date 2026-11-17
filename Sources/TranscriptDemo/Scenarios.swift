import AppKit
import BelloCore
import Engine
import MockOpenCode
import QuartzCore
import Synchronization
import TranscriptKit

extension ScenarioRunner {
    // MARK: S1 cold open

    struct S1Report: Codable {
        var header: RunHeader
        var windowOpenToFirstContentFrameMs: Double
        var windowRows: Int
        var loadAllHistoryMs: Double
        var fullOpenToFirstContentFrameMs: Double
        var fullOpenPassMs: Double
        var fullRows: Int
        var exactRowsAtOpen: Int
        var measureAllMs: Double
        var measureAllRows: Int
        var memoryAtOpen: Memory
        var memorySettled: Memory
        var documentHeight: Double
        var processLaunchToFirstFrameS: Double
    }

    /// Time from bind to the first display frame with content drawn.
    func timeToFirstContentFrame() async -> Double {
        guard let controller else { return -1 }
        let start = CACurrentMediaTime()
        var result = -1.0
        await perFrame { _, elapsed in
            let ready = !controller.rows.isEmpty && controller.tableView.rows(in: controller.tableView.visibleRect).length > 1
            if ready { result = (CACurrentMediaTime() - start) * 1000 }
            return !ready && elapsed < 10
        }
        return result
    }

    func runS1() async {
        let launch = ProcessStats.secondsSinceLaunch()
        // The thread's newest window (what a user opening it sees), from the Engine.
        mount()
        let windowFrame = await timeToFirstContentFrame()
        let windowRows = controller?.rows.count ?? 0
        await controller?.settle()
        // The whole history, paged in through the Engine, then a fresh transcript over 10,000 messages (the spike's S1).
        let loadAll = await loadAll()
        unmount()
        await sleep(0.5)
        mount()
        let fullFrame = await timeToFirstContentFrame()
        guard let controller else { return }
        let exact = controller.exactRowCount
        let atOpen = Memory.now()
        await waitForMeasureAll()
        await sleep(2)
        Snapshots.capture(window.contentView!, name: "S1-open-bottom")
        Report.write(
            S1Report(
                header: header("S1"), windowOpenToFirstContentFrameMs: round2(windowFrame), windowRows: windowRows,
                loadAllHistoryMs: round2(loadAll), fullOpenToFirstContentFrameMs: round2(fullFrame),
                fullOpenPassMs: round2(controller.metrics.openMilliseconds), fullRows: controller.rows.count, exactRowsAtOpen: exact,
                measureAllMs: round2(controller.metrics.measureAllMilliseconds), measureAllRows: controller.metrics.measureAllRows,
                memoryAtOpen: atOpen, memorySettled: Memory.now(), documentHeight: Double(controller.rowRect(controller.rows.count - 1).maxY),
                processLaunchToFirstFrameS: round2(launch)),
            name: "S1")
    }

    // MARK: S2 continuous scroll

    struct S2Report: Codable {
        var header: RunHeader
        var documentHeight: Double
        var down: FrameStats
        var up: FrameStats
        var whileHugeRowVisible: FrameStats
        var realisticSpeed60s: FrameStats
        var meanVelocityPtPerS: Double
        var realisticMeanVelocityPtPerS: Double
        var traversalSpeedMultiplier: Double
        var watchdog: Watchdog.Report
        var metrics: TranscriptController.Metrics
        var hugeRowHeight: Double
        var tableGeometryErrorPt: Double
        var memoryAfter: Memory
    }

    func runS2() async {
        await mountFull()
        guard let controller else { return }
        controller.noteUserScroll(deltaY: 1)
        controller.scrollTo(y: 0)
        await sleep(1)
        let hugeIndex = controller.rows.indices.max { controller.rowRect($0).height < controller.rowRect($1).height } ?? 0
        recorder.tagProvider = { [weak controller] in
            guard let controller else { return false }
            let range = controller.tableView.rows(in: controller.tableView.visibleRect)
            return (range.location..<(range.location + range.length)).contains(hugeIndex + 1)
        }
        let documentHeight = Double(controller.rowRect(controller.rows.count - 1).maxY)
        var flick = Flick()
        var travelled = 0.0
        var duration = 0.0
        watchdog.start()
        recorder.start()
        await perFrame { [self] dt, _ in
            let d = flick.step(dt, rng: &rng, scale: scrollSpeed)
            controller.userScroll(by: d)
            travelled += d
            duration += dt
            return controller.distanceFromBottom > 1
        }
        let downIntervals = recorder.stop()
        let downTags = recorder.tags
        log("S2 down done (\(downIntervals.count) frames)")
        recorder.start()
        flick = Flick()
        await perFrame { [self] dt, _ in
            let d = flick.step(dt, rng: &rng, scale: scrollSpeed)
            controller.userScroll(by: -d)
            travelled += d
            duration += dt
            return controller.scrollView.contentView.bounds.minY > 0.5
        }
        let upIntervals = recorder.stop()
        let upTags = recorder.tags
        recorder.tagProvider = nil
        log("S2 up done (\(upIntervals.count) frames)")
        let huge = zip(downIntervals + upIntervals, downTags + upTags).filter(\.1).map(\.0)

        controller.scrollTo(y: CGFloat(documentHeight / 4))
        await sleep(0.5)
        flick = Flick()
        var realTravel = 0.0
        var realDuration = 0.0
        var goingDown = true
        recorder.start()
        await perFrame { [self] dt, elapsed in
            let d = flick.step(dt, rng: &rng, scale: 1)
            if controller.distanceFromBottom < 2_000 { goingDown = false }
            if controller.scrollView.contentView.bounds.minY < 2_000 { goingDown = true }
            controller.userScroll(by: goingDown ? d : -d)
            realTravel += d
            realDuration += dt
            return elapsed < 60
        }
        let realistic = recorder.stop()
        Report.write(
            S2Report(
                header: header("S2"), documentHeight: documentHeight, down: FrameStats(intervals: downIntervals, nominal: nominal),
                up: FrameStats(intervals: upIntervals, nominal: nominal), whileHugeRowVisible: FrameStats(intervals: huge, nominal: nominal),
                realisticSpeed60s: FrameStats(intervals: realistic, nominal: nominal),
                meanVelocityPtPerS: round2(travelled / max(duration, 0.001)),
                realisticMeanVelocityPtPerS: round2(realTravel / max(realDuration, 0.001)), traversalSpeedMultiplier: scrollSpeed,
                watchdog: watchdog.stop(), metrics: controller.metrics, hugeRowHeight: Double(controller.rowRect(hugeIndex).height),
                tableGeometryErrorPt: geometryError(), memoryAfter: Memory.now()),
            name: "S2")
    }

    // MARK: Streaming (S3, S4)

    /// A long Markdown reply (prose, lists, tables, fences) streamed by the mock at `rate` deltas per second.
    func streamingScript(seconds: Double, rate: Double, chunk: Int) -> (TurnScript, String) {
        var text = ""
        var section = 0
        let target = Int(seconds * rate) * chunk
        while text.utf8.count < target {
            section += 1
            text += """
                ## Section \(section)

                The transcript keeps its anchor while this section streams; selection and copy stay stable. Paragraph \(section) adds enough words to wrap across several lines in a 760 point column, which is typical of agent output.

                - First point for section \(section) with `inline code`
                - Second point with a [link](https://example.com/\(section))
                  - Nested detail \(section)

                | Metric | Value \(section) | Notes |
                | --- | ---: | --- |
                | frames | \(section * 7) | streamed |
                | deltas | \(section * 11) | coalesced |

                ```swift
                func section\(section)(_ value: Int) -> Int {
                    let doubled = value * 2 // comment \(section)
                    return doubled + \(section)
                }
                ```


                """
        }
        let script = TurnScript(name: "bench-stream-\(Int(seconds))") {
            TurnStep.text(text, chunkSize: chunk, rate: rate)
        }
        return (script, text)
    }

    struct StreamStats: Codable {
        var frames: FrameStats
        /// Delta emitted by the mock → its text shown (complete lines and words: the line buffer holds partial ones).
        var deltaToVisible: LatencyStats
        /// Delta emitted → its text received, parsed and laid out by the transcript (before line buffering).
        var deltaToApplied: LatencyStats
        var deltasProduced: Int
        var deltasShown: Int
        var finalTextMatches: Bool
        var cpuPercentOfOneCore: Double
        var maxDistanceFromBottomWhileFollowing: Double
        var streamedBytes: Int
        var maxTailApplyMs: Double
        var tailJobs: Int
    }

    struct LatencyStats: Codable {
        var samples = 0
        var p50Ms = 0.0
        var p95Ms = 0.0
        var maxMs = 0.0
    }

    /// Deltas (from the mock's observer) and their visibility (tail commits), for delta→visible latency.
    final class DeltaClock: Sendable {
        private let state = Mutex<(times: [(length: Int, time: Double)], messageID: String?)>(([], nil))
        func record(_ id: String, _ length: Int, _ time: Double) {
            state.withLock { state in
                if state.messageID == nil { state.messageID = id }
                guard state.messageID == id else { return }
                state.times.append((length, time))
            }
        }
        var count: Int { state.withLock { $0.times.count } }
        var messageID: String? { state.withLock { $0.messageID } }
        /// Removes and returns the times of deltas now visible (cumulative length ≤ shown).
        func drain(upTo shown: Int) -> [Double] {
            state.withLock { state in
                let visible = state.times.prefix { $0.length <= shown }
                state.times.removeFirst(visible.count)
                return visible.map(\.time)
            }
        }
    }

    /// Streams a scripted reply through mock → Engine → ThreadModel → transcript; `during` runs once per frame.
    func stream(seconds: Double, during: ((Double, Double) -> Void)? = nil) async -> StreamStats {
        guard let controller, let server, let thread, let sessionID else { fatalError("no transcript") }
        let rate = 100.0
        let (script, text) = streamingScript(seconds: seconds, rate: rate, chunk: 9)
        let clock = DeltaClock()
        let appliedClock = DeltaClock()
        await server.setDeltaObserver { id, length, time in
            clock.record(id, length, time)
            appliedClock.record(id, length, time)
        }
        await server.enqueueScript(script, for: sessionID.rawValue)
        var latencies: [Double] = []
        var applied: [Double] = []
        controller.onTailCommit = { id in
            guard let messageID = clock.messageID, id.rawValue.contains(messageID), let shown = controller.displayedTailLength(id) else { return }
            let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
            // Drawn at the next display refresh.
            latencies += clock.drain(upTo: shown).map { (now - $0) * 1000 }
            applied += appliedClock.drain(upTo: controller.appliedTailLength(id) ?? 0).map { (now - $0) * 1000 }
        }
        let cpuStart = ProcessStats.cpuSeconds()
        let wallStart = CACurrentMediaTime()
        let sent = await thread.send("Stream a long benchmark reply")
        if sent == nil { log("FAIL send: \(thread.lastError?.userMessage ?? "unknown")") }
        // Wait for the turn to start (the mock answers the prompt, then plays the script).
        let waitStart = CACurrentMediaTime()
        while !thread.isRunning, clock.count == 0, CACurrentMediaTime() - waitStart < 10 { await sleep(0.01) }
        var maxDistance = 0.0
        recorder.start()
        var sawRunning = false
        await perFrame { dt, elapsed in
            during?(dt, elapsed)
            if controller.following { maxDistance = max(maxDistance, Double(controller.distanceFromBottom)) }
            if thread.isRunning { sawRunning = true }
            let finished = sawRunning && !thread.isRunning && controller.streamingRowIDs.isEmpty
            return !finished && elapsed < seconds * 3 + 30
        }
        let intervals = recorder.stop()
        await controller.settle()
        controller.onTailCommit = nil
        await server.setDeltaObserver(nil)
        let cpu = (ProcessStats.cpuSeconds() - cpuStart) / max(0.001, CACurrentMediaTime() - wallStart) * 100
        let shownText = controller.rows.compactMap { row -> String? in
            if case .markdown(let value, _) = row.content, value.hasPrefix("## Section 1") { return value }
            return nil
        }.last
        let sorted = latencies.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        let appliedSorted = applied.sorted()
        func apct(_ p: Double) -> Double { appliedSorted.isEmpty ? 0 : appliedSorted[min(appliedSorted.count - 1, Int(Double(appliedSorted.count - 1) * p))] }
        let produced = Int(ceil(Double(text.utf8.count) / 9))
        return StreamStats(
            frames: FrameStats(intervals: intervals, nominal: nominal),
            deltaToVisible: LatencyStats(samples: sorted.count, p50Ms: round2(pct(0.5)), p95Ms: round2(pct(0.95)), maxMs: round2(sorted.last ?? 0)),
            deltaToApplied: LatencyStats(
                samples: appliedSorted.count, p50Ms: round2(apct(0.5)), p95Ms: round2(apct(0.95)), maxMs: round2(appliedSorted.last ?? 0)),
            deltasProduced: produced, deltasShown: sorted.count, finalTextMatches: shownText == text,
            cpuPercentOfOneCore: round2(cpu), maxDistanceFromBottomWhileFollowing: round2(maxDistance), streamedBytes: text.utf8.count,
            maxTailApplyMs: round2(controller.metrics.maxTailApplyMilliseconds), tailJobs: controller.metrics.tailJobs)
    }

    struct S3Report: Codable {
        var header: RunHeader
        var stream: StreamStats
        var followedToTheEnd: Bool
    }

    func runS3() async {
        await mountFull()
        guard let controller else { return }
        controller.jumpToLatest()
        await sleep(0.5)
        let stats = await stream(seconds: streamSeconds)
        Snapshots.capture(window.contentView!, name: "S3-end")
        Report.write(S3Report(header: header("S3"), stream: stats, followedToTheEnd: controller.following && controller.distanceFromBottom < 1), name: "S3")
    }

    struct S4Report: Codable {
        var header: RunHeader
        var stream: StreamStats
        var readingPauses: Int
        var maxDriftWhileReadingPt: Double
        var releasedOnScrollUp: Bool
        var unexpectedFollow: Bool
        var pillShown: Bool
        var rejoinedByJumpToLatest: Bool
        var distanceAfterJump: Double
    }

    func runS4() async {
        await mountFull()
        guard let controller else { return }
        controller.jumpToLatest()
        await sleep(0.3)
        controller.userScroll(by: -3 * controller.scrollView.contentView.bounds.height)
        await sleep(0.4)
        let released = !controller.following
        var maxDrift = 0.0
        var pauses = 0
        var anchor: (RowID, Double)?
        var phaseStart = 0.0
        var reading = true
        var unexpected = false
        var pill = false
        var flick = Flick()
        let stats = await stream(seconds: streamSeconds) { [self] dt, elapsed in
            if controller.following { unexpected = true }
            if controller.isJumpPillVisible { pill = true }
            if reading {
                if anchor == nil { anchor = topAnchor() }
                if elapsed - phaseStart > 1.5 {
                    maxDrift = max(maxDrift, drift(from: anchor))
                    pauses += 1
                    reading = false
                    phaseStart = elapsed
                    anchor = nil
                }
            } else {
                // Scroll up and down a little around three viewports from the bottom.
                let d = flick.step(dt, rng: &rng, scale: 0.15)
                let target = controller.distanceFromBottom > 4 * controller.scrollView.contentView.bounds.height ? d : -d
                controller.userScroll(by: target)
                if controller.following { controller.userScroll(by: -200) }
                if elapsed - phaseStart > 1.5 {
                    reading = true
                    phaseStart = elapsed
                }
            }
        }
        controller.jumpToLatest()
        await controller.settle()
        Report.write(
            S4Report(
                header: header("S4"), stream: stats, readingPauses: pauses, maxDriftWhileReadingPt: round2(maxDrift),
                releasedOnScrollUp: released, unexpectedFollow: unexpected, pillShown: pill, rejoinedByJumpToLatest: controller.following,
                distanceAfterJump: round2(Double(controller.distanceFromBottom))),
            name: "S4")
    }

    // MARK: S5 anchors

    struct AnchorCase: Codable {
        var name: String
        var heightChangePt: Double
        var driftPt: Double
        var note: String
    }

    struct S5Report: Codable {
        var header: RunHeader
        var cases: [AnchorCase]
        var expandDuringScrollErrorPt: Double
    }

    func runS5() async {
        images.holdAll(true)
        await mountFull()
        guard let controller else { return }
        var cases: [AnchorCase] = []
        controller.noteUserScroll(deltaY: 1)
        let height = controller.rowRect(controller.rows.count - 1).maxY
        controller.scrollTo(y: height / 2)
        await controller.settle()

        // 1. Expand a work group above the viewport.
        if let top = topAnchor(), let topIndex = controller.rows.firstIndex(where: { $0.id == top.0 }),
            let group = controller.rows[..<max(0, topIndex - 2)].lastIndex(where: { if case .work(let g) = $0.content { g.isCollapsible } else { false } })
        {
            let before = controller.rowRect(group).height
            let anchor = topAnchor()
            controller.toggle(row: controller.rows[group].id, key: .group)
            await controller.settle()
            cases.append(AnchorCase(name: "expand tool group above", heightChangePt: Double(controller.rowRect(group).height - before), driftPt: drift(from: anchor), note: "row \(topIndex - group) rows above"))
        }

        // 2. A late image above the viewport: show its row (requested, held), scroll below it, release it.
        if let imageIndex = controller.rows.indices.first(where: { index in
            index > controller.rows.count / 3 && { if case .markdown(let text, _) = controller.rows[index].content { text.contains("![") } else { false } }()
        }) {
            controller.scrollTo(y: controller.rowRect(imageIndex).minY - 100)
            await controller.settle()
            await sleep(0.2)
            controller.scrollTo(y: controller.rowRect(imageIndex).maxY + 1_200)
            await controller.settle()
            let before = controller.rowRect(imageIndex).height
            let anchor = topAnchor()
            for source in images.pending { images.release(source) }
            await sleep(0.3)
            await controller.settle()
            cases.append(AnchorCase(name: "late image above", heightChangePt: Double(controller.rowRect(imageIndex).height - before), driftPt: drift(from: anchor), note: "held until below it"))
        }
        images.holdAll(false)

        // 3. Expanding a card above while the user scrolls at 900 pt/s: the content moves exactly by the user's travel.
        var error = 0.0
        controller.scrollTo(y: height / 3)
        await controller.settle()
        if let top = topAnchor(), let topIndex = controller.rows.firstIndex(where: { $0.id == top.0 }),
            let group = controller.rows[..<max(0, topIndex - 2)].lastIndex(where: { if case .work(let g) = $0.content { g.isCollapsible } else { false } })
        {
            let id = controller.rows[topIndex + 4].id
            var startOffset: Double?
            var travel = 0.0
            var toggled = false
            await perFrame { dt, elapsed in
                let index = controller.rows.firstIndex { $0.id == id }!
                let offset = Double(controller.rowRect(index).minY - controller.scrollView.contentView.bounds.minY)
                if startOffset == nil { startOffset = offset }
                if elapsed > 0.5, !toggled {
                    controller.toggle(row: controller.rows[group].id, key: .group)
                    toggled = true
                }
                let d = 900 * dt
                controller.userScroll(by: d)
                travel += d
                return elapsed < 1.2
            }
            await controller.settle()
            let index = controller.rows.firstIndex { $0.id == id }!
            let offset = Double(controller.rowRect(index).minY - controller.scrollView.contentView.bounds.minY)
            error = abs((startOffset ?? 0) - travel - offset)
        }

        // 4. Prepend older pages: a fresh window of the thread, read near its top, while history pages in.
        unmount()
        thread?.close()
        _ = await openThread()
        mount()
        await controller.settle()
        if let fresh = self.controller {
            fresh.noteUserScroll(deltaY: 1)
            fresh.scrollTo(y: 2_000)
            await fresh.settle()
            let rowsBefore = fresh.rows.count
            let anchor = topAnchor()
            await thread?.loadOlder()
            await fresh.settle()
            cases.append(AnchorCase(name: "prepend older page", heightChangePt: Double(fresh.rows.count - rowsBefore), driftPt: drift(from: anchor), note: "rows added (not points)"))
        }
        Report.write(S5Report(header: header("S5"), cases: cases, expandDuringScrollErrorPt: round2(error)), name: "S5")
    }

    // MARK: S6 resize

    struct ResizeCase: Codable {
        var name: String
        var frames: FrameStats
        var anchorDriftPt: Double
        var roundTripPixelsDiffer: Double
    }

    struct S6Report: Codable {
        var header: RunHeader
        var cases: [ResizeCase]
    }

    func resize(from: CGFloat, to: CGFloat, name: String) async -> ResizeCase {
        guard let controller else { fatalError() }
        window.setFrame(NSRect(x: 80, y: 80, width: from, height: 900), display: true)
        await controller.settle()
        await sleep(0.6)
        await controller.settle()
        let before = Snapshots.bitmap(window.contentView!)
        let anchor = topAnchor()
        recorder.start()
        await perFrame { [self] _, elapsed in
            let t = min(1, elapsed / 2)
            let width = t < 0.5 ? from + (to - from) * t * 2 : to - (to - from) * (t - 0.5) * 2
            window.setFrame(NSRect(x: 80, y: 80, width: width.rounded(), height: 900), display: true)
            return elapsed < 2
        }
        let intervals = recorder.stop()
        window.setFrame(NSRect(x: 80, y: 80, width: from, height: 900), display: true)
        await sleep(0.6)
        await controller.settle()
        let after = Snapshots.bitmap(window.contentView!)
        let differ = (before != nil && after != nil) ? Snapshots.difference(before!, after!) : 1
        return ResizeCase(name: name, frames: FrameStats(intervals: intervals, nominal: nominal), anchorDriftPt: round2(drift(from: anchor)), roundTripPixelsDiffer: round2(differ * 100))
    }

    func runS6() async {
        await mountFull()
        guard let controller else { return }
        controller.noteUserScroll(deltaY: 1)
        controller.scrollTo(y: controller.rowRect(controller.rows.count - 1).maxY / 2)
        await controller.settle()
        var cases = [await resize(from: 900, to: 1400, name: "900→1400→900 (column stays 760 pt)")]
        cases.append(await resize(from: 560, to: 1000, name: "560→1000→560 (column re-wraps 512↔760 pt)"))
        window.setFrame(NSRect(x: 80, y: 80, width: 900, height: 900), display: true)
        Report.write(S6Report(header: header("S6"), cases: cases), name: "S6")
    }

    // MARK: S7 selection, copy, find

    struct S7Report: Codable {
        var header: RunHeader
        var autoscrollFrames: FrameStats
        var selectedRows: Int
        var copyMs: Double
        var copiedCharacters: Int
        var copySurvivesScrolling: Bool
        var findProseMs: Double
        var findProseRowsAway: Int
        var findCollapsedMs: Double
        var findCollapsedRowsAway: Int
        var collapsedRevealedAndExpanded: Bool
    }

    func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func runS7() async {
        await mountFull()
        guard let controller else { return }
        controller.noteUserScroll(deltaY: 1)
        controller.scrollTo(y: controller.rowRect(controller.rows.count - 1).maxY * 0.3)
        await controller.settle()
        // Drag from the top of the viewport to below it: autoscroll until at least 25 rows are selected.
        let table = controller.tableView
        let visible = controller.scrollView.contentView.bounds
        let start = table.convert(NSPoint(x: table.bounds.midX - 300, y: visible.minY + 40), to: nil)
        table.mouseDown(with: mouse(.leftMouseDown, start))
        let below = controller.scrollView.convert(NSPoint(x: controller.scrollView.bounds.midX, y: controller.scrollView.bounds.maxY + 60), to: nil)
        table.mouseDragged(with: mouse(.leftMouseDragged, below))
        recorder.start()
        await perFrame { _, elapsed in (controller.selectionRowSpan ?? 0) < 60 && elapsed < 15 }
        let autoscroll = recorder.stop()
        table.mouseUp(with: mouse(.leftMouseUp, below))
        let rows = controller.selectionRowSpan ?? 0
        let copyStart = CACurrentMediaTime()
        controller.copySelection()
        let copyMs = (CACurrentMediaTime() - copyStart) * 1000
        let copied = controller.pasteboard.string(forType: .string) ?? ""
        controller.userScroll(by: 30_000)
        await controller.settle()
        controller.userScroll(by: -60_000)
        await controller.settle()
        let again = controller.selectedText()
        controller.clearSelection()

        // Find: prose ~3,000 rows away; then text inside a collapsed tool output ~2,500 rows away.
        func find(_ query: String) async -> Double {
            let start = CACurrentMediaTime()
            controller.showFind()
            controller.setFindQuery(query, debounce: false)
            while controller.findMatches.isEmpty, CACurrentMediaTime() - start < 10 { await sleep(0.005) }
            await controller.settle()
            return (CACurrentMediaTime() - start) * 1000
        }
        let here = controller.tableView.row(at: NSPoint(x: 1, y: controller.scrollView.contentView.bounds.minY)) - 1
        var proseMs = -1.0
        var proseAway = 0
        if let target = (min(controller.rows.count - 1, here + 3_000)...).lazy.first(where: { if case .markdown = controller.rows[$0].content { true } else { false } }),
            case .markdown(let text, _) = controller.rows[target].content
        {
            let words = text.split(separator: " ").prefix(6).joined(separator: " ")
            proseMs = await find(words)
            proseAway = abs(target - here)
            controller.closeFind()
        }
        var collapsedMs = -1.0
        var collapsedAway = 0
        var revealed = false
        let here2 = controller.tableView.row(at: NSPoint(x: 1, y: controller.scrollView.contentView.bounds.minY)) - 1
        if let target = controller.rows.indices.first(where: { index in
            abs(index - here2) > 2_400
                && { if case .work(let group) = controller.rows[index].content { group.isCollapsible && group.items.contains { $0.output.count > 40 } } else { false } }()
        }), case .work(let group) = controller.rows[target].content,
            let item = group.items.first(where: { $0.output.count > 40 }),
            let line = item.output.split(separator: "\n").first(where: { $0.count > 20 })
        {
            collapsedMs = await find(String(line.prefix(40)))
            collapsedAway = abs(target - here2)
            if let current = controller.findCurrent, controller.findMatches.indices.contains(current) {
                let match = controller.findMatches[current]
                revealed = controller.isExpanded(row: match.rowID, key: .group) && controller.visibleRectOfCurrentMatch() != nil
            }
        }
        Snapshots.capture(window.contentView!, name: "S7-find-collapsed")
        controller.closeFind()
        Report.write(
            S7Report(
                header: header("S7"), autoscrollFrames: FrameStats(intervals: autoscroll, nominal: nominal), selectedRows: rows,
                copyMs: round2(copyMs), copiedCharacters: copied.count, copySurvivesScrolling: again == copied, findProseMs: round2(proseMs),
                findProseRowsAway: proseAway, findCollapsedMs: round2(collapsedMs), findCollapsedRowsAway: collapsedAway,
                collapsedRevealedAndExpanded: revealed),
            name: "S7")
    }

    // MARK: S8 memory

    struct S8Report: Codable {
        var header: RunHeader
        var afterScenarios: Memory
        var cycles: [Memory]
        var afterClose: Memory
    }

    func runS8() async {
        let after = Memory.now()
        var cycles: [Memory] = []
        for cycle in 0..<20 {
            unmount()
            await sleep(0.2)
            mount()
            await controller?.settle()
            controller?.noteUserScroll(deltaY: 1)
            controller?.scrollTo(y: CGFloat(cycle) * 5_000)
            await controller?.settle()
            cycles.append(Memory.now())
        }
        unmount()
        await sleep(1)
        Report.write(S8Report(header: header("S8"), afterScenarios: after, cycles: cycles, afterClose: Memory.now()), name: "S8")
    }
}
