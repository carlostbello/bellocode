import AppKit
import BelloCore
import DesignSystem
import QuartzCore

extension TranscriptController {
    /// What the viewport is pinned to across a change.
    enum Anchor {
        case bottom
        case row(id: RowID, block: Int?, offset: CGFloat)
    }

    func captureAnchor() -> Anchor {
        if following { return .bottom }
        let visible = scrollView.contentView.bounds
        var tableRow = tableView.row(at: NSPoint(x: 1, y: visible.minY))
        if tableRow == 0 || tableRow < 0 { tableRow = 1 }
        guard let index = modelIndex(tableRow: tableRow) else { return .bottom }
        let rowTop = rowRect(index).minY
        let y = visible.minY - rowTop
        let id = rows[index].id
        if let layout = cellView(index)?.layout, layout.key.rowID == id, !layout.blocks.isEmpty, y >= 0 {
            let block = layout.blockIndex(atY: y)
            return .row(id: id, block: block, offset: y - layout.origins[block].y)
        }
        return .row(id: id, block: nil, offset: y)
    }

    func restore(_ anchor: Anchor) {
        switch anchor {
        case .bottom:
            scrollToBottom()
        case .row(let id, let block, let offset):
            guard let index = rowIndex[id] else { return }
            let rowTop = rowRect(index).minY
            var y = rowTop + offset
            if let block, let layout = layouts[id] ?? tails[id]?.composed, block < layout.blocks.count {
                y = rowTop + layout.origins[block].y + offset
            }
            setScroll(y)
        }
    }

    var documentHeight: CGFloat { tableView.rect(ofRow: rows.count + 1).maxY }

    func setScroll(_ y: CGFloat) {
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

    public func scrollToBottom() { setScroll(.greatestFiniteMagnitude) }

    public var distanceFromBottom: CGFloat { documentHeight - scrollView.contentView.bounds.maxY }

    // MARK: Follow, release, rejoin

    func boundsChanged() {
        let now = CACurrentMediaTime()
        let y = scrollView.contentView.bounds.minY
        if now - lastBoundsTime > 0.2 {
            scrollVelocity = 0
        } else if now > lastBoundsTime {
            scrollVelocity = 0.7 * scrollVelocity + 0.3 * (y - lastBoundsY) / CGFloat(now - lastBoundsTime)
        }
        lastBoundsY = y
        lastBoundsTime = now
        for (_, view) in visibleCells() where view.bounds.height > TranscriptCellView.tallRowThreshold { view.updateCanvas() }
        updatePrefetch()
        if !isAdjustingScroll, liveScrolling || now - lastWheelTime < 0.6 { evaluateFollow() }
        if dragStartWindowPoint != nil { updateDragFocus() }
        maybeLoadOlder()
        if !isAdjustingScroll { scheduleAnchorNotification() }
    }

    func noteWheel(_ event: NSEvent) {
        guard event.window === scrollView.window else { return }
        let point = scrollView.convert(event.locationInWindow, from: nil)
        guard scrollView.bounds.contains(point) else { return }
        noteUserScroll(deltaY: event.scrollingDeltaY)
    }

    /// Real and synthesised wheel events, and the harness's programmatic user scrolling.
    public func noteUserScroll(deltaY: CGFloat) {
        lastWheelTime = CACurrentMediaTime()
        if deltaY > 0 {  // toward older content
            turnAnchor = nil
            if following { setFollowing(false) }
        }
    }

    func evaluateFollow() {
        let distance = distanceFromBottom
        if distance > 2, following, liveScrolling { setFollowing(false) }
        if distance <= 2, !following { setFollowing(true) }
    }

    func setFollowing(_ value: Bool) {
        guard following != value else { return }
        following = value
        if value {
            hasNewOutput = false
            hidePill()
        } else {
            schedulePill()
        }
    }

    /// Content arrived while the reader is away from the bottom.
    func noteNewOutput() {
        guard !following, !hasNewOutput else { return }
        hasNewOutput = true
        jumpPill.setTitle(newOutput: true)
    }

    /// Debounced on show (no flicker while scrolling near the bottom), immediate on hide.
    func schedulePill() {
        pillTask?.cancel()
        pillTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, !self.following, !self.rows.isEmpty else { return }
            self.jumpPill.setTitle(newOutput: self.hasNewOutput)
            self.jumpPill.isHidden = false
            self.jumpPill.setAccessibilityElement(true)
        }
    }

