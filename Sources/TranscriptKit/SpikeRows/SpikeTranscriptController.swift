// SPIKE G1-B: the row-based transcript controller.
//
// Owns the transcript state (items, per-item UI state, height cache, bounded layout cache, selection, streaming
// tail) outside the reusable views, drives a view-based NSTableView with explicit cached row heights, and keeps the
// viewport anchored by (item ID, block index, offset) whenever heights change above it.

import AppKit
import os
import QuartzCore
import Synchronization

let spikeSignposter = OSSignposter(subsystem: "BelloCode.SpikeB", category: .pointsOfInterest)

/// A position in the transcript: item, block within the item, UTF-16 offset in the block's plain text.
public struct SpikePosition: Equatable, Sendable {
    public var itemID: Int
    public var block: Int
    public var offset: Int
}

public struct SpikeFindMatch: Sendable, Equatable {
    public var itemID: Int
    public var block: Int
    public var range: Range<Int>
}

/// Ordered stream deltas waiting for the next UI commit. Bounded: overflow is reported, never silently dropped.
public final class SpikeDeltaBuffer: Sendable {
    private struct State {
        var text = ""
        var times: [Double] = []
        var overflowed = false
    }

    private let state = Mutex(State())
    public static let limitBytes = 4 << 20

    public init() {}

    public func append(_ delta: String, time: Double) {
        state.withLock {
            if $0.text.utf8.count + delta.utf8.count > Self.limitBytes { $0.overflowed = true; return }
            $0.text += delta
            $0.times.append(time)
        }
    }

    public func drain() -> (text: String, times: [Double], overflowed: Bool) {
        state.withLock {
            let result = ($0.text, $0.times, $0.overflowed)
            $0 = State()
            return result
        }
    }
}

/// Result of the off-main open pass: estimated heights for every row, exact layouts for the bottom rows.
final class SpikeOpenResult {
    var heights: [CGFloat] = []
    var exact: [(row: Int, layout: SpikeItemLayout)] = []
}

/// Result of one streaming-tail parse + layout job.
final class SpikeTailJobResult {
    var parsed: [SpikeMarkdown.Parsed] = []
    var layouts: [SpikeBlockLayout] = []
}

