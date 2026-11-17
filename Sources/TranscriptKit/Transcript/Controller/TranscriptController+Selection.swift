import AppKit
import BelloCore
import QuartzCore

extension NSPasteboard.PasteboardType {
    /// Markdown source alongside plain text when copying from the transcript.
    public static let markdown = NSPasteboard.PasteboardType("net.daringfireball.markdown")
}

extension TranscriptController {
    // MARK: Blocks

    /// The blocks of a row as copy, find and selection see them (streaming rows use their live parse).
    func blocks(row index: Int) -> [RenderBlock] {
        let row = rows[index]
        if let tail = tails[row.id] { return tail.stream.blocks.map { RenderBlock(.markdown($0, tone: .normal)) } }
        if blockCache.cachedBlocks(for: row) == nil { metrics.mainThreadParses += 1 }
        return blockCache.blocks(for: row)
    }

    func visibility(row index: Int, blocks: [RenderBlock]) -> [Bool] {
        let row = rows[index]
        let state = ui[row.id] ?? RowUIState()
        return blocks.map { RenderBlocks.isVisible($0, content: row.content, ui: state) }
    }

    func copyRow(_ index: Int) -> CopyRow {
        let rowBlocks = blocks(row: index)
        var source: String?
        if case .markdown(let text, _) = rows[index].content { source = text }
        return CopyRow(id: rows[index].id, blocks: rowBlocks, visible: visibility(row: index, blocks: rowBlocks), markdownSource: source)
    }

    // MARK: Selection state

    public var hasSelection: Bool { !(selection?.isEmpty ?? true) }

    func ordered() -> (start: TranscriptPosition, end: TranscriptPosition)? {
        guard let selection, !selection.isEmpty else { return nil }
        return selection.ordered { self.rowIndex[$0] }
    }

    func setSelection(_ new: TranscriptSelection?) {
        guard new != selection else { return }
        selection = new
        refreshVisibleRows()
        if let new, !new.isEmpty { NSAccessibility.post(element: tableView, notification: .selectedTextChanged) }
    }

    public func clearSelection() { setSelection(nil) }

    public func selectAll() {
        guard let lastIndex = rows.indices.last, let first = rows.first else { return }
        let lastBlocks = blocks(row: lastIndex)
        let lastBlock = max(0, lastBlocks.count - 1)
        let length = lastBlocks.isEmpty ? 0 : (lastBlocks[lastBlock].plainText as NSString).length
        setSelection(
            TranscriptSelection(
                anchor: TranscriptPosition(rowID: first.id, block: 0, offset: 0),
                focus: TranscriptPosition(rowID: rows[lastIndex].id, block: lastBlock, offset: length)))
    }

    /// Programmatic selection (harness, tests and find).
    public func select(from start: TranscriptPosition, to end: TranscriptPosition) {
        setSelection(TranscriptSelection(anchor: start, focus: end))
    }

    /// Rows the selection spans.
    public var selectionRowSpan: Int? {
        guard let (start, end) = ordered(), let a = rowIndex[start.rowID], let b = rowIndex[end.rowID] else { return nil }
        return b - a + 1
    }

    // MARK: Hit testing

    /// Table point → transcript position (synchronous layout fallback for rows never drawn).
    func position(at point: NSPoint) -> TranscriptPosition? {
        guard !rows.isEmpty else { return nil }
        let tableRow = tableView.row(at: NSPoint(x: 1, y: point.y))
        if tableRow <= 0 && point.y < rowRect(0).minY + 1 {
            return TranscriptPosition(rowID: rows[0].id, block: 0, offset: 0)
        }
        guard let index = modelIndex(tableRow: tableRow) ?? (tableRow == 0 ? 0 : nil) else { return endPosition() }
        let rect = rowRect(index)
        let columnX = TranscriptGeometry.columnX(forTableWidth: rect.width, contentWidth: contentWidth)
        guard let layout = cellView(index)?.layout ?? displayLayout(row: index) else { return nil }
        let local = CGPoint(x: point.x - rect.minX - columnX, y: point.y - rect.minY)
        let hit = layout.hitTest(local, scrollOffsets: scrollOffsets[rows[index].id] ?? [:])
        return TranscriptPosition(rowID: rows[index].id, block: hit.block, offset: hit.offset)
    }

