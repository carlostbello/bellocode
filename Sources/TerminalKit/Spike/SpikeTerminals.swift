// G5 SPIKE ONLY (docs/spikes/G5-terminal.md). Two ways of driving a SwiftTerm view:
//   (a) SpikeLocalTerminal  — the app owns the PTY and the login shell (SwiftTerm's LocalProcessTerminalView).
//   (b) SpikeRemoteTerminal — opencode owns the PTY; the view is only an emulator fed from the WebSocket.

import AppKit
import Darwin
import Foundation
import Synchronization
import SwiftTerm

/// The surface the spike harness measures; both process models conform.
@MainActor
public protocol SpikeTerminal: AnyObject {
    var model: String { get }
    var view: TerminalView { get }
    var markers: SpikeMarkerRecorder { get }
    /// Types `text` into the program as if the user had (bypasses key handling).
    func type(_ text: String)
    func close()
}

public enum SpikeTerminalStyle {
    @MainActor public static var font: NSFont { NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) }

    @MainActor public static func options(scrollback: Int, cols: Int = 100, rows: Int = 30) -> TerminalOptions {
        var options = TerminalOptions(cols: cols, rows: rows, scrollback: scrollback)
        // OSC 52 and OSC 1337 payloads are untrusted; cap one OSC at 1 MiB instead of the 65 MiB default.
        options.maximumOscBytes = 1 << 20
        return options
    }
}

// MARK: - Markers

/// Records OSC sequences after SwiftTerm parsed them. The spike prints `ESC ] 6973 ; <token> BEL` after each workload,
/// so "marker seen" means every byte before it went through the emulator.
public final class SpikeMarkerRecorder: Sendable {
    public struct Event: Sendable {
        public let code: Int
        public let payload: String
        public let time: ContinuousClock.Instant
    }

    public static let markerCode = 6973
    private let events = SpikeLocked<[Event]>([])
    private let observation = SpikeLocked<TerminalOscObservation?>(nil)

    @MainActor
    public init(view: TerminalView) {
        let token = view.observeOscEvents { [events] event in
            let now = ContinuousClock.now
            events.withLock { list in
                list.append(Event(code: event.code, payload: String(decoding: event.payload, as: UTF8.self), time: now))
                if list.count > 4096 { list.removeFirst(list.count - 4096) }
            }
        }
        observation.withLock { $0 = token }
    }

    public func all() -> [Event] { events.withLock { $0 } }

    public func seen(code: Int) -> [Event] { events.withLock { $0.filter { $0.code == code } } }

    public func time(ofMarker token: String) -> ContinuousClock.Instant? {
        events.withLock { $0.last { $0.code == Self.markerCode && $0.payload == token }?.time }
    }

    /// Polls (without blocking the main actor) until the marker arrives.
    public func waitForMarker(_ token: String, timeout: Duration) async -> ContinuousClock.Instant? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let time = time(ofMarker: token) { return time }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    public static func command(_ token: String) -> String { "printf '\\033]\(markerCode);\(token)\\007'" }
}

// MARK: - Shell launch policy (model a)

public enum SpikeShell {
    /// The user's login shell from the directory service, falling back to zsh.
    public static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    /// The environment a terminal tab starts with: the app's own environment (a Finder-launched app has a minimal one;
    /// the login shell's profile fills in PATH) minus variables that would confuse the child, plus terminal identity.
    public static func environment(extra: [String: String] = [:]) -> [String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["OPENCODE_PASSWORD", "OPENCODE_SERVER_PASSWORD", "TERM_SESSION_ID", "ITERM_SESSION_ID",
                    "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "__CFBundleIdentifier", "XPC_SERVICE_NAME",
                    "COLUMNS", "LINES"] {
            env[key] = nil
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "BelloCode"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (key, value) in extra { env[key] = value }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }
}

// MARK: - (a) App-owned PTY

@MainActor
public final class SpikeLocalTerminal: NSObject, SpikeTerminal, LocalProcessTerminalViewDelegate {
    public let model = "local"
    public let localView: SpikeLocalProcessView
    public var view: TerminalView { localView }
    public let markers: SpikeMarkerRecorder
    public private(set) var exitCode: Int32??
    public private(set) var reportedDirectory: String?
    public private(set) var title: String = ""
    public private(set) var shellPID: pid_t = 0
    public var onLink: ((String) -> Void)?

    public init(frame: NSRect, directory: String, scrollback: Int, extraEnvironment: [String: String] = [:], shell: String? = nil) {
        localView = SpikeLocalProcessView(frame: frame, font: SpikeTerminalStyle.font, options: SpikeTerminalStyle.options(scrollback: scrollback))
        markers = SpikeMarkerRecorder(view: localView)
        super.init()
        localView.processDelegate = self
        localView.onLink = { [weak self] link in self?.onLink?(link) }
        let shell = shell ?? SpikeShell.loginShell()
        // argv[0] "-zsh" makes it a login shell, as Terminal.app does.
        localView.startProcess(
            executable: shell, args: [], environment: SpikeShell.environment(extra: extraEnvironment),
            execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: directory
        )
        shellPID = localView.process.shellPid
    }

