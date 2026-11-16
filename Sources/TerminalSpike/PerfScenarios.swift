// G5 spike: performance scenarios (throughput, frame pacing, main-thread stalls, keystroke latency, memory, idle CPU).
// Usage: TerminalSpike perf|latency|memory|idle --model local|remote [--renderer cg|metal]

import AppKit
import Darwin
import Foundation
import SwiftTerm
import TerminalKit

extension Scenarios {
    var model: String { option("model") ?? "local" }
    var renderer: String { option("renderer") ?? "cg" }
    var tag: String { "\(model)-\(renderer)" }

    /// A 20 MiB text file of 80-column lines (created once).
    func bigFile() -> String {
        let path = h.scratch.appending(path: "20mb.txt").path
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size == 20 << 20 { return path }
        let line = Array("The quick brown fox jumps over the lazy dog 0123456789 ABCDEFGHIJKLMNOPQRSTUVW\n".utf8)
        var data = Data(capacity: 20 << 20)
        while data.count + line.count <= 20 << 20 { data.append(contentsOf: line) }
        data.append(contentsOf: Array(repeating: UInt8(ascii: "x"), count: (20 << 20) - data.count - 1) + [0x0A])
        try? data.write(to: URL(fileURLWithPath: path))
        return path
    }

    // MARK: Throughput, frames, stalls

    func perf() async -> Int32 {
        var report: Report = ["model": model, "renderer": renderer]
        var workloads: [Report] = []
        do {
            let file = bigFile()
            let terminal = try await h.makeTerminal(model: model, renderer: renderer)
            guard await h.ready(terminal) else { throw SpikeClientError2("shell not ready") }
            await h.run(terminal, "clear")
            let cases: [(String, String, Int)] = [
                ("yes", "yes | head -n 2000000", 4_000_000),
                ("cat20MB", "cat \(file)", 20 << 20),
                ("seq5M", "seq 1 5000000", 38_888_897),
            ]
            for (name, command, bytes) in cases {
                await h.pause(500)
                let frames = SpikeFrameMonitor()
                let forced = ForcedFrameClock()
                let probe = SpikeMainStallProbe()
                let before = h.processSample()
                frames.start(on: terminal.view)
                if renderer == "cg" { forced.start(terminal.view) }
                probe.start()
                let elapsed = await h.run(terminal, command, timeout: .seconds(240))
                let frameResult = frames.stop()
                let forcedResult = forced.stop()
                let stall = probe.stop()
                let after = h.processSample()
                var entry: Report = [
                    "name": name, "command": command, "payloadBytes": bytes,
                    "seconds": elapsed.map { h.round($0, 3) } ?? -1,
                    "MBps": elapsed.map { h.round(Double(bytes) / 1_048_576 / $0, 1) } ?? -1,
                    "frameIntervalsMs": h.stats(frameResult.intervals), "framesOver33ms": frameResult.over33ms,
                    "framesOver50ms": frameResult.over50ms, "framesOver100ms": frameResult.over100ms,
                    "mainQueueLatencyMs": h.stats(stall.latency), "mainStallsOver50ms": stall.over50ms,
                    "mainStallsOver100ms": stall.over100ms, "processes": h.cpuDelta(before, after),
                    "forcedFrames": ForcedFrameClock.available && renderer == "cg" ? [
                        "intervalsMs": h.stats(forcedResult.intervals), "renderWorkMs": h.stats(forcedResult.work),
                        "intervalsOver33ms": forcedResult.intervalsOver33ms, "intervalsOver50ms": forcedResult.intervalsOver50ms,
                    ] as Report : "unavailable",
                ]
                if let remote = terminal as? SpikeRemoteTerminal { entry["socketBytes"] = remote.connection?.totalBytesReceived ?? 0 }
                // Correct final state: the last line of the workload is on screen.
                let screen = h.screenText(terminal.view).joined(separator: "\n")
                let expected = name == "seq5M" ? "5000000" : name == "yes" ? "y" : "xxxxxxxx"
                entry["finalScreenOK"] = screen.contains(expected)
                if renderer == "cg" { entry["snapshot"] = h.snapshot(terminal.view, "perf-\(tag)-\(name)") }
                workloads.append(entry)
                h.say("\(name): \(entry["seconds"]!) s, \(entry["MBps"]!) MB/s, displayLink frames \(frameResult.intervals.count), forced work p95 \(h.round(forcedResult.work.p95)) ms max \(h.round(forcedResult.work.max)), forced intervals>33ms \(forcedResult.intervalsOver33ms), main p99 \(h.round(stall.latency.p99)) ms, stalls>50ms \(stall.over50ms)")
            }
            terminal.close()
        } catch {
            report["error"] = "\(error)"
        }
        report["workloads"] = workloads
        h.write("perf-\(tag)", report)
        return report["error"] == nil ? 0 : 1
    }

    // MARK: Keystroke to echo

