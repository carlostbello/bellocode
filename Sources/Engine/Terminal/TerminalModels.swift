import BelloCore
import Foundation
import OpenCodeKit

/// Where a terminal is shown: the bottom drawer or a right-panel tab. Each terminal is in exactly one place.
public enum TerminalPlacement: String, Codable, Sendable, Hashable, CaseIterable {
    case drawer
    case panel
}

/// Whether a terminal's process runs. opencode forgets a PTY the moment it exits, so `exited` (with the code from
/// the socket's `exited` frame) and `ended` exist only here.
public enum TerminalRunState: Codable, Sendable, Hashable {
    case running
    /// The process exited; `code` nil when it was killed by a signal or the code was not received.
    case exited(code: Int?)
    /// The server no longer has the PTY and no exit code was seen (it ended while detached, the server restarted,
    /// or it was closed elsewhere). `reason` is a short user-facing sentence.
    case ended(reason: String)

    public var isRunning: Bool { self == .running }

    /// "exited (0)", "exited", or the end reason. nil while running.
    public var label: String? {
        switch self {
        case .running: nil
        case .exited(let code): code.map { "exited (\($0))" } ?? "exited"
        case .ended(let reason): reason
        }
    }
}

/// One terminal of a thread. Identity is the server's PTY ID (`pty_persistent_…`; AGENTS.md rule 1); a restarted
/// terminal gets the new PTY's ID in the same position.
public struct TerminalRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var sessionID: SessionID
    /// The server's title (what we created it with, then OSC 2 titles from the shell).
    public var title: String
    /// A title the user set with Rename; wins over `title`.
    public var userTitle: String?
    /// The directory it started in (the thread's directory or worktree).
    public var startDirectory: String
    /// The shell's current directory (OSC 7), else the start directory.
    public var currentDirectory: String
    public var foregroundProcess: String?
    public var state: TerminalRunState
    public var placement: TerminalPlacement
    public var created: Date
    public var lastActivity: Date

    public init(
        id: String, sessionID: SessionID, title: String, userTitle: String? = nil, startDirectory: String,
        currentDirectory: String? = nil, foregroundProcess: String? = nil, state: TerminalRunState = .running,
        placement: TerminalPlacement = .drawer, created: Date = Date(), lastActivity: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.userTitle = userTitle
        self.startDirectory = startDirectory
        self.currentDirectory = currentDirectory ?? startDirectory
        self.foregroundProcess = foregroundProcess
        self.state = state
        self.placement = placement
        self.created = created
        self.lastActivity = lastActivity ?? created
    }

    /// The tab title: the user's, else the shell's.
    public var displayTitle: String {
        if let userTitle, !userTitle.isEmpty { return userTitle }
        return title.isEmpty ? "Terminal" : title
    }
}

/// A thread's terminals and their layout, persisted as one app-owned value (`app_terminal`).
public struct ThreadTerminalSet: Codable, Sendable, Hashable {
    public static let currentVersion = 1
    /// Bound (AGENTS.md rule 5): a thread keeps at most this many terminal records (oldest exited dropped first).
    public static let maxRecords = 24

    public var version = ThreadTerminalSet.currentVersion
    /// Tab order (drawer and panel terminals interleaved; each place shows its own in this order).
    public var records: [TerminalRecord] = []
    /// The selected terminal per place.
    public var selectedDrawer: String?
    public var selectedPanel: String?
    /// The drawer's second pane (side by side with the selected one), if split.
    public var splitSecondary: String?
    /// Whether the drawer was open for this thread, and its height in points.
    public var isDrawerOpen: Bool?
    public var drawerHeight: Double?
    /// Next number for "Terminal N" titles.
    public var nextNumber = 1

    public init() {}

    public var isEmpty: Bool { records.isEmpty && isDrawerOpen == nil && drawerHeight == nil }

    public func records(in placement: TerminalPlacement) -> [TerminalRecord] { records.filter { $0.placement == placement } }

    public func record(_ id: String) -> TerminalRecord? { records.first { $0.id == id } }

