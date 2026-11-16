// G1-A scenarios S1 to S8 plus the pathological huge-block scroll and find. Each writes one JSON report.

import AppKit
import QuartzCore
import TranscriptKit

struct Environment: Encodable {
    var machine = "Apple M5 Max, 36 GB"
    var os = ProcessInfo.processInfo.operatingSystemVersionString
    var build = "swift build -c release"
    var displayRefreshHz = 0
    var displayLinkNominalMS = 0.0
    var windowPoints = ""
    var backingScale = 0.0
    var textKit2 = true
    var textKit1FallbackObserved = false
}

struct Workload: Encodable {
    var messages = 0
    var megabytes = 0.0
    var tables = 0
    var codeBlocks = 0
    var hugeCodeBlockBytes = 0
    var tools = 0
    var reasoning = 0
    var diffs = 0
    var images = 0
    var storageUTF16 = 0
    var generationMS = 0.0
}

@MainActor
final class Scenarios {
    let h: Harness
    let processStart: Double
    var velocity: Double { Double(argument("--velocity") ?? "") ?? 6_000 }
    var maxScrollSeconds: Double { Double(argument("--max-seconds") ?? "") ?? 1_200 }
    var streamSeconds: Double { Double(argument("--stream-seconds") ?? "") ?? 60 }

    init(harness: Harness, processStart: Double) {
        h = harness
        self.processStart = processStart
    }

    var c: SpikeTranscriptController { h.controller }

    func environment() -> Environment {
        var e = Environment()
        e.displayRefreshHz = h.screenRefreshHz
        e.displayLinkNominalMS = h.frames.lastDuration * 1_000
        if let w = h.window {
            e.windowPoints = "\(Int(w.frame.width))×\(Int(w.frame.height))"
            e.backingScale = Double(w.backingScaleFactor)
        }
        e.textKit2 = h.controller?.isUsingTextKit2 ?? true
        e.textKit1FallbackObserved = h.controller?.textKit1Fallback ?? false
        return e
    }

    func workload() -> Workload {
        let s = h.transcript.stats
        return Workload(messages: s.messages, megabytes: Double(s.totalUTF8Bytes) / 1_000_000, tables: s.tables,
                        codeBlocks: s.codeBlocks, hugeCodeBlockBytes: s.hugeCodeBlockBytes, tools: s.tools,
                        reasoning: s.reasoning, diffs: s.diffs, images: s.images,
                        storageUTF16: h.controller?.storage.length ?? 0, generationMS: h.generationMS)
    }

    func run(_ name: String) async {
        switch name {
        case "S1": Output.write("S1", await s1())
        case "S2": Output.write("S2", await s2())
        case "S3": Output.write("S3", await s3())
        case "S4": Output.write("S4", await s4())
        case "S5": Output.write("S5", await s5())
        case "S6": Output.write("S6", await s6())
        case "S7": Output.write("S7", await s7())
        case "S8": Output.write("S8", await s8())
        case "huge": Output.write("huge", await huge())
        case "find": Output.write("find", await find())
        case "bench": await bench()
        case "visual": Output.write("visual-jumps", await visualJump())
        default: await look()
        }
    }

    /// Opens a fresh window with the full transcript loaded and settled.
    func openLoaded(autoDeliverImages: Bool = true, width: CGFloat = 1_100) async {
        h.makeWindow(width: width, autoDeliverImages: autoDeliverImages)
        if arguments.contains("--no-images") { c.autoDeliverImages = false }
        if let screens = argument("--prefetch").flatMap(Double.init) { c.prefetchScreens = CGFloat(screens) }
        log("window up, loading")
        _ = await h.load(t0: CACurrentMediaTime())
        log("first content frame; marks \(c.loadMarks)")
        await c.waitUntilLoaded()
        log("history loaded; marks \(c.loadMarks)")
        if arguments.contains("--full-layout") {
            let t = CACurrentMediaTime()
            c.layoutManager.ensureLayout(for: c.contentStorage.documentRange)
            log("full layout \(Int((CACurrentMediaTime() - t) * 1_000)) ms, height \(c.textView.frame.height), memory \(Probe.memory())")
        }
        await h.sleep(1)
    }

    // MARK: storage micro-benchmark (no window)

