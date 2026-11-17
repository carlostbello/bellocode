import BelloCore
import DesignSystem
import Engine
import Foundation

/// What the palette was opened for.
enum PaletteMode: String, Sendable, CaseIterable {
    /// ⌘K: actions first, then threads and projects; `>` limits to actions.
    case commands
    /// ⌘P: threads, projects and files of the current project.
    case quickOpen
    /// ⇧⌘F: full-text message search, grouped by thread.
    case messages

    var placeholder: String {
        switch self {
        case .commands: "Type a command, or @ thread, # project, / file"
        case .quickOpen: "Open a thread, project or file (> for commands)"
        case .messages: "Search messages in every thread"
        }
    }
}

/// Which kinds a query searches, from its prefix: `>` actions, `@` threads, `#` projects, `/` files.
enum PaletteScope: String, Sendable {
    case all, actions, threads, projects, files

    var title: String {
        switch self {
        case .all: "All"
        case .actions: "Actions"
        case .threads: "Threads"
        case .projects: "Projects"
        case .files: "Files"
        }
    }
}

struct PaletteQuery: Equatable, Sendable {
    var scope: PaletteScope
    var text: String

    static func parse(_ raw: String, mode: PaletteMode) -> PaletteQuery {
        guard mode != .messages, let first = raw.first else { return PaletteQuery(scope: .all, text: raw.trimmingCharacters(in: .whitespaces)) }
        let rest = String(raw.dropFirst()).trimmingCharacters(in: .whitespaces)
        switch first {
        case ">": return PaletteQuery(scope: .actions, text: rest)
        case "@": return PaletteQuery(scope: .threads, text: rest)
        case "#": return PaletteQuery(scope: .projects, text: rest)
        case "/": return PaletteQuery(scope: .files, text: rest)
        default: return PaletteQuery(scope: .all, text: raw.trimmingCharacters(in: .whitespaces))
        }
    }
}

/// One palette row's subject.
enum PalettePayload: Hashable, Sendable {
    case command(ShellCommand)
    case thread(SessionID)
    case project(directory: String, isArchived: Bool)
    /// A file of a project: its directory and the path relative to it.
    case file(directory: String, path: String)
    /// A search hit: the top-level thread, the thread the message is in, and the message.
    case message(thread: SessionID, session: SessionID, message: MessageID)
}

struct PaletteItem: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case command, thread, project, file, message }

    /// The frecency key (stable identity): "command:newThread", "thread:<id>", "project:<dir>", "file:<dir>/<path>".
    var id: String
    var kind: Kind
    var payload: PalettePayload
    var title: String
    var subtitle: String?
    /// The shortcut as the menu shows it ("⇧⌘P").
    var shortcut: String?
    /// Why it cannot run now (commands); shown instead of the shortcut, and Return beeps.
    var disabledReason: String?
    var symbolName: String
    /// Matched characters in `title`, for bold.
    var titleMatches: [Int] = []
    var snippet: SearchSnippet?
    var score: Double = 0

    var isEnabled: Bool { disabledReason == nil }
}

struct PaletteSection: Hashable, Sendable {
    var title: String
    var items: [PaletteItem]
}

/// A candidate prepared once per palette opening (the fuzzy matcher reuses its folded form on every keystroke).
struct PaletteCandidate: Sendable {
    var item: PaletteItem
    var prepared: FuzzyMatcher.Prepared
    /// Synonyms ("create" for New Thread), matched at a lower weight.
    var keywords: [FuzzyMatcher.Prepared] = []
    /// A secondary text matched at a lower weight (a project's path).
    var secondary: FuzzyMatcher.Prepared?

    init(_ item: PaletteItem, keywords: [String] = [], secondary: String? = nil) {
        self.item = item
        prepared = FuzzyMatcher.Prepared(item.title)
        self.keywords = keywords.map(FuzzyMatcher.Prepared.init)
        self.secondary = secondary.map(FuzzyMatcher.Prepared.init)
    }
}

/// The local candidates of one opening, read from the cache once (never a spinner for local data).
struct PaletteSources: Sendable {
    var commands: [PaletteCandidate] = []
    /// Most recently active first (the order used when the query is empty).
    var threads: [PaletteCandidate] = []
    var projects: [PaletteCandidate] = []
    /// Results of the last server file search (kept while a newer one runs, filtered locally: no flicker).
    var files: [PaletteCandidate] = []
}

/// Ranking: fuzzy score, plus frecency, plus the pick remembered for this query; fixed group order per mode, stable
/// tie-breaks (title, then identity), so results never reshuffle between equal keystrokes. Pure; tested directly.
enum PaletteSearch {
    static let limits: [PaletteItem.Kind: Int] = [.command: 12, .thread: 20, .project: 8, .file: 30]
    static let recentLimit = 8

