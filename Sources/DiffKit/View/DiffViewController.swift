import AppKit
import DesignSystem
import Engine
import os

/// Display options of a diff view.
public struct DiffViewOptions: Sendable, Hashable, Codable {
    public var layout: DiffLayout = .unified
    public var wraps = false
    public var ignoreWhitespace = false
    public init() {}
}

/// A review comment on lines of one side of a file's diff.
public struct DiffReviewComment: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var path: String
    public var side: DiffSide
    public var startLine: Int
    public var endLine: Int
    /// The commented lines, as shown.
    public var quoted: String
    public var text: String

    public init(id: UUID = UUID(), path: String, side: DiffSide, startLine: Int, endLine: Int, quoted: String, text: String) {
        self.id = id
        self.path = path
        self.side = side
        self.startLine = startLine
        self.endLine = endLine
        self.quoted = quoted
        self.text = text
    }

    /// "Sources/App.swift:12–14".
    public var location: String { startLine == endLine ? "\(path):\(startLine)" : "\(path):\(startLine)–\(endLine)" }

    /// The text given to the agent: location, side, the quoted lines, then the comment.
    public var promptText: String {
        let sideName = side == .old ? "old (removed) side" : "new side"
        let fence = quoted.contains("```") ? "~~~" : "```"
        return "Review comment on \(location) (\(sideName)):\n\(fence)\n\(quoted)\n\(fence)\n\(text)\n"
    }
}

/// An action the owner offers on an inline review thread (menu item, keyboard, accessibility).
public struct DiffAnnotationAction: Sendable, Hashable {
    /// The owner's identifier ("reply", "resolve", "agent" …).
    public var id: String
    public var title: String
    public var isEnabled: Bool

    public init(id: String, title: String, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
    }
}

/// What the diff view asks its owner to do.
@MainActor
public protocol DiffViewControllerDelegate: AnyObject {
    func diffViewController(_ controller: DiffViewController, revertHunk hunkIndex: Int, in file: DiffFile)
    func diffViewController(_ controller: DiffViewController, addComment comment: DiffReviewComment)
    func diffViewController(_ controller: DiffViewController, open file: DiffFile, line: Int?)
}

/// The diff view: a virtualised AppKit diff (unified or side by side) for a list of files, with a find bar, keyboard
/// navigation between hunks and files, selection and copy within a side, review comments, and hunk revert buttons
/// for files the owner allows. Rows and syntax are built off the main actor; the previous content stays visible until
/// the new rows are ready, and the first visible row keeps its place across rebuilds.
///
/// Mounting: `let diff = DiffViewController()`, add `diff.view`, then `diff.display(files)`.
@MainActor
public final class DiffViewController: NSViewController, NSTextFieldDelegate {
    public weak var delegate: (any DiffViewControllerDelegate)?
    public var options = DiffViewOptions() {
        didSet {
            guard options != oldValue else { return }
            content.wraps = options.wraps
            if options.layout != oldValue.layout || options.ignoreWhitespace != oldValue.ignoreWhitespace { rebuild(keepPosition: true) }
            updateIndicator()
        }
    }
    /// Shown when there is nothing to display ("No changes in this turn").
    public var emptyText = "No changes" { didSet { updateEmptyState() } }
    public private(set) var files: [DiffFile] = []
    public private(set) var isBuilding = false
    /// Called after new rows are shown (tests, benchmarks, the Changes panel's counts).
    public var onDisplay: (() -> Void)?
    /// Called when the file the viewport is in changes (the Changes panel highlights it in the tree).
    public var onVisibleFileChange: ((String?) -> Void)?
    public var commentMarks: Set<DiffCommentMark> {
        get { content.commentMarks }
        set { content.commentMarks = newValue }
    }
    /// Review threads and drafts shown inline (GitLab 2). Setting them rebuilds the rows off the main actor and keeps
    /// the first visible row in place.
    public var annotations: [DiffAnnotation] = [] {
        didSet {
            guard annotations != oldValue else { return }
            expandedAnnotations.formIntersection(Set(annotations.map(\.id)))
            rebuild(keepPosition: true)
        }
    }
    /// Threads shown expanded (notes and bodies).
    public private(set) var expandedAnnotations: Set<String> = []
    /// The actions the owner offers on a thread (context menu, keys, accessibility).
    public var annotationActions: ((DiffAnnotation) -> [DiffAnnotationAction])?
    public var onAnnotationAction: ((DiffAnnotationAction, DiffAnnotation) -> Void)?
    /// Called when the current thread changes (keyboard or click).
    public var onCurrentAnnotationChange: ((DiffAnnotation?) -> Void)?
    /// Keys the diff handles for threads: N / P next and previous thread, o expand or collapse, r reply.
    public var annotationKeys = true
    /// The comment popover's hint and button (the Changes panel's comments go to the composer; a review's are drafts).
    public var commentHint = "Goes to the composer as context."
    public var commentActionTitle = "Add Comment"