    func bench() async {
        func ms(_ t: Double) -> String { String(format: "%.1f ms", (CACurrentMediaTime() - t) * 1_000) }
        var t = CACurrentMediaTime()
        let rich = await SpikeTranscriptController.renderIR(h.transcript.messages, expanded: [])
        log("render IR 10k: \(ms(t))")
        t = CACurrentMediaTime()
        let full = SpikeMaterializer().materialize(rich)
        log("materialize 10k: \(ms(t)) length \(full.length)")
        let stock = NSTextStorage()
        t = CACurrentMediaTime()
        stock.setAttributedString(full)
        log("stock setAttributedString: \(ms(t))")
        let hundred = SpikeMaterializer().materialize(Array(rich[100..<200]))
        t = CACurrentMediaTime()
        stock.insert(hundred, at: 0)
        log("stock insert 100 messages at 0: \(ms(t))")
        t = CACurrentMediaTime()
        let perMessage = await SpikeTranscriptController.materializeOffMain(rich) { _ in }
        log("materialize per message (parallel): \(ms(t))")
        let storage = SpikeChunkedStorage()
        t = CACurrentMediaTime()
        storage.insertChunks(perMessage, at: 0)
        log("chunked insert all: \(ms(t))")
        let page = Array(perMessage[100..<200])
        t = CACurrentMediaTime()
        storage.insertChunks(page, at: 0)
        log("chunked insert 100 messages at 0: \(ms(t))")
        t = CACurrentMediaTime()
        storage.replaceCharacters(in: NSRange(location: storage.chunkRange(5_000).location + 10, length: 20), with: hundred.attributedSubstring(from: NSRange(location: 0, length: 300)))
        log("chunked replace inside a message: \(ms(t))")
        t = CACurrentMediaTime()
        storage.replaceCharacters(in: NSRange(location: storage.chunkRange(6_000).location + 10, length: 20), with: hundred.attributedSubstring(from: NSRange(location: 0, length: 300)))
        log("chunked replace inside a message again: \(ms(t))")
        if arguments.contains("--loop") {
            for i in 0..<40 {
                storage.replaceCharacters(in: NSRange(location: storage.chunkRange(6_000 + i).location + 10, length: 20), with: hundred.attributedSubstring(from: NSRange(location: 0, length: 300)))
            }
        }
        t = CACurrentMediaTime()
        var runs = 0
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { _, _, _ in runs += 1 }
        log("chunked enumerate all attributes: \(ms(t)) runs \(runs)")
    }

    // MARK: look (visual check)

    func look() async {
        await openLoaded()
        Output.snapshot(h.window.contentView!, "look-bottom")
        c.reveal(messageAt: 5_001)
        await h.sleep(0.5)
        Output.snapshot(h.window.contentView!, "look-huge")
        c.reveal(messageAt: 1_201)
        await h.sleep(1.6)
        Output.snapshot(h.window.contentView!, "look-mid")
        log("textKit2 \(c.isUsingTextKit2) height \(c.textView.frame.height)")
    }

    // MARK: S1 cold open

    struct S1Report: Encodable {
        var environment: Environment
        var workload: Workload
        var processToWorkloadReadyMS = 0.0
        var tailInstalledMS = 0.0
        var firstContentFrameMS = 0.0
        var processLaunchToFirstContentFrameMS = 0.0
        var timeToInteractiveMS = 0.0
        var interactiveDefinition = "first content frame presented with the newest 150 messages selectable and scrolled to bottom; history then streams in"
        var historyLoadedMS = 0.0
        var maxPrependMainThreadMS = 0.0
        var stallsDuringHistoryLoad: StallStats?
        var framesDuringHistoryLoad: FrameStats?
        var openedAtBottom = false
        var stillAtBottomAfterHistory = false
        var memoryAfterOpen: Probe.Memory?
        var memoryAfterSettle: Probe.Memory?
        var documentHeight = 0.0
    }

    func s1() async -> S1Report {
        var r = S1Report(environment: environment(), workload: workload())
        r.processToWorkloadReadyMS = (CACurrentMediaTime() - processStart) * 1_000
        h.makeWindow()
        let t0 = CACurrentMediaTime()
        h.watchdog.start()
        let marks = await h.load(t0: t0)
        r.tailInstalledMS = marks.installed
        r.firstContentFrameMS = marks.firstFrame
        r.processLaunchToFirstContentFrameMS = (CACurrentMediaTime() - processStart) * 1_000
        r.timeToInteractiveMS = marks.firstFrame
        r.openedAtBottom = c.isAtBottom
        Output.snapshot(h.window.contentView!, "S1-first-frame")
        h.frames.start()
        await c.waitUntilLoaded()
        r.framesDuringHistoryLoad = h.frames.stop()
        r.stallsDuringHistoryLoad = h.watchdog.stop()
        r.historyLoadedMS = c.loadMarks["historyLoadedMS"] ?? 0
        r.maxPrependMainThreadMS = c.loadMarks["maxPrependMS"] ?? 0
        r.memoryAfterOpen = Probe.memory()
        await h.sleep(2)
        r.stillAtBottomAfterHistory = c.isAtBottom
        r.memoryAfterSettle = Probe.memory()
        r.documentHeight = c.textView.frame.height
        r.environment = environment()
        r.workload = workload()
        Output.snapshot(h.window.contentView!, "S1-settled")
        return r
    }

    // MARK: S2 continuous scroll

    struct S2Report: Encodable {
        var environment: Environment
        var velocityPTPerS = 0.0
        var jumpToTopMS = 0.0
        var down: JumpStats?
        var up: JumpStats?
        var framesDown: FrameStats?
        var framesUp: FrameStats?
        var stalls: StallStats?
        var memoryAfter: Probe.Memory?
        var stabiliserEnabled = true
        var stabiliserCorrections = 0
        var stabiliserMaxCorrectionPT = 0.0
    }

    func s2() async -> S2Report {
        await openLoaded()
        var r = S2Report(environment: environment())
        r.velocityPTPerS = velocity
        let t = CACurrentMediaTime()
        c.scrollToTop()
        r.jumpToTopMS = (CACurrentMediaTime() - t) * 1_000
        await h.sleep(1)
        Output.snapshot(h.window.contentView!, "S2-top")
        h.watchdog.start()
        h.frames.start()
        r.down = await h.driveScroll(velocity: velocity, maxSeconds: maxScrollSeconds) { $0.isAtBottom }
        r.framesDown = h.frames.stop()
        Output.snapshot(h.window.contentView!, "S2-bottom")
        h.frames.start()
        r.up = await h.driveScroll(velocity: -velocity, maxSeconds: maxScrollSeconds) { $0.visibleRect.minY <= 0.5 }
        r.framesUp = h.frames.stop()
        r.stalls = h.watchdog.stop()
        r.memoryAfter = Probe.memory()
        r.stabiliserEnabled = c.stabiliseViewport
        r.stabiliserCorrections = c.stabiliserCorrections
        r.stabiliserMaxCorrectionPT = Double(c.stabiliserMaxCorrectionPT)
        r.environment = environment()
        return r
    }

