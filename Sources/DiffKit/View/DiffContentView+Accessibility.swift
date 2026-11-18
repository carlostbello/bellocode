import AppKit

/// A change made through an accessibility action, announced once when the rebuilt rows arrive.
enum DiffAccessibilityChange: Equatable {
    case toggledFile(Int)
    case expandedGap(file: Int, hunk: Int, all: Bool)
}

/// One diff row as a virtual accessibility element (review M6). Nothing is drawn or laid out for it: its frame is
/// computed from the parent's row geometry when asked, so any row of the document can be read, focused (which scrolls
/// it into view) and acted on, whether or not it is on screen.
///
/// Threading: NSAccessibilityElement's methods are nonisolated, and AppKit calls them on the main thread; each override
/// hops into the view's main-actor code with `MainActor.assumeIsolated`. Elements are made on the main actor and never
/// leave it.
final class DiffRowAccessibilityElement: NSAccessibilityElement {
    nonisolated(unsafe) weak var view: DiffContentView?
    let row: Int
    let generation: Int

    @MainActor init(view: DiffContentView, row: Int) {
        self.view = view
        self.row = row
        generation = view.generation
        super.init()
    }

    override func accessibilityParent() -> Any? { view }

    override func accessibilityFrame() -> NSRect {
        let (view, row, generation) = (view, row, generation)
        return MainActor.assumeIsolated { view?.accessibilityScreenFrame(row: row, generation: generation) ?? .zero }
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        guard focused else { return }
        let (view, row, generation) = (view, row, generation)
        MainActor.assumeIsolated { view?.scrollAccessibilityRowToVisible(row, generation: generation) }
    }

    override func accessibilityPerformPress() -> Bool {
        let (view, row, generation) = (view, row, generation)
        return MainActor.assumeIsolated { view?.performAccessibilityPress(row: row, generation: generation) ?? false }
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let (view, row, generation) = (view, row, generation)
        nonisolated(unsafe) var actions: [NSAccessibilityCustomAction]?
        MainActor.assumeIsolated { actions = view?.accessibilityActions(row: row, generation: generation) }
        return actions
    }
}

extension DiffContentView {
    /// More elements than this are never kept; the ranged children API serves any row on demand.
    static let accessibilityElementLimit = 4_096

    func accessibilityElement(row: Int) -> DiffRowAccessibilityElement {
        accessibilityRowElements.value(for: row) {
            let element = DiffRowAccessibilityElement(view: self, row: row)
            let item = rows.rows[row]
            element.setAccessibilityRole(Self.accessibilityRole(item))
            element.setAccessibilityLabel(Self.accessibilityText(item, files: files, layout: layoutMode, annotations: rows.annotations))
            if case .annotation = item.kind { element.setAccessibilityRoleDescription("review thread") }
            element.setAccessibilityIndex(row)
            if case .fileHeader = item.kind { element.setAccessibilityRoleDescription("file header") }
            if case .hunkHeader = item.kind { element.setAccessibilityRoleDescription("change header") }
            return element
        }
    }

    static func accessibilityRole(_ row: DiffRow) -> NSAccessibility.Role {
        switch row.kind {
        case .fileHeader: .button
        case .gap(_, let expandable): expandable ? .button : .staticText
        case .hunkHeader, .line, .notice: .staticText
        case .annotation: .button
        }
    }

    // MARK: Children for the whole document

    /// Small documents list every row; large ones list the rows around the viewport here, and assistive apps reach the
    /// rest through the ranged children API below (as with a table's rows), so elements are made only when asked for.
    override func accessibilityChildren() -> [Any]? {
        let count = rows.rows.count
        guard count > 0 else { return [] }
        if count <= Self.accessibilityElementLimit / 2 { return (0..<count).map(accessibilityElement(row:)) }
        let center = rowIndex(atY: visibleRect.midY) ?? 0
        let half = Self.accessibilityElementLimit / 4
        let low = max(0, center - half)
        let high = min(count, low + 2 * half)
        return (low..<high).map(accessibilityElement(row:))
    }

