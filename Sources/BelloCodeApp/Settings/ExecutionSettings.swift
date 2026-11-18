import AppKit
import BelloCore
import ContainerKit
import DesignSystem
import Engine
import SwiftUI

// Settings ▸ Containers ▸ Code roots and Execution, and the per-project mode picker (docs/features/containers.md,
// "Execution modes").

/// Settings ▸ Containers ▸ Code roots: the folders the shared workspace mounts and the policy layer trusts.
struct CodeRootsSettingsView: View {
    let service: EnvironmentService
    @StateObject private var box = MessageBox()
    private var message: String? { box.message }

    var body: some View {
        let roots = service.configuredCodeRoots
        let validation = service.codeRootsValidation
        if roots.isEmpty {
            SettingsRow("No code roots", detail: "Add the folder your repositories are in (for example ~/Documents/Repos). Projects in the shared workspace must be inside one.", divided: false) {
                DSPillView("None", tone: .warning, symbolName: "exclamationmark.triangle")
            }
        }
        ForEach(Array(roots.enumerated()), id: \.element) { index, path in
            let standardized = CodeRoots.standardize(path)
            let issues = validation.issues.filter { $0.path == standardized || $0.path == (CodeRoots.canonical(standardized) ?? standardized) }
            let blocking = issues.first(where: \.isBlocking)
            SettingsRow(CodeRoots.display(standardized), detail: (blocking ?? issues.first)?.message, divided: index > 0) {
                HStack(spacing: DS.Space.s6) {
                    if let blocking {
                        DSPillView(Self.label(blocking.kind), tone: .danger, symbolName: "xmark.octagon")
                        if let suggestion = blocking.suggestion, !service.codeRootsLocked {
                            Button("Use Real Path") { replace(path, with: suggestion) }.buttonStyle(DSButtonStyle(.outline, size: .small))
                        }
                    } else if let link = issues.first(where: { $0.kind == .notCanonical }), let real = link.suggestion {
                        DSPillView("Uses \(CodeRoots.display(real))", tone: .info, symbolName: "arrow.turn.down.right")
                    } else if issues.contains(where: { $0.kind == .overlaps }) {
                        DSPillView("Inside another root", tone: .neutral, symbolName: "arrow.turn.down.right")
                    } else {
                        DSPillView("Mounted", tone: .success, symbolName: "checkmark")
                    }
                    if !service.codeRootsLocked {
                        Button("Remove") { remove(path) }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                            .accessibilityLabel("Remove code root \(CodeRoots.display(standardized))")
                    }
                }
            }
        }
        if service.codeRootsLocked {
            SettingsRow("Set by your organisation", detail: service.managedExecution?.source, divided: true) {
                DSPillView("Managed", tone: .info, symbolName: "building.2")
            }
        } else {
            SettingsActionsRow {
                Button("Add Folder…") { addFolder() }.buttonStyle(DSButtonStyle(.outline, size: .small))
                let suggestion = suggestion
                if !suggestion.isEmpty, Set(suggestion) != Set(service.codeRootsValidation.roots) {
                    Button("Use Suggestion: \(suggestion.map { CodeRoots.display($0) }.joined(separator: ", "))") {
                        Task { await service.setCodeRoots(suggestion) }
                    }
                    .buttonStyle(DSButtonStyle(.ghost, size: .small))
                }
                if service.codeRootsSource == .suggested {
                    Text("Suggested from where your projects live").font(.ds(.meta)).foregroundStyle(Color.ds.text3)
                }
            }
        }
        if let message { SettingsNote(message) }
    }

    private var suggestion: [String] {
        CodeRoots.suggestion(projectDirectories: service.environments.map(\.directory))
    }