    let content: DiffContentView
    private let scrollView = DiffScrollView()
    private let findBar = NSStackView()
    private let findInput = DSTextField(style: .search, placeholder: "Find in diff")
    private var findField: NSTextField { findInput.field }
    private let findCount = NSTextField(labelWithString: "")
    private let indicator = HorizontalIndicatorView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var findTopConstraint: NSLayoutConstraint?
    private var revertablePaths: Set<String> = []
    private var collapsedFiles: Set<String> = []
    private var expansions: [GapKey: GapExpansion] = [:]
    private var buildTask: Task<Void, Never>?
    private var syntaxTask: Task<Void, Never>?
    private var findTask: Task<Void, Never>?
    private var generation = 0
    private var themeAppearance: String?
    private var lastVisibleFile: String?
    static let signposter = OSSignposter(subsystem: "dev.bellocode.diffkit", category: .pointsOfInterest)

    public init() {
        content = DiffContentView(theme: DiffTheme.resolve(appearance: NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        buildTask?.cancel()
        syntaxTask?.cancel()
        findTask?.cancel()
    }

    // MARK: View

    public override func loadView() {
        let container = DiffContainerView()
        container.owner = self
        container.onAppearanceChange = { [weak self] in self?.updateTheme() }
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        DSScroller.install(on: scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        content.autoresizingMask = []
        scrollView.documentView = content
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.onToggleFile = { [weak self] index in self?.toggleFile(index) }
        content.onExpandGap = { [weak self] row, all in self?.expand(row, all: all) }
        content.onRevertHunk = { [weak self] file, hunk in self?.requestRevert(file: file, hunk: hunk) }
        content.onComment = { [weak self] in self?.beginComment() }
        content.onToggleAnnotation = { [weak self] id in self?.toggleAnnotation(id) }
        content.annotationAccessibilityActions = { [weak self] id in
            guard let self, let annotation = self.annotations.first(where: { $0.id == id }) else { return [] }
            return (self.annotationActions?(annotation) ?? []).filter(\.isEnabled).map { action in
                (action.title, { [weak self] in self?.onAnnotationAction?(action, annotation) })
            }
        }
        content.onSelectionChange = { [weak self] in self?.view.window?.toolbar?.validateVisibleItems() }
        content.contextMenuProvider = { [weak self] row, _ in self?.contextMenu(row: row) }
        content.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        buildFindBar()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.isHidden = true
        // Empty and loading states: `label text2`, centred (the panel's toolbar keeps the context).
        emptyLabel.font = DS.TextRole.label.font
        emptyLabel.textColor = DS.Color.text2
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        for subview in [scrollView, findBar, indicator, emptyLabel] as [NSView] { container.addSubview(subview) }
        let findTop = findBar.topAnchor.constraint(equalTo: container.topAnchor, constant: -40)
        findTopConstraint = findTop
        NSLayoutConstraint.activate([
            findTop,
            findBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            indicator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            indicator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            indicator.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            indicator.heightAnchor.constraint(equalToConstant: 5),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32),
        ])
        findBar.isHidden = true
        view = container
        updateEmptyState()
    }

    /// The diff's find bar (⌘F): a 36 pt docked strip on `canvas` with a `border` hairline, the DS search field, match
    /// count (`meta text3`, tabular), previous / next icon buttons and a ghost Done.
    private func buildFindBar() {
        findInput.showsHalo = false
        findField.delegate = self
        findField.setAccessibilityLabel("Find in diff")
        findCount.font = .monospacedDigitSystemFont(ofSize: DS.TextRole.meta.font.pointSize, weight: .regular)
        findCount.textColor = DS.Color.text3
        func button(_ symbol: String, _ label: String, _ action: Selector) -> DSButton {
            let button = DSButton(icon: symbol, accessibilityTitle: label, size: .small, target: self, action: action)
            button.toolTip = label
            return button
        }
        let done = DSButton(title: "Done", variant: .ghost, size: .small, target: self, action: #selector(closeFind(_:)))
        for view in [findInput, findCount, button("chevron.up", "Previous Match (⇧⌘G)", #selector(findPreviousAction(_:))),
                     button("chevron.down", "Next Match (⌘G)", #selector(findNextAction(_:))), done] as [NSView] {
            findBar.addArrangedSubview(view)
        }
        findInput.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        findInput.heightAnchor.constraint(equalToConstant: DS.Size.controlSmall).isActive = true
        findBar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        findBar.spacing = DS.Space.s4
        findBar.setCustomSpacing(DS.Space.s8, after: findInput)
        findBar.alignment = .centerY
        findBar.wantsLayer = true
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.heightAnchor.constraint(equalToConstant: DS.Size.toolbar).isActive = true
        let rule = DSDivider()
        rule.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(rule)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: findBar.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: findBar.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: findBar.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: DS.Border.hairline),
        ])
    }

    public func controlTextDidChange(_ notification: Notification) { findFieldChanged(nil) }

    public override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentSize.width
        if content.frame.width != width { content.setFrameSize(NSSize(width: width, height: content.frame.height)) }
        updateIndicator()
    }

    private func updateTheme() {
        let appearance = view.effectiveAppearance
        content.theme = DiffTheme.resolve(appearance: appearance, revision: Int(appearance.name.rawValue.hashValue & 0xFFFF))
        findBar.layer?.backgroundColor = DS.Color.canvas.resolvedCGColor(for: appearance)
        scrollView.backgroundColor = DS.Color.canvas
    }

    private func updateEmptyState() {
        guard isViewLoaded else { return }
        emptyLabel.stringValue = emptyText
        emptyLabel.isHidden = !files.isEmpty || isBuilding
    }

    // MARK: Content

    /// Shows files. `revertable`: paths whose hunks get a "Revert Hunk" button. `keepPosition` keeps the first visible
    /// row (by ID) in place, as after a refresh; otherwise the view starts at the top.
    public func display(_ files: [DiffFile], revertable: Set<String> = [], keepPosition: Bool = false) {
        let oldPaths = Set(self.files.map(\.path))
        self.files = files
        revertablePaths = revertable
        let newPaths = Set(files.map(\.path))
        collapsedFiles.formIntersection(newPaths)
        expansions = expansions.filter { newPaths.contains($0.key.path) }
        rebuild(keepPosition: keepPosition && !oldPaths.isDisjoint(with: newPaths))
    }

    private func rebuild(keepPosition: Bool) {
        _ = view
        generation += 1
        let generation = generation
        buildTask?.cancel()
        syntaxTask?.cancel()
        isBuilding = true
        let anchor = keepPosition ? topAnchorRow() : nil
        if let id = currentAnnotation?.id { pendingCurrentAnnotation = id }
        var rowOptions = DiffRowOptions()
        rowOptions.layout = options.layout
        rowOptions.collapsedFiles = collapsedFiles
        rowOptions.expansions = expansions
        rowOptions.annotations = annotations
        rowOptions.expandedAnnotations = expandedAnnotations
        let files = files
        let ignoreWhitespace = options.ignoreWhitespace
        updateEmptyState()
        buildTask = Task { [weak self] in
            let interval = Self.signposter.beginInterval("diffBuild")
            let (shown, rows) = await Self.build(files, options: rowOptions, ignoreWhitespace: ignoreWhitespace)
            Self.signposter.endInterval("diffBuild", interval)
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.apply(shown, rows: rows, anchor: anchor, layout: rowOptions.layout)
            self.syntaxTask = Task { [weak self] in
                let syntax = await Self.syntax(shown)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.content.setSyntax(syntax)
            }
        }
    }

    @concurrent
    static func build(_ files: [DiffFile], options: DiffRowOptions, ignoreWhitespace: Bool) async -> ([DiffFile], DiffRows) {
        let shown = ignoreWhitespace ? files.map { $0.rediffed(ignoreWhitespace: true) } : files
        return (shown, DiffRowBuilder.build(shown, options: options))
    }

    @concurrent
    static func syntax(_ files: [DiffFile]) async -> [Int: DiffSyntax] {
        var result: [Int: DiffSyntax] = [:]
        for (index, file) in files.enumerated() {
            if Task.isCancelled { break }
            let syntax = DiffSyntax.compute(for: file)
            if !syntax.old.isEmpty || !syntax.new.isEmpty { result[index] = syntax }
        }
        return result
    }

    private func apply(_ shown: [DiffFile], rows: DiffRows, anchor: (DiffRowID, CGFloat)?, layout: DiffLayout) {
        isBuilding = false
        let revertable = Set(shown.enumerated().filter { revertablePaths.contains($0.element.path) }.map(\.offset))
        content.revertableFiles = revertable
        content.setContent(files: shown, rows: rows, syntax: [:], layout: layout)
        if let id = pendingCurrentAnnotation {
            pendingCurrentAnnotation = nil
            content.currentAnnotationRow = rows.rows.indices.first { row in
                if case .annotation(let index) = rows.rows[row].kind { rows.annotations[index].id == id } else { false }
            }
        }
        if let (id, offset) = anchor, let index = rows.rows.firstIndex(where: { $0.id >= id }) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, content.rowRect(index).minY + offset)))
        } else if anchor == nil {
            scrollView.contentView.scroll(to: .zero)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateEmptyState()
        updateIndicator()
        if !findField.stringValue.isEmpty, !findBar.isHidden { runFind(scrollToFirst: false) }
        reportVisibleFile()
        onDisplay?()
    }

    /// The first visible row's ID and the viewport's offset from its top.
    private func topAnchorRow() -> (DiffRowID, CGFloat)? {
        let y = scrollView.contentView.bounds.minY
        guard let index = content.rowIndex(atY: y), content.rows.rows.indices.contains(index) else { return nil }
        return (content.rows.rows[index].id, y - content.rowRect(index).minY)
    }

    private func toggleFile(_ index: Int) {
        guard files.indices.contains(index) else { return }
        let path = files[index].path
        if collapsedFiles.contains(path) { collapsedFiles.remove(path) } else { collapsedFiles.insert(path) }
        rebuild(keepPosition: true)
    }

    private func expand(_ row: DiffRow, all: Bool) {
        guard files.indices.contains(row.fileIndex) else { return }
        let key = GapKey(path: files[row.fileIndex].path, beforeHunk: row.hunkIndex)
        var expansion = expansions[key] ?? GapExpansion()
        if all {
            expansion.top += 1_000_000
        } else if row.hunkIndex == 0 {
            expansion.bottom += 20
        } else if row.hunkIndex >= files[row.fileIndex].hunks.count {
            expansion.top += 20
        } else {
            expansion.top += 10
            expansion.bottom += 10
        }
        expansions[key] = expansion
        rebuild(keepPosition: true)
    }

    private func requestRevert(file: Int, hunk: Int) {
        guard content.files.indices.contains(file) else { return }
        delegate?.diffViewController(self, revertHunk: hunk, in: content.files[file])
    }

    // MARK: Scrolling and navigation

    @objc private func boundsChanged(_ notification: Notification) {
        reportVisibleFile()
    }

    private func reportVisibleFile() {
        let y = scrollView.contentView.bounds.minY + 4
        let path = content.rowIndex(atY: y).flatMap { content.rows.rows.indices.contains($0) ? content.files[content.rows.rows[$0].fileIndex].path : nil }
        if path != lastVisibleFile {
            lastVisibleFile = path
            onVisibleFileChange?(path)
        }
    }

    private func scroll(toRow index: Int, margin: CGFloat = 0) {
        let rect = content.rowRect(index)
        let maxY = max(0, content.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, rect.minY - margin), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func reveal(row index: Int) {
        let rect = content.rowRect(index)
        let visible = scrollView.contentView.bounds
        if rect.minY < visible.minY || rect.maxY > visible.maxY { scroll(toRow: index, margin: visible.height / 3) }
    }

    /// Scrolls to a file's header.
    public func scroll(toFile path: String) {
        guard let fileIndex = content.files.firstIndex(where: { $0.path == path }), content.rows.fileHeaderRows.indices.contains(fileIndex) else { return }
        scroll(toRow: content.rows.fileHeaderRows[fileIndex])
        if let hunk = content.rows.hunkHeaderRows.first(where: { content.rows.rows[$0].fileIndex == fileIndex }) { content.currentHunkRow = hunk }
    }

    /// The hunk after the current one (or after the viewport's top) becomes current and scrolls to the top.
    public func nextHunk() { moveHunk(forward: true) }
    public func previousHunk() { moveHunk(forward: false) }

    private func moveHunk(forward: Bool) {
        let headers = content.rows.hunkHeaderRows
        guard !headers.isEmpty else { return NSSound.beep() }
        let reference = content.currentHunkRow ?? content.rowIndex(atY: scrollView.contentView.bounds.minY + 1) ?? 0
        let target = forward ? headers.first { $0 > reference } : headers.last { $0 < reference }
        guard let target else { return NSSound.beep() }
        content.currentHunkRow = target
        scroll(toRow: target, margin: content.theme.rowHeight)
    }

    public func nextFile() { moveFile(forward: true) }
    public func previousFile() { moveFile(forward: false) }

    private func moveFile(forward: Bool) {
        let headers = content.rows.fileHeaderRows
        guard !headers.isEmpty else { return NSSound.beep() }
        let top = content.rowIndex(atY: scrollView.contentView.bounds.minY + 1) ?? 0
        let target = forward ? headers.first { $0 > top } : headers.last { $0 < top }
        guard let target else { return NSSound.beep() }
        scroll(toRow: target)
    }

    /// The file and hunk index of the current hunk (for "Revert Hunk" from the menu).
    public var currentHunk: (file: DiffFile, hunk: Int)? {
        guard let row = content.currentHunkRow, content.rows.rows.indices.contains(row) else { return nil }
        let item = content.rows.rows[row]
        return (content.files[item.fileIndex], item.hunkIndex)
    }

    public var visibleFilePath: String? { lastVisibleFile }

    /// Vertical scroll (benchmarks): sets the viewport's top.
    public func scroll(toY y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, content.frame.height - scrollView.contentView.bounds.height))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    public var contentHeight: CGFloat { content.totalHeight }
    public var lastDrawDuration: Duration { content.lastDrawDuration }
    public var rowCount: Int { content.rows.rows.count }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty else { return false }
        let page = scrollView.contentView.bounds.height - content.theme.rowHeight * 2
        let y = scrollView.contentView.bounds.minY
        switch event.keyCode {
        case 125: scroll(toY: y + content.theme.rowHeight * 3); return true
        case 126: scroll(toY: y - content.theme.rowHeight * 3); return true
        case 121: scroll(toY: y + page); return true
        case 116: scroll(toY: y - page); return true
        case 49: scroll(toY: event.modifierFlags.contains(.shift) ? y - page : y + page); return true
        case 115: scroll(toY: 0); return true
        case 119: scroll(toY: .greatestFiniteMagnitude); return true
        case 123: content.horizontalOffset -= content.theme.charWidth * 8; updateIndicator(); return true
        case 124: content.horizontalOffset += content.theme.charWidth * 8; updateIndicator(); return true
        case 53:
            if !findBar.isHidden { closeFind(nil) } else if content.selection != nil { content.selection = nil } else { return false }
            return true
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "n", "j": nextHunk(); return true
        case "p", "k": previousHunk(); return true
        case "]": nextFile(); return true
        case "[": previousFile(); return true
        case "c": beginComment(); return true
        case "N" where annotationKeys && !annotations.isEmpty: nextAnnotation(); return true
        case "P" where annotationKeys && !annotations.isEmpty: previousAnnotation(); return true
        case "o" where annotationKeys && currentAnnotation != nil: toggleAnnotation(currentAnnotation!.id); return true
        case "r" where annotationKeys && currentAnnotation != nil:
            let annotation = currentAnnotation!
            if let reply = annotationActions?(annotation).first(where: { $0.id == "reply" && $0.isEnabled }) { onAnnotationAction?(reply, annotation) } else { NSSound.beep() }
            return true
        default: return false
        }
    }

    // MARK: Review threads

    /// The thread keyboard actions apply to.
    public var currentAnnotation: DiffAnnotation? {
        guard let row = content.currentAnnotationRow, content.rows.rows.indices.contains(row), case .annotation(let index) = content.rows.rows[row].kind,
            content.rows.annotations.indices.contains(index)
        else { return nil }
        return content.rows.annotations[index]
    }

    /// Rows of placed threads, in order.
    private var annotationRows: [Int] {
        content.rows.rows.indices.filter { if case .annotation = content.rows.rows[$0].kind { true } else { false } }
    }

    public func toggleAnnotation(_ id: String) {
        if expandedAnnotations.contains(id) { expandedAnnotations.remove(id) } else { expandedAnnotations.insert(id) }
        pendingCurrentAnnotation = id
        rebuild(keepPosition: true)
        pendingCurrentAnnotation = id
        onCurrentAnnotationChange?(annotations.first { $0.id == id })
    }

    public func setExpanded(_ ids: Set<String>) {
        guard ids != expandedAnnotations else { return }
        expandedAnnotations = ids
        rebuild(keepPosition: true)
    }

    public func nextAnnotation() { moveAnnotation(forward: true) }
    public func previousAnnotation() { moveAnnotation(forward: false) }

    private func moveAnnotation(forward: Bool) {
        let rows = annotationRows
        guard !rows.isEmpty else { return NSSound.beep() }
        let reference = content.currentAnnotationRow ?? content.rowIndex(atY: scrollView.contentView.bounds.minY + 1) ?? 0
        let target = forward ? (rows.first { $0 > reference } ?? rows.first!) : (rows.last { $0 < reference } ?? rows.last!)
        content.currentAnnotationRow = target
        scroll(toRow: target, margin: content.theme.rowHeight * 3)
        onCurrentAnnotationChange?(currentAnnotation)
    }

    /// Makes a thread current and scrolls to it.
    public func reveal(annotation id: String) {
        guard let row = annotationRows.first(where: { row in
            if case .annotation(let index) = content.rows.rows[row].kind { content.rows.annotations[index].id == id } else { false }
        }) else { return }
        content.currentAnnotationRow = row
        scroll(toRow: row, margin: content.theme.rowHeight * 3)
        onCurrentAnnotationChange?(currentAnnotation)
    }

    /// Opens the comment editor popover by a thread's row (or the selection when `annotationID` is nil): the owner
    /// decides the title, hint and button, and receives the text.
    public func showEditor(annotationID: String?, title: String, hint: String, actionTitle: String, initial: String = "", onSubmit: @escaping (String) -> Void) {
        let row: Int? = annotationID.flatMap { id in
            annotationRows.first { row in
                if case .annotation(let index) = content.rows.rows[row].kind { content.rows.annotations[index].id == id } else { false }
            }
        } ?? content.selection?.end.row
        let editor = CommentEditorController(location: title, title: title, hint: hint, actionTitle: actionTitle)
        editor.text = initial
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = editor
        editor.onSubmit = { [weak popover] text in
            popover?.close()
            onSubmit(text)
        }
        editor.onCancel = { [weak popover] in popover?.close() }
        let rect = row.map { content.rowRect($0) } ?? CGRect(x: 0, y: scrollView.contentView.bounds.minY, width: 200, height: 20)
        popover.show(relativeTo: NSRect(x: rect.minX + 80, y: rect.minY, width: 40, height: min(rect.height, 30)), of: content, preferredEdge: .maxY)
        pendingCommentPopover = popover
    }

    func updateIndicator() {
        let maximum = content.maxHorizontalOffset
        indicator.isHidden = maximum <= 0
        indicator.fraction = maximum > 0 ? content.horizontalOffset / maximum : 0
        indicator.visibleShare = maximum > 0 ? content.columnWidth / (content.columnWidth + maximum) : 1
        indicator.leadingInset = options.layout == .unified ? 2 * content.gutterWidth + content.markerWidth : content.gutterWidth + content.markerWidth
    }

    // MARK: Selection, copy, comments

    public var hasSelection: Bool { content.selectedText != nil }

    /// Selects whole lines `first...last` of a file on one side (tests, demos, "select hunk").
    public func selectLines(path: String, side: DiffSide, _ lines: ClosedRange<Int>) {
        guard let fileIndex = content.files.firstIndex(where: { $0.path == path }) else { return }
        let rows = content.rows.rows.indices.filter { index in
            let row = content.rows.rows[index]
            guard row.fileIndex == fileIndex, let cell = content.cell(row: index, side: options.layout == .unified ? nil : side), cell.side == side || options.layout == .unified else { return false }
            let number = options.layout == .unified && cell.side != side ? (cell.kind == .context ? cell.otherNumber ?? 0 : 0) : cell.number
            return lines.contains(number)
        }
        guard let first = rows.first, let last = rows.last else { return }
        let sideKey: DiffSide? = options.layout == .unified ? nil : side
        content.selection = DiffTextSelection(
            side: sideKey, anchor: DiffTextPosition(row: first, offset: 0),
            head: DiffTextPosition(row: last, offset: content.cell(row: last, side: sideKey)?.text.utf16.count ?? 0))
        reveal(row: first)
    }
    public var selectedText: String? { content.selectedText }

    public func copySelection() {
        guard let text = content.selectedText else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The selection as a comment target: one file, one side, a line range.
    public var commentTarget: (file: DiffFile, side: DiffSide, lines: ClosedRange<Int>, quoted: String)? {
        guard let selection = content.selection else { return nil }
        var cells: [(Int, DiffCell)] = []
        for row in selection.start.row...selection.end.row {
            guard let cell = content.cell(row: row, side: selection.side) else { continue }
            if row == selection.end.row, selection.end.offset == 0, row != selection.start.row { continue }
            cells.append((content.rows.rows[row].fileIndex, cell))
        }
        guard let first = cells.first, cells.allSatisfy({ $0.0 == first.0 }) else { return nil }
        let side: DiffSide = selection.side ?? (cells.contains { $0.1.side == .new } ? .new : .old)
        let numbers = cells.filter { $0.1.side == side }.map(\.1.number)
        guard let low = numbers.min(), let high = numbers.max() else { return nil }
        let quoted = cells.filter { $0.1.side == side }.map(\.1.text).joined(separator: "\n")
        return (content.files[first.0], side, low...high, quoted)
    }

    /// Opens the comment popover for the selected lines (beeps without a selection).
    public func beginComment() {
        guard let target = commentTarget, let selection = content.selection else { return NSSound.beep() }
        let editor = CommentEditorController(
            location: "\(target.file.path):\(target.lines.lowerBound)\(target.lines.count > 1 ? "–\(target.lines.upperBound)" : "")", hint: commentHint,
            actionTitle: commentActionTitle)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = editor
        editor.onSubmit = { [weak self, weak popover] text in
            popover?.close()
            guard let self else { return }
            let comment = DiffReviewComment(
                path: target.file.path, side: target.side, startLine: target.lines.lowerBound, endLine: target.lines.upperBound, quoted: target.quoted, text: text)
            for line in target.lines { self.content.commentMarks.insert(DiffCommentMark(path: comment.path, side: comment.side, line: line)) }
            self.delegate?.diffViewController(self, addComment: comment)
        }
        editor.onCancel = { [weak popover] in popover?.close() }
        let rect = content.rowRect(selection.end.row)
        popover.show(relativeTo: NSRect(x: rect.minX + 80, y: rect.minY, width: 40, height: rect.height), of: content, preferredEdge: .maxY)
        pendingCommentPopover = popover
    }

    private var pendingCommentPopover: NSPopover?
    private var pendingCurrentAnnotation: String?

    private func contextMenu(row: Int?) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        let comment = menu.addItem(withTitle: "Add Comment…", action: #selector(addCommentAction(_:)), keyEquivalent: "")
        comment.target = self
        if let row, content.rows.rows.indices.contains(row), case .annotation(let index) = content.rows.rows[row].kind, content.rows.annotations.indices.contains(index) {
            let annotation = content.rows.annotations[index]
            content.currentAnnotationRow = row
            let thread = NSMenu()
            let toggle = thread.addItem(withTitle: expandedAnnotations.contains(annotation.id) ? "Collapse Thread" : "Expand Thread", action: #selector(annotationMenuAction(_:)), keyEquivalent: "")
            toggle.target = self
            toggle.representedObject = AnnotationMenuItem(action: DiffAnnotationAction(id: "toggle", title: ""), annotation: annotation)
            for action in annotationActions?(annotation) ?? [] {
                let item = thread.addItem(withTitle: action.title, action: action.isEnabled ? #selector(annotationMenuAction(_:)) : nil, keyEquivalent: "")
                item.target = self
                item.isEnabled = action.isEnabled
                item.representedObject = AnnotationMenuItem(action: action, annotation: annotation)
            }
            return thread
        }
        if let row, content.rows.rows.indices.contains(row) {
            let item = content.rows.rows[row]
            let file = content.files[item.fileIndex]
            if item.hunkIndex >= 0, item.hunkIndex < file.hunks.count, revertablePaths.contains(file.path) {
                let revert = menu.addItem(withTitle: "Revert This Hunk…", action: #selector(revertHunkAction(_:)), keyEquivalent: "")
                revert.target = self
                revert.representedObject = [item.fileIndex, item.hunkIndex]
            }
            menu.addItem(.separator())
            let open = menu.addItem(withTitle: "Open \((file.path as NSString).lastPathComponent)", action: #selector(openFileAction(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = [item.fileIndex, (item.right ?? item.left)?.number ?? 0]
        }
        return menu
    }

    @objc private func addCommentAction(_ sender: Any?) { beginComment() }

    @objc private func annotationMenuAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? AnnotationMenuItem else { return }
        if item.action.id == "toggle" { toggleAnnotation(item.annotation.id) } else { onAnnotationAction?(item.action, item.annotation) }
    }

    @objc private func revertHunkAction(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Int], pair.count == 2 else { return }
        requestRevert(file: pair[0], hunk: pair[1])
    }

    @objc private func openFileAction(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Int], pair.count == 2, content.files.indices.contains(pair[0]) else { return }
        delegate?.diffViewController(self, open: content.files[pair[0]], line: pair[1] > 0 ? pair[1] : nil)
    }

    // MARK: Find

    public var isFindVisible: Bool { !findBar.isHidden }

    public func showFind() {
        _ = view
        findBar.isHidden = false
        findTopConstraint?.constant = 0
        view.window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
        if !findField.stringValue.isEmpty { runFind(scrollToFirst: false) }
    }

    @objc public func closeFind(_ sender: Any?) {
        findBar.isHidden = true
        findTopConstraint?.constant = -40
        content.findMatches = []
        content.currentMatch = nil
        view.window?.makeFirstResponder(content)
    }

    public func setFindQuery(_ query: String) {
        _ = view
        if findBar.isHidden { showFind() }
        findField.stringValue = query
        runFind(scrollToFirst: true)
    }

    public func useSelectionForFind() {
        guard let text = content.selectedText?.split(separator: "\n").first.map(String.init), !text.isEmpty else { return NSSound.beep() }
        setFindQuery(text)
    }

    public func findNext() { stepMatch(1) }
    public func findPrevious() { stepMatch(-1) }
    public var findMatchCount: Int { content.findMatches.count }

    @objc private func findNextAction(_ sender: Any?) { findNext() }
    @objc private func findPreviousAction(_ sender: Any?) { findPrevious() }
    @objc private func findFieldChanged(_ sender: Any?) { runFind(scrollToFirst: true) }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? findPrevious() : findNext()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            closeFind(nil)
            return true
        }
        return false
    }

    private func runFind(scrollToFirst: Bool) {
        let query = findField.stringValue
        findTask?.cancel()
        guard !query.isEmpty else {
            content.findMatches = []
            content.currentMatch = nil
            findCount.stringValue = ""
            return
        }
        let rows = content.rows
        let layout = options.layout
        let generation = generation
        findTask = Task { [weak self] in
            let matches = await Self.search(rows, query: query, layout: layout)
            guard let self, !Task.isCancelled, self.generation == generation, self.findField.stringValue == query else { return }
            self.content.findMatches = matches
            let top = self.content.rowIndex(atY: self.scrollView.contentView.bounds.minY) ?? 0
            self.content.currentMatch = matches.isEmpty ? nil : (matches.firstIndex { $0.row >= top } ?? 0)
            self.updateFindCount()
            if scrollToFirst, let current = self.content.currentMatch { self.reveal(row: matches[current].row) }
        }
    }

    @concurrent
    static func search(_ rows: DiffRows, query: String, layout: DiffLayout) async -> [DiffFindMatch] {
        var matches: [DiffFindMatch] = []
        for (index, row) in rows.rows.enumerated() {
            if index % 4_096 == 0, Task.isCancelled { return [] }
            guard case .line = row.kind else { continue }
            let cells: [(DiffCell, DiffSide?)] = layout == .unified ? row.cell.map { [($0, nil)] } ?? [] : [row.left.map { ($0, .old) }, row.right.map { ($0, .new) }].compactMap { $0 }
            for (cell, side) in cells {
                let text = cell.text as NSString
                var range = NSRange(location: 0, length: text.length)
                while range.length > 0 {
                    let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                    guard found.location != NSNotFound else { break }
                    matches.append(DiffFindMatch(row: index, side: side, range: found))
                    if matches.count >= 10_000 { return matches }
                    range = NSRange(location: found.location + max(1, found.length), length: text.length - found.location - max(1, found.length))
                }
            }
        }
        return matches
    }

    private func stepMatch(_ step: Int) {
        let matches = content.findMatches
        guard !matches.isEmpty else { return NSSound.beep() }
        let next = ((content.currentMatch ?? -step) + step + matches.count) % matches.count
        content.currentMatch = next
        updateFindCount()
        reveal(row: matches[next].row)
        let range = matches[next].range
        content.horizontalOffset = max(0, CGFloat(range.location) * content.theme.charWidth - content.columnWidth / 2)
        updateIndicator()
    }

    private func updateFindCount() {
        let count = content.findMatches.count
        findCount.stringValue = count == 0 ? "No matches" : "\((content.currentMatch ?? 0) + 1) of \(count)\(count >= 10_000 ? "+" : "")"
    }

    /// Focuses the diff (keyboard navigation).
    public func focus() { view.window?.makeFirstResponder(content) }
    public var focusView: NSView { content }
}

