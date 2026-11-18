import AppKit
import BelloCore
import Combine
import DesignSystem
import Engine
import SecretKit
import SwiftUI

/// Settings ▸ Secrets (docs/features/secrets.md): every secret by label (never a value) with its handle, use mode,
/// scope, bound destinations, what BelloCode claims about it and its last use; add, change mode or bindings, rotate,
/// revoke and delete; the audit; the built-in brokered tokens; the egress proxy's state; hosts HTML visuals may load.
public struct SecretManagerSettingsView: View {
    let manager: SecretManager
    let visuals: VisualService
    let confirm: (String, String, String) -> Bool
    @StateObject private var state = SecretsSettingsState()

    /// `confirm(title, detail, button)` shows a confirmation (deletion, which cannot be undone).
    public init(manager: SecretManager, visuals: VisualService, confirm: @escaping (String, String, String) -> Bool) {
        self.manager = manager
        self.visuals = visuals
        self.confirm = confirm
    }

    /// Snapshot harness: start with a row selected or the add form open.
    public init(manager: SecretManager, visuals: VisualService, selected: String?, adding: Bool = false) {
        self.init(manager: manager, visuals: visuals) { _, _, _ in false }
        _state = StateObject(wrappedValue: SecretsSettingsState(selected: selected, adding: adding))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s10) {
            header
            if state.adding { SecretEditorForm(manager: manager, state: state) }
            if manager.secrets.isEmpty && !state.adding {
                Text("No secrets yet. Agents ask for one with a card, or add one here.")
                    .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3)
            }
            VStack(spacing: 0) {
                ForEach(manager.secrets) { secret in
                    SecretRow(secret: secret, lastUse: manager.lastUse[secret.account], selected: state.selected == secret.account)
                        .contentShape(Rectangle())
                        .onTapGesture { state.select(secret.account, manager: manager) }
                    if state.selected == secret.account {
                        SecretDetail(manager: manager, secret: secret, state: state, confirm: confirm)
                    }
                    SwiftUI.Color.ds.border.frame(height: 1)
                }
            }
            if let error = manager.lastError ?? state.error { Text(error).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.dangerText) }
            builtIn
            egressSettings
            visualHosts
        }
        .buttonStyle(DSButtonStyle(.outline))
        .toggleStyle(DSToggleStyle(.checkbox))
        .padding(20)
        .frame(width: 620, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            HStack {
                Text("Secrets").font(.ds(.title))
                Spacer()
                Button(state.adding ? "Cancel" : "Add Secret…") { state.adding.toggle(); state.error = nil }
                    .keyboardShortcut("n", modifiers: [.command])
            }
            Text("Values stay in your Keychain and are never shown, logged or sent to a model. Each secret's mode decides who may use it.")
                .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s6) {
                Image(systemName: egressSymbol).foregroundStyle(egressColor).accessibilityHidden(true)
                Text("Egress proxy: \(egressText)").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2)
                if let fingerprint = manager.authorityFingerprint {
                    Text("CA \(fingerprint.prefix(12))…").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).textSelection(.enabled)
                }
                if manager.auditGap > 0 {
                    Text("Audit incomplete (\(manager.auditGap) events dropped)").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.warningText)
                }
            }
        }
    }

    private var egressText: String {
        switch manager.egressStatus {
        case .off: "off: placeholder secrets are unavailable"
        case .starting: "starting…"
        case .ready: "running; container traffic goes through it"
        case .failed(let reason): "failed (\(reason)). Containers have no network until it runs."
        }
    }

    private var egressSymbol: String {
        switch manager.egressStatus {
        case .ready: "checkmark.shield"
        case .failed: "xmark.shield"
        default: "shield"
        }
    }

    private var egressColor: SwiftUI.Color {
        switch manager.egressStatus {
        case .ready: SwiftUI.Color.ds.successText
        case .failed: SwiftUI.Color.ds.dangerText
        default: SwiftUI.Color.ds.text3
        }
    }

    @ViewBuilder private var builtIn: some View {
        let rows = manager.builtInBrokered()
        if !rows.isEmpty {
            Text("Used only by BelloCode").font(.ds(.title))
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: DS.Space.s8) {
                    Image(systemName: "key.horizontal").foregroundStyle(SwiftUI.Color.ds.text3).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DS.Space.s2) {
                        HStack(spacing: DS.Space.s6) {
                            Text(row.label).font(.ds(.bodyEmph))
                            DSPillView("Brokered", tone: .neutral)
                        }
                        Text("\(row.destination) · \(row.operations)").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
                            .fixedSize(horizontal: false, vertical: true)
                        if let problem = row.problem { Text(problem).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.dangerText) }
                    }
                    Spacer()
                    SecretClaimBadge(kind: .hidden, headline: SecretClaims.hiddenHeadline, explanation: SecretClaims.hiddenGuarantee,
                                     limits: SecretClaims.hiddenLimits)
                }
                .padding(.vertical, DS.Space.s4)
            }
            Text("Managed in Settings ▸ GitLab. Agents use these only through BelloCode's GitLab tools and git's credential helper.")
                .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
        }
    }

    @ViewBuilder private var egressSettings: some View {
        SwiftUI.Color.ds.border.frame(height: 1)
        Text("Container network").font(.ds(.title))
        Toggle("Route all container traffic through BelloCode's proxy (needed for placeholder secrets)", isOn: Binding(
            get: { manager.enforceEgressSetting }, set: { manager.enforceEgressSetting = $0; state.objectWillChange.send() }))
            .disabled(SecretManagerConfiguration.egressForcedByAdministrator)
        Text(SecretManagerConfiguration.egressForcedByAdministrator
             ? "Set by your administrator."
             : "Applies at the next launch. Off: containers reach the network directly and placeholder secrets are unavailable.")
            .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
        let projects = manager.egressProjects
        if !projects.isEmpty {
            HStack(spacing: DS.Space.s6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(SwiftUI.Color.ds.warningText).accessibilityHidden(true)
                Text("Uninspected destinations: no secret protection").font(.ds(.labelEmph)).foregroundStyle(SwiftUI.Color.ds.warningText)
            }
            Text("Non-HTTP services a project needs (SSH, databases): host:port pairs reached by a raw tunnel through the proxy, never inspected and never given a secret. Everything else that is not HTTP stays blocked.")
                .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s6) {
                DSMenuSelect("Project", options: projects.map { ($0, ($0 as NSString).lastPathComponent) },
                             selection: Binding(get: { state.rawProject ?? projects[0] }, set: { state.rawProject = $0; state.rawText = manager.rawEgressAllowlist(projectDirectory: $0).joined(separator: ", ") }))
                TextField("db.internal:5432, git.example.com:22", text: $state.rawText).textFieldStyle(DSTextFieldStyle())
                Button("Save") {
                    let project = state.rawProject ?? projects[0]
                    manager.setRawEgressAllowlist(state.rawText.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init), projectDirectory: project)
                    state.rawText = manager.rawEgressAllowlist(projectDirectory: project).joined(separator: ", ")
                }
            }
        }
    }

    @ViewBuilder private var visualHosts: some View {
        SwiftUI.Color.ds.border.frame(height: 1)
        Text("Network hosts HTML visuals may load from").font(.ds(.title))
        if visuals.networkGrants.isEmpty {
            Text("None. Visuals load nothing from the network unless you allow a host.").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3)
        } else {
            ForEach(visuals.networkGrants, id: \.self) { host in
                HStack {
                    Text(host).font(.body.monospaced())
                    Spacer()
                    Button("Revoke") { Task { try? await visuals.revokeNetwork(host) } }
                }
            }
        }
        ForEach(visuals.pendingNetworkRevocations, id: \.self) { host in
            HStack {
                Text(host).font(.body.monospaced())
                Text("Removal pending").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.dangerText)
                Spacer()
                Button("Retry") { Task { try? await visuals.revokeNetwork(host) } }
            }
        }
        if let error = visuals.revocationError { Text(error).foregroundStyle(SwiftUI.Color.ds.dangerText) }
    }
}

