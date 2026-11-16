// SPIKE G1-B measurement tools: display-link frame recorder, main-thread watchdog, CPU and memory, snapshots, JSON.

import AppKit
import Darwin
import QuartzCore
import Synchronization

struct FrameStats: Codable {
    var frames = 0
    var p50Ms = 0.0
    var p95Ms = 0.0
    var p99Ms = 0.0
    var maxMs = 0.0
    var over16_7ms = 0
    var over33ms = 0
    /// Sum over intervals of (round(interval / nominal) - 1): vsyncs the main thread missed.
    var missedVsyncs = 0
    var nominalMs = 0.0
    var durationS = 0.0

    init() {}

    init(intervals: [Double], nominal: Double) {
        guard !intervals.isEmpty else { return }
        let ms = intervals.map { $0 * 1000 }.sorted()
        func pct(_ p: Double) -> Double { ms[min(ms.count - 1, Int(Double(ms.count - 1) * p))] }
        frames = ms.count
        p50Ms = pct(0.5)
        p95Ms = pct(0.95)
        p99Ms = pct(0.99)
        maxMs = ms.last ?? 0
        over16_7ms = ms.filter { $0 > 16.7 }.count
        over33ms = ms.filter { $0 > 33.4 }.count
        missedVsyncs = intervals.reduce(0) { $0 + max(0, Int(($1 / nominal).rounded()) - 1) }
        nominalMs = nominal * 1000
        durationS = intervals.reduce(0, +)
    }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

/// Records display-link callback intervals on the main thread. A main-thread stall shows up as a long interval.
@MainActor
final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private(set) var intervals: [Double] = []
    private(set) var tags: [Bool] = []
    private var last: Double?
    private var recording = false
    private var discard = 0
    var tagProvider: (() -> Bool)?
    var onFrame: ((CADisplayLink) -> Void)?
    private var waiters: [CheckedContinuation<Double, Never>] = []

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
        let timestamp = link.timestamp
        if discard > 0 {
            discard -= 1
        } else if recording, let last {
            intervals.append(timestamp - last)
            tags.append(tagProvider?() ?? false)
        }
        last = timestamp
        onFrame?(link)
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: timestamp) }
    }

    /// Drops the next interval (used right after a snapshot, which is not part of the workload).
    func discardNext() { discard = 1 }

    func start() {
        intervals.removeAll()
        tags.removeAll()
        last = nil
        recording = true
    }

    func stop() -> [Double] {
        recording = false
        return intervals
    }

    func nextFrame() async -> Double {
        await withCheckedContinuation { waiters.append($0) }
    }

    func frames(_ count: Int) async {
        for _ in 0..<count { _ = await nextFrame() }
    }
}

/// Background thread that pings the main queue every 5 ms and records how long each ping waited.
final class Watchdog: Sendable {
    private struct State {
        var running = false
        var latencies: [Double] = []
    }

    private let state = Mutex(State())

    func start() {
        state.withLock { $0 = State(running: true) }
        Thread.detachNewThread { [self] in
            while state.withLock({ $0.running }) {
                let sent = CACurrentMediaTime()
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { semaphore.signal() }
                semaphore.wait()
                let latency = CACurrentMediaTime() - sent
                state.withLock { $0.latencies.append(latency) }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    struct Report: Codable {
        var pings = 0
        var stallsOver50ms = 0
        var stallsOver100ms = 0
        var maxStallMs = 0.0
        var p99PingMs = 0.0
        var worstStallsMs: [Double] = []
    }

    func stop() -> Report {
        let latencies = state.withLock {
            $0.running = false
            return $0.latencies
        }
        let ms = latencies.map { $0 * 1000 }
        var report = Report()
        report.pings = ms.count
        report.stallsOver50ms = ms.filter { $0 > 50 }.count
        report.stallsOver100ms = ms.filter { $0 > 100 }.count
        report.maxStallMs = ms.max() ?? 0
        report.p99PingMs = percentile(ms, 0.99)
        report.worstStallsMs = Array(ms.sorted(by: >).prefix(8))
        return report
    }
}

enum ProcessStats {
    /// (resident MB, physical footprint MB)
    static func memory() -> (resident: Double, footprint: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.resident_size) / 1_048_576, Double(info.phys_footprint) / 1_048_576)
    }

    /// User + system CPU seconds of this process.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    /// Seconds since this process started.
    static func secondsSinceLaunch() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        return Date().timeIntervalSince1970 - started
    }
}

struct Memory: Codable {
    var residentMB: Double
    var footprintMB: Double
    /// Live malloc bytes (all zones). Footprint also counts freed-but-retained allocator pages.
    var mallocInUseMB: Double

    static func now() -> Memory {
        let m = ProcessStats.memory()
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Memory(residentMB: (m.resident * 10).rounded() / 10, footprintMB: (m.footprint * 10).rounded() / 10,
                      mallocInUseMB: (Double(stats.size_in_use) / 104_857.6).rounded() / 10)
    }
}

@MainActor
enum Snapshots {
    static let directory = URL(fileURLWithPath: "build/snapshots")

    @discardableResult
    static func capture(_ view: NSView, name: String) -> NSBitmapImageRep? {
        guard let rep = bitmap(view) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: directory.appending(path: "G1-B-\(name).png"))
        }
        return rep
    }

    static func bitmap(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Fraction of pixels that differ by more than a small tolerance.
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, let pa = a.bitmapData, let pb = b.bitmapData
        else { return 1 }
        let bytes = min(a.bytesPerRow * a.pixelsHigh, b.bytesPerRow * b.pixelsHigh)
        let stride = max(1, a.bitsPerPixel / 8)
        var differing = 0
        var total = 0
        var index = 0
        while index + stride <= bytes {
            var diff = 0
            for channel in 0..<min(3, stride) { diff = max(diff, abs(Int(pa[index + channel]) - Int(pb[index + channel]))) }
            if diff > 24 { differing += 1 }
            total += 1
            index += stride
        }
        return total == 0 ? 1 : Double(differing) / Double(total)
    }
}

enum Report {
    static let directory = URL(fileURLWithPath: "build/spikes/G1-B")

    static func write<T: Encodable>(_ value: T, name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) {
            try? data.write(to: directory.appending(path: "\(name).json"))
        }
    }

    static func writeText(_ text: String, name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? text.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
    }
}

func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