/// A thread menu item's payload.
final class AnnotationMenuItem: NSObject {
    let action: DiffAnnotationAction
    let annotation: DiffAnnotation
    init(action: DiffAnnotationAction, annotation: DiffAnnotation) {
        self.action = action
        self.annotation = annotation
    }
}

/// The diff's root view: tells the controller when the appearance changes.
@MainActor
final class DiffContainerView: NSView {
    weak var owner: DiffViewController?
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onAppearanceChange?()
    }
}

/// The diff's scroll view (vertical only; horizontal offset is the content view's).
@MainActor
final class DiffScrollView: NSScrollView {}

/// A thin capsule showing the horizontal position of long lines (gutters never scroll).
@MainActor
final class HorizontalIndicatorView: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var visibleShare: CGFloat = 1 { didSet { needsDisplay = true } }
    var leadingInset: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 0, dy: 0).divided(atDistance: leadingInset, from: .minXEdge).remainder
        guard track.width > 20 else { return }
        let width = max(24, track.width * min(1, visibleShare))
        let x = track.minX + (track.width - width) * min(max(fraction, 0), 1)
        DS.Color.scrollThumb.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: width, height: bounds.height), xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The popover for writing a review comment: ⌘↩ adds, Escape cancels.
@MainActor
public final class CommentEditorController: NSViewController, NSTextViewDelegate {
    let location: String
    let titleText: String
    let hintText: String
    let actionTitle: String
    public var onSubmit: ((String) -> Void)?
    public var onCancel: (() -> Void)?
    private let textView = NSTextView()

