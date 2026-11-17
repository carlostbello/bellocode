import AppKit
import BelloCore
import DesignSystem
import Engine
import OrchestrationUI

/// The thread header: title (editable in place: click, type, Return; Escape cancels), then
/// "project › directory · status" so the user always sees where an agent acts (AGENTS.md UX rule 6).
@MainActor
final class ThreadHeaderView: NSView, NSTextFieldDelegate {
    private let context: ThreadSurfaceContext
    private let onRename: (SessionID, String) -> Void
    let titleField = NSTextField(string: "")
    private let monogram = MonogramView()
    private let projectLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let statusImage = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    /// "⎇ feature/x · Worktree · 3 changed ↑1" (M2-C), refreshed with the repository's status.
    private let gitLabel = NSTextField(labelWithString: "")
    private let gitDot = NSTextField(labelWithString: "·")
    /// The lineage strip (M3-A): "Agents · 2 running · 1 needs you" (shows the Agents panel) or "Child of “…”" (opens
    /// the parent). Hidden without lineage.
    private let agentsButton = NSButton(title: "", target: nil, action: nil)
    private var agentsIsChild = false
    /// Linked pull requests (M3-B): "#42 Open · ✓ Check passed"; shows the Pull Requests tab.
    private let pullRequestButton = NSButton(title: "", target: nil, action: nil)
    private var loop: ObservationLoop?
    private var editingOriginal: String?

