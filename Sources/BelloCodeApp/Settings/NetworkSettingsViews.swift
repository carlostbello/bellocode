import AppKit
import BelloCore
import ContainerKit
import DesignSystem
import Engine
import SwiftUI

// Settings ▸ Containers ▸ Corporate network and the GitLab registry (docs/features/containers.md, "Corporate
// network", "Registries"): enterprise root certificates for containers and opencode, proxy variables, Network
// diagnostics, and the suggested GitLab registry hosts with sign-in through the GitLab token.

@MainActor
final class NetworkSettingsModel: ObservableObject {
    let engine: Engine
    var service: EnvironmentService { engine.environments }
    @Published var urlsText: String
    @Published var gitLabInstance: String
    @Published var gitLabRegistry: String
    @Published var gitLabUser: String
    @Published var message: String?

    static weak var last: NetworkSettingsModel?

    init(engine: Engine) {
        self.engine = engine
        urlsText = engine.environments.network.diagnosticsURLs.joined(separator: "\n")
        let instance = engine.extras?.mergeRequests.instances.first?.baseURL ?? "https://gitlab.novacoast.com"
        gitLabInstance = instance
        gitLabRegistry = EnvironmentService.gitLabRegistrySuggestions(instance: instance).first ?? ""
        gitLabUser = engine.extras?.mergeRequests.instanceStatus[instance]?.user ?? ""
    }

    var gitLabInstances: [String] {
        let known = engine.extras?.mergeRequests.instances.map(\.baseURL) ?? []
        return known.isEmpty ? ["https://gitlab.novacoast.com"] : known
    }

    func setTrust(_ on: Bool) async {
        var settings = await service.networkSettings()
        settings.trustEnterpriseCertificates = on
        await service.setNetworkSettings(settings)
    }

    func setCertificate(_ fingerprint: String, selected: Bool) async {
        var settings = await service.networkSettings()
        var chosen = service.network.selected
        if selected { chosen.insert(fingerprint) } else { chosen.remove(fingerprint) }
        settings.selectedCertificates = chosen.sorted()
        await service.setNetworkSettings(settings)
    }

    func useDefaults() async {
        var settings = await service.networkSettings()
        settings.trustEnterpriseCertificates = nil
        settings.selectedCertificates = nil
        await service.setNetworkSettings(settings)
    }

    func runDiagnostics() async {
        let urls = urlsText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if service.network.managedSource == nil || !urls.isEmpty {
            var settings = await service.networkSettings()
            settings.diagnosticsURLs = urls == NetworkSettings.defaultDiagnosticsURLs ? nil : urls
            await service.setNetworkSettings(settings)
        }
        await service.runNetworkDiagnostics(directory: EnvironmentSettingsModel.preferredDirectory)
    }

    func addSuggestion(_ registry: String, to containers: ContainersSettingsModel) {
        var lines = containers.allowlist.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.contains(registry) else { return }
        lines.append(registry)
        containers.allowlist = lines.joined(separator: "\n")
        message = "Added \(registry) to the allowlist below the policy. Choose Save Policy to apply it."
    }

    func signInWithGitLab() {
        do {
            try service.signInWithGitLabToken(registry: gitLabRegistry.trimmingCharacters(in: .whitespaces), instance: gitLabInstance,
                                              username: gitLabUser.trimmingCharacters(in: .whitespaces))
            message = "Signed in to \(gitLabRegistry) with the GitLab token of \(gitLabInstance). The token stays in its one Keychain item and needs the read_registry scope."
        } catch {
            message = "\(error)"
        }
    }
}

/// Trust enterprise certificates in containers: the switch (automatic, chosen or managed), the roots to trust, and
/// where the proxy variables come from.
struct CorporateNetworkSettingsView: View {
    @ObservedObject var model: NetworkSettingsModel
    let service: EnvironmentService

