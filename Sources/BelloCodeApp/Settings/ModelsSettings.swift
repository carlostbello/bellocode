import AgentUI
import AppKit
import BelloCore
import DesignSystem
import Engine
import SwiftUI

/// Settings ▸ Models (docs/features/models.md): one row per task, each the composer's model picker over the catalog of
/// connected providers. opencode's default and small model go to BelloCode's isolated `opencode.json` (then opencode
/// reloads); the reviewer, git writing and delegated-thread choices are BelloCode preferences.
@MainActor
@Observable
final class ModelsSettingsModel {
    @ObservationIgnored let engine: Engine
    @ObservationIgnored let auth: AuthService?
    @ObservationIgnored var onConnect: @MainActor (String?) -> Void
    /// Asks before something that cancels pending approvals (title, detail, button). Returns true to go ahead.
    @ObservationIgnored var confirm: @MainActor (String, String, String) -> Bool
    private(set) var message: String?
    /// The pane last built (snapshots, menu commands).
    static weak var last: ModelsSettingsModel?

    let newThreads: ModelPickerModel
    let small: ModelPickerModel
    let reviewer: ModelPickerModel
    let gitText: ModelPickerModel
    let delegated: ModelPickerModel

    init(
        engine: Engine, auth: AuthService?, onConnect: @escaping @MainActor (String?) -> Void = { _ in },
        confirm: @escaping @MainActor (String, String, String) -> Bool = ModelsSettingsModel.alert
    ) {
        self.engine = engine
        self.auth = auth
        self.onConnect = onConnect
        self.confirm = confirm
        let catalog: @MainActor () -> Catalog? = { [weak engine] in engine?.root.catalog.current }
        let integrations: @MainActor () -> [IntegrationItem] = { [weak auth] in auth?.integrations ?? [] }
        let reload: @MainActor () async -> Void = { [weak engine, weak auth] in
            await engine?.refreshAllCatalogs()
            await auth?.refresh()
        }
        func picker(current: @escaping @MainActor () -> ModelSelection?, apply: @escaping @MainActor (ModelSelection) async -> String?) -> ModelPickerModel {
            let model = ModelPickerModel(
                catalog: catalog, current: current, preferences: engine.modelPreferences, apply: apply, integrations: integrations,
                reload: reload, onConnect: { id in onConnect(id) })
            model.shortcutHint = nil
            return model
        }
        let models = engine.models!
        let auto: AutoModeService = engine.auto
        // The pickers are made before `self` exists; they reach `applyModel` through this box, filled in below (a
        // late-assigned captured `var` is a Swift 6 isolation warning, N32).
        let applier = ModelApplier()
        let apply: @MainActor (ModelSelection?, @escaping @MainActor (ModelSelection?, Bool) async -> String?) async -> String? = { selection, write in
            await applier.apply(selection, write)
        }

        newThreads = picker(current: { [weak models] in models?.configuredDefault }, apply: { selection in await apply(selection) { await models.setDefaultModel($0, reload: $1) } })
        small = picker(current: { [weak models] in models?.configuredSmall }, apply: { selection in await apply(selection) { await models.setSmallModel($0, reload: $1) } })
        reviewer = picker(current: { [weak auto] in auto?.settings.choice.selection }, apply: { selection in
            var settings = auto.settings
            settings.choice = .specific(selection)
            await auto.updateSettings(settings)
            return nil
        })
        gitText = picker(current: { [weak models] in models?.background.gitText.selection }, apply: { selection in
            await models.setGitText(.specific(selection))
            return nil
        })
        delegated = picker(current: { [weak models] in models?.background.delegated.selection }, apply: { selection in
            await models.setDelegated(.specific(selection))
            return nil
        })

        // opencode's own choice (removes the key) for the two opencode settings.
        newThreads.choices = { [weak self] in [.init(id: "server", title: "opencode's choice", detail: self?.serverDefaultLabel)] }
        newThreads.currentChoice = { [weak models] in models?.configuredDefault == nil ? "server" : nil }
        newThreads.applyChoice = { _ in await apply(nil) { await models.setDefaultModel($0, reload: $1) } }
        small.choices = { [.init(id: "auto", title: "opencode's choice", detail: "A fast model of the thread's provider")] }
        small.currentChoice = { [weak models] in models?.configuredSmall == nil ? "auto" : nil }
        small.applyChoice = { _ in await apply(nil) { await models.setSmallModel($0, reload: $1) } }

        reviewer.choices = { [weak self] in
            [.init(id: "thread", title: "Same as thread", detail: self?.label(auto.reviewerResolution(for: nil).selection)),
             .init(id: "server", title: "Server default", detail: self?.serverDefaultLabel)]
        }
        reviewer.currentChoice = { [weak auto] in Self.choiceID(auto?.settings.choice) }
        reviewer.applyChoice = { item in
            var settings = auto.settings
            settings.choice = item.id == "server" ? .serverDefault : .sameAsThread
            await auto.updateSettings(settings)
            return nil
        }
        gitText.choices = { [weak self] in
            [.init(id: "thread", title: "Same as thread", detail: "With the thread's context"),
             .init(id: "small", title: "Small model", detail: self?.label(BackgroundModelResolver.small(configured: models.configuredSmall, provider: engine.root.catalog.current?.defaultModel?.providerID, catalog: engine.root.catalog.current)))]
        }
        gitText.currentChoice = { [weak models] in Self.choiceID(models?.background.gitText) }
        gitText.applyChoice = { item in
            await models.setGitText(item.id == "small" ? .smallModel : .sameAsThread)
            return nil
        }
        delegated.choices = { [weak self] in
            [.init(id: "thread", title: "Same as parent", detail: "The thread that starts it"),
             .init(id: "server", title: "Server default", detail: self?.serverDefaultLabel)]
        }
        delegated.currentChoice = { [weak models] in Self.choiceID(models?.background.delegated) }
        delegated.applyChoice = { item in
            await models.setDelegated(item.id == "server" ? .serverDefault : .sameAsThread)
            return nil
        }

        applier.model = self
        Self.last = self
    }