    func endPosition() -> TranscriptPosition? {
        guard let index = rows.indices.last else { return nil }
        let rowBlocks = blocks(row: index)
        let visible = visibility(row: index, blocks: rowBlocks)
        let last = visible.lastIndex(of: true) ?? max(0, rowBlocks.count - 1)
        let length = rowBlocks.indices.contains(last) ? (rowBlocks[last].plainText as NSString).length : 0
        return TranscriptPosition(rowID: rows[index].id, block: last, offset: length)
    }

    // MARK: Mouse

    func mouseDown(_ event: NSEvent) {
        tableView.window?.makeFirstResponder(tableView)
        let point = tableView.convert(event.locationInWindow, from: nil)
        dragStartWindowPoint = event.locationInWindow
        lastDragWindowPoint = event.locationInWindow
        didDrag = false
        clickCandidate = nil
        linkCandidate = nil
        if let (index, local) = rowPoint(point), let layout = cellView(index)?.layout {
            if let (block, hotspot) = layout.hotspot(at: local) {
                clickCandidate = (rows[index].id, block, hotspot.action)
            } else if let link = layout.link(at: local, scrollOffsets: scrollOffsets[rows[index].id] ?? [:]) {
                linkCandidate = link.url
            }
        }
        guard let position = position(at: point) else { return }
        if event.modifierFlags.contains(.shift), let selection {
            setSelection(TranscriptSelection(anchor: selection.anchor, focus: position))
            selectionGranularity = .character
        } else if event.clickCount == 2 {
            selectionGranularity = .word
            setSelection(expand(position, to: .word))
        } else if event.clickCount >= 3 {
            selectionGranularity = .paragraph
            setSelection(expand(position, to: .paragraph))
        } else {
            selectionGranularity = .character
            setSelection(TranscriptSelection(anchor: position, focus: position))
        }
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
        defer {
            clickCandidate = nil
            linkCandidate = nil
        }
        guard !didDrag, event.clickCount <= 1 else { return }
        if let candidate = clickCandidate {
            setSelection(nil)
            perform(candidate.action, row: candidate.row, block: candidate.block)
        } else if let link = linkCandidate, !hasSelection {
            open(link: link)
        }
    }

    /// Expands a position to the word or paragraph around it.
    func expand(_ position: TranscriptPosition, to granularity: SelectionGranularity) -> TranscriptSelection {
        guard let index = rowIndex[position.rowID] else { return TranscriptSelection(anchor: position, focus: position) }
        let rowBlocks = blocks(row: index)
        guard position.block < rowBlocks.count else { return TranscriptSelection(anchor: position, focus: position) }
        let text = rowBlocks[position.block].plainText
        let range =
            granularity == .word
            ? SelectionText.wordRange(in: text, at: position.offset) : SelectionText.paragraphRange(in: text, at: position.offset)
        var start = position
        start.offset = range.lowerBound
        var end = position
        end.offset = range.upperBound
        return TranscriptSelection(anchor: start, focus: end)
    }

    func updateDragFocus() {
        guard let selection, dragStartWindowPoint != nil, didDrag else { return }
        let point = tableView.convert(lastDragWindowPoint, from: nil)
        guard var focus = position(at: point) else { return }
        var anchor = selection.anchor
        if selectionGranularity != .character {
            // Word/paragraph drags extend by whole units.
            let unit = expand(focus, to: selectionGranularity)
            let original = expand(anchor, to: selectionGranularity)
            let forward = TranscriptSelection(anchor: anchor, focus: focus).ordered { self.rowIndex[$0] }?.start == anchor
            focus = forward ? unit.focus : unit.anchor
            anchor = forward ? original.anchor : original.focus
        }
        guard focus != selection.focus || anchor != selection.anchor else { return }
        setSelection(TranscriptSelection(anchor: anchor, focus: focus))
    }