    public init(location: String, title: String? = nil, hint: String = "Goes to the composer as context.", actionTitle: String = "Add Comment") {
        self.location = location
        titleText = title ?? "Comment on \(location)"
        hintText = hint
        self.actionTitle = actionTitle
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The comment popover's content (§6 menus/popovers recipe): title `title`, a `canvas` text box with the
    /// `borderStrong` ring and `r.md`, the hint in `label text3`, ghost Cancel and primary "Add Comment ⌘↩".
    public override func loadView() {
        let title = NSTextField(labelWithString: titleText)
        title.font = DS.TextRole.title.font
        title.textColor = DS.Color.text
        title.lineBreakMode = .byTruncatingMiddle
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        DSScroller.install(on: scroll)
        let box = DSCommentBox()
        textView.isRichText = false
        textView.font = DS.TextRole.body.font
        textView.textColor = DS.Color.text
        textView.drawsBackground = false
        textView.insertionPointColor = DS.Color.accent
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = self
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.setAccessibilityLabel("Comment")
        textView.minSize = NSSize(width: 0, height: 60)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        let hint = NSTextField(labelWithString: hintText)
        hint.font = DS.TextRole.label.font
        hint.textColor = DS.Color.text3
        let cancel = DSButton(title: "Cancel", variant: .ghost, size: .small, target: self, action: #selector(cancel(_:)))
        let add = DSButton(title: actionTitle, variant: .primary, size: .small, shortcutHint: "⌘↩", target: self, action: #selector(submit(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [hint, spacer, cancel, add])
        buttons.alignment = .centerY
        let stack = NSStackView(views: [title, box, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.s8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 380), box.heightAnchor.constraint(equalToConstant: 84),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            buttons.widthAnchor.constraint(equalTo: box.widthAnchor),
        ])
        view = stack
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    public var text: String {
        get { textView.string }
        set { textView.string = newValue }
    }

    @objc public func submit(_ sender: Any?) {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return NSSound.beep() }
        onSubmit?(text)
    }

    @objc func cancel(_ sender: Any?) { onCancel?() }

    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        // ⌘↩ adds (the button shows the hint; DS buttons have no key equivalent).
        if selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            submit(nil)
            return true
        }
        return false
    }
}

