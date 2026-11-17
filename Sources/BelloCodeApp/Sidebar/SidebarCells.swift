import AppKit
import BelloCore
import DesignSystem
import Engine
import OrchestrationUI

/// A thread row ("Needs you" or under a project). Observes only its own `SessionRowModel` (and the manual-unread
/// set), so one busy thread re-renders one row (AGENTS.md rule 2).
@MainActor
final class ThreadCell: SidebarRowView {
    static let identifier = NSUserInterfaceItemIdentifier("thread")
    static let attentionIdentifier = NSUserInterfaceItemIdentifier("attention")

    private var loop: ObservationLoop?
    private(set) var sessionID: SessionID?
    private weak var workspace: WorkspaceController?
    private var showsProject = false
    private(set) var presentation: ThreadRowPresentation?
    /// The linked PR chip in the detail ("#42 ✓", M3-B).
    private(set) var pullRequestText: String?
    /// "project · age" never takes more than this from the title.
    private lazy var detailCap = detail.widthAnchor.constraint(lessThanOrEqualToConstant: 92)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.isEditable = false
        title.focusRingType = .none
        badge.noun = "sub-agents"
        badge.tint = DS.Palette.secondaryText
        setAccessibilityRole(.row)
    }

    private static let unreadImage = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Unread")?
        .withSymbolConfiguration(.init(pointSize: 7, weight: .regular).applying(.init(paletteColors: [DS.Palette.accent])))

    func bind(_ id: SessionID, workspace: WorkspaceController, showsProject: Bool) {
        loop?.cancel()
        sessionID = id
        self.workspace = workspace
        self.showsProject = showsProject
        // "Needs you" rows: the title wins; the "project · age" detail truncates from its head (keeping the age).
        detail.setContentCompressionResistancePriority(showsProject ? .defaultLow - 9 : .required, for: .horizontal)
        detail.lineBreakMode = showsProject ? .byTruncatingHead : .byClipping
        detailCap.isActive = showsProject
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
        let pullRequestText = Self.pullRequestText(sessionID, workspace: workspace)
        guard presentation != self.presentation || pullRequestText != self.pullRequestText else { return }
        self.presentation = presentation
        self.pullRequestText = pullRequestText
        if title.currentEditor() == nil { title.stringValue = presentation.title }
        // Regular weight; emphasis only for unread rows and rows that need the user.
        title.font = presentation.isEmphasized ? DS.Typography.current.bodyEmphasized : DS.Typography.current.body
        // One leading slot: the status glyph, else the unread dot, so titles stay aligned.
        if let status = presentation.glyphStatus {
            leading.image = StatusGlyph(status).image()
            leading.toolTip = StatusGlyph(status).label
        } else if presentation.isUnread {
            leading.image = Self.unreadImage
            leading.toolTip = "Unread"
        } else {
            leading.image = nil
            leading.toolTip = nil
        }
        badge.count = presentation.childCount
        detail.stringValue = [pullRequestText, presentation.projectName, presentation.timeText].compactMap { $0 }.joined(separator: " · ")
        setAccessibilityLabel(presentation.accessibilityLabel + (pullRequestText.map { ", pull request \($0)" } ?? ""))
    }

    /// "#42 ✓" for the first linked PR (+N more), nil without links.
    static func pullRequestText(_ id: SessionID, workspace: WorkspaceController) -> String? {
        guard let service = workspace.engine.extras?.pullRequests else { return nil }
        let links = service.links(for: id)
        guard let first = links.first else { return nil }
        return PullRequestText.compact(first, service.snapshots[first.ref.url]) + (links.count > 1 ? " +\(links.count - 1)" : "")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loop?.cancel()
        loop = nil
        presentation = nil
    }
}

