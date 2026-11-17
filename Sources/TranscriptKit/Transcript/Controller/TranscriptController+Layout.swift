import AppKit
import BelloCore
import DesignSystem
import QuartzCore

/// Result of the off-main open pass: rows, segments, estimated heights, exact layouts for the bottom rows.
final class OpenResult {
    var rows: [TranscriptRow] = []
    var segments: [MessageID: (revision: Int, turn: MessageID?, segments: [RowBuilder.Segment])] = [:]
    var heights: [CGFloat] = []
    var exact: [(index: Int, layout: RowLayout)] = []
}

extension TranscriptController {
    // MARK: Open

    /// First content: rows, estimates and the bottom three viewports' exact layouts are computed off the main actor,
    /// then the table loads once at the bottom (or at the restored anchor).
    func open(ids: [MessageID], running: Bool) {
        guard let source else { return }
        let messages = ids.compactMap { source.transcriptMessage($0) }
        let start = CACurrentMediaTime()
        updateContentWidth()
        let width = contentWidth
        let theme = self.theme
        let highlighter = self.highlighter
        let cache = blockCache
        let viewport = max(400, scrollView.contentView.bounds.height)
        let generation = observationGeneration
        knownIDs = ids
        openTask = Task { [weak self] in
            let result = await Self.openPass(
                messages: messages, running: running, width: width, theme: theme, viewportHeight: viewport,
                highlighter: highlighter, cache: cache)
            guard let self, !Task.isCancelled, self.observationGeneration == generation else { return }
            self.openTask = nil
            self.finishOpen(result, start: start)
        }
    }

    @concurrent
    static func openPass(
        messages: [Message], running: Bool, width: CGFloat, theme: TranscriptTheme, viewportHeight: CGFloat,
        highlighter: any HighlightService, cache: RenderBlockCache
    ) async -> sending OpenResult {
        let signpost = transcriptSignposter.beginInterval("openPass")
        defer { transcriptSignposter.endInterval("openPass", signpost) }
        let result = OpenResult()
        var turn: MessageID?
        var segments: [RowBuilder.Segment] = []
        for message in messages {
            if case .user = message.kind { turn = message.id }
            let messageSegments = RowBuilder.segments(for: message, turnID: turn)
            result.segments[message.id] = (message.revision, turn, messageSegments)
            segments += messageSegments
        }
        result.rows = RowBuilder.rows(from: segments, isRunning: running, lastTurn: turn)
        result.heights = result.rows.indices.map { index in
            LayoutEngine.estimate(result.rows[index], width: width, theme: theme, topPadding: topPadding(result.rows, index))
        }
        let fonts = TranscriptFonts(theme: theme)
        var accumulated: CGFloat = 0
        var index = result.rows.count - 1
        while index >= 0, accumulated < viewportHeight * 3 {
            if Task.isCancelled { break }
            let input = RowLayoutInput(
                row: result.rows[index], ui: RowUIState(), width: width, theme: theme,
                topPadding: topPadding(result.rows, index), imageSizes: [:], blocks: nil, highlighter: highlighter, cache: cache)
            let layout = LayoutEngine.layoutNow(input, fonts: fonts)
            result.heights[index] = layout.height
            result.exact.append((index, layout))
            accumulated += layout.height
            index -= 1
        }
        return result
    }

    func finishOpen(_ result: OpenResult, start: CFTimeInterval) {
        let signpost = transcriptSignposter.beginInterval("finishOpen")
        defer { transcriptSignposter.endInterval("finishOpen", signpost) }
        rows = result.rows
        rowIndex = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        segmentCache = result.segments
        heights = result.heights
        heightKeys = Array(repeating: nil, count: rows.count)
        for (index, layout) in result.exact where layout.key == currentKey(row: index) {
            store(layout)
            heightKeys[index] = layout.key
        }
        lastRunning = source?.transcriptIsRunning ?? false
        isReady = true
        for id in knownIDs.suffix(Self.trackedTail) { track(id) }
        updateSpacer()
        tableView.reloadData()
        forceTableGeometry(from: 0)
        following = true
        scrollToBottom()
        applyPendingRestore()
        updatePrefetch(force: true)
        updateEmptyState()
        metrics.openMilliseconds = (CACurrentMediaTime() - start) * 1000
        scheduleMeasureAll()
        // Anything that changed while the open pass ran.
        let ids = source?.transcriptMessageIDs ?? []
        if ids != knownIDs || !dirtyMessages.isEmpty { sync() }
        for row in rows where row.isLive { if let index = rowIndex[row.id] { contentChanged(row: index) } }
    }

