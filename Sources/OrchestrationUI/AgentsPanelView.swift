import AppKit
import BelloCore
import DesignSystem
import Engine
import SwiftUI

/// The tint of a task state. Status is never colour-only: every use shows the symbol and the label too.
public enum TaskStatusStyle {
    public static func tone(_ status: ChildTaskStatus) -> DS.Tone {
        switch status {
        case .needsApproval, .needsAnswer: .warning
        case .failed: .danger
        case .running, .waitingOnChildren, .stopping: .info
        case .done: .success
        case .stopped, .idle, .unknown: .neutral
        }
    }

    public static func tint(_ status: ChildTaskStatus) -> NSColor {
        let tone = tone(status)
        return tone == .neutral ? DS.Color.text3 : DS.Color.tone(tone).text
    }

    /// Outline glyphs at the DS optical weight (no filled symbols, visual-language.md §5).
    public static func symbolName(_ status: ChildTaskStatus) -> String {
        switch status {
        case .running: "circle.dotted"
        case .waitingOnChildren: "pause.circle"
        case .needsApproval: "exclamationmark.shield"
        case .needsAnswer: "questionmark.bubble"
        case .failed: "exclamationmark.triangle"
        case .stopping, .stopped: "stop.circle"
        case .done: "checkmark"
        case .idle, .unknown: "circle"
        }
    }
}

/// Glyph plus label for a task state: the drawn spinner while running, an outline symbol otherwise.
public struct TaskStatusLabel: View {
    let status: ChildTaskStatus
    let showsText: Bool

    public init(_ status: ChildTaskStatus, showsText: Bool = true) {
        self.status = status
        self.showsText = showsText
    }

    public var body: some View {
        HStack(spacing: DS.Space.s6) {
            Group {
                if status == .running || status == .stopping {
                    StatusLabel(.running, showsText: false)
                } else {
                    Image(systemName: TaskStatusStyle.symbolName(status))
                        .font(.system(size: DS.Size.iconPointRow, weight: status == .done ? .semibold : .regular))
                        .foregroundStyle(SwiftUI.Color(nsColor: TaskStatusStyle.tint(status)))
                }
            }
            .frame(width: DS.Size.statusGlyph, height: DS.Size.statusGlyph)
            .accessibilityHidden(true)
            if showsText {
                Text(status.label)
                    .foregroundStyle(status.isBlocked || status == .failed ? SwiftUI.Color(nsColor: TaskStatusStyle.tint(status)) : SwiftUI.Color.ds.text3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label)
    }
}

/// The Agents panel (agents-dark.png): a summary line of pills, the lineage tree (status glyph, title, agent tag,
/// state word · elapsed · model, report box, guide lines, ghost actions on hover or selection) and the plugin footer.
/// Desktop density; no sheets; no animation.
public struct AgentsPanelView: View {
    let model: AgentsPanelModel

    public init(model: AgentsPanelModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            let created = model.createdThreads
            if let lineage = model.lineage, lineage.hasChildren || !created.isEmpty
                || model.orchestration.node(lineage.rootID)?.node.parentID != nil
            {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(lineage.rows) { row in
                            AgentRowView(model: model, row: row)
                        }
                        if !created.isEmpty {
                            Text(created.count == 1 ? "Created 1 thread" : "Created \(created.count) threads")
                                .font(.ds(.metaEmph)).foregroundStyle(SwiftUI.Color.ds.text3)
                                .padding(.horizontal, DS.Space.s12).padding(.top, DS.Space.s12).padding(.bottom, DS.Space.s4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(created, id: \.self) { id in
                                AgentRowView(model: model, row: LineageRow(id: id, depth: 1))
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.s8)
                    .padding(.vertical, DS.Space.s4)
                }
            } else {
                empty
            }
            footer
        }
        .font(.ds(.body))
        .foregroundStyle(SwiftUI.Color.ds.text)
        .background(SwiftUI.Color.ds.canvas)
        .transaction { $0.animation = nil }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s6) {
            if let lineage = model.lineage, lineage.aggregate.total > 0 {
                let aggregate = lineage.aggregate
                if aggregate.running > 0 { pill("\(aggregate.running) running", .info, spinner: true) }
                if aggregate.needsYou > 0 { pill("\(aggregate.needsYou) need\(aggregate.needsYou == 1 ? "s" : "") you", .warning) }
                if aggregate.failed > 0 { pill("\(aggregate.failed) failed", .danger) }
                if aggregate.running + aggregate.needsYou + aggregate.failed == 0 {
                    Text(aggregate.text).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
                }
            } else {
                Text("Agents").font(.ds(.labelEmph)).foregroundStyle(SwiftUI.Color.ds.text2)
            }
            Spacer(minLength: 0)
            if let error = model.errorMessage {
                HStack(spacing: DS.Space.s4) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(SwiftUI.Color.ds.dangerText)
                    Text(error).foregroundStyle(SwiftUI.Color.ds.text).lineLimit(1)
                }
                .font(.ds(.meta))
                .accessibilityElement(children: .combine)
            }
            if let id = model.threadID, model.orchestration.node(id)?.node.parentID != nil {
                Button("Back to Parent") { model.openParent() }
                    .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                    .help("Show the thread that started this one")
            }
        }
        .padding(.horizontal, DS.Space.s12)
        .frame(height: DS.Size.toolbar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.lineage.map { "Child agents: \($0.aggregate.text)" } ?? "Agents")
    }

