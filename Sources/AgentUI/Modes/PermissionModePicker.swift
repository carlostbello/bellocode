import AppKit
import BelloCore
import Engine
import SwiftUI

/// What a permission mode allows, in plain words. The rules behind each are `PermissionModeRules` (verified on
/// opencode 2.3.0; see docs/features/agent-ui.md).
public struct PermissionModeOption: Hashable, Sendable, Identifiable {
    public var mode: PermissionMode
    public var title: String
    public var shortTitle: String
    public var symbolName: String
    /// One line: what runs without asking.
    public var allows: String
    /// One line: what still asks or is refused.
    public var asks: String

    public var id: PermissionMode { mode }

    public static let all: [PermissionModeOption] = [
        PermissionModeOption(
            mode: .ask, title: "Ask every time", shortTitle: "Ask", symbolName: "hand.raised",
            allows: "Reads and searches inside the project run without asking.",
            asks: "Asks before every edit, every command and anything outside the project; .env files ask."),
        PermissionModeOption(
            mode: .autoEdit, title: "Auto-accept edits", shortTitle: "Auto-edit", symbolName: "pencil.and.outline",
            allows: "File edits and reads inside the project run without asking.",
            asks: "Asks before every command and anything outside the project; .env files ask."),
        PermissionModeOption(
            mode: .fullAccess, title: "Full access", shortTitle: "Full access", symbolName: "lock.open",
            allows: "Edits, commands, folders outside the project, .env files and web access run without asking.",
            asks: "Nothing asks. The plan agent still cannot edit files."),
    ]

    public static func option(_ mode: PermissionMode) -> PermissionModeOption { all.first { $0.mode == mode }! }

    /// A thread with no BelloCode mode uses opencode's agent defaults.
    public static let unset = (
        title: "opencode default", shortTitle: "Default", symbolName: "slider.horizontal.3",
        detail: "No mode set: the build agent edits and runs commands without asking; .env files ask.")
}

/// The thread state the controls read and the commands they call. `ThreadModel` conforms.
@MainActor
public protocol AgentModeSource: AnyObject {
    var session: Session? { get }
    var lastError: EngineError? { get }
    func setPermissionMode(_ mode: PermissionMode) async
    func setAgent(_ agent: String) async
    func setModel(_ model: ModelSelection) async
}

extension ThreadModel: AgentModeSource {}

/// Compact permission-mode control for the composer's controls bar: icon and text label (never colour only), a
/// popover with each mode's plain description, and the build/plan agent switch.
public struct PermissionModePicker: View {
    @Environment(\.agentUIStyle) private var style
    let source: any AgentModeSource
    /// Primary agents to offer (from the catalog); `build` and `plan` when empty.
    let agents: [AgentEntry]
    @StateObject private var isOpen = ViewState(false)
    @StateObject private var pending = ViewState<PermissionMode?>(nil)
    @StateObject private var highlighted = ViewState(PermissionMode.ask)

    public init(source: any AgentModeSource, agents: [AgentEntry] = []) {
        self.source = source
        self.agents = agents
    }

    private var current: PermissionMode? { pending.value ?? source.session?.permissionMode }

    public var body: some View {
        Button {
            highlighted.value = current ?? .ask
            isOpen.value.toggle()
        } label: {
            HStack(spacing: 4) {
                if let current {
                    let option = PermissionModeOption.option(current)
                    Image(systemName: option.symbolName)
                    Text(option.shortTitle)
                } else {
                    Image(systemName: PermissionModeOption.unset.symbolName)
                    Text(PermissionModeOption.unset.shortTitle)
                }
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(style.secondaryText)
            }
            .font(style.smallFont)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.permissionMode)
        .help("Permission mode (\(AgentShortcut.permissionMode.display))")
        .accessibilityLabel("Permission mode")
        .accessibilityValue(current.map { PermissionModeOption.option($0).title } ?? PermissionModeOption.unset.title)
        .popover(isPresented: $isOpen.value, arrowEdge: .top) {
            PermissionModePopover(
                current: current, agent: source.session?.agent, agents: agents, highlighted: $highlighted.value,
                choose: { mode in
                    isOpen.value = false
                    apply(mode)
                },
                chooseAgent: { agent in
                    isOpen.value = false
                    Task { await source.setAgent(agent) }
                })
        }
    }

