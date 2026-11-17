import AppKit
import BelloCore
import Darwin
import Engine
import Foundation
import OpenCodeKit
import Synchronization
@testable import SwiftTerm
@testable import TerminalKit

/// The spike's throughput and keystroke-latency scenarios (docs/spikes/G5-terminal.md) re-run on the production
/// path: `TerminalService` → `TerminalStream` (socket, bounded pipe, coalesced feed) → `TerminalPaneController` in a
/// `TerminalSurfaceController`, against the pinned opencode with an isolated HOME/XDG. A 120x37 grid, as in the spike.
@MainActor
final class PerfScenarios {
    struct Workload: Codable {
        var name: String
        var command: String
        var payloadBytes: Int
        var seconds: Double
        var mbPerSecond: Double
        var mainQueueLatencyMs: Stats
        var mainStallsOver50ms: Int
        var cpuSeconds: [String: Double]
        var finalScreenOK: Bool
        var windowOccluded: Bool
    }

    struct PerfReport: Codable {
        var path = "production (TerminalStream + TerminalPaneController, CoreGraphics renderer)"
        var grid = "120x37"
        var workloads: [Workload] = []
        var error: String?
    }

    struct LatencyReport: Codable {
        var path = "production: key event → TerminalPaneView → TerminalStream → PTY echo → feed → buffer"
        var keystrokeToBufferMs: Stats
        var misses: Int
        var error: String?
    }

    private var sandbox: URL?
    private var supervisor: ServerSupervisor?

    // MARK: Setup

    private func startServer() async throws -> (OpenCodeClient, SessionID, TerminalLaunch) {
        guard let executable = DemoPaths.opencode else { throw DemoError("run Scripts/fetch-opencode.sh first") }
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-terminal-perf-\(UUID().uuidString)", directoryHint: .isDirectory)
        sandbox = root
        let project = root.appending(path: "project", directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        for url in [project, home] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let supervisor = ServerSupervisor(
            configuration: ServerConfiguration(
                executableURL: executable, dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
                expectedVersion: DemoPaths.pinnedVersion))
        self.supervisor = supervisor
        await supervisor.start()
        let deadline = ContinuousClock.now + .seconds(30)
        var endpoint = await supervisor.endpoint
        while endpoint == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            endpoint = await supervisor.endpoint
        }
        guard let endpoint else { throw DemoError("server did not become ready") }
        serverPID = await supervisor.childPID
        let client = OpenCodeClient(endpoint: endpoint)
        let session = try await client.createSession(SessionCreateRequest(directory: project.path, title: "perf"))
        let launch = TerminalLaunch(
            command: "/bin/zsh", args: ["-f"],
            environment: [
                "HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
                "PS1": "%# ",
            ])
        return (client, SessionID(session.id), launch)
    }

