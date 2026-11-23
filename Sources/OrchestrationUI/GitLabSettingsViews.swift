import AppKit
import BelloCore
import DesignSystem
import Engine
import SwiftUI

/// Settings ▸ GitLab: instances (base URL, path prefix allowed) and their access tokens. A token is typed once into a
/// secure field and goes straight to the Keychain; it is never shown again. "Test" asks GitLab who the token is.
@MainActor
@Observable
public final class GitLabSettingsModel {
    public let service: MergeRequestService
    public var baseURL = ""
    public var token = ""
    /// The explicit, per-instance choice to send the token over plain HTTP (shown only for an http:// address).
    public var allowPlainHTTP = false
    public var isPlainHTTPAddress: Bool { baseURL.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://") }
    public private(set) var results: [String: String] = [:]
    public private(set) var message: String?

    /// The owner's instance is suggested until one is configured (the person still pastes the token).
    public init(service: MergeRequestService) {
        self.service = service
        if service.instances.isEmpty { baseURL = GitLabInstance.suggestedBaseURL }
    }

    public func save() async {
        let secret = token.isEmpty ? nil : SecretValue(token)
        token = ""
        do {
            let instance = try await service.saveInstance(baseURL: baseURL, token: secret, allowPlainHTTP: isPlainHTTPAddress && allowPlainHTTP)
            baseURL = ""
            allowPlainHTTP = false
            message = nil
            if secret != nil { await test(instance) }
        } catch {
            message = ExtrasError.message(error)
        }
    }

    /// Saves a new token for `instance`, then tests it. A save that fails is shown on the instance and the typed token
    /// is kept in the field to retry; the old token is not tested as if it were the new one (NV12).
    public func replaceToken(_ instance: GitLabInstance) async {
        guard !token.isEmpty else { return }
        let typed = token
        token = ""
        do {
            _ = try await service.saveInstance(baseURL: instance.baseURL, token: SecretValue(typed))
        } catch {
            if token.isEmpty { token = typed }
            results[instance.baseURL] = "The new token was not saved: \(ExtrasError.message(error))"
            return
        }
        await test(instance)
    }

    public func test(_ instance: GitLabInstance) async {
        switch await service.testConnection(instance) {
        case .success(let user): results[instance.baseURL] = "Connected as \(user)"
        case .failure(let error): results[instance.baseURL] = error.description
        }
    }

    public func remove(_ instance: GitLabInstance) async {
        do {
            try await service.removeInstance(instance)
            results[instance.baseURL] = nil
        } catch {
            results[instance.baseURL] = ExtrasError.message(error)
        }
    }
}

public struct GitLabSettingsView: View {
    let model: GitLabSettingsModel
    let confirmRemove: (GitLabInstance) -> Bool

    public init(model: GitLabSettingsModel, confirmRemove: @escaping (GitLabInstance) -> Bool) {
        self.model = model
        self.confirmRemove = confirmRemove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s8) {
            Text("Merge requests are read from your GitLab instance with a personal access token (read_api is enough to read; write actions need api). The token is kept in your Keychain, sent only to that instance, and never shown again, given to agents, or used by git.")
                .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3).fixedSize(horizontal: false, vertical: true)
            if model.service.instances.isEmpty {
                Text("No GitLab instance yet.").foregroundStyle(SwiftUI.Color.ds.text3)
            }
            ForEach(model.service.instances) { instance in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: model.service.instancesWithToken.contains(instance.baseURL) ? "key.fill" : "key.slash")
                            .foregroundStyle(SwiftUI.Color.ds.text3).accessibilityHidden(true)
                        Text(instance.baseURL).font(.body.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button("Test") { Task { await model.test(instance) } }.disabled(!model.service.instancesWithToken.contains(instance.baseURL))
                        Button("Replace Token") { Task { await model.replaceToken(instance) } }.disabled(model.token.isEmpty)
                            .help("Type the new token in the field below, then click Replace Token")
                        Button("Remove…") { if confirmRemove(instance) { Task { await model.remove(instance) } } }
                    }
                    if instance.isPlainHTTP {
                        Label("Plain HTTP: the token crosses the network unencrypted (allowed for this instance).", systemImage: "exclamationmark.triangle")
                            .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.warningText)
                    }
                    Text(status(instance)).font(.ds(.meta))
                        .foregroundStyle(model.service.instanceProblems[instance.baseURL] != nil ? SwiftUI.Color.ds.dangerText : SwiftUI.Color.ds.text3)
                    InstanceDetails(model: model, instance: instance)
                }
                SwiftUI.Color.ds.border.frame(height: 1)
            }
            VStack(alignment: .leading, spacing: DS.Space.s8) {
                HStack(spacing: DS.Space.s10) {
                    Text("Instance URL").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2).frame(width: 96, alignment: .trailing)
                    TextField("", text: Bindable(model).baseURL, prompt: Text("https://gitlab.example.com")).textFieldStyle(DSTextFieldStyle())
                        .accessibilityLabel("Instance URL")
                }
                HStack(spacing: DS.Space.s10) {
                    Text("Access token").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2).frame(width: 96, alignment: .trailing)
                    SecureField("", text: Bindable(model).token, prompt: Text("glpat-…")).textFieldStyle(DSTextFieldStyle())
                        .accessibilityLabel("GitLab access token")
                }
                if model.isPlainHTTPAddress {
                    Toggle("Allow unencrypted HTTP for this instance (the token is sent in clear text)", isOn: Bindable(model).allowPlainHTTP)
                        .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.warningText)
                }
                HStack {
                    Spacer()
                    Button("Add Instance") { Task { await model.save() } }
                        .buttonStyle(DSButtonStyle(.primary, size: .small))
                        .disabled(model.baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let message = model.message { Text(message).foregroundStyle(SwiftUI.Color.ds.dangerText) }
            BabysitPolicyEditor(service: model.service)
            Text("Git uses this token over HTTPS for clone, fetch, pull and push (scopes read_repository and write_repository, or api). It never reaches the agent, its container or the repository.")
                .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).fixedSize(horizontal: false, vertical: true)
            Text("Self-managed instances with a private CA work once that CA is trusted in Keychain Access (System trust store).")
                .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(DSButtonStyle(.outline))
        .toggleStyle(DSToggleStyle(.checkbox))
        .padding(20)
        .frame(width: 560, alignment: .topLeading)
    }

    private func status(_ instance: GitLabInstance) -> String {
        if let problem = model.service.instanceProblems[instance.baseURL] { return problem }
        if let result = model.results[instance.baseURL] { return result }
        return model.service.instancesWithToken.contains(instance.baseURL) ? "Token saved in the Keychain." : "No token yet: type one below and click Replace Token."
    }
}