    /// Writing opencode.json reloads opencode, which cancels pending approvals and questions: ask first, or save only.
    func applyModel(_ selection: ModelSelection?, _ write: @escaping @MainActor (ModelSelection?, Bool) async -> String?) async -> String? {
        let counts = engine.root.attention.counts
        var reloadNow = true
        if counts.approvals + counts.questions > 0 {
            let waiting = counts.approvals + counts.questions
            reloadNow = confirm(
                "Apply the model change now?",
                "opencode reloads its configuration, which cancels \(waiting) pending approval\(waiting == 1 ? "" : "s") or question\(waiting == 1 ? "" : "s"). Choose Save Only to apply it at the next reload (Window ▸ Reload opencode Configuration).",
                "Reload Now")
        }
        let problem = await write(selection, reloadNow)
        message = problem ?? (reloadNow ? nil : "Saved. It applies when opencode next reloads its configuration.")
        return problem
    }

    static func choiceID(_ choice: ModelChoice?) -> String? {
        switch choice {
        case .sameAsThread?, nil: "thread"
        case .serverDefault?: "server"
        case .smallModel?: "small"
        case .specific?: nil
        }
    }

    var catalog: Catalog? { engine.root.catalog.current }

    func label(_ selection: ModelSelection?) -> String? { selection.map { BackgroundModelResolver.label($0, in: catalog) } }

    var serverDefaultLabel: String? { label(catalog?.defaultModel) }

    /// Why a saved model cannot be used now, or nil.
    func problem(_ selection: ModelSelection?) -> String? {
        guard let selection else { return nil }
        switch BackgroundModelResolver.availability(of: selection, in: catalog) {
        case .available, .unknown: return nil
        case .missing: return "\(BackgroundModelResolver.label(selection, in: catalog)) is not in the catalog (provider not connected?)"
        case .unavailable(let reason): return reason
        }
    }

    /// What the reviewer uses now for a thread on opencode's default model (shown under the row).
    var reviewerNow: String {
        let resolution = engine.auto.reviewerResolution(for: nil)
        let name = label(resolution.selection) ?? "opencode's default"
        guard let selection = resolution.selection, let entry = BackgroundModelResolver.entry(selection, in: catalog) else { return "Now: \(name)." }
        return "Now: \(name)\(entry.isFree ? " (free)" : "")."
    }

    var connectedSummary: String {
        guard let catalog else { return "Loading the catalog…" }
        let providers = Set(BackgroundModelResolver.usable(catalog).map(\.providerID))
        let paid = BackgroundModelResolver.hasPaid(catalog)
        return "\(providers.count) provider\(providers.count == 1 ? "" : "s") connected · \(BackgroundModelResolver.usable(catalog).count) models"
            + (paid ? "" : " · free models only")
    }