    private func stopServer() async {
        if let pid = await supervisor?.childPID {
            await supervisor?.stop()
            if kill(pid, 0) == 0 { print("WARNING: server \(pid) still running") }
        }
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    /// A drawer surface in a window sized for a 120x37 grid, with one terminal attached and at its prompt.
    private func makeTerminal(_ client: OpenCodeClient, _ session: SessionID, _ launch: TerminalLaunch) async throws
        -> (TerminalService, TerminalWorkspace, DemoWindow, TerminalPaneController, MarkerRecorder)
    {
        let service = TerminalService(store: try ProjectionStore(location: .inMemory), client: { client }, launch: launch)
        let workspace = TerminalWorkspace(service: service, preferences: TerminalPreferences(fontSize: 12, scrollback: 10_000))
        let surface = workspace.makeSurface(.drawer)
        let font = workspace.preferences.font
        let cell = ("W" as NSString).size(withAttributes: [.font: font])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let size = NSSize(width: ceil(cell.width * 120) + 8, height: ceil(lineHeight * 37) + 31 + 4)
        let window = DemoWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = surface.view
        let terminals = service.terminals(for: session)
        await terminals.waitUntilLoaded()
        surface.display(terminals, directory: launch.environment["HOME"])
        guard let record = await terminals.create(directory: launch.environment["HOME"] ?? "/", size: PTYSize(cols: 120, rows: 37)) else {
            throw DemoError("could not create the terminal")
        }
        _ = await waitUntil(timeout: .seconds(5)) { workspace.existingPane(record.id) != nil }
        window.contentView?.layoutSubtreeIfNeeded()
        guard let pane = workspace.existingPane(record.id) else { throw DemoError("no pane") }
        let markers = MarkerRecorder(view: pane.terminalView)
        guard await waitUntil(timeout: .seconds(15), { pane.status == .live }) else { throw DemoError("not live") }
        _ = await run(pane, markers, "true", timeout: .seconds(15))
        return (service, workspace, window, pane, markers)
    }

    /// Runs `command` followed by a marker OSC; returns seconds until the emulator has parsed the marker.
    private func run(_ pane: TerminalPaneController, _ markers: MarkerRecorder, _ command: String, timeout: Duration = .seconds(240)) async -> Double? {
        let token = UUID().uuidString.prefix(8)
        let start = ContinuousClock.now
        pane.stream.send(Array("\(command); printf '\\033]6973;\(token)\\007'\r".utf8))
        guard let seen = await markers.wait(for: String(token), timeout: timeout) else { return nil }
        let elapsed = seen - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    // MARK: perf

    func perf() async -> Int32 {
        var report = PerfReport()
        do {
            let (client, session, launch) = try await startServer()
            let (service, workspace, window, pane, markers) = try await makeTerminal(client, session, launch)
            let file = try bigFile()
            let cases: [(String, String, Int)] = [
                ("yes", "yes | head -n 2000000", 4_000_000),
                ("cat20MB", "cat \(file)", 20 << 20),
                ("seq5M", "seq 1 5000000", 54_444_420),
            ]
            for (name, command, bytes) in cases {
                _ = await run(pane, markers, "clear")
                try? await Task.sleep(for: .milliseconds(500))
                let probe = MainLatencyProbe()
                let before = cpu()
                probe.start()
                let seconds = await run(pane, markers, command) ?? -1
                let stall = probe.stop()
                let after = cpu()
                Render.frame(pane.terminalView)
                let screen = pane.terminalView.visibleRowsText(0..<37).joined(separator: "\n")
                let expected = name == "seq5M" ? "5e+06" : name == "yes" ? "y" : "0123456789"
                var cpuDelta: [String: Double] = [:]
                for (key, value) in after { cpuDelta[key] = Stats.round(value - (before[key] ?? 0), 2) }
                let workload = Workload(
                    name: name, command: command, payloadBytes: bytes, seconds: Stats.round(seconds, 3),
                    mbPerSecond: seconds > 0 ? Stats.round(Double(bytes) / 1_048_576 / seconds, 1) : -1,
                    mainQueueLatencyMs: stall.stats, mainStallsOver50ms: stall.over50ms, cpuSeconds: cpuDelta,
                    finalScreenOK: screen.contains(expected), windowOccluded: !window.occlusionState.contains(.visible))
                report.workloads.append(workload)
                print("\(name): \(workload.seconds) s, \(workload.mbPerSecond) MB/s, main p99 \(stall.stats.p99) ms, stalls>50ms \(stall.over50ms), cpu \(cpuDelta), screen ok \(workload.finalScreenOK)")
            }
            workspace.close()
            await service.shutdown()
            _ = window
        } catch {
            report.error = "\(error)"
            print("perf failed: \(error)")
        }
        await stopServer()
        writeReport("perf", report)
        return report.error == nil ? 0 : 1
    }

    // MARK: latency

    /// Key events delivered to the focused terminal view while `cat` echoes them; time until the character is in
    /// the emulator's buffer (visible on the next frame).
    func latency() async -> Int32 {
        var samples: [Double] = []
        var misses = 0
        var failure: String?
        do {
            let (client, session, launch) = try await startServer()
            let (service, workspace, window, pane, markers) = try await makeTerminal(client, session, launch)
            _ = await run(pane, markers, "clear")
            pane.stream.send(Array("cat\r".utf8))
            try? await Task.sleep(for: .milliseconds(500))
            window.makeFirstResponder(pane.terminalView)
            let letters = Array("abcdefghijklmnopqrstuvwxyz")
            for round in 0..<6 {
                let row = pane.terminalView.terminalStateSnapshot().cursor.row
                for index in 0..<40 {
                    let character = String(letters[(round * 40 + index) % letters.count])
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: character,
                        charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)
                    else { continue }
                    let start = ContinuousClock.now
                    pane.terminalView.keyDown(with: event)
                    let expected = index + 1
                    let seen = await waitUntil(timeout: .seconds(1), poll: .microseconds(250)) {
                        (pane.terminalView.visibleRowsText(row..<(row + 1)).first ?? "").count >= expected
                    }
                    if seen {
                        let elapsed = ContinuousClock.now - start
                        samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
                    } else {
                        misses += 1
                    }
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 15...40)))
                }
                pane.stream.send(Array("\r".utf8))
                try? await Task.sleep(for: .milliseconds(200))
            }
            pane.stream.send([0x04])
            workspace.close()
            await service.shutdown()
        } catch {
            failure = "\(error)"
        }
        await stopServer()
        let report = LatencyReport(keystrokeToBufferMs: Stats(samples), misses: misses, error: failure)
        print("keystroke to buffer: p50 \(report.keystrokeToBufferMs.p50) / p95 \(report.keystrokeToBufferMs.p95) / max \(report.keystrokeToBufferMs.max) ms over \(samples.count), misses \(misses)")
        writeReport("latency", report)
        return failure == nil && misses == 0 ? 0 : 1
    }

    // MARK: Helpers

    private func cpu() -> [String: Double] {
        var result = ["app": ProcessStats.cpuSeconds()]
        if let pid = serverPID {
            if let server = ProcessStats.cpuSeconds(pid: pid) { result["server"] = server }
            var daemon = 0.0
            for child in ProcessStats.children(of: pid) { daemon += ProcessStats.cpuSeconds(pid: child) ?? 0 }
            result["serverChildren"] = daemon
        }
        return result
    }

    private var serverPID: pid_t?

    private func bigFile() throws -> String {
        let path = (sandbox ?? FileManager.default.temporaryDirectory).appending(path: "20mb.txt").path
        let line = Array("The quick brown fox jumps over the lazy dog 0123456789 ABCDEFGHIJKLMNOPQRSTUVW\n".utf8)
        var data = Data(capacity: 20 << 20)
        while data.count + line.count <= 20 << 20 { data.append(contentsOf: line) }
        data.append(contentsOf: Array(repeating: UInt8(ascii: "x"), count: (20 << 20) - data.count - 1) + [0x0A])
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }
}

/// Records when marker OSCs (`ESC ] 6973 ; token BEL`) have been parsed by the emulator: everything printed before
/// a marker went through SwiftTerm's parser when it is seen.
@MainActor
final class MarkerRecorder {
    final class Seen: Sendable {
        let times = Mutex<[String: ContinuousClock.Instant]>([:])
    }

    private let seen = Seen()
    private var observation: TerminalOscObservation?

    init(view: TerminalView) {
        let seen = self.seen
        observation = view.observeOscEvents { event in
            guard event.code == 6973 else { return }
            let now = ContinuousClock.now
            let payload = String(decoding: event.payload, as: UTF8.self)
            seen.times.withLock { $0[payload] = now }
        }
    }

    func wait(for token: String, timeout: Duration) async -> ContinuousClock.Instant? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let time = seen.times.withLock({ $0[token] }) { return time }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }
}
