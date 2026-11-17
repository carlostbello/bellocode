import AppKit
import Darwin
import Engine
import Foundation
@testable import SwiftTerm
@testable import TerminalKit

/// Paths into the repository (the demo runs from the package root).
enum DemoPaths {
    static let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    static let snapshots = root.appending(path: "build/snapshots")
    static let reports = root.appending(path: "build/terminal")

    static var opencode: URL? {
        let version = (try? String(contentsOf: root.appending(path: "Scripts/opencode-version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "2.3.0"
        let url = root.appending(path: "Vendor/opencode/\(version)/opencode")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var pinnedVersion: String? {
        (try? String(contentsOf: root.appending(path: "Scripts/opencode-version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A window that reports itself key, so focus rendering appears even though the demo never activates.
final class DemoWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

@MainActor
enum Render {
    /// Forces SwiftTerm to prepare and draw a frame now. Its display-link frame driver is suspended while the window
    /// is occluded (as it is here: the demo never orders its window in, and the Mac may be locked).
    static func frame(_ view: TerminalView) {
        view.frameTick()
        view.display()
    }

    /// Renders `view` to a PNG with `cacheDisplay` (every surface draws its background in `draw(_:)` for this).
    /// SwiftTerm's CoreGraphics draw clears its rect and leaves the default background to its layer, which
    /// `cacheDisplay` does not capture, so each terminal is composited: its background, then its own render.
    @discardableResult
    static func png(_ view: NSView, terminals: [TerminalView], to url: URL) -> Bool {
        view.layoutSubtreeIfNeeded()
        for terminal in terminals { frame(terminal) }
        view.needsDisplay = true
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
            for terminal in terminals where terminal.window === view.window && !terminal.isHiddenOrHasHiddenAncestor {
                guard let own = terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds) else { continue }
                terminal.cacheDisplay(in: terminal.bounds, to: own)
                var rect = terminal.convert(terminal.bounds, to: view)
                if !view.isFlipped, terminal.isFlipped != view.isFlipped { rect.origin.y = rect.origin.y }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                terminal.nativeBackgroundColor.setFill()
                rect.fill()
                own.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }
}

/// Waits without blocking the main actor.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), poll: Duration = .milliseconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: poll)
    }
    return condition()
}

/// Percentile summary of a sample, in the unit of the sample.
struct Stats: Codable {
    var count: Int
    var p50: Double
    var p95: Double
    var p99: Double
    var max: Double

    init(_ values: [Double]) {
        let sorted = values.sorted()
        func at(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
        count = sorted.count
        p50 = Self.round(at(0.5))
        p95 = Self.round(at(0.95))
        p99 = Self.round(at(0.99))
        max = Self.round(sorted.last ?? 0)
    }

    static func round(_ value: Double, _ places: Double = 2) -> Double {
        let factor = pow(10, places)
        return (value * factor).rounded() / factor
    }
}

/// Measures how late the main queue runs a block scheduled every 5 ms (main-thread responsiveness).
@MainActor
final class MainLatencyProbe {
    private var samples: [Double] = []
    private var running = false

    func start() {
        running = true
        samples.removeAll()
        schedule()
    }

    private func schedule() {
        guard running else { return }
        let scheduled = DispatchTime.now()
        DispatchQueue.main.asyncAfter(deadline: scheduled + .milliseconds(5)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                let late = Double(DispatchTime.now().uptimeNanoseconds - scheduled.uptimeNanoseconds) / 1e6 - 5
                self.samples.append(Swift.max(0, late))
                self.schedule()
            }
        }
    }

    func stop() -> (stats: Stats, over50ms: Int) {
        running = false
        return (Stats(samples), samples.count { $0 > 50 })
    }
}

enum ProcessStats {
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// CPU seconds of another process we can inspect (our own children).
    static func cpuSeconds(pid: pid_t) -> Double? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// Direct children of `pid` (the server's pty daemon).
    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        return count > 0 ? Array(buffer.prefix(Int(count))) : []
    }

    private static func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
}

func writeReport(_ name: String, _ value: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? FileManager.default.createDirectory(at: DemoPaths.reports, withIntermediateDirectories: true)
    let url = DemoPaths.reports.appending(path: "\(name).json")
    try? encoder.encode(value).write(to: url)
    print("report: \(url.path.replacingOccurrences(of: DemoPaths.root.path + "/", with: ""))")
}