    static func label(_ kind: CodeRootIssue.Kind) -> String {
        switch kind {
        case .notAbsolute: "Not a full path"
        case .missing: "Missing"
        case .notDirectory: "Not a folder"
        case .notCanonical: "Link"
        case .systemLocation: "System location"
        case .wholeHome: "Home folder"
        case .sensitive: "Holds credentials"
        case .overlaps: "Inside another root"
        case .notShared: "Not shared with Rancher"
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Code Root"
        panel.message = "Choose the folder your repositories are in. The shared workspace mounts it read-write at the same path."
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map(\.path)
        let issues = added.flatMap { CodeRoots.issues(for: $0) }.filter(\.isBlocking)
        box.message = issues.isEmpty ? nil : issues.map(\.message).joined(separator: " ")
        Task { await service.setCodeRoots(service.configuredCodeRoots + added) }
    }

    private func remove(_ path: String) {
        let previous = service.configuredCodeRoots
        Task { await service.setCodeRoots(previous.filter { $0 != path }) }
        box.message = "Removed \(CodeRoots.display(CodeRoots.standardize(path))). The shared workspace is recreated without it on its next use."
    }

    private func replace(_ path: String, with canonical: String) {
        Task { await service.setCodeRoots(service.configuredCodeRoots.map { $0 == path ? canonical : $0 }) }
    }
}

/// Settings ▸ Containers ▸ Execution: the default mode for projects that have not chosen one.
struct DefaultExecutionModeView: View {
    let service: EnvironmentService

