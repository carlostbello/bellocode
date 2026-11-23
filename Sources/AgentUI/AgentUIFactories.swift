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
    /// - Parameter attachedOverlap: how far the host overlaps the composer onto the card's bottom edge (T3's attached
    ///   look; 0 when the stack stands alone). The card reserves that much room under its content.
    public static func pendingRequestStack(
        thread: ThreadModel, engine: Engine, style: AgentUIStyle = .standard, attachedOverlap: CGFloat = 0
    ) -> (view: NSView, model: PendingRequestStackModel) {
        let model = PendingRequestStackModel(source: thread, context: context(for: thread, engine: engine))
        let view = PendingRequestStackView(model: model).environment(\.agentUIAttachedOverlap, attachedOverlap)
        return (host(view, style: style), model)
    }

    /// Names for the stack: the project and child-thread titles, read from the engine's cached models.
    public static func context(for thread: ThreadModel, engine: Engine) -> PendingRequestContext {
        let projectID = thread.session?.projectID
        let projectName = engine.root.projects.first { $0.projectID == projectID }?.name
        return PendingRequestContext(projectName: projectName) { [weak engine] id in
            guard let engine, let projectID else { return nil }
            return engine.root.project(projectID)?.row(id)?.session
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
    /// `catalogTimedOut`: the caller stopped waiting for the catalog, so a missing one is "unavailable", not "loading".
    public static func onboarding(
        auth: AuthService, engine: Engine, importSource: CredentialImportSource? = .userInstall(),
        style: AgentUIStyle = .standard, catalogTimedOut: Bool = true, onFinish: @escaping (OnboardingOutcome) -> Void
    ) -> NSViewController {
        let catalog: @MainActor () -> OnboardingCatalog = { [weak engine] in
            .from(catalog: engine?.root.catalog.current, hidden: engine?.modelPreferences.value.hidden ?? [], timedOut: catalogTimedOut)
        }
        return controller(OnboardingView(auth: auth, catalog: catalog, importSource: importSource, onFinish: onFinish), style: style)
    }

    /// Settings ▸ Accounts.
    /// `freeModelsOffered`: whether opencode's free models can be chosen now (the empty state promises them only then).
    public static func accountsSettings(
        auth: AuthService, importSource: CredentialImportSource? = .userInstall(), style: AgentUIStyle = .standard,
        freeModelsOffered: (@MainActor () -> Bool)? = nil
    ) -> NSViewController {
        controller(AccountsSettingsView(auth: auth, importSource: importSource, freeModelsOffered: freeModelsOffered), style: style)
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

/// The request actions a host exposes as menu commands; they act on the front request of a stack.
public enum RequestCommand: String, CaseIterable, Sendable {
    case allowOnce, allowAlways, deny, submitAnswer, previous, next

    public var title: String {
        switch self {
        case .allowOnce: "Allow Once"
        case .allowAlways: "Always Allow"
        case .deny: "Deny or Dismiss"
        case .submitAnswer: "Submit Answer"
        case .previous: "Previous Request"
        case .next: "Next Request"
        }
    }

    public var shortcut: AgentShortcut {
        switch self {
        case .allowOnce: .allowOnce
        case .allowAlways: .allowAlways
        case .deny: .deny
        case .submitAnswer: .submitAnswer
        case .previous: .previousRequest
        case .next: .nextRequest
        }
    }
}

extension PendingRequestStackModel {
    /// Whether `command` applies to the front request now (nothing while its reply is being sent).
    public func canPerform(_ command: RequestCommand) -> Bool {
        guard let current, !isSubmitting(current) else { return false }
        let permission: PermissionRequest? = if case .permission(let p) = current { p } else { nil }
        switch command {
        case .allowOnce: return permission != nil
        case .allowAlways: return permission.map { presentation($0).allowAlways.isAvailable } ?? false
        case .deny: return true
        case .submitAnswer: if case .question = current { return true } else { return false }
        case .previous, .next: return requests.count > 1
        }
    }

    /// Performs `command` on the front request (no-op when it does not apply).
    public func perform(_ command: RequestCommand) {
        guard canPerform(command), let current else { return }
        switch (command, current) {
        case (.allowOnce, .permission(let p)): Task { await reply(.once, to: p) }
        case (.allowAlways, .permission(let p)): Task { await reply(.always, to: p) }
        case (.deny, .permission(let p)): Task { await reply(.reject, to: p) }
        case (.deny, .question(let q)): Task { await dismiss(q) }
        case (.submitAnswer, .question(let q)): Task { _ = await submit(q) }
        case (.previous, _): showPrevious()
        case (.next, _): showNext()
        default: break
        }
    }
}

/// Target for `requestMenuItems`; validates items against the front request.
@MainActor
final class MenuActionTarget: NSObject, NSMenuItemValidation {
    let model: PendingRequestStackModel

    init(model: PendingRequestStackModel) {
        self.model = model
    }

    @objc func allowOnce() { model.perform(.allowOnce) }
    @objc func allowAlways() { model.perform(.allowAlways) }
    @objc func deny() { model.perform(.deny) }
    @objc func submit() { model.perform(.submitAnswer) }
    @objc func previous() { model.perform(.previous) }
    @objc func next() { model.perform(.next) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(allowOnce): model.canPerform(.allowOnce)
        case #selector(allowAlways): model.canPerform(.allowAlways)
        case #selector(deny): model.canPerform(.deny)
        case #selector(submit): model.canPerform(.submitAnswer)
        case #selector(previous): model.canPerform(.previous)
        case #selector(next): model.canPerform(.next)
        default: false
        }
    }
}
