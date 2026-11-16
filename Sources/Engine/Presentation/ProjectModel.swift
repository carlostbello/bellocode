import BelloCore
import Foundation
import Observation

/// One sidebar row: a session and its derived status.
///
/// Threading: `@MainActor`. Updated only when this session or its status changes, so one busy thread re-renders one
/// row. The status always has a text label (`SessionStatus.label`); never show it by colour alone.
@MainActor
@Observable
public final class SessionRowModel: Identifiable {
    public let id: SessionID
    public private(set) var session: Session
    public private(set) var status: SessionAttention?

    init(session: Session, status: SessionAttention?) {
        id = session.id
        self.session = session
        self.status = status
    }

    func update(session newSession: Session?, status newStatus: SessionAttention?) {
        if let newSession, newSession != session { session = newSession }
        if let newStatus, newStatus != status { status = newStatus }
    }
}

/// The sessions of one project, for the sidebar.
///
/// Threading and ownership: `@MainActor`, owned by `EngineRoot` (one per project, created at launch from the cache).
/// Subscribes to its own `.sessions(projectID)` topic only.
///
/// `sessionIDs` lists top-level, unarchived threads, newest first by creation, so rows do not reshuffle while agents
/// work. It changes only when a thread is added, removed, archived or unarchived; everything else updates the row
/// model (`row(_:)`).
@MainActor
@Observable
public final class ProjectModel: Identifiable {
    public let projectID: ProjectID
    public nonisolated var id: ProjectID { projectID }

    /// Top-level, unarchived threads, newest first.
    public private(set) var sessionIDs: [SessionID] = []
    /// Archived top-level threads, newest first.
    public private(set) var archivedSessionIDs: [SessionID] = []

    @ObservationIgnored private var rows: [SessionID: SessionRowModel] = [:]
    @ObservationIgnored private let core: EngineCore
    @ObservationIgnored private let tasks = TaskBox()
    @ObservationIgnored private var subscription: ChangeSubscription?
    @ObservationIgnored private var generation = 0

    init(projectID: ProjectID, sessions: [Session], statuses: [SessionID: SessionAttention], core: EngineCore, store: ProjectionStore) {
        self.projectID = projectID
        self.core = core
        let subscription = store.observe(.sessions(projectID))
        self.subscription = subscription
        replace(sessions: sessions, statuses: statuses)
        tasks.set(
            "changes",
            Task { [weak self] in
                for await change in subscription {
                    guard let self else { return }
                    self.apply(change)
                }
            })
    }

    public func row(_ id: SessionID) -> SessionRowModel? { rows[id] }

    /// Child sessions (sub-agents) of a thread, newest first.
    public func children(of id: SessionID) -> [SessionID] {
        rows.values.filter { $0.session.parentID == id }.sorted { $0.session.created > $1.session.created }.map(\.id)
    }

    func close() {
        subscription?.cancel()
        tasks.cancelAll()
    }

    private func replace(sessions: [Session], statuses: [SessionID: SessionAttention]) {
        var newRows: [SessionID: SessionRowModel] = [:]
        for session in sessions {
            if let row = rows[session.id] {
                row.update(session: session, status: statuses[session.id])
                newRows[session.id] = row
            } else {
                newRows[session.id] = SessionRowModel(session: session, status: statuses[session.id])
            }
        }
        rows = newRows
        reorder()
    }

    private func reorder() {
        let topLevel = rows.values.filter { $0.session.parentID == nil || rows[$0.session.parentID!] == nil }
            .sorted { $0.session.created == $1.session.created ? $0.id > $1.id : $0.session.created > $1.session.created }
        let active = topLevel.filter { !$0.session.isArchived }.map(\.id)
        let archived = topLevel.filter { $0.session.isArchived }.map(\.id)
        if active != sessionIDs { sessionIDs = active }
        if archived != archivedSessionIDs { archivedSessionIDs = archived }
    }

    func apply(_ change: ChangeSet) {
        if change.overflowed {
            generation += 1
            let generation = self.generation
            let core = self.core
            let projectID = self.projectID
            tasks.set(
                "reload",
                Task { [weak self] in
                    let (sessions, statuses) = await core.sessions(projectID: projectID)
                    guard let self, generation == self.generation, !Task.isCancelled else { return }
                    self.replace(sessions: sessions, statuses: statuses)
                })
            return
        }
        var structural = false
        for id in change.removedSessions where rows[id] != nil {
            rows[id] = nil
            structural = true
        }
        for (id, session) in change.sessions {
            if let row = rows[id] {
                if row.session.isArchived != session.isArchived || row.session.parentID != session.parentID { structural = true }
                row.update(session: session, status: change.statuses[id])
            } else {
                rows[id] = SessionRowModel(session: session, status: change.statuses[id])
                structural = true
            }
        }
        for (id, status) in change.statuses where change.sessions[id] == nil { rows[id]?.update(session: nil, status: status) }
        if structural { reorder() }
    }
}

/// Providers, models and agents per location, for pickers.
///
/// Threading: `@MainActor`, owned by `EngineRoot`. Refreshed when opencode reports a catalog change.
@MainActor
@Observable
public final class CatalogModel {
    public private(set) var catalogs: [String: Catalog] = [:]
    /// The catalog of the default location (the first project), if loaded.
    public private(set) var current: Catalog?

    init() {}

    public func catalog(for directory: String) -> Catalog? { catalogs[directory] ?? current }

    func apply(_ catalog: Catalog, isDefault: Bool) {
        if catalogs[catalog.directory] != catalog { catalogs[catalog.directory] = catalog }
        if isDefault || current == nil || current?.directory == catalog.directory, current != catalog { current = catalog }
    }
}