/// The comment field's box: `canvas` fill, `borderStrong` ring, `r.md` (the DS text-field recipe for a multi-line box).
@MainActor
final class DSCommentBox: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        DSDraw.fill(bounds, radius: DS.Radius.md, color: DS.Color.canvas)
        DSDraw.ring(bounds, radius: DS.Radius.md, color: DS.Color.borderStrong)
    }
}

extension NSColor {
    func resolvedCGColor(for appearance: NSAppearance) -> CGColor {
        var color = cgColor
        appearance.performAsCurrentDrawingAppearance { color = self.cgColor }
        return color
    }
}

// MARK: - Responder-chain actions of the focused diff

/// Edit, Find and Changes menu commands answered by the focused diff. The Find selectors are the shell's Find menu
/// actions (`findInTranscript:` …): a focused diff answers them itself, as a focused transcript does, so ⌘F, ⌘G and
/// ⌘E act on what has focus.
extension DiffContentView: NSMenuItemValidation {
    var controller: DiffViewController? { (enclosingScrollView?.superview as? DiffContainerView)?.owner }

    @objc func copy(_ sender: Any?) { controller?.copySelection() }

    @objc override func selectAll(_ sender: Any?) {
        guard !rows.rows.isEmpty else { return }
        let side: DiffSide? = layoutMode == .unified ? nil : (selection?.side ?? .new)
        let last = rows.rows.count - 1
        selection = DiffTextSelection(side: side, anchor: DiffTextPosition(row: 0, offset: 0), head: DiffTextPosition(row: last, offset: cell(row: last, side: side)?.text.utf16.count ?? 0))
    }