/// Version, token scopes and expiry, and the per-instance switches (write actions; approve and merge).
struct InstanceDetails: View {
    let model: GitLabSettingsModel
    let instance: GitLabInstance

    var body: some View {
        let service = model.service
        let status = service.instanceStatus[instance.baseURL]
        let settings = service.settings(for: instance.baseURL)
        VStack(alignment: .leading, spacing: 2) {
            if let status {
                Text(status.capabilities.label + (status.user.map { " · signed in as @\($0)" } ?? "")).foregroundStyle(SwiftUI.Color.ds.text3)
                Text(status.token?.label ?? "Token scopes and expiry unknown (this GitLab or token type does not report them)").foregroundStyle(SwiftUI.Color.ds.text3)
            }
            if let warning = service.tokenWarning(instance.baseURL) {
                Label(warning.text, systemImage: "clock.badge.exclamationmark").foregroundStyle(SwiftUI.Color.ds.warningText)
            }
            Toggle(
                "Allow write actions (create MRs, reply, resolve, retry and run jobs; needs the api scope)",
                isOn: Binding(
                    get: { settings.writesEnabled },
                    set: { value in
                        var next = settings
                        next.writesEnabled = value
                        if !value { next.approveAndMergeEnabled = false }
                        Task { await service.setSettings(next, for: instance.baseURL) }
                    }))
            if status?.token?.allowsWrites == false && settings.writesEnabled {
                Label("This token has no api scope: GitLab will refuse changes. Replace it with one that has api.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(SwiftUI.Color.ds.warningText)
            }
            Toggle(
                "Show Approve and Merge for me (never for agents; each checks the reviewed commit)",
                isOn: Binding(
                    get: { settings.approveAndMergeEnabled },
                    set: { value in
                        var next = settings
                        next.approveAndMergeEnabled = value
                        Task { await service.setSettings(next, for: instance.baseURL) }
                    })
            )
            .disabled(!settings.writesEnabled)
        }
        .font(.ds(.meta))
    }
}

/// The babysit policy: wake budget and which events wake.
struct BabysitPolicyEditor: View {
    let service: MergeRequestService

    var body: some View {
        let policy = service.babysitPolicy
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text("Babysitting").font(.ds(.labelEmph)).foregroundStyle(SwiftUI.Color.ds.text2)
            DSStepper(
                "Wakes per hour", value: Binding(get: { policy.wakesPerHour }, set: { value in update { $0.wakesPerHour = value } }), in: 1...30)
            Toggle("Wake when a pipeline passes", isOn: Binding(get: { policy.wakeOnPipelineSuccess }, set: { value in update { $0.wakeOnPipelineSuccess = value } }))
            Toggle("Ignore my own comments", isOn: Binding(get: { policy.ignoreOwnNotes }, set: { value in update { $0.ignoreOwnNotes = value } }))
            Text(policy.summary).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).fixedSize(horizontal: false, vertical: true)
        }
        .font(.ds(.label))
    }

    private func update(_ change: (inout BabysitPolicy) -> Void) {
        var next = service.babysitPolicy
        change(&next)
        Task { await service.setBabysitPolicy(next) }
    }
}
