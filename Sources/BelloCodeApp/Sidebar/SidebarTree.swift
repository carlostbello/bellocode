import BelloCore
import DesignSystem
import Engine
import Foundation

/// How the sidebar groups threads (View ▸ Group Threads by Project).
enum SidebarGrouping: String, Codable, Sendable, CaseIterable {
    /// Projects, each with its sections (default).
    case byProject
    /// One list of sections across projects ("all threads by state").
    case byState
}

/// A sidebar row's identity: server IDs and project directories, never indexes (AGENTS.md rule 1). A thread can be
/// listed twice (under "Needs you" and in its section), so the two rows have distinct identities.
enum SidebarNodeID: Hashable, Sendable {
    case needsYouHeader
    case attention(SessionID)
    case projectsHeader
    case project(String)
    /// A section of a project (`scope` = its directory), or of the whole list when grouped by state (`scope` nil).
    case section(scope: String?, ThreadSection)
    case thread(SessionID)
    /// "No threads yet" under an empty project.
    case emptyProject(String)
    /// The filter matched nothing.
    case noResults
    /// The insertion gap of a drop preview (snapshots only; a real drag uses the outline view's own gap).
    case dropGap

    var sessionID: SessionID? {
        switch self {
        case .attention(let id), .thread(let id): id
        default: nil
        }
    }

    var projectDirectory: String? {
        switch self {
        case .project(let directory), .emptyProject(let directory): directory
        case .section(let scope, _): scope
        default: nil
        }
    }

    /// Source-list group rows (not selectable).
    var isGroup: Bool {
        switch self {
        case .needsYouHeader, .projectsHeader: true
        case .section(nil, _): true
        default: false
        }
    }

    var section: ThreadSection? {
        if case .section(_, let section) = self { section } else { nil }
    }

    /// A string form for restoration (scroll position, expansion).
    var restorationKey: String {
        switch self {
        case .needsYouHeader: "needs-you"
        case .attention(let id): "attention|\(id.rawValue)"
        case .projectsHeader: "projects"
        case .project(let directory): "project|\(directory)"
        case .section(let scope, let section): "section|\(scope ?? "*")|\(section.rawValue)"
        case .thread(let id): "thread|\(id.rawValue)"
        case .emptyProject(let directory): "empty|\(directory)"
        case .noResults: "no-results"
        case .dropGap: "gap"
        }
    }

    /// The expansion key of a section: "<directory or *>|<section>".
    static func sectionKey(scope: String?, _ section: ThreadSection) -> String { "\(scope ?? "*")|\(section.rawValue)" }
}

struct SidebarNode: Hashable, Sendable {
    var id: SidebarNodeID
    var children: [SidebarNode] = []
}

/// The sidebar's structure, built from engine state. Pure; the outline view diffs successive trees by identity, so
/// a status change never moves a row it does not have to, and a token never rebuilds the list.
enum SidebarTree {
    struct Project: Equatable, Sendable {
        var directory: String
        /// Each section's threads in display order (`ThreadSections.derive`). Missing or empty sections are not shown.
        var sections: [ThreadSection: [SessionID]] = [:]

        init(directory: String, sections: [ThreadSection: [SessionID]] = [:]) {
            self.directory = directory
            self.sections = sections
        }

        /// A project whose threads are all Active (tests and simple callers).
        init(directory: String, threadIDs: [SessionID]) {
            self.init(directory: directory, sections: threadIDs.isEmpty ? [:] : [.active: threadIDs])
        }

        var isEmpty: Bool { sections.values.allSatisfy(\.isEmpty) }
    }

    struct Input: Equatable, Sendable {
        /// The "Needs you" list in the engine's order (urgency, then age).
        var attention: [SessionID] = []
        var projects: [Project] = []
        var grouping: SidebarGrouping = .byProject
        /// A filter is active: empty projects are hidden and an empty result says so.
        var isFiltering = false
        /// Rows nested under a thread's row (docs/features/orchestration.md): its sub-agent and delegated children,
        /// oldest first, then the threads it created with `create_threads` (its fan-out group). Collapsible; nesting
        /// never reorders the top-level list.
        var lineage: [SessionID: [SessionID]] = [:]
        /// Created threads shown under their creator instead of at the top level, when the creator is listed in the
        /// same section (thread → creator).
        var nestedUnder: [SessionID: SessionID] = [:]
    }

