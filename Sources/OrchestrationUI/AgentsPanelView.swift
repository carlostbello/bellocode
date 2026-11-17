import AppKit
import BelloCore
import DesignSystem
import Engine
import SwiftUI

/// The tint of a task state. Status is never colour-only: every use shows the symbol and the label too.
public enum TaskStatusStyle {
    public static func tint(_ status: ChildTaskStatus) -> NSColor {
        switch status {
        case .needsApproval, .needsAnswer: DS.Palette.attention
        case .failed: DS.Palette.failure
        case .running, .waitingOnChildren, .stopping: DS.Palette.running
        case .done: DS.Palette.success
        case .stopped, .idle, .unknown: DS.Palette.neutral
        }
    }
}

/// Glyph plus label for a task state.
public struct TaskStatusLabel: View {
    let status: ChildTaskStatus
    let showsText: Bool

    public init(_ status: ChildTaskStatus, showsText: Bool = true) {
        self.status = status
        self.showsText = showsText
    }

    public var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: status.symbolName)
                .foregroundStyle(Color(nsColor: TaskStatusStyle.tint(status)))
                .frame(width: 13)
                .accessibilityHidden(true)
            if showsText {
                Text(status.label).foregroundStyle(status.isBlocked ? Color(nsColor: DS.Palette.attention) : .secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label)
    }
}

/// The Agents panel: the lineage tree of the displayed thread with state, last update, elapsed time and model per
/// node, and Open / Stop / Follow-up actions. Desktop density; no sheets; no animation.
public struct AgentsPanelView: View {
    let model: AgentsPanelModel

    public init(model: AgentsPanelModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let lineage = model.lineage, lineage.hasChildren || model.orchestration.node(lineage.rootID)?.node.parentID != nil {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lineage.rows) { row in
                            AgentRowView(model: model, row: row)
                        }
                    }
                    .padding(.vertical, DS.Spacing.xs)
                }
            } else {
                empty
            }
            Divider()
            footer
        }
        .font(.system(size: 12))
        .transaction { $0.animation = nil }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Text("Agents").font(.system(size: 12, weight: .semibold))
            if let lineage = model.lineage, !lineage.aggregate.text.isEmpty {
                Text(lineage.aggregate.text)
                    .foregroundStyle(lineage.aggregate.needsYou > 0 ? Color(nsColor: DS.Palette.attention) : .secondary)
                    .accessibilityLabel("Child agents: \(lineage.aggregate.text)")
            }
            Spacer(minLength: 0)
            if let id = model.threadID, model.orchestration.node(id)?.node.parentID != nil {
                Button("Back to Parent") { model.openParent() }
                    .buttonStyle(.link)
                    .help("Show the thread that started this one")
            }
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.m)
        .overlay(alignment: .bottomLeading) {
            if let error = model.errorMessage {
                Text(error).foregroundStyle(Color(nsColor: DS.Palette.failure)).font(.caption)
                    .padding(.horizontal, DS.Spacing.l).offset(y: 14)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: DS.Spacing.s) {
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 22)).foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(model.threadID == nil ? "No thread yet" : "No child agents")
                .font(.system(size: 13, weight: .medium))
            Text(
                model.threadID == nil
                    ? "Send a first message. Work this thread delegates will appear here."
                    : "When this thread delegates work or creates threads, they appear here with their state."
            )
            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 260)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.l)
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: model.orchestration.pluginStatus.isReady ? "checkmark.seal" : "exclamationmark.triangle")
                .foregroundStyle(model.orchestration.pluginStatus.isReady ? Color.secondary : Color(nsColor: DS.Palette.attention))
                .accessibilityHidden(true)
            Text(model.orchestration.pluginStatus.label).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
    }
}

/// One node: indent by depth, glyph + state words, title and kind, last meaningful update, elapsed and model, actions.
struct AgentRowView: View {
    let model: AgentsPanelModel
    let row: LineageRow

    var body: some View {
        if let nodeModel = model.orchestration.node(row.id) {
            content(nodeModel.node)
        }
    }

