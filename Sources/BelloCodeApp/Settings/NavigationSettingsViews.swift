import AppKit
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
        Form {
            Picker("Settle finished threads:", selection: Binding(
                get: { root.organisationRules.autoSettleAfterHours ?? -1 },
                set: { engine.setOrganisationRules(OrganisationRules(autoSettleAfterHours: $0 < 0 ? nil : $0)) })
            ) {
                ForEach(OrganisationRules.autoSettleChoices, id: \.self) { hours in
                    Text(Self.title(hours)).tag(hours ?? -1)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 380)
            Text("A thread is settled only when its last turn finished, you have seen it, nothing is pending and it is not pinned. Use “Never Auto-Settle” in a thread’s menu to keep one active. New activity that needs you brings a settled thread back.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 480)
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
        Form {
            Picker("Notify me about:", selection: $settings.notifications.mode) {
                ForEach(NotificationSettings.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text("Only when BelloCode is in the background, or the thread is not on screen. Never for streaming output or tool calls.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Play a sound for approvals, questions and failures", isOn: $settings.notifications.playsSound)
            Toggle("Show “Needs You” in the menu bar", isOn: $settings.notifications.showsMenuBarItem)
            LabeledContent("System permission:") {
                HStack {
                    Label(authorization.label, systemImage: symbol).labelStyle(.titleAndIcon)
                    if authorization == .notDetermined, let notifier {
                        Button("Allow Notifications…") { Task { await notifier.requestAuthorization() } }
                    } else if authorization == .denied || authorization == .provisional {
                        Button("Open System Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            if authorization == .unavailable {
                Text("Notifications need the signed app bundle (make app). The Dock badge and the sidebar still show what needs you.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Mute projects") {
                if root.projects.isEmpty {
                    Text("No projects yet.").foregroundStyle(.secondary)
                }
                ForEach(root.projects, id: \.directory) { project in
                    Toggle(isOn: Binding(
                        get: { settings.notifications.mutedProjects.contains(project.directory) },
                        set: { muted in
                            if muted { settings.notifications.mutedProjects.insert(project.directory) } else {
                                settings.notifications.mutedProjects.remove(project.directory)
                            }
                        })
                    ) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(project.name)
                            Text((project.directory as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 500)
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