    static func build(_ input: Input) -> [SidebarNode] {
        var roots: [SidebarNode] = []
        if !input.attention.isEmpty {
            var seen = Set<SessionID>()
            let items = input.attention.filter { seen.insert($0).inserted }.map { SidebarNode(id: .attention($0)) }
            roots.append(SidebarNode(id: .needsYouHeader, children: items))
        }
        var seenProjects = Set<String>()
        let projects = input.projects.filter { seenProjects.insert($0.directory).inserted }
        var seenThreads = Set<SessionID>()
        func threadNode(_ id: SessionID, depth: Int) -> SidebarNode {
            guard depth < 8, let children = input.lineage[id], !children.isEmpty else { return SidebarNode(id: .thread(id)) }
            let nested = children.filter { seenThreads.insert($0).inserted }.map { threadNode($0, depth: depth + 1) }
            return SidebarNode(id: .thread(id), children: nested)
        }
        func threads(_ ids: [SessionID]) -> [SidebarNode] {
            let listed = Set(ids)
            let topLevel = ids.filter { id in !(input.nestedUnder[id].map(listed.contains) ?? false) }
            let kept = topLevel.filter { seenThreads.insert($0).inserted }
            return kept.map { threadNode($0, depth: 0) }
        }
        switch input.grouping {
        case .byProject:
            let nodes: [SidebarNode] = projects.compactMap { project in
                let sections = ThreadSection.allCases.compactMap { section -> SidebarNode? in
                    let children = threads(project.sections[section] ?? [])
                    return children.isEmpty ? nil : SidebarNode(id: .section(scope: project.directory, section), children: children)
                }
                if sections.isEmpty {
                    if input.isFiltering { return nil }
                    return SidebarNode(id: .project(project.directory), children: [SidebarNode(id: .emptyProject(project.directory))])
                }
                return SidebarNode(id: .project(project.directory), children: sections)
            }
            if !nodes.isEmpty { roots.append(SidebarNode(id: .projectsHeader, children: nodes)) }
        case .byState:
            for section in ThreadSection.allCases {
                let children = threads(projects.flatMap { $0.sections[section] ?? [] })
                if !children.isEmpty { roots.append(SidebarNode(id: .section(scope: nil, section), children: children)) }
            }
        }
        if input.isFiltering, roots.allSatisfy({ $0.id == .needsYouHeader }) { roots.append(SidebarNode(id: .noResults)) }
        return roots
    }

    /// The row to highlight for a selection: the thread's row in its section (else its "Needs you" row), or the
    /// project row for a draft.
    static func node(for selection: ShellSelection?, in roots: [SidebarNode]) -> SidebarNodeID? {
        guard let selection else { return nil }
        let ids = Set(flatten(roots))
        switch selection {
        case .thread(let id):
            if ids.contains(.thread(id)) { return .thread(id) }
            if ids.contains(.attention(id)) { return .attention(id) }
            return nil
        case .draft(let directory):
            return ids.contains(.project(directory)) ? .project(directory) : nil
        }
    }

    /// All identities, depth first.
    static func flatten(_ nodes: [SidebarNode]) -> [SidebarNodeID] {
        nodes.flatMap { [$0.id] + flatten($0.children) }
    }

    /// Parent of every node (nil for roots). Used to detect a node moving between parents.
    static func parents(_ nodes: [SidebarNode], parent: SidebarNodeID? = nil) -> [SidebarNodeID: SidebarNodeID?] {
        var result: [SidebarNodeID: SidebarNodeID?] = [:]
        result.reserveCapacity(nodes.count * 4)
        collectParents(nodes, parent: parent, into: &result)
        return result
    }

    private static func collectParents(_ nodes: [SidebarNode], parent: SidebarNodeID?, into result: inout [SidebarNodeID: SidebarNodeID?]) {
        for node in nodes {
            result[node.id] = .some(parent)
            if !node.children.isEmpty { collectParents(node.children, parent: node.id, into: &result) }
        }
    }

    /// The batch of outline operations that turns `old` into `new`: removals first (deepest parents last does not
    /// matter; each parent's from the highest index), then insertions top-down (children of inserted nodes come from
    /// the data source). A node that changes parent or position is removed and inserted, so only it animates.
    struct Update: Equatable, Sendable {
        var removals: [(parent: SidebarNodeID?, index: Int)] = []
        var insertions: [(parent: SidebarNodeID?, index: Int)] = []
        /// Nodes that appear under a new parent (or are new), for expansion defaults.
        var inserted: [SidebarNodeID] = []

        static func == (lhs: Update, rhs: Update) -> Bool {
            lhs.removals.map { "\($0.parent.map { $0.restorationKey } ?? "-")@\($0.index)" }
                == rhs.removals.map { "\($0.parent.map { $0.restorationKey } ?? "-")@\($0.index)" }
                && lhs.insertions.map { "\($0.parent.map { $0.restorationKey } ?? "-")@\($0.index)" }
                    == rhs.insertions.map { "\($0.parent.map { $0.restorationKey } ?? "-")@\($0.index)" }
                && lhs.inserted == rhs.inserted
        }
    }

