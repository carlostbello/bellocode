import AppKit
import QuartzCore
import CoreGraphics
import TranscriptKit

/// Per-frame attribution of main-thread time (TranscriptProfiler phases) and peak memory sampling during a traversal.
@MainActor
final class FrameAttribution {
    struct PhaseTotals: Codable {
        var frames = 0
        /// Milliseconds per phase, summed over the frames.
        var phaseMs: [String: Double] = [:]
        /// Interval minus nominal minus attributed time, summed (AppKit/CA work outside our phases, other threads'
        /// contention, scheduling).
        var unattributedMs = 0.0

        mutating func add(_ phases: [Double], interval: Double, nominal: Double) {
            frames += 1
            var attributed = 0.0
            for phase in TranscriptProfiler.Phase.allCases {
                let ms = phases[phase.rawValue]
                phaseMs[phase.name, default: 0] += ms
                attributed += ms
            }
            unattributedMs += max(0, interval * 1000 - nominal * 1000 - attributed)
        }

        func rounded() -> PhaseTotals {
            var copy = self
            copy.phaseMs = phaseMs.mapValues(round2)
            copy.unattributedMs = round2(unattributedMs)
            return copy
        }
    }

    struct SlowFrame: Codable {
        var intervalMs: Double
        var phaseMs: [String: Double]
        var at: Double
    }

    struct Report: Codable {
        var all = PhaseTotals()
        var over16_7ms = PhaseTotals()
        var over33ms = PhaseTotals()
        var worst: [SlowFrame] = []
        var counters: [String: Int] = [:]
    }

    private(set) var report = Report()
    private let nominal: Double
    private var elapsed = 0.0

    init(nominal: Double) {
        self.nominal = nominal
        TranscriptProfiler.shared.isEnabled = true
        _ = TranscriptProfiler.shared.takeFrame()
        TranscriptProfiler.shared.resetCounters()
    }

    /// Called once per display frame with the interval that just ended.
    func frame(interval: Double) {
        let phases = TranscriptProfiler.shared.takeFrame()
        elapsed += interval
        report.all.add(phases, interval: interval, nominal: nominal)
        if interval * 1000 > 16.7 { report.over16_7ms.add(phases, interval: interval, nominal: nominal) }
        if interval * 1000 > 33.4 {
            report.over33ms.add(phases, interval: interval, nominal: nominal)
            var named: [String: Double] = [:]
            for phase in TranscriptProfiler.Phase.allCases where phases[phase.rawValue] > 0.05 {
                named[phase.name] = round2(phases[phase.rawValue])
            }
            report.worst.append(SlowFrame(intervalMs: round2(interval * 1000), phaseMs: named, at: round2(elapsed)))
            report.worst.sort { $0.intervalMs > $1.intervalMs }
            if report.worst.count > 25 { report.worst.removeLast() }
        }
    }

    func finish() -> Report {
        TranscriptProfiler.shared.isEnabled = false
        var result = report
        result.all = report.all.rounded()
        result.over16_7ms = report.over16_7ms.rounded()
        result.over33ms = report.over33ms.rounded()
        result.counters = TranscriptProfiler.shared.counters
        return result
    }
}

/// Samples footprint and live malloc every `every` frames and keeps the cache report at the footprint peak.
@MainActor
final class PeakSampler {
    struct Report: Codable {
        var peakFootprint: Memory?
        var peakMalloc: Memory?
        var cachesAtPeak: TranscriptCacheReport?
        var maxCaches: TranscriptCacheReport?
        var samples = 0
        var maxSampleMs = 0.0
        var atStart: Memory?
        /// Seconds into the traversal at which the footprint peak was sampled.
        var peakAtS = 0.0
    }

    private(set) var report = Report()
    private var frames = 0
    private let every: Int

    private let started = CACurrentMediaTime()

    init(every: Int = 30) {
        self.every = every
        report.atStart = Memory.now()
    }

    func frame(_ controller: TranscriptController) {
        frames += 1
        guard frames % every == 0 else { return }
        // Footprint (task_info) is cheap; malloc statistics and the cache report are taken at new peaks and every
        // 20th sample. The sampler's own cost is reported.
        let start = CACurrentMediaTime()
        let footprint = ProcessStats.memory().footprint
        report.samples += 1
        if footprint > (report.peakFootprint?.footprintMB ?? 0) + 5 || report.samples % 20 == 0 {
            let memory = Memory.now()
            let caches = controller.cacheReport()
            if memory.footprintMB > (report.peakFootprint?.footprintMB ?? 0) {
                report.peakFootprint = memory
                report.cachesAtPeak = caches
                report.peakAtS = round2(CACurrentMediaTime() - started)
            }
            if memory.mallocInUseMB > (report.peakMalloc?.mallocInUseMB ?? 0) { report.peakMalloc = memory }
            var max = report.maxCaches ?? caches
            max.layoutCount = Swift.max(max.layoutCount, caches.layoutCount)
            max.layoutCost = Swift.max(max.layoutCost, caches.layoutCost)
            max.parseCacheEntries = Swift.max(max.parseCacheEntries, caches.parseCacheEntries)
            max.parseCacheCost = Swift.max(max.parseCacheCost, caches.parseCacheCost)
            max.highlightCacheCost = Swift.max(max.highlightCacheCost, caches.highlightCacheCost)
            max.imageBytes = Swift.max(max.imageBytes, caches.imageBytes)
            max.availableCellViews = Swift.max(max.availableCellViews, caches.availableCellViews)
            max.liveCellViews = Swift.max(max.liveCellViews, caches.liveCellViews)
        max.liveRowViews = Swift.max(max.liveRowViews, caches.liveRowViews)
            max.canvasBackingBytes = Swift.max(max.canvasBackingBytes, caches.canvasBackingBytes)
            report.maxCaches = max
        }
        report.maxSampleMs = Swift.max(report.maxSampleMs, round2((CACurrentMediaTime() - start) * 1000))
    }
}

