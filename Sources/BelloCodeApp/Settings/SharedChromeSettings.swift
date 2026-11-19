import AppKit
import ContainerKit
import DesignSystem
import Engine
import SwiftUI

/// Settings ▸ Browser ▸ Shared Chrome (docs/features/shared-browser.md): enable, idle time, profile size, compact
/// display, approved projects, versions, sandbox status, diagnostics (pairing, relay, CA trust), rebuild, and clearing
/// cookies and site data (confirmed: it signs every site out for every thread).
struct SharedChromeSettingsGroup: View {
    let service: SharedBrowserService
    /// Confirms deleting the profile (an alert in the app; tests and snapshots inject an answer).
    var confirmClear: @MainActor () -> Bool = SharedChromeSettingsGroup.confirmClearAlert

    private var settings: SharedBrowserSettings { service.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s20) {
            SettingsGroup(
                "Shared Chrome",
                footer: "One Chromium in a BelloCode container serves every thread and project, like your own browser: one profile, and sign-ins are kept and shared by every thread you allow to use it. browse and Chrome run only in the container. Agents need your approval per project, even in Auto or Full access."
            ) {
                SettingsToggleRow("Let agents use the shared Chrome", divided: false, isOn: binding(\.enabled))
                SettingsRow("Status", detail: statusDetail) {
                    HStack(spacing: DS.Space.s6) {
                        SharedChromeStatusPill(phase: service.phase)
                        if service.phase.isReady {
                            Button("Restart") { Task { await service.restartBrowser() } }.buttonStyle(DSButtonStyle(.outline, size: .small))
                            Button("Stop") { Task { await service.stopBrowser() } }.buttonStyle(DSButtonStyle(.outline, size: .small))
                        } else {
                            Button("Start") { Task { await service.startBrowser() } }
                                .buttonStyle(DSButtonStyle(.outline, size: .small))
                                .disabled(!service.isAvailable || !settings.enabled)
                        }
                    }
                }
                SettingsRow("Stop when idle for", detail: "Calls, a visible live view, a handoff or your control keep it running. Stopping lets Chrome save its cookies first.") {
                    DSMenuSelect("Idle time", options: [5, 10, 15, 30, 60].map { (id: $0, title: "\($0) minutes") }, selection: binding(\.idleMinutes))
                        .frame(width: 140)
                }
                SettingsRow("Profile size limit", detail: profileDetail) {
                    DSMenuSelect("Profile size", options: [2, 4, 8, 16].map { (id: $0, title: "\($0) GB") }, selection: binding(\.profileLimitGiB))
                        .frame(width: 140)
                }
                SettingsToggleRow("Compact display (1024 × 640)", detail: "36% fewer pixels per full redraw; pages lay out for a smaller window. Restarts the browser.",
                                  isOn: binding(\.compactDisplay))
                SettingsToggleRow("Close a thread's tabs when it is done", detail: "Shared or lent tabs stay open.", isOn: binding(\.closeTabsWhenDone))
            }
            SettingsGroup("Projects allowed to use it", footer: "Allowed with “Always” on the approval card. Revoking removes the tools from that project's threads.") {
                if service.approvedProjects.isEmpty {
                    SettingsRow("None yet", detail: "An agent asks when it first needs the shared Chrome.", divided: false) { EmptyView() }
                }
                ForEach(Array(service.approvedProjects.sorted().enumerated()), id: \.element) { index, project in
                    SettingsRow(URL(filePath: project).lastPathComponent, detail: (project as NSString).abbreviatingWithTildeInPath, divided: index > 0) {
                        Button("Revoke") { Task { await service.revokeProject(project) } }.buttonStyle(DSButtonStyle(.outline, size: .small))
                    }
                }
            }
            SettingsGroup("Versions and security", footer: "Pinned by SHA-256 and built on this Mac with Rancher Desktop; `make browser-verify` is the upgrade gate.") {
                SettingsRow("Chromium", divided: false) { value(service.status?.chromium.nonEmpty ?? "Chromium \(BrowserVersions.chromium) (Debian)") }
                SettingsRow("browse") { value("\(service.status?.browse.nonEmpty ?? BrowserVersions.browse) · extension \(shortID)") }
                SettingsRow("Image") { value(service.imageTag ?? "Built on first use").help("Rebuilt when a pinned input changes; one previous image is kept.") }
                SettingsRow("Sandbox", detail: "Chromium keeps its own namespace sandbox (no --no-sandbox); capabilities dropped, no-new-privileges, reviewed seccomp profile.") {
                    value(sandboxText, warning: service.status?.sandbox == "failed" || service.phase == .sandboxUnavailable)
                }
            }
            SettingsGroup("Diagnostics") {
                SettingsRow("Pairing", divided: false) { value(pairingText) }
                SettingsRow("Relay") { value(service.status.map { $0.relay == "up" ? "Running (container loopback only)" : "Down" } ?? "—") }
                SettingsRow("Certificate trust", detail: "Company roots and BelloCode's egress CA are imported into Chrome's certificate store at every start.") {
                    value(service.status.map { "\($0.caCount) certificate\($0.caCount == 1 ? "" : "s") imported" } ?? "—")
                }
                SettingsRow("Chrome restarts") { value(service.status.map { "\($0.chromiumRestarts)" } ?? "—") }
                SettingsActionsRow {
                    Button("Refresh") { Task { await service.refreshStatus() } }
                        .buttonStyle(DSButtonStyle(.outline, size: .small))
                    Button("Rebuild Image") { Task { await service.rebuildImage() } }
                        .buttonStyle(DSButtonStyle(.outline, size: .small))
                        .disabled(!service.isAvailable)
                    Button("Delete Cookies and Site Data…") {
                        if confirmClear() { Task { await service.clearSiteData() } }
                    }
                    .buttonStyle(DSButtonStyle(.destructive, size: .small))
                    .disabled(!service.isAvailable)
                }
            }
        }
        .task { await service.refreshStatus() }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<SharedBrowserSettings, Value>) -> Binding<Value> {
        Binding(get: { service.settings[keyPath: keyPath] }, set: { newValue in
            var next = service.settings
            next[keyPath: keyPath] = newValue
            Task { await service.update(next) }
        })
    }

    private func value(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(.ds(.label)).foregroundStyle(warning ? Color.ds.dangerText : Color.ds.text2).lineLimit(1).truncationMode(.middle)
    }

    private var statusDetail: String {
        switch service.phase {
        case .failed(let message): message
        case .preparingImage(let line): line
        case .ready: "\(service.bindings.count) thread\(service.bindings.count == 1 ? "" : "s") have a tab group · \(service.viewerSubscribers) live view\(service.viewerSubscribers == 1 ? "" : "s")"
        default: service.isAvailable ? "Starts on first use." : "Needs container execution (Rancher Desktop)."
        }
    }

    private var profileDetail: String {
        guard let status = service.status else { return "Docker volumes have no byte quota: BelloCode measures the profile and warns at 80%. The HTTP cache is bounded at 128 MB and kept out of the profile." }
        let used = ByteCountFormatter.string(fromByteCount: status.profileBytes, countStyle: .file)
        let limit = Int64(settings.profileLimitGiB) << 30
        let warn = status.profileBytes > limit * 8 / 10 ? " — over 80% of the limit: delete site data or raise the limit" : ""
        return "Profile \(used) (downloads \(ByteCountFormatter.string(fromByteCount: status.downloadBytes, countStyle: .file)))\(warn)."
    }

    private var shortID: String { service.status.map { String($0.extensionID.prefix(8)) + "…" } ?? "stable per Mac" }

    private var sandboxText: String {
        if service.phase == .sandboxUnavailable { return "Unavailable — not started" }
        switch service.status?.sandbox {
        case "ok": return "Verified (renderers in their own PID namespace, seccomp-BPF)"
        case "failed": return "Check failed — stopped"
        default: return "Checked at every start"
        }
    }

    private var pairingText: String {
        guard let status = service.status else { return "—" }
        return status.extension == "connected" ? "Extension paired and connected" : "Extension not connected (pairs automatically at start)"
    }

    @MainActor static func confirmClearAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete the shared Chrome's cookies and site data?"
        alert.informativeText = "This signs every site out for every thread and removes saved site data and downloads. The browser restarts with an empty profile. This cannot be undone."
        alert.addButton(withTitle: "Delete and Sign Out Everywhere")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