/// Editing state that outlives a redraw (no `@State` here: SwiftUI's macro plugin is unavailable).
@MainActor
final class SecretsSettingsState: ObservableObject {
    @Published var selected: String?
    @Published var adding: Bool
    @Published var error: String?
    @Published var audit: [SecretAuditEntry] = []
    // Add form.
    @Published var label = ""
    @Published var name = ""
    @Published var value = ""
    @Published var mode: SecretUseMode = .placeholder
    @Published var destination = ""
    @Published var header = "Authorization"
    @Published var prefix = "Bearer "
    @Published var path = ""
    @Published var confirmVisible = false
    // Detail.
    @Published var rotateValue = ""
    @Published var newDestination = ""
    @Published var newHeader = "Authorization"
    @Published var newPrefix = "Bearer "
    @Published var newPath = ""
    // Raw egress allowlist.
    @Published var rawProject: String?
    @Published var rawText = ""

    init(selected: String? = nil, adding: Bool = false) {
        self.selected = selected
        self.adding = adding
    }

    func select(_ account: String, manager: SecretManager) {
        selected = selected == account ? nil : account
        error = nil
        guard let selected else { return }
        Task { self.audit = await manager.audit(account: selected, limit: 20) }
    }
}

struct SecretRow: View {
    let secret: ManagedSecret
    let lastUse: SecretAuditEntry?
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s8) {
            Image(systemName: secret.revoked ? "key.slash" : "key.fill").foregroundStyle(SwiftUI.Color.ds.text3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack(spacing: DS.Space.s6) {
                    Text(secret.label).font(.ds(.bodyEmph))
                    Text(secret.name).font(.ds(.codeSmall)).foregroundStyle(SwiftUI.Color.ds.text2)
                    DSPillView(secret.mode == .visible && !secret.visibleConfirmed ? "Approved commands" : secret.mode.title,
                               tone: secret.mode == .visible ? .warning : .neutral)
                    if secret.revoked { DSPillView("Revoked", tone: .danger, symbolName: "nosign") }
                }
                Text(summary).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).lineLimit(2)
            }
            Spacer(minLength: DS.Space.s8)
            SecretModeClaim(secret: secret)
            Image(systemName: selected ? "chevron.down" : "chevron.right").foregroundStyle(SwiftUI.Color.ds.text4).accessibilityHidden(true)
        }
        .padding(.vertical, DS.Space.s6)
        .padding(.horizontal, DS.Space.s4)
        .background(selected ? SwiftUI.Color.ds.rowSelected : SwiftUI.Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var summary: String {
        var parts = [secret.scope.title]
        if !secret.bindings.isEmpty { parts.append(secret.bindings.map(\.origin).joined(separator: ", ")) }
        if let lastUse {
            parts.append("last used \(lastUse.at.formatted(date: .abbreviated, time: .shortened)) · \(lastUse.outcome.rawValue)")
        } else {
            parts.append("not used yet")
        }
        return parts.joined(separator: " · ")
    }
}