    private func pill(_ text: String, _ tone: DS.Tone, spinner: Bool = false) -> some View {
        let colors = DS.Color.tone(tone)
        return HStack(spacing: DS.Space.s4) {
            if spinner { StatusLabel(.running, showsText: false).scaleEffect(0.86).frame(width: 12, height: 12) }
            Text(text).font(.ds(.metaEmph))
        }
        .foregroundStyle(SwiftUI.Color(nsColor: colors.text))
        .padding(.horizontal, DS.Space.s6)
        .frame(height: DS.Size.pill + 2)
        .background(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous).fill(SwiftUI.Color(nsColor: colors.surface)))
        .accessibilityElement(children: .combine)
    }

    private var empty: some View {
        VStack(spacing: DS.Space.s8) {
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 32)).foregroundStyle(SwiftUI.Color.ds.text4).accessibilityHidden(true)
            Text(model.threadID == nil ? "No thread yet" : "No child agents")
                .font(.ds(.body)).foregroundStyle(SwiftUI.Color.ds.text)
            Text(
                model.threadID == nil
                    ? "Send a first message. Work this thread delegates will appear here."
                    : "When this thread delegates work or creates threads, they appear here with their state."
            )
            .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2).multilineTextAlignment(.center).frame(maxWidth: 260)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Space.s16)
    }

    private var footer: some View {
        let ready = model.orchestration.pluginStatus.isReady
        return HStack(spacing: DS.Space.s6) {
            Image(systemName: ready ? "checkmark" : "exclamationmark.triangle")
                .font(.system(size: DS.Size.iconPointMeta, weight: ready ? .semibold : .regular))
                .foregroundStyle(ready ? SwiftUI.Color.ds.successText : SwiftUI.Color.ds.warningText)
                .accessibilityHidden(true)
            Text(model.orchestration.pluginStatus.label).foregroundStyle(SwiftUI.Color.ds.text3).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.ds(.meta))
        .padding(.horizontal, DS.Space.s12)
        .frame(height: DS.Size.terminalTabStrip)
        .overlay(alignment: .top) { SwiftUI.Color.ds.border.frame(height: 1) }
    }
}

/// One node: indent by depth with guide lines, glyph, title (`bodyEmph`), agent tag pill, state word · time · model
/// (`meta text3`, the word in its tone when blocked or failed), a report box, and ghost actions shown on hover or
/// selection (always present for VoiceOver and keyboard). The current thread and the selection use `rowActive`.
struct AgentRowView: View {
    let model: AgentsPanelModel
    let row: LineageRow
    @StateObject private var hover = HoverBox()

    static let indent: CGFloat = 28

    var body: some View {
        if let nodeModel = model.orchestration.node(row.id) {
            content(nodeModel.node)
        }
    }

