import AppKit
import BelloCore
import DesignSystem
import Engine
import OrchestrationUI

// The sidebar's rows (visual-language.md §6 "Sidebar"). Cheap by construction (the outline view is virtualised and
// these are reused): manual layout, no stack views; the row background is the row view's one fill
// (`SidebarRowBackground`), the status glyph is a `DSStatusGlyphView` on the shared step clock, and secondary text
// (time, project, counts, guide lines) is drawn in the cell's `draw(_:)`. Only the title is a text field (inline
// rename through the field editor). Never bold: medium marks unread threads and project names only.

/// Horizontal metrics shared by every row, in the cell's coordinates (the outline indents nothing itself).
enum SidebarMetrics {
    /// Row fill inset from the sidebar's edges.
    static let rowInset = DS.Size.sidebarRowInset
    /// The 16 pt glyph slot's leading edge (row inset + content inset).
    static let glyphX = DS.Size.sidebarRowInset + DS.Size.sidebarContentInset
    /// Titles, project names and section labels start here.
    static let titleX: CGFloat = glyphX + DS.Size.iconBox + DS.Space.s6
    /// Trailing edge of row content.
    static func trailing(_ width: CGFloat) -> CGFloat { width - rowInset - DS.Space.s8 }
    /// Indent of a nested child thread per level.
    static let childIndent = DS.Size.sidebarChildIndent
}

/// The row view: the neutral row recipe (`DSTableRowView`: hover `rowHover`, multi-select `rowSelected`, the displayed
/// thread `rowActive`, 6 pt radius inset 8). Header and section rows do not track hover.
@MainActor
final class SidebarRowBackground: DSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebarRow")
}