    @ViewBuilder
    private func content(_ node: TaskNode) -> some View {
        let isCurrent = node.id == model.threadID
        let isSelected = node.id == (model.selection ?? model.threadID)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                TaskStatusLabel(node.status, showsText: false)
                Text(node.title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1).truncationMode(.tail)
                if node.kind != .thread {
                    Text(node.kind.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: DS.Palette.groupFill)))
                }
                if node.inWorktree {
                    Text("Worktree").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Spacing.s)
                actions(node, isCurrent: isCurrent)
            }
            HStack(spacing: DS.Spacing.xs) {
                Text(node.status.label)
                    .foregroundStyle(node.status.isBlocked ? Color(nsColor: DS.Palette.attention) : .secondary)
                timing(node)
                if let model = node.model {
                    Text("· " + model.modelID + (model.variant.map { " " + $0 } ?? "")).foregroundStyle(.tertiary)
                }
                if let agent = node.agent, node.parentID != nil { Text("· @" + agent).foregroundStyle(.tertiary) }
            }
            .font(.system(size: 11))
            .padding(.leading, 19)
            if let summary = node.summary, !node.status.isActive || node.ownStatus == .done {
                Text(summary)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.tail)
                    .padding(.leading, 19)
            }
            if model.followUpTarget == node.id { followUpField(node) }
        }
        .padding(.vertical, DS.Spacing.s)
        .padding(.trailing, DS.Spacing.l)
        .padding(.leading, DS.Spacing.l + CGFloat(min(row.depth, 6)) * DS.Spacing.sidebarIndent)
        .background(isSelected ? Color(nsColor: DS.Palette.groupFill) : Color.clear)
        .overlay(alignment: .leading) {
            if row.depth > 0 {
                Rectangle().fill(Color(nsColor: DS.Palette.separator)).frame(width: 1)
                    .padding(.leading, DS.Spacing.l + CGFloat(min(row.depth, 6) - 1) * DS.Spacing.sidebarIndent + 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = node.id }
        .onTapGesture(count: 2) { model.open(node.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText(node, isCurrent: isCurrent))
    }

    @ViewBuilder
    private func timing(_ node: TaskNode) -> some View {
        if node.ownStatus == .running || node.ownStatus == .stopping, let started = node.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("· " + OrchestrationText.elapsed(from: started.date, to: context.date)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("· " + RelativeTime.short(node.since.date)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func actions(_ node: TaskNode, isCurrent: Bool) -> some View {
        HStack(spacing: DS.Spacing.s) {
            if !isCurrent {
                Button("Open") { model.open(node.id) }
                    .help("Show this thread (Back returns)")
            }
            if node.parentID != nil {
                Button("Follow Up") { model.beginFollowUp(node.id) }
                    .help("Send this child a follow-up message")
            }
            if model.canStop(node.id) {
                Button("Stop") { model.stop(node.id) }
                    .help("Stop this thread and every task below it")
            }
        }
        .buttonStyle(.link)
        .font(.system(size: 11))
    }

    private func followUpField(_ node: TaskNode) -> some View {
        HStack(spacing: DS.Spacing.s) {
            TextField("Follow-up for “\(node.title)”", text: Bindable(model).followUpText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.sendFollowUp() }
                .onExitCommand { model.cancelFollowUp() }
                .disabled(model.isSending)
            Button(model.isSending ? "Sending…" : "Send") { model.sendFollowUp() }
                .disabled(model.isSending || model.followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel") { model.cancelFollowUp() }
        }
        .font(.system(size: 11))
        .padding(.leading, 19)
        .padding(.top, 2)
    }

    private func accessibilityText(_ node: TaskNode, isCurrent: Bool) -> String {
        var parts = [node.title, node.kind.label, node.status.label]
        if isCurrent { parts.append("shown") }
        if let summary = node.summary { parts.append(summary) }
        if let model = node.model { parts.append(model.modelID) }
        return parts.joined(separator: ", ")
    }
}