/// A project row: monogram, name, pin mark, attention count while collapsed, and a "New Thread" button shown on hover
/// and on keyboard selection.
@MainActor
final class ProjectCell: SidebarRowView {
    static let identifier = NSUserInterfaceItemIdentifier("project")
    private var loop: ObservationLoop?
    private(set) var directory: String?
    private weak var workspace: WorkspaceController?
    var isCollapsed = false { didSet { if isCollapsed != oldValue { render() } } }
    var isHovered = false { didSet { updateAccessory() } }
    var isSelectedRow = false { didSet { updateAccessory() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        leading.isHidden = true
        monogram.isHidden = false
        title.font = DS.Typography.current.bodyEmphasized
        badge.noun = "threads need you"
        badge.isProminent = true
        badge.tint = DS.Palette.attention
        accessoryButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Thread")
        accessoryButton.toolTip = "New Thread (⌘N)"
        accessoryButton.setAccessibilityLabel("New Thread")
        setAccessibilityRole(.row)
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
        monogram.name = item.name
        detail.stringValue = item.isPinned ? "Pinned" : ""
        detail.isHidden = !item.isPinned
        let needing = isCollapsed ? workspace.engine.root.attention.items.filter { $0.projectID == item.projectID }.count : 0
        badge.count = needing
        var label = "Project \(item.name)"
        if item.isPinned { label += ", pinned" }
        if needing > 0 { label += ", \(needing) need you" }
        setAccessibilityLabel(label)
        toolTip = item.directory
    }

    private func updateAccessory() {
        accessoryButton.isHidden = !(isHovered || isSelectedRow)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loop?.cancel()
        loop = nil
        isHovered = false
        isSelectedRow = false
    }
}

/// Group headers ("Needs you" with its count, "Projects") and the "No threads yet" placeholder row.
@MainActor
final class SidebarTextCell: NSTableCellView {
    static let headerIdentifier = NSUserInterfaceItemIdentifier("header")
    static let placeholderIdentifier = NSUserInterfaceItemIdentifier("placeholder")
    let label = NSTextField(labelWithString: "")
    let badge = CountBadge()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let isHeader = identifier == Self.headerIdentifier
        label.font = isHeader ? DS.Typography.current.sectionHeader : DS.Typography.current.caption
        label.textColor = isHeader ? DS.Palette.secondaryText : DS.Palette.tertiaryText
        label.lineBreakMode = .byTruncatingTail
        badge.isProminent = true
        badge.tint = DS.Palette.attention
        badge.noun = "threads need you"
        textField = label
        let stack = NSStackView(views: [label, badge])
        stack.spacing = DS.Spacing.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: isHeader ? 0 : 22),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Spacing.s),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A section header inside a project ("PINNED 2", "SETTLED 14"), or a group row when grouped by state. The outline
/// view draws the disclosure triangle; the label carries the count for VoiceOver.
@MainActor
final class SidebarSectionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("section")
    let symbol = NSImageView()
    let label = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = DS.Typography.current.sectionHeader
        label.textColor = DS.Palette.secondaryText
        count.font = DS.Typography.current.badge
        count.textColor = DS.Palette.tertiaryText
        symbol.imageScaling = .scaleProportionallyDown
        textField = label
        let stack = NSStackView(views: [symbol, label, count])
        stack.spacing = DS.Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Spacing.s),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 12),
        ])
        setAccessibilityRole(.row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ id: SidebarNodeID, count: Int) {
        guard case .section(let scope, let section) = id else { return }
        let isGroup = scope == nil
        label.stringValue = isGroup ? section.title : section.title.uppercased()
        label.font = isGroup ? DS.Typography.current.sectionHeader : .systemFont(ofSize: DS.Typography.current.baseSize - 3, weight: .semibold)
        self.count.stringValue = "\(count)"
        symbol.isHidden = isGroup
        symbol.image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [DS.Palette.tertiaryText])))
        setAccessibilityLabel("\(section.title), \(count == 1 ? "1 thread" : "\(count) threads")")
    }
}

/// The insertion gap of a forced drop preview (snapshots): an empty row with an accent insertion line, as the outline
/// view draws during a real drag.
@MainActor
final class DropGapCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("dropGap")
    private let line = NSView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.s),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 2),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        line.layer?.backgroundColor = DS.Palette.accent.cgColor
        line.layer?.cornerRadius = 1
    }
}