    init(context: ThreadSurfaceContext, onRename: @escaping (SessionID, String) -> Void) {
        self.context = context
        self.onRename = onRename
        super.init(frame: .zero)
        let typography = DS.Typography.current
        titleField.font = typography.title
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.isScrollable = true
        titleField.delegate = self
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setAccessibilityLabel("Thread title")
        titleField.toolTip = "Click to rename"
        for label in [projectLabel, pathLabel, statusLabel, gitLabel] {
            label.font = typography.caption
            label.textColor = DS.Palette.secondaryText
            label.lineBreakMode = .byTruncatingMiddle
        }
        projectLabel.font = .systemFont(ofSize: typography.caption.pointSize, weight: .medium)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusImage.setContentHuggingPriority(.required, for: .horizontal)

        let separator = NSTextField(labelWithString: "›")
        separator.textColor = DS.Palette.tertiaryText
        separator.font = typography.caption
        let dot = NSTextField(labelWithString: "·")
        dot.textColor = DS.Palette.tertiaryText
        dot.font = typography.caption
        gitDot.stringValue = "·"
        gitDot.textColor = DS.Palette.tertiaryText
        gitDot.font = typography.caption
        gitLabel.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        agentsButton.isBordered = false
        agentsButton.font = typography.caption
        agentsButton.contentTintColor = DS.Palette.accent
        agentsButton.target = self
        agentsButton.action = #selector(agentsStripClicked)
        agentsButton.setContentCompressionResistancePriority(.init(230), for: .horizontal)
        agentsButton.isHidden = true
        pullRequestButton.isBordered = false
        pullRequestButton.font = typography.caption
        pullRequestButton.contentTintColor = DS.Palette.accent
        pullRequestButton.target = self
        pullRequestButton.action = #selector(pullRequestsClicked)
        pullRequestButton.imagePosition = .imageLeading
        pullRequestButton.setContentCompressionResistancePriority(.init(220), for: .horizontal)
        pullRequestButton.isHidden = true
        let contextLine = NSStackView(views: [
            monogram, projectLabel, separator, pathLabel, dot, statusImage, statusLabel, gitDot, gitLabel, agentsButton,
            pullRequestButton,
        ])
        contextLine.spacing = DS.Spacing.xs
        contextLine.setCustomSpacing(DS.Spacing.s, after: monogram)
        let stack = NSStackView(views: [titleField, contextLine])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Spacing.xxs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.xl),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Spacing.xl),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: DS.Spacing.m),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DS.Spacing.m),
            titleField.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2 * DS.Spacing.xl),
        ])
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { loop?.cancel() }

    private func render() {
        projectLabel.stringValue = context.projectName
        monogram.name = context.projectName
        pathLabel.stringValue = (context.directory as NSString).abbreviatingWithTildeInPath
        pathLabel.toolTip = context.directory
        if let thread = context.thread {
            titleField.isEditable = thread.session != nil
            if titleField.currentEditor() == nil {
                titleField.stringValue = thread.session?.displayTitle ?? ""
                titleField.placeholderString = "Thread"
            }
            let status = thread.status?.status ?? (thread.isRunning ? .running : .idle)
            let glyph = StatusGlyph(status)
            statusImage.image = glyph.image(pointSize: 10)
            statusImage.isHidden = false
            statusLabel.stringValue = thread.phase == .deleted ? "Deleted on the server" : glyph.label
            // A thread whose own run ended while its children work is waiting, not done (M3-A).
            if let orchestration = context.engine.orchestration, thread.phase != .deleted,
                let waiting = OrchestrationText.waitingStatus(orchestration, thread.sessionID)
            {
                statusLabel.stringValue = waiting
                statusImage.image = NSImage(systemSymbolName: ChildTaskStatus.waitingOnChildren.symbolName, accessibilityDescription: waiting)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [DS.Palette.running])))
            }
            renderAgentsStrip(thread.sessionID)
            renderPullRequests(thread.sessionID)
        } else {
            agentsButton.isHidden = true
            pullRequestButton.isHidden = true
            titleField.isEditable = false
            titleField.stringValue = "New Thread"
            statusImage.isHidden = true
            statusLabel.stringValue = context.isCreatingThread ? "Creating…" : "Draft — created when you send"
        }
        let repository = context.engine.git.repository(for: context.directory)
        gitLabel.stringValue = Self.gitText(repository)
        gitDot.isHidden = gitLabel.stringValue.isEmpty
        gitLabel.isHidden = gitLabel.stringValue.isEmpty
        gitLabel.toolTip = repository.status.map(\.accessibleSummary)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(
            "\(titleField.stringValue), \(context.projectName), \(pathLabel.stringValue), \(statusLabel.stringValue), \(gitLabel.stringValue)")
    }

    private func renderAgentsStrip(_ id: SessionID) {
        guard let orchestration = context.engine.orchestration, let strip = OrchestrationText.strip(orchestration, id) else {
            agentsButton.isHidden = true
            return
        }
        agentsIsChild = strip.isChild
        agentsButton.title = "· " + strip.text
        agentsButton.toolTip = strip.isChild ? "Go to the parent thread (⌃⌘U)" : "Show the Agents panel (⌃⌘A)"
        agentsButton.setAccessibilityLabel(strip.isChild ? "\(strip.text). Go to parent thread" : "\(strip.text). Show Agents")
        agentsButton.isHidden = false
    }

    private func renderPullRequests(_ id: SessionID) {
        guard let service = context.engine.extras?.pullRequests else { return }
        let links = service.links(for: id)
        guard let first = links.first else {
            pullRequestButton.isHidden = true
            return
        }
        let snapshot = service.snapshots[first.ref.url]
        var title = "· " + PullRequestText.chip(first, snapshot)
        if links.count > 1 { title += " +\(links.count - 1)" }
        pullRequestButton.title = title
        pullRequestButton.image = NSImage(systemSymbolName: snapshot?.state.symbolName ?? "arrow.triangle.pull", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        pullRequestButton.toolTip = links.map { PullRequestText.accessibility($0, service.snapshots[$0.ref.url]) }.joined(separator: "\n")
            + "\nShow the Pull Requests panel"
        pullRequestButton.setAccessibilityLabel(links.map { PullRequestText.accessibility($0, service.snapshots[$0.ref.url]) }.joined(separator: "; "))
        pullRequestButton.isHidden = false
    }

    @objc private func pullRequestsClicked() { context.onShowPullRequests?() }

    @objc private func agentsStripClicked() {
        guard let id = context.thread?.sessionID else { return }
        if agentsIsChild, let parent = context.engine.orchestration?.node(id)?.node.parentID {
            context.onOpenThread?(parent)
        } else {
            context.onShowAgents?()
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
