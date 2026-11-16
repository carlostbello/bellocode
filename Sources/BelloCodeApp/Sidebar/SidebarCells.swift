import AppKit
import BelloCore
import DesignSystem
import Engine

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
        detail.setContentCompressionResistancePriority(showsProject ? .defaultLow - 1 : .required, for: .horizontal)
        detail.lineBreakMode = showsProject ? .byTruncatingHead : .byClipping
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
        let presentation = ThreadRowPresentation(
            session: session, status: row.status?.status, manuallyUnread: workspace.manualUnread.contains(sessionID),
            childCount: childCount, projectName: projectName)
        guard presentation != self.presentation else { return }
        self.presentation = presentation
        if title.currentEditor() == nil { title.stringValue = presentation.title }
        title.font = presentation.isUnread ? DS.Typography.current.bodyEmphasized : DS.Typography.current.body
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
        detail.stringValue = [presentation.projectName, presentation.timeText].compactMap { $0 }.joined(separator: " · ")
        setAccessibilityLabel(presentation.accessibilityLabel)
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