    static func results(
        _ query: PaletteQuery, mode: PaletteMode, sources: PaletteSources, frecency: FrecencyIndex, now: Timestamp
    ) -> [PaletteSection] {
        if query.text.isEmpty { return emptyResults(query.scope, mode: mode, sources: sources, frecency: frecency, now: now) }
        let prepared = FuzzyMatcher.PreparedQuery(query.text)
        let picked = frecency.pick(for: query.text, now: now)
        func rank(_ candidates: [PaletteCandidate], kind: PaletteItem.Kind) -> [PaletteItem] {
            var ranked: [PaletteItem] = []
            ranked.reserveCapacity(64)
            for candidate in candidates {
                var item = candidate.item
                if let match = FuzzyMatcher.match(prepared, in: candidate.prepared) {
                    item.titleMatches = match.positions
                    item.score = match.score
                } else if let match = candidate.keywords.lazy.compactMap({ FuzzyMatcher.match(prepared, in: $0) }).first {
                    item.titleMatches = []
                    item.score = match.score * 0.6
                } else if let secondary = candidate.secondary, let match = FuzzyMatcher.match(prepared, in: secondary) {
                    item.titleMatches = []
                    item.score = match.score * 0.5
                } else {
                    continue
                }
                let frecent = frecency.score(item.id, now: now)
                if frecent > 0 { item.score += log2(1 + frecent) * 1.5 }
                if item.id == picked { item.score += 100 }
                if !item.isEnabled { item.score -= 8 }
                ranked.append(item)
            }
            ranked.sort(by: order)
            return Array(ranked.prefix(limits[kind] ?? 20))
        }
        var sections: [PaletteSection] = []
        func add(_ title: String, _ items: [PaletteItem]) {
            if !items.isEmpty { sections.append(PaletteSection(title: title, items: items)) }
        }
        let scope = query.scope
        let commandsFirst = mode == .commands || scope == .actions
        if commandsFirst, scope == .all || scope == .actions { add("Actions", rank(sources.commands, kind: .command)) }
        if scope == .all || scope == .threads { add("Threads", rank(sources.threads, kind: .thread)) }
        if scope == .all || scope == .projects { add("Projects", rank(sources.projects, kind: .project)) }
        if mode == .quickOpen || scope == .files, scope == .all || scope == .files { add("Files", rank(sources.files, kind: .file)) }
        if !commandsFirst, scope == .all, mode == .commands { add("Actions", rank(sources.commands, kind: .command)) }
        // The remembered pick for this query leads, wherever its group is.
        if let picked, let index = sections.firstIndex(where: { $0.items.first?.id == picked }), index > 0 {
            sections.insert(sections.remove(at: index), at: 0)
        }
        return sections
    }

    /// Higher score first; ties by title, then identity (deterministic).
    static func order(_ lhs: PaletteItem, _ rhs: PaletteItem) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let titles = lhs.title.localizedStandardCompare(rhs.title)
        if titles != .orderedSame { return titles == .orderedAscending }
        return lhs.id < rhs.id
    }

    /// No query: recent picks (frecency), then each group's default order.
    static func emptyResults(
        _ scope: PaletteScope, mode: PaletteMode, sources: PaletteSources, frecency: FrecencyIndex, now: Timestamp
    ) -> [PaletteSection] {
        var byID: [String: PaletteItem] = [:]
        let pools: [PaletteCandidate] = switch scope {
        case .all: (mode == .commands ? sources.commands : []) + sources.threads + sources.projects + sources.files
        case .actions: sources.commands
        case .threads: sources.threads
        case .projects: sources.projects
        case .files: sources.files
        }
        for candidate in pools { byID[candidate.item.id] = candidate.item }
        let prefix: String = switch scope {
        case .all: ""
        case .actions: "command:"
        case .threads: "thread:"
        case .projects: "project:"
        case .files: "file:"
        }
        let recent = frecency.top(prefix: prefix, limit: recentLimit * 3, now: now).compactMap { byID[$0] }.prefix(recentLimit)
        let recentIDs = Set(recent.map(\.id))
        var sections: [PaletteSection] = []
        if !recent.isEmpty { sections.append(PaletteSection(title: "Recent", items: Array(recent))) }
        func rest(_ candidates: [PaletteCandidate], limit: Int, sorted: Bool = false) -> [PaletteItem] {
            var items = candidates.map(\.item).filter { !recentIDs.contains($0.id) }
            if sorted {
                items.sort { lhs, rhs in
                    if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled }
                    return order(lhs, rhs)
                }
            }
            return Array(items.prefix(limit))
        }
        func add(_ title: String, _ items: [PaletteItem]) {
            if !items.isEmpty { sections.append(PaletteSection(title: title, items: items)) }
        }
        switch scope {
        case .all:
            if mode == .commands { add("Actions", rest(sources.commands, limit: 200, sorted: true)) }
            add("Threads", rest(sources.threads, limit: mode == .commands ? 8 : 20))
            add("Projects", rest(sources.projects, limit: 8))
            if mode == .quickOpen { add("Files", rest(sources.files, limit: 20)) }
        case .actions: add("Actions", rest(sources.commands, limit: 200, sorted: true))
        case .threads: add("Threads", rest(sources.threads, limit: 50))
        case .projects: add("Projects", rest(sources.projects, limit: 50))
        case .files: add("Files", rest(sources.files, limit: 50))
        }
        return sections
    }

    /// Search groups as palette sections: one section per thread (title, project and date), one row per hit.
    static func messageSections(_ groups: [ThreadSearchGroup], projectName: (String) -> String, now: Date) -> [PaletteSection] {
        groups.map { group in
            let header = [projectName(group.directory), RelativeTime.short(group.newest.date, now: now)]
                + (group.isArchived ? ["Archived"] : [])
                + (group.totalHits > group.hits.count ? ["\(group.totalHits) matches"] : [])
            let items = group.hits.map { hit in
                PaletteItem(
                    id: "thread:\(group.sessionID.rawValue)", kind: .message,
                    payload: .message(thread: group.sessionID, session: hit.sessionID, message: hit.messageID),
                    title: hit.snippet.text, subtitle: RelativeTime.short(hit.created.date, now: now), symbolName: "text.bubble",
                    snippet: hit.snippet)
            }
            return PaletteSection(title: "\(group.title) — \(header.joined(separator: " · "))", items: items)
        }
    }
}