    var opencodeEditable: Bool { engine.models.folder != nil }

    func refresh() async {
        await engine.models.readConfig()
        if let directory = catalog?.directory { await engine.refreshCatalog(directory: directory) }
    }

    func reloadNow() {
        Task { message = await engine.models.reloadServer() }
    }

    static func alert(_ title: String, _ detail: String, _ button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Save Only")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct ModelsSettingsView: View {
    @Bindable var model: ModelsSettingsModel
    @Environment(\.openCodeSnapshot) private var isSnapshot

    var body: some View {
        let models = model.engine.models!
        SettingsPaneBody {
            SettingsGroup(
                "opencode",
                footer: model.opencodeEditable
                    ? "Saved in BelloCode's opencode.json (model, agents.title.model); opencode reloads it. Your other settings and comments there are kept."
                    : "This opencode server is not managed by BelloCode: set these in its own configuration."
            ) {
                SettingsRow("Default for new threads", detail: "New threads start on it; change one thread's model in the composer (⇧⌘M).", divided: false) {
                    ModelSettingButton(model: model.newThreads, label: "Default for new threads", problem: model.problem(models.configuredDefault))
                        .disabled(!model.opencodeEditable)
                }
                SettingsRow("Small model", detail: "Thread titles. Also offered for git writing below.") {
                    ModelSettingButton(model: model.small, label: "Small model", problem: model.problem(models.configuredSmall))
                        .disabled(!model.opencodeEditable)
                }
                if let problem = models.configProblem {
                    SettingsFieldRow {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.ds(.meta)).foregroundStyle(Color.ds.dangerText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if models.reloadPending {
                    SettingsActionsRow {
                        Label("Saved; not applied yet", systemImage: "clock").font(.ds(.meta)).foregroundStyle(Color.ds.warningText)
                        Button("Reload opencode Now") { model.reloadNow() }.buttonStyle(DSButtonStyle(.outline, size: .small))
                    }
                }
            }
            SettingsGroup(
                "Background tasks",
                footer: "While a paid provider is connected, reviews never fall back to a free model: opencode's free tier refuses background requests once its allowance is used. A model that stops being available falls back to the next choice and is marked here."
            ) {
                SettingsRow("Auto reviewer", detail: "Decides what Auto's policy leaves open. \(model.reviewerNow)", divided: false) {
                    ModelSettingButton(model: model.reviewer, label: "Auto reviewer", problem: model.problem(model.engine.auto.settings.choice.selection))
                }
                SettingsRow("Git & GitLab writing", detail: "Commit messages, branch names, merge request title and description.") {
                    ModelSettingButton(model: model.gitText, label: "Git and GitLab writing", problem: model.problem(models.background.gitText.selection))
                }
                SettingsRow("Delegated threads and scheduled tasks", detail: "When the agent, task or schedule names no model.") {
                    ModelSettingButton(model: model.delegated, label: "Delegated threads and scheduled tasks", problem: model.problem(models.background.delegated.selection))
                }
            }
            SettingsGroup("Providers", footer: "A provider you connect here, in Settings ▸ Accounts or with bellocode-opencode auth login appears in every picker at once.") {
                SettingsActionsRow(divided: false) {
                    Button("Connect a Provider…") { model.onConnect(nil) }.buttonStyle(DSButtonStyle(.outline, size: .small))
                    Button("Refresh Models") { Task { await model.refresh() } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                    Spacer(minLength: DS.Space.s8)
                    Text(model.connectedSummary).font(.ds(.meta)).foregroundStyle(Color.ds.text3)
                }
            }
            if let message = model.message {
                SettingsNote(message)
            }
        }
        .task {
            guard !isSnapshot else { return }
            await model.refresh()
        }
    }
}

/// Lets pickers built in `ModelsSettingsModel.init` call the model once it exists (weak: the pane owns the pickers).
@MainActor
private final class ModelApplier {
    weak var model: ModelsSettingsModel?

    func apply(_ selection: ModelSelection?, _ write: @escaping @MainActor (ModelSelection?, Bool) async -> String?) async -> String? {
        await model?.applyModel(selection, write)
    }
}