    // MARK: Keys, padding, estimates

    /// Space above a row, from its kind and its predecessor's.
    nonisolated static func topPadding(_ rows: [TranscriptRow], _ index: Int) -> CGFloat {
        let row = rows[index]
        guard index > 0 else { return 0 }
        let previous = rows[index - 1]
        if row.role == .user { return TranscriptTheme.turnGap }
        if previous.role == .user { return 16 }
        if case .lifecycle = row.content { return 12 }
        if case .lifecycle = previous.content { return 12 }
        if case .work = row.content, case .work = previous.content { return 4 }
        if case .reasoning = previous.content { return 8 }
        return TranscriptTheme.blockSpacing
    }

    func topPadding(_ index: Int) -> CGFloat { Self.topPadding(rows, index) }

    func estimate(_ row: TranscriptRow, index: Int) -> CGFloat {
        LayoutEngine.estimate(row, width: contentWidth, theme: theme, topPadding: topPadding(index))
    }

    func currentKey(row index: Int) -> LayoutKey {
        let row = rows[index]
        let uiVersion = ui[row.id]?.version ?? 0
        if let tail = tails[row.id] {
            return LayoutKey(
                rowID: row.id, version: tail.keyVersion, uiVersion: uiVersion, width: Int(contentWidth.rounded()),
                themeRevision: theme.revision, topPadding: Int(topPadding(index).rounded()))
        }
        return LayoutKey(
            rowID: row.id, version: row.version, uiVersion: uiVersion, width: Int(contentWidth.rounded()),
            themeRevision: theme.revision, topPadding: Int(topPadding(index).rounded()))
    }

    func layoutInput(row index: Int) -> RowLayoutInput {
        let row = rows[index]
        return RowLayoutInput(
            row: row, ui: ui[row.id] ?? RowUIState(), width: contentWidth, theme: theme, topPadding: topPadding(index),
            imageSizes: imageSizes(for: row), blocks: nil, highlighter: highlighter, cache: blockCache)
    }

    func imageSizes(for row: TranscriptRow) -> [String: CGSize] {
        guard !imageSizes.isEmpty else { return [:] }
        var sizes: [String: CGSize] = [:]
        for source in Self.imageSources(row) { if let size = imageSizes[source] { sizes[source] = size } }
        return sizes
    }

    nonisolated static func imageSources(_ row: TranscriptRow) -> [String] {
        switch row.content {
        case .user(let user): return user.attachments.filter(\.isImage).map(\.uri)
        case .file(let file): return file.isImage ? [file.uri] : []
        case .markdown(let text, _):
            guard text.contains("![") else { return [] }
            return MarkdownParser.blocks(text).compactMap { if case .image(let source, _) = $0.kind { source } else { nil } }
        default: return []
        }
    }

    // MARK: Layout cache

    func store(_ layout: RowLayout) {
        tick += 1
        let id = layout.key.rowID
        if let old = layouts[id] { layoutCacheCost -= old.cost }
        layouts[id] = layout
        layoutCacheCost += layout.cost
        layoutTick[id] = tick
        if layouts.count > layoutCacheLimit || layoutCacheCost > layoutCacheCostLimit { evictLayouts() }
    }

    /// Evicts least recently used layouts just until the cache is back under its bounds, so deallocation is spread out.
    func evictLayouts() {
        let keep = Set(availableCells().map { rows[$0.index].id })
        let candidates = layoutTick.filter { !keep.contains($0.key) && tails[$0.key] == nil }.sorted { $0.value < $1.value }
        for (id, _) in candidates {
            guard layouts.count > layoutCacheLimit || layoutCacheCost > layoutCacheCostLimit else { break }
            if let old = layouts.removeValue(forKey: id) { layoutCacheCost -= old.cost }
            layoutTick[id] = nil
        }
    }

