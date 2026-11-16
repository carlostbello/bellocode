import AppKit
import BelloCore
import Engine
import SwiftUI

/// AppKit seams for the shell, composer and Settings window (docs/features/agent-ui.md). Every view is self-contained
/// SwiftUI hosted in an `NSHostingView`/`NSHostingController`, styled by the injected `AgentUIStyle`.
@MainActor
public enum AgentUIFactories {
    /// The pinned approvals/questions stack for an open thread, to place directly above the composer. Its height
    /// follows its content (zero when nothing is pending) through the intrinsic content size; pin its width.
    public static func pendingRequestStack(
        thread: ThreadModel, engine: Engine, style: AgentUIStyle = .standard
    ) -> (view: NSView, model: PendingRequestStackModel) {
        let model = PendingRequestStackModel(source: thread, context: context(for: thread, engine: engine))
        return (host(PendingRequestStackView(model: model), style: style), model)
    }

    /// Names for the stack: the project and child-thread titles, read from the engine's cached models.
    public static func context(for thread: ThreadModel, engine: Engine) -> PendingRequestContext {
        let projectID = thread.session?.projectID
        let projectName = engine.root.projects.first { $0.projectID == projectID }?.name
        return PendingRequestContext(projectName: projectName) { [weak engine] id in
            guard let engine, let projectID else { return nil }
            return engine.root.project(projectID)?.row(id)?.session.title
        }
    }

    /// The permission-mode control for the composer's controls bar (⇧⌘A opens it).
    public static func permissionModeControl(thread: ThreadModel, engine: Engine, style: AgentUIStyle = .standard) -> NSView {
        let agents = engine.root.catalog.catalog(for: thread.session?.directory ?? "")?.primaryAgents ?? []
        return host(PermissionModePicker(source: thread, agents: agents), style: style)
    }

    /// The Plan/Build switch for the controls bar (⌥⌘P).
    public static func planToggle(thread: ThreadModel, style: AgentUIStyle = .standard) -> NSView {
        host(PlanModeToggle(source: thread), style: style)
    }

    /// The model button and picker popover for the composer's controls bar (⇧⌘M).
    ///
    /// - Parameters:
    ///   - auth: shows providers that are not connected, with "Connect…"; nil hides them.
    ///   - onConnect: open the provider connection UI (Settings ▸ Accounts or onboarding) for an integration ID, or for
    ///     any provider when nil.
    public static func modelPicker(
        thread: ThreadModel, engine: Engine, auth: AuthService?, onConnect: @escaping @MainActor (String?) -> Void,
        style: AgentUIStyle = .standard
    ) -> (view: NSView, model: ModelPickerModel) {
        let model = modelPickerModel(thread: thread, engine: engine, auth: auth, onConnect: onConnect)
        return (host(ModelPickerButton(model: model), style: style), model)
    }

    /// The picker's model, for hosts that build their own button.
    public static func modelPickerModel(
        thread: ThreadModel, engine: Engine, auth: AuthService?, onConnect: @escaping @MainActor (String?) -> Void
    ) -> ModelPickerModel {
        ModelPickerModel(
            catalog: { [weak engine, weak thread] in
                guard let engine else { return nil }
                return engine.root.catalog.catalog(for: thread?.session?.directory ?? "")
            },
            current: { [weak thread] in thread?.session?.model },
            preferences: engine.modelPreferences,
            apply: { [weak thread] selection in
                guard let thread else { return "The thread was closed." }
                await thread.setModel(selection)
                return thread.lastError?.userMessage
            },
            integrations: { [weak auth] in auth?.integrations ?? [] },
            reload: { [weak engine, weak thread, weak auth] in
                if let engine, let directory = thread?.session?.directory ?? engine.root.catalog.current?.directory {
                    await engine.refreshCatalog(directory: directory)
                }
                await auth?.refresh()
            },
            onConnect: onConnect)
    }