    var body: some View {
        let network = service.network
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Trust enterprise certificates in containers", detail: trustDetail(network), divided: false) {
                if let managed = network.managedTrustValue {
                    DSPillView(managed ? "On · Managed" : "Off · Managed", tone: .info, symbolName: "building.2")
                } else {
                    Toggle(isOn: Binding(get: { network.trustEnabled }, set: { value in Task { await model.setTrust(value) } })) { EmptyView() }
                        .toggleStyle(DSToggleStyle(.switch)).accessibilityLabel("Trust enterprise certificates in containers")
                }
            }
            if network.trustEnabled {
                if network.candidates.isEmpty {
                    SettingsRow("No enterprise root certificates", detail: "This Mac trusts no root certificates beyond Apple's built-in ones, so there is nothing to add.") {
                        EmptyView()
                    }
                }
                ForEach(network.candidates) { certificate in
                    let selected = network.selected.contains(certificate.fingerprint)
                    SettingsRow(certificate.subject, detail: certificateDetail(certificate)) {
                        if network.managedCertificates {
                            DSPillView(selected ? "Trusted · Managed" : "Not trusted", tone: selected ? .info : .neutral, symbolName: selected ? "building.2" : nil)
                        } else {
                            Toggle(isOn: Binding(get: { selected }, set: { value in Task { await model.setCertificate(certificate.fingerprint, selected: value) } })) {
                                EmptyView()
                            }
                            .toggleStyle(DSToggleStyle(.checkbox)).accessibilityLabel("Trust \(certificate.subject) in containers")
                        }
                    }
                }
                if let problem = network.exportProblem {
                    SettingsRow(problem) { DSPillView("Not applied", tone: .warning, symbolName: "exclamationmark.triangle") }
                }
            }
            SettingsRow("Proxy", detail: proxyDetail(network)) {
                DSPillView(network.proxySource == nil ? "None" : "Passed on", tone: network.proxySource == nil ? .neutral : .info,
                           symbolName: network.proxySource == nil ? "arrow.right" : "arrow.triangle.branch")
            }
            if !network.trustAutomatic, network.managedTrustValue == nil, !network.managedCertificates {
                SettingsActionsRow {
                    Spacer()
                    Button("Use Defaults") { Task { await model.useDefaults() } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                }
            }
        }
    }

    private func trustDetail(_ network: NetworkState) -> String {
        var text = "Exports the selected roots from the Mac's Keychain (certificates only, never keys) and mounts them read-only into every BelloCode container, with SSL_CERT_FILE, NODE_EXTRA_CA_CERTS, REQUESTS_CA_BUNDLE, PIP_CERT and GIT_SSL_CAINFO; opencode gets them too (at its next start)."
        if network.trustAutomatic { text += " Automatic: on when the Mac trusts roots installed for all users." }
        if let source = network.managedSource, network.managedTrust || network.managedCertificates { text += " Set by your organisation (\(source))." }
        return text
    }

    private func certificateDetail(_ certificate: TrustedCertificate) -> String {
        let domain = certificate.domain == .admin ? "Installed for all users (profile or administrator)" : "Trusted in your login keychain"
        let expiry = certificate.notAfter.map { " · until \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        return "\(domain) · SHA-256 \(certificate.shortFingerprint)…\(expiry)"
    }

    private func proxyDetail(_ network: NetworkState) -> String {
        guard let source = network.proxySource else {
            return "No proxy is set on this Mac or by your organisation. A transparent proxy needs none; if it intercepts TLS, trust its root above."
        }
        let corporate = network.corporate
        let urls = [corporate.httpProxy.map { "HTTP \($0)" }, corporate.httpsProxy.map { "HTTPS \($0)" }].compactMap { $0 }.joined(separator: ", ")
        return "From \(source == "administrator" ? "your organisation" : source): \(urls). Containers also bypass it for loopback and the project's services (NO_PROXY)."
    }
}

/// Network diagnostics: the URLs (one per line), Run, and what each fetch saw from the container and from the Mac.
struct NetworkDiagnosticsView: View {
    @ObservedObject var model: NetworkSettingsModel
    let service: EnvironmentService

