import AppKit
import BelloCore
import DesignSystem
import Engine
import OrchestrationUI

/// The thread's title and crumbs, one line in the window's header bar (visual-language.md §6 "Thread header"):
/// title (`title`, editable in place: click, type, Return; Escape cancels), then `label text2` crumbs with 12 pt
/// glyphs: project / branch · worktree (or the directory outside a repository), and the container, agents and merge
/// request chips when they apply. The user always sees where an agent acts (AGENTS.md UX rule 6); the status is in
/// the sidebar, so the header only names states the sidebar cannot (draft, creating, deleted, waiting on children).
@MainActor
final class ThreadHeaderView: NSView, NSTextFieldDelegate {
    private let context: ThreadSurfaceContext
    private let onRename: (SessionID, String) -> Void
    let titleField = NSTextField(string: "")
    private let projectCrumb = HeaderCrumb(symbolName: "folder")
    private let slash = HeaderCrumb.separator("/")
    private let branchCrumb = HeaderCrumb(symbolName: "arrow.triangle.branch")
    private let dot = HeaderCrumb.separator("·")
    /// "worktree" / "local checkout", or the directory outside a repository.
    private let placeCrumb = HeaderCrumb(symbolName: "square.on.square.dashed")
    private let statusDot = HeaderCrumb.separator("·")
    private let statusCrumb = HeaderCrumb(symbolName: nil)
    private let containerCrumb = HeaderCrumb(symbolName: "shippingbox")
    /// The lineage strip (M3-A): "2 running · 1 needs you" (shows the Agents panel) or "Child of “…”" (opens the parent).
    private let agentsButton = DSButton(title: "", variant: .ghost, size: .small, symbolName: "point.3.connected.trianglepath.dotted")
    private var agentsIsChild = false
    /// Linked merge requests (M3-B): "#42 Open · ✓ Check passed"; shows the Merge Requests tab.
    private let mergeRequestButton = DSButton(title: "", variant: .ghost, size: .small, symbolName: "arrow.triangle.pull")
    /// Linked GitLab issues (GitLab 2): "#12 Launch checklist"; shows the Issues section.
    private let issueButton = DSButton(title: "", variant: .ghost, size: .small, symbolName: "smallcircle.circle")
    private var loop: ObservationLoop?
    private var editingOriginal: String?
    /// An editable field has no intrinsic width: the title takes its text's width (and truncates first when short).
    private lazy var titleWidth = titleField.widthAnchor.constraint(equalToConstant: 80)
    /// The plain-text summary read by VoiceOver (also the tests' view of the crumbs).
    private(set) var summary = ""

