import AgentUI
import AppKit
import ComposerKit
import DesignSystem
import Engine
import SwiftUI

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

    init(settings: AppSettings, auth: AuthService?, importSource: CredentialImportSource?) {
        var panes = [
            SettingsPane(id: "general", title: "General", symbolName: "gearshape") {
                let controller = NSHostingController(rootView: GeneralSettingsView(settings: settings))
                controller.sizingOptions = [.preferredContentSize]
                return controller
            },
        ]
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
