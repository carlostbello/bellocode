// SPIKE G1-B: scripted scenarios S1...S8. Everything is driven in-process (the shell cannot drive the UI).

import AppKit
import QuartzCore
import TranscriptKit

struct RunHeader: Codable {
    var scenario: String
    var date = ISO8601DateFormatter().string(from: Date())
    var machine: String
    var cores = ProcessInfo.processInfo.activeProcessorCount
    var macOS = ProcessInfo.processInfo.operatingSystemVersionString
    var displayMaxFPS: Int
    var displayName: String
    var build: String
    var window: String
    var workload: SpikeWorkload.Stats
    var workloadGenerationMs: Double
    /// 1-minute load average when the report was written (other processes on the machine skew results).
    var loadAverage1m: Double = {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return (loads[0] * 100).rounded() / 100
    }()
}

@MainActor
final class ScenarioRunner {
    unowned let app: SpikeApp
    let workload: SpikeWorkload
    let workloadGenerationMs: Double
    var controller: SpikeTranscriptController?
    var recorder: FrameRecorder!
    let watchdog = Watchdog()
    var rng = SpikeRNG(seed: 4242)
    let streamSeconds: Double
    let scrollSpeed: Double
    var excludeFrames = false

    init(app: SpikeApp) {
        self.app = app
        let start = CACurrentMediaTime()
        workload = SpikeWorkload.generate()
        workloadGenerationMs = (CACurrentMediaTime() - start) * 1000
        let args = CommandLine.arguments
        func option(_ name: String, _ fallback: Double) -> Double {
            args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? fallback
        }
        streamSeconds = option("--stream-seconds", 65)
        scrollSpeed = option("--scroll-speed", 3)
    }

    var nominal: Double { 1.0 / Double(max(1, app.window.screen?.maximumFramesPerSecond ?? 60)) }

    func header(_ scenario: String) -> RunHeader {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        let screen = app.window.screen
        return RunHeader(scenario: scenario, machine: String(decoding: brand.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                         displayMaxFPS: screen?.maximumFramesPerSecond ?? 0,
                         displayName: screen?.localizedName ?? "?", build: build,
                         window: "\(Int(app.window.frame.width))x\(Int(app.window.frame.height)) pt, backing scale \(screen?.backingScaleFactor ?? 0)",
                         workload: workload.stats, workloadGenerationMs: round2(workloadGenerationMs))
    }

    // MARK: Open / close

    struct OpenTimings: Codable {
        var offMainOpenPassMs = 0.0
        var openToFirstFrameMs = 0.0
        var openToInteractiveMs = 0.0
        var launchToFirstFrameMs = 0.0
        var memoryAfterOpen = Memory.now()
    }

    @discardableResult
    func openTranscript(holdImages: Set<Int> = []) async -> OpenTimings {
        if recorder == nil { recorder = FrameRecorder(view: app.window.contentView!) }
        let start = CACurrentMediaTime()
        let theme = SpikeTheme.resolve(for: app.window.effectiveAppearance)
        let controller = SpikeTranscriptController(items: workload.items, theme: theme)
        controller.heldImages = holdImages
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("BelloCode.SpikeB.\(getpid())"))
        self.controller = controller
        controller.container.translatesAutoresizingMaskIntoConstraints = false
        app.host.addSubview(controller.container)
        NSLayoutConstraint.activate([
            controller.container.leadingAnchor.constraint(equalTo: app.host.leadingAnchor),
            controller.container.trailingAnchor.constraint(equalTo: app.host.trailingAnchor),
            controller.container.topAnchor.constraint(equalTo: app.host.topAnchor),
            controller.container.bottomAnchor.constraint(equalTo: app.host.bottomAnchor),
        ])
        app.host.layoutSubtreeIfNeeded()
        await controller.open(viewportHeight: controller.scrollView.contentView.bounds.height)
        var timings = OpenTimings()
        timings.offMainOpenPassMs = round2((CACurrentMediaTime() - start) * 1000)
        let f1 = await recorder.nextFrame()  // the frame that commits the first content
        let t1 = CACurrentMediaTime()
        let f2 = await recorder.nextFrame()
        FileHandle.standardError.write(Data("open: pass \(timings.offMainOpenPassMs) ms; frame1 cb at \((t1 - start) * 1000) ms (ts \((f1 - start) * 1000)); frame2 ts \((f2 - start) * 1000) ms\n".utf8))
        timings.openToFirstFrameMs = round2((CACurrentMediaTime() - start) * 1000)
        timings.launchToFirstFrameMs = round2(ProcessStats.secondsSinceLaunch() * 1000)
        // Interactive: a main-queue ping comes back within one frame.
        while true {
            let sent = CACurrentMediaTime()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            if CACurrentMediaTime() - sent < nominal { break }
        }
        timings.openToInteractiveMs = round2((CACurrentMediaTime() - start) * 1000)
        timings.memoryAfterOpen = Memory.now()
        return timings
    }

    func closeTranscript() {
        controller?.close()
        controller = nil
    }

    func waitForMeasureAll(timeout: Double = 30) async {
        let start = CACurrentMediaTime()
        while let controller, !controller.measureAllComplete, CACurrentMediaTime() - start < timeout {
            try? await Task.sleep(for: .milliseconds(50))
        }
        await recorder.frames(3)
    }