    static func update(from old: [SidebarNode], to new: [SidebarNode]) -> Update {
        var update = Update()
        let newParents = parents(new)
        let oldParents = parents(old)
        let oldChildren = childMap(old)
        let newChildren = childMap(new)
        // Removals: a child that is gone, or under another parent now, from each parent that stays.
        func removals(_ nodes: [SidebarNode], parent: SidebarNodeID?) {
            // A parent that is itself removed (or moved) takes its subtree with it.
            if let parent, newParents[parent] == nil || newParents[parent]! != oldParents[parent]! { return }
            let kept = keptInOrder(old: nodes.map(\.id), new: parent.map { newChildren[$0] ?? [] } ?? new.map(\.id))
            for (index, node) in nodes.enumerated().reversed() where !kept.contains(node.id) {
                update.removals.append((parent, index))
            }
            for node in nodes where kept.contains(node.id) && !node.children.isEmpty { removals(node.children, parent: node.id) }
        }
        removals(old, parent: nil)
        // Insertions: top-down, into parents that existed before under the same parent.
        func insertions(_ nodes: [SidebarNode], parent: SidebarNodeID?) {
            let kept = keptInOrder(old: parent.map { oldChildren[$0] ?? [] } ?? old.map(\.id), new: nodes.map(\.id))
            for (index, node) in nodes.enumerated() where !kept.contains(node.id) {
                update.insertions.append((parent, index))
                update.inserted.append(node.id)
            }
            for node in nodes where kept.contains(node.id) && !node.children.isEmpty { insertions(node.children, parent: node.id) }
        }
        insertions(new, parent: nil)
        return update
    }

    /// The children that keep their place: the longest run in common order (others are removed and re-inserted).
    private static func keptInOrder(old: [SidebarNodeID], new: [SidebarNodeID]) -> Set<SidebarNodeID> {
        if old == new { return Set(old) }
        let difference = new.difference(from: old)
        var kept = Set(old)
        for change in difference.removals {
            if case .remove(_, let element, _) = change { kept.remove(element) }
        }
        return kept.intersection(new)
    }

    private static func childMap(_ nodes: [SidebarNode], into map: inout [SidebarNodeID: [SidebarNodeID]]) {
        for node in nodes where !node.children.isEmpty {
            map[node.id] = node.children.map(\.id)
            childMap(node.children, into: &map)
        }
    }

    private static func childMap(_ nodes: [SidebarNode]) -> [SidebarNodeID: [SidebarNodeID]] {
        var map: [SidebarNodeID: [SidebarNodeID]] = [:]
        childMap(nodes, into: &map)
        return map
    }
}

/// Filters the sidebar: thread titles fuzzy-match the query, and a project whose name matches keeps all its threads.
enum SidebarFilter {
    static func apply(
        _ query: String, projects: [SidebarTree.Project], projectName: (String) -> String, title: (SessionID) -> String
    ) -> [SidebarTree.Project] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return projects }
        return projects.map { project in
            if FuzzyMatcher.match(trimmed, in: projectName(project.directory)) != nil { return project }
            var filtered = project
            filtered.sections = project.sections.mapValues { ids in ids.filter { FuzzyMatcher.match(trimmed, in: title($0)) != nil } }
            return filtered
        }
    }
}

/// What a thread row shows. Pure, so the mapping (status, unread, time, accessibility) is tested.
struct ThreadRowPresentation: Equatable, Sendable {
    var title: String
    /// Shown as a glyph; nil when the row is quiet (idle) or unread (the unread dot carries it).
    var glyphStatus: SessionStatus?
    var status: SessionStatus
    var isUnread: Bool
    /// Unread, or blocked on the user / failed: the only rows drawn with emphasis.
    var isEmphasized: Bool { isUnread || [.awaitingApproval, .awaitingAnswer, .failed].contains(status) }
    var timeText: String
    var childCount: Int
    /// For "Needs you" rows and the flat list: the project, shown as detail.
    var projectName: String?
    var accessibilityLabel: String

    init(
        session: Session, status: SessionStatus?, manuallyUnread: Bool, childCount: Int, projectName: String? = nil,
        snoozedUntil: Date? = nil, now: Date = Date()
    ) {
        let status = status ?? (session.isRunning ? .running : .idle)
        self.status = status
        title = session.displayTitle
        isUnread = status == .finishedUnread || manuallyUnread
        glyphStatus = (status == .idle || status == .finishedUnread) ? nil : status
        let reference = session.idleAt ?? session.busySince ?? session.updated
        if let snoozedUntil {
            timeText = "until " + Self.wakeText(snoozedUntil, now: now)
        } else {
            timeText = RelativeTime.short(reference.date, now: now)
        }
        self.childCount = childCount
        self.projectName = projectName
        var parts = [title]
        if let projectName { parts.append(projectName) }
        if status != .idle { parts.append(StatusGlyph(status).label) }
        if isUnread, status != .finishedUnread { parts.append("Unread") }
        if childCount > 0 { parts.append(childCount == 1 ? "1 sub-agent" : "\(childCount) sub-agents") }
        if let snoozedUntil {
            parts.append("Snoozed until \(Self.wakeText(snoozedUntil, now: now))")
        } else {
            parts.append(RelativeTime.spoken(reference.date, now: now))
        }
        accessibilityLabel = parts.joined(separator: ", ")
    }

    /// "18:00", "Tue 09:00", "24 Nov".
    static func wakeText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale.current
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.setLocalizedDateFormatFromTemplate("jmm")
        } else if date.timeIntervalSince(now) < 6 * 86_400 {
            formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("d MMM")
        }
        return formatter.string(from: date)
    }
}
