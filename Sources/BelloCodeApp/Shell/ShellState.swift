import BelloCore
import Foundation

/// What the content area shows. Identity is the server's session ID or the project directory, never an index.
enum ShellSelection: Hashable, Codable, Sendable {
    /// An existing thread.
    case thread(SessionID)
    /// A new, unsent thread in a project (the "hero" composer). The thread is created on first send.
    case draft(directory: String)

    var threadID: SessionID? {
        if case .thread(let id) = self { id } else { nil }
    }
}

/// Per-window state restored on relaunch (AGENTS.md UX rule 9). Window frame and divider positions are saved by
/// AppKit autosave; everything else is here. Versioned JSON in `UserDefaults`; anything unreadable or from another
/// version falls back to defaults instead of failing.
struct ShellState: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// Bounds (AGENTS.md rule 5): the oldest entries beyond these are dropped when saving.
    static let maxManualUnread = 500
    static let maxNewThreadDrafts = 50

    var version = ShellState.currentVersion
    var selection: ShellSelection?
    var collapsedProjects: Set<String> = []
    var isNeedsYouCollapsed = false
    var isSidebarCollapsed = false
    var isRightPanelVisible = false
    var isTerminalVisible = false
    var rightPanelTab: String?
    /// Threads the user marked unread (local only; opencode has no "unview"). Cleared when the thread is opened.
    var manualUnread: [SessionID] = []
    /// Unsent text of new-thread drafts, by project directory. Existing threads keep drafts in the engine.
    var newThreadDrafts: [String: String] = [:]

    static func decode(_ data: Data?) -> ShellState {
        guard let data, let state = try? JSONDecoder().decode(ShellState.self, from: data),
            state.version == currentVersion
        else { return ShellState() }
        return state.bounded()
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(bounded())) ?? Data()
    }

    func bounded() -> ShellState {
        var copy = self
        if copy.manualUnread.count > Self.maxManualUnread {
            copy.manualUnread.removeFirst(copy.manualUnread.count - Self.maxManualUnread)
        }
        if copy.newThreadDrafts.count > Self.maxNewThreadDrafts {
            let keep = copy.newThreadDrafts.keys.sorted().prefix(Self.maxNewThreadDrafts)
            copy.newThreadDrafts = copy.newThreadDrafts.filter { keep.contains($0.key) }
        }
        copy.newThreadDrafts = copy.newThreadDrafts.filter { !$0.value.isEmpty }
        return copy
    }

    mutating func setManualUnread(_ id: SessionID, _ unread: Bool) {
        manualUnread.removeAll { $0 == id }
        if unread { manualUnread.append(id) }
    }
}

/// Loads and saves `ShellState` under one key. The mock and snapshot modes use their own defaults suite.
@MainActor
struct ShellStateStore {
    let defaults: UserDefaults?
    let key: String

    init(defaults: UserDefaults?, key: String = "BelloCode.ShellState") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> ShellState { ShellState.decode(defaults?.data(forKey: key)) }

    func save(_ state: ShellState) { defaults?.set(state.encoded(), forKey: key) }
}