    func sleep(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    /// Runs `step(dt, elapsed)` once per display frame until it returns false.
    func perFrame(_ step: @escaping (Double, Double) -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var last: Double?
            var start: Double?
            recorder.onFrame = { [weak self] link in
                let t = link.timestamp
                let dt = min(0.1, last.map { t - $0 } ?? (self?.nominal ?? 0.016))
                last = t
                if start == nil { start = t }
                if !step(dt, t - start!) {
                    self?.recorder.onFrame = nil
                    continuation.resume()
                }
            }
        }
    }

    var lastLog = 0.0
    func progress(_ text: @autoclosure () -> String) {
        let now = CACurrentMediaTime()
        guard now - lastLog > 2 else { return }
        lastLog = now
        FileHandle.standardError.write(Data("[\(Int(ProcessStats.secondsSinceLaunch()))s] \(text())\n".utf8))
    }

    func snapshot(_ name: String) {
        Snapshots.capture(app.window.contentView!, name: name)
    }

    /// Flick-and-momentum velocity profile (points per second), like repeated trackpad flicks.
    struct Flick {
        var velocity = 0.0
        mutating func step(_ dt: Double, rng: inout SpikeRNG, scale: Double) -> Double {
            if velocity < 500 { velocity = (4_000 + rng.unit() * 10_000) * scale }
            let distance = velocity * dt
            velocity *= exp(-dt / 0.7)
            return distance
        }
    }

    /// |NSTableView's document height - our model's| (should be 0).
    func geometryError() -> Double {
        guard let controller else { return -1 }
        let count = controller.items.count
        return abs(Double(controller.rowRect(count - 1).maxY - controller.modelOffset(ofRow: count)))
    }

    func release() { controller?.noteUserScroll(deltaY: 1) }

    // MARK: Run

    func run(_ name: String) async {
        if name == "all" {
            for scenario in ["S1", "S2", "S3", "S4", "S5", "S6", "S7"] {
                await run(scenario)
                closeTranscript()
                await sleep(1)
            }
            await runS8()
            return
        }
        switch name {
        case "S1": await runS1()
        case "S2": await runS2()
        case "S3": await runS3()
        case "S4": await runS4()
        case "S5": await runS5()
        case "S6": await runS6()
        case "S7": await runS7()
        case "S8": await runS8()
        default: print("unknown scenario \(name)")
        }
    }

    // MARK: S1 cold open

    struct S1Report: Codable {
        var header: RunHeader
        var open: OpenTimings
        var measureAllMs = 0.0
        var measureAllRows = 0
        var searchIndexMs = 0.0
        var exactRowsAtOpen = 0
        var memoryAfterBackgroundWork = Memory.now()
        var documentHeight = 0.0
        var metrics: SpikeTranscriptController.Metrics
    }

    func runS1() async {
        let open = await openTranscript()
        guard let controller else { return }
        let exactAtOpen = controller.exactRowCount
        snapshot("S1-open-bottom")
        await waitForMeasureAll()
        while !controller.searchIndexReady { await sleep(0.05) }
        await sleep(5.5)  // let all late images arrive
        snapshot("S1-after-background")
        Report.write(S1Report(header: header("S1"), open: open, measureAllMs: round2(controller.metrics.measureAllMilliseconds),
                              measureAllRows: controller.metrics.measureAllRows,
                              searchIndexMs: round2(controller.metrics.searchIndexMilliseconds), exactRowsAtOpen: exactAtOpen,
                              documentHeight: controller.rowRect(controller.items.count - 1).maxY, metrics: controller.metrics),
                     name: "S1")
    }

    // MARK: S2 continuous scroll

    struct S2Report: Codable {
        var header: RunHeader
        var documentHeight: Double
        var down: FrameStats
        var up: FrameStats
        var whileHugeRowVisible: FrameStats
        var synthesizedWheel: FrameStats
        var synthesizedWheelDistance: Double
        var watchdog: Watchdog.Report
        var metrics: SpikeTranscriptController.Metrics
        var meanVelocityPtPerS: Double
        var traversalSpeedMultiplier: Double
        var realisticSpeed60s: FrameStats
        var realisticMeanVelocityPtPerS: Double
        var hugeRowHeight: Double
        var tableGeometryErrorPt: Double
    }

    func runS2() async {
        await openTranscript()
        guard let controller else { return }
        await waitForMeasureAll()
        await sleep(5.5)
        release()
        controller.scrollTo(y: 0)
        await sleep(1)
        let hugeID = workload.items.first { $0.utf8Count > 100_000 }?.id ?? -1
        let hugeRow = controller.row(forItemID: hugeID) ?? -1
        recorder.tagProvider = { [weak controller] in controller?.visibleRows.contains(hugeRow) ?? false }
        let docHeight = controller.rowRect(controller.items.count - 1).maxY
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
            progress("S2 down y=\(Int(controller.scrollView.contentView.bounds.minY)) doc=\(Int(controller.rowRect(controller.items.count - 1).maxY)) model=\(Int(controller.modelOffset(ofRow: controller.items.count))) r5000=\(Int(controller.rowRect(5000).minY))/\(Int(controller.modelOffset(ofRow: 5000))) flushes=\(controller.metrics.heightFlushes) sync=\(controller.metrics.syncLayouts) dist=\(Int(controller.distanceFromBottom)) frames=\(recorder.intervals.count)")
            return controller.distanceFromBottom > 1
        }
        let downIntervals = recorder.stop()
        let downTags = recorder.tags
        snapshot("S2-bottom")
        recorder.start()
        flick = Flick()
        await perFrame { [self] dt, _ in
            let d = flick.step(dt, rng: &rng, scale: scrollSpeed)
            controller.userScroll(by: -d)
            travelled += d
            duration += dt
            progress("S2 up y=\(Int(controller.scrollView.contentView.bounds.minY))")
            return controller.scrollView.contentView.bounds.minY > 0.5
        }
        let upIntervals = recorder.stop()
        let upTags = recorder.tags
        snapshot("S2-top")
        let hugeIntervals = zip(downIntervals + upIntervals, downTags + upTags).filter(\.1).map(\.0)
        recorder.tagProvider = nil