/// The claim for a secret's mode, with its popover.
struct SecretModeClaim: View {
    let secret: ManagedSecret

    var body: some View {
        switch secret.mode {
        case .brokered, .placeholder:
            SecretClaimBadge(kind: .hidden, headline: SecretClaims.hiddenHeadline, explanation: SecretClaims.hiddenGuarantee, limits: SecretClaims.hiddenLimits)
        case .visible where secret.visibleConfirmed:
            SecretClaimBadge(kind: .visible, headline: SecretClaims.visibleHeadline, explanation: SecretClaims.visibleExplanation)
        case .visible:
            SecretClaimBadge(kind: .command, headline: SecretClaims.commandHeadline, explanation: SecretClaims.commandExplanation)
        }
    }
}

/// Add a secret.
struct SecretEditorForm: View {
    let manager: SecretManager
    @ObservedObject var state: SecretsSettingsState

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            HStack(spacing: DS.Space.s6) {
                TextField("Label, e.g. OpenAI API key", text: $state.label).textFieldStyle(DSTextFieldStyle())
                TextField("NAME", text: $state.name).textFieldStyle(DSTextFieldStyle()).frame(width: 160)
            }
            SecureField("Value", text: $state.value).textFieldStyle(DSTextFieldStyle()).accessibilityLabel("Secret value")
            DSSegmentedPicker(options: SecretUseMode.allCases.map { ($0, $0.title) }, selection: $state.mode)
            Text(state.mode.summary).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3)
            if state.mode != .visible {
                HStack(spacing: DS.Space.s6) {
                    TextField("https://api.example.com", text: $state.destination).textFieldStyle(DSTextFieldStyle())
                    TextField("Header", text: $state.header).textFieldStyle(DSTextFieldStyle()).frame(width: 110)
                    TextField("Prefix", text: $state.prefix).textFieldStyle(DSTextFieldStyle()).frame(width: 70)
                    TextField("/path", text: $state.path).textFieldStyle(DSTextFieldStyle()).frame(width: 70)
                }
            } else {
                Toggle("I understand the agent can see, print and send this value", isOn: $state.confirmVisible)
            }
            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(DSButtonStyle(.primary))
                    .disabled(state.label.isEmpty || state.value.isEmpty)
            }
        }
        .padding(DS.Space.s10)
        .background(SwiftUI.Color.ds.raised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
    }

    private func save() {
        let value = SecretValue(state.value)
        state.value = ""
        let choice = SecretChoice(mode: SecretChoice.Mode(rawValue: state.mode.rawValue) ?? .placeholder, destination: state.destination,
                                  headerName: state.header, headerPrefix: state.prefix, pathPrefix: state.path)
        Task {
            do {
                let bindings = state.mode == .visible ? [] : [try SecretManager.binding(from: choice)]
                try await manager.create(label: state.label, name: state.name.isEmpty ? nil : state.name, value: value, mode: state.mode,
                                         bindings: bindings, confirmVisible: state.confirmVisible)
                state.adding = false
                state.label = ""
                state.name = ""
                state.error = nil
            } catch {
                state.error = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
            }
        }
    }
}