    // MARK: S3 streaming while following

    struct StreamReport: Encodable {
        var deltas = 0
        var commits = 0
        var bytes = 0
        var seconds = 0.0
        var parseP50MS = 0.0
        var parseP95MS = 0.0
        var parseMaxMS = 0.0
        var commitP50MS = 0.0
        var commitP95MS = 0.0
        var commitMaxMS = 0.0
        var commitEditP95MS = 0.0
        var commitEditMaxMS = 0.0
        var deltaToVisibleP50MS = 0.0
        var deltaToVisibleP95MS = 0.0
        var deltaToVisibleMaxMS = 0.0
        var cpuPercent = 0.0
        var tailMatchesFullRender = false
    }

    struct S3Report: Encodable {
        var environment: Environment
        var stream: StreamReport?
        var frames: FrameStats?
        var stalls: StallStats?
        var followedToEnd = false
        var bottomGapMaxPT = 0.0
        var memoryAfter: Probe.Memory?
    }

    /// Runs the streaming pipeline for `streamSeconds`, collecting latency; `during` runs concurrently.
    func stream(during: (@MainActor () async -> Void)? = nil) async -> StreamReport {
        var report = StreamReport()
        let id = "msg-stream"
        let generation = c.beginStreamingMessage(id: id)
        let pipeline = SpikeStreamPipeline(script: SpikeWorkload.streamScript())
        var latencies: [Double] = []
        let controller = c
        h.frames.auxTick = { link in
            if !controller.pendingVisibleStamps.isEmpty {
                for stamp in controller.pendingVisibleStamps { latencies.append((link.targetTimestamp - stamp) * 1_000) }
                controller.pendingVisibleStamps.removeAll(keepingCapacity: true)
            }
        }
        let cpu0 = Probe.cpuSeconds()
        let wall0 = CACurrentMediaTime()
        let seconds = streamSeconds
        let streaming = Task { await pipeline.run(into: controller, generation: generation, duration: seconds) }
        if let during { await during() }
        await streaming.value
        await h.sleep(0.1)
        h.frames.auxTick = nil
        report.cpuPercent = (Probe.cpuSeconds() - cpu0) / (CACurrentMediaTime() - wall0) * 100
        report.seconds = CACurrentMediaTime() - wall0
        let stats = await pipeline.stats
        report.deltas = stats.deltas
        report.commits = stats.commits
        report.bytes = stats.bytes
        report.parseP50MS = percentile(stats.parseMS, 0.5)
        report.parseP95MS = percentile(stats.parseMS, 0.95)
        report.parseMaxMS = stats.parseMS.max() ?? 0
        report.commitP50MS = percentile(c.commitDurationsMS, 0.5)
        report.commitP95MS = percentile(c.commitDurationsMS, 0.95)
        report.commitMaxMS = c.commitDurationsMS.max() ?? 0
        report.commitEditP95MS = percentile(c.commitEditMS, 0.95)
        report.commitEditMaxMS = c.commitEditMS.max() ?? 0
        report.deltaToVisibleP50MS = percentile(latencies, 0.5)
        report.deltaToVisibleP95MS = percentile(latencies, 0.95)
        report.deltaToVisibleMaxMS = latencies.max() ?? 0
        // Equivalence: the incrementally committed tail must equal a full render of the final source.
        let source = await pipeline.streamedSource
        var full = SpikeRich()
        SpikeMarkdown.render(source, into: &full)
        if let index = c.messageIndex(id: id) {
            let range = c.range(ofMessage: index)
            let body = (c.storage.string as NSString).substring(from: range.upperBound - full.length)
            report.tailMatchesFullRender = body == full.text && range.length >= full.length
        }
        return report
    }

    func s3() async -> S3Report {
        await openLoaded()
        var r = S3Report(environment: environment())
        var gapMax = 0.0
        let controller = c
        h.frames.onTick = { _ in
            gapMax = max(gapMax, Double(controller.textView.frame.height - controller.visibleRect.maxY))
        }
        h.watchdog.start()
        h.frames.start()
        var snapped = false
        r.stream = await stream {
            await self.h.sleep(self.streamSeconds / 2)
            Output.snapshot(self.h.window.contentView!, "S3-mid-stream")
            snapped = true
        }
        r.frames = h.frames.stop()
        r.stalls = h.watchdog.stop()
        h.frames.onTick = nil
        _ = snapped
        r.followedToEnd = c.isFollowing && c.isAtBottom
        r.bottomGapMaxPT = gapMax
        r.memoryAfter = Probe.memory()
        Output.snapshot(h.window.contentView!, "S3-end")
        return r
    }

    // MARK: S4 streaming while scrolled up and scrolling