    /// The first-run flow, for the main window's content area or a panel. It never blocks the app.
    public static func onboarding(
        auth: AuthService, engine: Engine, importSource: CredentialImportSource? = .userInstall(),
        style: AgentUIStyle = .standard, onFinish: @escaping (OnboardingOutcome) -> Void
    ) -> NSViewController {
        let free = (engine.root.catalog.current?.models ?? []).filter(\.isFree).map(\.name)
        return controller(OnboardingView(auth: auth, freeModels: free, importSource: importSource, onFinish: onFinish), style: style)
    }

    /// Settings ▸ Accounts.
    public static func accountsSettings(
        auth: AuthService, importSource: CredentialImportSource? = .userInstall(), style: AgentUIStyle = .standard
    ) -> NSViewController {
        controller(AccountsSettingsView(auth: auth, importSource: importSource), style: style)
    }

    /// Provider list and sign-in form on its own (for "Connect…" from the model picker).
    public static func providerConnect(
        auth: AuthService, integrationID: String? = nil, style: AgentUIStyle = .standard, onDone: (() -> Void)? = nil
    ) -> NSViewController {
        controller(ProviderConnectView(auth: auth, initialIntegrationID: integrationID, onDone: onDone), style: style)
    }

    /// Menu items the shell adds (Thread menu) so every request action has a menu entry and visible shortcut. The
    /// actions act on the front request of `model`.
    public static func requestMenuItems(for model: PendingRequestStackModel) -> [NSMenuItem] {
        let target = MenuActionTarget(model: model)
        func item(_ title: String, _ shortcut: AgentShortcut, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut.menuKeyEquivalent)
            item.keyEquivalentModifierMask = shortcut.menuModifierMask
            item.target = target
            item.representedObject = target
            return item
        }
        return [
            item("Allow Once", .allowOnce, #selector(MenuActionTarget.allowOnce)),
            item("Always Allow", .allowAlways, #selector(MenuActionTarget.allowAlways)),
            item("Deny or Dismiss", .deny, #selector(MenuActionTarget.deny)),
            item("Submit Answer", .submitAnswer, #selector(MenuActionTarget.submit)),
            item("Previous Request", .previousRequest, #selector(MenuActionTarget.previous)),
            item("Next Request", .nextRequest, #selector(MenuActionTarget.next)),
        ]
    }

    // MARK: Hosting

    static func host<V: View>(_ view: V, style: AgentUIStyle) -> NSView {
        let hosting = NSHostingView(rootView: view.environment(\.agentUIStyle, style))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.translatesAutoresizingMaskIntoConstraints = false
        return hosting
    }

    static func controller<V: View>(_ view: V, style: AgentUIStyle) -> NSViewController {
        let controller = NSHostingController(rootView: AnyView(view.environment(\.agentUIStyle, style)))
        controller.sizingOptions = []
        return controller
    }
}

/// Target for `requestMenuItems`; validates items against the front request.
@MainActor
final class MenuActionTarget: NSObject, NSMenuItemValidation {
    let model: PendingRequestStackModel

    init(model: PendingRequestStackModel) {
        self.model = model
    }

    private var permission: PermissionRequest? { if case .permission(let p)? = model.current { p } else { nil } }
    private var question: QuestionRequest? { if case .question(let q)? = model.current { q } else { nil } }

    @objc func allowOnce() { if let permission { Task { await model.reply(.once, to: permission) } } }
    @objc func allowAlways() {
        if let permission, model.presentation(permission).allowAlways.isAvailable { Task { await model.reply(.always, to: permission) } }
    }
    @objc func deny() {
        if let permission { Task { await model.reply(.reject, to: permission) } }
        if let question { Task { await model.dismiss(question) } }
    }
    @objc func submit() { if let question { Task { await model.submit(question) } } }
    @objc func previous() { model.showPrevious() }
    @objc func next() { model.showNext() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let current = model.current, !model.isSubmitting(current) else { return false }
        switch menuItem.action {
        case #selector(allowOnce): return permission != nil
        case #selector(allowAlways): return permission.map { model.presentation($0).allowAlways.isAvailable } ?? false
        case #selector(deny): return true
        case #selector(submit): return question != nil
        case #selector(previous), #selector(next): return model.requests.count > 1
        default: return false
        }
    }
}