    init(context: ThreadSurfaceContext, onRename: @escaping (SessionID, String) -> Void) {
        self.context = context
        self.onRename = onRename
        super.init(frame: .zero)
        titleField.font = DS.TextRole.title.font
        titleField.textColor = DS.Color.text
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.isScrollable = true
        titleField.delegate = self
        titleField.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        titleField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        titleField.setAccessibilityLabel("Thread title")
        titleField.toolTip = "Click to rename"
        for button in [agentsButton, mergeRequestButton, issueButton] {
            button.isMuted = true
            button.target = self
            button.isHidden = true
            button.setContentCompressionResistancePriority(.init(230), for: .horizontal)
        }
        agentsButton.action = #selector(agentsStripClicked)
        mergeRequestButton.action = #selector(mergeRequestsClicked)
        issueButton.action = #selector(issuesClicked)
        placeCrumb.setContentCompressionResistancePriority(.init(235), for: .horizontal)
        containerCrumb.setContentCompressionResistancePriority(.init(225), for: .horizontal)
        let stack = NSStackView(views: [
            titleField, projectCrumb, slash, branchCrumb, dot, placeCrumb, statusDot, statusCrumb, containerCrumb, agentsButton,
            mergeRequestButton, issueButton,
        ])
        stack.spacing = DS.Space.s6
        stack.setCustomSpacing(DS.Space.s10, after: titleField)
        stack.alignment = .centerY
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Crumbs give way (truncate, then detach from the end) instead of drawing under Open and Commit.
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        for (index, view) in [containerCrumb, statusCrumb, statusDot, placeCrumb, dot].enumerated() {
            stack.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: Float(400 + index * 50)), for: view)
        }
        clipsToBounds = true
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: DS.Size.control),
        ])
        titleWidth.priority = .init(248)
        titleWidth.isActive = true
        titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { loop?.cancel() }

    private func render() {
        projectCrumb.text = context.projectName
        projectCrumb.toolTip = context.projectDirectory
        var status = ""
        if let thread = context.thread {
            titleField.isEditable = thread.session != nil
            if titleField.currentEditor() == nil {
                titleField.stringValue = thread.session?.displayTitle ?? ""
                titleField.placeholderString = "Thread"
            }
            if thread.phase == .deleted {
                status = "Deleted on the server"
            } else if let orchestration = context.engine.orchestration, let waiting = OrchestrationText.waitingStatus(orchestration, thread.sessionID) {
                // A thread whose own run ended while its children work is waiting, not done (M3-A).
                status = waiting
            }
            renderAgentsStrip(thread.sessionID)
            renderMergeRequests(thread.sessionID)
            renderIssues(thread.sessionID)
        } else {
            agentsButton.isHidden = true
            mergeRequestButton.isHidden = true
            issueButton.isHidden = true
            titleField.isEditable = false
            titleField.stringValue = "New Thread"
            status = context.isCreatingThread ? "Creating…" : "Draft, created when you send"
        }
        titleWidth.constant = ceil(DSDraw.width(of: titleField.stringValue, font: DS.TextRole.title.font)) + 6
        statusCrumb.text = status
        statusCrumb.isHidden = status.isEmpty
        statusDot.isHidden = status.isEmpty
        let repository = context.engine.git.repository(for: context.directory)
        let directory = (context.directory as NSString).abbreviatingWithTildeInPath
        if repository.phase == .notRepository || repository.status == nil {
            branchCrumb.isHidden = true
            dot.isHidden = true
            placeCrumb.symbolName = "folder"
            placeCrumb.text = directory
            placeCrumb.lineBreakMode = .byTruncatingMiddle
            slash.isHidden = directory.isEmpty
            placeCrumb.isHidden = directory.isEmpty
        } else {
            branchCrumb.text = Self.branchText(repository)
            branchCrumb.isHidden = false
            dot.isHidden = false
            slash.isHidden = false
            placeCrumb.symbolName = "square.on.square.dashed"
            placeCrumb.text = repository.workspaceKind == .worktree ? "worktree" : "local checkout"
            placeCrumb.lineBreakMode = .byTruncatingTail
            placeCrumb.isHidden = false
        }
        placeCrumb.toolTip = context.directory
        branchCrumb.toolTip = repository.status.map(\.accessibleSummary)
        let container = Self.containerText(context.engine.environments, directory: context.directory)
        containerCrumb.text = container
        containerCrumb.isHidden = container.isEmpty
        if let environment = context.engine.environments.isEnabled && !context.directory.isEmpty
            ? context.engine.environments.project(containing: context.directory) : nil {
            containerCrumb.symbolName = environment.mode.symbolName
        }
        summary = [
            titleField.stringValue, context.projectName, branchCrumb.isHidden ? nil : branchCrumb.text, placeCrumb.isHidden ? nil : placeCrumb.text,
            status.isEmpty ? nil : status, container.isEmpty ? nil : container, Self.gitText(repository).isEmpty ? nil : Self.gitText(repository),
        ].compactMap { $0 }.joined(separator: ", ")
        setAccessibilityLabel(summary)
    }

    /// "fix/parser-recovery ↑1" (the branch, or the detached head; ahead/behind as arrows with numbers).
    static func branchText(_ repository: GitRepositoryModel) -> String {
        guard let status = repository.status else { return "…" }
        var text = status.branch ?? status.head.map { "detached at \($0.prefix(7))" } ?? "…"
        if status.ahead > 0 { text += " ↑\(status.ahead)" }
        if status.behind > 0 { text += " ↓\(status.behind)" }
        return text
    }

    private func renderAgentsStrip(_ id: SessionID) {
        guard let orchestration = context.engine.orchestration, let strip = OrchestrationText.strip(orchestration, id) else {
            agentsButton.isHidden = true
            return
        }
        agentsIsChild = strip.isChild
        agentsButton.title = strip.text
        agentsButton.toolTip = strip.isChild ? "Go to the parent thread (⌃⌘U)" : "Show the Agents panel (⌃⌘A)"
        agentsButton.accessibilityTitle = strip.isChild ? "\(strip.text). Go to parent thread" : "\(strip.text). Show Agents"
        agentsButton.isHidden = false
    }

    private func renderMergeRequests(_ id: SessionID) {
        guard let service = context.engine.extras?.mergeRequests else { return }
        let links = service.links(for: id)
        guard let first = links.first else {
            mergeRequestButton.isHidden = true
            return
        }
        let snapshot = service.snapshots[first.ref.url]
        var title = MergeRequestText.chip(first, snapshot)
        if links.count > 1 { title += " +\(links.count - 1)" }
        mergeRequestButton.title = title
        mergeRequestButton.symbolName = snapshot?.state.symbolName ?? "arrow.triangle.pull"
        mergeRequestButton.toolTip = links.map { MergeRequestText.accessibility($0, service.snapshots[$0.ref.url]) }.joined(separator: "\n")
            + "\nShow the Merge Requests panel"
        mergeRequestButton.accessibilityTitle = (links.map { MergeRequestText.accessibility($0, service.snapshots[$0.ref.url]) }.joined(separator: "; "))
        mergeRequestButton.isHidden = false
    }

    @objc private func mergeRequestsClicked() { context.onShowMergeRequests?() }

    private func renderIssues(_ id: SessionID) {
        guard let issues = context.engine.extras?.gitLabWork.issues(for: id), let first = issues.first else {
            issueButton.isHidden = true
            return
        }
        let title = first.title.count > 28 ? String(first.title.prefix(27)) + "…" : first.title
        issueButton.title = "#\(first.iid) \(title)" + (issues.count > 1 ? " +\(issues.count - 1)" : "")
        issueButton.toolTip = issues.map { "Issue \($0.reference): \($0.title)" }.joined(separator: "\n") + "\nShow the Issues panel"
        issueButton.accessibilityTitle = issues.map { "Linked issue \($0.reference): \($0.title)" }.joined(separator: "; ")
        issueButton.isHidden = false
    }

    @objc private func issuesClicked() { context.onShowIssues?() }

    /// The issue chip's text when shown (tests).
    var issueChipTitle: String? { issueButton.isHidden ? nil : issueButton.title }

    @objc private func agentsStripClicked() {
        guard let id = context.thread?.sessionID else { return }
        if agentsIsChild, let parent = context.engine.orchestration?.node(id)?.node.parentID {
            context.onOpenThread?(parent)
        } else {
            context.onShowAgents?()
        }
    }

    /// "Container: node:22 (Running)" while commands run in the project's container (M6-A); empty when off.
    static func containerText(_ service: EnvironmentService, directory: String) -> String {
        guard service.isEnabled, !directory.isEmpty, let environment = service.project(containing: directory) else { return "" }
        return executionText(environment)
    }

    /// "Shared workspace: base:1 (Running)", "Project container: node:22 (Stopped)", "Host docker only (Ready)": the
    /// execution mode, image and state in words.
    static func executionText(_ environment: ProjectEnvironment) -> String {
        switch environment.mode {
        case .hostDocker: "Host docker only (\(environment.phase == .ready ? "Ready" : environment.phase.label))"
        case .sharedWorkspace: "Shared workspace: \(environment.image ?? "no image") (\(environment.phase.label))"
        case .projectContainer: "Project container: \(environment.image ?? "no image") (\(environment.phase.label))"
        }
    }

    /// "⎇ main · Local checkout · 3 changed ↑2" (words, not colour; empty outside a repository).
    static func gitText(_ repository: GitRepositoryModel) -> String {
        guard repository.phase != .notRepository else { return "" }
        var parts: [String] = []
        if let status = repository.status {
            parts.append(status.branch.map { "⎇ " + $0 } ?? status.head.map { "Detached at \($0.prefix(7))" } ?? "⎇ …")
        }
        parts.append(repository.workspaceKind.label)
        if let status = repository.status {
            var state = status.files.isEmpty ? "clean" : "\(status.files.count) changed"
            if status.ahead > 0 { state += " ↑\(status.ahead)" }
            if status.behind > 0 { state += " ↓\(status.behind)" }
            parts.append(state)
        }
        return parts.joined(separator: " · ")
    }

    /// Begins editing the title (Rename Thread from the menu while the content area is focused).
    func beginEditingTitle() {
        guard titleField.isEditable else { return }
        window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    func controlTextDidBeginEditing(_ notification: Notification) { editingOriginal = titleField.stringValue }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            titleField.stringValue = editingOriginal ?? titleField.stringValue
            editingOriginal = nil
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        defer { editingOriginal = nil }
        guard let original = editingOriginal, let id = context.thread?.sessionID else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            titleField.stringValue = original
        } else if title != original {
            onRename(id, title)
        }
    }
}