    struct S4Report: Encodable {
        var environment: Environment
        var stream: StreamReport?
        var frames: FrameStats?
        var stalls: StallStats?
        var scrollSegments: [JumpStats] = []
        var pauseDriftsPT: [Double] = []
        /// Pixel ground truth: on-screen shift of the viewport content across each 1 s pause while streaming.
        var pausePixelShiftsPT: [Double] = []
        var maxAbsPausePixelShiftPT = 0.0
        var maxAbsPauseDriftPT = 0.0
        var releasedOnScrollUp = false
        var stayedReleasedWhileStreaming = true
        var jumpButtonShownWhileReleased = false
        var rejoinedByJumpButton = false
        var followedAfterJumpButton = false
        var releasedAgain = false
        var rejoinedByScrollingToBottom = false
    }

    func s4() async -> S4Report {
        await openLoaded()
        var r = S4Report(environment: environment())
        // Release follow mode with user scrolling: 2 s up at 3,000 pt/s.
        _ = await h.driveScroll(velocity: -3_000, maxSeconds: 2) { _ in false }
        r.releasedOnScrollUp = !c.isFollowing
        r.jumpButtonShownWhileReleased = c.jumpButtonVisible
        await h.sleep(0.5)
        h.watchdog.start()
        h.frames.start()
        r.stream = await stream {
            let end = CACurrentMediaTime() + self.streamSeconds - 2
            var direction = -1.0
            while CACurrentMediaTime() < end {
                let segment = await self.h.driveScroll(velocity: 1_500 * direction, maxSeconds: 2) { _ in false }
                r.scrollSegments.append(segment)
                if self.c.isFollowing { r.stayedReleasedWhileStreaming = false }
                direction = -direction
                await self.h.sleep(0.05)
                let anchor = self.c.captureTopAnchor()
                let pixelsBefore = self.windowSignature()
                await self.h.sleep(1)
                let drift = self.c.drift(of: anchor, shiftedBy: 0)
                r.pauseDriftsPT.append(drift)
                if let a = pixelsBefore, let b = self.windowSignature() {
                    r.pausePixelShiftsPT.append(self.pixelShift(a, b).shiftPT)
                }
                if self.c.isFollowing { r.stayedReleasedWhileStreaming = false }
            }
            Output.snapshot(self.h.window.contentView!, "S4-released")
            // Rejoin with the jump-to-latest control (a real button click through the event path).
            if let frame = Optional(self.c.jumpButtonFrame), !frame.isEmpty {
                let point = NSPoint(x: frame.midX, y: frame.midY)
                if let down = self.h.mouseEvent(.leftMouseDown, at: point), let up = self.h.mouseEvent(.leftMouseUp, at: point) {
                    NSApp.postEvent(up, atStart: false)
                    self.h.window.sendEvent(down)
                }
            }
            r.rejoinedByJumpButton = self.c.isFollowing && self.c.isAtBottom
            await self.h.sleep(1)
            r.followedAfterJumpButton = self.c.isFollowing && self.c.isAtBottom
        }
        r.frames = h.frames.stop()
        r.stalls = h.watchdog.stop()
        r.maxAbsPauseDriftPT = r.pauseDriftsPT.map(abs).max() ?? 0
        r.maxAbsPausePixelShiftPT = r.pausePixelShiftsPT.map(abs).max() ?? 0
        Output.snapshot(h.window.contentView!, "S4-rejoined")
        // Release again, then rejoin by scrolling down to the bottom.
        _ = await h.driveScroll(velocity: -2_000, maxSeconds: 0.5) { _ in false }
        r.releasedAgain = !c.isFollowing
        _ = await h.driveScroll(velocity: 4_000, maxSeconds: 3) { $0.isAtBottom }
        _ = await h.driveScroll(velocity: 1_000, maxSeconds: 0.1) { _ in false }
        r.rejoinedByScrollingToBottom = c.isFollowing
        r.environment = environment()
        return r
    }

    // MARK: S5 anchoring

    struct AnchorCase: Encodable {
        var name: String
        var compensated: Bool
        var driftImmediatePT: Double
        var driftSettledPT: Double
        var heightChangePT: Double
        var pixelShiftPT = 0.0
        var note = ""
    }

    struct S5Report: Encodable {
        var environment: Environment
        var cases: [AnchorCase] = []
        var clickToggle: [String: Double] = [:]
        var clickToggleWorked = false
        var passes2PT = false
    }

    /// Message indices with a tool card, and the card IDs.
    func toolCards(in range: Range<Int>) -> [(index: Int, id: String)] {
        var out: [(Int, String)] = []
        for index in range {
            for case let .tool(tool) in c.messages[index].parts { out.append((index, tool.id)) }
        }
        return out
    }

    func images(in range: Range<Int>) -> [(index: Int, id: String)] {
        var out: [(Int, String)] = []
        for index in range {
            for case let .image(image) in c.messages[index].parts { out.append((index, image.id)) }
        }
        return out
    }

    func measureCase(_ name: String, compensated: Bool, note: String = "", _ edit: () -> Void) async -> AnchorCase {
        c.compensateAnchors = compensated
        let anchor = c.captureTopAnchor()
        let heightBefore = c.textView.frame.height
        let lengthBefore = c.storage.length
        let topMessageBefore = anchor.map { $0.location } ?? 0
        let pixelsBefore = windowSignature()
        edit()
        // Shift only matters when the edit is above the anchor; callers edit above, so shift = length delta.
        let shift = c.storage.length - lengthBefore
        let immediate = c.drift(of: anchor, shiftedBy: shift)
        let settled = await c.settledDrift(of: anchor, shiftedBy: shift)
        _ = topMessageBefore
        var pixel = Double.nan
        if let a = pixelsBefore, let b = windowSignature() { pixel = pixelShift(a, b).shiftPT }
        c.compensateAnchors = true
        return AnchorCase(name: name, compensated: compensated, driftImmediatePT: immediate, driftSettledPT: settled,
                          heightChangePT: c.textView.frame.height - heightBefore, pixelShiftPT: pixel, note: note)
    }