    var body: some View {
        let network = service.network
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $model.urlsText).font(.ds(.codeSmall)).scrollContentBackground(.hidden)
                .frame(height: 52).padding(DS.Space.s4)
                .background(DSColor.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(DSColor.borderStrong, lineWidth: 1))
                .accessibilityLabel("URLs to fetch, one per line")
                .padding(DS.Space.s12)
            SettingsActionsRow {
                Button(network.isDiagnosing ? "Running…" : "Run Diagnostics") { Task { await model.runDiagnostics() } }
                    .buttonStyle(DSButtonStyle(.primary, size: .small)).disabled(network.isDiagnosing)
                if let run = network.diagnostics {
                    Text(run.interceptedBy.isEmpty ? "No interception by a selected enterprise root seen" : "TLS intercepted by \(run.interceptedBy.joined(separator: ", "))")
                        .font(.ds(.meta)).foregroundStyle(DSColor.text2)
                }
            }
            if let run = network.diagnostics {
                if let problem = run.containerProblem {
                    SettingsRow("From the container", detail: problem) { DSPillView("Not run", tone: .warning, symbolName: "exclamationmark.triangle") }
                }
                ForEach(run.container) { result in
                    resultRow(result, place: "Container\(run.project.map { " (\($0))" } ?? "")")
                }
                ForEach(run.mac) { result in
                    resultRow(result, place: "This Mac (as opencode)")
                }
            }
        }
    }

    private func resultRow(_ result: NetworkProbeResult, place: String) -> some View {
        var parts = ["\(place) · \(result.tool)"]
        if let status = result.status { parts.append("HTTP \(status)") }
        if let issuer = result.issuer { parts.append("issuer \(issuer)") }
        if let proxy = result.proxy { parts.append("via proxy \(proxy)") }
        if !result.proxyHeaders.isEmpty { parts.append(result.proxyHeaders.joined(separator: "; ")) }
        if let error = result.error { parts.append(error) }
        return SettingsRow(result.url, detail: parts.joined(separator: " · ")) {
            DSPillView(result.ok ? "Reached" : "Failed", tone: result.ok ? .success : .danger, symbolName: result.ok ? "checkmark.circle" : "xmark.octagon")
        }
    }
}

/// The GitLab registry: suggested allowlist entries (never picked silently) and sign-in with the GitLab token.
struct GitLabRegistryView: View {
    @ObservedObject var model: NetworkSettingsModel
    @ObservedObject var containers: ContainersSettingsModel
    let service: EnvironmentService

    var body: some View {
        let suggestions = EnvironmentService.gitLabRegistrySuggestions(instance: model.gitLabInstance)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, registry in
                let listed = containers.allowlist.split(whereSeparator: \.isNewline).map(String.init).contains(registry)
                SettingsRow(registry, detail: index == 0 ? "If your GitLab serves its registry on its own domain." : "If your GitLab serves its registry on its own host name, port 5050 (GitLab's default).",
                            divided: index > 0) {
                    if service.managedPolicy != nil {
                        DSPillView("Policy managed", tone: .info, symbolName: "building.2")
                    } else if listed {
                        DSPillView("In allowlist", tone: .success, symbolName: "checkmark")
                    } else {
                        Button("Add to Allowlist") { model.addSuggestion(registry, to: containers) }.buttonStyle(DSButtonStyle(.outline, size: .small))
                    }
                }
            }
            SettingsFieldRow {
                DSMenuSelect("GitLab instance", options: model.gitLabInstances.map { (id: $0, title: $0) }, selection: $model.gitLabInstance)
                TextField("", text: $model.gitLabRegistry, prompt: Text(suggestions.first ?? "registry host")).textFieldStyle(DSTextFieldStyle())
                    .accessibilityLabel("GitLab registry host")
                TextField("", text: $model.gitLabUser, prompt: Text("GitLab user")).textFieldStyle(DSTextFieldStyle()).frame(width: 96)
                    .accessibilityLabel("GitLab user name")
                Button("Use GitLab Token") { model.signInWithGitLab() }.buttonStyle(DSButtonStyle(.outline, size: .small))
                    .disabled(model.gitLabRegistry.isEmpty || model.gitLabUser.isEmpty)
            }
            if let instance = service.registryGitLabInstance(model.gitLabRegistry) {
                SettingsRow("Signed in to \(model.gitLabRegistry)", detail: "With the token of \(instance).") {
                    DSPillView("Signed in", tone: .success, symbolName: "checkmark.circle")
                }
            }
        }
    }
}