/// Draws a single line of text vertically centred in `rect` (truncating at the tail).
@MainActor
private func drawLine(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
    guard !text.isEmpty, rect.width > 0 else { return }
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    style.alignment = alignment
    let height = ceil(font.ascender - font.descender)
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        .draw(with: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
}

/// A thread row ("Needs you" or under a project). Observes only its own `SessionRowModel` (and the manual-unread
/// set), so one busy thread re-renders one row (AGENTS.md rule 2).
///
/// One line (28): glyph slot (spinner / shield / bubble / triangle / unread dot; empty when idle), title (`body`
/// regular; `bodyEmph` only when unread), trailing relative time (`meta text4`). "Needs you" rows are two lines (40):
/// the second says the status word in its tone and the project. Nested children indent 22 per level with a 1 pt
/// `border` guide line under their parent's glyph.
@MainActor
final class ThreadCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("thread")
    static let attentionIdentifier = NSUserInterfaceItemIdentifier("attention")

    let title = NSTextField(labelWithString: "")
    let glyph = DSStatusGlyphView()
    /// Shows or hides nested children (threads with sub-agents or fan-out threads only).
    let disclosure = DSButton(icon: "chevron.right", accessibilityTitle: "Show sub-agents", size: .small)
    private var loop: ObservationLoop?
    private(set) var sessionID: SessionID?
    private weak var workspace: WorkspaceController?
    private var showsProject = false
    private var isTwoLine = false
    /// Nesting depth below a top-level thread (0 for top-level rows).
    var depth = 0 { didSet { if depth != oldValue { needsLayout = true; needsDisplay = true } } }
    /// Settled threads recede (`text3`).
    var recedes = false { didSet { if recedes != oldValue { applyTitleStyle() } } }
    var hasChildren = false { didSet { disclosure.isHidden = !hasChildren; needsLayout = true } }
    var isExpanded = false { didSet { disclosure.symbolName = isExpanded ? "chevron.down" : "chevron.right"; disclosure.accessibilityTitle = isExpanded ? "Hide sub-agents" : "Show sub-agents" } }
    private(set) var presentation: ThreadRowPresentation?
    /// The linked MR chip in the detail ("#42 ✓", M3-B).
    private(set) var mergeRequestText: String?
    /// The trailing text ("2m", "#42 ✓ · atlas · 1d").
    private(set) var detailText = ""
    /// The second line of a "Needs you" row ("Approval · atlas").
    private(set) var subtitle: (word: String, tone: DS.Tone, rest: String)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        title.isEditable = false
        title.focusRingType = .none
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
        title.cell?.isScrollable = false
        title.font = DS.TextRole.body.font
        title.textColor = DS.Color.sidebarText
        textField = title
        addSubview(glyph)
        addSubview(title)
        disclosure.isHidden = true
        disclosure.isMuted = true
        addSubview(disclosure)
        setAccessibilityRole(.row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Manual layout: re-run it when the outline view resizes the cell.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true; needsDisplay = true }
    }

    func bind(_ id: SessionID, workspace: WorkspaceController, showsProject: Bool, twoLine: Bool) {
        loop?.cancel()
        sessionID = id
        self.workspace = workspace
        self.showsProject = showsProject
        isTwoLine = twoLine
        presentation = nil
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    /// Re-applies the presentation (also called by the sidebar's clock to refresh relative times).
    func render() {
        guard let sessionID, let workspace, let row = workspace.row(sessionID) else {
            // Not loaded yet: observe the project lists so the row fills in when its project's sessions arrive.
            if let workspace {
                for item in workspace.engine.root.projects { _ = workspace.projectModel(item)?.sessionIDs }
            }
            title.stringValue = ""
            return
        }
        let session = row.session
        var projectName: String?
        var childCount = 0
        if let project = workspace.projectItem(for: session) {
            if showsProject { projectName = project.name }
            childCount = workspace.projectModel(project)?.children(of: sessionID).count ?? 0
        }
        let organisation = workspace.engine.root.organisation[sessionID]
        let presentation = ThreadRowPresentation(
            session: session, status: row.status?.status,
            manuallyUnread: organisation?.markedUnread ?? false || workspace.manualUnread.contains(sessionID),
            childCount: childCount, projectName: projectName, snoozedUntil: organisation?.snoozedUntil?.date)
        let mergeRequestText = Self.mergeRequestText(sessionID, workspace: workspace)
        guard presentation != self.presentation || mergeRequestText != self.mergeRequestText else { return }
        self.presentation = presentation
        self.mergeRequestText = mergeRequestText
        if title.currentEditor() == nil { title.stringValue = presentation.title }
        applyTitleStyle()
        // One leading slot: the status glyph, else the unread dot, so titles stay aligned.
        glyph.status = presentation.glyphStatus ?? (presentation.isUnread ? .finishedUnread : .idle)
        glyph.toolTip = presentation.glyphStatus.map { StatusGlyph($0).label } ?? (presentation.isUnread ? "Unread" : nil)
        glyph.setAccessibilityElement(false)
        if isTwoLine {
            let status = presentation.status
            let word = Self.needsYouWord(status)
            subtitle = (word, StatusGlyph(status).tone, presentation.projectName ?? "")
            detailText = [mergeRequestText, presentation.timeText].compactMap { $0 }.joined(separator: " · ")
        } else {
            subtitle = nil
            detailText = [mergeRequestText, presentation.projectName, presentation.timeText].compactMap { $0 }.joined(separator: " · ")
        }
        setAccessibilityLabel(presentation.accessibilityLabel + (mergeRequestText.map { ", merge request \($0)" } ?? ""))
        needsLayout = true
        needsDisplay = true
    }

    /// The status word of a "Needs you" row ("Approval", "Question", "Failed", …).
    static func needsYouWord(_ status: SessionStatus) -> String {
        switch status {
        case .awaitingApproval: "Approval"
        case .awaitingAnswer: "Question"
        case .failed: "Failed"
        case .finishedUnread: "Finished"
        default: StatusGlyph(status).label
        }
    }

    private func applyTitleStyle() {
        let unread = presentation?.isUnread ?? false
        title.font = unread ? DS.TextRole.bodyEmph.font : DS.TextRole.body.font
        title.textColor = recedes && !unread ? DS.Color.text3 : DS.Color.sidebarText
    }

    /// "#42 ✓" for the first linked PR (+N more), nil without links.
    static func mergeRequestText(_ id: SessionID, workspace: WorkspaceController) -> String? {
        guard let service = workspace.engine.extras?.mergeRequests else { return nil }
        let links = service.links(for: id)
        guard let first = links.first else { return nil }
        return MergeRequestText.compact(first, service.snapshots[first.ref.url]) + (links.count > 1 ? " +\(links.count - 1)" : "")
    }

    private var indent: CGFloat { CGFloat(depth) * SidebarMetrics.childIndent }
    private var metaFont: NSFont { DS.TextRole.meta.font(base: DS.Typography.current.baseSize, monospacedDigits: true) }
    /// The first line's band (the whole row for one-line rows).
    private var firstLine: NSRect { NSRect(x: 0, y: isTwoLine ? 3 : 0, width: bounds.width, height: DS.Size.sidebarRow - (isTwoLine ? 6 : 0)) }

    override func layout() {
        super.layout()
        let line = firstLine
        let side = DS.Size.iconBox
        glyph.frame = NSRect(x: SidebarMetrics.glyphX + indent, y: (line.midY - side / 2).rounded(), width: side, height: side)
        var trailing = SidebarMetrics.trailing(bounds.width)
        let detailWidth = ceil(DSDraw.width(of: detailText, font: metaFont))
        if !detailText.isEmpty { trailing -= min(detailWidth, showsProject && !isTwoLine ? 110 : detailWidth) + DS.Space.s8 }
        if !disclosure.isHidden {
            let size: CGFloat = 20
            disclosure.frame = NSRect(x: trailing - size + 4, y: (line.midY - size / 2).rounded(), width: size, height: size)
            trailing -= size
        }
        let titleX = SidebarMetrics.titleX + indent
        let height = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: titleX - 2, y: (line.midY - height / 2).rounded(), width: max(0, trailing - titleX + 2), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Guide lines under each ancestor's glyph.
        if depth > 0 {
            DS.Color.border.setFill()
            for level in 0..<depth {
                let x = SidebarMetrics.glyphX + DS.Size.iconBox / 2 + CGFloat(level) * SidebarMetrics.childIndent
                NSRect(x: x.rounded(), y: 0, width: DS.Border.hairline, height: bounds.height).fill()
            }
        }
        let line = firstLine
        let right = SidebarMetrics.trailing(bounds.width)
        if !detailText.isEmpty {
            let width = min(ceil(DSDraw.width(of: detailText, font: metaFont)) + 1, showsProject && !isTwoLine ? 110 : .greatestFiniteMagnitude)
            drawLine(detailText, in: NSRect(x: right - width, y: line.minY, width: width, height: line.height), font: metaFont, color: DS.Color.text4, alignment: .right)
        }
        if let subtitle {
            let font = DS.TextRole.meta.font
            let y = line.maxY - 3
            let rect = NSRect(x: SidebarMetrics.titleX, y: y, width: right - SidebarMetrics.titleX, height: 14)
            let tone = subtitle.tone == .neutral ? DS.Color.text3 : DS.Color.tone(subtitle.tone).text
            let text = NSMutableAttributedString(string: subtitle.word, attributes: [.font: font, .foregroundColor: tone])
            if !subtitle.rest.isEmpty {
                text.append(NSAttributedString(string: " · " + subtitle.rest, attributes: [.font: font, .foregroundColor: DS.Color.text3]))
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loop?.cancel()
        loop = nil
        presentation = nil
        depth = 0
        recedes = false
        hasChildren = false
    }
}

/// A project row (30): folder glyph (or favicon), name (`bodyEmph`), thread count (`meta text3`), the "needs you"
/// count while collapsed, and at the trailing edge a "New Thread" button (on hover and keyboard selection) and the
/// disclosure chevron.
@MainActor
final class ProjectCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("project")
    let icon = ProjectIcon()
    let title = NSTextField(labelWithString: "")
    let badge = CountBadge()
    let accessoryButton = DSButton(icon: "square.and.pencil", accessibilityTitle: "New Thread", size: .small)
    let disclosure = DSButton(icon: "chevron.down", accessibilityTitle: "Collapse project", size: .small)
    private var loop: ObservationLoop?
    private(set) var directory: String?
    private weak var workspace: WorkspaceController?
    private var countText = ""
    private var isPinned = false
    var isCollapsed = false {
        didSet {
            guard isCollapsed != oldValue else { return }
            disclosure.symbolName = isCollapsed ? "chevron.right" : "chevron.down"
            disclosure.accessibilityTitle = isCollapsed ? "Expand project" : "Collapse project"
            render()
        }
    }
    var isHovered = false { didSet { updateAccessory() } }
    var isSelectedRow = false { didSet { updateAccessory() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        title.font = DS.TextRole.bodyEmph.font
        title.textColor = DS.Color.sidebarText
        title.lineBreakMode = .byTruncatingTail
        textField = title
        badge.noun = "threads need you"
        badge.isProminent = true
        badge.tint = DS.Color.warningText
        accessoryButton.toolTip = "New Thread (⌘N)"
        accessoryButton.isHidden = true
        accessoryButton.isMuted = true
        disclosure.isMuted = true
        for view in [icon, title, badge, accessoryButton, disclosure] as [NSView] { addSubview(view) }
        setAccessibilityRole(.row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Manual layout: re-run it when the outline view resizes the cell.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true; needsDisplay = true }
    }

    func bind(_ directory: String, workspace: WorkspaceController) {
        loop?.cancel()
        self.directory = directory
        self.workspace = workspace
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    func render() {
        guard let directory, let workspace, let item = workspace.projectItem(directory: directory) else { return }
        title.stringValue = item.name
        isPinned = item.isPinned
        let total = workspace.projectModel(item)?.sessionIDs.count ?? 0
        countText = total > 0 ? "\(total)" : ""
        let needing = isCollapsed ? workspace.engine.root.attention.items.filter { $0.projectID == item.projectID }.count : 0
        badge.count = needing
        var label = "Project \(item.name)"
        if item.isPinned { label += ", pinned" }
        if total > 0 { label += total == 1 ? ", 1 thread" : ", \(total) threads" }
        if needing > 0 { label += ", \(needing) need you" }
        setAccessibilityLabel(label)
        toolTip = item.directory
        needsLayout = true
        needsDisplay = true
    }

    private var metaFont: NSFont { DS.TextRole.meta.font(base: DS.Typography.current.baseSize, monospacedDigits: true) }

    override func layout() {
        super.layout()
        let mid = bounds.midY
        icon.frame = NSRect(x: SidebarMetrics.glyphX, y: (mid - 8).rounded(), width: 16, height: 16)
        var trailing = SidebarMetrics.trailing(bounds.width) + 4
        disclosure.frame = NSRect(x: trailing - 20, y: (mid - 10).rounded(), width: 20, height: 20)
        trailing -= 20 + 2
        if !accessoryButton.isHidden {
            accessoryButton.frame = NSRect(x: trailing - 20, y: (mid - 10).rounded(), width: 20, height: 20)
            trailing -= 22
        }
        if !badge.isHidden {
            let size = badge.intrinsicContentSize
            badge.frame = NSRect(x: trailing - size.width, y: (mid - size.height / 2).rounded(), width: size.width, height: size.height)
            trailing -= size.width + DS.Space.s6
        }
        let extra = (countText.isEmpty ? 0 : ceil(DSDraw.width(of: countText, font: metaFont)) + DS.Space.s6) + (isPinned ? 16 : 0)
        let height = ceil(title.intrinsicContentSize.height)
        let natural = ceil(DSDraw.width(of: title.stringValue, font: title.font ?? DS.TextRole.bodyEmph.font)) + 4
        let width = max(0, min(natural, trailing - SidebarMetrics.titleX - extra))
        title.frame = NSRect(x: SidebarMetrics.titleX - 2, y: (mid - height / 2).rounded(), width: width + 2, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x = title.frame.maxX + DS.Space.s6
        if !countText.isEmpty {
            let width = ceil(DSDraw.width(of: countText, font: metaFont)) + 1
            drawLine(countText, in: NSRect(x: x, y: 0, width: width, height: bounds.height), font: metaFont, color: DS.Color.text3)
            x += width + DS.Space.s4
        }
        if isPinned, let pin = DSDraw.symbol("pin", pointSize: DS.Size.iconPointMeta) {
            DSDraw.draw(template: pin, in: NSRect(x: x, y: 0, width: 12, height: bounds.height), color: DS.Color.text4)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func updateAccessory() {
        let hidden = !(isHovered || isSelectedRow)
        guard accessoryButton.isHidden != hidden else { return }
        accessoryButton.isHidden = hidden
        needsLayout = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loop?.cancel()
        loop = nil
        isHovered = false
        isSelectedRow = false
    }
}

/// Group labels ("Needs you" with its count pill), the gap before the projects, and the "No threads yet" / "No
/// threads match" placeholder rows. Labels are sentence case, `meta` medium `text3` (never caps).
@MainActor
final class SidebarTextCell: NSTableCellView {
    static let headerIdentifier = NSUserInterfaceItemIdentifier("header")
    static let placeholderIdentifier = NSUserInterfaceItemIdentifier("placeholder")
    let label = NSTextField(labelWithString: "")
    let badge = CountBadge()
    /// Leading edge of the label (group rows sit at the glyph column, placeholders at the title column).
    var labelX: CGFloat = SidebarMetrics.glyphX { didSet { needsLayout = true } }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let isHeader = identifier == Self.headerIdentifier
        label.font = isHeader ? DS.TextRole.labelEmph.font : DS.TextRole.label.font
        label.textColor = DS.Color.text3
        label.lineBreakMode = .byTruncatingTail
        badge.isProminent = true
        badge.tint = DS.Color.warningText
        badge.noun = "threads need you"
        textField = label
        addSubview(label)
        addSubview(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Manual layout: re-run it when the outline view resizes the cell.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true; needsDisplay = true }
    }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        let natural = ceil(DSDraw.width(of: label.stringValue, font: label.font ?? DS.TextRole.label.font)) + 4
        let width = min(natural, SidebarMetrics.trailing(bounds.width) - labelX - 30)
        label.frame = NSRect(x: labelX - 2, y: (bounds.midY - height / 2).rounded(), width: max(0, width + 2), height: height)
        let size = badge.intrinsicContentSize
        badge.frame = NSRect(x: label.frame.maxX + DS.Space.s6, y: (bounds.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }
}

/// A section label inside a project ("Pinned", "Working 2", "Settled 14"), or a group label when grouped by state:
/// `meta` medium `text3` + count `text4` at the title column, 24 high. Clicking it collapses or expands the section
/// (the label carries the state for VoiceOver).
@MainActor
final class SidebarSectionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("section")
    let label = NSTextField(labelWithString: "")
    private var countText = ""
    var isExpanded = true { didSet { if isExpanded != oldValue { needsDisplay = true } } }
    private var isGroup = false

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        label.font = DS.TextRole.metaEmph.font
        label.textColor = DS.Color.text3
        textField = label
        addSubview(label)
        setAccessibilityRole(.row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Manual layout: re-run it when the outline view resizes the cell.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true; needsDisplay = true }
    }

    func configure(_ id: SidebarNodeID, count: Int, expanded: Bool) {
        guard case .section(let scope, let section) = id else { return }
        isGroup = scope == nil
        label.stringValue = section.title
        label.font = isGroup ? DS.TextRole.labelEmph.font : DS.TextRole.metaEmph.font
        countText = "\(count)"
        isExpanded = expanded
        setAccessibilityLabel("\(section.title), \(count == 1 ? "1 thread" : "\(count) threads"), \(expanded ? "expanded" : "collapsed")")
        needsLayout = true
        needsDisplay = true
    }

    private var x: CGFloat { isGroup ? SidebarMetrics.glyphX : SidebarMetrics.titleX }
    private var countFont: NSFont { DS.TextRole.meta.font(base: DS.Typography.current.baseSize, monospacedDigits: true) }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        let width = ceil(DSDraw.width(of: label.stringValue, font: label.font ?? DS.TextRole.metaEmph.font)) + 4
        label.frame = NSRect(x: x - 2, y: (bounds.midY - height / 2).rounded(), width: width + 2, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let countX = label.frame.maxX + DS.Space.s4
        drawLine(countText, in: NSRect(x: countX, y: 0, width: 40, height: bounds.height), font: countFont, color: DS.Color.text4)
        // A collapsed section says so with a chevron after its count (not colour or weight alone).
        if !isExpanded, let chevron = DSDraw.symbol("chevron.right", pointSize: DS.Size.iconPointMeta - 1) {
            let width = ceil(DSDraw.width(of: countText, font: countFont))
            DSDraw.draw(template: chevron, in: NSRect(x: countX + width + DS.Space.s4, y: 0, width: 10, height: bounds.height), color: DS.Color.text4)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The insertion gap of a forced drop preview (snapshots): an empty row with an accent insertion line at the title
/// column, as the outline view draws during a real drag.
@MainActor
final class DropGapCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("dropGap")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: SidebarMetrics.titleX - 4, y: bounds.midY - 1, width: SidebarMetrics.trailing(bounds.width) - SidebarMetrics.titleX + 4, height: 2)
        DSDraw.fill(rect, radius: 1, color: DS.Color.accent)
        DSDraw.fill(NSRect(x: rect.minX - 3, y: bounds.midY - 3, width: 6, height: 6), radius: 3, color: DS.Color.accent)
    }
}
