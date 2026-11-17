import BelloCore
import Engine
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

/// Per-thread layout: whether the right panel shows (and which tab) while that thread is displayed.
struct ThreadPanelState: Codable, Equatable, Sendable {
    var isRightPanelVisible: Bool
    var rightPanelTab: String?
}

/// Per-window state restored on relaunch (AGENTS.md UX rule 9). Window frame and divider positions are saved by
/// AppKit autosave; everything else is here. Versioned JSON in `UserDefaults`; anything unreadable or from another
/// version falls back to defaults instead of failing, and fields added later decode as their defaults.
struct ShellState: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// Bounds (AGENTS.md rule 5): the oldest entries beyond these are dropped when saving.
    static let maxManualUnread = 500
    static let maxNewThreadDrafts = 50
    static let maxThreadPanels = 200
    static let maxSectionKeys = 400

    var version = ShellState.currentVersion
    var selection: ShellSelection?
    var collapsedProjects: Set<String> = []
    var isNeedsYouCollapsed = false
    var isSidebarCollapsed = false
    var isRightPanelVisible = false
    var isTerminalVisible = false
    var rightPanelTab: String?
    /// Legacy (M1): threads marked unread, now kept by the engine (`ThreadOrganisation.markedUnread`).
    var manualUnread: [SessionID] = []
    /// Unsent text of new-thread drafts, by project directory. Existing threads keep drafts in the engine.
    var newThreadDrafts: [String: String] = [:]
    var grouping: SidebarGrouping = .byProject
    /// Sections the user expanded or collapsed against their default ("<directory or *>|<section>").
    var toggledSections: Set<String> = []
    /// The sidebar row at the top of the viewport and how far it is scrolled past (restored after relaunch).
    var sidebarTopRow: String?
    var sidebarTopOffset: Double = 0
    /// Right panel per thread (session ID → state); a thread without an entry uses the window's.
    var threadPanels: [String: ThreadPanelState] = [:]
    /// Most recent last; `threadPanels` is trimmed oldest first.
    var threadPanelOrder: [String] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, selection, collapsedProjects, isNeedsYouCollapsed, isSidebarCollapsed, isRightPanelVisible
        case isTerminalVisible, rightPanelTab, manualUnread, newThreadDrafts, grouping, toggledSections, sidebarTopRow
        case sidebarTopOffset, threadPanels, threadPanelOrder
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        selection = try? c.decodeIfPresent(ShellSelection.self, forKey: .selection)
        collapsedProjects = (try? c.decodeIfPresent(Set<String>.self, forKey: .collapsedProjects)) ?? []
        isNeedsYouCollapsed = (try? c.decodeIfPresent(Bool.self, forKey: .isNeedsYouCollapsed)) ?? false
        isSidebarCollapsed = (try? c.decodeIfPresent(Bool.self, forKey: .isSidebarCollapsed)) ?? false
        isRightPanelVisible = (try? c.decodeIfPresent(Bool.self, forKey: .isRightPanelVisible)) ?? false
        isTerminalVisible = (try? c.decodeIfPresent(Bool.self, forKey: .isTerminalVisible)) ?? false
        rightPanelTab = try? c.decodeIfPresent(String.self, forKey: .rightPanelTab)
        manualUnread = (try? c.decodeIfPresent([SessionID].self, forKey: .manualUnread)) ?? []
        newThreadDrafts = (try? c.decodeIfPresent([String: String].self, forKey: .newThreadDrafts)) ?? [:]
        grouping = (try? c.decodeIfPresent(SidebarGrouping.self, forKey: .grouping)) ?? .byProject
        toggledSections = (try? c.decodeIfPresent(Set<String>.self, forKey: .toggledSections)) ?? []
        sidebarTopRow = try? c.decodeIfPresent(String.self, forKey: .sidebarTopRow)
        sidebarTopOffset = (try? c.decodeIfPresent(Double.self, forKey: .sidebarTopOffset)) ?? 0
        threadPanels = (try? c.decodeIfPresent([String: ThreadPanelState].self, forKey: .threadPanels)) ?? [:]
        threadPanelOrder = (try? c.decodeIfPresent([String].self, forKey: .threadPanelOrder)) ?? []
    }

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
        copy.threadPanelOrder = copy.threadPanelOrder.filter { copy.threadPanels[$0] != nil }
        if copy.threadPanelOrder.count > Self.maxThreadPanels {
            let drop = copy.threadPanelOrder.prefix(copy.threadPanelOrder.count - Self.maxThreadPanels)
            for key in drop { copy.threadPanels[key] = nil }
            copy.threadPanelOrder.removeFirst(drop.count)
        }
        copy.threadPanels = copy.threadPanels.filter { copy.threadPanelOrder.contains($0.key) }
        if copy.toggledSections.count > Self.maxSectionKeys {
            copy.toggledSections = Set(copy.toggledSections.sorted().prefix(Self.maxSectionKeys))
        }
        return copy
    }

    mutating func setManualUnread(_ id: SessionID, _ unread: Bool) {
        manualUnread.removeAll { $0 == id }
        if unread { manualUnread.append(id) }
    }

    mutating func setPanel(_ panel: ThreadPanelState, for id: SessionID) {
        threadPanels[id.rawValue] = panel
        threadPanelOrder.removeAll { $0 == id.rawValue }
        threadPanelOrder.append(id.rawValue)
    }

    func isSectionExpanded(scope: String?, _ section: ThreadSection) -> Bool {
        let toggled = toggledSections.contains(SidebarNodeID.sectionKey(scope: scope, section))
        return section.isCollapsedByDefault ? toggled : !toggled
    }

    mutating func setSectionExpanded(scope: String?, _ section: ThreadSection, _ expanded: Bool) {
        let key = SidebarNodeID.sectionKey(scope: scope, section)
        let toggled = section.isCollapsedByDefault ? expanded : !expanded
        if toggled { toggledSections.insert(key) } else { toggledSections.remove(key) }
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