    /// The layout to draw for a row now: current; else stale (other key) while a fresh one is computed; else a
    /// synchronous layout for a visible row (counted: prefetch makes it rare).
    func displayLayout(row index: Int, allowPlaceholder: Bool = false) -> RowLayout? {
        let id = rows[index].id
        let key = currentKey(row: index)
        if let layout = layouts[id] {
            tick += 1
            layoutTick[id] = tick
            if layout.key != key { requestLayout(row: index) }
            return layout
        }
        if let tail = tails[id], let layout = tail.composed { return layout }
        // Rows AppKit prepares outside the viewport (responsive-scrolling overdraw) get their layout asynchronously.
        if allowPlaceholder, !tableView.visibleRect.intersects(rowRect(index)) {
            requestLayout(row: index)
            metrics.placeholderRows += 1
            return nil
        }
        let signpost = transcriptSignposter.beginInterval("syncLayout")
        let layout = LayoutEngine.layoutNow(layoutInput(row: index), fonts: TranscriptFonts(theme: theme))
        transcriptSignposter.endInterval("syncLayout", signpost)
        metrics.syncLayouts += 1
        store(layout)
        acceptHeight(layout, row: index)
        return layout
    }

    func requestLayout(row index: Int, priority: Bool = false) {
        guard index < rows.count else { return }
        let row = rows[index]
        if tails[row.id] != nil { return }
        let input = layoutInput(row: index)
        let key = input.key
        if layouts[row.id]?.key == key || inflight[row.id] == key { return }
        inflight[row.id] = key
        layoutTasks[row.id]?.cancel()
        metrics.asyncLayouts += 1
        layoutTasks[row.id] = Task(priority: priority ? .userInitiated : nil) { [weak self] in
            let layout = await LayoutEngine.layout(input)
            guard !Task.isCancelled, let self else { return }
            self.didFinishLayout(layout)
        }
    }

    func didFinishLayout(_ layout: RowLayout) {
        let id = layout.key.rowID
        if inflight[id] == layout.key {
            inflight[id] = nil
            layoutTasks[id] = nil
        }
        defer { if inflight.count < maxInflightPrefetch / 2 { updatePrefetch(force: true) } }
        guard let index = rowIndex[id], currentKey(row: index) == layout.key else { return }  // stale: drop
        store(layout)
        acceptHeight(layout, row: index)
        if pendingHeights[id] == nil, let view = cellView(index) { configure(view, index: index) }
    }

    func acceptHeight(_ layout: RowLayout, row index: Int) {
        heightKeys[index] = layout.key
        if abs(heights[index] - layout.height) > 0.25 {
            pendingHeights[layout.key.rowID] = layout.height
            scheduleFlush()
        }
    }

    /// Visible rows first; then rows ahead in the scroll direction (0.35 s of travel, at least 1.5 viewports), then
    /// one viewport behind. At most `maxInflightPrefetch` prefetch layouts run at once.
    func updatePrefetch(force: Bool = false) {
        guard !rows.isEmpty else { return }
        let visible = tableView.visibleRect
        guard visible.height > 0 else { return }
        let ahead = max(visible.height * 1.5, abs(scrollVelocity) * 0.35)
        let down = scrollVelocity >= 0
        let window = CGRect(
            x: 0, y: visible.minY - (down ? visible.height : ahead), width: visible.width, height: visible.height * 2 + ahead)
        let range = tableView.rows(in: window)
        let tableRows = range.location..<(range.location + range.length)
        if !force, tableRows == lastPrefetchRange { return }
        lastPrefetchRange = tableRows
        let visibleNS = tableView.rows(in: visible)
        let visibleRows = (visibleNS.location..<(visibleNS.location + visibleNS.length)).compactMap { modelIndex(tableRow: $0) }
        for index in visibleRows { requestLayout(row: index, priority: true) }
        let all = tableRows.compactMap { modelIndex(tableRow: $0) }
        guard let firstVisible = visibleRows.first ?? all.first, let lastVisible = visibleRows.last ?? all.last else { return }
        let below = all.filter { $0 > lastVisible }
        let above = all.filter { $0 < firstVisible }.reversed()
        let order: [Int] = down ? below + above : Array(above) + below
        for index in order {
            if inflight.count >= maxInflightPrefetch { break }
            requestLayout(row: index)
        }
    }

