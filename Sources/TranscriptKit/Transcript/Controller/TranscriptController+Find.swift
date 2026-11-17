import AppKit
import BelloCore
import QuartzCore

extension TranscriptController {
    // MARK: Find bar

    public var isFindBarVisible: Bool { !findBar.isHidden }

    /// Shows the find bar (⌘F) and focuses its field.
    public func showFind() {
        prewarmFindIndex()
        findBar.isHidden = false
        findBar.window?.makeFirstResponder(findBar.field)
        if !findBar.field.stringValue.isEmpty { setFindQuery(findBar.field.stringValue) }
    }

    public func closeFind() {
        findTask?.cancel()
        findTask = nil
        findRefreshScheduled = false
        findBar.isHidden = true
        findMatches = []
        findCurrent = nil
        findMatchesByRow = [:]
        findQuery = ""
        refreshVisibleRows()
        tableView.window?.makeFirstResponder(tableView)
    }

    /// "Use Selection for Find" (⌘E): the selection of whatever has keyboard focus. When a text view other than the
    /// transcript is first responder (the composer, the find field's editor), its selection is used, even when empty
    /// (then nothing happens); the transcript's own selection only when it has focus or no text view does.
    public func useSelectionForFind() {
        let source = focusedTextSelection() ?? selectedText()
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500 else { NSSound.beep(); return }
        findBar.field.stringValue = text
        findBar.isHidden = false
        setFindQuery(text)
    }

    /// The selected text of the window's first responder when it is a text input other than the transcript; nil when
    /// the transcript (or no text input) has focus.
    func focusedTextSelection() -> String? {
        guard let responder = tableView.window?.firstResponder, responder !== tableView else { return nil }
        if let textView = responder as? NSTextView {
            let range = textView.selectedRange()
            let string = textView.string as NSString
            guard range.location != NSNotFound, NSMaxRange(range) <= string.length else { return "" }
            return string.substring(with: range)
        }
        if let client = responder as? any NSTextInputClient {
            let range = client.selectedRange()
            guard range.location != NSNotFound, range.length > 0 else { return "" }
            return client.attributedSubstring(forProposedRange: range, actualRange: nil)?.string ?? ""
        }
        return nil
    }