    func s5() async -> S5Report {
        await openLoaded(autoDeliverImages: false)
        var r = S5Report(environment: environment())
        let count = c.messages.count
        // (a) Expand a tool card just above the viewport, then one far above (not laid out).
        for compensated in [true, false] {
            let target = compensated ? count - 3_000 : count - 4_000
            let cards = toolCards(in: (target - 40)..<(target - 2))
            c.reveal(messageAt: target, offset: 0)
            await h.sleep(0.5)
            if let near = cards.last {
                r.cases.append(await measureCase("expand tool card just above viewport", compensated: compensated) {
                    c.toggleCard(near.id, pinned: false)
                })
            }
            await h.sleep(0.3)
            let far = toolCards(in: (target - 400)..<(target - 200)).first
            if let far {
                r.cases.append(await measureCase("expand tool card far above (unlaid)", compensated: compensated) {
                    c.toggleCard(far.id, pinned: false)
                })
            }
        }
        // (b) A late image arrives above the viewport (placeholder 180×28 grows to full size).
        let allImages = images(in: 200..<(count - 200))
        for (n, compensated) in [true, false].enumerated() {
            guard allImages.count > 10 else { break }
            let image = allImages[allImages.count / 2 + n * 3]
            c.reveal(messageAt: image.index + 1, offset: 0)
            await h.sleep(0.5)
            r.cases.append(await measureCase("late image arrives just above viewport", compensated: compensated,
                                             note: image.id) {
                c.deliverImage(image.id)
            })
            let far = allImages[allImages.count / 2 - 6 + n]
            r.cases.append(await measureCase("late image arrives far above (unlaid)", compensated: compensated,
                                             note: far.id) {
                c.deliverImage(far.id)
            })
        }
        // (c) Prepend 100 older messages while viewing the top region.
        for (n, compensated) in [true, false].enumerated() {
            c.reveal(messageAt: 30 + n * 10, offset: 0)
            await h.sleep(0.5)
            c.compensateAnchors = compensated
            let pixelsBefore = windowSignature()
            let result = await c.prependOlder(SpikeWorkload.olderPage(seed: UInt64(4_242 + n)).map {
                SpikeMessage(id: "\($0.id)-\(n)", role: $0.role, parts: $0.parts)
            })
            c.compensateAnchors = true
            r.cases.append(AnchorCase(name: "prepend 100 older messages", compensated: compensated,
                                      driftImmediatePT: result.driftImmediate, driftSettledPT: result.driftSettled,
                                      heightChangePT: 0,
                                      pixelShiftPT: pixelsBefore.flatMap { a in windowSignature().map { pixelShift(a, $0).shiftPT } } ?? .nan,
                                      note: "main-thread insert \(String(format: "%.1f", c.loadMarks["lastPrependMS"] ?? 0)) ms"))
        }
        // Click a tool card header in the viewport (behaviour 5): the header must stay put.
        c.reveal(messageAt: count - 2_000, offset: 0)
        await h.sleep(0.5)
        let candidates = toolCards(in: (count - 2_000)..<(count - 1_980))
        var chosen: (card: (index: Int, id: String), header: NSRange, point: CGPoint)?
        for card in candidates {
            guard let header = c.headerRange(ofCard: card.id) else { continue }
            if chosen == nil { c.reveal(messageAt: card.index, offset: 0); await h.sleep(0.4) }
            if let point = c.characterPoint(at: header.location + 4), c.visibleRect.insetBy(dx: 0, dy: 20).contains(point) {
                chosen = (card, header, point)
                break
            }
        }
        if let chosen {
            let card = chosen.card, header = chosen.header, point = chosen.point
            let before = c.fragmentFrame(at: header.location)!.minY - c.visibleRect.minY
            let wasExpanded = c.expanded.contains(card.id)
            log("app active \(NSApp.isActive) window key \(h.window.isKeyWindow) first responder is text view \(h.window.firstResponder === c.textView)")
            let hit = c.textView.characterIndexForInsertion(at: point)
            log("click test: card \(card.id) header \(header) point \(point) hit index \(hit) link \(String(describing: c.storage.attribute(.link, at: min(hit, c.storage.length - 1), effectiveRange: nil)))")
            Output.snapshot(h.window.contentView!, "S5-before-click")
            h.click(textViewPoint: point)
            await h.sleep(0.4)
            Output.snapshot(h.window.contentView!, "S5-after-click-expand")
            let afterExpand = c.fragmentFrame(at: header.location)!.minY - c.visibleRect.minY
            let expandedNow = c.expanded.contains(card.id)
            h.click(textViewPoint: c.characterPoint(at: header.location + 4) ?? point)
            await h.sleep(0.4)
            let afterCollapse = c.fragmentFrame(at: header.location)!.minY - c.visibleRect.minY
            log("link clicks \(c.linkClicks)")
            r.clickToggleWorked = !wasExpanded && expandedNow && !c.expanded.contains(card.id)
            r.clickToggle = ["headerDriftAfterExpandPT": Double(afterExpand - before),
                             "headerDriftAfterCollapsePT": Double(afterCollapse - before)]
        }
        r.passes2PT = r.cases.filter(\.compensated).allSatisfy { abs($0.pixelShiftPT) <= 2 }
        r.environment = environment()
        return r
    }