    override func accessibilityVisibleChildren() -> [Any]? {
        guard let first = rowIndex(atY: visibleRect.minY), let last = rowIndex(atY: visibleRect.maxY) else { return [] }
        return (first...last).map(accessibilityElement(row:))
    }

    // The ranged API is declared nonisolated by NSObject; AppKit calls it on the main thread.
    override func accessibilityArrayAttributeCount(_ attribute: NSAccessibility.Attribute) -> Int {
        guard attribute == .children else { return super.accessibilityArrayAttributeCount(attribute) }
        return MainActor.assumeIsolated { rows.rows.count }
    }

    override func accessibilityArrayAttributeValues(_ attribute: NSAccessibility.Attribute, index: Int, maxCount: Int) -> [Any] {
        guard attribute == .children else { return super.accessibilityArrayAttributeValues(attribute, index: index, maxCount: maxCount) }
        // Elements are not Sendable; they are made and returned on the main thread, never crossing actors.
        nonisolated(unsafe) var elements: [Any] = []
        MainActor.assumeIsolated { elements = accessibilityChildren(in: index, maxCount: maxCount) }
        return elements
    }

    func accessibilityChildren(in index: Int, maxCount: Int) -> [DiffRowAccessibilityElement] {
        let low = max(0, index)
        let high = min(rows.rows.count, low + max(0, min(maxCount, Self.accessibilityElementLimit / 2)))
        guard low < high else { return [] }
        return (low..<high).map { accessibilityElement(row: $0) }
    }

    override func accessibilityIndex(ofChild child: Any) -> Int {
        guard let element = child as? DiffRowAccessibilityElement, element.view === self else { return super.accessibilityIndex(ofChild: child) }
        let (row, elementGeneration) = (element.row, element.generation)
        return MainActor.assumeIsolated { elementGeneration == generation ? row : NSNotFound }
    }

    override func accessibilityLabel() -> String? {
        "Diff, \(files.count) file\(files.count == 1 ? "" : "s"), \(rows.rows.count) rows"
    }

    // MARK: Actions

    func isCurrentAccessibilityRow(_ row: Int, generation: Int) -> Bool {
        generation == self.generation && rows.rows.indices.contains(row)
    }

    func accessibilityScreenFrame(row: Int, generation: Int) -> NSRect {
        guard isCurrentAccessibilityRow(row, generation: generation), let window else { return .zero }
        return window.convertToScreen(convert(rowRect(row), to: nil))
    }

    func scrollAccessibilityRowToVisible(_ row: Int, generation: Int) {
        guard isCurrentAccessibilityRow(row, generation: generation) else { return }
        let rect = rowRect(row)
        if !visibleRect.contains(rect) { scrollToVisible(rect) }
    }

    func performAccessibilityPress(row: Int, generation: Int) -> Bool {
        isCurrentAccessibilityRow(row, generation: generation) && performAccessibilityPress(row: row)
    }

    func accessibilityActions(row: Int, generation: Int) -> [NSAccessibilityCustomAction]? {
        isCurrentAccessibilityRow(row, generation: generation) ? accessibilityActions(row: row) : nil
    }

    /// Press: a file header collapses or expands the file, an expandable gap shows 20 more lines, a hunk header becomes
    /// the current change (as a click does).
    func performAccessibilityPress(row index: Int) -> Bool {
        let row = rows.rows[index]
        switch row.kind {
        case .fileHeader:
            pendingAccessibilityChange = .toggledFile(row.fileIndex)
            onToggleFile?(row.fileIndex)
            return true
        case .gap(_, let expandable):
            guard expandable else { return false }
            pendingAccessibilityChange = .expandedGap(file: row.fileIndex, hunk: row.hunkIndex, all: false)
            onExpandGap?(row, false)
            return true
        case .hunkHeader:
            currentHunkRow = index
            onCurrentHunkChange?(index)
            return true
        case .line, .notice:
            return false
        case .annotation(let annotation):
            guard rows.annotations.indices.contains(annotation) else { return false }
            onToggleAnnotation?(rows.annotations[annotation].id)
            return true
        }
    }