    var body: some View {
        let modes = ExecutionMode.allCases.filter(service.isAllowed)
        ForEach(Array(modes.enumerated()), id: \.element) { index, mode in
            ExecutionModeRow(mode: mode, selected: service.defaultMode == mode, recommended: mode == .defaultMode,
                             enabled: service.managedExecution?.defaultMode == nil, divided: index > 0) {
                Task { await service.setDefaultMode(mode) }
            }
        }
        if service.managedExecution?.defaultMode != nil {
            SettingsRow("Default set by your organisation", detail: service.managedExecution?.source, divided: true) {
                DSPillView("Managed", tone: .info, symbolName: "building.2")
            }
        }
    }
}

/// One mode as a radio row with its explanation.
struct ExecutionModeRow: View {
    let mode: ExecutionMode
    let selected: Bool
    var recommended = false
    var enabled = true
    var divided = true
    var detail: String?
    /// Replaces the mode's title (the "follow the default" row).
    var title: String?
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: DS.Space.s8) {
                DSToggleMark(kind: .radio, isOn: selected).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.s6) {
                        Image(systemName: mode.symbolName).font(.system(size: 11)).foregroundStyle(Color.ds.text2)
                        Text(title ?? mode.title).font(.ds(.bodyEmph)).foregroundStyle(Color.ds.text)
                        if recommended { DSPillView("Default", tone: .info) }
                        if mode == .hostDocker { DSPillView("Weaker", tone: .warning, symbolName: "exclamationmark.triangle") }
                    }
                    Text(detail ?? mode.explanation).font(.ds(.meta)).foregroundStyle(Color.ds.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.s12)
            .padding(.vertical, DS.Space.s8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .overlay(alignment: .top) {
            if divided { Rectangle().fill(Color.ds.border).frame(height: 1).padding(.leading, DS.Space.s12) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title ?? mode.title). \(detail ?? mode.explanation)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A transient note shown under a settings group (SwiftUI's `@State` macro is unavailable with Command Line Tools).
@MainActor
final class MessageBox: ObservableObject {
    @Published var message: String?
}

/// Project Settings ▸ Environment ▸ Where commands run: the project's mode (or the default), each with what it does;
/// a change applies at once, says what it changed and can be undone.
struct ExecutionModePickerView: View {
    let service: EnvironmentService
    let environment: ProjectEnvironment
    @StateObject private var box = UndoBox()

    var body: some View {
        let chosen = environment.settings.executionMode
        ExecutionModeRow(mode: service.defaultMode, selected: chosen == nil, divided: false,
                         detail: "Follows Settings ▸ Containers ▸ Execution, which is \(service.defaultMode.title) now.",
                         title: "App default: \(service.defaultMode.title)") {
            choose(nil)
        }
        ForEach(ExecutionMode.allCases.filter(service.isAllowed), id: \.self) { mode in
            ExecutionModeRow(mode: mode, selected: chosen == mode, recommended: false) { choose(mode) }
        }
        if environment.mode == .sharedWorkspace {
            SettingsRow("Code roots", detail: service.codeRootsValidation.roots.map { CodeRoots.display($0) }.joined(separator: ", "), divided: true) {
                DSPillView(environment.phase.label, tone: environment.phase.tone.ds, symbolName: environment.phase.symbolName)
            }
        }
        if let message = box.message {
            SettingsActionsRow {
                Text(message).font(.ds(.meta)).foregroundStyle(Color.ds.text2).fixedSize(horizontal: false, vertical: true)
                if let undo = box.undo {
                    Button("Undo") {
                        box.message = nil
                        box.undo = nil
                        Task { await service.setMode(undo.mode, for: environment.directory) }
                    }
                    .buttonStyle(DSButtonStyle(.outline, size: .small))
                }
            }
        }
    }

    private func choose(_ mode: ExecutionMode?) {
        let previous = environment.settings.executionMode
        guard previous != mode else { return }
        let effective = mode ?? service.defaultMode
        box.message = "Now: \(effective.title). \(effective.switchEffect)"
        box.undo = .init(mode: previous)
        Task { await service.setMode(mode, for: environment.directory) }
    }
}

@MainActor
final class UndoBox: ObservableObject {
    struct Undo { var mode: ExecutionMode? }
    @Published var message: String?
    @Published var undo: Undo?
}

/// Docker requests BelloCode's endpoint refused for this environment (newest first): what was asked and why.
struct DockerRefusalsView: View {
    let refusals: [DockerFilterProxy.Refusal]

    var body: some View {
        if refusals.isEmpty {
            SettingsRow("No refused requests", detail: "docker inside the container talks to BelloCode's filtered endpoint; anything it refuses is listed here.", divided: false) {
                DSPillView("Filtered", tone: .success, symbolName: "checkmark.shield")
            }
        }
        ForEach(Array(refusals.reversed().prefix(5).enumerated()), id: \.offset) { index, refusal in
            SettingsRow("\(refusal.method) \(refusal.path)", detail: refusal.message.replacingOccurrences(of: "BelloCode refused this Docker request: ", with: ""),
                        divided: index > 0) {
                DSPillView("Refused", tone: .danger, symbolName: "hand.raised")
            }
        }
    }
}

/// Project Settings ▸ Environment ▸ Dev container (Project container mode, when the project has a devcontainer.json):
/// use it or not, what is refused or ignored and why, and the lifecycle commands to review before they run.
struct DevContainerSectionView: View {
    let service: EnvironmentService
    let environment: ProjectEnvironment
    let plan: DevContainerPlan

    var body: some View {
        let using = environment.settings.useDevContainer
        SettingsToggleRow("Use \(CodeRoots.display(plan.file.replacingOccurrences(of: environment.directory + "/", with: "")))",
                          detail: plan.isUsable ? (plan.image.map { "Image \($0)" } ?? "Built from \((plan.build?.dockerfile ?? "") .replacingOccurrences(of: environment.directory + "/", with: "")) with Rancher Desktop's docker buildx")
                              : "Cannot be used until the refused settings below are removed; the project's own image is used meanwhile.",
                          divided: false,
                          isOn: Binding(get: { using }, set: { value in
                              var settings = environment.settings
                              settings.useDevContainer = value
                              Task { await service.update(environment.directory, settings: settings) }
                          }))
        ForEach(plan.refused, id: \.self) { refusal in
            SettingsRow(refusal.key, detail: refusal.reason) { DSPillView("Refused", tone: .danger, symbolName: "hand.raised") }
        }
        if !plan.ignored.isEmpty {
            SettingsRow("Ignored: \(plan.ignored.joined(separator: ", "))", detail: "Editor and host settings have no effect here.") {
                DSPillView("Ignored", tone: .neutral, symbolName: "minus.circle")
            }
        }
        let details = [plan.remoteUser.map { "user \($0)" }, plan.forwardPorts.isEmpty ? nil : "forwards \(plan.forwardPorts.map(String.init).joined(separator: ", "))",
                       (plan.containerEnv.count + plan.remoteEnv.count) > 0 ? "\(plan.containerEnv.count + plan.remoteEnv.count) variables" : nil].compactMap { $0 }
        if !details.isEmpty {
            SettingsRow("Applied", detail: details.joined(separator: " · ")) { DSPillView("Supported", tone: .success, symbolName: "checkmark") }
        }
        if let digest = plan.lifecycleDigest {
            let approved = environment.settings.approvedDevLifecycle == digest
            SettingsRow("Lifecycle commands", detail: [plan.postCreate.map { "After create: \($0)" }, plan.postStart.map { "After start: \($0)" }].compactMap { $0 }.joined(separator: "\n")) {
                if approved {
                    DSPillView("Reviewed", tone: .success, symbolName: "checkmark")
                } else {
                    Button("Approve and Run on Next Start") { Task { await service.approveDevLifecycle(environment.directory) } }
                        .buttonStyle(DSButtonStyle(.outline, size: .small))
                        .help("These commands come from the repository. They run inside the container, as shown, until the file changes.")
                }
            }
        }
    }
}