    @ViewBuilder
    private func content(_ node: TaskNode) -> some View {
        let isCurrent = node.id == model.threadID
        let isSelected = node.id == (model.selection ?? model.threadID)
        let depth = CGFloat(min(row.depth, 6))
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: DS.Space.s8) {
                TaskStatusLabel(node.status, showsText: false)
                Text(node.title)
                    .font(.ds(.bodyEmph))
                    .foregroundStyle(SwiftUI.Color.ds.text)
                    .lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                if let agent = node.agent, node.parentID != nil { DSPillView("@" + agent).fixedSize() }
                if node.inWorktree { DSPillView("Worktree", symbolName: "square.on.square.dashed").fixedSize() }
                Spacer(minLength: DS.Space.s8)
                actions(node, isCurrent: isCurrent)
                    .opacity(hover.isHovered || isSelected || node.status.isBlocked || node.status == .failed ? 1 : 0)
            }
            HStack(spacing: DS.Space.s4) {
                Text(node.status.label)
                    .foregroundStyle(node.status.isBlocked || node.status == .failed
                        ? SwiftUI.Color(nsColor: TaskStatusStyle.tint(node.status)) : SwiftUI.Color.ds.text3)
                timing(node)
                if let model = node.model {
                    Text("· " + model.modelID + (model.variant.map { " " + $0 } ?? "")).foregroundStyle(SwiftUI.Color.ds.text3)
                }
                if node.kind != .thread { Text("· " + node.kind.label.lowercased()).foregroundStyle(SwiftUI.Color.ds.text3) }
            }
            .font(.ds(.meta))
            .lineLimit(1)
            .padding(.leading, DS.Size.statusGlyph + DS.Space.s8)
            if let summary = node.summary, !node.status.isActive || node.ownStatus == .done {
                Text(summary)
                    .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2)
                    .lineLimit(3).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.s10).padding(.vertical, DS.Space.s8)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(SwiftUI.Color.ds.fillSubtle))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(SwiftUI.Color.ds.border))
                    .padding(.leading, DS.Size.statusGlyph + DS.Space.s8)
                    .padding(.top, DS.Space.s4)
            }
            if model.followUpTarget == node.id { followUpField(node) }
        }
        .padding(.vertical, DS.Space.s6)
        .padding(.horizontal, DS.Space.s8)
        .dsRowBackground(isSelected || isCurrent ? .active : (hover.isHovered ? .hover : .rest), radius: DS.Radius.md)
        .padding(.leading, depth * Self.indent)
        .overlay(alignment: .topLeading) {
            // One 1 pt `border` guide per ancestor level, at the parent's glyph centre.
            if row.depth > 0 {
                ZStack(alignment: .topLeading) {
                    ForEach(0..<Int(depth), id: \.self) { level in
                        Rectangle().fill(SwiftUI.Color.ds.border).frame(width: 1)
                            .padding(.leading, CGFloat(level) * Self.indent + DS.Space.s8 + DS.Size.statusGlyph / 2)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover.isHovered = $0 }
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
                    .foregroundStyle(SwiftUI.Color.ds.text3)
            }
        } else {
            Text("· " + RelativeTime.short(node.since.date)).foregroundStyle(SwiftUI.Color.ds.text3)
        }
    }

    @ViewBuilder
    private func actions(_ node: TaskNode, isCurrent: Bool) -> some View {
        HStack(spacing: DS.Space.s2) {
            if !isCurrent {
                Button(node.status.isBlocked ? "Review" : "Open") { model.open(node.id) }
                    .buttonStyle(DSButtonStyle(node.status.isBlocked ? .outline : .ghost, size: .small))
                    .help("Show this thread (Back returns)")
            }
            if node.parentID != nil || (node.kind == .created && !isCurrent) {
                Button("Follow Up") { model.beginFollowUp(node.id) }
                    .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                    .help("Send this child a follow-up message")
            }
            if model.canStop(node.id) {
                Button("Stop") { model.stop(node.id) }
                    .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                    .help("Stop this thread and every task below it")
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func followUpField(_ node: TaskNode) -> some View {
        HStack(spacing: DS.Space.s6) {
            TextField("Follow-up for “\(node.title)”", text: Bindable(model).followUpText)
                .textFieldStyle(DSTextFieldStyle())
                .onSubmit { model.sendFollowUp() }
                .onExitCommand { model.cancelFollowUp() }
                .disabled(model.isSending)
            Button(model.isSending ? "Sending…" : "Send") { model.sendFollowUp() }
                .buttonStyle(DSButtonStyle(.primary, size: .small))
                .disabled(model.isSending || model.followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel") { model.cancelFollowUp() }
                .buttonStyle(DSButtonStyle(.ghost, size: .small))
        }
        .padding(.leading, DS.Size.statusGlyph + DS.Space.s8)
        .padding(.top, DS.Space.s4)
    }

    private func accessibilityText(_ node: TaskNode, isCurrent: Bool) -> String {
        var parts = [node.title, node.kind.label, node.status.label]
        if isCurrent { parts.append("shown") }
        if let summary = node.summary { parts.append(summary) }
        if let model = node.model { parts.append(model.modelID) }
        return parts.joined(separator: ", ")
    }
}

/// Row hover state (`@State` cannot compile here: no SwiftUI macro plugin with Command Line Tools).
@MainActor
final class HoverBox: ObservableObject {
    @Published var isHovered = false
}