    private func apply(_ mode: PermissionMode) {
        guard mode != source.session?.permissionMode else { return }
        pending.value = mode
        Task {
            await source.setPermissionMode(mode)
            // The engine applied it optimistically and rolled back on failure; show the server's state from here on.
            pending.value = nil
        }
    }
}

struct PermissionModePopover: View {
    @Environment(\.agentUIStyle) private var style
    let current: PermissionMode?
    let agent: String?
    let agents: [AgentEntry]
    @Binding var highlighted: PermissionMode
    let choose: (PermissionMode) -> Void
    let chooseAgent: (String) -> Void
    @FocusState private var focused: Bool

    private var agentChoices: [(id: String, name: String, detail: String)] {
        let primary = agents.filter { !$0.hidden && $0.mode != .subagent }
        if primary.isEmpty {
            return [("build", "Build", "Can change files"), ("plan", "Plan", "Read-only: plans before changing anything")]
        }
        return primary.map { entry in
            let detail =
                entry.id == "plan" ? "Read-only: plans before changing anything"
                : entry.id == "build" ? "Can change files" : (entry.detail ?? "")
            return (entry.id, entry.name.capitalized, detail)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.spacing * 2) {
            Text("Permissions").font(style.smallFont.weight(.semibold)).foregroundStyle(style.secondaryText)
            VStack(spacing: 2) {
                ForEach(PermissionModeOption.all) { option in
                    row(option)
                }
            }
            if current == nil {
                Text(PermissionModeOption.unset.detail)
                    .font(style.smallFont).foregroundStyle(style.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Agent").font(style.smallFont.weight(.semibold)).foregroundStyle(style.secondaryText)
            HStack(spacing: style.spacing * 2) {
                ForEach(agentChoices, id: \.id) { choice in
                    Button {
                        chooseAgent(choice.id)
                    } label: {
                        Label(choice.name, systemImage: (agent ?? "build") == choice.id ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.borderless)
                    .help(choice.detail)
                    .accessibilityAddTraits((agent ?? "build") == choice.id ? .isSelected : [])
                }
            }
            .font(style.bodyFont)
            Text("Plan: \(AgentShortcut.togglePlan.display) toggles between plan and build.")
                .font(style.smallFont).foregroundStyle(style.secondaryText)
        }
        .padding(style.spacing * 3)
        .frame(width: 340)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.return) {
            choose(highlighted)
            return .handled
        }
        .noImplicitAnimation()
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let all = PermissionModeOption.all.map(\.mode)
        let index = all.firstIndex(of: highlighted) ?? 0
        highlighted = all[(index + delta + all.count) % all.count]
        return .handled
    }

    private func row(_ option: PermissionModeOption) -> some View {
        let selected = option.mode == current
        let isHighlighted = option.mode == highlighted
        return Button {
            choose(option.mode)
        } label: {
            HStack(alignment: .top, spacing: style.spacing * 2) {
                Image(systemName: option.symbolName).frame(width: 18).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(option.title).font(style.bodyFont.weight(.medium))
                        if selected { Image(systemName: "checkmark").foregroundStyle(style.accent).accessibilityHidden(true) }
                    }
                    Text(option.allows).font(style.smallFont).foregroundStyle(style.secondaryText)
                    Text(option.asks).font(style.smallFont).foregroundStyle(style.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, style.spacing * 2)
            .padding(.vertical, style.spacing * 1.5)
            .contentShape(Rectangle())
            .background(isHighlighted ? style.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = option.mode } }
        .accessibilityLabel(option.title)
        .accessibilityHint("\(option.allows) \(option.asks)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A one-click Plan/Build switch for the controls bar (⌥⌘P). Shows "Plan" with an icon when the plan agent is active.
public struct PlanModeToggle: View {
    @Environment(\.agentUIStyle) private var style
    let source: any AgentModeSource

    public init(source: any AgentModeSource) {
        self.source = source
    }

    public var body: some View {
        let isPlan = source.session?.agent == "plan"
        Button {
            Task { await source.setAgent(isPlan ? "build" : "plan") }
        } label: {
            Label(isPlan ? "Plan" : "Build", systemImage: isPlan ? "list.bullet.clipboard" : "hammer")
                .font(style.smallFont)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.togglePlan)
        .help(isPlan ? "Plan agent: read-only. Switch to build (\(AgentShortcut.togglePlan.display))"
              : "Build agent: can change files. Switch to plan (\(AgentShortcut.togglePlan.display))")
        .accessibilityLabel("Agent")
        .accessibilityValue(isPlan ? "Plan, read-only" : "Build")
    }
}
