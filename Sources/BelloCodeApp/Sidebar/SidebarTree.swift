import BelloCore
import DesignSystem
import Foundation

/// A sidebar row's identity: server IDs and project directories, never indexes (AGENTS.md rule 1). A thread can be
/// listed twice (under "Needs you" and under its project), so the two rows have distinct identities.
enum SidebarNodeID: Hashable, Sendable {
    case needsYouHeader
    case attention(SessionID)
    case projectsHeader
    case project(String)
    case thread(SessionID)
    /// "No threads yet" under an empty project.
    case emptyProject(String)

    var sessionID: SessionID? {
        switch self {
        case .attention(let id), .thread(let id): id
        default: nil
        }
    }

    var projectDirectory: String? {
        switch self {
        case .project(let directory), .emptyProject(let directory): directory
        default: nil
        }
    }

    var isGroup: Bool { self == .needsYouHeader || self == .projectsHeader }
}

struct SidebarNode: Hashable, Sendable {
    var id: SidebarNodeID
    var children: [SidebarNode] = []
}

/// The sidebar's structure, built from engine state. Pure; the outline view diffs successive trees by identity, so
/// a status change never moves a row and a token never rebuilds the list.
enum SidebarTree {
    struct Project: Equatable, Sendable {
        var directory: String
        /// Top-level, unarchived threads, newest created first (the engine's stable order).
        var threadIDs: [SessionID]
    }

    struct Input: Equatable, Sendable {
        /// The "Needs you" list in the engine's order (urgency, then age).
        var attention: [SessionID] = []
        var projects: [Project] = []
    }

    static func build(_ input: Input) -> [SidebarNode] {
        var roots: [SidebarNode] = []
        if !input.attention.isEmpty {
            var seen = Set<SessionID>()
            let items = input.attention.filter { seen.insert($0).inserted }.map { SidebarNode(id: .attention($0)) }
            roots.append(SidebarNode(id: .needsYouHeader, children: items))
        }
        guard !input.projects.isEmpty else { return roots }
        var seenProjects = Set<String>()
        var seenThreads = Set<SessionID>()
        let projects = input.projects.filter { seenProjects.insert($0.directory).inserted }.map { project in
            let threads = project.threadIDs.filter { seenThreads.insert($0).inserted }.map { SidebarNode(id: .thread($0)) }
            return SidebarNode(id: .project(project.directory), children: threads.isEmpty ? [SidebarNode(id: .emptyProject(project.directory))] : threads)
        }
        roots.append(SidebarNode(id: .projectsHeader, children: projects))
        return roots
    }

    /// The row to highlight for a selection: the thread's row under its project (else its "Needs you" row), or the
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
        for node in nodes {
            result[node.id] = parent
            result.merge(parents(node.children, parent: node.id)) { $1 }
        }
        return result
    }
}

/// What a thread row shows. Pure, so the mapping (status, unread, time, accessibility) is tested.
struct ThreadRowPresentation: Equatable, Sendable {
    var title: String
    /// Shown as a glyph; nil when the row is quiet (idle) or unread (the unread dot carries it).
    var glyphStatus: SessionStatus?
    var status: SessionStatus
    var isUnread: Bool
    var timeText: String
    var childCount: Int
    /// For "Needs you" rows: the project, shown as detail.
    var projectName: String?
    var accessibilityLabel: String

    init(
        session: Session, status: SessionStatus?, manuallyUnread: Bool, childCount: Int, projectName: String? = nil,
        now: Date = Date()
    ) {
        let status = status ?? (session.isRunning ? .running : .idle)
        self.status = status
        title = session.displayTitle
        isUnread = status == .finishedUnread || manuallyUnread
        glyphStatus = (status == .idle || status == .finishedUnread) ? nil : status
        let reference = session.idleAt ?? session.busySince ?? session.updated
        timeText = RelativeTime.short(reference.date, now: now)
        self.childCount = childCount
        self.projectName = projectName
        var parts = [title]
        if let projectName { parts.append(projectName) }
        if status != .idle { parts.append(StatusGlyph(status).label) }
        if isUnread, status != .finishedUnread { parts.append("Unread") }
        if childCount > 0 { parts.append(childCount == 1 ? "1 sub-agent" : "\(childCount) sub-agents") }
        parts.append(RelativeTime.spoken(reference.date, now: now))
        accessibilityLabel = parts.joined(separator: ", ")
    }
}