/// A selected secret: bindings, mode, rotate, revoke, delete, audit.
struct SecretDetail: View {
    let manager: SecretManager
    let secret: ManagedSecret
    @ObservedObject var state: SecretsSettingsState
    let confirm: (String, String, String) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s8) {
            HStack(spacing: DS.Space.s8) {
                Text("Mode").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2)
                DSSegmentedPicker(options: SecretUseMode.allCases.map { ($0, $0.title) },
                                  selection: Binding(get: { secret.mode }, set: { change(mode: $0) }))
            }
            if !secret.bindings.isEmpty {
                Text("May be sent to").font(.ds(.labelEmph)).foregroundStyle(SwiftUI.Color.ds.text2)
                ForEach(secret.bindings) { binding in
                    HStack {
                        Text(SecretManager.describe(binding)).font(.ds(.label)).fixedSize(horizontal: false, vertical: true)
                        if let limit = binding.maxUses { Text("\(secret.uses[binding.id] ?? 0)/\(limit) uses").font(.ds(.meta)) }
                        if let expires = binding.expires { Text("until \(expires.formatted(date: .abbreviated, time: .shortened))").font(.ds(.meta)) }
                        Spacer()
                        Button("Remove") { remove(binding) }.disabled(secret.bindings.count == 1 && secret.mode == .placeholder)
                    }
                }
            }
            if secret.mode != .visible {
                HStack(spacing: DS.Space.s6) {
                    TextField("https://api.example.com", text: $state.newDestination).textFieldStyle(DSTextFieldStyle())
                    TextField("Header", text: $state.newHeader).textFieldStyle(DSTextFieldStyle()).frame(width: 110)
                    TextField("Prefix", text: $state.newPrefix).textFieldStyle(DSTextFieldStyle()).frame(width: 70)
                    TextField("/path", text: $state.newPath).textFieldStyle(DSTextFieldStyle()).frame(width: 70)
                    Button("Add Destination") { addBinding() }.disabled(state.newDestination.isEmpty)
                }
            }
            HStack(spacing: DS.Space.s6) {
                SecureField("New value", text: $state.rotateValue).textFieldStyle(DSTextFieldStyle()).frame(width: 220)
                    .accessibilityLabel("New value for \(secret.label)")
                Button("Rotate") { rotate() }.disabled(state.rotateValue.isEmpty)
                    .help("Replace the value; placeholders and handles stay the same")
                Spacer()
                if secret.revoked {
                    Button("Restore") { Task { try? await manager.restore(account: secret.account) } }
                } else {
                    Button("Revoke") { Task { try? await manager.revoke(account: secret.account) } }
                        .help("Stop every use now; placeholders already given stop working")
                }
                Button("Delete…") {
                    if confirm("Delete “\(secret.label)”?", "The value is removed from your Keychain and its placeholders and handles stop working. This cannot be undone.", "Delete") {
                        Task { await manager.delete(account: secret.account) }
                    }
                }
            }
            Text("Recent use").font(.ds(.labelEmph)).foregroundStyle(SwiftUI.Color.ds.text2)
            if state.audit.isEmpty {
                Text("Nothing yet.").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
            } else {
                ForEach(state.audit) { entry in
                    HStack(spacing: DS.Space.s6) {
                        Text(entry.at.formatted(date: .omitted, time: .standard)).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
                        DSPillView(Self.outcomeTitle(entry.outcome), tone: Self.tone(entry.outcome))
                        Text([entry.method, entry.destination].filter { !$0.isEmpty }.joined(separator: " ")).font(.ds(.codeSmall)).lineLimit(1)
                        if let status = entry.status { Text("\(status)").font(.ds(.meta)) }
                        Text(entry.detail).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).lineLimit(1)
                        Spacer()
                        if let session = entry.sessionID { Text(String(session.suffix(8))).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text4) }
                    }
                }
            }
        }
        .padding(DS.Space.s10)
        .background(SwiftUI.Color.ds.fillSubtle)
    }

    static func outcomeTitle(_ outcome: SecretAuditEntry.Outcome) -> String {
        switch outcome {
        case .substituted: "Substituted"
        case .brokered: "Brokered"
        case .refused: "Refused"
        case .responseRedacted: "Echo redacted"
        case .responseBlocked: "Response blocked"
        case .revealed: "Shown to agent"
        case .rotated: "Rotated"
        case .revoked: "Revoked"
        case .created: "Saved"
        }
    }

    static func tone(_ outcome: SecretAuditEntry.Outcome) -> DS.Tone {
        switch outcome {
        case .substituted, .brokered: .success
        case .refused, .responseBlocked: .danger
        case .responseRedacted, .revealed: .warning
        default: .neutral
        }
    }

    private func change(mode: SecretUseMode) {
        var next = secret
        next.mode = mode
        if mode == .visible, !secret.visibleConfirmed,
           !confirm("Let the agent see “\(secret.label)”?", SecretClaims.visibleExplanation, "Allow") { return }
        Task {
            do { try await manager.update(next, confirmVisible: mode == .visible) } catch { state.error = String(describing: error) }
        }
    }

    private func remove(_ binding: SecretBinding) {
        var next = secret
        next.bindings.removeAll { $0.id == binding.id }
        Task { do { try await manager.update(next) } catch { state.error = String(describing: error) } }
    }

    private func addBinding() {
        let choice = SecretChoice(mode: .placeholder, destination: state.newDestination, headerName: state.newHeader,
                                  headerPrefix: state.newPrefix, pathPrefix: state.newPath)
        Task {
            do {
                var next = secret
                next.bindings.append(try SecretManager.binding(from: choice))
                try await manager.update(next)
                state.newDestination = ""
                state.newPath = ""
            } catch {
                state.error = String(describing: error)
            }
        }
    }

    private func rotate() {
        let value = SecretValue(state.rotateValue)
        state.rotateValue = ""
        Task {
            do {
                try await manager.rotate(account: secret.account, value: value)
                state.audit = await manager.audit(account: secret.account, limit: 20)
            } catch {
                state.error = String(describing: error)
            }
        }
    }
}