    func autoscrollSpeed() -> CGFloat {
        let point = scrollView.contentView.convert(lastDragWindowPoint, from: nil)
        let visible = scrollView.contentView.bounds
        if point.y < visible.minY { return -(visible.minY - point.y) }
        if point.y > visible.maxY { return point.y - visible.maxY }
        return 0
    }

    func updateAutoscroll() {
        if autoscrollSpeed() == 0 { stopAutoscroll(); return }
        guard autoscrollTimer == nil else { return }
        lastAutoscrollTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollStep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoscrollTimer = timer
    }

    func autoscrollStep() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - lastAutoscrollTime)
        lastAutoscrollTime = now
        let distance = autoscrollSpeed()
        guard distance != 0 else { stopAutoscroll(); return }
        // 300 pt/s plus 25 pt/s per point outside the view, capped.
        let speed = min(6_000, 300 + abs(distance) * 25) * (distance < 0 ? -1 : 1)
        userScroll(by: speed * dt)
        updateDragFocus()
    }

    func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    public var isAutoscrolling: Bool { autoscrollTimer != nil }

    // MARK: Hover

    func mouseMoved(_ event: NSEvent) {
        let point = tableView.convert(event.locationInWindow, from: nil)
        var newHover: (row: RowID, block: Int, action: HotspotAction)?
        var link: String?
        if let (index, local) = rowPoint(point), let layout = cellView(index)?.layout {
            if let (block, hotspot) = layout.hotspot(at: local) {
                newHover = (rows[index].id, block, hotspot.action)
            } else if let found = layout.link(at: local, scrollOffsets: scrollOffsets[rows[index].id] ?? [:]) {
                link = found.url
            }
            cellView(index)?.setHovered(true)
        }
        for (index, view) in visibleCells() where view.isHovered {
            if let (hovered, _) = rowPoint(point), hovered == index { continue }
            view.setHovered(false)
        }
        let changed = newHover?.row != hover?.row || newHover?.block != hover?.block || newHover?.action != hover?.action
        let oldRow = hover?.row
        hover = newHover
        if changed {
            for id in [oldRow, newHover?.row].compactMap({ $0 }) {
                if let index = rowIndex[id], let view = cellView(index) {
                    view.drawState = drawState(for: index)
                    view.invalidate()
                }
            }
        }
        if link != hoverLink {
            hoverLink = link
            tableView.toolTip = link
        }
        (newHover != nil || link != nil ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    func mouseExited() {
        for (_, view) in visibleCells() where view.isHovered { view.setHovered(false) }
        if let id = hover?.row, let index = rowIndex[id], let view = cellView(index) {
            hover = nil
            view.drawState = drawState(for: index)
            view.invalidate()
        }
        hover = nil
        hoverLink = nil
        tableView.toolTip = nil
    }

    // MARK: Actions on blocks

    func perform(_ action: HotspotAction, row id: RowID, block: Int) {
        switch action {
        case .toggle(let key): toggle(row: id, key: key)
        case .copyCode: copyCode(row: id, block: block)
        case .openChild(let session): delegate?.transcript(self, openChildThread: session)
        case .openFile(let uri):
            if let url = URL(string: uri), url.scheme != nil { openURL(url) } else { openURL(URL(fileURLWithPath: uri)) }
        }
    }

    func open(link: String) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "file"].contains(scheme)
        else { return }
        openURL(url)
    }

    /// Expands or collapses part of a row. Applied synchronously so the click responds in the same frame; the
    /// viewport stays anchored.
    public func toggle(row id: RowID, key: ExpansionKey) {
        guard let index = rowIndex[id] else { return }
        var state = ui[id] ?? RowUIState()
        let expanded = RenderBlocks.isExpanded(key, content: rows[index].content, ui: state)
        state.overrides[key] = !expanded
        state.version += 1
        ui[id] = state
        if tails[id] != nil {
            relayoutTails()
            return
        }
        let layout = LayoutEngine.layoutNow(layoutInput(row: index), fonts: TranscriptFonts(theme: theme))
        store(layout)
        acceptHeight(layout, row: index)
        flushHeights()
        if let view = cellView(index) { configure(view, index: index) }
        NSAccessibility.post(element: cellView(index) ?? tableView, notification: .layoutChanged)
    }

    public func isExpanded(row id: RowID, key: ExpansionKey) -> Bool {
        guard let index = rowIndex[id] else { return false }
        return RenderBlocks.isExpanded(key, content: rows[index].content, ui: ui[id] ?? RowUIState())
    }

    // MARK: Copy

    public func selectedText() -> String {
        guard let (start, end) = ordered(), let a = rowIndex[start.rowID], let b = rowIndex[end.rowID] else { return "" }
        return SelectionText.plain((a...b).map(copyRow), start: start, end: end)
    }

    public func selectedMarkdown() -> String {
        guard let (start, end) = ordered(), let a = rowIndex[start.rowID], let b = rowIndex[end.rowID] else { return "" }
        return SelectionText.markdown((a...b).map(copyRow), start: start, end: end)
    }

    func write(plain: String, markdown: String?) {
        guard !plain.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.declareTypes(markdown == nil ? [.string] : [.string, .markdown], owner: nil)
        pasteboard.setString(plain, forType: .string)
        if let markdown { pasteboard.setString(markdown, forType: .markdown) }
    }

    public func copySelection() {
        write(plain: selectedText(), markdown: selectedMarkdown())
    }

    /// The row a command without a selection acts on: the context-menu row, the selection's focus, else the last
    /// assistant row on screen.
    var commandRow: Int? {
        if let id = contextRow, let index = rowIndex[id] { return index }
        if let focus = selection?.focus, let index = rowIndex[focus.rowID] { return index }
        let visible = visibleCells().map(\.index)
        return visible.last { rows[$0].role == .assistant } ?? visible.last
    }

    /// Rows of the message at `index`: a user prompt, or the whole assistant reply of its turn.
    func messageRows(_ index: Int) -> ClosedRange<Int> {
        let row = rows[index]
        if row.role == .user { return index...index }
        var lo = index
        while lo > 0, rows[lo - 1].role != .user, rows[lo - 1].turnID == row.turnID { lo -= 1 }
        var hi = index
        while hi + 1 < rows.count, rows[hi + 1].role != .user, rows[hi + 1].turnID == row.turnID { hi += 1 }
        return lo...hi
    }

    func messageText(_ range: ClosedRange<Int>, markdown: Bool) -> String {
        let copyRows = range.map(copyRow).filter { row in row.blocks.contains { !$0.plainText.isEmpty } }
        guard let first = copyRows.first, let last = copyRows.last else { return "" }
        let lastVisible = last.visible.lastIndex(of: true) ?? 0
        let start = TranscriptPosition(rowID: first.id, block: 0, offset: 0)
        let end = TranscriptPosition(rowID: last.id, block: lastVisible, offset: Int.max / 2)
        return markdown ? SelectionText.markdown(copyRows, start: start, end: end) : SelectionText.plain(copyRows, start: start, end: end)
    }

    /// Copies the message (or reply) under the pointer or the selection.
    public func copyMessage() {
        guard let index = commandRow else { return }
        let range = messageRows(index)
        write(plain: messageText(range, markdown: false), markdown: messageText(range, markdown: true))
    }

    /// Copies the selection, or else the message, as Markdown source.
    public func copyAsMarkdown() {
        if hasSelection {
            let markdown = selectedMarkdown()
            write(plain: markdown, markdown: markdown)
            return
        }
        guard let index = commandRow else { return }
        let markdown = messageText(messageRows(index), markdown: true)
        write(plain: markdown, markdown: markdown)
    }

    /// The code block under the pointer, or holding the selection.
    var commandCodeBlock: (row: RowID, block: Int)? {
        if let target = contextCode { return target }
        if let focus = selection?.focus, let index = rowIndex[focus.rowID], case .markdown(let block, _)? = blocks(row: index)[safe: focus.block]?.kind,
            case .code = block.kind
        {
            return (focus.rowID, focus.block)
        }
        return nil
    }

    public func copyCode() {
        guard let target = commandCodeBlock else { return }
        copyCode(row: target.row, block: target.block)
    }

    func copyCode(row id: RowID, block: Int) {
        guard let index = rowIndex[id], let renderBlock = blocks(row: index)[safe: block] else { return }
        write(plain: renderBlock.plainText, markdown: nil)
        copiedBlock = (id, block)
        if let view = cellView(index) { view.drawState = drawState(for: index); view.invalidate() }
        NSAccessibility.post(
            element: tableView, notification: .announcementRequested,
            userInfo: [.announcement: "Copied code", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            self.copiedBlock = nil
            if let index = self.rowIndex[id], let view = self.cellView(index) {
                view.drawState = self.drawState(for: index)
                view.invalidate()
            }
        }
    }

    // MARK: Keyboard

    /// Handles navigation and selection keys. Returns whether the key was used.
    func keyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        guard let special = event.specialKey else {
            if event.keyCode == 49, !command {  // space pages
                scrollPage(shift ? -1 : 1)
                return true
            }
            return false
        }
        switch special {
        case .leftArrow where shift, .rightArrow where shift:
            extendSelection(horizontal: special == .rightArrow, word: option)
        case .upArrow where shift && command, .downArrow where shift && command:
            extendSelectionToEnd(forward: special == .downArrow)
        case .upArrow where shift, .downArrow where shift:
            extendSelection(vertical: special == .downArrow)
        case .upArrow where command, .home:
            setFollowing(false)
            setScroll(0)
        case .downArrow where command, .end:
            jumpToLatest()
        case .upArrow:
            userScroll(by: -40)
        case .downArrow:
            userScroll(by: 40)
        case .pageUp:
            scrollPage(-1)
        case .pageDown:
            scrollPage(1)
        default:
            return false
        }
        return true
    }

    func scrollPage(_ direction: CGFloat) {
        userScroll(by: direction * max(40, scrollView.contentView.bounds.height - 48))
    }

    /// The selection focus, or a starting point at the top of the viewport when nothing is selected.
    func caret() -> TranscriptPosition? {
        if let focus = selection?.focus { return focus }
        let visible = scrollView.contentView.bounds
        return position(at: NSPoint(x: 0, y: visible.minY + 4))
    }

    func extendSelection(horizontal forward: Bool, word: Bool) {
        guard let focus = caret() else { return }
        let anchor = selection?.anchor ?? focus
        guard let next = step(focus, forward: forward, word: word) else { return }
        setSelection(TranscriptSelection(anchor: anchor, focus: next))
        reveal(position: next)
    }

    /// One character (or word) forward/back, crossing into the next or previous visible block and row.
    func step(_ position: TranscriptPosition, forward: Bool, word: Bool) -> TranscriptPosition? {
        guard let index = rowIndex[position.rowID] else { return nil }
        let rowBlocks = blocks(row: index)
        guard position.block < rowBlocks.count else { return nil }
        let text = rowBlocks[position.block].plainText
        let length = (text as NSString).length
        if forward, position.offset < length || !word && position.offset < length {
            var next = position
            if word {
                var offset = position.offset
                let ns = text as NSString
                while offset < length, let scalar = Unicode.Scalar(ns.character(at: offset)), !CharacterSet.alphanumerics.contains(scalar) { offset += 1 }
                next.offset = SelectionText.wordRange(in: text, at: offset).upperBound
                if next.offset <= position.offset { next.offset = min(length, position.offset + 1) }
            } else {
                next.offset = SelectionText.step(in: text, from: position.offset, forward: true)
            }
            return next
        }
        if !forward, position.offset > 0 {
            var next = position
            if word {
                var offset = position.offset
                let ns = text as NSString
                while offset > 0, let scalar = Unicode.Scalar(ns.character(at: offset - 1)), !CharacterSet.alphanumerics.contains(scalar) { offset -= 1 }
                next.offset = offset > 0 ? SelectionText.wordRange(in: text, at: offset - 1).lowerBound : 0
            } else {
                next.offset = SelectionText.step(in: text, from: position.offset, forward: false)
            }
            return next
        }
        // Cross a block or row boundary.
        return neighbour(of: position, forward: forward)
    }

    func neighbour(of position: TranscriptPosition, forward: Bool) -> TranscriptPosition? {
        guard var index = rowIndex[position.rowID] else { return nil }
        var block = position.block
        while true {
            let rowBlocks = blocks(row: index)
            let visible = visibility(row: index, blocks: rowBlocks)
            var candidate = forward ? block + 1 : block - 1
            while candidate >= 0, candidate < rowBlocks.count, !visible[candidate] { candidate += forward ? 1 : -1 }
            if candidate >= 0, candidate < rowBlocks.count {
                let length = (rowBlocks[candidate].plainText as NSString).length
                return TranscriptPosition(rowID: rows[index].id, block: candidate, offset: forward ? 0 : length)
            }
            index += forward ? 1 : -1
            guard index >= 0, index < rows.count else { return nil }
            block = forward ? -1 : blocks(row: index).count
        }
    }

    func extendSelection(vertical down: Bool) {
        guard let focus = caret(), let index = rowIndex[focus.rowID] else { return }
        let anchor = selection?.anchor ?? focus
        guard let layout = cellView(index)?.layout ?? displayLayout(row: index), focus.block < layout.blocks.count else { return }
        let frame = layout.blockFrame(focus.block)
        let caretRect = layout.blocks[focus.block].rect(forOffset: focus.offset, scrollOffset: scrollOffsets[focus.rowID]?[focus.block] ?? .zero)
            .offsetBy(dx: frame.minX, dy: frame.minY)
        let rect = rowRect(index)
        let columnX = TranscriptGeometry.columnX(forTableWidth: rect.width, contentWidth: contentWidth)
        let y = rect.minY + (down ? caretRect.maxY + 2 : caretRect.minY - 2)
        let point = NSPoint(x: rect.minX + columnX + caretRect.minX, y: y)
        guard let next = position(at: point), next != focus else {
            if let neighbour = neighbour(of: focus, forward: down) {
                setSelection(TranscriptSelection(anchor: anchor, focus: neighbour))
            }
            return
        }
        setSelection(TranscriptSelection(anchor: anchor, focus: next))
        reveal(position: next)
    }

    func extendSelectionToEnd(forward: Bool) {
        guard let focus = caret(), let first = rows.first else { return }
        let anchor = selection?.anchor ?? focus
        let target = forward ? endPosition() : TranscriptPosition(rowID: first.id, block: 0, offset: 0)
        guard let target else { return }
        setSelection(TranscriptSelection(anchor: anchor, focus: target))
        reveal(position: target)
    }

    /// Scrolls just enough to show a position.
    func reveal(position: TranscriptPosition) {
        guard let index = rowIndex[position.rowID] else { return }
        let rect = rowRect(index)
        var y = rect.minY
        if let layout = layouts[position.rowID], position.block < layout.blocks.count {
            let frame = layout.blockFrame(position.block)
            y += frame.minY + layout.blocks[position.block].rect(forOffset: position.offset).minY
        }
        let visible = scrollView.contentView.bounds
        if y < visible.minY + 8 {
            setFollowing(false)
            setScroll(y - 24)
        } else if y > visible.maxY - 24 {
            setScroll(y - visible.height + 48)
            evaluateFollow()
        }
    }

    // MARK: Turn navigation

    /// Scrolls the previous (or next) user prompt to the top of the viewport.
    public func goToTurn(previous: Bool) {
        let top = scrollView.contentView.bounds.minY
        let users = rows.indices.filter { rows[$0].role == .user }
        let target: Int? =
            previous
            ? users.last { rowRect($0).minY + topPadding($0) < top - 4 }
            : users.first { rowRect($0).minY + topPadding($0) > top + 4 }
        guard let target else {
            if !previous { jumpToLatest() }
            return
        }
        turnAnchor = nil
        setFollowing(false)
        setScroll(rowRect(target).minY + topPadding(target) - TranscriptMetrics.turnTopInset)
        if distanceFromBottom <= 2 { setFollowing(true) }
        focusAccessibility(row: target)
    }

    /// Scrolls to the last failure (failed tool, error banner, failed sub-agent).
    public func goToLastFailure() {
        guard let index = rows.indices.last(where: { rows[$0].isFailure }) else { NSSound.beep(); return }
        turnAnchor = nil
        setFollowing(false)
        let rect = rowRect(index)
        setScroll(rect.midY - scrollView.contentView.bounds.height / 2)
        if distanceFromBottom <= 2 { setFollowing(true) }
        focusAccessibility(row: index)
    }

    public var hasFailure: Bool { rows.contains { $0.isFailure } }

    // MARK: Context menu

    func contextMenu(for event: NSEvent) -> NSMenu {
        let point = tableView.convert(event.locationInWindow, from: nil)
        contextRow = nil
        contextCode = nil
        contextLink = nil
        contextWord = nil
        if let (index, local) = rowPoint(point) {
            contextRow = rows[index].id
            if let layout = cellView(index)?.layout {
                if let link = layout.link(at: local, scrollOffsets: scrollOffsets[rows[index].id] ?? [:]) { contextLink = link.url }
                let hit = layout.hitTest(local, scrollOffsets: scrollOffsets[rows[index].id] ?? [:])
                let rowBlocks = blocks(row: index)
                if let block = rowBlocks[safe: hit.block] {
                    if case .markdown(let markdown, _) = block.kind, case .code = markdown.kind { contextCode = (rows[index].id, hit.block) }
                    let range = SelectionText.wordRange(in: block.plainText, at: hit.offset)
                    if !range.isEmpty {
                        contextWord = ((block.plainText as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count)), point)
                    }
                }
            }
        }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        if hasSelection { add("Copy", #selector(TranscriptTableView.copy(_:))) }
        add("Copy Message", #selector(TranscriptTableView.copyTranscriptMessage(_:)))
        add("Copy as Markdown", #selector(TranscriptTableView.copyTranscriptMarkdown(_:)))
        if contextCode != nil { add("Copy Code", #selector(TranscriptTableView.copyTranscriptCode(_:))) }
        if contextLink != nil {
            menu.addItem(.separator())
            add("Open Link", #selector(TranscriptTableView.openTranscriptLink(_:)))
            add("Copy Link", #selector(TranscriptTableView.copyTranscriptLink(_:)))
        }
        if let word = lookUpTerm {
            menu.addItem(.separator())
            add("Look Up “\(word.prefix(40))”", #selector(TranscriptTableView.lookUpTranscriptWord(_:)))
        }
        menu.addItem(.separator())
        add("Select All", #selector(NSResponder.selectAll(_:)))
        return menu
    }

    var lookUpTerm: String? {
        if hasSelection {
            let text = selectedText()
            return text.count <= 80 ? text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        return contextWord?.text
    }

    func lookUp() {
        guard let term = lookUpTerm, !term.isEmpty else { return }
        let point = contextWord?.point ?? NSPoint(x: tableView.visibleRect.midX, y: tableView.visibleRect.midY)
        let attributed = NSAttributedString(string: term, attributes: [.font: NSFont.systemFont(ofSize: theme.bodySize)])
        tableView.showDefinition(for: attributed, at: point)
    }
}