    // MARK: Height changes

    func scheduleFlush() {
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
        let signpost = transcriptSignposter.beginInterval("flushHeights")
        let start = CACurrentMediaTime()
        let anchor = captureAnchor()
        var tableRows = IndexSet()
        for (id, height) in pendingHeights {
            guard let index = rowIndex[id] else { continue }
            heights[index] = height
            tableRows.insert(index + 1)
        }
        pendingHeights.removeAll()
        withoutAnimation { tableView.noteHeightOfRows(withIndexesChanged: tableRows) }
        forceTableGeometry(from: tableRows.first ?? 0)
        for (index, view) in availableCells() where tableRows.contains(index + 1) { configure(view, index: index) }
        updateSpacer()
        restore(anchor)
        metrics.heightFlushes += 1
        metrics.maxFlushMilliseconds = max(metrics.maxFlushMilliseconds, (CACurrentMediaTime() - start) * 1000)
        transcriptSignposter.endInterval("flushHeights", signpost)
        updatePrefetch()
    }

    /// NSTableView computes variable row offsets lazily and *estimates* rows it has not asked about, so its geometry
    /// silently drifts from our heights (43,000 pt at row 5,000 in the G1-B spike) and moves rows while the user
    /// scrolls. Asking for every row rect from the first changed row onward forces it to use our heights. Cost: about
    /// 0.5 µs per row. `TranscriptGeometryTests` guards this undocumented behaviour.
    func forceTableGeometry(from tableRow: Int) {
        let count = rows.count + 2
        guard tableRow < count else { return }
        for row in max(0, tableRow)..<count { _ = tableView.rect(ofRow: row) }
    }

    /// Our own prefix sum of heights (geometry tests compare it with the table's).
    public func modelOffset(ofRow index: Int) -> CGFloat { lastHeaderHeight + heights[0..<index].reduce(0, +) }

    public func tableOffset(ofRow index: Int) -> CGFloat { rowRect(index).minY }

    // MARK: Width

    func updateContentWidth() {
        let available = scrollView.contentView.bounds.width
        contentWidth = TranscriptGeometry.contentWidth(forTableWidth: available)
    }

    func clipFrameChanged() {
        let old = contentWidth
        updateContentWidth()
        updateSpacer()
        guard abs(contentWidth - old) >= 1, !rows.isEmpty else {
            for (_, view) in availableCells() { view.needsLayout = true; view.invalidate() }
            return
        }
        generation += 1
        measureTask?.cancel()
        // Visible rows re-lay out off-main right away and draw their previous layout (clipped) for a frame or two;
        // off-screen rows keep their heights until measured again (anchored).
        updatePrefetch(force: true)
        relayoutTails()
        scheduleMeasureAll(delay: 0.4)
    }

    // MARK: Measure-all

