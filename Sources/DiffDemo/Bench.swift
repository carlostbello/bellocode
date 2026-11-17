import AppKit
import DiffKit
import QuartzCore

/// Scroll benchmarks (release build, window on screen): a 10,000-changed-line diff and a 100,000-line file, unified,
/// side by side and wrapped. Each scenario scrolls the whole document top to bottom and back at a fixed speed per
/// display frame, recording display-link intervals (a main-thread stall shows as a long interval) and the diff
/// view's own draw time. Report: build/snapshots/diff-bench.json.
@MainActor
struct Bench {
    let window: NSWindow
    let arguments: [String]

    struct Result: Codable {
        var name: String
        var rows: Int
        var contentHeight: Double
        var buildMs: Double
        var frames: Int
        var nominalMs: Double
        var p50Ms: Double
        var p95Ms: Double
        var p99Ms: Double
        var maxMs: Double
        var over16_7ms: Int
        var over33ms: Int
        var drawP95Ms: Double
        var drawMaxMs: Double
    }

    func run() async -> Bool {
        let tenK = Samples.large(total: 20_000, changed: 10_000)
        let huge = Samples.hugeFile(lines: 100_000)
        let scenarios: [(String, [DiffFile], DiffViewOptions)] = [
            ("10k-changed-unified", [tenK], options(.unified)),
            ("10k-changed-split", [tenK], options(.split)),
            ("10k-changed-wrapped", [tenK], options(.unified, wraps: true)),
            ("100k-line-file-unified", [huge], options(.unified)),
            ("100k-line-file-split", [huge], options(.split)),
        ]
        var results: [Result] = []
        for (name, files, options) in scenarios {
            guard let result = await measure(name, files: files, options: options) else { return false }
            print(String(format: "%@: rows %d, build %.0f ms, frames %d, p50 %.1f p95 %.1f p99 %.1f max %.1f ms, >16.7: %d, >33: %d, draw p95 %.2f max %.2f ms",
                         name, result.rows, result.buildMs, result.frames, result.p50Ms, result.p95Ms, result.p99Ms, result.maxMs,
                         result.over16_7ms, result.over33ms, result.drawP95Ms, result.drawMaxMs))
            results.append(result)
        }
        let url = URL(fileURLWithPath: "build/snapshots/diff-bench.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(results).write(to: url)
        print("wrote \(url.path)")
        return results.allSatisfy { $0.over33ms == 0 }
    }

    private func options(_ layout: DiffLayout, wraps: Bool = false) -> DiffViewOptions {
        var options = DiffViewOptions()
        options.layout = layout
        options.wraps = wraps
        return options
    }

    private func measure(_ name: String, files: [DiffFile], options: DiffViewOptions) async -> Result? {
        let controller = DiffViewController()
        controller.options = options
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1200, height: 900))
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        let start = ContinuousClock.now
        controller.display(files)
        for _ in 0..<2_000 where controller.isBuilding || controller.rowCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        let build = ContinuousClock.now - start
        try? await Task.sleep(for: .milliseconds(400))
        let recorder = FrameRecorder(view: controller.view)
        // Warm up, then scroll down and back up at 60 pt per frame (≈7,200 pt/s at 120 Hz: a fast flick).
        await recorder.frames(10)
        let height = controller.contentHeight
        let step: CGFloat = 60
        var y: CGFloat = 0
        var draws: [Double] = []
        recorder.start()
        var direction: CGFloat = 1
        var passes = 0
        let deadline = ContinuousClock.now + .seconds(40)
        while passes < 2, ContinuousClock.now < deadline {
            y += step * direction
            if y >= height - 900 { direction = -1; passes += 1 }
            if y <= 0, direction < 0 { passes += 1; direction = 1 }
            controller.scroll(toY: y)
            await recorder.nextFrame()
            draws.append(Double(controller.lastDrawDuration.components.attoseconds) / 1e15 + Double(controller.lastDrawDuration.components.seconds) * 1000)
        }
        let intervals = recorder.stop()
        recorder.invalidate()
        window.contentViewController = nil
        guard !intervals.isEmpty else { print("FAIL \(name): no frames (is the display asleep?)"); return nil }
        let ms = intervals.map { $0 * 1000 }.sorted()
        func pct(_ values: [Double], _ p: Double) -> Double { values.isEmpty ? 0 : values[min(values.count - 1, Int(Double(values.count - 1) * p))] }
        let nominal = pct(ms, 0.5)
        let drawsSorted = draws.sorted()
        return Result(
            name: name, rows: controller.rowCount, contentHeight: Double(height), buildMs: Double(build.components.attoseconds) / 1e15 + Double(build.components.seconds) * 1000,
            frames: ms.count, nominalMs: nominal, p50Ms: pct(ms, 0.5), p95Ms: pct(ms, 0.95), p99Ms: pct(ms, 0.99), maxMs: ms.last ?? 0,
            over16_7ms: ms.filter { $0 > 16.7 }.count, over33ms: ms.filter { $0 > 33.4 }.count, drawP95Ms: pct(drawsSorted, 0.95),
            drawMaxMs: drawsSorted.last ?? 0)
    }
}

/// Display-link frame intervals on the main thread (as TranscriptDemo's recorder).
@MainActor
final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private var intervals: [Double] = []
    private var last: Double?
    private var recording = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(view: NSView) {
        super.init()
        link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        if recording, let last { intervals.append(link.timestamp - last) }
        last = link.timestamp
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func start() {
        intervals.removeAll()
        last = nil
        recording = true
    }

    func stop() -> [Double] {
        recording = false
        return intervals
    }

    func nextFrame() async { await withCheckedContinuation { waiters.append($0) } }
    func frames(_ count: Int) async { for _ in 0..<count { await nextFrame() } }
}
