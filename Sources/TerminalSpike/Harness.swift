// G5 spike harness: window, terminal factories, typing, waiting and report writing.

import AppKit
import Foundation
import QuartzCore
import SwiftTerm
import TerminalKit

typealias Report = [String: Any]

@MainActor
final class Harness {
    let paths = SpikePaths()
    let window: NSWindow
    let container: NSView
    let terminalFrame = NSRect(x: 0, y: 0, width: 900, height: 560)
    var server: SpikeServer?
    var sessionID: String?
    var log: [String] = []
    let scratch: URL

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 1400, height: 900), styleMask: [.titled, .resizable, .closable],
            backing: .buffered, defer: false
        )
        window.title = "BelloCode G5 terminal spike"
        window.isReleasedWhenClosed = false
        container = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        window.contentView = container
        scratch = paths.root.appending(path: "build/spikes/G5/work")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func say(_ message: String) {
        log.append(message)
        print("g5: \(message)")
        fflush(stdout)
    }

    // MARK: Server

    func ensureServer() async throws -> SpikeServer {
        if let server { return server }
        let root = paths.root.appending(path: "build/spikes/G5/oc-\(ProcessInfo.processInfo.processIdentifier)")
        let server = try await SpikeServer.startOwned(paths: paths, dataRoot: root)
        self.server = server
        sessionID = try await server.client.createSession(directory: scratch.path, title: "g5")
        say("opencode pid \(server.pid) ready at \(server.endpoint.baseURL.absoluteString)")
        return server
    }

    func stopServer() async {
        guard let server else { return }
        await server.stop()
        self.server = nil
        try? FileManager.default.removeItem(at: server.dataRoot)
    }

    // MARK: Terminals

    func makeLocal(scrollback: Int = 10_000, extraEnvironment: [String: String] = [:], frame: NSRect? = nil) -> SpikeLocalTerminal {
        let terminal = SpikeLocalTerminal(
            frame: frame ?? terminalFrame, directory: scratch.path, scrollback: scrollback, extraEnvironment: extraEnvironment
        )
        container.addSubview(terminal.view)
        window.makeFirstResponder(terminal.view)
        return terminal
    }

    /// The environment BelloCode passes to an opencode persistent PTY so the user's shell does not inherit the
    /// server's isolated HOME/XDG directories.
    func remoteEnvironment() -> [String: String] {
        let mine = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "BelloCode",
            "LANG": mine["LANG"] ?? "en_US.UTF-8",
        ]
        for key in ["PATH", "USER", "LOGNAME", "SHELL", "TMPDIR", "SSH_AUTH_SOCK"] { env[key] = mine[key] }
        return env
    }

    func makeRemote(scrollback: Int = 10_000, frame: NSRect? = nil, ptyID existing: String? = nil, cursor: Int = 0,
                    env: [String: String]? = nil) async throws -> SpikeRemoteTerminal {
        let server = try await ensureServer()
        let client = server.client
        let ptyID: String
        if let existing {
            ptyID = existing
        } else {
            let shell = SpikeShell.loginShell()
            let info = try await client.createTerminal(
                sessionID: sessionID!, cwd: scratch.path, size: SpikeTerminalSize(cols: 100, rows: 30), title: "g5",
                env: env ?? remoteEnvironment(), command: shell, args: ["-l"]
            )
            ptyID = info.id
        }
        let terminal = SpikeRemoteTerminal(frame: frame ?? terminalFrame, client: client, ptyID: ptyID, scrollback: scrollback)
        container.addSubview(terminal.view)
        window.makeFirstResponder(terminal.view)
        terminal.attach(cursor: cursor)
        return terminal
    }

    // MARK: Driving

    /// Types a command and waits until the marker printed after it has been parsed. Returns the elapsed seconds.
    @discardableResult
    func run(_ terminal: some SpikeTerminal, _ command: String, timeout: Duration = .seconds(30)) async -> Double? {
        let token = "m\(UUID().uuidString.prefix(8))"
        let start = ContinuousClock.now
        terminal.type("\(command); \(SpikeMarkerRecorder.command(token))\r")
        guard let end = await terminal.markers.waitForMarker(token, timeout: timeout) else {
            say("timeout waiting for: \(command.prefix(60))")
            return nil
        }
        return seconds(end - start)
    }

    /// Waits until the shell answers (its rc files can take a while on first start).
    func ready(_ terminal: some SpikeTerminal) async -> Bool {
        await run(terminal, "true", timeout: .seconds(20)) != nil
    }

    func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }

    func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    func screenText(_ view: TerminalView) -> [String] {
        view.visibleRowsText(0..<view.terminalDimensions.rows)
    }

    /// Delivers a real key event through the window to the first responder (the view's own key handling).
    func key(_ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ) else { return }
        window.sendEvent(event)
    }

    func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
        let windowPoint = view.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: type, location: windowPoint, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        ) else { return }
        window.sendEvent(event)
    }

    /// The point at the centre of a cell (col, row from the top of the viewport).
    func cellPoint(_ view: TerminalView, col: Int, row: Int) -> NSPoint {
        let dims = view.terminalDimensions
        let cellWidth = view.bounds.width / CGFloat(dims.cols)
        let cellHeight = view.bounds.height / CGFloat(dims.rows)
        let y = view.isFlipped ? (CGFloat(row) + 0.5) * cellHeight : view.bounds.height - (CGFloat(row) + 0.5) * cellHeight
        return NSPoint(x: (CGFloat(col) + 0.5) * cellWidth, y: y)
    }

    func snapshot(_ view: NSView, _ name: String) -> String {
        let url = paths.snapshots.appending(path: "G5-\(name).png")
        return SpikeSnapshot.writePNG(view, to: url) ? url.path.replacingOccurrences(of: paths.root.path + "/", with: "") : "failed"
    }

    func write(_ name: String, _ report: Report) {
        try? FileManager.default.createDirectory(at: paths.reports, withIntermediateDirectories: true)
        let url = paths.reports.appending(path: "\(name).json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
        say("wrote \(url.path.replacingOccurrences(of: paths.root.path + "/", with: ""))")
    }

    func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    func round(_ value: Double, _ places: Int = 2) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }

    func stats(_ stats: SpikeStats) -> Report {
        ["count": stats.count, "p50": round(stats.p50), "p95": round(stats.p95), "p99": round(stats.p99),
         "max": round(stats.max), "mean": round(stats.mean)]
    }
}