    /// Sends real key events through the window to the view while `cat` echoes them (tty echo), and times until the
    /// character is in the emulator's buffer (visible on the next frame).
    func latency() async -> Int32 {
        var report: Report = ["model": model, "renderer": renderer]
        do {
            let terminal = try await h.makeTerminal(model: model, renderer: renderer)
            guard await h.ready(terminal) else { throw SpikeClientError2("shell not ready") }
            await h.run(terminal, "clear")
            terminal.type("cat\r")
            await h.pause(500)
            var samples: [Double] = []
            var misses = 0
            let letters = Array("abcdefghijklmnopqrstuvwxyz")
            let frames = SpikeFrameMonitor()
            frames.start(on: terminal.view)
            for round in 0..<6 {
                let cursorRow = terminal.view.terminalStateSnapshot().cursor.row
                for index in 0..<40 {
                    let character = String(letters[(round * 40 + index) % letters.count])
                    let expectedLength = index + 1
                    let start = ContinuousClock.now
                    h.key(character, keyCode: 0)
                    let seen = await h.waitUntil(timeout: .seconds(1), poll: .microseconds(250)) {
                        (terminal.view.visibleRowsText(cursorRow..<(cursorRow + 1)).first ?? "").count >= expectedLength
                    }
                    if seen { samples.append(h.seconds(ContinuousClock.now - start) * 1000) } else { misses += 1 }
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 15...40)))
                }
                h.key("\r", keyCode: 36)
                await h.pause(200)
            }
            let frameResult = frames.stop()
            terminal.type("\u{4}")
            await h.pause(200)
            let stats = SpikeStats(samples)
            report["keystrokeToBufferMs"] = h.stats(stats)
            report["misses"] = misses
            report["frameIntervalsMs"] = h.stats(frameResult.intervals)
            report["note"] = "Poll every 250 us on the main actor; add up to one frame for display."
            if renderer == "cg" { report["snapshot"] = h.snapshot(terminal.view, "latency-\(tag)") }
            h.say("latency p50 \(h.round(stats.p50)) ms p95 \(h.round(stats.p95)) ms max \(h.round(stats.max)) ms misses \(misses)")
            terminal.close()
        } catch {
            report["error"] = "\(error)"
        }
        h.write("latency-\(tag)", report)
        return report["error"] == nil ? 0 : 1
    }

    // MARK: Scrollback memory

    func memory() async -> Int32 {
        var report: Report = ["model": model, "renderer": renderer]
        do {
            if model == "remote" { _ = try await h.ensureServer() }
            await h.pause(1000)
            let baseline = h.processSample()
            let terminal = try await h.makeTerminal(model: model, renderer: renderer, scrollback: 100_000)
            guard await h.ready(terminal) else { throw SpikeClientError2("shell not ready") }
            await h.pause(1000)
            let empty = h.processSample()
            var steps: [Report] = []
            for (index, lines) in [100_000, 100_000, 100_000].enumerated() {
                let command = "awk 'BEGIN{for(i=0;i<\(lines);i++) printf \"%07d \\033[32mgreen\\033[0m lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor\\n\", i}'"
                await h.run(terminal, command, timeout: .seconds(120))
                await h.pause(1500)
                let sample = h.processSample()
                let all = terminal.view.terminalContentSnapshot(region: .all)
                steps.append([
                    "linesWritten": lines * (index + 1),
                    "retainedRows": all?.rows.count ?? -1,
                    "firstRetained": String(all?.rows.first?.text.prefix(30) ?? ""),
                    "footprintMiB": sample.mapValues { h.round($0.mib, 1) },
                ])
                h.say("after \(lines * (index + 1)) lines: app \(h.round(sample["app"]!.mib, 1)) MiB, rows \(all?.rows.count ?? -1)")
            }
            report["baselineMiB"] = baseline.mapValues { h.round($0.mib, 1) }
            report["emptyTerminalMiB"] = empty.mapValues { h.round($0.mib, 1) }
            report["steps"] = steps
            terminal.close()
            await h.pause(1500)
            report["afterCloseMiB"] = h.processSample().mapValues { h.round($0.mib, 1) }
        } catch {
            report["error"] = "\(error)"
        }
        h.write("memory-\(tag)", report)
        return report["error"] == nil ? 0 : 1
    }

    // MARK: Idle CPU

    func idle() async -> Int32 {
        var report: Report = ["model": model, "renderer": renderer]
        do {
            let count = Int(option("count") ?? "1") ?? 1
            var terminals: [any SpikeTerminal] = []
            for index in 0..<count {
                let frame = NSRect(x: (index % 2) * 700, y: (index / 2) * 300, width: 680, height: 280)
                let terminal: any SpikeTerminal = model == "remote"
                    ? try await h.makeRemote(frame: frame)
                    : h.makeLocal(frame: frame)
                if renderer == "metal" { try terminal.view.setUseMetal(true) }
                guard await h.ready(terminal) else { throw SpikeClientError2("shell not ready") }
                terminals.append(terminal)
            }
            await h.pause(3000)
            let seconds = 20.0
            let before = h.processSample()
            try? await Task.sleep(for: .seconds(seconds))
            let after = h.processSample()
            var cpu: Report = [:]
            for (key, value) in after {
                guard let start = before[key] else { continue }
                cpu[key] = ["cpuPercent": h.round((value.cpu - start.cpu) / seconds * 100, 2), "footprintMiB": h.round(value.mib, 1)]
            }
            report["terminals"] = count
            report["idle"] = cpu
            report["windowVisible"] = h.window.isVisible
            h.say("idle \(count) terminal(s): \(cpu)")
            terminals.forEach { $0.close() }
        } catch {
            report["error"] = "\(error)"
        }
        h.write("idle-\(tag)-\(option("count") ?? "1")", report)
        return report["error"] == nil ? 0 : 1
    }
}