    /// Searches for `query` (debounced); the first match at or after the viewport becomes current and is revealed.
    public func setFindQuery(_ query: String, debounce: Bool = true) {
        findQuery = query
        findTask?.cancel()
        guard !query.isEmpty else {
            findMatches = []
            findCurrent = nil
            findMatchesByRow = [:]
            findBar.update(count: 0, current: nil, query: query)
            refreshVisibleRows()
            return
        }
        let generation = observationGeneration
        findTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(120)) }
            guard let self, !Task.isCancelled else { return }
            let entries = await self.findEntries()
            guard !Task.isCancelled, self.observationGeneration == generation else { return }
            let matches = await FindSearch.search(entries, query: query)
            guard !Task.isCancelled, self.findQuery == query, self.observationGeneration == generation else { return }
            self.findTask = nil
            self.applyMatches(matches, keepCurrent: false)
        }
    }

    func applyMatches(_ matches: [FindMatch], keepCurrent: Bool) {
        let previous = findCurrent.flatMap { findMatches[safe: $0] }
        findMatches = matches
        var byRow: [RowID: [(block: Int, range: Range<Int>, index: Int)]] = [:]
        for (index, match) in matches.enumerated() { byRow[match.rowID, default: []].append((match.block, match.range, index)) }
        findMatchesByRow = byRow
        if matches.isEmpty {
            findCurrent = nil
        } else if keepCurrent, let previous, let same = matches.firstIndex(of: previous) {
            findCurrent = same
        } else {
            let top = position(at: NSPoint(x: 0, y: scrollView.contentView.bounds.minY + 2))
            findCurrent = FindSearch.firstIndex(in: matches, atOrAfter: top) { self.rowIndex[$0] }
            if let current = findCurrent { reveal(matches[current]) }
        }
        findBar.update(count: matches.count, current: findCurrent, query: findQuery)
        refreshVisibleRows()
    }

    public func findNext() { moveFind(1) }
    public func findPrevious() { moveFind(-1) }

    func moveFind(_ step: Int) {
        if findQuery.isEmpty, !findBar.field.stringValue.isEmpty { setFindQuery(findBar.field.stringValue, debounce: false); return }
        guard !findMatches.isEmpty else { NSSound.beep(); return }
        let count = findMatches.count
        let current = findCurrent.map { ($0 + step + count) % count } ?? (step > 0 ? 0 : count - 1)
        findCurrent = current
        findBar.update(count: count, current: current, query: findQuery)
        reveal(findMatches[current])
        refreshVisibleRows()
    }

    /// Expands a collapsed block if the match is inside it, lays the row out exactly, centres the match and selects it.
    public func reveal(_ match: FindMatch) {
        guard let index = rowIndex[match.rowID] else { return }
        let rowBlocks = blocks(row: index)
        guard match.block < rowBlocks.count else { return }
        if case .expanded(let key) = rowBlocks[match.block].visibility,
            !RenderBlocks.isExpanded(key, content: rows[index].content, ui: ui[match.rowID] ?? RowUIState())
        {
            toggle(row: match.rowID, key: key)
        }
        // A summary hides successful tool lines: open the group too when the match is in one of them.
        if case .work(let group) = rows[index].content, group.isCollapsible, match.block > 0,
            !RenderBlocks.isExpanded(.group, content: rows[index].content, ui: ui[match.rowID] ?? RowUIState())
        {
            if case .expanded(.group) = rowBlocks[match.block].visibility { toggle(row: match.rowID, key: .group) }
            if case .toolDetail = rowBlocks[match.block].kind { toggle(row: match.rowID, key: .group) }
        }
        let layout = layouts[match.rowID].flatMap { $0.key == currentKey(row: index) ? $0 : nil } ?? {
            let layout = LayoutEngine.layoutNow(layoutInput(row: index), fonts: TranscriptFonts(theme: theme))
            store(layout)
            acceptHeight(layout, row: index)
            return layout
        }()
        flushHeights()
        turnAnchor = nil
        setFollowing(false)
        let rect = rowRect(index)
        var y = rect.minY
        if match.block < layout.blocks.count {
            let frame = layout.blockFrame(match.block)
            let block = layout.blocks[match.block]
            var caret = block.rect(forOffset: match.range.lowerBound)
            // Matches inside an inner scroll area: scroll the area so the match shows.
            if let area = block.scroll, let fragment = block.fragments.first(where: { $0.scrolls }) {
                let local = fragment.rect(forOffset: match.range.lowerBound - fragment.textStart)
                    .offsetBy(dx: fragment.origin.x, dy: fragment.origin.y)
                var offset = scrollOffsets[match.rowID]?[match.block] ?? .zero
                if local.minY - offset.y < area.viewport.minY || local.maxY - offset.y > area.viewport.maxY {
                    offset.y = local.midY - area.viewport.midY
                }
                if local.minX - offset.x < area.viewport.minX || local.maxX - offset.x > area.viewport.maxX - 20 {
                    offset.x = local.minX - area.viewport.minX - 40
                }
                offset = area.clamp(offset)
                scrollOffsets[match.rowID, default: [:]][match.block] = offset
                caret = local.offsetBy(dx: -offset.x, dy: -offset.y)
            }
            y += frame.minY + caret.midY
        }
        setScroll(y - scrollView.contentView.bounds.height / 2)
        if distanceFromBottom <= 2 { setFollowing(true) }
        updatePrefetch(force: true)
        for (visibleIndex, view) in availableCells() { configure(view, index: visibleIndex) }
    }

    /// Screen rect (scroll view coordinates) of the current match when its row is on screen (harness and tests).
    public func visibleRectOfCurrentMatch() -> CGRect? {
        guard let current = findCurrent, let match = findMatches[safe: current], let index = rowIndex[match.rowID],
            let view = cellView(index), let layout = view.layout, match.block < layout.blocks.count
        else { return nil }
        let frame = layout.blockFrame(match.block)
        let columnX = TranscriptGeometry.columnX(forTableWidth: view.bounds.width, contentWidth: contentWidth)
        let offset = scrollOffsets[match.rowID]?[match.block] ?? .zero
        let rect = layout.blocks[match.block].rect(forOffset: match.range.lowerBound, scrollOffset: offset)
            .offsetBy(dx: frame.minX + columnX, dy: frame.minY)
        return view.convert(rect, to: scrollView)
    }

    // MARK: Index

    /// The search index for every row, current with the rows' versions. Indexing (parsing and folding every row's
    /// text) runs off the main actor in chunks; the main actor only merges entries (see `updateFindIndex`).
    /// Streaming tails are indexed from their current parse.
    func findEntries() async -> [FindIndexEntry] {
        await updateFindIndex()
        return rows.map { row in
            if tails[row.id] != nil, let index = rowIndex[row.id] {
                return FindIndexEntry(rowID: row.id, version: row.version, blocks: blocks(row: index).map(\.plainText))
            }
            return findIndex[row.id] ?? FindIndexEntry(rowID: row.id, version: row.version, blocks: [])
        }
    }

    /// Starts indexing ahead of the query (the find bar opened): typing and the debounce overlap the build.
    func prewarmFindIndex() {
        guard findIndexTask == nil, rows.contains(where: { findIndex[$0.id]?.version != $0.version }) else { return }
        findIndexTask = Task { [weak self] in
            await self?.indexStaleRows()
            self?.findIndexTask = nil
        }
    }

    /// Brings the index up to date. Callers share one indexing task.
    func updateFindIndex() async {
        if let running = findIndexTask {
            await running.value
        }
        await indexStaleRows()
    }

    /// Indexes rows whose entry is missing or stale: chunks of `findIndexChunk` rows on up to four tasks at utility
    /// QoS, each merged on the main actor as it arrives (a few hundred dictionary inserts). Checks the generation
    /// so a rebind drops late results.
    func indexStaleRows() async {
        let generation = observationGeneration
        let stale = rows.filter { findIndex[$0.id]?.version != $0.version && tails[$0.id] == nil }
        guard !stale.isEmpty else { return }
        let signpost = transcriptSignposter.beginInterval("findIndex")
        defer { transcriptSignposter.endInterval("findIndex", signpost) }
        let chunks = stride(from: 0, to: stale.count, by: Self.findIndexChunk).map {
            Array(stale[$0..<min($0 + Self.findIndexChunk, stale.count)])
        }
        let cache = blockCache
        await withTaskGroup(of: [FindIndexEntry].self) { group in
            var next = 0
            for _ in 0..<min(4, chunks.count) {
                let chunk = chunks[next]
                group.addTask(priority: .utility) { await Self.indexRows(chunk, cache: cache) }
                next += 1
            }
            for await entries in group {
                guard !Task.isCancelled, observationGeneration == generation else {
                    group.cancelAll()
                    return
                }
                for entry in entries where rowIndex[entry.rowID] != nil { findIndex[entry.rowID] = entry }
                if next < chunks.count {
                    let chunk = chunks[next]
                    group.addTask(priority: .utility) { await Self.indexRows(chunk, cache: cache) }
                    next += 1
                }
            }
        }
    }

    static let findIndexChunk = 512

    /// Parsed blocks come from the parse cache when present but are not stored in it: indexing 13,000 rows would
    /// evict everything layout needs.
    @concurrent
    static func indexRows(_ rows: [TranscriptRow], cache: RenderBlockCache) async -> [FindIndexEntry] {
        var result: [FindIndexEntry] = []
        result.reserveCapacity(rows.count)
        for row in rows {
            if Task.isCancelled { break }
            let blocks = cache.cachedBlocks(for: row) ?? RenderBlocks.blocks(for: row)
            result.append(FindIndexEntry(rowID: row.id, version: row.version, blocks: blocks.map(\.plainText)))
        }
        return result
    }

    /// Rows changed: their index entries are stale; an open search refreshes.
    func invalidateFind(rows ids: [RowID]) {
        guard !ids.isEmpty else { return }
        for id in ids { findIndex[id] = nil }
        // Throttled, not debounced: while a reply streams, rows change every commit; restarting the search each time
        // would starve it. A running search or a scheduled refresh picks the change up.
        guard !findQuery.isEmpty, isFindBarVisible, !findRefreshScheduled, findTask == nil || findTask?.isCancelled == true else { return }
        let query = findQuery
        findRefreshScheduled = true
        findTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.findRefreshScheduled = false
            guard !Task.isCancelled else { return }
            let entries = await self.findEntries()
            let matches = await FindSearch.search(entries, query: query)
            guard !Task.isCancelled, self.findQuery == query else { return }
            self.findTask = nil
            self.applyMatches(matches, keepCurrent: true)
        }
    }

    // MARK: Images

    func requestImages(in layout: RowLayout, row id: RowID) {
        for block in layout.blocks where !block.isHidden {
            for image in block.images {
                imageRows[image.source, default: []].insert(id)
                guard images[image.source] == nil, !imageRequests.contains(image.source) else { continue }
                imageRequests.insert(image.source)
                let source = image.source
                let loader = imageLoader
                imageTasks[source] = Task { [weak self] in
                    let loaded = await loader.load(source)
                    guard !Task.isCancelled, let self else { return }
                    self.imageTasks[source] = nil
                    self.imageArrived(source, loaded)
                }
            }
        }
    }

    func imageArrived(_ source: String, _ loaded: LoadedImage?) {
        guard let loaded else { return }  // stays a placeholder (unreachable, unsupported or too large)
        tick += 1
        images[source] = loaded.image
        imageTick[source] = tick
        imageBytes += loaded.image.bytesPerRow * loaded.image.height
        evictImages()
        let knew = imageSizes[source] != nil
        imageSizes[source] = loaded.pixelSize
        for id in imageRows[source] ?? [] {
            guard let index = rowIndex[id] else { continue }
            if knew {
                if let view = cellView(index) { view.invalidate() }
            } else {
                // The size is new: the row re-lays out with the reserved size (anchored if above the viewport).
                ui[id, default: RowUIState()].version += 1
                requestLayout(row: index, priority: true)
            }
        }
    }

    func image(_ source: String) -> CGImage? {
        guard let image = images[source] else { return nil }
        tick += 1
        imageTick[source] = tick
        return image
    }

    /// Least recently drawn images go first; images of rows AppKit is displaying stay (they are re-requested when a
    /// row that lost its image is configured again).
    func evictImages() {
        guard imageBytes > imageByteLimit else { return }
        let visible = Set(availableCells().flatMap { cell in cell.view.layout?.blocks.flatMap { $0.images.map(\.source) } ?? [] })
        for (source, _) in imageTick.sorted(by: { $0.value < $1.value }) where !visible.contains(source) {
            guard imageBytes > imageByteLimit else { break }
            dropImage(source)
        }
    }

    func dropImage(_ source: String) {
        if let image = images.removeValue(forKey: source) { imageBytes -= image.bytesPerRow * image.height }
        imageTick[source] = nil
        imageRequests.remove(source)
    }

    /// Harness: whether an image source has loaded.
    public func isImageLoaded(_ source: String) -> Bool { images[source] != nil }

    // MARK: Accessibility

    func announce(_ text: String) {
        let trimmed = text.count > 600 ? String(text.prefix(600)) + "…" : text
        NSAccessibility.post(
            element: tableView, notification: .announcementRequested,
            userInfo: [.announcement: "Reply finished. " + trimmed, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func focusAccessibility(row index: Int) {
        guard let view = cellView(index) else { return }
        NSAccessibility.post(element: view, notification: .focusedUIElementChanged)
    }

    /// Accessibility label for a row: who or what it is.
    func accessibilityLabel(_ row: TranscriptRow) -> String {
        let time = Self.timeFormatter.string(from: Date(timeIntervalSince1970: Double(row.created.milliseconds) / 1000))
        switch row.content {
        case .user(let user): return user.isSending ? "You, sending" : "You, \(time)"
        case .markdown(_, let streaming): return streaming ? "Assistant, writing" : "Assistant"
        case .reasoning(let reasoning): return reasoning.isStreaming ? "Reasoning, in progress" : "Reasoning, collapsed by default"
        case .work(let group):
            let failed = group.items.filter { if case .failed = $0.status { true } else { false } }.count
            let running = group.items.filter(\.status.isActive).count
            var label = group.items.count == 1 ? "Tool call" : "\(group.items.count) tool calls"
            if running > 0 { label += ", \(running) running" }
            if failed > 0 { label += ", \(failed) failed" }
            return label
        case .todo: return "To-do list"
        case .file(let file): return file.isImage ? "Image \(file.name)" : "File \(file.name)"
        case .subagent(let card): return "Sub-agent, \(card.status.label)"
        case .error(let error): return "Error: \(error.title)"
        case .lifecycle(let event): return event.text
        case .working: return "Agent working"
        case .unknown(let type): return "Unsupported content \(type)"
        }
    }

    /// The text VoiceOver reads for a row: its visible blocks.
    func accessibilityValue(_ index: Int) -> String {
        let rowBlocks = blocks(row: index)
        let visible = visibility(row: index, blocks: rowBlocks)
        return zip(rowBlocks, visible).filter(\.1).map(\.0.plainText).joined(separator: "\n")
    }

    func accessibilityActions(_ index: Int, layout: RowLayout?) -> [NSAccessibilityCustomAction] {
        let id = rows[index].id
        var actions: [NSAccessibilityCustomAction] = []
        actions.append(NSAccessibilityCustomAction(name: "Copy message") { [weak self] in
            guard let self, let index = self.rowIndex[id] else { return false }
            let range = self.messageRows(index)
            self.write(plain: self.messageText(range, markdown: false), markdown: self.messageText(range, markdown: true))
            return true
        })
        guard let layout else { return actions }
        for (block, blockLayout) in layout.blocks.enumerated() where !blockLayout.isHidden {
            for hotspot in blockLayout.hotspots {
                let action = hotspot.action
                actions.append(NSAccessibilityCustomAction(name: hotspot.label) { [weak self] in
                    self?.perform(action, row: id, block: block)
                    return true
                })
            }
            for fragment in blockLayout.fragments {
                for link in fragment.links.prefix(5) {
                    let url = link.url
                    actions.append(NSAccessibilityCustomAction(name: "Open link \(url)") { [weak self] in
                        self?.open(link: url)
                        return true
                    })
                }
            }
        }
        return actions
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

extension TranscriptController {
    /// The find bar's field (harness and tests).
    public var findBarField: NSSearchField { findBar.field }
}
