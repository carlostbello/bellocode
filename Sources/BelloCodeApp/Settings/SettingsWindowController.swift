import AgentUI
import AppKit
import BelloCore
import ComposerKit
import DesignSystem
import Engine
import OrchestrationUI
import SwiftUI
import TerminalKit

/// One Settings pane. Later packages add panes here (each a real pane; no placeholders are shown).
@MainActor
struct SettingsPane {
    var id: String
    var title: String
    var symbolName: String
    var make: @MainActor () -> NSViewController
}

/// The Settings window (⌘,): a toolbar of panes in the standard macOS style. General (send key, text size,
/// appearance) and Accounts (AgentUI's provider accounts) today.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let tabs = NSTabViewController()
    private(set) var panes: [SettingsPane]

    init(
        settings: AppSettings, auth: AuthService?, importSource: CredentialImportSource?, engine: Engine? = nil,
        notifier: AttentionNotifier? = nil, openThread: ((SessionID) -> Void)? = nil
    ) {
        var panes = [
            SettingsPane(id: "general", title: "General", symbolName: "gearshape") {
                let controller = NSHostingController(rootView: GeneralSettingsView(settings: settings))
                controller.sizingOptions = [.preferredContentSize]
                return controller
            },
            SettingsPane(id: "terminal", title: "Terminal", symbolName: "terminal") {
                let controller = NSHostingController(rootView: TerminalSettingsView(settings: settings))
                controller.sizingOptions = [.preferredContentSize]
                return controller
            },
            SettingsPane(id: "browser", title: "Browser", symbolName: "globe") {
                let browse = BrowseStatusModel(configDirectory: AppRuntime.applicationSupport().appending(path: "opencode/config"))
                let controller = NSHostingController(rootView: BrowserSettingsView(settings: settings, browse: browse))
                controller.sizingOptions = [.preferredContentSize]
                return controller
            },
        ]
        if let engine {
            panes.append(
                SettingsPane(id: "threads", title: "Threads", symbolName: "tray.2") {
                    let controller = NSHostingController(rootView: ThreadSettingsView(engine: engine, root: engine.root))
                    controller.sizingOptions = [.preferredContentSize]
                    return controller
                })
            panes.append(
                SettingsPane(id: "notifications", title: "Notifications", symbolName: "bell.badge") {
                    let controller = NSHostingController(
                        rootView: NotificationSettingsView(settings: settings, root: engine.root, notifier: notifier))
                    controller.sizingOptions = [.preferredContentSize]
                    return controller
                })
            // M6-A containerised execution (docs/features/containers.md).
            panes.append(
                SettingsPane(id: "containers", title: "Containers", symbolName: "shippingbox") {
                    let view = ContainersSettingsView(model: ContainersSettingsModel(engine: engine), service: engine.environments) { container in
                        let alert = NSAlert()
                        alert.messageText = "Remove the container \(container.name)?"
                        alert.informativeText = "Processes in it stop. Project files are on this Mac and are not touched; the container is created again on next use."
                        alert.addButton(withTitle: "Remove")
                        alert.addButton(withTitle: "Cancel")
                        alert.buttons.first?.hasDestructiveAction = true
                        return alert.runModal() == .alertFirstButtonReturn
                    }
                    let controller = NSHostingController(rootView: view)
                    controller.sizingOptions = [.preferredContentSize]
                    return controller
                })
            panes.append(
                SettingsPane(id: "environment", title: "Environment", symbolName: "cube.transparent") {
                    let model = EnvironmentSettingsModel(engine: engine, directory: EnvironmentSettingsModel.preferredDirectory)
                    model.openTerminal = { _ in EnvironmentSettingsModel.openTerminalInFrontWindow() }
                    model.openBrowser = { url in
                        // The built-in browser of the front window's thread; the default browser without one.
                        let front = NSApp.orderedWindows.compactMap { $0.windowController as? MainWindowController }.first
                        if front?.browser?.open(url) != true { NSWorkspace.shared.open(url) }
                    }
                    EnvironmentSettingsModel.last = model
                    let controller = NSHostingController(rootView: EnvironmentSettingsView(model: model))
                    controller.sizingOptions = [.preferredContentSize]
                    return controller
                })
            if let extras = engine.extras {
                // M3-B (docs/features/orchestration-extras.md).
                panes.append(
                    SettingsPane(id: "schedules", title: "Scheduled Tasks", symbolName: "calendar.badge.clock") {
                        let model = ScheduledTasksModel(scheduler: extras.schedules)
                        model.projects = { engine.root.projects.map { ($0.name, $0.directory) } }
                        model.threads = { directory in
                            guard let projectID = engine.root.projects.first(where: { $0.directory == directory })?.projectID,
                                let graph = engine.orchestration?.graph
                            else { return [] }
                            return graph.nodes.values.filter { $0.projectID == projectID && $0.parentID == nil }
                                .sorted { $0.created > $1.created }.prefix(40).map { ($0.title, $0.id) }
                        }
                        model.openThread = { id in openThread?(id) }
                        ScheduledTasksModelRegistry.last = model
                        let controller = NSHostingController(rootView: ScheduledTasksView(model: model))
                        controller.sizingOptions = [.preferredContentSize]
                        return controller
                    })
                panes.append(
                    SettingsPane(id: "gitlab", title: "GitLab", symbolName: "arrow.triangle.pull") {
                        let model = GitLabSettingsModel(service: extras.mergeRequests)
                        let view = GitLabSettingsView(model: model) { instance in
                            let alert = NSAlert()
                            alert.messageText = "Remove \(instance.baseURL)?"
                            alert.informativeText = "Its access token is deleted from your Keychain. Linked merge requests on it stop updating until you add it again with a token."
                            alert.addButton(withTitle: "Remove")
                            alert.addButton(withTitle: "Cancel")
                            alert.buttons.first?.hasDestructiveAction = true
                            return alert.runModal() == .alertFirstButtonReturn
                        }
                        let controller = NSHostingController(rootView: view)
                        controller.sizingOptions = [.preferredContentSize]
                        return controller
                    })
                panes.append(
                    SettingsPane(id: "secrets", title: "Secrets", symbolName: "key") {
                        let view = SecretsSettingsView(secrets: extras.secrets, visuals: extras.visuals) { label in
                            let alert = NSAlert()
                            alert.messageText = "Delete “\(label.label)”?"
                            alert.informativeText = "The value is removed from your Keychain. Agents holding a reference to it can no longer use it. This cannot be undone."
                            alert.addButton(withTitle: "Delete")
                            alert.addButton(withTitle: "Cancel")
                            alert.buttons.first?.hasDestructiveAction = true
                            return alert.runModal() == .alertFirstButtonReturn
                        }
                        let controller = NSHostingController(rootView: view)
                        controller.sizingOptions = [.preferredContentSize]
                        return controller
                    })
            }
        }
        if let auth {
            panes.append(
                SettingsPane(id: "accounts", title: "Accounts", symbolName: "person.crop.circle") {
                    let controller = AgentUIFactories.accountsSettings(auth: auth, importSource: importSource, style: AppStyle.agentUI)
                    controller.preferredContentSize = NSSize(width: 620, height: 460)
                    return controller
                })
        }
        self.panes = panes
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        for pane in panes {
            let controller = pane.make()
            let item = NSTabViewItem(viewController: controller)
            item.label = pane.title
            item.identifier = pane.id
            item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BelloCodeSettings")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window on a pane ("general", "accounts").
    func show(pane: String? = nil) {
        if let pane, let index = tabs.tabViewItems.firstIndex(where: { ($0.identifier as? String) == pane }) {
            tabs.selectedTabViewItemIndex = index
        }
        window?.title = tabs.tabViewItems[tabs.selectedTabViewItemIndex].label
        showWindow(nil)
        window?.center()
    }

    var paneIDs: [String] { panes.map(\.id) }
}

/// Settings ▸ General.
struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Picker("Send messages with:", selection: $settings.sendKey) {
                Text("Return (⇧↩ for a new line)").tag(SendKey.returnKey)
                Text("⌘ Return (↩ for a new line)").tag(SendKey.commandReturn)
            }
            .pickerStyle(.radioGroup)
            LabeledContent("Text size:") {
                HStack {
                    Slider(value: $settings.baseFontSize, in: AppSettings.fontSizeRange, step: 1)
                        .frame(width: 160)
                        .accessibilityLabel("Text size")
                        .accessibilityValue("\(Int(settings.baseFontSize)) points")
                    Text("\(Int(settings.baseFontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Picker("Appearance:", selection: $settings.appearance) {
                ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 280)
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Settings ▸ Terminal.
struct TerminalSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            LabeledContent("Font size:") {
                HStack {
                    Slider(value: fontSize, in: Double(TerminalPreferences.fontSizeRange.lowerBound)...Double(TerminalPreferences.fontSizeRange.upperBound), step: 1)
                        .frame(width: 160)
                        .accessibilityLabel("Terminal font size")
                        .accessibilityValue("\(Int(settings.terminalPreferences.fontSize)) points")
                    Text("\(Int(settings.terminalPreferences.fontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Picker("Scrollback:", selection: $settings.terminalPreferences.scrollback) {
                Text("1,000 lines").tag(1_000)
                Text("10,000 lines").tag(10_000)
                Text("50,000 lines").tag(50_000)
                Text("100,000 lines").tag(100_000)
            }
            .pickerStyle(.menu)
            .frame(width: 280)
            Toggle("Use Option as Meta key", isOn: $settings.terminalPreferences.optionAsMeta)
            Toggle("Ask before pasting several lines into a shell", isOn: $settings.terminalPreferences.confirmsMultilinePaste)
            Toggle("Let programs copy to the clipboard (OSC 52)", isOn: $settings.terminalPreferences.allowsClipboardWrites)
            Text("Terminal output is untrusted. Programs can never read the clipboard.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460)
    }

    private var fontSize: Binding<Double> {
        Binding(
            get: { Double(settings.terminalPreferences.fontSize) },
            set: { settings.terminalPreferences.fontSize = CGFloat($0) })
    }
}

/// A small titled window hosting a view controller (onboarding, Connect Provider). Never modal.
@MainActor
final class UtilityWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(title: String, content: NSViewController, size: NSSize) {
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = title
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