    func scheduleMeasureAll(delay: Double = 0) {
        measureDebounce?.cancel()
        measureDebounce = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
            guard !Task.isCancelled else { return }
            self?.startMeasureAll()
        }
    }

    /// Exact heights for every row, in the background at utility QoS on at most half the cores (saturating every core
    /// starved display-link delivery in the spike), committed at most ~6 times a second.
    func startMeasureAll() {
        measureTask?.cancel()
        measureAllComplete = false
        let generation = self.generation
        var inputs: [RowLayoutInput] = []
        // Nearest the viewport first, so corrections land where the reader is.
        let visible = tableView.rows(in: tableView.visibleRect)
        let center = modelIndex(tableRow: visible.location + visible.length / 2) ?? (rows.count - 1)
        let order = rows.indices.sorted { abs($0 - center) < abs($1 - center) }
        for index in order where heightKeys[index] != currentKey(row: index) && tails[rows[index].id] == nil {
            inputs.append(layoutInput(row: index))
        }
        let start = CACurrentMediaTime()
        let total = inputs.count
        // Batches flow from an off-main producer to the main actor through a stream (≤ ~7 commits a second; the
        // buffer is bounded by the row count). Orchestrating the task group on the main actor throttled it to
        // whenever the main thread was free.
        let (stream, continuation) = AsyncStream<[(key: LayoutKey, height: CGFloat)]>.makeStream()
        let work = inputs
        measureTask = Task(priority: .utility) { [weak self] in
            async let producer: Void = Self.measureAll(work, into: continuation)
            for await batch in stream {
                guard let self, !Task.isCancelled, self.generation == generation else { break }
                self.applyMeasured(batch)
            }
            await producer
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.metrics.measureAllMilliseconds = (CACurrentMediaTime() - start) * 1000
            self.metrics.measureAllRows = total
            self.measureAllComplete = true
            self.onMeasureAllFinished?()
        }
    }

    /// Measures `inputs` in chunks of 100 on at most half the cores at utility QoS, yielding batches.
    @concurrent
    nonisolated static func measureAll(
        _ inputs: [RowLayoutInput], into continuation: AsyncStream<[(key: LayoutKey, height: CGFloat)]>.Continuation
    ) async {
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        await withTaskGroup(of: [(key: LayoutKey, height: CGFloat)].self) { group in
            var index = 0
            var running = 0
            func addChunk() {
                let chunk = Array(inputs[index..<min(index + 100, inputs.count)])
                group.addTask(priority: .utility) { await LayoutEngine.measure(chunk) }
                index += 100
                running += 1
            }
            while index < inputs.count, running < width { addChunk() }
            var batch: [(key: LayoutKey, height: CGFloat)] = []
            var lastYield = CACurrentMediaTime()
            for await result in group {
                running -= 1
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if index < inputs.count { addChunk() }
                batch += result
                if CACurrentMediaTime() - lastYield > 0.15 || running == 0 {
                    continuation.yield(batch)
                    batch.removeAll()
                    lastYield = CACurrentMediaTime()
                }
            }
            if !batch.isEmpty { continuation.yield(batch) }
        }
        continuation.finish()
    }

    func applyMeasured(_ results: [(key: LayoutKey, height: CGFloat)]) {
        for (key, height) in results {
            guard let index = rowIndex[key.rowID], currentKey(row: index) == key else { continue }
            heightKeys[index] = key
            if abs(heights[index] - height) > 0.25 { pendingHeights[key.rowID] = height }
        }
        scheduleFlush()
    }

    /// Rows whose height is exact for the current width and theme.
    public var exactRowCount: Int { rows.indices.filter { heightKeys[$0] == currentKey(row: $0) }.count }
}

/// Column geometry shared with the composer: a centred column at most `DS.Spacing.readableWidth` wide.
public enum TranscriptGeometry {
    public static func contentWidth(forTableWidth width: CGFloat) -> CGFloat {
        let margin = DSColumn.margin
        return max(220, min(DSColumn.readableWidth, width - 2 * margin))
    }

    public static func columnX(forTableWidth width: CGFloat, contentWidth: CGFloat) -> CGFloat {
        max(DSColumn.margin, floor((width - contentWidth) / 2))
    }
}

enum DSColumn {
    static let readableWidth = DS.Spacing.readableWidth
    static let margin = DS.Spacing.columnMargin
}

extension TranscriptController {
    /// No layout, height flush, open pass or streaming job is pending (harness and tests).
    public var isSettled: Bool {
        openTask == nil && inflight.isEmpty && pendingHeights.isEmpty && !flushScheduled && !syncScheduled
            && tails.values.allSatisfy { !$0.jobInFlight && $0.pendingText == nil }
    }

    /// Waits until `isSettled` (bounded).
    public func settle(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while !isSettled, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(30))
    }

    /// The first row whose content matches.
    public func rowID(where predicate: (TranscriptRow) -> Bool) -> RowID? { rows.first(where: predicate)?.id }
}
