// G5 SPIKE ONLY. In-process measurement: display-link frame intervals, main-thread stalls, CPU, memory, PNG snapshots.

import AppKit
import Darwin
import Foundation
import QuartzCore

/// Summary statistics in milliseconds.
public struct SpikeStats: Codable, Sendable {
    public var count: Int
    public var p50: Double
    public var p95: Double
    public var p99: Double
    public var max: Double
    public var mean: Double

    public init(_ samples: [Double]) {
        let sorted = samples.sorted()
        count = sorted.count
        func pick(_ q: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[Swift.min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
        }
        p50 = pick(0.5)
        p95 = pick(0.95)
        p99 = pick(0.99)
        max = sorted.last ?? 0
        mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
    }
}

/// Records display-link callback timestamps on the main run loop. A late or missing callback means the main thread
/// could not service the frame.
@MainActor
public final class SpikeFrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []

    public func start(on view: NSView) {
        stamps.removeAll(keepingCapacity: true)
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    public var timestamps: [CFTimeInterval] { stamps }

    @objc private func tick(_ link: CADisplayLink) { stamps.append(CACurrentMediaTime()) }

    /// Stops and returns frame intervals (ms) plus the number over 50 ms ("stall frames").
    public func stop() -> (intervals: SpikeStats, over33ms: Int, over50ms: Int, over100ms: Int) {
        link?.invalidate()
        link = nil
        let intervals = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        return (SpikeStats(intervals), intervals.count { $0 > 33.4 }, intervals.count { $0 > 50 }, intervals.count { $0 > 100 })
    }
}

/// A background thread posts to the main queue every 5 ms and records how long each post waited. This measures the
/// latency of any main-thread work (input handling, layout) while output is streaming.
public final class SpikeMainStallProbe: Sendable {
    private let samples = SpikeLocked<[Double]>([])
    private let running = SpikeLocked(false)

    public init() {}

    public func start() {
        running.withLock { $0 = true }
        samples.withLock { $0.removeAll() }
        let samples = samples
        let running = running
        let thread = Thread {
            while running.value {
                let posted = DispatchTime.now().uptimeNanoseconds
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    let waited = Double(DispatchTime.now().uptimeNanoseconds - posted) / 1_000_000
                    samples.withLock { $0.append(waited) }
                    done.signal()
                }
                _ = done.wait(timeout: .now() + 2)
                usleep(5000)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    public func stop() -> (latency: SpikeStats, over50ms: Int, over100ms: Int) {
        running.withLock { $0 = false }
        let values = samples.value
        return (SpikeStats(values), values.count { $0 > 50 }, values.count { $0 > 100 })
    }
}

public enum SpikeProcessStats {
    /// User + system CPU seconds of this process.
    public static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Physical footprint in MiB (the number Activity Monitor shows as "Memory").
    public static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// CPU seconds and footprint of another process we can inspect (our own children).
    public static func other(pid: pid_t) -> (cpu: Double, footprintMiB: Double)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom)
        return (ticks / 1e9, Double(info.ri_phys_footprint) / 1_048_576)
    }

    private static func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
}

public enum SpikeSnapshot {
    /// Renders a view (CoreGraphics renderer only; a CAMetalLayer is not captured by cacheDisplay) to a PNG.
    @MainActor
    @discardableResult
    public static func writePNG(_ view: NSView, to url: URL) -> Bool {
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }
}