    func hidePill() {
        pillTask?.cancel()
        jumpPill.isHidden = true
    }

    public var isJumpPillVisible: Bool { !jumpPill.isHidden }

    /// Scrolls to the newest content and follows it again.
    public func jumpToLatest() {
        turnAnchor = nil
        updateSpacer()
        setFollowing(true)
        scrollToBottom()
        scheduleAnchorNotification()
    }

    /// Harness: user scroll by a delta (positive = toward the bottom).
    public func userScroll(by delta: CGFloat) {
        noteUserScroll(deltaY: -delta)
        let clip = scrollView.contentView
        let maxY = max(0, documentHeight - clip.bounds.height)
        let target = min(max(0, clip.bounds.origin.y + delta), maxY)
        clip.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(clip)
        if delta > 0 { evaluateFollow() }
    }

    public func scrollTo(y: CGFloat) { setScroll(y) }

    // MARK: New turn anchoring

    /// Holds a new prompt near the top of the viewport (T3 Code's behaviour): a spacer below the content keeps it
    /// there until the reply is taller than the viewport, then the transcript follows the bottom as usual.
    func beginTurnAnchor(_ id: RowID) {
        turnAnchor = id
        following = true
        hidePill()
        updateSpacer()
    }

    func updateSpacer() {
        var height = TranscriptMetrics.bottomPadding
        if let id = turnAnchor, let index = rowIndex[id], following {
            let viewport = scrollView.contentView.bounds.height
            let contentBelow = (heights[index...].reduce(0, +)) - topPadding(index) + TranscriptMetrics.bottomPadding
            let needed = viewport - contentBelow - TranscriptMetrics.turnTopInset
            if needed > TranscriptMetrics.bottomPadding {
                height = needed + TranscriptMetrics.bottomPadding
            } else {
                turnAnchor = nil
            }
        } else {
            turnAnchor = nil
        }
        height = ceil(height)
        guard abs(height - spacerHeight) > 0.5 else { return }
        spacerHeight = height
        withoutAnimation { tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: rows.count + 1)) }
        _ = tableView.rect(ofRow: rows.count + 1)
        if following { scrollToBottom() }
    }

    // MARK: Paging older history

    /// Loads an older page when the reader nears the top. The prepend keeps the viewport anchored.
    func maybeLoadOlder() {
        guard let source, source.transcriptHasOlder, !source.transcriptIsLoadingOlder, loadOlderTask == nil else { return }
        let visible = scrollView.contentView.bounds
        guard visible.minY < visible.height * 1.5 else { return }
        loadOlderTask = Task { [weak self] in
            await source.transcriptLoadOlder()
            self?.loadOlderTask = nil
        }
    }

    // MARK: Restoration

    /// The reader's position for restoration; nil while at the bottom (following).
    public var scrollAnchor: TranscriptAnchor? {
        guard !following, !rows.isEmpty else { return nil }
        let visible = scrollView.contentView.bounds
        let tableRow = max(1, tableView.row(at: NSPoint(x: 1, y: visible.minY)))
        guard let index = modelIndex(tableRow: tableRow) else { return nil }
        let messageID = rows[index].messageID
        let first = rows.firstIndex { $0.messageID == messageID } ?? index
        return TranscriptAnchor(messageID: messageID, offset: Double(visible.minY - rowRect(first).minY))
    }

    /// Restores a position saved with `scrollAnchor` (nil: the bottom). Applied once the rows exist; a message in
    /// older history is paged in first (up to four pages), else the transcript opens at the bottom.
    public func restore(anchor: TranscriptAnchor?) {
        pendingRestore = .some(anchor)
        restoreAttempts = 0
        if !rows.isEmpty { applyPendingRestore() }
    }

    func applyPendingRestore() {
        guard let pending = pendingRestore else { return }
        guard let anchor = pending else {
            pendingRestore = nil
            jumpToLatest()
            return
        }
        if let first = rows.firstIndex(where: { $0.messageID == anchor.messageID }) {
            pendingRestore = nil
            turnAnchor = nil
            following = false
            updateSpacer()
            setScroll(rowRect(first).minY + CGFloat(anchor.offset))
            evaluateFollowAfterRestore()
            return
        }
        guard let source, source.transcriptHasOlder, restoreAttempts < 4 else {
            pendingRestore = nil
            jumpToLatest()
            return
        }
        restoreAttempts += 1
        Task { [weak self] in
            await source.transcriptLoadOlder()
            guard let self else { return }
            self.sync()
            self.applyPendingRestore()
        }
    }

    func evaluateFollowAfterRestore() {
        if distanceFromBottom <= 2 { setFollowing(true) } else { schedulePill() }
    }

    func scheduleAnchorNotification() {
        anchorTask?.cancel()
        anchorTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.delegate?.transcriptAnchorDidChange(self)
        }
    }

    // MARK: Inner scrolling (code blocks, wide tables, tool output)

    /// Scrolls a block's inner area when the wheel is over it and it can move in that direction. Returns whether the
    /// event was consumed. A gesture that starts outside an area never gets captured by one mid-way.
    func handleScrollWheel(_ event: NSEvent) -> Bool {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let began = event.phase.contains(.began) || event.phase.contains(.mayBegin)
        let legacy = event.phase.isEmpty && event.momentumPhase.isEmpty
        let ending = event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
            || (event.momentumPhase.isEmpty && (event.phase.contains(.cancelled)))
        defer { if ending || legacy { innerScrollTarget = nil } }
        if began || legacy {
            innerScrollTarget = nil
            if let (index, local) = rowPoint(point), let layout = cellView(index)?.layout ?? layouts[rows[index].id],
                let (block, _) = layout.scrollArea(at: local)
            {
                innerScrollTarget = (rows[index].id, block)
            }
        }
        guard let target = innerScrollTarget, let index = rowIndex[target.row],
            let layout = cellView(index)?.layout ?? layouts[target.row], target.block < layout.blocks.count,
            let area = layout.blocks[target.block].scroll
        else { return false }
        let dx = -event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 8)
        let dy = -event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8)
        let horizontal = abs(dx) > abs(dy)
        var offsets = scrollOffsets[target.row] ?? [:]
        let current = offsets[target.block] ?? .zero
        var next = current
        if horizontal {
            guard area.scrollsHorizontally else { return false }
            next.x += dx
        } else {
            guard area.scrollsVertically else { return false }
            next.y += dy
            let clamped = area.clamp(next)
            // At an edge, let the transcript scroll instead.
            if clamped.y == current.y { return false }
        }
        next = area.clamp(next)
        guard next != current else { return horizontal }
        offsets[target.block] = next
        scrollOffsets[target.row] = offsets
        if let view = cellView(index) {
            view.drawState = drawState(for: index)
            view.invalidate()
        }
        return true
    }

    /// Keeps a live tool output scrolled to its end while it was at its end.
    func followLiveOutput(row index: Int, layout: RowLayout) {
        let id = rows[index].id
        guard case .work(let group) = rows[index].content, group.items.contains(where: \.outputIsLive) else { return }
        for (block, blockLayout) in layout.blocks.enumerated() {
            guard let area = blockLayout.scroll, area.scrollsVertically else { continue }
            var offsets = scrollOffsets[id] ?? [:]
            let current = offsets[block] ?? .zero
            let previousMax = (layouts[id]?.blocks[safe: block]?.scroll?.maxOffset.y) ?? 0
            if current.y >= previousMax - 1 { offsets[block] = CGPoint(x: current.x, y: area.maxOffset.y) }
            scrollOffsets[id] = offsets
        }
    }

    // MARK: Points

    /// Table point → (model index, row-local point in column coordinates).
    func rowPoint(_ point: NSPoint) -> (Int, CGPoint)? {
        let tableRow = tableView.row(at: NSPoint(x: 1, y: point.y))
        guard let index = modelIndex(tableRow: tableRow) else { return nil }
        let rect = rowRect(index)
        let columnX = TranscriptGeometry.columnX(forTableWidth: rect.width, contentWidth: contentWidth)
        return (index, CGPoint(x: point.x - rect.minX - columnX, y: point.y - rect.minY))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