    /// Drops the oldest non-running records beyond the bound.
    mutating func trim() {
        while records.count > Self.maxRecords, let index = records.firstIndex(where: { !$0.state.isRunning }) {
            records.remove(at: index)
        }
        let ids = Set(records.map(\.id))
        if let id = selectedDrawer, !ids.contains(id) { selectedDrawer = nil }
        if let id = selectedPanel, !ids.contains(id) { selectedPanel = nil }
        if let id = splitSecondary, !ids.contains(id) { splitSecondary = nil }
    }
}

/// What a new terminal runs and with which environment. opencode's server runs with isolated HOME/XDG directories,
/// so the user's own `HOME`, `PATH`, locale and agent socket are passed explicitly (docs/spikes/G5-terminal.md).
public struct TerminalLaunch: Sendable, Hashable {
    public var command: String
    public var args: [String]
    public var environment: [String: String]

    public init(command: String, args: [String], environment: [String: String]) {
        self.command = command
        self.args = args
        self.environment = environment
    }

    /// The user's login shell (`-l`, like Terminal.app) with the user's environment and terminal identity.
    public static func userDefault(processEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> TerminalLaunch {
        let shell = loginShell(processEnvironment)
        var env: [String: String] = [
            "TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "BelloCode",
            "LANG": processEnvironment["LANG"] ?? "en_US.UTF-8", "SHELL": shell,
        ]
        for key in ["HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "LC_ALL", "LC_CTYPE"] {
            if let value = processEnvironment[key] { env[key] = value }
        }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        return TerminalLaunch(command: shell, args: ["-l"], environment: env)
    }

    /// A terminal in the project's workspace container: `bellocode-exec` with no arguments starts an interactive login
    /// shell in the container at the terminal's directory (docs/features/containers.md). Only terminal identity and
    /// language pass through; the Mac's PATH, HOME and SSH agent do not.
    public static func container(helper: URL, execConfig: URL, processEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> TerminalLaunch {
        var env: [String: String] = [
            "TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "BelloCode",
            "LANG": processEnvironment["LANG"] ?? "C.UTF-8",
            "BELLOCODE_EXEC_CONFIG": execConfig.path, "SHELL": helper.path, "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
        ]
        if let value = processEnvironment["LC_ALL"] { env["LC_ALL"] = value }
        return TerminalLaunch(command: helper.path, args: [], environment: env)
    }

    /// Whether this launch runs in a container (the terminal shows it).
    public var isContainer: Bool { (command as NSString).lastPathComponent == "bellocode-exec" }

    static func loginShell(_ environment: [String: String]) -> String {
        if let entry = getpwuid(getuid()), let pointer = entry.pointee.pw_shell {
            let path = String(validatingCString: pointer) ?? ""
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let shell = environment["SHELL"], FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return "/bin/zsh"
    }
}

/// Decides which terminals to close when a thread settles or is archived (wired by the shell later). The default
/// closes running terminals that have shown no output for `idleFor` and run no foreground program besides the shell.
public struct TerminalIdlePolicy: Sendable {
    public var shouldClose: @Sendable (TerminalRecord, Date) -> Bool

    public init(shouldClose: @escaping @Sendable (TerminalRecord, Date) -> Bool) {
        self.shouldClose = shouldClose
    }

    public static func idle(for interval: TimeInterval) -> TerminalIdlePolicy {
        TerminalIdlePolicy { record, now in
            guard record.state.isRunning, now.timeIntervalSince(record.lastActivity) >= interval else { return false }
            let foreground = record.foregroundProcess.map { ($0 as NSString).lastPathComponent } ?? ""
            return foreground.isEmpty || ["zsh", "bash", "fish", "sh", "-zsh", "-bash", "login"].contains(foreground)
        }
    }

    public static let never = TerminalIdlePolicy { _, _ in false }
}

/// A user-presentable terminal failure.
public struct TerminalError: Error, Sendable, Hashable, CustomStringConvertible {
    public var userMessage: String
    public init(_ userMessage: String) { self.userMessage = userMessage }
    public var description: String { userMessage }
}