    // MARK: S6 resize

    struct S6Report: Encodable {
        var environment: Environment
        var frames: FrameStats?
        var stalls: StallStats?
        var anchorDriftAfterRoundTripPT = 0.0
        var pixelShiftAfterRoundTripPT = 0.0
        var anchorMessageStillTop = false
        var containerTracksWidth = false
        var widths: [String: Double] = [:]
        var followingRun: FrameStats?
        var stayedAtBottomWhileFollowing = false
    }

    func animateWidth(from: CGFloat, to: CGFloat, seconds: Double) async {
        c.resizing = true
        defer { c.resizing = false }
        let start = CACurrentMediaTime()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            h.frames.onTick = { [weak self] _ in
                guard let self else { return }
                let t = min(1, (CACurrentMediaTime() - start) / seconds)
                var frame = self.h.window.frame
                frame.size.width = from + (to - from) * t
                self.h.window.setFrame(frame, display: true)
                if t >= 1 { self.h.frames.onTick = nil; continuation.resume() }
            }
        }
    }

    func s6() async -> S6Report {
        await openLoaded(width: 900)
        var r = S6Report(environment: environment())
        c.reveal(messageAt: c.messages.count - 1_500, offset: 0)
        await h.sleep(0.5)
        let anchor = c.captureTopAnchor()
        let topIndex = c.messages.count - 1_500
        Output.snapshot(h.window.contentView!, "S6-900")
        let pixelsBefore = windowSignature()
        h.watchdog.start()
        h.frames.start()
        await animateWidth(from: 900, to: 1_400, seconds: 1)
        r.widths["textView1400"] = c.textView.frame.width
        r.widths["container1400"] = c.layoutManager.textContainer?.size.width ?? 0
        Output.snapshot(h.window.contentView!, "S6-1400")
        await animateWidth(from: 1_400, to: 900, seconds: 1)
        r.frames = h.frames.stop()
        r.stalls = h.watchdog.stop()
        await h.sleep(0.4)
        r.widths["textView900"] = c.textView.frame.width
        r.widths["container900"] = c.layoutManager.textContainer?.size.width ?? 0
        r.containerTracksWidth = abs((r.widths["container1400"] ?? 0) - (r.widths["textView1400"] ?? 0) + 32) < 1
            && abs((r.widths["container900"] ?? 0) - (r.widths["textView900"] ?? 0) + 32) < 1
        r.anchorDriftAfterRoundTripPT = c.drift(of: anchor, shiftedBy: 0)
        if let a = pixelsBefore, let b = windowSignature() { r.pixelShiftAfterRoundTripPT = pixelShift(a, b).shiftPT }
        if let top = c.captureTopAnchor() {
            let range = c.range(ofMessage: topIndex)
            r.anchorMessageStillTop = NSLocationInRange(top.location, range)
        }
        Output.snapshot(h.window.contentView!, "S6-900-after")
        // Following at the bottom while resizing.
        c.jumpToLatest()
        await h.sleep(0.3)
        h.frames.start()
        var stayed = true
        await animateWidth(from: 900, to: 1_400, seconds: 1)
        stayed = stayed && c.isAtBottom
        await animateWidth(from: 1_400, to: 900, seconds: 1)
        await h.sleep(0.2)
        stayed = stayed && c.isAtBottom
        r.followingRun = h.frames.stop()
        r.stayedAtBottomWhileFollowing = stayed
        r.environment = environment()
        return r
    }

    // MARK: S7 selection and copy

    struct S7Report: Encodable {
        var environment: Environment
        var method = ""
        var startMessage = 0
        var messagesSpanned = 0
        var selectedUTF16 = 0
        var dragSeconds = 0.0
        var dragMessagesSpanned = 0
        var dragStartedAtMessageStart = false
        var shiftClickMS = 0.0
        var copyMS = 0.0
        var copiedCharacters = 0
        var startsWithRoleLabel = false
        var roleLabels = 0
        var codeLinesFound = 0
        var codeLinesExpected = 0
        var collapsedCardsCopiedAsSummary = 0
        var collapsedCardsExpected = 0
        var collapsedOutputLeaked = false
        var objectReplacementCharacters = 0
        var imagesAsText = 0
        var tablesAsTabSeparated = 0
        var excerpt = ""
        var frames: FrameStats?
    }

    func s7() async -> S7Report {
        await openLoaded()
        var r = S7Report(environment: environment())
        // Pick a start so the 20-message span contains code blocks and tool cards.
        let count = c.messages.count
        var start = count - 2_400
        while start < count - 30 {
            let span = c.messages[start..<(start + 21)]
            let tools = span.flatMap(\.parts).filter { if case .tool = $0 { return true } else { return false } }.count
            let code = span.flatMap(\.parts).contains { if case let .markdown(t) = $0 { return t.contains("```") } else { return false } }
            if tools >= 2, code, start % 2 == 0 { break }
            start += 1
        }
        r.startMessage = start
        let endIndex = start + 20
        c.reveal(messageAt: start, offset: 10)
        await h.sleep(0.5)
        let startRange = c.range(ofMessage: start)
        let endRange = c.range(ofMessage: endIndex)
        guard let startPoint = c.characterPoint(at: startRange.location) else { return r }
        // Real drag: mouse-down at the start, then drag below the view so NSTextView autoscrolls, then mouse-up.
        r.method = "synthetic drag with autoscroll: mouseDown on the text view, mouseDragged posted below the view each frame until the live selection passes message start+20, mouseUp"
        let windowStart = c.textView.convert(startPoint, to: nil)
        let below = NSPoint(x: windowStart.x + 200, y: -30)
        let began = CACurrentMediaTime()
        let deadline = began + 60
        var finished = false
        let harness = h
        let controller = c
        h.frames.start()
        // The display link runs in common modes, so it keeps firing inside the text view's mouse tracking loop. The
        // stop condition reads the live selection (TextKit geometry for far text is an estimate, see the report).
        let target = endRange.upperBound - 1
        var ticks = 0
        h.frames.onTick = { _ in
            guard !finished else { return }
            ticks += 1
            // Hit-test a visible point near the bottom of the viewport (measured layout, unlike far geometry).
            let probe = NSPoint(x: 60, y: controller.visibleRect.maxY - 40)
            let index = controller.textView.characterIndexForInsertion(at: probe)
            if ticks % 30 == 0 { log("drag tick \(ticks) visible-bottom index \(index) target \(target) selection \(controller.textView.selectedRange())") }
            if (ticks > 3 && index >= target) || CACurrentMediaTime() > deadline {
                let wp = controller.textView.convert(probe, to: nil)
                if let drag = harness.mouseEvent(.leftMouseDragged, at: wp), let up = harness.mouseEvent(.leftMouseUp, at: wp) {
                    NSApp.postEvent(drag, atStart: false)
                    NSApp.postEvent(up, atStart: false)
                }
                finished = true
                harness.frames.onTick = nil
            } else if let drag = harness.mouseEvent(.leftMouseDragged, at: below) {
                NSApp.postEvent(drag, atStart: false)
            }
        }
        c.textView.setSelectedRange(NSRange(location: startRange.location, length: 0))
        log("drag start hit index \(c.textView.characterIndexForInsertion(at: startPoint)) expected \(startRange.location)")
        if let down = h.mouseEvent(.leftMouseDown, at: windowStart) { c.textView.mouseDown(with: down) }
        // sendEvent returns when the text view's tracking loop sees the mouse-up.
        while !finished { await h.sleep(0.05) }
        await h.sleep(0.2)
        r.frames = h.frames.stop()
        r.dragSeconds = CACurrentMediaTime() - began
        let dragSelection = c.textView.selectedRange()
        r.dragMessagesSpanned = (0..<count).filter { NSIntersectionRange(c.range(ofMessage: $0), dragSelection).length > 0 }.count
        r.dragStartedAtMessageStart = dragSelection.location == startRange.location
        Output.snapshot(h.window.contentView!, "S7-drag-end")
        // Method 2 (exact extent): click at the start, scroll to the 20th message, shift-click at its last character.
        c.reveal(messageAt: start, offset: 10)
        await h.sleep(0.3)
        if let p = c.characterPoint(at: startRange.location) { h.click(textViewPoint: p) }
        c.reveal(messageAt: endIndex, offset: 10)
        await h.sleep(0.3)
        var endPoint: CGPoint?
        // Find a visible point whose hit index is the end of message start+20 (hit-testing, not far geometry).
        if let guess = c.characterPoint(at: endRange.upperBound - 1) {
            let hit = c.textView.characterIndexForInsertion(at: guess)
            log("shift-click target \(endRange.upperBound - 1) hit \(hit) visible \(c.visibleRect.contains(guess))")
            endPoint = guess
        }
        let t2 = CACurrentMediaTime()
        if let endPoint { h.click(textViewPoint: CGPoint(x: endPoint.x + 4, y: endPoint.y), modifiers: .shift) }
        r.shiftClickMS = (CACurrentMediaTime() - t2) * 1_000
        r.method = "primary: click at message start, scroll, shift-click at the end of message start+20; also a synthetic drag with autoscroll (dragMessagesSpanned)"
        let selection = c.textView.selectedRange()
        r.selectedUTF16 = selection.length
        r.messagesSpanned = (0..<count).filter { NSIntersectionRange(c.range(ofMessage: $0), selection).length > 0 }.count
        Output.snapshot(h.window.contentView!, "S7-selection-end")
        // Copy through the text view's own pasteboard writer (a private pasteboard, not the user's clipboard).
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("bello.g1a.\(getpid())"))
        let t = CACurrentMediaTime()
        _ = c.textView.writeSelection(to: pasteboard, types: [.string])
        let text = pasteboard.string(forType: .string) ?? ""
        r.copyMS = (CACurrentMediaTime() - t) * 1_000
        pasteboard.releaseGlobally()
        r.copiedCharacters = text.count
        try? text.write(to: Output.reportDirectory.appending(path: "S7-copied.txt"), atomically: true, encoding: .utf8)
        r.startsWithRoleLabel = text.hasPrefix("You\n") || text.hasPrefix("Assistant\n")
        r.roleLabels = text.components(separatedBy: "\n").filter { $0 == "You" || $0 == "Assistant" }.count
        r.objectReplacementCharacters = text.filter { $0 == "\u{FFFC}" }.count
        r.imagesAsText = text.components(separatedBy: "[image ").count - 1
        for index in start..<min(count, endIndex + 1) where NSIntersectionRange(c.range(ofMessage: index), selection).length > 0 {
            for part in c.messages[index].parts {
                switch part {
                case let .markdown(md):
                    for block in SpikeMarkdown.blocks(Substring(md)) {
                        if case .code = block.kind, let line = block.lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                            r.codeLinesExpected += 1
                            if text.contains(String(line)) { r.codeLinesFound += 1 }
                        }
                        if case .table = block.kind { if text.contains("\t") { r.tablesAsTabSeparated += 1 } }
                    }
                case let .tool(tool) where !c.expanded.contains(tool.id):
                    r.collapsedCardsExpected += 1
                    if text.contains("\(tool.name)  \(tool.title)") { r.collapsedCardsCopiedAsSummary += 1 }
                    if let line = tool.output.first(where: { $0.count > 30 }), text.contains(line) { r.collapsedOutputLeaked = true }
                default: break
                }
            }
        }
        r.excerpt = String(text.prefix(700))
        r.environment = environment()
        return r
    }

    // MARK: find

    struct FindReport: Encodable {
        var environment: Environment
        var results: [[String: String]] = []
    }

    func find() async -> FindReport {
        await openLoaded()
        var r = FindReport(environment: environment())
        for needle in [SpikeTranscript.offscreenNeedle, SpikeTranscript.collapsedNeedle] {
            let t = CACurrentMediaTime()
            let result = await c.findAndReveal(needle)
            let ms = (CACurrentMediaTime() - t) * 1_000
            await h.sleep(0.6)
            let selected = (c.storage.string as NSString).substring(with: c.textView.selectedRange())
            let visibleAfter = c.fragmentFrame(at: c.textView.selectedRange().location).map { c.visibleRect.intersects($0) } ?? false
            r.results.append([
                "needle": needle,
                "found": result == nil ? "false" : "true",
                "message": result.map { String($0.messageIndex) } ?? "-",
                "expandedCard": result?.cardID ?? "-",
                "ms": String(format: "%.1f", ms),
                "visibleAfterSettle": String(visibleAfter),
                "selectionMatches": String(selected == needle),
                "followingAfter": String(c.isFollowing),
            ])
            Output.snapshot(h.window.contentView!, "find-\(needle)")
        }
        r.environment = environment()
        return r
    }

    // MARK: huge code block

    struct HugeReport: Encodable {
        var environment: Environment
        var blockHeightPT = 0.0
        var revealMS = 0.0
        var down: JumpStats?
        var up: JumpStats?
        var framesDown: FrameStats?
        var framesUp: FrameStats?
        var stalls: StallStats?
    }

    func huge() async -> HugeReport {
        await openLoaded()
        var r = HugeReport(environment: environment())
        let index = SpikeTranscript.hugeBlockMessage
        let t = CACurrentMediaTime()
        c.reveal(messageAt: index, offset: 0)
        r.revealMS = (CACurrentMediaTime() - t) * 1_000
        await h.sleep(0.5)
        let range = c.range(ofMessage: index)
        let top = c.fragmentFrame(at: range.location)?.minY ?? 0
        let bottom = c.fragmentFrame(at: range.upperBound - 1)?.maxY ?? 0
        r.blockHeightPT = bottom - top
        Output.snapshot(h.window.contentView!, "huge-start")
        h.watchdog.start()
        h.frames.start()
        let speed = 3_000.0
        r.down = await h.driveScroll(velocity: speed, maxSeconds: 120) { $0.visibleRect.minY >= bottom }
        r.framesDown = h.frames.stop()
        h.frames.start()
        r.up = await h.driveScroll(velocity: -speed, maxSeconds: 120) { $0.visibleRect.minY <= top }
        r.framesUp = h.frames.stop()
        r.stalls = h.watchdog.stop()
        r.environment = environment()
        return r
    }

    // MARK: S8 memory

    struct S8Report: Encodable {
        var environment: Environment
        var afterEachScenario: [String: Probe.Memory] = [:]
        var afterCycles: [Probe.Memory] = []
        var afterAllCyclesSettled: Probe.Memory?
        var note = "S1–S7 run in sequence in one process (S2 scrolls the full document at the standard velocity)."
    }

    func s8() async -> S8Report {
        var r = S8Report(environment: environment())
        r.afterEachScenario["0-start"] = Probe.memory()
        let steps: [(String, () async -> Void)] = [
            ("S1", { Output.write("S8-S1", await self.s1()) }),
            ("S2", { Output.write("S8-S2", await self.s2()) }),
            ("S3", { Output.write("S8-S3", await self.s3()) }),
            ("S4", { Output.write("S8-S4", await self.s4()) }),
            ("S5", { Output.write("S8-S5", await self.s5()) }),
            ("S6", { Output.write("S8-S6", await self.s6()) }),
            ("S7", { Output.write("S8-S7", await self.s7()) }),
        ]
        for (name, step) in steps {
            if h.window != nil { h.closeWindow() }
            await step()
            r.afterEachScenario[name] = Probe.memory()
            r.environment = environment()
        }
        h.closeWindow()
        for _ in 0..<20 {
            await openLoaded()
            h.closeWindow()
            await h.sleep(0.2)
            r.afterCycles.append(Probe.memory())
        }
        await h.sleep(3)
        r.afterAllCyclesSettled = Probe.memory()
        return r
    }
}
