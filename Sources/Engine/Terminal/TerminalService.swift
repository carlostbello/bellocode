import BelloCore
import Foundation
import Observation
import OpenCodeKit

/// The app's terminals: opencode owns each PTY (so terminals survive app restarts and the agent can read them); this
/// service owns BelloCode's records of them per thread, persists those as app-owned state in the projection store,
/// reconciles them with the server, and makes streams for the views that show them.
///
/// Threading and ownership: `@MainActor`; one per engine (`Engine.terminals`). Thread models are cached (bounded)
/// and keep no tasks of their own beyond debounced saves; streams belong to the views. `shutdown()` detaches every
/// stream (PTYs keep running) and flushes pending saves.
@MainActor
public final class TerminalService {
    /// Loaded thread models kept in memory (least recently used dropped beyond this; their state is on disk).
    public static let threadCacheLimit = 64

    let store: ProjectionStore
    let client: @Sendable () async throws -> OpenCodeClient
    let socketFactory: PTYSocketFactory
    /// What a new terminal runs.
    public var launch: TerminalLaunch
    private var threads: [SessionID: ThreadTerminals] = [:]
    private var recency: [SessionID] = []
    private var streams: [WeakStream] = []

    public init(
        store: ProjectionStore, client: @escaping @Sendable () async throws -> OpenCodeClient,
        launch: TerminalLaunch = .userDefault(),
        socketFactory: @escaping PTYSocketFactory = { URLSessionPTYSocket(request: $0) }
    ) {
        self.store = store
        self.client = client
        self.launch = launch
        self.socketFactory = socketFactory
    }

    /// The terminals of a thread. Returns at once (empty until the saved set loads, within milliseconds), then
    /// reconciles with the server in the background.
    public func terminals(for sessionID: SessionID) -> ThreadTerminals {
        recency.removeAll { $0 == sessionID }
        recency.append(sessionID)
        if let existing = threads[sessionID] { return existing }
        let model = ThreadTerminals(sessionID: sessionID, service: self)
        threads[sessionID] = model
        while recency.count > Self.threadCacheLimit {
            let evicted = recency.removeFirst()
            threads.removeValue(forKey: evicted)?.flushSoon()
        }
        model.load()
        return model
    }

    /// A stream for showing `terminalID` in an emulator. Keep `cursor` with the emulator so a later stream for the
    /// same emulator replays only what it missed.
    public func makeStream(
        _ terminalID: String, in terminals: ThreadTerminals, sink: any TerminalOutputSink,
        cursor: TerminalStreamCursor = TerminalStreamCursor()
    ) -> TerminalStream {
        let stream = TerminalStream(
            terminalID: terminalID, owner: terminals, sink: sink, cursor: cursor, client: client, socketFactory: socketFactory)
        streams.removeAll { $0.stream == nil }
        streams.append(WeakStream(stream: stream))
        return stream
    }

    /// Writes every pending save.
    public func flush() async {
        for model in threads.values { await model.save() }
    }

    /// Detaches every stream (PTYs keep running on the server) and writes pending saves.
    public func shutdown() async {
        for box in streams { box.stream?.deactivate() }
        streams.removeAll()
        await flush()
    }

    /// Streams currently attached or attaching (diagnostics, tests).
    public var activeStreamCount: Int {
        streams.filter { box in
            guard let stream = box.stream else { return false }
            return stream.status != .detached && stream.status != .ended
        }.count
    }

    private struct WeakStream {
        weak var stream: TerminalStream?
    }
}

/// One thread's terminals: records (tab order, titles, run state with exit codes), selection, split and drawer
/// layout. Changes apply locally at once and are saved shortly after (debounced); server calls report failures in
/// `lastError` without losing local state.
///
/// Threading: `@MainActor`, `@Observable` (the drawer observes `set`).
@MainActor
@Observable
public final class ThreadTerminals {
    public let sessionID: SessionID
    public private(set) var set = ThreadTerminalSet()
    /// The saved set has been read (until then `set` is empty but may not be).
    public private(set) var isLoaded = false
    /// Terminals being created (the UI shows a "Starting…" placeholder; no record exists until the server answers).
    public private(set) var creatingCount = 0
    /// The last failure, for an inline message. Cleared by the next successful command or `clearError()`.
    public private(set) var lastError: TerminalError?
    /// The last reconcile with the server failed (offline): records may be stale.
    public private(set) var isStale = false