@MainActor
public final class SpikeTranscriptController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    public let container: NSView
    public let scrollView: NSScrollView
    public let tableView: SpikeTableView
    public let jumpButton: NSButton

    // Model (row-ordered) and per-row caches.
    public private(set) var items: [SpikeItem]
    private var rowByID: [Int: Int] = [:]
    private var ui: [Int: SpikeItemUIState] = [:]
    private var heights: [CGFloat] = []
    private var heightKeys: [SpikeLayoutKey?] = []

    // Bounded layout cache (LRU by access tick).
    private var layouts: [Int: SpikeItemLayout] = [:]
    private var layoutTick: [Int: UInt64] = [:]
    private var tick: UInt64 = 0
    /// Cache bounds: count and approximate CTLine cost (~1-2 KB each). The first S2 runs used a 500-layout count
    /// limit that grew the footprint to 520 MB and evicted 100 layouts at once (60-100 ms frames).
    public var layoutCacheLimit = Int(ProcessInfo.processInfo.environment["SPIKE_CACHE"] ?? "") ?? 300
    public var layoutCacheCostLimit = 25_000
    private var layoutCacheCost = 0
    private var scrollVelocity: CGFloat = 0
    private var lastBoundsY: CGFloat = 0
    private var lastBoundsTime: Double = 0
    private let maxInflightPrefetch = 8

    private var inflight: [Int: SpikeLayoutKey] = [:]
    private var layoutTasks: [Int: Task<Void, Never>] = [:]
    private var pendingHeights: [Int: CGFloat] = [:]
    private var flushScheduled = false
    private var isAdjustingScroll = false
    private var generation = 0
    private var lastPrefetchRange: Range<Int> = 0..<0

    public private(set) var width: CGFloat = 0
    public private(set) var theme: SpikeTheme
    public private(set) var following = true
    private var liveScrolling = false
    private var lastWheelTime: Double = 0

    // Images.
    private var images: [Int: CGImage] = [:]
    private var imageSizes: [Int: CGSize] = [:]
    private var imageOwner: [Int: Int] = [:]
    private var imageTasks: [Task<Void, Never>] = []
    public var heldImages: Set<Int> = []
    private var heldReady: [Int: CGImage] = [:]

    // Selection, find.
    private var selection: (anchor: SpikePosition, focus: SpikePosition)?
    private var findMatch: SpikeFindMatch?
    private var dragStartWindowPoint: NSPoint?
    private var lastDragWindowPoint: NSPoint = .zero
    private var didDrag = false
    private var toggleCandidate: (itemID: Int, block: Int)?
    private var autoscrollTimer: Timer?
    private var lastAutoscrollTime: Double = 0
    public var pasteboard: NSPasteboard = .general
    private var blockCache: [Int: (revision: Int, blocks: [SpikeBlock])] = [:]
    private var searchIndex: [(id: Int, blocks: [String])] = []
    public private(set) var searchIndexReady = false

    // Streaming tail.
    private final class TailState {
        let id: Int
        var source = ""
        var stableEnd = 0  // UTF-8 offset into source
        var stableBlocks: [SpikeBlock] = []
        var stableLayouts: [SpikeBlockLayout] = []
        var openBlocks: [SpikeBlock] = []
        var openLayouts: [SpikeBlockLayout] = []
        var revision = 0
        var appliedRevision = 0
        var jobInFlight = false
        var layoutWidth: CGFloat = 0
        var pendingTimes: [(revision: Int, time: Double)] = []
        init(id: Int) { self.id = id }
        var blocks: [SpikeBlock] { stableBlocks + openBlocks }
    }

    private var tail: TailState?
    public let deltaBuffer = SpikeDeltaBuffer()
    public var commitInterval: Double = 0.033
    private var lastCommit: Double = 0
    private var commitLink: CADisplayLink?
    /// Creation times of deltas whose text has been applied to the tail row since the last drain.
    public private(set) var appliedDeltaTimes: [Double] = []
    public private(set) var appliedDeltaCount = 0
    public private(set) var tailOverflowed = false

    // Tasks and observers.
    private var measureTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var tailTask: Task<Void, Never>?
    private var measureDebounce: Task<Void, Never>?
    private var eventMonitor: Any?
    private var observers: [any NSObjectProtocol] = []

    // Metrics.
    public struct Metrics: Sendable, Codable {
        public var syncLayouts = 0
        public var asyncLayouts = 0
        public var heightFlushes = 0
        public var maxFlushMilliseconds = 0.0
        public var measureAllMilliseconds = 0.0
        public var measureAllRows = 0
        public var tailJobs = 0
        public var maxTailApplyMilliseconds = 0.0
        public var searchIndexMilliseconds = 0.0
        public var maxNoteHeightMilliseconds = 0.0
        public var maxRestoreMilliseconds = 0.0
        public var maxFlushRows = 0
        public var placeholderRows = 0
    }

    public private(set) var metrics = Metrics()
    public var onMeasureAllFinished: (() -> Void)?

    // MARK: Lifecycle

    public init(items: [SpikeItem], theme: SpikeTheme) {
        self.items = items
        self.theme = theme
        scrollView = NSScrollView()
        tableView = SpikeTableView()
        jumpButton = NSButton(title: "Jump to Latest ↓", target: nil, action: nil)
        container = NSView()
        super.init()
        rebuildIndex()
        for item in items {
            for imageID in item.imageIDs { imageOwner[imageID] = item.id }
        }
        configureViews()
    }

    private func configureViews() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.usesAutomaticRowHeights = false
        tableView.rowSizeStyle = .custom
        tableView.allowsColumnResizing = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.backgroundColor = .textBackgroundColor
        tableView.controller = self
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        jumpButton.bezelStyle = .push
        jumpButton.controlSize = .regular
        jumpButton.target = self
        jumpButton.action = #selector(jumpToLatest(_:))
        jumpButton.isHidden = true
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        jumpButton.setAccessibilityLabel("Jump to latest message")

        container.addSubview(scrollView)
        container.addSubview(jumpButton)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            jumpButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                            queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.boundsChanged() }
        })
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView,
                                            queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.clipFrameChanged() }
        })
        observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView,
                                            queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveScrolling = true }
        })
        observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView,
                                            queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.liveScrolling = false
                self?.evaluateFollow(userInitiated: true)
            }
        })
        scrollView.contentView.postsFrameChangedNotifications = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.noteWheel(event) }
            return event
        }
    }

    /// Opens the transcript scrolled to the bottom: estimates for every row and exact layouts for the bottom rows are
    /// computed off the main actor, then the table loads once.
    public func open(viewportHeight: CGFloat) async {
        width = max(320, scrollView.contentView.bounds.width)
        let items = self.items
        let theme = self.theme
        let width = self.width
        let result = await Self.openPass(items: items, width: width, theme: theme, viewportHeight: viewportHeight)
        heights = result.heights
        heightKeys = Array(repeating: nil, count: items.count)
        for (row, layout) in result.exact {
            store(layout)
            heightKeys[row] = layout.key
        }
        tableView.reloadData()
        forceTableGeometry(from: 0)
        scrollToBottom()
        following = true
        updatePrefetch(force: true)
        startMeasureAll()
        startSearchIndex()
        scheduleImages()
    }

    @concurrent
    private static func openPass(items: [SpikeItem], width: CGFloat, theme: SpikeTheme, viewportHeight: CGFloat) async
        -> sending SpikeOpenResult {
        let result = SpikeOpenResult()
        result.heights = items.map { SpikeLayoutEngine.estimate($0, width: width) }
        let fonts = SpikeFonts(theme: theme)
        var accumulated: CGFloat = 0
        var row = items.count - 1
        while row >= 0, accumulated < viewportHeight * 3 {
            let input = SpikeLayoutInput(item: items[row], blocks: nil, ui: SpikeItemUIState(), imageSizes: [:],
                                         width: width, theme: theme)
            let layout = SpikeLayoutEngine.layoutNow(input, fonts: fonts)
            result.heights[row] = layout.height
            result.exact.append((row, layout))
            accumulated += layout.height
            row -= 1
        }
        return result
    }

    /// Cancels every task owned by this transcript and detaches the views.
    public func close() {
        measureTask?.cancel()
        indexTask?.cancel()
        tailTask?.cancel()
        measureDebounce?.cancel()
        for task in layoutTasks.values { task.cancel() }
        for task in imageTasks { task.cancel() }
        layoutTasks.removeAll()
        imageTasks.removeAll()
        autoscrollTimer?.invalidate()
        commitLink?.invalidate()
        commitLink = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        tableView.dataSource = nil
        tableView.delegate = nil
        tableView.controller = nil
        container.removeFromSuperview()
        layouts.removeAll()
        blockCache.removeAll()
        searchIndex.removeAll()
    }

    // MARK: Table data source and delegate

    public func numberOfRows(in tableView: NSTableView) -> Int { heights.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row < heights.count ? max(1, heights[row]) : 1
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SpikeRowView()
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: SpikeItemView.identifier, owner: nil) as? SpikeItemView
            ?? SpikeItemView(frame: .zero)
        view.imageSource = self
        configure(view, row: row)
        return view
    }

    private func configure(_ view: SpikeItemView, row: Int) {
        guard row < items.count else { return }
        let id = items[row].id
        let layout = displayLayout(row: row, allowPlaceholder: true)
        let selection = rowSelection(row: row)
        let find = findMatch.flatMap { $0.itemID == id ? ($0.block, $0.range) : nil }
        let changed = view.itemID != id || view.layout !== layout || view.rowSelection != selection
            || view.findMatch?.block != find?.0 || view.findMatch?.range != find?.1
        view.itemID = id
        view.layout = layout
        view.rowSelection = selection
        view.findMatch = find
        view.updateCanvas(force: true)
        if changed { view.invalidate() }
    }

    /// Every row view AppKit currently holds (visible plus prepared overdraw).
    private func availableItemViews() -> [(row: Int, view: SpikeItemView)] {
        var result: [(Int, SpikeItemView)] = []
        tableView.enumerateAvailableRowViews { rowView, row in
            if let view = rowView.view(atColumn: 0) as? SpikeItemView { result.append((row, view)) }
        }
        return result
    }

    private func visibleItemViews() -> [(row: Int, view: SpikeItemView)] {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.length > 0 else { return [] }
        return (range.location..<(range.location + range.length)).compactMap { row in
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SpikeItemView).map { (row, $0) }
        }
    }

    // MARK: Layout cache

    private func currentKey(row: Int) -> SpikeLayoutKey {
        let item = items[row]
        if let tail, tail.id == item.id {
            return SpikeLayoutKey(id: item.id, revision: tail.appliedRevision, uiVersion: ui[item.id]?.version ?? 0,
                                  width: Int(width.rounded()))
        }
        return SpikeLayoutKey(id: item.id, revision: item.revision, uiVersion: ui[item.id]?.version ?? 0,
                              width: Int(width.rounded()))
    }

    private func layoutInput(row: Int) -> SpikeLayoutInput {
        let item = items[row]
        var sizes: [Int: CGSize] = [:]
        for imageID in item.imageIDs { if let size = imageSizes[imageID] { sizes[imageID] = size } }
        return SpikeLayoutInput(item: item, blocks: nil, ui: ui[item.id] ?? SpikeItemUIState(), imageSizes: sizes,
                                width: width, theme: theme)
    }

    private func store(_ layout: SpikeItemLayout) {
        tick += 1
        if let old = layouts[layout.key.id] { layoutCacheCost -= old.cost }
        layouts[layout.key.id] = layout
        layoutCacheCost += layout.cost
        layoutTick[layout.key.id] = tick
        if layouts.count > layoutCacheLimit || layoutCacheCost > layoutCacheCostLimit { evictLayouts() }
    }

    /// Evicts least recently used layouts just until the cache is back under its bounds (a few per call), so
    /// deallocation cost is spread out instead of arriving in one burst.
    private func evictLayouts() {
        let keep = Set(availableItemViews().map { items[$0.row].id })
        let candidates = layoutTick.filter { !keep.contains($0.key) && $0.key != tail?.id }.sorted { $0.value < $1.value }
        for (id, _) in candidates {
            guard layouts.count > layoutCacheLimit || layoutCacheCost > layoutCacheCostLimit else { break }
            if let old = layouts.removeValue(forKey: id) { layoutCacheCost -= old.cost }
            layoutTick[id] = nil
        }
    }

    /// Layout to draw for a row now: current, else stale (other width) while a fresh one is computed, else a
    /// synchronous layout (counted: should be rare thanks to prefetch).
    private func displayLayout(row: Int, allowPlaceholder: Bool = false) -> SpikeItemLayout? {
        let id = items[row].id
        let key = currentKey(row: row)
        if let layout = layouts[id] {
            tick += 1
            layoutTick[id] = tick
            if layout.key != key { requestLayout(row: row) }
            return layout
        }
        if tail?.id == id { return composeTail() }
        // Rows AppKit prepares outside the viewport (responsive-scrolling overdraw) get their layout asynchronously.
        if allowPlaceholder, !tableView.visibleRect.intersects(tableView.rect(ofRow: row)) {
            requestLayout(row: row)
            metrics.placeholderRows += 1
            return nil
        }
        let state = spikeSignposter.beginInterval("syncLayout")
        let layout = SpikeLayoutEngine.layoutNow(layoutInput(row: row), fonts: SpikeFonts(theme: theme))
        spikeSignposter.endInterval("syncLayout", state)
        metrics.syncLayouts += 1
        store(layout)
        acceptHeight(layout, row: row)
        return layout
    }

    private func requestLayout(row: Int) {
        let item = items[row]
        if tail?.id == item.id { return }
        let input = layoutInput(row: row)
        let key = input.key
        if layouts[item.id]?.key == key || inflight[item.id] == key { return }
        inflight[item.id] = key
        layoutTasks[item.id]?.cancel()
        metrics.asyncLayouts += 1
        layoutTasks[item.id] = Task { [weak self] in
            let layout = await SpikeLayoutEngine.layout(input)
            guard !Task.isCancelled, let self else { return }
            self.didFinishLayout(layout)
        }
    }

    private func didFinishLayout(_ layout: SpikeItemLayout) {
        let id = layout.key.id
        if inflight[id] == layout.key {
            inflight[id] = nil
            layoutTasks[id] = nil
        }
        defer { if inflight.count < maxInflightPrefetch / 2 { updatePrefetch(force: true) } }
        guard let row = rowByID[id], currentKey(row: row) == layout.key else { return }  // stale: drop
        store(layout)
        acceptHeight(layout, row: row)
        if pendingHeights[id] == nil, let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SpikeItemView {
            configure(view, row: row)
        }
    }

    private func acceptHeight(_ layout: SpikeItemLayout, row: Int) {
        heightKeys[row] = layout.key
        if abs(heights[row] - layout.height) > 0.25 {
            pendingHeights[layout.key.id] = layout.height
            scheduleFlush()
        }
    }

    /// Visible rows are always requested; then rows ahead in the scroll direction (lookahead grows with velocity:
    /// 0.35 s of travel, at least 1.5 viewports), then one viewport behind. At most `maxInflightPrefetch` prefetch
    /// layouts run at once so prefetch never saturates the cores (which delays display-link delivery).
    private func updatePrefetch(force: Bool = false) {
        let visible = tableView.visibleRect
        guard visible.height > 0 else { return }
        let ahead = max(visible.height * 1.5, abs(scrollVelocity) * 0.35)
        let down = scrollVelocity >= 0
        let window = CGRect(x: 0, y: visible.minY - (down ? visible.height : ahead), width: visible.width,
                            height: visible.height * 2 + ahead)
        let range = tableView.rows(in: window)
        let rows = range.location..<(range.location + range.length)
        if !force, rows == lastPrefetchRange { return }
        lastPrefetchRange = rows
        let visibleNS = tableView.rows(in: visible)
        let visibleRows = visibleNS.location..<(visibleNS.location + visibleNS.length)
        for row in visibleRows { requestLayout(row: row) }
        let aheadRows: [Int] = down ? Array(visibleRows.upperBound..<rows.upperBound)
            : Array((rows.lowerBound..<visibleRows.lowerBound).reversed())
        let behindRows: [Int] = down ? Array((rows.lowerBound..<visibleRows.lowerBound).reversed())
            : Array(visibleRows.upperBound..<rows.upperBound)
        for row in aheadRows + behindRows {
            if inflight.count >= maxInflightPrefetch { break }
            requestLayout(row: row)
        }
    }

    // MARK: Height changes and anchoring

    private enum Anchor {
        case bottom
        case item(id: Int, block: Int?, offset: CGFloat)
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flushHeights() }
        }
    }

    /// Applies all pending height changes in one table update and restores the anchor.
    public func flushHeights() {
        flushScheduled = false
        guard !pendingHeights.isEmpty else { return }
        let state = spikeSignposter.beginInterval("flushHeights")
        let start = CACurrentMediaTime()
        let anchor = captureAnchor()
        var rows = IndexSet()
        for (id, height) in pendingHeights {
            guard let row = rowByID[id] else { continue }
            heights[row] = height
            rows.insert(row)
        }
        pendingHeights.removeAll()
        let noteStart = CACurrentMediaTime()
        withoutAnimation { tableView.noteHeightOfRows(withIndexesChanged: rows) }
        forceTableGeometry(from: rows.first ?? 0)
        metrics.maxNoteHeightMilliseconds = max(metrics.maxNoteHeightMilliseconds, (CACurrentMediaTime() - noteStart) * 1000)
        metrics.maxFlushRows = max(metrics.maxFlushRows, rows.count)
        for (row, view) in availableItemViews() where rows.contains(row) { configure(view, row: row) }
        let restoreStart = CACurrentMediaTime()
        restore(anchor)
        metrics.maxRestoreMilliseconds = max(metrics.maxRestoreMilliseconds, (CACurrentMediaTime() - restoreStart) * 1000)
        metrics.heightFlushes += 1
        metrics.maxFlushMilliseconds = max(metrics.maxFlushMilliseconds, (CACurrentMediaTime() - start) * 1000)
        spikeSignposter.endInterval("flushHeights", state)
        updatePrefetch()
    }

    /// NSTableView computes variable row offsets lazily and estimates rows it has not asked about yet, so its
    /// geometry silently drifts from our height cache (43,000 pt at row 5,000 in the first S2 run) and moves rows
    /// while the user scrolls. Asking for every row rect from the first changed row onward forces it to use our
    /// heights. Cost: ~0.5 µs per row (≈5 ms for 10,000 rows; ~0 for tail-only changes).
    private func forceTableGeometry(from row: Int) {
        guard row < heights.count else { return }
        for index in row..<heights.count { _ = tableView.rect(ofRow: index) }
    }

    private func withoutAnimation(_ body: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    private func captureAnchor() -> Anchor {
        if following { return .bottom }
        let visible = scrollView.contentView.bounds
        let row = tableView.row(at: NSPoint(x: 1, y: visible.minY))
        guard row >= 0 else { return .bottom }
        let rowTop = tableView.rect(ofRow: row).minY
        let y = visible.minY - rowTop
        let id = items[row].id
        if let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SpikeItemView,
           let layout = view.layout, !layout.blocks.isEmpty {
            let block = layout.blockIndex(atY: y)
            return .item(id: id, block: block, offset: y - layout.origins[block].y)
        }
        return .item(id: id, block: nil, offset: y)
    }

    private func restore(_ anchor: Anchor) {
        switch anchor {
        case .bottom:
            scrollToBottom()
        case .item(let id, let block, let offset):
            guard let row = rowByID[id] else { return }
            let rowTop = tableView.rect(ofRow: row).minY
            var y = rowTop + offset
            if let block, let layout = layouts[id], block < layout.blocks.count {
                y = rowTop + layout.origins[block].y + offset
            }
            setScroll(y)
        }
    }

    private var documentHeight: CGFloat {
        heights.isEmpty ? 0 : tableView.rect(ofRow: heights.count - 1).maxY
    }

    private func setScroll(_ y: CGFloat) {
        let clip = scrollView.contentView
        if abs(tableView.frame.height - documentHeight) > 0.5 { tableView.tile() }
        let maxY = max(0, documentHeight - clip.bounds.height)
        let target = min(max(0, y), maxY)
        guard abs(clip.bounds.origin.y - target) > 0.01 else { return }
        isAdjustingScroll = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
        isAdjustingScroll = false
    }

    public func scrollToBottom() {
        setScroll(.greatestFiniteMagnitude)
    }

    public var distanceFromBottom: CGFloat {
        documentHeight - scrollView.contentView.bounds.maxY
    }

    // MARK: Scrolling, follow and release

    private func boundsChanged() {
        let now = CACurrentMediaTime()
        let y = scrollView.contentView.bounds.minY
        if now - lastBoundsTime > 0.2 { scrollVelocity = 0 }
        else if now > lastBoundsTime { scrollVelocity = 0.7 * scrollVelocity + 0.3 * (y - lastBoundsY) / CGFloat(now - lastBoundsTime) }
        lastBoundsY = y
        lastBoundsTime = now
        for (_, view) in visibleItemViews() where view.bounds.height > SpikeItemView.tallRowThreshold {
            view.updateCanvas()
        }
        updatePrefetch()
        if !isAdjustingScroll && liveScrolling { evaluateFollow(userInitiated: true) }
        else if !isAdjustingScroll && CACurrentMediaTime() - lastWheelTime < 0.6 { evaluateFollow(userInitiated: true) }
        if dragStartWindowPoint != nil { updateDragFocus() }
    }

    private func noteWheel(_ event: NSEvent) {
        guard event.window === scrollView.window else { return }
        let point = scrollView.convert(event.locationInWindow, from: nil)
        guard scrollView.bounds.contains(point) else { return }
        noteUserScroll(deltaY: event.scrollingDeltaY)
    }

    /// Called for real and synthesised wheel events, and by the scenario driver for programmatic user scrolling.
    public func noteUserScroll(deltaY: CGFloat) {
        lastWheelTime = CACurrentMediaTime()
        if deltaY > 0, following { setFollowing(false) }  // scrolling toward older content releases follow
    }

    private func evaluateFollow(userInitiated: Bool) {
        guard userInitiated else { return }
        let distance = distanceFromBottom
        if distance > 2, following, liveScrolling { setFollowing(false) }
        if distance <= 2, !following { setFollowing(true) }
    }

    private func setFollowing(_ value: Bool) {
        guard following != value else { return }
        following = value
        jumpButton.isHidden = value
    }

    @objc public func jumpToLatest(_ sender: Any?) {
        setFollowing(true)
        scrollToBottom()
    }

    /// Scenario driver: user scroll by a delta (positive = toward the bottom).
    public func userScroll(by delta: CGFloat) {
        noteUserScroll(deltaY: -delta)
        let clip = scrollView.contentView
        let maxY = max(0, documentHeight - clip.bounds.height)
        let target = min(max(0, clip.bounds.origin.y + delta), maxY)
        clip.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(clip)
        if delta > 0 { evaluateFollow(userInitiated: true) }
    }

    public func scrollTo(y: CGFloat) {
        setScroll(y)
    }

    // MARK: Width changes

    private func clipFrameChanged() {
        let newWidth = scrollView.contentView.bounds.width
        guard abs(newWidth - width) >= 1, !heights.isEmpty else { return }
        width = newWidth
        generation += 1
        measureTask?.cancel()
        // Visible rows are re-laid out off-main right away; they draw their previous layout (clipped) for the frame
        // or two until the new one arrives. Off-screen rows keep their old heights until measured again.
        updatePrefetch(force: true)
        if let tail { relayoutTail(tail) }
        measureDebounce?.cancel()
        measureDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.startMeasureAll()
        }
    }

    // MARK: Measure-all pass

    public private(set) var measureAllComplete = false

    private func startMeasureAll() {
        measureTask?.cancel()
        measureAllComplete = false
        let generation = self.generation
        var inputs: [SpikeLayoutInput] = []
        for row in items.indices where heightKeys[row] != currentKey(row: row) && items[row].id != tail?.id {
            inputs.append(layoutInput(row: row))
        }
        let start = CACurrentMediaTime()
        let total = inputs.count
        // Background work runs at utility QoS on at most half the cores: saturating every core at the inherited
        // user-initiated QoS starved display-link delivery (first frame 600 ms late in the first S1 runs).
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        measureTask = Task(priority: .utility) { [weak self] in
            await withTaskGroup(of: [(key: SpikeLayoutKey, height: CGFloat)].self) { group in
                var index = 0
                var running = 0
                func addChunk() {
                    let chunk = Array(inputs[index..<min(index + 100, inputs.count)])
                    group.addTask(priority: .utility) { await SpikeLayoutEngine.measure(chunk) }
                    index += 100
                    running += 1
                }
                while index < inputs.count, running < width { addChunk() }
                var batch: [(key: SpikeLayoutKey, height: CGFloat)] = []
                var lastApply = CACurrentMediaTime()
                for await result in group {
                    running -= 1
                    guard let self, !Task.isCancelled, self.generation == generation else {
                        group.cancelAll()
                        return
                    }
                    if index < inputs.count { addChunk() }
                    batch += result
                    // Coalesce height commits to at most ~6 per second while measuring.
                    if CACurrentMediaTime() - lastApply > 0.15 || running == 0 {
                        self.applyMeasured(batch)
                        batch.removeAll()
                        lastApply = CACurrentMediaTime()
                    }
                }
                if !batch.isEmpty { self?.applyMeasured(batch) }
            }
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.metrics.measureAllMilliseconds = (CACurrentMediaTime() - start) * 1000
            self.metrics.measureAllRows = total
            self.measureAllComplete = true
            self.onMeasureAllFinished?()
        }
    }

    private func applyMeasured(_ results: [(key: SpikeLayoutKey, height: CGFloat)]) {
        for (key, height) in results {
            guard let row = rowByID[key.id], currentKey(row: row) == key else { continue }
            heightKeys[row] = key
            if abs(heights[row] - height) > 0.25 { pendingHeights[key.id] = height }
        }
        scheduleFlush()
    }

    // MARK: Images

    private func scheduleImages() {
        for item in items {
            for part in item.parts {
                guard case .image(let ref) = part else { continue }
                imageTasks.append(Task { [weak self] in
                    try? await Task.sleep(for: .seconds(ref.delay))
                    guard !Task.isCancelled else { return }
                    let image = await Self.makeImage(ref)
                    self?.imageArrived(ref.imageID, image: image, size: ref.pixelSize)
                })
            }
        }
    }

    @concurrent
    private static func makeImage(_ ref: SpikeImageRef) async -> CGImage? {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let c = ref.colour
        context?.setFillColor(red: CGFloat((c >> 16) & 0xFF) / 255, green: CGFloat((c >> 8) & 0xFF) / 255,
                              blue: CGFloat(c & 0xFF) / 255, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return context?.makeImage()
    }

    private func imageArrived(_ imageID: Int, image: CGImage?, size: CGSize) {
        guard let image else { return }
        if heldImages.contains(imageID) {
            heldReady[imageID] = image
            return
        }
        images[imageID] = image
        imageSizes[imageID] = size
        guard let owner = imageOwner[imageID], let row = rowByID[owner] else { return }
        ui[owner, default: SpikeItemUIState()].version += 1
        requestLayout(row: row)
    }

    /// Delivers an image that was held back by the scenario (S5 late image).
    public func releaseHeldImage(_ imageID: Int) {
        heldImages.remove(imageID)
        if let image = heldReady.removeValue(forKey: imageID) {
            imageArrived(imageID, image: image, size: imageSizeFor(imageID))
        }
    }

    private func imageSizeFor(_ imageID: Int) -> CGSize {
        guard let owner = imageOwner[imageID], let row = rowByID[owner] else { return .zero }
        for part in items[row].parts { if case .image(let ref) = part, ref.imageID == imageID { return ref.pixelSize } }
        return .zero
    }

    public func isImageLoaded(_ imageID: Int) -> Bool { images[imageID] != nil }

    func image(_ imageID: Int) -> CGImage? { images[imageID] }

    // MARK: Expand / collapse

    public func isExpanded(itemID: Int, block: Int) -> Bool {
        guard let blocks = blocks(itemID: itemID), block < blocks.count else { return false }
        return blocks[block].defaultExpanded != (ui[itemID]?.toggled.contains(block) ?? false)
    }

    public func toggle(itemID: Int, block: Int) {
        var state = ui[itemID] ?? SpikeItemUIState()
        if state.toggled.contains(block) { state.toggled.remove(block) } else { state.toggled.insert(block) }
        state.version += 1
        ui[itemID] = state
        guard let row = rowByID[itemID] else { return }
        if tail?.id == itemID { if let tail { relayoutTail(tail) }; return }
        requestLayout(row: row)
    }

    // MARK: Prepend

    /// Prepends a page of older messages, measured exactly off-main first, keeping the viewport anchored.
    public func prepend(_ older: [SpikeItem]) async {
        let theme = self.theme
        let width = self.width
        let inputs = older.map {
            SpikeLayoutInput(item: $0, blocks: nil, ui: SpikeItemUIState(), imageSizes: [:], width: width, theme: theme)
        }
        let measured = await SpikeLayoutEngine.measure(inputs)
        guard width == self.width else { return }
        let anchor = captureAnchor()
        items.insert(contentsOf: older, at: 0)
        heights.insert(contentsOf: measured.map(\.height), at: 0)
        heightKeys.insert(contentsOf: measured.map { Optional($0.key) }, at: 0)
        rebuildIndex()
        for item in older { for imageID in item.imageIDs { imageOwner[imageID] = item.id } }
        lastPrefetchRange = 0..<0
        withoutAnimation { tableView.insertRows(at: IndexSet(integersIn: 0..<older.count), withAnimation: []) }
        forceTableGeometry(from: 0)
        restore(anchor)
        updatePrefetch(force: true)
    }

    private func rebuildIndex() {
        rowByID.removeAll(keepingCapacity: true)
        for (row, item) in items.enumerated() { rowByID[item.id] = row }
    }

    public func row(forItemID id: Int) -> Int? { rowByID[id] }

    // MARK: Streaming tail

    /// Appends an empty assistant message that will receive deltas from `deltaBuffer`.
    public func beginStreamingTail(id: Int) {
        let item = SpikeItem(id: id, role: .assistant, parts: [.markdown("")], revision: 0)
        let state = TailState(id: id)
        state.layoutWidth = width
        tail = state
        items.append(item)
        rowByID[id] = items.count - 1
        let layout = composeTail()
        store(layout)
        heights.append(layout.height)
        heightKeys.append(layout.key)
        let anchor = captureAnchor()
        tableView.insertRows(at: IndexSet(integer: items.count - 1), withAnimation: [])
        restore(anchor)
        commitLink = tableView.displayLink(target: self, selector: #selector(commitTick(_:)))
        commitLink?.add(to: .main, forMode: .common)
    }

    public func endStreamingTail() {
        commitLink?.invalidate()
        commitLink = nil
        commitPending()
    }

    @objc private func commitTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        guard now - lastCommit >= commitInterval - 0.002 else { return }
        lastCommit = now
        commitPending()
    }

    private func commitPending() {
        guard let tail else { return }
        let drained = deltaBuffer.drain()
        if drained.overflowed { tailOverflowed = true }  // the real client would resync from the list endpoint
        guard !drained.text.isEmpty else { return }
        tail.source += drained.text
        tail.revision += 1
        for time in drained.times { tail.pendingTimes.append((tail.revision, time)) }
        startTailJob(tail)
    }

    private func startTailJob(_ tail: TailState) {
        guard !tail.jobInFlight else { return }
        tail.jobInFlight = true
        let source = tail.source
        let suffix = String(decoding: source.utf8.dropFirst(tail.stableEnd), as: UTF8.self)
        let firstIndex = tail.stableBlocks.count
        let ui = self.ui[tail.id] ?? SpikeItemUIState()
        let contentWidth = SpikeLayoutEngine.contentWidth(width, role: .assistant)
        let width = self.width
        let theme = self.theme
        let revision = tail.revision
        metrics.tailJobs += 1
        tailTask = Task { [weak self] in
            let result = await Self.tailJob(suffix: suffix, firstIndex: firstIndex, ui: ui, contentWidth: contentWidth,
                                            theme: theme)
            guard !Task.isCancelled, let self else { return }
            self.applyTailJob(result, tail: tail, revision: revision, width: width, firstIndex: firstIndex)
        }
    }

    @concurrent
    private static func tailJob(suffix: String, firstIndex: Int, ui: SpikeItemUIState, contentWidth: CGFloat,
                                theme: SpikeTheme) async -> sending SpikeTailJobResult {
        let state = spikeSignposter.beginInterval("tailJob")
        let result = SpikeTailJobResult()
        result.parsed = SpikeMarkdown.parse(suffix)
        result.layouts = SpikeLayoutEngine.layoutBlocks(result.parsed.map(\.block), startIndex: firstIndex, ui: ui,
                                                        imageSizes: [:], contentWidth: contentWidth,
                                                        fonts: SpikeFonts(theme: theme))
        spikeSignposter.endInterval("tailJob", state)
        return result
    }

    private func applyTailJob(_ result: SpikeTailJobResult, tail: TailState, revision: Int, width: CGFloat, firstIndex: Int) {
        tail.jobInFlight = false
        guard self.tail === tail else { return }
        guard width == self.width, firstIndex == tail.stableBlocks.count else {
            startTailJob(tail)  // width or stable prefix changed meanwhile: redo with current state
            return
        }
        let start = CACurrentMediaTime()
        let state = spikeSignposter.beginInterval("tailApply")
        let count = result.parsed.count
        let firstChangedBlock = tail.stableBlocks.count
        if count >= 2 {
            tail.stableBlocks += result.parsed[0..<(count - 1)].map(\.block)
            tail.stableLayouts += result.layouts[0..<(count - 1)]
            tail.stableEnd += result.parsed[count - 1].sourceStart
        }
        tail.openBlocks = count > 0 ? [result.parsed[count - 1].block] : []
        tail.openLayouts = count > 0 ? [result.layouts[count - 1]] : []
        tail.appliedRevision = revision
        tail.layoutWidth = width
        blockCache[tail.id] = nil

        let layout = composeTail()
        store(layout)
        guard let row = rowByID[tail.id] else { return }
        heightKeys[row] = layout.key
        if let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SpikeItemView {
            let dirtyTop = firstChangedBlock < layout.origins.count ? layout.origins[firstChangedBlock].y : 0
            view.layout = layout
            view.rowSelection = rowSelection(row: row)
            view.updateCanvas()
            view.invalidate(CGRect(x: 0, y: dirtyTop - 2, width: view.bounds.width, height: layout.height - dirtyTop + 4))
        }
        if abs(heights[row] - layout.height) > 0.25 {
            pendingHeights[tail.id] = layout.height
            flushHeights()
        }
        // Latency bookkeeping: deltas up to `revision` are now applied (visible at the next frame).
        var remaining: [(revision: Int, time: Double)] = []
        for entry in tail.pendingTimes {
            if entry.revision <= revision { appliedDeltaTimes.append(entry.time); appliedDeltaCount += 1 }
            else { remaining.append(entry) }
        }
        tail.pendingTimes = remaining
        metrics.maxTailApplyMilliseconds = max(metrics.maxTailApplyMilliseconds, (CACurrentMediaTime() - start) * 1000)
        spikeSignposter.endInterval("tailApply", state)
        if tail.revision > revision { startTailJob(tail) }
    }

    private func relayoutTail(_ tail: TailState) {
        // Width or expansion changed: re-parse and re-lay out the whole tail once.
        tail.stableBlocks = []
        tail.stableLayouts = []
        tail.stableEnd = 0
        tail.revision += 1
        startTailJob(tail)
    }

    private func composeTail() -> SpikeItemLayout {
        guard let tail else { fatalError("no tail") }
        let key = SpikeLayoutKey(id: tail.id, revision: tail.appliedRevision, uiVersion: ui[tail.id]?.version ?? 0,
                                 width: Int(width.rounded()))
        return SpikeItemLayout(key: key, blocks: tail.stableLayouts + tail.openLayouts, isUser: false, width: width,
                               theme: theme)
    }

    public func drainAppliedDeltaTimes() -> [Double] {
        defer { appliedDeltaTimes.removeAll(keepingCapacity: true) }
        return appliedDeltaTimes
    }

    public var tailSourceLength: Int { tail?.source.utf8.count ?? 0 }

    // MARK: Selection model

    public var hasSelection: Bool {
        guard let selection else { return false }
        return selection.anchor != selection.focus
    }

    private func isBefore(_ a: SpikePosition, _ b: SpikePosition) -> Bool {
        let ra = rowByID[a.itemID] ?? 0
        let rb = rowByID[b.itemID] ?? 0
        if ra != rb { return ra < rb }
        if a.block != b.block { return a.block < b.block }
        return a.offset < b.offset
    }

    private func orderedSelection() -> (start: SpikePosition, end: SpikePosition)? {
        guard let selection, selection.anchor != selection.focus else { return nil }
        return isBefore(selection.anchor, selection.focus) ? (selection.anchor, selection.focus)
            : (selection.focus, selection.anchor)
    }

    private func rowSelection(row: Int) -> SpikeRowSelection? {
        guard let (start, end) = orderedSelection(), let startRow = rowByID[start.itemID],
              let endRow = rowByID[end.itemID], row >= startRow, row <= endRow else { return nil }
        var result = SpikeRowSelection.whole
        if row == startRow { result.startBlock = start.block; result.startOffset = start.offset }
        if row == endRow { result.endBlock = end.block; result.endOffset = end.offset }
        return result
    }

    /// Table point -> transcript position (synchronous layout fallback for rows never drawn).
    private func position(at point: NSPoint) -> SpikePosition? {
        guard !items.isEmpty else { return nil }
        var row = tableView.row(at: NSPoint(x: 1, y: point.y))
        if row < 0 {
            row = point.y < 0 ? 0 : items.count - 1
        }
        let rowRect = tableView.rect(ofRow: row)
        let id = items[row].id
        guard let layout = (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SpikeItemView)?.layout
            ?? displayLayout(row: row) else { return nil }
        if point.y >= rowRect.maxY && row == items.count - 1 {
            let last = max(0, layout.blocks.count - 1)
            return SpikePosition(itemID: id, block: last, offset: layout.blocks.isEmpty ? 0 : layout.blocks[last].plainLength)
        }
        let hit = layout.hitTest(CGPoint(x: point.x - rowRect.minX, y: point.y - rowRect.minY))
        return SpikePosition(itemID: id, block: hit.block, offset: hit.offset)
    }

    private func refreshSelectionDrawing() {
        for (row, view) in availableItemViews() {
            let selection = rowSelection(row: row)
            if view.rowSelection != selection {
                view.rowSelection = selection
                view.invalidate()
            }
        }
    }

    public func clearSelection() {
        selection = nil
        findMatch = nil
        for (row, view) in availableItemViews() { configure(view, row: row) }
    }

    public func selectAll() {
        guard let first = items.first, let last = items.last, let blocks = blocks(itemID: last.id) else { return }
        let lastBlock = max(0, blocks.count - 1)
        let length = blocks.isEmpty ? 0 : (blocks[lastBlock].plainText(expanded: isExpanded(itemID: last.id, block: lastBlock)) as NSString).length
        selection = (SpikePosition(itemID: first.id, block: 0, offset: 0),
                     SpikePosition(itemID: last.id, block: lastBlock, offset: length))
        refreshSelectionDrawing()
    }

    /// Programmatic selection (scenario driver and find).
    public func select(from start: SpikePosition, to end: SpikePosition) {
        selection = (start, end)
        refreshSelectionDrawing()
    }

    public var selectionSpan: (rows: Int, startItem: Int, endItem: Int)? {
        guard let (start, end) = orderedSelection(), let a = rowByID[start.itemID], let b = rowByID[end.itemID] else { return nil }
        return (b - a + 1, start.itemID, end.itemID)
    }

    // MARK: Mouse

    func mouseDown(_ event: NSEvent) {
        tableView.window?.makeFirstResponder(tableView)
        let point = tableView.convert(event.locationInWindow, from: nil)
        guard let position = position(at: point) else { return }
        dragStartWindowPoint = event.locationInWindow
        lastDragWindowPoint = event.locationInWindow
        didDrag = false
        toggleCandidate = nil
        if let row = rowByID[position.itemID],
           let layout = (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SpikeItemView)?.layout {
            let rowRect = tableView.rect(ofRow: row)
            if let block = layout.toggleHit(CGPoint(x: point.x - rowRect.minX, y: point.y - rowRect.minY)) {
                toggleCandidate = (position.itemID, block)
            }
        }
        findMatch = nil
        if event.modifierFlags.contains(.shift), let selection {
            self.selection = (selection.anchor, position)
        } else if event.clickCount == 2 {
            selection = wordSelection(at: position)
        } else if event.clickCount >= 3 {
            selection = blockSelection(at: position)
        } else {
            selection = (position, position)
        }
        refreshSelectionDrawing()
    }

    func mouseDragged(_ event: NSEvent) {
        guard let start = dragStartWindowPoint else { return }
        lastDragWindowPoint = event.locationInWindow
        if hypot(lastDragWindowPoint.x - start.x, lastDragWindowPoint.y - start.y) > 3 { didDrag = true }
        updateDragFocus()
        updateAutoscroll()
    }

    func mouseUp(_ event: NSEvent) {
        lastDragWindowPoint = event.locationInWindow
        if didDrag { updateDragFocus() }
        stopAutoscroll()
        dragStartWindowPoint = nil
        if !didDrag, let candidate = toggleCandidate {
            selection = nil
            refreshSelectionDrawing()
            toggle(itemID: candidate.itemID, block: candidate.block)
        }
        toggleCandidate = nil
    }

    private func updateDragFocus() {
        guard let selection, dragStartWindowPoint != nil, didDrag else { return }
        let point = tableView.convert(lastDragWindowPoint, from: nil)
        guard let focus = position(at: point), focus != selection.focus else { return }
        self.selection = (selection.anchor, focus)
        refreshSelectionDrawing()
    }

    private func autoscrollSpeed() -> CGFloat {
        let point = scrollView.contentView.convert(lastDragWindowPoint, from: nil)
        let visible = scrollView.contentView.bounds
        if point.y < visible.minY { return -(visible.minY - point.y) }
        if point.y > visible.maxY { return point.y - visible.maxY }
        return 0
    }

    private func updateAutoscroll() {
        if autoscrollSpeed() == 0 { stopAutoscroll(); return }
        guard autoscrollTimer == nil else { return }
        lastAutoscrollTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollStep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoscrollTimer = timer
    }

    private func autoscrollStep() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - lastAutoscrollTime)
        lastAutoscrollTime = now
        let distance = autoscrollSpeed()
        guard distance != 0 else { stopAutoscroll(); return }
        // Speed grows with distance outside the view: 300 pt/s plus 25 pt/s per point, capped.
        let speed = min(6_000, 300 + abs(distance) * 25) * (distance < 0 ? -1 : 1)
        userScroll(by: speed * dt)
        updateDragFocus()
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    /// Scenario hook: is autoscroll running.
    public var isAutoscrolling: Bool { autoscrollTimer != nil }

    private func wordSelection(at position: SpikePosition) -> (SpikePosition, SpikePosition) {
        guard let blocks = blocks(itemID: position.itemID), position.block < blocks.count else { return (position, position) }
        let text = blocks[position.block].plainText(expanded: isExpanded(itemID: position.itemID, block: position.block)) as NSString
        var lo = min(position.offset, text.length)
        var hi = lo
        let letters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < text.length, let scalar = Unicode.Scalar(text.character(at: i)) else { return false }
            return letters.contains(scalar)
        }
        while isWord(lo - 1) { lo -= 1 }
        while isWord(hi) { hi += 1 }
        var a = position
        a.offset = lo
        var b = position
        b.offset = hi
        return (a, b)
    }

    private func blockSelection(at position: SpikePosition) -> (SpikePosition, SpikePosition) {
        guard let blocks = blocks(itemID: position.itemID), position.block < blocks.count else { return (position, position) }
        let length = (blocks[position.block].plainText(expanded: isExpanded(itemID: position.itemID, block: position.block)) as NSString).length
        var a = position
        a.offset = 0
        var b = position
        b.offset = length
        return (a, b)
    }

    // MARK: Copy

    private func blocks(itemID: Int) -> [SpikeBlock]? {
        if let tail, tail.id == itemID { return tail.blocks }
        guard let row = rowByID[itemID] else { return nil }
        let item = items[row]
        if let cached = blockCache[itemID], cached.revision == item.revision { return cached.blocks }
        let blocks = SpikeMarkdown.blocks(for: item)
        if blockCache.count > 256 { blockCache.removeAll(keepingCapacity: true) }
        blockCache[itemID] = (item.revision, blocks)
        return blocks
    }

    /// Plain text of the transcript selection, built from the model (not from views), so rows that scrolled off
    /// screen or were never drawn copy correctly.
    public func selectedText() -> String {
        guard let (start, end) = orderedSelection(), let startRow = rowByID[start.itemID], let endRow = rowByID[end.itemID]
        else { return "" }
        var output = ""
        for row in startRow...endRow {
            let id = items[row].id
            guard let blocks = blocks(itemID: id), let rowSelection = rowSelection(row: row) else { continue }
            var rowText = ""
            var previous: SpikeBlock?
            for (index, block) in blocks.enumerated() {
                let plain = block.plainText(expanded: isExpanded(itemID: id, block: index)) as NSString
                guard let range = rowSelection.range(forBlock: index, length: plain.length) else { continue }
                let clamped = NSRange(location: range.lowerBound, length: min(range.upperBound, plain.length) - range.lowerBound)
                guard clamped.length > 0 else { continue }
                if !rowText.isEmpty, let previous { rowText += block.copySeparator(after: previous) }
                rowText += plain.substring(with: clamped)
                previous = block
            }
            if !rowText.isEmpty {
                if !output.isEmpty { output += "\n\n" }
                output += rowText
            }
        }
        return output
    }

    public func copySelection() {
        let text = selectedText()
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Find

    private func startSearchIndex() {
        let items = self.items
        let start = CACurrentMediaTime()
        indexTask = Task(priority: .utility) { [weak self] in
            let index = await withTaskGroup(of: (Int, [(id: Int, blocks: [String])]).self) { group in
                var offset = 0
                while offset < items.count {
                    let chunk = Array(items[offset..<min(offset + 2_500, items.count)])
                    let chunkStart = offset
                    group.addTask(priority: .utility) { (chunkStart, await Self.indexChunk(chunk)) }
                    offset += 2_500
                }
                var parts: [(Int, [(id: Int, blocks: [String])])] = []
                for await part in group { parts.append(part) }
                return parts.sorted { $0.0 < $1.0 }.flatMap(\.1)
            }
            guard !Task.isCancelled, let self else { return }
            self.searchIndex = index
            self.searchIndexReady = true
            self.metrics.searchIndexMilliseconds = (CACurrentMediaTime() - start) * 1000
        }
    }

    @concurrent
    private static func indexChunk(_ items: [SpikeItem]) async -> [(id: Int, blocks: [String])] {
        items.map { item in (item.id, SpikeMarkdown.blocks(for: item).map { $0.plainText(expanded: true) }) }
    }

    @concurrent
    private static func search(_ index: [(id: Int, blocks: [String])], query: String, after: (id: Int, block: Int, offset: Int)?)
        async -> SpikeFindMatch? {
        let start = after.flatMap { position in index.firstIndex { $0.id == position.id } } ?? 0
        for step in 0..<index.count {
            let entry = index[(start + step) % index.count]
            for (blockIndex, text) in entry.blocks.enumerated() {
                if step == 0, let after, entry.id == after.id, blockIndex < after.block { continue }
                let ns = text as NSString
                var from = 0
                if step == 0, let after, entry.id == after.id, blockIndex == after.block { from = min(ns.length, after.offset) }
                let found = ns.range(of: query, options: .caseInsensitive, range: NSRange(location: from, length: ns.length - from))
                if found.location != NSNotFound {
                    return SpikeFindMatch(itemID: entry.id, block: blockIndex,
                                          range: found.location..<(found.location + found.length))
                }
            }
        }
        return nil
    }

    /// Finds the next match after the current one (or from the top) and reveals it.
    public func findNext(_ query: String) async -> SpikeFindMatch? {
        guard searchIndexReady, !query.isEmpty else { return nil }
        let after = findMatch.map { (id: $0.itemID, block: $0.block, offset: $0.range.upperBound) }
        guard let match = await Self.search(searchIndex, query: query, after: after) else { return nil }
        await reveal(match)
        return match
    }

    /// Expands a collapsed card if the match is inside its body, lays the item out exactly, scrolls the match to the
    /// middle of the viewport and highlights it.
    public func reveal(_ match: SpikeFindMatch) async {
        guard let row = rowByID[match.itemID], let blocks = blocks(itemID: match.itemID), match.block < blocks.count else { return }
        let block = blocks[match.block]
        if block.isCollapsible, !isExpanded(itemID: match.itemID, block: match.block),
           match.range.lowerBound > (block.headerText(expanded: false) as NSString).length {
            var state = ui[match.itemID] ?? SpikeItemUIState()
            state.toggled.formSymmetricDifference([match.block])
            state.version += 1
            ui[match.itemID] = state
        }
        setFollowing(false)
        let input = layoutInput(row: row)
        let layout = await SpikeLayoutEngine.layout(input)
        guard currentKey(row: row) == layout.key else { return }
        store(layout)
        heightKeys[row] = layout.key
        if abs(heights[row] - layout.height) > 0.25 { pendingHeights[match.itemID] = layout.height }
        flushHeights()
        let rowRect = tableView.rect(ofRow: row)
        let frame = layout.blockFrame(match.block)
        let rect = layout.blocks[match.block].rect(forOffset: match.range.lowerBound)
        let y = rowRect.minY + frame.minY + rect.midY
        setScroll(y - scrollView.contentView.bounds.height / 2)
        findMatch = match
        selection = (SpikePosition(itemID: match.itemID, block: match.block, offset: match.range.lowerBound),
                     SpikePosition(itemID: match.itemID, block: match.block, offset: match.range.upperBound))
        updatePrefetch(force: true)
        for (visibleRow, view) in availableItemViews() { configure(view, row: visibleRow) }
    }

    /// Screen-space (scroll view coordinates) rect of a match, if its row is on screen.
    public func visibleRect(of match: SpikeFindMatch) -> CGRect? {
        guard let row = rowByID[match.itemID],
              let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SpikeItemView,
              let layout = view.layout, match.block < layout.blocks.count else { return nil }
        let frame = layout.blockFrame(match.block)
        let rect = layout.blocks[match.block].rect(forOffset: match.range.lowerBound).offsetBy(dx: frame.minX, dy: frame.minY)
        return view.convert(rect, to: scrollView)
    }

    // MARK: Scenario introspection

    /// Top-left of a block as drawn, in scroll view coordinates (independent of the anchor bookkeeping: it reads the
    /// actual row view frame).
    public func drawnBlockTop(itemID: Int, block: Int) -> CGFloat? {
        guard let row = rowByID[itemID],
              let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SpikeItemView,
              let layout = view.layout, block < layout.blocks.count else { return nil }
        return view.convert(CGPoint(x: 0, y: layout.origins[block].y), to: scrollView).y
    }

    /// First visible item and block at the top of the viewport.
    public func topVisible() -> (itemID: Int, block: Int)? {
        let visible = scrollView.contentView.bounds
        let row = tableView.row(at: NSPoint(x: 1, y: visible.minY + 1))
        guard row >= 0, let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SpikeItemView,
              let layout = view.layout else { return nil }
        let y = visible.minY + 1 - tableView.rect(ofRow: row).minY
        return (items[row].id, layout.blockIndex(atY: y))
    }

    public var visibleRows: Range<Int> {
        let range = tableView.rows(in: tableView.visibleRect)
        return range.location..<(range.location + range.length)
    }

    public func rowRect(_ row: Int) -> CGRect { tableView.rect(ofRow: row) }

    public var layoutCacheCount: Int { layouts.count }
    public var inflightLayouts: Int { inflight.count }

    /// Our own prefix sum of row heights (to compare with NSTableView's geometry).
    public func modelOffset(ofRow row: Int) -> CGFloat { heights[0..<row].reduce(0, +) }

    /// Visible rows whose view currently draws a selection (scenario check after row reuse).
    public var visibleRowsDrawingSelection: Int { visibleItemViews().filter { $0.view.rowSelection != nil }.count }

    public var exactRowCount: Int {
        items.indices.filter { heightKeys[$0] == currentKey(row: $0) }.count
    }

    public func blocksForTesting(itemID: Int) -> [SpikeBlock]? { blocks(itemID: itemID) }

    /// Item-local hit test through the drawn layout, for scenario use.
    public func windowPoint(itemID: Int, block: Int, offset: Int) -> NSPoint? {
        guard let row = rowByID[itemID],
              let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SpikeItemView,
              let layout = view.layout, block < layout.blocks.count else { return nil }
        let frame = layout.blockFrame(block)
        let rect = layout.blocks[block].rect(forOffset: offset).offsetBy(dx: frame.minX, dy: frame.minY)
        return view.convert(CGPoint(x: frame.minX + 4, y: rect.midY), to: nil)
    }

    public func itemID(atRow row: Int) -> Int { items[row].id }
}