        // 60 s at realistic (1x) flick velocities from a quarter of the way down.
        controller.scrollTo(y: docHeight / 4)
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
        let realisticIntervals = recorder.stop()

        // Synthesised trackpad-style scroll-wheel events through NSScrollView.scrollWheel(with:) for 20 s.
        controller.scrollTo(y: docHeight / 2)
        await sleep(0.5)
        let startY = controller.scrollView.contentView.bounds.minY
        recorder.start()
        var gesture = 0.0
        var direction = 1.0
        await perFrame { [self] dt, elapsed in
            gesture += dt
            if gesture > 1.6 { gesture = 0; direction = -direction }
            let velocity = (gesture < 0.15 ? 9_000 : 9_000 * exp(-(gesture - 0.15) / 0.5)) * scrollSpeed
            let phase: Int64 = gesture < dt * 1.5 ? 1 : gesture < 0.15 ? 2 : 0
            let momentum: Int64 = gesture < 0.15 ? 0 : (gesture - 0.15 < dt * 1.5 ? 1 : 2)
            let delta = -direction * velocity * dt
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(delta.rounded()),
                                wheel2: 0, wheel3: 0) {
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: delta)
                if let event = NSEvent(cgEvent: cg) {
                    controller.noteUserScroll(deltaY: event.scrollingDeltaY)
                    controller.scrollView.scrollWheel(with: event)
                }
            }
            return elapsed < 20
        }
        let wheelIntervals = recorder.stop()
        let wheelDistance = abs(controller.scrollView.contentView.bounds.minY - startY)
        let report = S2Report(header: header("S2"), documentHeight: docHeight,
                              down: FrameStats(intervals: downIntervals, nominal: nominal),
                              up: FrameStats(intervals: upIntervals, nominal: nominal),
                              whileHugeRowVisible: FrameStats(intervals: hugeIntervals, nominal: nominal),
                              synthesizedWheel: FrameStats(intervals: wheelIntervals, nominal: nominal),
                              synthesizedWheelDistance: wheelDistance, watchdog: watchdog.stop(),
                              metrics: controller.metrics, meanVelocityPtPerS: round2(travelled / max(duration, 0.001)),
                              traversalSpeedMultiplier: scrollSpeed,
                              realisticSpeed60s: FrameStats(intervals: realisticIntervals, nominal: nominal),
                              realisticMeanVelocityPtPerS: round2(realTravel / max(realDuration, 0.001)),
                              hugeRowHeight: hugeRow >= 0 ? controller.rowRect(hugeRow).height : 0,
                              tableGeometryErrorPt: geometryError())
        Report.write(report, name: "S2")
    }

    // MARK: Streaming helpers

    @concurrent
    static func produce(_ deltas: [String], buffer: SpikeDeltaBuffer, rate: Double, seconds: Double) async -> Int {
        let start = CACurrentMediaTime()
        var emitted = 0
        while !Task.isCancelled {
            let elapsed = CACurrentMediaTime() - start
            if elapsed >= seconds || emitted >= deltas.count { break }
            let due = min(deltas.count, Int(elapsed * rate) + 1)
            while emitted < due {
                buffer.append(deltas[emitted], time: CACurrentMediaTime())
                emitted += 1
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return emitted
    }

    // MARK: S3 streaming while following

    struct S3Report: Codable {
        var header: RunHeader
        var streamSeconds: Double
        var deltasProduced: Int
        var deltasApplied: Int
        var tailBytes: Int
        var commitIntervalMs: Double
        var frames: FrameStats
        var deltaToVisibleP50Ms: Double
        var deltaToVisibleP95Ms: Double
        var deltaToVisibleMaxMs: Double
        var cpuPercent: Double
        var maxDistanceFromBottomWhileFollowing: Double
        var followingAtEnd: Bool
        var watchdog: Watchdog.Report
        var metrics: SpikeTranscriptController.Metrics
        var overflowed: Bool
    }

    func runS3() async {
        await openTranscript()
        guard let controller else { return }
        await waitForMeasureAll()
        await sleep(5.5)
        let deltas = SpikeWorkload.tailDeltas(SpikeWorkload.tailScript())
        controller.beginStreamingTail(id: 50_000)
        var latencies: [Double] = []
        var maxDistance = 0.0
        let cpuStart = ProcessStats.cpuSeconds()
        let wallStart = CACurrentMediaTime()
        let buffer = controller.deltaBuffer
        let seconds = streamSeconds
        let producer = Task { await Self.produce(deltas, buffer: buffer, rate: 100, seconds: seconds) }
        watchdog.start()
        recorder.start()
        var snapshotsTaken = Set<Int>()
        await perFrame { [self] dt, elapsed in
            if dt > 0.04 { FileHandle.standardError.write(Data("S3 long frame \(Int(dt * 1000)) ms at \(round2(elapsed)) s, tail \(controller.tailSourceLength) B\n".utf8)) }
            for time in controller.drainAppliedDeltaTimes() { latencies.append(CACurrentMediaTime() - time) }
            if controller.following { maxDistance = max(maxDistance, controller.distanceFromBottom) }
            for mark in [10, 40] where elapsed > Double(mark) && !snapshotsTaken.contains(mark) && seconds > Double(mark) {
                snapshotsTaken.insert(mark)
                snapshot("S3-streaming-\(mark)s")  // excluded below: costs a frame or two
                recorder.discardNext()
            }
            return elapsed < seconds + 0.3
        }
        let intervals = recorder.stop()
        let produced = await producer.value
        controller.endStreamingTail()
        await recorder.frames(3)
        for time in controller.drainAppliedDeltaTimes() { latencies.append(CACurrentMediaTime() - time) }
        let cpu = (ProcessStats.cpuSeconds() - cpuStart) / (CACurrentMediaTime() - wallStart) * 100
        snapshot("S3-end")
        let ms = latencies.map { $0 * 1000 }
        Report.write(S3Report(header: header("S3"), streamSeconds: seconds, deltasProduced: produced,
                              deltasApplied: controller.appliedDeltaCount, tailBytes: controller.tailSourceLength,
                              commitIntervalMs: controller.commitInterval * 1000,
                              frames: FrameStats(intervals: intervals, nominal: nominal),
                              deltaToVisibleP50Ms: round2(percentile(ms, 0.5)), deltaToVisibleP95Ms: round2(percentile(ms, 0.95)),
                              deltaToVisibleMaxMs: round2(ms.max() ?? 0), cpuPercent: round2(cpu),
                              maxDistanceFromBottomWhileFollowing: maxDistance, followingAtEnd: controller.following,
                              watchdog: watchdog.stop(), metrics: controller.metrics, overflowed: controller.tailOverflowed),
                     name: "S3")
    }

    // MARK: S4 streaming while scrolled up

    struct S4Report: Codable {
        var header: RunHeader
        var frames: FrameStats
        var releasedOnScrollUp: Bool
        var unexpectedFollowFrames: Int
        var maxAnchorDriftWhileReadingPt: Double
        var readingPhases: Int
        var rejoinedByJumpButton: Bool
        var distanceAfterJump: Double
        var rejoinedByScrollToBottom: Bool
        var tailBytes: Int
        var cpuPercent: Double
        var watchdog: Watchdog.Report
        var metrics: SpikeTranscriptController.Metrics
    }

    func runS4() async {
        await openTranscript()
        guard let controller else { return }
        await waitForMeasureAll()
        await sleep(5.5)
        let deltas = SpikeWorkload.tailDeltas(SpikeWorkload.tailScript())
        controller.beginStreamingTail(id: 50_000)
        let buffer = controller.deltaBuffer
        let seconds = streamSeconds
        let producer = Task { await Self.produce(deltas, buffer: buffer, rate: 100, seconds: seconds) }
        await sleep(2)
        let viewport = controller.scrollView.contentView.bounds.height
        let cpuStart = ProcessStats.cpuSeconds()
        let wallStart = CACurrentMediaTime()
        watchdog.start()
        recorder.start()
        // Scroll up three viewports over half a second.
        var scrolled = 0.0
        await perFrame { dt, _ in
            let d = min(viewport * 3 - scrolled, viewport * 6 * dt)
            controller.userScroll(by: -d)
            scrolled += d
            return scrolled < viewport * 3
        }
        let released = !controller.following
        var unexpectedFollow = 0
        var maxDrift = 0.0
        var phases = 0
        var phaseStart = 0.0
        var reference: (id: Int, block: Int, top: CGFloat)?
        var velocity = 0.0
        var direction = -1.0
        var tookSnapshot = false
        await perFrame { [self] dt, elapsed in
            if controller.following { unexpectedFollow += 1 }
            let cycle = elapsed - phaseStart
            if cycle < 2 {
                // Reading: the top visible block must not move.
                if reference == nil, let top = controller.topVisible(),
                   let y = controller.drawnBlockTop(itemID: top.itemID, block: top.block) {
                    reference = (top.itemID, top.block, y)
                    phases += 1
                } else if let ref = reference, let y = controller.drawnBlockTop(itemID: ref.id, block: ref.block) {
                    maxDrift = max(maxDrift, abs(y - ref.top))
                }
                if !tookSnapshot && elapsed > 20 {
                    tookSnapshot = true
                    snapshot("S4-reading-released")
                    recorder.discardNext()
                }
            } else if cycle < 3 {
                reference = nil
                if velocity == 0 { velocity = 300 + rng.unit() * 1_200; direction = -direction }
                // Stay well clear of the bottom so the user never "returns" to it.
                if controller.distanceFromBottom < viewport * 2 { direction = -1 }
                controller.userScroll(by: direction * velocity * dt)
            } else {
                phaseStart = elapsed
                velocity = 0
            }
            return elapsed < seconds - 3
        }
        let intervals = recorder.stop()
        let cpu = (ProcessStats.cpuSeconds() - cpuStart) / (CACurrentMediaTime() - wallStart) * 100
        let watchdogReport = watchdog.stop()
        _ = await producer.value
        controller.endStreamingTail()
        controller.jumpToLatest(nil)
        await recorder.frames(3)
        let rejoinedByJump = controller.following
        let distanceAfterJump = controller.distanceFromBottom
        snapshot("S4-after-jump")
        // Release again, then return to the bottom by scrolling.
        controller.userScroll(by: -600)
        await recorder.frames(2)
        let releasedAgain = !controller.following
        await perFrame { dt, _ in
            controller.userScroll(by: 3_000 * dt)
            return controller.distanceFromBottom > 0.5
        }
        await recorder.frames(2)
        Report.write(S4Report(header: header("S4"), frames: FrameStats(intervals: intervals, nominal: nominal),
                              releasedOnScrollUp: released, unexpectedFollowFrames: unexpectedFollow,
                              maxAnchorDriftWhileReadingPt: maxDrift, readingPhases: phases,
                              rejoinedByJumpButton: rejoinedByJump, distanceAfterJump: distanceAfterJump,
                              rejoinedByScrollToBottom: releasedAgain && controller.following,
                              tailBytes: controller.tailSourceLength, cpuPercent: round2(cpu), watchdog: watchdogReport,
                              metrics: controller.metrics),
                     name: "S4")
    }

    // MARK: S5 anchor tests

    struct AnchorCase: Codable {
        var name: String
        var changedRowAboveViewport: Bool
        var rowHeightBefore: Double
        var rowHeightAfter: Double
        var driftPt: Double
        var visiblePixelsChangedPercent: Double
        var note: String
    }

    struct S5Report: Codable {
        var header: RunHeader
        var cases: [AnchorCase]
    }

    func measureAnchor(_ name: String, changedRow: () -> Int?, note: String, change: () async -> Void) async -> AnchorCase {
        guard let controller else { fatalError() }
        await recorder.frames(10)
        let top = controller.topVisible()!
        let before = controller.drawnBlockTop(itemID: top.itemID, block: top.block) ?? 0
        let topRow = controller.row(forItemID: top.itemID) ?? 0
        let row = changedRow() ?? -1
        let heightBefore = row >= 0 ? controller.rowRect(row).height : 0
        let bitmapBefore = Snapshots.bitmap(controller.scrollView)
        snapshot("S5-\(name)-before")
        await change()
        await sleep(0.3)
        await recorder.frames(10)
        let after = controller.drawnBlockTop(itemID: top.itemID, block: top.block) ?? .nan
        let newRow = row >= 0 ? row + (controller.row(forItemID: top.itemID)! - topRow) : -1
        let heightAfter = newRow >= 0 ? controller.rowRect(newRow).height : 0
        let bitmapAfter = Snapshots.bitmap(controller.scrollView)
        snapshot("S5-\(name)-after")
        let diff = (bitmapBefore != nil && bitmapAfter != nil) ? Snapshots.difference(bitmapBefore!, bitmapAfter!) : 1
        return AnchorCase(name: name, changedRowAboveViewport: row >= 0 && row < topRow, rowHeightBefore: heightBefore,
                          rowHeightAfter: heightAfter, driftPt: Double(after - before),
                          visiblePixelsChangedPercent: round2(diff * 100), note: note)
    }

    func runS5() async {
        // Hold back one image owned by a message in the middle of the transcript.
        let ownerIndex = workload.items.indices.first { $0 > 5_000 && !workload.items[$0].imageIDs.isEmpty }!
        let heldImage = workload.items[ownerIndex].imageIDs[0]
        await openTranscript(holdImages: [heldImage])
        guard let controller else { return }
        await waitForMeasureAll()
        await sleep(5.5)
        release()
        let ownerRow = controller.row(forItemID: workload.items[ownerIndex].id)!

        // (a) Expand a collapsed tool card above the viewport.
        var toolRow = ownerRow + 12
        var toolBlock = 0
        search: for row in (ownerRow + 6)..<(ownerRow + 400) {
            let id = controller.itemID(atRow: row)
            if let blocks = controller.blocksForTesting(itemID: id) {
                for (index, block) in blocks.enumerated() {
                    if case .tool = block, !controller.isExpanded(itemID: id, block: index) {
                        toolRow = row
                        toolBlock = index
                        break search
                    }
                }
            }
        }
        controller.scrollTo(y: controller.rowRect(toolRow + 2).minY + 37)
        await sleep(0.5)
        let toolID = controller.itemID(atRow: toolRow)
        var cases: [AnchorCase] = []
        cases.append(await measureAnchor("expand-tool-above", changedRow: { toolRow },
                                         note: "tool card in row \(toolRow), viewport top in row \(toolRow + 2)") {
            controller.toggle(itemID: toolID, block: toolBlock)
        })

        // (b) Late image arrives above the viewport.
        controller.scrollTo(y: controller.rowRect(ownerRow + 2).minY + 23)
        await sleep(0.5)
        cases.append(await measureAnchor("late-image-above", changedRow: { ownerRow },
                                         note: "image \(heldImage) in row \(ownerRow), held until now") {
            controller.releaseHeldImage(heldImage)
        })

        // (c) Prepend a page of 100 older messages while reading near the top.
        controller.scrollTo(y: controller.rowRect(3).minY + 11)
        await sleep(0.8)
        cases.append(await measureAnchor("prepend-100", changedRow: { nil },
                                         note: "100 older messages inserted at row 0") {
            await controller.prepend(workload.olderPage)
        })

        // (d) Expand a card above the viewport while the user is scrolling (momentum-like 900 pt/s).
        let midRow = controller.items.count / 2
        var cardRow = midRow
        var cardBlock = 0
        find: for row in midRow..<(midRow + 400) {
            let id = controller.itemID(atRow: row)
            for (index, block) in (controller.blocksForTesting(itemID: id) ?? []).enumerated() {
                if case .tool = block, !controller.isExpanded(itemID: id, block: index) { cardRow = row; cardBlock = index; break find }
            }
        }
        controller.scrollTo(y: controller.rowRect(cardRow + 3).minY)
        await sleep(0.5)
        await recorder.frames(5)
        let reference = controller.topVisible()!
        let referenceRow = controller.row(forItemID: reference.itemID)!
        // Track a row that stays on screen: the second visible row, block 0.
        let trackedID = controller.itemID(atRow: referenceRow + 1)
        let start = controller.drawnBlockTop(itemID: trackedID, block: 0)!
        var userTravel = 0.0
        var maxError = 0.0
        var toggled = false
        await perFrame { dt, elapsed in
            if let y = controller.drawnBlockTop(itemID: trackedID, block: 0) {
                maxError = max(maxError, abs(Double(y - start) + userTravel))
            }
            if elapsed > 0.25, !toggled {
                toggled = true
                controller.toggle(itemID: controller.itemID(atRow: cardRow), block: cardBlock)
            }
            let d = 900 * dt
            controller.userScroll(by: d)
            userTravel += d
            return elapsed < 0.6
        }
        cases.append(AnchorCase(name: "expand-tool-above-while-scrolling", changedRowAboveViewport: true, rowHeightBefore: 0,
                                rowHeightAfter: controller.rowRect(cardRow).height, driftPt: maxError,
                                visiblePixelsChangedPercent: -1,
                                note: "max |drawn displacement - user scroll distance| of a tracked row over 0.6 s at 900 pt/s"))
        Report.write(S5Report(header: header("S5"), cases: cases), name: "S5")
    }

    // MARK: S6 resize

    struct S6Report: Codable {
        var header: RunHeader
        var frames: FrameStats
        var maxAnchorBlockMovementDuringResizePt: Double
        var anchorDriftAfterRoundTripPt: Double
        var visiblePixelsChangedAfterRoundTripPercent: Double
        var watchdog: Watchdog.Report
        var metrics: SpikeTranscriptController.Metrics
    }

    func runS6() async {
        await openTranscript()
        guard let controller else { return }
        await waitForMeasureAll()
        await sleep(5.5)
        release()
        controller.scrollTo(y: controller.rowRect(controller.items.count / 2).minY + 37)
        await sleep(0.8)
        await recorder.frames(5)
        let top = controller.topVisible()!
        let before = controller.drawnBlockTop(itemID: top.itemID, block: top.block)!
        let bitmapBefore = Snapshots.bitmap(controller.scrollView)
        snapshot("S6-900-before")
        let origin = app.window.frame.origin
        let height = app.window.frame.height
        var maxMove = 0.0
        watchdog.start()
        recorder.start()
        await perFrame { [self] _, elapsed in
            let t = min(elapsed, 2)
            let fraction = t < 1 ? t : 2 - t
            app.window.setFrame(NSRect(x: origin.x, y: origin.y, width: (900 + 500 * fraction).rounded(), height: height),
                                display: true)
            if let y = controller.drawnBlockTop(itemID: top.itemID, block: top.block) { maxMove = max(maxMove, abs(Double(y - before))) }
            return elapsed < 2
        }
        app.window.setFrame(NSRect(x: origin.x, y: origin.y, width: 900, height: height), display: true)
        let intervals = recorder.stop()
        let watchdogReport = watchdog.stop()
        await sleep(0.6)
        await waitForMeasureAll()
        let after = controller.drawnBlockTop(itemID: top.itemID, block: top.block) ?? .nan
        let bitmapAfter = Snapshots.bitmap(controller.scrollView)
        snapshot("S6-900-after")
        // Static snapshot at 1,400 points for visual re-wrap check (outside the measured window).
        app.window.setFrame(NSRect(x: origin.x, y: origin.y, width: 1400, height: height), display: true)
        await sleep(0.5)
        await recorder.frames(5)
        snapshot("S6-1400")
        app.window.setFrame(NSRect(x: origin.x, y: origin.y, width: 900, height: height), display: true)
        await sleep(0.5)
        let diff = (bitmapBefore != nil && bitmapAfter != nil) ? Snapshots.difference(bitmapBefore!, bitmapAfter!) : 1
        Report.write(S6Report(header: header("S6"), frames: FrameStats(intervals: intervals, nominal: nominal),
                              maxAnchorBlockMovementDuringResizePt: maxMove, anchorDriftAfterRoundTripPt: Double(after - before),
                              visiblePixelsChangedAfterRoundTripPercent: round2(diff * 100), watchdog: watchdogReport,
                              metrics: controller.metrics),
                     name: "S6")
    }

    // MARK: S7 selection, copy and find

    struct FindResult: Codable {
        var query: String
        var expectedItemID: Int
        var foundItemID: Int?
        var expandedCollapsedCard: Bool
        var visibleAfterReveal: Bool
        var milliseconds: Double
        var rowsAway: Int
    }

    struct S7Report: Codable {
        var header: RunHeader
        var startRow: Int
        var rowsSpanned: Int
        var dragMilliseconds: Double
        var autoscrollFrames: FrameStats
        var copyMilliseconds: Double
        var copiedCharacters: Int
        var codeBlocksInSpan: Int
        var codeBlocksCopiedVerbatim: Int
        var collapsedCardsInSpan: Int
        var collapsedCardsHeaderOnly: Int
        var tablesInSpan: Int
        var tablesCopiedAsTSV: Int
        var middleBlocksChecked: Int
        var middleBlocksMissing: Int
        var startsAtDragOrigin: Bool
        var survivedReuse: Bool
        var visibleRowsHighlightedAfterReturn: Int
        var finds: [FindResult]
    }

    func mouse(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int = 1) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: app.window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        app.window.sendEvent(event)
    }

    func runS7() async {
        await openTranscript()
        guard let controller else { return }
        await waitForMeasureAll()
        while !controller.searchIndexReady { await sleep(0.05) }
        await sleep(5.5)
        release()
        // Pick a 24-row window with code blocks, a collapsed tool card and a table.
        var startRow = 4_000
        for row in stride(from: 4_000, to: 9_000, by: 1) {
            var code = 0, collapsed = 0, tables = 0
            for r in row..<(row + 22) {
                let id = controller.itemID(atRow: r)
                for (index, block) in (controller.blocksForTesting(itemID: id) ?? []).enumerated() {
                    switch block {
                    case .code: code += 1
                    case .tool, .reasoning: if !controller.isExpanded(itemID: id, block: index) { collapsed += 1 }
                    case .table: tables += 1
                    default: break
                    }
                }
            }
            if code >= 2, collapsed >= 2, tables >= 1, controller.itemID(atRow: row) % 2 == 0 { startRow = row; break }
        }
        controller.scrollTo(y: controller.rowRect(startRow).minY - 30)
        await sleep(0.5)
        await recorder.frames(5)
        let startID = controller.itemID(atRow: startRow)
        guard var downPoint = controller.windowPoint(itemID: startID, block: 0, offset: 0) else { return }
        downPoint.x -= 10  // just left of the first glyph: selection starts at offset 0
        let scrollFrame = controller.scrollView.convert(controller.scrollView.bounds, to: nil)
        let outside = NSPoint(x: scrollFrame.midX, y: scrollFrame.minY - 40)  // below the view (window coordinates)
        let dragStart = CACurrentMediaTime()
        mouse(.leftMouseDown, downPoint)
        mouse(.leftMouseDragged, NSPoint(x: downPoint.x + 20, y: downPoint.y - 30))
        recorder.start()
        var tookMidSnapshot = false
        await perFrame { [self] _, elapsed in
            mouse(.leftMouseDragged, outside)
            let rows = controller.selectionSpan?.rows ?? 0
            if rows >= 12, !tookMidSnapshot {
                tookMidSnapshot = true
                snapshot("S7-autoscroll-mid")
                recorder.discardNext()
            }
            return rows < 26 && elapsed < 30
        }
        let autoscrollIntervals = recorder.stop()
        let inside = NSPoint(x: scrollFrame.midX, y: scrollFrame.minY + 25)  // back inside, near the bottom edge
        mouse(.leftMouseDragged, inside)
        mouse(.leftMouseUp, inside)
        let dragMs = (CACurrentMediaTime() - dragStart) * 1000
        await recorder.frames(3)
        snapshot("S7-selection-done")
        let span = controller.selectionSpan
        let copyStart = CACurrentMediaTime()
        controller.copySelection()
        let copied = controller.pasteboard.string(forType: .string) ?? ""
        let copyMs = (CACurrentMediaTime() - copyStart) * 1000
        Report.writeText(copied, name: "S7-copied.txt")

        // Verify against the model: middle rows must be complete; code verbatim; collapsed cards header only.
        var code = 0, codeOK = 0, collapsed = 0, collapsedOK = 0, tables = 0, tablesOK = 0, checked = 0, missing = 0
        if let span, let first = controller.row(forItemID: span.startItem), let last = controller.row(forItemID: span.endItem) {
            for row in first...last {
                let id = controller.itemID(atRow: row)
                for (index, block) in (controller.blocksForTesting(itemID: id) ?? []).enumerated() {
                    let expanded = controller.isExpanded(itemID: id, block: index)
                    let plain = block.plainText(expanded: expanded)
                    let middle = row > first && row < last
                    if middle {
                        checked += 1
                        if !copied.contains(plain) { missing += 1 }
                    }
                    switch block {
                    case .code(let mono) where middle:
                        code += 1
                        if copied.contains(mono.text) { codeOK += 1 }
                    case .tool(let tool, _) where middle && !expanded:
                        collapsed += 1
                        if copied.contains(block.headerText(expanded: false)) && !copied.contains(tool.output) { collapsedOK += 1 }
                    case .table where middle:
                        tables += 1
                        if copied.contains(plain) && plain.contains("\t") { tablesOK += 1 }
                    default: break
                    }
                }
            }
        }
        let firstText = controller.blocksForTesting(itemID: startID)?.first?.plainText(expanded: true) ?? ""
        let startsAtOrigin = copied.hasPrefix(String(firstText.prefix(40)))

        // Scroll far away (rows are reused for other items) and back; selection must survive.
        let savedY = controller.scrollView.contentView.bounds.minY
        controller.scrollTo(y: savedY - 30_000)
        await recorder.frames(10)
        controller.scrollTo(y: savedY + 30_000)
        await recorder.frames(10)
        controller.scrollTo(y: savedY)
        await recorder.frames(10)
        snapshot("S7-after-reuse")
        controller.copySelection()
        let again = controller.pasteboard.string(forType: .string) ?? ""
        let highlighted = controller.visibleRowsDrawingSelection

        // Find: prose in a far message, then text inside a collapsed tool card's output.
        var finds: [FindResult] = []
        let proseTarget = workload.items[startRow - 3_000 > 0 ? startRow - 3_000 : 100]
        if let text = controller.blocksForTesting(itemID: proseTarget.id)?.first?.plainText(expanded: true) {
            let words = text.split(separator: " ").prefix(9).dropFirst(2).joined(separator: " ")
            finds.append(await find(words, expected: proseTarget.id, from: startRow, name: "prose"))
        }
        if let toolTarget = workload.items[(startRow + 2_500)...].first(where: { item in
            item.parts.contains { if case .tool(let tool) = $0 { !tool.expandedByDefault && tool.output.count > 300 } else { false } }
        }), case .tool(let tool)? = toolTarget.parts.first(where: { if case .tool(let t) = $0 { !t.expandedByDefault && t.output.count > 300 } else { false } }) {
            let output = tool.output
            let start = output.index(output.startIndex, offsetBy: output.count / 2)
            let query = String(output[start...].prefix(70))
            finds.append(await find(query, expected: toolTarget.id, from: startRow, name: "tool-output"))
        }

        Report.write(S7Report(header: header("S7"), startRow: startRow, rowsSpanned: span?.rows ?? 0,
                              dragMilliseconds: round2(dragMs),
                              autoscrollFrames: FrameStats(intervals: autoscrollIntervals, nominal: nominal),
                              copyMilliseconds: round2(copyMs), copiedCharacters: copied.count, codeBlocksInSpan: code,
                              codeBlocksCopiedVerbatim: codeOK, collapsedCardsInSpan: collapsed,
                              collapsedCardsHeaderOnly: collapsedOK, tablesInSpan: tables, tablesCopiedAsTSV: tablesOK,
                              middleBlocksChecked: checked, middleBlocksMissing: missing, startsAtDragOrigin: startsAtOrigin,
                              survivedReuse: again == copied && !copied.isEmpty, visibleRowsHighlightedAfterReturn: highlighted,
                              finds: finds),
                     name: "S7")
    }

    func find(_ query: String, expected: Int, from row: Int, name: String) async -> FindResult {
        guard let controller else { fatalError() }
        controller.clearSelection()
        let start = CACurrentMediaTime()
        let match = await controller.findNext(query)
        let ms = (CACurrentMediaTime() - start) * 1000
        await recorder.frames(4)
        var visible = false
        if let match, let rect = controller.visibleRect(of: match) {
            visible = controller.scrollView.bounds.intersects(rect)
        }
        snapshot("S7-find-\(name)")
        let expandedCard: Bool = {
            guard let match, let blocks = controller.blocksForTesting(itemID: match.itemID), match.block < blocks.count,
                  case .tool = blocks[match.block] else { return false }
            return controller.isExpanded(itemID: match.itemID, block: match.block)
        }()
        return FindResult(query: query, expectedItemID: expected, foundItemID: match?.itemID, expandedCollapsedCard: expandedCard,
                          visibleAfterReveal: visible, milliseconds: round2(ms),
                          rowsAway: abs((controller.row(forItemID: expected) ?? 0) - row))
    }

    // MARK: S8 memory

    struct S8Report: Codable {
        var header: RunHeader
        var afterScenarios: Memory
        var cycles: [Memory]
        var afterCyclesIdle: Memory
        var afterCloseIdle: Memory
    }

    func runS8() async {
        let afterScenarios = Memory.now()
        var cycles: [Memory] = []
        for _ in 0..<20 {
            await openTranscript()
            await sleep(1.5)
            closeTranscript()
            await sleep(0.3)
            cycles.append(Memory.now())
        }
        await openTranscript()
        await sleep(3)
        let afterCycles = Memory.now()
        closeTranscript()
        await sleep(2)
        Report.write(S8Report(header: header("S8"), afterScenarios: afterScenarios, cycles: cycles, afterCyclesIdle: afterCycles,
                              afterCloseIdle: Memory.now()),
                     name: "S8")
    }
}
