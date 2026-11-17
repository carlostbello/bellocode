import AppKit
import DesignSystem
import Engine
import SwiftUI

/// Settings ▸ Threads: the auto-settle rule (per-thread "Never" is in the thread's menu).
struct ThreadSettingsView: View {
    let engine: Engine
    @Bindable var root: EngineRoot

    static func title(_ hours: Double?) -> String {
        guard let hours else { return "Never" }
        switch hours {
        case 1: return "1 hour after I last look"
        case ..<24: return "\(Int(hours)) hours after I last look"
        case 24: return "1 day after I last look"
        default: return "\(Int(hours / 24)) days after I last look"
        }
    }

    var body: some View {
        SettingsPaneBody {
            SettingsGroup(
                "Auto-settle",
                footer: "A thread is settled only when its last turn finished, you have seen it, nothing is pending and it is not pinned. Use “Never Auto-Settle” in a thread’s menu to keep one active. New activity that needs you brings a settled thread back."
            ) {
                SettingsRow("Settle finished threads", divided: false) {
                    SettingsMenuPicker(
                        label: "Settle finished threads",
                        options: OrganisationRules.autoSettleChoices.map { ($0 ?? -1, Self.title($0)) },
                        selection: Binding(
                            get: { root.organisationRules.autoSettleAfterHours ?? -1 },
                            set: { engine.setOrganisationRules(OrganisationRules(autoSettleAfterHours: $0 < 0 ? nil : $0)) }))
                }
            }
        }
    }
}

/// Settings ▸ Notifications: what notifies (blockers and completions, blockers only, off), sounds, the menu-bar
/// item, muted projects, and the system authorization with a way to fix it.
struct NotificationSettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var root: EngineRoot
    let notifier: AttentionNotifier?

    private var authorization: NotificationAuthorization { notifier?.authorization ?? .unavailable }

    var body: some View {
        SettingsPaneBody {
            SettingsGroup(
                "Notify me about",
                footer: "Only when BelloCode is in the background, or the thread is not on screen. Never for streaming output or tool calls."
            ) {
                SettingsRadioRows(
                    options: NotificationSettings.Mode.allCases.map { ($0, $0.title) }, selection: $settings.notifications.mode)
            }
            SettingsGroup("Alerts") {
                SettingsToggleRow("Play a sound for approvals, questions and failures", divided: false, isOn: $settings.notifications.playsSound)
                SettingsToggleRow("Show “Needs you” in the menu bar", isOn: $settings.notifications.showsMenuBarItem)
                SettingsRow(
                    "System permission",
                    detail: authorization == .unavailable
                        ? "Notifications need the signed app bundle (make app). The Dock badge and the sidebar still show what needs you." : nil
                ) {
                    HStack(spacing: DS.Space.s8) {
                        HStack(spacing: DS.Space.s4) {
                            Image(systemName: symbol).foregroundStyle(Color.ds.icon)
                            Text(authorization.label).font(.ds(.label)).foregroundStyle(Color.ds.text2)
                        }
                        .accessibilityElement(children: .combine)
                        if authorization == .notDetermined, let notifier {
                            Button("Allow Notifications…") { Task { await notifier.requestAuthorization() } }
                                .buttonStyle(DSButtonStyle(.outline, size: .small))
                        } else if authorization == .denied || authorization == .provisional {
                            Button("Open System Settings…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(DSButtonStyle(.outline, size: .small))
                        }
                    }
                }
            }
            SettingsGroup("Mute projects") {
                if root.projects.isEmpty {
                    SettingsRow("No projects yet.", divided: false) { EmptyView() }
                }
                ForEach(Array(root.projects.enumerated()), id: \.element.directory) { index, project in
                    SettingsToggleRow(
                        project.name, detail: (project.directory as NSString).abbreviatingWithTildeInPath, divided: index > 0,
                        isOn: Binding(
                            get: { settings.notifications.mutedProjects.contains(project.directory) },
                            set: { muted in
                                if muted { settings.notifications.mutedProjects.insert(project.directory) } else {
                                    settings.notifications.mutedProjects.remove(project.directory)
                                }
                            }))
                }
            }
        }
    }

    private var symbol: String {
        switch authorization {
        case .authorized: "checkmark.circle"
        case .provisional: "bell.slash"
        case .denied: "xmark.octagon"
        case .notDetermined: "questionmark.circle"
        case .unavailable: "exclamationmark.triangle"
        }
    }
}