    public func type(_ text: String) { localView.send(txt: text) }

    /// Hang up the whole session we own (shell and its jobs), then let LocalProcess escalate SIGTERM -> SIGKILL.
    public func close() {
        let pid = shellPID
        if pid > 0, localView.process.running {
            // forkpty() made the shell a session and process-group leader, so -pid addresses only processes we started.
            kill(-pid, SIGHUP)
            kill(pid, SIGHUP)
        }
        localView.terminate()
        localView.removeFromSuperview()
    }

    // LocalProcessTerminalViewDelegate
    public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    public func setTerminalTitle(source: LocalProcessTerminalView, title: String) { self.title = title }
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { reportedDirectory = directory }
    public func processTerminated(source: TerminalView, exitCode: Int32?) { self.exitCode = .some(exitCode) }
}

/// LocalProcessTerminalView opens links in the default browser and serves OSC 52 from the general pasteboard; the
/// spike intercepts links (BelloCode routes them to its own browser). OSC 52 cannot be intercepted here because
/// `clipboardCopy`/`clipboardRead` are `public`, not `open` — production must use its own TerminalViewDelegate.
public final class SpikeLocalProcessView: LocalProcessTerminalView {
    public var onLink: ((String) -> Void)?

    public override func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        if let onLink { onLink(request.link) } else { super.requestOpenLink(source: source, request: request) }
    }
}

// MARK: - (b) opencode-owned PTY

@MainActor
public final class SpikeRemoteTerminal: NSObject, SpikeTerminal, TerminalViewDelegate {
    public let model = "remote"
    public let view: TerminalView
    public let markers: SpikeMarkerRecorder
    public let ptyID: String
    public let client: SpikePTYClient
    public private(set) var connection: SpikePTYConnection?
    public private(set) var size: SpikeTerminalSize
    public private(set) var reportedDirectory: String?
    public private(set) var title: String = ""
    public var onLink: ((String) -> Void)?
    /// Control events seen on the socket, for the report (attached, replay, exited, ...).
    public let controlLog = SpikeLocked<[String]>([])
    public let exited = SpikeLocked(false)
    public let replayDone = SpikeLocked(false)

    public init(frame: NSRect, client: SpikePTYClient, ptyID: String, scrollback: Int) {
        view = TerminalView(frame: frame, font: SpikeTerminalStyle.font, options: SpikeTerminalStyle.options(scrollback: scrollback))
        markers = SpikeMarkerRecorder(view: view)
        self.client = client
        self.ptyID = ptyID
        let dimensions = view.terminalDimensions
        size = SpikeTerminalSize(cols: dimensions.cols, rows: dimensions.rows)
        super.init()
        view.terminalDelegate = self
    }

    /// Attaches from `cursor` (0 = everything the server still retains). Output is parsed on the socket's receive
    /// task through SwiftTerm's thread-safe feed sender; nothing here touches the main actor per byte.
    public func attach(cursor: Int = 0) {
        let feed = view.feedSender
        let log = controlLog
        let exited = exited
        let replayDone = replayDone
        replayDone.withLock { $0 = false }
        let connection = client.connect(ptyID: ptyID, cursor: cursor) { event in
            switch event {
            case .output(let data):
                data.withUnsafeBytes { feed.feed(byteArray: ArraySlice($0.bindMemory(to: UInt8.self))) }
            case .exited:
                exited.withLock { $0 = true }
                log.withLock { $0.append("\(event)") }
            case .replayComplete:
                replayDone.withLock { $0 = true }
                log.withLock { $0.append("\(event)") }
            default:
                log.withLock { if $0.count < 256 { $0.append("\(event)") } }
            }
        }
        self.connection = connection
        connection.sendResize(size)
    }

    /// Drops the socket; the PTY keeps running on the server.
    public func detach() {
        connection?.close()
        connection = nil
    }

    public func type(_ text: String) { connection?.sendInput(Array(text.utf8), size: size) }

    public func close() {
        detach()
        view.removeFromSuperview()
    }

    // TerminalViewDelegate
    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        size = SpikeTerminalSize(cols: newCols, rows: newRows)
        connection?.sendResize(size)
    }
    public func setTerminalTitle(source: TerminalView, title: String) { self.title = title }
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { reportedDirectory = directory }
    public func send(source: TerminalView, data: ArraySlice<UInt8>) { connection?.sendInput(data, size: size) }
    public func scrolled(source: TerminalView, position: Double) {}
    public func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) { onLink?(request.link) }
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { onLink?(link) }
    public func bell(source: TerminalView) {}
    public func clipboardCopy(source: TerminalView, content: Data) {
        // OSC 52 policy: never write the pasteboard silently from terminal output. See the spike note.
        controlLog.withLock { $0.append("osc52-blocked \(content.count) bytes") }
    }
    public func clipboardRead(source: TerminalView) -> Data? { nil }
    public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
