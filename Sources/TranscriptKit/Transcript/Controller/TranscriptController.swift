import AppKit
import BelloCore
import DesignSystem
import Observation
import QuartzCore
import os

let transcriptSignposter = OSSignposter(subsystem: "BelloCode.Transcript", category: .pointsOfInterest)

/// Callbacks to the host (the shell).
@MainActor
public protocol TranscriptControllerDelegate: AnyObject {
    /// The user asked to open a sub-agent's thread.
    func transcript(_ controller: TranscriptController, openChildThread id: SessionID)
    /// The scroll anchor changed (debounced after scrolling ends); persist it for restoration.
    func transcriptAnchorDidChange(_ controller: TranscriptController)
}

/// Where the reader is, for restoring a thread's scroll position: a message and the offset of the viewport's top from
/// the top of that message's first row. `nil` means "at the bottom, following".
public struct TranscriptAnchor: Equatable, Sendable {
    public var messageID: MessageID
    public var offset: Double

    public init(messageID: MessageID, offset: Double) {
        self.messageID = messageID
        self.offset = offset
    }
}

/// The production transcript: a virtualised NSTableView of CoreText-drawn rows over a `TranscriptSource`.
///
/// Owns all transcript state outside the reusable views: rows (by server ID), per-row presentation state, the height
/// cache, a bounded layout cache, the streaming tails, the selection and find state. Parsing, highlighting and layout
/// run off the main actor and return immutable layouts that are applied only if their key (row version, UI version,
/// width, theme) still matches. See docs/features/transcript.md.
@MainActor
public final class TranscriptController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    public let container: TranscriptContainerView
    public let scrollView: NSScrollView
    public let tableView: TranscriptTableView
    let jumpPill = JumpPillView()
    let findBar = FindBarView()
    let emptyLabel = NSTextField(labelWithString: "")

    public weak var delegate: (any TranscriptControllerDelegate)?
    public private(set) weak var source: (any TranscriptSource)?
    public let highlighter: any HighlightService
    public let imageLoader: any TranscriptImageLoading
    public let blockCache = RenderBlockCache()
    public var pasteboard: NSPasteboard = .general
    /// Opens links and files (default: NSWorkspace).
    public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    // MARK: Model (row-ordered) and per-row caches

    public internal(set) var rows: [TranscriptRow] = []
    var rowIndex: [RowID: Int] = [:]
    var ui: [RowID: RowUIState] = [:]
    var heights: [CGFloat] = []
    var heightKeys: [LayoutKey?] = []
    var knownIDs: [MessageID] = []
    var segmentCache: [MessageID: (revision: Int, turn: MessageID?, segments: [RowBuilder.Segment])] = [:]
    var reasoningStarts: [PartID: CFTimeInterval] = [:]
    var reasoningDurations: [PartID: TimeInterval] = [:]
    var lastRunning = false
    var isReady = false

    // Observation.
    var trackedMessages: Set<MessageID> = []
    var dirtyMessages: Set<MessageID> = []
    var listDirty = true
    var syncScheduled = false
    var observationGeneration = 0
    /// Newest messages tracked individually (older finished ones are re-validated when the list changes).
    static let trackedTail = 256

    // Layout cache (LRU by access tick), bounded by count and CTLine cost.
    var layouts: [RowID: RowLayout] = [:]
    var layoutTick: [RowID: UInt64] = [:]
    var tick: UInt64 = 0
    var layoutCacheCost = 0
    public var layoutCacheLimit = 300
    public var layoutCacheCostLimit = 25_000
    var inflight: [RowID: LayoutKey] = [:]
    var layoutTasks: [RowID: Task<Void, Never>] = [:]
    let maxInflightPrefetch = 10
    var pendingHeights: [RowID: CGFloat] = [:]
    var flushScheduled = false
    var isAdjustingScroll = false
    var generation = 0
    /// Evicted layouts waiting to be released after the frame (see `bury`).
    var graveyard: [RowLayout] = []
    var graveyardScheduled = false
    static let graveyardLimit = 64
    var lastPrefetchRange: Range<Int> = 0..<0
    var prefetchScheduled = false
    var scrollVelocity: CGFloat = 0
    var lastBoundsY: CGFloat = 0
    var lastBoundsTime: CFTimeInterval = 0

    // Geometry and appearance.
    public internal(set) var contentWidth: CGFloat = 0
    public internal(set) var theme: TranscriptTheme
    var themeRevision = 0
    public var baseFontSize: CGFloat {
        didSet { if baseFontSize != oldValue { appearanceChanged() } }
    }

    // Scrolling.
    public internal(set) var following = true
    var liveScrolling = false
    var lastWheelTime: CFTimeInterval = 0
    var hasNewOutput = false
    var pillTask: Task<Void, Never>?
    var anchorTask: Task<Void, Never>?
    var lastAnchorChange: CFTimeInterval = 0
    /// A new turn's user row is held near the top until the reply fills the viewport.
    var turnAnchor: RowID?
    var spacerHeight: CGFloat = TranscriptMetrics.bottomPadding
    var pendingRestore: TranscriptAnchor??
    var restoreAttempts = 0
    var loadOlderTask: Task<Void, Never>?

    // Images.
    var images: [String: CGImage] = [:]
    /// Last draw tick per decoded image (LRU).
    var imageTick: [String: UInt64] = [:]
    var imageBytes = 0
    /// Decoded image budget (bytes of bitmap data). Each drawn image also costs a GPU-side copy of similar size while
    /// it lives, so this bound roughly halves what images add to the footprint. The G1-B fixture's 640×360 images
    /// at 96 MB (FIFO) were the largest single item of the peak footprint.
    public var imageByteLimit = 32 << 20
    var imageSizes: [String: CGSize] = [:]
    var imageRequests: Set<String> = []
    var imageTasks: [String: Task<Void, Never>] = [:]
    var imageRows: [String: Set<RowID>] = [:]
    var imageSourceCache: [RowID: (version: Int, sources: [String])] = [:]

    // Inner scrolling (code, tables, tool output) and per-block state.
    var scrollOffsets: [RowID: [Int: CGPoint]] = [:]
    var innerScrollTarget: (row: RowID, block: Int)?
    var copiedBlock: (row: RowID, block: Int)?
    var copiedTask: Task<Void, Never>?
    var hover: (row: RowID, block: Int, action: HotspotAction)?
    var hoverLink: String?

    // Selection.
    public internal(set) var selection: TranscriptSelection?
    var dragStartWindowPoint: NSPoint?
    var lastDragWindowPoint: NSPoint = .zero
    var didDrag = false
    var clickCandidate: (row: RowID, block: Int, action: HotspotAction)?
    var linkCandidate: String?
    var autoscrollTimer: Timer?
    var lastAutoscrollTime: CFTimeInterval = 0
    var selectionGranularity: SelectionGranularity = .character
    enum SelectionGranularity { case character, word, paragraph }
    var contextRow: RowID?
    var contextCode: (row: RowID, block: Int)?
    var contextLink: String?
    var contextWord: (text: String, point: NSPoint)?

    // Find.
    var findQuery = ""
    public internal(set) var findMatches: [FindMatch] = []
    public internal(set) var findCurrent: Int?
    /// Search text per row: proportional to the transcript's text (one string per block), built when find is first
    /// used, dropped under memory pressure and on unbind.
    var findIndex: [RowID: FindIndexEntry] = [:]
    var findIndexTask: Task<Void, Never>?
    var findTask: Task<Void, Never>?
    var findRefreshScheduled = false
    var findMatchesByRow: [RowID: [(block: Int, range: Range<Int>, index: Int)]] = [:]

    // Streaming tails.
    var tails: [RowID: TailState] = [:]

    // Accessibility.
    var announced: Set<MessageID> = []
    var announcedOrder: [MessageID] = []
    var streamingSeen: Set<MessageID> = []

    // Measure-all and tasks.
    var openTask: Task<Void, Never>?
    var measureTask: Task<Void, Never>?
    var measureDebounce: Task<Void, Never>?
    public internal(set) var measureAllComplete = false
    var eventMonitor: Any?
    var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    /// Cached `NSWorkspace.isVoiceOverEnabled` (asking costs up to milliseconds; configure needs it per row).
    var isVoiceOverRunning = NSWorkspace.shared.isVoiceOverEnabled
    var voiceOverObservation: NSKeyValueObservation?
    var observers: [any NSObjectProtocol] = []
    public var onMeasureAllFinished: (() -> Void)?
    var lastHeaderHeight: CGFloat = TranscriptMetrics.topPadding

    // Metrics (harness and tests).
    public struct Metrics: Sendable, Codable {
        public var syncLayouts = 0
        public var asyncLayouts = 0
        public var heightFlushes = 0
        public var maxFlushMilliseconds = 0.0
        public var measureAllMilliseconds = 0.0
        public var measureAllRows = 0
        public var tailJobs = 0
        public var maxTailApplyMilliseconds = 0.0
        public var syncs = 0
        public var maxSyncMilliseconds = 0.0
        public var openMilliseconds = 0.0
        public var placeholderRows = 0
    }

    public internal(set) var metrics = Metrics()
    /// Called after each applied tail commit (harness: delta→visible latency).
    public var onTailCommit: ((RowID) -> Void)?

    // MARK: Lifecycle

    public init(
        highlighter: any HighlightService = TokenizerHighlighter.shared, imageLoader: any TranscriptImageLoading = DefaultImageLoader(),
        baseFontSize: CGFloat = DS.Typography.current.baseSize
    ) {
        self.highlighter = highlighter
        self.imageLoader = imageLoader
        self.baseFontSize = baseFontSize
        scrollView = NSScrollView()
        tableView = TranscriptTableView()
        container = TranscriptContainerView()
        theme = TranscriptTheme.resolve(appearance: NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!, baseSize: baseFontSize, revision: 0)
        super.init()
        configureViews()
        startMemoryPressureMonitoring()
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] workspace, _ in
            let enabled = workspace.isVoiceOverEnabled
            Task { @MainActor [weak self] in self?.isVoiceOverRunning = enabled }
        }
    }

    /// Binds a source (a thread). Replaces any previous one; content appears from the source at once (cached state).
    public func bind(_ source: any TranscriptSource, anchor: TranscriptAnchor? = nil) {
        unbindSource()
        appearanceChanged()
        self.source = source
        observationGeneration += 1
        pendingRestore = .some(anchor)
        listDirty = true
        sync()
    }

    /// Cancels every task owned by the transcript and detaches the views. Call when the thread leaves the screen.
    public func close() {
        unbindSource()
        measureDebounce?.cancel()
        pillTask?.cancel()
        anchorTask?.cancel()
        copiedTask?.cancel()
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        voiceOverObservation?.invalidate()
        voiceOverObservation = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        tableView.dataSource = nil
        tableView.delegate = nil
        tableView.controller = nil
        findBar.onChange = nil
        layouts.removeAll()
        graveyard.removeAll()
        blockCache.removeAll()
    }

    private func unbindSource() {
        observationGeneration += 1
        openTask?.cancel()
        measureTask?.cancel()
        findTask?.cancel()
        findIndexTask?.cancel()
        findIndexTask = nil
        loadOlderTask?.cancel()
        for task in layoutTasks.values { task.cancel() }
        layoutTasks.removeAll()
        inflight.removeAll()
        for task in imageTasks.values { task.cancel() }
        imageTasks.removeAll()
        for tail in tails.values { tail.task?.cancel() }
        tails.removeAll()
        source = nil
        trackedMessages.removeAll()
        dirtyMessages.removeAll()
        knownIDs = []
        segmentCache.removeAll()
        rows = []
        rowIndex = [:]
        heights = []
        heightKeys = []
        selection = nil
        findMatches = []
        findCurrent = nil
        findMatchesByRow = [:]
        findIndex = [:]
        imageSourceCache = [:]
        isReady = false
        turnAnchor = nil
        pendingHeights.removeAll()
        tableView.reloadData()
    }

    // MARK: Observation

    func trackList() {
        guard let source else { return }
        let generation = observationGeneration
        withObservationTracking {
            _ = source.transcriptMessageIDs
            _ = source.transcriptHasOlder
            _ = source.transcriptIsLoadingOlder
            _ = source.transcriptIsReady
            _ = source.transcriptIsRunning
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.listDirty = true
                self.scheduleSync()
            }
        }
    }

    func track(_ id: MessageID) {
        guard let source, !trackedMessages.contains(id) else { return }
        trackedMessages.insert(id)
        let generation = observationGeneration
        withObservationTracking {
            _ = source.transcriptMessage(id)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.trackedMessages.remove(id)
                self.dirtyMessages.insert(id)
                // Already off the mutation's call stack: sync now (later hops in this turn find nothing dirty).
                if !self.syncScheduled { self.sync() }
            }
        }
    }

    func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    // MARK: Sync from the source

    /// Brings rows up to date with the source. Cheap while a reply streams: only the last turn's rows are rebuilt.
    func sync() {
        syncScheduled = false
        guard let source, openTask == nil else { return }
        let signpost = transcriptSignposter.beginInterval("sync")
        defer { transcriptSignposter.endInterval("sync", signpost) }
        let start = CACurrentMediaTime()
        if listDirty {
            listDirty = false
            trackList()
        }
        let ids = source.transcriptMessageIDs
        let running = source.transcriptIsRunning
        let ready = source.transcriptIsReady
        updateEdgeState()

        // First content: build everything off the main actor.
        if rows.isEmpty, knownIDs.isEmpty, !ids.isEmpty {
            open(ids: ids, running: running)
            return
        }
        isReady = ready
        let listChanged = ids != knownIDs
        var dirty = dirtyMessages
        dirtyMessages.removeAll()
        if listChanged {
            // Revalidate finished messages that are not tracked individually.
            let known = Set(knownIDs)
            for id in ids where !known.contains(id) { dirty.insert(id) }
            for id in ids where !trackedMessages.contains(id) {
                if let message = source.transcriptMessage(id), segmentCache[id]?.revision != message.revision { dirty.insert(id) }
            }
        }
        guard listChanged || !dirty.isEmpty || running != lastRunning else {
            updateEmptyState()
            return
        }
        // The last turn starts at the last user message.
        let lastTurnStart = ids.lastIndex { id in
            if let message = source.transcriptMessage(id), case .user = message.kind { return true }
            return false
        } ?? 0
        let tailIDs = Set(ids[lastTurnStart...])
        let tailOnly = !listChanged && dirty.allSatisfy { tailIDs.contains($0) }
        let lastTurn: MessageID? = ids.indices.contains(lastTurnStart)
            ? source.transcriptMessage(ids[lastTurnStart]).flatMap { if case .user = $0.kind { $0.id } else { nil } } : nil
        let newRows: [TranscriptRow]
        if tailOnly, let firstTailRow = rows.firstIndex(where: { tailIDs.contains($0.messageID) }) {
            let segments = segments(for: Array(ids[lastTurnStart...]), dirty: dirty, source: source)
            newRows = Array(rows[..<firstTailRow]) + RowBuilder.rows(from: segments, isRunning: running, lastTurn: lastTurn)
        } else {
            let segments = segments(for: ids, dirty: dirty, source: source)
            newRows = RowBuilder.rows(from: segments, isRunning: running, lastTurn: lastTurn)
        }
        knownIDs = ids
        lastRunning = running
        for id in ids.suffix(Self.trackedTail) { track(id) }
        noteStreamingTransitions(dirty, source: source)
        apply(newRows)
        updateEmptyState()
        metrics.syncs += 1
        metrics.maxSyncMilliseconds = max(metrics.maxSyncMilliseconds, (CACurrentMediaTime() - start) * 1000)
    }

    /// Segments of `ids` in order, recomputing those that are dirty, uncached or in a different turn.
    func segments(for ids: [MessageID], dirty: Set<MessageID>, source: any TranscriptSource) -> [RowBuilder.Segment] {
        var turn: MessageID?
        // The turn of the first message: the last user message before it.
        if let first = ids.first, let position = knownIDs.firstIndex(of: first) ?? source.transcriptMessageIDs.firstIndex(of: first) {
            let all = source.transcriptMessageIDs
            for id in all[..<min(position, all.count)].reversed() {
                if let message = source.transcriptMessage(id), case .user = message.kind { turn = id; break }
            }
        }
        var result: [RowBuilder.Segment] = []
        for id in ids {
            guard let message = source.transcriptMessage(id) else { continue }
            if case .user = message.kind { turn = id }
            if !dirty.contains(id), let cached = segmentCache[id], cached.revision == message.revision, cached.turn == turn {
                result += cached.segments
                continue
            }
            noteReasoning(message)
            let context = RowBuilder.Context(reasoningDurations: reasoningDurations)
            let segments = RowBuilder.segments(for: message, turnID: turn, context: context)
            segmentCache[id] = (message.revision, turn, segments)
            result += segments
        }
        return result
    }

    /// Times reasoning the transcript sees streaming (BelloCore parts carry no timestamps).
    func noteReasoning(_ message: Message) {
        for part in message.parts {
            guard case .reasoning = part.content else { continue }
            if part.isStreaming {
                if reasoningStarts[part.id] == nil { reasoningStarts[part.id] = CACurrentMediaTime() }
            } else if let start = reasoningStarts.removeValue(forKey: part.id) {
                reasoningDurations[part.id] = CACurrentMediaTime() - start
                if reasoningDurations.count > 1_024 { reasoningDurations.removeAll() }
            }
        }
    }

    // MARK: Applying rows

    /// Replaces the rows, updating only what changed in the table, and keeps the viewport anchored.
    func apply(_ newRows: [TranscriptRow]) {
        let old = rows
        var prefix = 0
        while prefix < old.count, prefix < newRows.count, old[prefix].id == newRows[prefix].id { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < newRows.count - prefix,
            old[old.count - 1 - suffix].id == newRows[newRows.count - 1 - suffix].id
        {
            suffix += 1
        }
        let removed = prefix..<(old.count - suffix)
        let inserted = prefix..<(newRows.count - suffix)
        var changed: [Int] = []
        for index in 0..<prefix where old[index] != newRows[index] { changed.append(index) }
        for offset in 0..<suffix {
            let oldIndex = old.count - 1 - offset
            let newIndex = newRows.count - 1 - offset
            if old[oldIndex] != newRows[newIndex] { changed.append(newIndex) }
        }
        guard !removed.isEmpty || !inserted.isEmpty || !changed.isEmpty else { return }

        let wasFollowing = following
        let anchor = captureAnchor()
        let appendedUser = !inserted.isEmpty && inserted.upperBound == newRows.count && inserted.contains { newRows[$0].role == .user }
        rows = newRows
        rowIndex = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let estimates = inserted.map { estimate(rows[$0], index: $0) }
        heights.replaceSubrange(removed, with: estimates)
        heightKeys.replaceSubrange(removed, with: Array(repeating: nil, count: inserted.count))
        for row in old[removed] where rowIndex[row.id] == nil { forget(row.id) }
        DS.Motion.withoutAnimation {
            withoutAnimation {
                tableView.beginUpdates()
                if !removed.isEmpty { tableView.removeRows(at: IndexSet(integersIn: (removed.lowerBound + 1)..<(removed.upperBound + 1)), withAnimation: []) }
                if !inserted.isEmpty { tableView.insertRows(at: IndexSet(integersIn: (inserted.lowerBound + 1)..<(inserted.upperBound + 1)), withAnimation: []) }
                tableView.endUpdates()
            }
        }
        // Rows whose content changed in place: streaming tails update their open block; others re-lay out. A new row
        // that is already streaming starts its tail at once.
        for index in changed { contentChanged(row: index) }
        for index in inserted where rows[index].isLive {
            if case .markdown = rows[index].content { contentChanged(row: index) }
        }
        // Spacing of the row after an insertion or removal may change (its top padding depends on its predecessor).
        if inserted.upperBound < rows.count { refreshKey(row: inserted.upperBound) }
        lastPrefetchRange = 0..<0
        forceTableGeometry(from: min(prefix, changed.min() ?? prefix) + 1)
        if appendedUser, let user = inserted.last(where: { rows[$0].role == .user }), wasFollowing || isLocalSend(rows[user]) {
            beginTurnAnchor(rows[user].id)
        }
        if !wasFollowing, !inserted.isEmpty || !changed.isEmpty { noteNewOutput() }
        updateSpacer()
        restore(anchor)
        if wasFollowing { scrollToBottom() }
        updatePrefetch(force: true)
        invalidateFind(rows: inserted.map { rows[$0].id } + changed.map { rows[$0].id })
        // Selections and finds that named removed rows are dropped.
        if let selection, rowIndex[selection.anchor.rowID] == nil || rowIndex[selection.focus.rowID] == nil { self.selection = nil }
        refreshVisibleRows()
    }

    func isLocalSend(_ row: TranscriptRow) -> Bool {
        if case .user(let user) = row.content { return user.isSending }
        return false
    }

    /// Drops caches of a row that left the transcript.
    func forget(_ id: RowID) {
        if let layout = layouts.removeValue(forKey: id) { layoutCacheCost -= layout.cost }
        layoutTick[id] = nil
        layoutTasks.removeValue(forKey: id)?.cancel()
        inflight[id] = nil
        ui[id] = nil
        scrollOffsets[id] = nil
        tails.removeValue(forKey: id)?.task?.cancel()
        findIndex[id] = nil
        pendingHeights[id] = nil
        imageSourceCache[id] = nil
    }

    func contentChanged(row index: Int) {
        let row = rows[index]
        if case .markdown(let text, let streaming) = row.content {
            if streaming || tails[row.id] != nil {
                updateTail(row: row, text: text, finished: !streaming)
                return
            }
        }
        refreshKey(row: index)
    }

    /// Re-requests a row's layout if its key changed; visible rows keep drawing the old layout until it arrives.
    func refreshKey(row index: Int) {
        guard index < rows.count else { return }
        let id = rows[index].id
        if tails[id] != nil { return }
        if layouts[id]?.key != currentKey(row: index) { requestLayout(row: index, priority: true) }
    }

    // MARK: Edge rows and empty state

    func updateEdgeState() {
        guard let source else { return }
        let height = source.transcriptHasOlder ? TranscriptMetrics.loadingHeaderHeight : TranscriptMetrics.topPadding
        if let header = tableView.view(atColumn: 0, row: 0, makeIfNecessary: false) as? TranscriptEdgeView {
            header.update(hasOlder: source.transcriptHasOlder, loading: source.transcriptIsLoadingOlder)
        }
        if height != lastHeaderHeight {
            let anchor = captureAnchor()
            lastHeaderHeight = height
            withoutAnimation { tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0)) }
            forceTableGeometry(from: 0)
            restore(anchor)
        }
    }

    func updateEmptyState() {
        let ready = source?.transcriptIsReady ?? false
        emptyLabel.isHidden = !(rows.isEmpty && ready && knownIDs.isEmpty)
    }

    // MARK: Table data source and delegate

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count + 2 }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if row == 0 { return lastHeaderHeight }
        let index = row - 1
        if index >= rows.count { return max(1, spacerHeight) }
        return index < heights.count ? max(1, heights[index]) : 1
    }

    /// Row views are dequeued by identifier. A fresh, unidentified row view per row is never reused: NSTableView
    /// parks every row view that leaves the screen in its row-view purgatory, which then grew by one view (with its own
    /// layout engine and backing layer) per row ever shown: 11,600 views and ~400 MB after one 10,000-message traversal.
    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let reused = tableView.makeView(withIdentifier: TranscriptRowView.identifier, owner: nil) as? TranscriptRowView {
            return reused
        }
        TranscriptProfiler.shared.count("rowViewsCreated")
        return TranscriptRowView()
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        TranscriptProfiler.shared.measure(.viewCreation) { makeView(row: row) }
    }

    private func makeView(row: Int) -> NSView? {
        if row == 0 {
            let view = tableView.makeView(withIdentifier: TranscriptEdgeView.identifier, owner: nil) as? TranscriptEdgeView
                ?? TranscriptEdgeView(frame: .zero)
            view.update(hasOlder: source?.transcriptHasOlder ?? false, loading: source?.transcriptIsLoadingOlder ?? false)
            return view
        }
        let index = row - 1
        guard index < rows.count else { return nil }
        let view = tableView.makeView(withIdentifier: TranscriptCellView.identifier, owner: nil) as? TranscriptCellView
            ?? {
                TranscriptProfiler.shared.count("cellViewsCreated")
                return TranscriptCellView(frame: .zero)
            }()
        view.controller = self
        configure(view, index: index)
        return view
    }

    /// Model index of a table row, or nil for the edge rows.
    func modelIndex(tableRow: Int) -> Int? {
        let index = tableRow - 1
        return index >= 0 && index < rows.count ? index : nil
    }

    /// The table rect of a transcript row (model index).
    public func rowRect(_ index: Int) -> CGRect { tableView.rect(ofRow: index + 1) }

    func cellView(_ index: Int) -> TranscriptCellView? {
        tableView.view(atColumn: 0, row: index + 1, makeIfNecessary: false) as? TranscriptCellView
    }

    func configure(_ view: TranscriptCellView, index: Int) {
        TranscriptProfiler.shared.measure(.configure) { configureNow(view, index: index) }
    }

    private func configureNow(_ view: TranscriptCellView, index: Int) {
        guard index < rows.count else { return }
        let row = rows[index]
        let layout = displayLayout(row: index, allowPlaceholder: true)
        let state = drawState(for: index)
        let changed = view.rowID != row.id || view.layout !== layout || !view.sameState(state)
        view.rowID = row.id
        view.row = row
        view.layout = layout
        view.drawState = state
        view.updateCanvas(force: true)
        if changed {
            view.invalidate()
            TranscriptProfiler.shared.measure(.accessibility) { view.updateAccessibility() }
        }
        if let layout { requestImages(in: layout, row: row.id) }
    }

    func drawState(for index: Int) -> RowLayout.DrawState {
        let id = rows[index].id
        var state = RowLayout.DrawState(selectionColor: selectionColor)
        state.selection = selection?.rowSelection(row: index, rowID: id) { self.rowIndex[$0] }
        if let matches = findMatchesByRow[id] {
            state.finds = matches.map { ($0.block, $0.range, $0.index == findCurrent) }
        }
        state.scrollOffsets = scrollOffsets[id] ?? [:]
        if let copiedBlock, copiedBlock.row == id { state.copiedBlock = copiedBlock.block }
        if let hover, hover.row == id { state.hover = (hover.block, hover.action) }
        return state
    }

    var selectionColor: CGColor {
        let focused = tableView.window?.firstResponder === tableView && (tableView.window?.isKeyWindow ?? false)
        return focused ? theme.selection : theme.inactiveSelection
    }

    /// Every row view AppKit currently holds (visible plus prepared overdraw).
    func availableCells() -> [(index: Int, view: TranscriptCellView)] {
        var result: [(Int, TranscriptCellView)] = []
        tableView.enumerateAvailableRowViews { rowView, row in
            if let view = rowView.view(atColumn: 0) as? TranscriptCellView, let index = self.modelIndex(tableRow: row) {
                result.append((index, view))
            }
        }
        return result
    }

    func visibleCells() -> [(index: Int, view: TranscriptCellView)] {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.length > 0 else { return [] }
        return (range.location..<(range.location + range.length)).compactMap { row in
            guard let index = modelIndex(tableRow: row), let view = cellView(index) else { return nil }
            return (index, view)
        }
    }

    /// Re-applies selection, find and hover state to the rows on screen.
    func refreshVisibleRows() {
        for (index, view) in availableCells() {
            let state = drawState(for: index)
            if !view.sameState(state) || view.rowID != rows[index].id {
                view.drawState = state
                view.invalidate()
            }
        }
    }

    func withoutAnimation(_ body: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    // MARK: Appearance

    func appearanceChanged() {
        let appearance = container.effectiveAppearance
        let resolved = TranscriptTheme.resolve(appearance: appearance, baseSize: baseFontSize, revision: themeRevision)
        guard resolved != theme else { return }
        themeRevision += 1
        theme = TranscriptTheme.resolve(appearance: appearance, baseSize: baseFontSize, revision: themeRevision)
        generation += 1
        // Visible rows re-lay out now, synchronously (a one-off: a stale-coloured frame would flash); others when
        // they are next needed.
        let fonts = TranscriptFonts(theme: theme)
        for (index, view) in visibleCells() where tails[rows[index].id] == nil {
            let layout = LayoutEngine.layoutNow(layoutInput(row: index), fonts: fonts)
            store(layout)
            acceptHeight(layout, row: index)
            configure(view, index: index)
        }
        for (index, _) in availableCells() { requestLayout(row: index, priority: true) }
        flushHeights()
        relayoutTails()
        scheduleMeasureAll()
        container.needsDisplay = true
    }
}

/// Layout constants of the transcript container.
enum TranscriptMetrics {
    static let topPadding: CGFloat = 14
    static let loadingHeaderHeight: CGFloat = 40
    static let bottomPadding: CGFloat = 20
    static let turnTopInset: CGFloat = 12
}

extension TranscriptController {
    /// Messages whose rows are built (tests: the transcript shows everything the thread has loaded).
    public var renderedMessageCount: Int { openTask == nil ? knownIDs.count : 0 }
}
