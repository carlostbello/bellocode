// G1-A harness instruments: display-link frame recorder, main-thread watchdog, CPU and memory probes, JSON reports
// and in-process PNG snapshots. Measurement only; not shipped.

import AppKit
import Darwin
import QuartzCore
import Synchronization

// MARK: - Frame recorder

/// Records display-link callback timestamps. A main-thread hitch delays the callback, so intervals capture it.
@MainActor
final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private(set) var stamps: [Double] = []
    private var recording = false
    /// Called on every tick (recording or not) with the link, for scroll drivers and latency probes.
    var onTick: ((CADisplayLink) -> Void)?
    private(set) var lastDuration: Double = 0

    func attach(to view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func detach() {
        link?.invalidate()
        link = nil
        onTick = nil
    }

    func start() { stamps.removeAll(keepingCapacity: true); recording = true }

    func stop() -> FrameStats {
        recording = false
        return FrameStats(stamps: stamps, nominal: lastDuration)
    }

    @objc private func tick(_ link: CADisplayLink) {
        lastDuration = link.duration
        if recording { stamps.append(link.timestamp) }
        onTick?(link)
    }
}

struct FrameStats: Encodable {
    var frames = 0
    var durationS = 0.0
    var nominalIntervalMS = 0.0
    var p50MS = 0.0
    var p95MS = 0.0
    var p99MS = 0.0
    var maxMS = 0.0
    var over16_7 = 0
    var over33 = 0
    /// Frames that should have been presented but were not: sum of (interval / nominal − 1), rounded.
    var missedFrames = 0
    var missedPercent = 0.0

    init(stamps: [Double], nominal: Double) {
        guard stamps.count > 2 else { return }
        var intervals: [Double] = []
        intervals.reserveCapacity(stamps.count)
        for i in 1..<stamps.count { intervals.append((stamps[i] - stamps[i - 1]) * 1_000) }
        frames = intervals.count
        durationS = stamps.last! - stamps.first!
        let nominalMS = nominal > 0 ? nominal * 1_000 : 1_000 / 120
        nominalIntervalMS = nominalMS
        let sorted = intervals.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        p50MS = pct(0.50); p95MS = pct(0.95); p99MS = pct(0.99); maxMS = sorted.last!
        over16_7 = intervals.filter { $0 > 16.7 }.count
        over33 = intervals.filter { $0 > 33.4 }.count
        missedFrames = intervals.reduce(0) { $0 + max(0, Int(($1 / nominalMS).rounded()) - 1) }
        let expected = durationS * 1_000 / nominalMS
        missedPercent = expected > 0 ? Double(missedFrames) / expected * 100 : 0
    }
}

// MARK: - Watchdog

/// Pings the main queue from a background thread every 4 ms and records how long each ping waited.
final class Watchdog: Sendable {
    private struct State {
        var running = false
        var latencies: [Double] = []
    }
    private let state = Mutex(State())

    func start() {
        state.withLock { $0.running = true; $0.latencies.removeAll() }
        let thread = Thread { [self] in self.loop() }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func loop() {
        while state.withLock({ $0.running }) {
            let sent = CACurrentMediaTime()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { [self] in
                let latency = (CACurrentMediaTime() - sent) * 1_000
                state.withLock { $0.latencies.append(latency) }
                done.signal()
            }
            // Wait for the pong (bounded so stop() always ends the loop).
            while done.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
                if !state.withLock({ $0.running }) { return }
            }
            usleep(4_000)
        }
    }

    func stop() -> StallStats {
        let latencies = state.withLock { s -> [Double] in s.running = false; return s.latencies }
        return StallStats(latencies)
    }
}

struct StallStats: Encodable {
    var pings = 0
    var p99MS = 0.0
    var maxMS = 0.0
    var stallsOver50MS = 0
    var stallsOver100MS = 0
    var stallsOver250MS = 0

    init(_ latencies: [Double]) {
        guard !latencies.isEmpty else { return }
        let sorted = latencies.sorted()
        pings = sorted.count
        p99MS = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        maxMS = sorted.last!
        stallsOver50MS = sorted.filter { $0 > 50 }.count
        stallsOver100MS = sorted.filter { $0 > 100 }.count
        stallsOver250MS = sorted.filter { $0 > 250 }.count
    }
}

// MARK: - CPU and memory

enum Probe {
    /// User + system CPU seconds consumed by this process.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    struct Memory: Encodable {
        var residentMB: Double
        var footprintMB: Double
    }

    static func memory() -> Memory {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Memory(residentMB: -1, footprintMB: -1) }
        return Memory(residentMB: Double(info.resident_size) / 1_048_576, footprintMB: Double(info.phys_footprint) / 1_048_576)
    }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

// MARK: - Reports and snapshots

@MainActor
enum Output {
    static var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    static var reportDirectory: URL { root.appending(path: "build/spikes/G1-A") }
    static var snapshotDirectory: URL { root.appending(path: "build/snapshots") }

    static func write(_ name: String, _ report: some Encodable) {
        try? FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        do {
            let data = try encoder.encode(report)
            try data.write(to: reportDirectory.appending(path: "\(name).json"))
            log("wrote \(reportDirectory.appending(path: "\(name).json").path)")
        } catch {
            log("FAILED to write report \(name): \(error)")
        }
    }

    static func snapshot(_ view: NSView, _ name: String) {
        try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = snapshotDirectory.appending(path: "G1-A-\(name).png")
        try? data.write(to: url)
        log("snapshot \(url.path)")
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[G1-A] \(message)\n".utf8))
}