enum DisplayInfo {
    struct Info: Codable {
        var screenLocked: Bool?
        var backingScale: Double
        var maximumFPS: Int
        var displayName: String
        var loadAverage1m: Double
    }

    @MainActor
    static func current(window: NSWindow) -> Info {
        var locked: Bool?
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            locked = (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
        }
        var load = [0.0, 0.0, 0.0]
        getloadavg(&load, 3)
        let screen = window.screen ?? NSScreen.main
        return Info(
            screenLocked: locked, backingScale: Double(window.backingScaleFactor), maximumFPS: screen?.maximumFramesPerSecond ?? 0,
            displayName: screen?.localizedName ?? "", loadAverage1m: round2(load[0]))
    }
}

extension ScenarioRunner {
    struct ProfileReport: Codable {
        var header: RunHeader
        var display: DisplayInfo.Info
        var fraction: Double
        var down: FrameStats
        var attribution: FrameAttribution.Report
        var peak: PeakSampler.Report
        /// Live malloc released by dropping each cache in turn at the end of the traversal (MB), then by closing the
        /// transcript; `floor` is the process before the transcript was ever mounted (mock server + Engine + thread).
        var mallocReleasedMB: [String: Double]
        var memoryBeforePurge: Memory
        var memoryAfterClose: Memory
        var floor: Memory
        var cachesBeforePurge: TranscriptCacheReport
        var metrics: TranscriptController.Metrics
    }

    /// Profile: downward traversal at 3× over `--fraction` of the document with per-frame attribution and peak
    /// sampling, then live memory attributed by purging each cache. Report: build/transcript-bench/P.json.
    func runProfile() async {
        let fraction = arguments.firstIndex(of: "--fraction").flatMap { Double(arguments[$0 + 1]) } ?? 1
        if thread?.hasOlder == true { _ = await loadAll() }
        await sleep(1)
        let floor = Memory.now()
        mount()
        await controller?.settle()
        await waitForMeasureAll()
        guard let controller else { return }
        controller.noteUserScroll(deltaY: 1)
        controller.scrollTo(y: 0)
        await sleep(1)
        let documentHeight = Double(controller.rowRect(controller.rows.count - 1).maxY)
        let stopAt = documentHeight * fraction
        let attribution = FrameAttribution(nominal: nominal)
        let sampler = PeakSampler()
        var flick = Flick()
        recorder.start()
        var first = true
        let sampler2: StackSampler? = arguments.contains("--sample") ? StackSampler() : nil
        sampler2?.start()
        let pauseAbove = arguments.firstIndex(of: "--pause-above").flatMap { Double(arguments[$0 + 1]) }
        var paused = false
        await perFrame { [self] dt, _ in
            if first { first = false; _ = TranscriptProfiler.shared.takeFrame() } else { attribution.frame(interval: dt) }
            if dt > 0.0334 { let now = CACurrentMediaTime(); sampler2?.keep(from: now - dt, to: now) }
            sampler.frame(controller)
            if let pauseAbove, !paused, ProcessStats.memory().footprint > pauseAbove {
                // Freeze mid-traversal so heap/footprint can inspect the transient peak.
                paused = true
                log("PAUSE pid \(getpid()) at \(Int(ProcessStats.memory().footprint)) MB")
                Thread.sleep(forTimeInterval: 45)
            }
            controller.userScroll(by: flick.step(dt, rng: &rng, scale: scrollSpeed))
            return controller.distanceFromBottom > 1 && Double(controller.scrollView.contentView.bounds.maxY) < stopAt
        }
        let down = recorder.stop()
        let profile = attribution.finish()
        if let sampler2 {
            sampler2.stop()
            sampler2.writeSamples(to: Report.directory.appending(path: "P-samples.txt"))
            log("SAMPLES pid \(getpid()) kept \(sampler2.keptSamples) samples from \(sampler2.keptFrames) slow frames; taken \(sampler2.taken) in \(Int(down.reduce(0, +))) s")
            await sleep(90)
        }
        await controller.settle()
        await sleep(1)
        if let hold = arguments.firstIndex(of: "--hold").flatMap({ Double(arguments[$0 + 1]) }) {
            // Inspect the live process at the peak: heap/vmmap/footprint <pid>.
            log("HOLD pid \(getpid()) for \(Int(hold)) s")
            await sleep(hold)
        }
        let before = Memory.now()
        let caches = controller.cacheReport()
        var released: [String: Double] = [:]
        var last = before.mallocInUseMB
        for kind in TranscriptCacheKind.allCases {
            controller.purge(kind)
            await sleep(0.3)
            let now = Memory.now().mallocInUseMB
            released[kind.rawValue] = round2(last - now)
            last = now
        }
        let metrics = controller.metrics
        unmount()
        await sleep(1)
        let afterClose = Memory.now()
        released["closeTranscript"] = round2(last - afterClose.mallocInUseMB)
        Report.write(
            ProfileReport(
                header: header("P"), display: DisplayInfo.current(window: window), fraction: fraction,
                down: FrameStats(intervals: down, nominal: nominal), attribution: profile, peak: sampler.report,
                mallocReleasedMB: released, memoryBeforePurge: before, memoryAfterClose: afterClose, floor: floor,
                cachesBeforePurge: caches, metrics: metrics),
            name: "P")
        log("P: >33 ms \(FrameStats(intervals: down, nominal: nominal).over33ms), peak \(sampler.report.peakFootprint?.footprintMB ?? 0) MB")
    }
}