    @ObservationIgnored private let store: ProjectionStore
    @ObservationIgnored private let client: @Sendable () async throws -> OpenCodeClient
    @ObservationIgnored private let launch: TerminalLaunch
    @ObservationIgnored private let tasks = TaskBox()
    @ObservationIgnored private var dirty = false
    /// The latest save; each save runs after the one before it (see `save()`).
    @ObservationIgnored private var lastSave: Task<Void, Never>?
    @ObservationIgnored private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    init(sessionID: SessionID, service: TerminalService) {
        self.sessionID = sessionID
        store = service.store
        client = service.client
        launch = service.launch
    }

    // MARK: Loading and reconcile

    func load() {
        let store = self.store
        let id = sessionID
        tasks.set("load", Task { [weak self] in
            let saved = try? await store.terminalSet(id)
            guard let self else { return }
            if let saved, !self.dirty { self.set = saved }
            self.isLoaded = true
            for waiter in self.loadWaiters { waiter.resume() }
            self.loadWaiters.removeAll()
            await self.refresh()
        })
    }

    /// Returns once the saved set has been read.
    public func waitUntilLoaded() async {
        if isLoaded { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    /// Reconciles with the server's list: running records the server no longer has become `ended`; PTYs the server
    /// has for this session that we do not know (the agent's) are added; titles and directories refresh. Offline
    /// leaves everything as it is and sets `isStale`.
    public func refresh() async {
        await waitUntilLoaded()
        let infos: [PTYInfo]
        do {
            infos = try await client().terminals(sessionID: sessionID.rawValue)
        } catch {
            isStale = true
            return
        }
        isStale = false
        let byID = Dictionary(infos.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        var changed = false
        for index in set.records.indices {
            let record = set.records[index]
            if let info = byID[record.id] {
                var updated = record
                updated.title = info.title
                updated.userTitle = info.userTitle ?? record.userTitle
                updated.foregroundProcess = info.foregroundProcess
                updated.state = .running
                if updated != record {
                    set.records[index] = updated
                    changed = true
                }
            } else if record.state.isRunning {
                set.records[index].state = .ended(reason: "Ended while BelloCode was away")
                changed = true
            }
        }
        let known = Set(set.records.map(\.id))
        for info in infos where !known.contains(info.id) {
            set.records.append(
                TerminalRecord(
                    id: info.id, sessionID: sessionID, title: info.title, userTitle: info.userTitle, startDirectory: info.cwd,
                    foregroundProcess: info.foregroundProcess))
            changed = true
        }
        if set.selectedDrawer == nil { set.selectedDrawer = set.records(in: .drawer).first?.id }
        if set.selectedPanel == nil { set.selectedPanel = set.records(in: .panel).first?.id }
        if changed { markDirty() }
    }

    // MARK: Queries

    public func records(in placement: TerminalPlacement) -> [TerminalRecord] { set.records(in: placement) }
    public func record(_ id: String) -> TerminalRecord? { set.record(id) }
    public func selected(in placement: TerminalPlacement) -> String? {
        placement == .drawer ? set.selectedDrawer : set.selectedPanel
    }

    public func clearError() { lastError = nil }

    // MARK: Commands

    /// Starts a new terminal in `directory` (the thread's directory or worktree) and selects it.
    @discardableResult
    public func create(
        directory: String, placement: TerminalPlacement = .drawer, size: PTYSize? = nil, title: String? = nil
    ) async -> TerminalRecord? {
        await waitUntilLoaded()
        creatingCount += 1
        defer { creatingCount -= 1 }
        let number = set.nextNumber
        set.nextNumber += 1
        let title = title ?? "Terminal \(number)"
                do {
            let info = try await client().createTerminal(
                sessionID: sessionID.rawValue,
                PTYCreateRequest(
                    command: launch.command, args: launch.args, cwd: directory, title: title, env: launch.environment,
                    size: size?.clamped))
            let record = TerminalRecord(
                id: info.id, sessionID: sessionID, title: info.title, startDirectory: directory, placement: placement)
            set.records.append(record)
            select(record.id, in: placement)
            set.trim()
            lastError = nil
            markDirty()
            return record
        } catch {
            lastError = Self.error(error, doing: "start a terminal")
            markDirty()
            return nil
        }
    }

    /// Restarts an exited or ended terminal: a new PTY in the same directory replaces it in the same tab position.
    @discardableResult
    public func restart(_ id: String, size: PTYSize? = nil) async -> TerminalRecord? {
        guard let old = set.record(id) else { return nil }
        if old.state.isRunning { try? await client().deleteTerminal(id) }
                do {
            let info = try await client().createTerminal(
                sessionID: sessionID.rawValue,
                PTYCreateRequest(
                    command: launch.command, args: launch.args, cwd: old.startDirectory, title: old.title,
                    env: launch.environment, size: size?.clamped))
            guard let index = set.records.firstIndex(where: { $0.id == id }) else { return nil }
            var record = TerminalRecord(
                id: info.id, sessionID: sessionID, title: info.title, userTitle: old.userTitle,
                startDirectory: old.startDirectory, placement: old.placement)
            record.created = Date()
            set.records[index] = record
            if set.selectedDrawer == id { set.selectedDrawer = record.id }
            if set.selectedPanel == id { set.selectedPanel = record.id }
            if set.splitSecondary == id { set.splitSecondary = record.id }
            if let userTitle = old.userTitle {
                _ = try? await client().updateTerminal(record.id, PTYUpdateRequest(title: userTitle))
            }
            lastError = nil
            markDirty()
            return record
        } catch {
            lastError = Self.error(error, doing: "restart the terminal")
            return nil
        }
    }

    /// Closes a terminal: the record goes at once; a running PTY is deleted on the server (its process is killed).
    public func close(_ id: String) async {
        guard let index = set.records.firstIndex(where: { $0.id == id }) else { return }
        let record = set.records.remove(at: index)
        reselect(after: record, at: index)
        markDirty()
        guard record.state.isRunning else { return }
        do {
            try await client().deleteTerminal(id)
        } catch let error as OpenCodeError where error.status == 404 {
            // Already gone.
        } catch {
            lastError = Self.error(error, doing: "close the terminal")
        }
    }

    /// Renames a terminal (nil or empty restores the shell's title). Saved locally at once and sent to the server so
    /// the agent sees the same title.
    public func rename(_ id: String, to title: String?) async {
        guard let index = set.records.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        set.records[index].userTitle = value
        markDirty()
        guard set.records[index].state.isRunning else { return }
        do {
            try await client().updateTerminal(id, PTYUpdateRequest(title: .some(value)))
        } catch {
            lastError = Self.error(error, doing: "rename the terminal on the server")
        }
    }

    /// Moves a terminal to `index` among the terminals of its place.
    public func move(_ id: String, to index: Int) {
        guard let from = set.records.firstIndex(where: { $0.id == id }) else { return }
        let placement = set.records[from].placement
        var peers = set.records(in: placement)
        guard let peerIndex = peers.firstIndex(where: { $0.id == id }) else { return }
        let record = peers.remove(at: peerIndex)
        peers.insert(record, at: min(max(0, index), peers.count))
        var iterator = peers.makeIterator()
        set.records = set.records.map { $0.placement == placement ? iterator.next()! : $0 }
        markDirty()
    }

    /// Moves a terminal between the drawer and the right panel and selects it there.
    public func setPlacement(_ id: String, _ placement: TerminalPlacement) {
        guard let index = set.records.firstIndex(where: { $0.id == id }), set.records[index].placement != placement else { return }
        let old = set.records[index]
        set.records[index].placement = placement
        if old.placement == .drawer {
            if set.splitSecondary == id { set.splitSecondary = nil }
            if set.selectedDrawer == id { set.selectedDrawer = set.records(in: .drawer).first?.id }
        } else if set.selectedPanel == id {
            set.selectedPanel = set.records(in: .panel).first?.id
        }
        select(id, in: placement)
        markDirty()
    }

    public func select(_ id: String, in placement: TerminalPlacement) {
        guard set.record(id)?.placement == placement else { return }
        switch placement {
        case .drawer:
            guard set.selectedDrawer != id else { return }
            if set.splitSecondary == id { set.splitSecondary = set.selectedDrawer }
            set.selectedDrawer = id
        case .panel:
            guard set.selectedPanel != id else { return }
            set.selectedPanel = id
        }
        markDirty()
    }

    /// Selects the next (`offset` 1) or previous (-1) terminal of a place, wrapping.
    public func selectAdjacent(_ offset: Int, in placement: TerminalPlacement) {
        let peers = set.records(in: placement)
        guard !peers.isEmpty else { return }
        let current = peers.firstIndex { $0.id == selected(in: placement) } ?? 0
        select(peers[(current + offset + peers.count) % peers.count].id, in: placement)
    }

    /// Shows `id` beside the selected drawer terminal (nil un-splits).
    public func setSplit(_ id: String?) {
        guard id != set.splitSecondary else { return }
        if let id, set.record(id)?.placement != .drawer || id == set.selectedDrawer { return }
        set.splitSecondary = id
        markDirty()
    }

    /// Records the drawer's state for this thread (restored when the thread is shown again).
    public func setDrawer(open: Bool? = nil, height: Double? = nil) {
        var changed = false
        if let open, set.isDrawerOpen != open {
            set.isDrawerOpen = open
            changed = true
        }
        if let height, height > 0, abs((set.drawerHeight ?? 0) - height) >= 1 {
            set.drawerHeight = height.rounded()
            changed = true
        }
        if changed { markDirty() }
    }

    /// Closes the running terminals `policy` selects (thread settled or archived). Returns their IDs.
    @discardableResult
    public func closeIdle(policy: TerminalIdlePolicy, now: Date = Date()) async -> [String] {
        await waitUntilLoaded()
        let idle = set.records.filter { policy.shouldClose($0, now) }.map(\.id)
        for id in idle {
            guard let index = set.records.firstIndex(where: { $0.id == id }) else { continue }
            set.records[index].state = .ended(reason: "Closed while idle")
            try? await client().deleteTerminal(id)
        }
        if !idle.isEmpty { markDirty() }
        return idle
    }

    /// The shell reported its directory (OSC 7).
    public func updateDirectory(_ id: String, _ directory: String) {
        guard let index = set.records.firstIndex(where: { $0.id == id }), set.records[index].currentDirectory != directory else { return }
        set.records[index].currentDirectory = directory
        markDirty()
    }

    // MARK: Stream callbacks

    func streamExited(_ id: String, code: Int?) {
        guard let index = set.records.firstIndex(where: { $0.id == id }) else { return }
        set.records[index].state = .exited(code: code)
        set.records[index].foregroundProcess = nil
        markDirty()
        Task { await save() }
    }

    func streamEnded(_ id: String, reason: String) {
        guard let index = set.records.firstIndex(where: { $0.id == id }), set.records[index].state.isRunning else { return }
        set.records[index].state = .ended(reason: reason)
        markDirty()
    }

    func streamTitleChanged(_ id: String, title: String) {
        guard let index = set.records.firstIndex(where: { $0.id == id }), set.records[index].title != title else { return }
        set.records[index].title = title
        markDirty()
    }

    func streamForegroundChanged(_ id: String, process: String?) {
        guard let index = set.records.firstIndex(where: { $0.id == id }) else { return }
        set.records[index].foregroundProcess = process
    }

    func streamActivity(_ id: String) {
        guard let index = set.records.firstIndex(where: { $0.id == id }) else { return }
        set.records[index].lastActivity = Date()
        dirty = true
        scheduleSave(after: .seconds(5))
    }

    // MARK: Persistence

    private func markDirty() {
        dirty = true
        scheduleSave(after: .milliseconds(300))
    }

    private func scheduleSave(after delay: Duration) {
        tasks.set("save", Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.save()
        })
    }

    func flushSoon() { if dirty { Task { await save() } } }

    /// Writes the set now if it changed, and returns once it is on disk. Saves run one after another: a save that
    /// finds the set clean must still wait for a write already in flight (a scheduled or exit-triggered save clears
    /// `dirty` before its write completes), otherwise its caller (shutdown, flush) could return before the set is stored.
    public func save() async {
        let previous = lastSave
        let save = Task { [weak self] in
            await previous?.value
            await self?.write()
        }
        lastSave = save
        await save.value
    }

    private func write() async {
        guard dirty else { return }
        dirty = false
        do {
            try await store.setTerminalSet(set, for: sessionID)
        } catch {
            dirty = true
        }
    }

    private func reselect(after removed: TerminalRecord, at index: Int) {
        if set.splitSecondary == removed.id { set.splitSecondary = nil }
        let peers = set.records(in: removed.placement)
        let replacement = peers.last { set.records.firstIndex(of: $0).map { $0 < index } ?? false } ?? peers.first
        switch removed.placement {
        case .drawer where set.selectedDrawer == removed.id:
            set.selectedDrawer = replacement?.id
            if set.splitSecondary == set.selectedDrawer { set.splitSecondary = nil }
        case .panel where set.selectedPanel == removed.id:
            set.selectedPanel = replacement?.id
        default: break
        }
    }

    static func error(_ error: any Error, doing action: String) -> TerminalError {
        if let engine = error as? EngineError, case .offline = engine {
            return TerminalError("Could not \(action): BelloCode is not connected to opencode.")
        }
        if let error = error as? OpenCodeError {
            if case .transport = error { return TerminalError("Could not \(action): opencode is not reachable.") }
            if error.status == 503 { return TerminalError("Could not \(action): opencode's terminal service is unavailable.") }
            return TerminalError("Could not \(action). \(error.description)")
        }
        return TerminalError("Could not \(action).")
    }
}