    @objc func findInTranscript(_ sender: Any?) { controller?.showFind() }
    @objc func findNextInTranscript(_ sender: Any?) { controller?.findNext() }
    @objc func findPreviousInTranscript(_ sender: Any?) { controller?.findPrevious() }
    @objc func useSelectionForTranscriptFind(_ sender: Any?) { controller?.useSelectionForFind() }
    @objc func nextDiffHunk(_ sender: Any?) { controller?.nextHunk() }
    @objc func previousDiffHunk(_ sender: Any?) { controller?.previousHunk() }
    @objc func nextDiffFile(_ sender: Any?) { controller?.nextFile() }
    @objc func previousDiffFile(_ sender: Any?) { controller?.previousFile() }
    @objc func addDiffComment(_ sender: Any?) { controller?.beginComment() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(useSelectionForTranscriptFind(_:)), #selector(addDiffComment(_:)): selectedText != nil
        case #selector(findNextInTranscript(_:)), #selector(findPreviousInTranscript(_:)): !findMatches.isEmpty
        case #selector(nextDiffHunk(_:)), #selector(previousDiffHunk(_:)): !rows.hunkHeaderRows.isEmpty
        case #selector(nextDiffFile(_:)), #selector(previousDiffFile(_:)): rows.fileHeaderRows.count > 1
        default: true
        }
    }
}