/// One crumb of the thread header: a 12 pt glyph tinted `icon` and a `label text2` string, drawn in one pass.
@MainActor
final class HeaderCrumb: NSView {
    var symbolName: String? { didSet { if symbolName != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var text = "" { didSet { if text != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var color: NSColor = DS.Color.text2 { didSet { needsDisplay = true } }
    var lineBreakMode: NSLineBreakMode = .byTruncatingTail { didSet { needsDisplay = true } }
    /// `label` by default; the composer's context strip uses `meta`.
    var font: NSFont = DS.TextRole.label.font { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var glyphPointSize: CGFloat = DS.Size.iconPointRow { didSet { needsDisplay = true } }

    init(symbolName: String?) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.init(245), for: .horizontal)
    }

    /// A "/" or "·" between crumbs (`text4`).
    static func separator(_ text: String) -> HeaderCrumb {
        let crumb = HeaderCrumb(symbolName: nil)
        crumb.text = text
        crumb.color = DS.Color.text4
        crumb.setContentCompressionResistancePriority(.required, for: .horizontal)
        return crumb
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    private var glyphWidth: CGFloat { symbolName == nil ? 0 : glyphPointSize + 2 + DS.Space.s4 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(glyphWidth + DSDraw.width(of: text, font: font)), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let symbolName, let image = DSDraw.symbol(symbolName, pointSize: glyphPointSize) {
            DSDraw.draw(template: image, in: NSRect(x: 0, y: 0, width: glyphPointSize + 2, height: bounds.height), color: DS.Color.icon)
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = lineBreakMode
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let height = ceil(font.ascender - font.descender)
        string.draw(
            with: NSRect(x: glyphWidth, y: (bounds.height - height) / 2, width: bounds.width - glyphWidth, height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