    /// The controls drawn on a row, as named actions: Revert Hunk, Show 20 More Lines / Show All Lines, Add Comment.
    func accessibilityActions(row index: Int) -> [NSAccessibilityCustomAction] {
        let row = rows.rows[index]
        var actions: [NSAccessibilityCustomAction] = []
        switch row.kind {
        case .fileHeader:
            actions.append(NSAccessibilityCustomAction(name: "Collapse or Expand File") { [weak self] in
                self?.performAccessibilityPress(row: index) ?? false
            })
        case .hunkHeader:
            if revertableFiles.contains(row.fileIndex) {
                let file = row.fileIndex, hunk = row.hunkIndex
                actions.append(NSAccessibilityCustomAction(name: "Revert Hunk") { [weak self] in
                    guard let self, let handler = self.onRevertHunk else { return false }
                    handler(file, hunk)
                    return true
                })
            }
        case .gap(_, let expandable):
            guard expandable else { break }
            actions.append(NSAccessibilityCustomAction(name: "Show 20 More Lines") { [weak self] in
                self?.performAccessibilityPress(row: index) ?? false
            })
            actions.append(NSAccessibilityCustomAction(name: "Show All Lines") { [weak self] in
                guard let self, self.rows.rows.indices.contains(index) else { return false }
                let gap = self.rows.rows[index]
                self.pendingAccessibilityChange = .expandedGap(file: gap.fileIndex, hunk: gap.hunkIndex, all: true)
                self.onExpandGap?(gap, true)
                return true
            })
        case .line:
            guard onComment != nil else { break }
            actions.append(NSAccessibilityCustomAction(name: "Add Comment") { [weak self] in
                self?.commentOnRow(index) ?? false
            })
        case .notice:
            break
        case .annotation(let annotation):
            guard rows.annotations.indices.contains(annotation) else { break }
            let id = rows.annotations[annotation].id
            actions.append(NSAccessibilityCustomAction(name: rows.expandedAnnotations.contains(id) ? "Collapse Thread" : "Expand Thread") { [weak self] in
                self?.performAccessibilityPress(row: index) ?? false
            })
            for (name, action) in annotationAccessibilityActions?(id) ?? [] {
                actions.append(NSAccessibilityCustomAction(name: name) { action(); return true })
            }
        }
        return actions
    }

    /// Selects the row's line (the new side when it has one) and opens the comment editor for it.
    private func commentOnRow(_ index: Int) -> Bool {
        guard rows.rows.indices.contains(index), let onComment else { return false }
        let row = rows.rows[index]
        let side: DiffSide? = layoutMode == .unified ? nil : (row.right != nil ? .new : .old)
        let length = cell(row: index, side: side)?.text.utf16.count ?? 0
        selection = DiffTextSelection(side: side, anchor: DiffTextPosition(row: index, offset: 0), head: DiffTextPosition(row: index, offset: length))
        onComment()
        return true
    }

    // MARK: Announcements

    /// After rows rebuilt for an accessibility action: one announcement of the new state, and focus on the element
    /// standing for the acted-on row (the old elements belong to the previous rows).
    func announcePendingAccessibilityChange() {
        guard let change = pendingAccessibilityChange else { return }
        pendingAccessibilityChange = nil
        let message: String
        let focusRow: Int?
        switch change {
        case .toggledFile(let file):
            guard files.indices.contains(file), rows.fileHeaderRows.indices.contains(file) else { return }
            let header = rows.fileHeaderRows[file]
            let next = header + 1
            let expanded = rows.rows.indices.contains(next) && rows.rows[next].fileIndex == file
            message = "\((files[file].path as NSString).lastPathComponent) \(expanded ? "expanded" : "collapsed")"
            focusRow = header
        case .expandedGap(let file, let hunk, let all):
            message = all ? "Showing all unchanged lines" : "Showing more unchanged lines"
            focusRow = rows.rows.firstIndex { $0.fileIndex == file && $0.hunkIndex == hunk }
        }
        Self.lastAnnouncement = message
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        if let focusRow {
            NSAccessibility.post(element: self, notification: .layoutChanged, userInfo: [.uiElements: [accessibilityElement(row: focusRow)]])
        }
    }
}

extension DiffContentView {
    /// The most recent announcement (tests read it; posting has no observable result without VoiceOver).
    static var lastAnnouncement: String?
}
