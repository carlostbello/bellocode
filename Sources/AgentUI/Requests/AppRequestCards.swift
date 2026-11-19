import AppKit
import BelloCore
import SwiftUI
import DesignSystem
import SecretKit

// Cards for BelloCode's own requests (docs/features/orchestration-extras.md): a secret the agent asked for, and app
// approvals (an agent's first scheduled task in a project, network hosts for an HTML visual). Same visual family as
// the permission and question cards: pinned above the composer, same chrome, same shortcuts, never auto-dismissed.

extension PendingRequestSource {
    public func respond(to request: AppRequest, _ response: AppRequestResponse) async {}
    public func savedSecretExists(label: String) -> Bool { false }
    public var placeholderSecretsAvailable: Bool { false }
}

extension PendingRequestStackModel {
    public func respond(_ request: AppRequest, _ response: AppRequestResponse) async {
        guard !source.submittingRequestIDs.contains(request.id) else { return }
        await source.respond(to: request, response)
        requestsChanged()
    }

    /// The secret card's Save. The typed value is cleared once the save succeeded (the request is resolved); a failed
    /// save keeps it so the person can correct the choice and retry instead of losing what they typed (R25). Decline
    /// clears it too.
    public func saveSecret(_ request: AppRequest, draft: SecretDraft) async {
        guard !draft.text.isEmpty else { return }
        await respond(request, .saveManagedSecret(SecretValue(draft.text), draft.choice))
        if !requests.contains(where: { $0.id == request.id }) { draft.text = "" }
    }
}

/// The secret card: label, why, an optional setup link, a secure field, and how the value will be used (secret
/// manager, docs/features/secrets.md): Placeholder, Brokered, Approved command or Visible, with the destination it is
/// bound to and what BelloCode claims about it. The typed value goes straight to the Keychain through `respond`; the
/// field is cleared once the save succeeds and the value is never shown again.
struct SecretRequestCard: View {
    let model: PendingRequestStackModel
    let request: AppRequest
    let prompt: SecretPrompt
    let count: Int
    @Bindable var draft: SecretDraft

    static func modeTitle(_ mode: SecretChoice.Mode) -> String {
        switch mode {
        case .placeholder: "Placeholder"
        case .brokered: "Brokered"
        case .command: "Approved command"
        case .visible: "Visible"
        }
    }

    var body: some View {
        let submitting = model.isSubmitting(.app(request))
        let saved = model.source.savedSecretExists(label: prompt.label)
        let placeholders = model.source.placeholderSecretsAvailable
        let _ = draft.seed(from: prompt, placeholdersAvailable: placeholders)
        CardChrome(tone: .warning) {
            RequestHeader(
                model: model, symbol: "key", tone: .warning, title: prompt.label, reason: "The agent asks for a secret",
                request: .app(request), count: count)
            VStack(alignment: .leading, spacing: DS.Space.s8) {
                Text(prompt.reason)
                    .font(.ds(.body))
                    .foregroundStyle(SwiftUI.Color.ds.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.s8) {
                    SecureField("Value for \(prompt.label)", text: $draft.text)
                        .textFieldStyle(DSTextFieldStyle())
                        .disabled(submitting)
                        .onSubmit { save() }
                        .accessibilityLabel("Secret value for \(prompt.label)")
                    if let link = prompt.setupURL.flatMap(URL.init(string:)), ["https", "http"].contains(link.scheme ?? "") {
                        Button {
                            NSWorkspace.shared.open(link)
                        } label: {
                            HStack(spacing: DS.Space.s4) {
                                Image(systemName: "arrow.up.right.square").font(.system(size: DS.Size.iconPointRow))
                                Text("Open Setup Page")
                            }
                        }
                        .buttonStyle(DSButtonStyle(.outline))
                        .help("Opens \(link.host ?? link.absoluteString) in your browser")
                    }
                }
                HStack(spacing: DS.Space.s8) {
                    Text("Use").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2)
                    DSSegmentedPicker(
                        options: SecretChoice.Mode.allCases.filter { $0 != .placeholder || placeholders }.map { ($0, Self.modeTitle($0)) },
                        selection: $draft.choice.mode)
                        .accessibilityLabel("How the value is used")
                }
                modeDetail
                if let error = model.replyError, !submitting { ReplyErrorLabel(text: error) }
                HStack(spacing: DS.Space.s8) {
                    Spacer(minLength: DS.Space.s8)
                    if submitting { SubmittingIndicator(text: "Saving…") }
                    Button("Decline") {
                        draft.text = ""
                        Task { await model.respond(request, .decline) }
                    }
                    .buttonStyle(DSButtonStyle(.outline, hint: AgentShortcut.deny.display))
                    .keyboardShortcut(.deny)
                    .help("Refuse. The agent is told you declined and gets nothing.")
                    if saved {
                        Button("Use Saved Value") {
                            draft.text = ""
                            Task { await model.respond(request, .useSavedSecret) }
                        }
                        .buttonStyle(DSButtonStyle(.outline))
                        .help("Give this thread the value already saved as “\(prompt.label)”, in the mode it was saved with")
                    }
                    Button("Save Securely") { save() }
                        .buttonStyle(DSButtonStyle(.primary, hint: AgentShortcut.submitAnswer.display))
                        .keyboardShortcut(.submitAnswer)
                        .disabled(!canSave)
                }
                .disabled(submitting)
            }
            .padding(.leading, DS.Size.iconBox + DS.Space.s8)
        }
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The agent asks for a secret: \(prompt.label)")
    }

    private var canSave: Bool {
        guard !draft.text.isEmpty else { return false }
        switch draft.choice.mode {
        case .placeholder, .brokered: return !draft.choice.destination.trimmingCharacters(in: .whitespaces).isEmpty
        case .visible: return draft.choice.confirmVisible
        case .command: return true
        }
    }

    @ViewBuilder private var modeDetail: some View {
        switch draft.choice.mode {
        case .placeholder, .brokered:
            VStack(alignment: .leading, spacing: DS.Space.s6) {
                HStack(spacing: DS.Space.s6) {
                    TextField("https://api.example.com", text: $draft.choice.destination)
                        .textFieldStyle(DSTextFieldStyle()).frame(minWidth: 180)
                        .accessibilityLabel("Destination the value may be sent to")
                    TextField("Header", text: $draft.choice.headerName)
                        .textFieldStyle(DSTextFieldStyle()).frame(width: 110)
                        .accessibilityLabel("Header that carries it")
                    TextField("Prefix", text: $draft.choice.headerPrefix)
                        .textFieldStyle(DSTextFieldStyle()).frame(width: 70)
                        .accessibilityLabel("Text before the value in the header")
                    TextField("/path", text: $draft.choice.pathPrefix)
                        .textFieldStyle(DSTextFieldStyle()).frame(width: 70)
                        .accessibilityLabel("Allowed path prefix")
                }
                HStack(spacing: DS.Space.s8) {
                    SecretClaimBadge(kind: .hidden, headline: SecretClaims.hiddenHeadline,
                                     explanation: SecretClaims.hiddenGuarantee, limits: SecretClaims.hiddenLimits)
                    Toggle("This project only", isOn: $draft.choice.projectOnly)
                        .toggleStyle(DSToggleStyle(.checkbox)).font(.ds(.label))
                }
                Text(draft.choice.mode == .placeholder
                     ? "The agent's commands get a placeholder in $\(handle). BelloCode's proxy puts the value in only for this destination and header; anywhere else the request is refused."
                     : "Only BelloCode sends it, for this destination and header (the agent asks BelloCode to make the request).")
                    .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .command:
            VStack(alignment: .leading, spacing: DS.Space.s6) {
                SecretClaimBadge(kind: .command, headline: SecretClaims.commandHeadline, explanation: SecretClaims.commandExplanation)
                Text(prompt.delivery == .file
                     ? "Saved in your Keychain. The agent gets a path that yields the value once to the first command that reads it; that command can reveal it."
                     : "Saved in your Keychain. You approve the exact command that receives it; that command can reveal it.")
                    .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .visible:
            VStack(alignment: .leading, spacing: DS.Space.s6) {
                SecretClaimBadge(kind: .visible, headline: SecretClaims.visibleHeadline, explanation: SecretClaims.visibleExplanation)
                Toggle("I understand the agent can see, print and send this value", isOn: $draft.choice.confirmVisible)
                    .toggleStyle(DSToggleStyle(.checkbox)).font(.ds(.label))
            }
        }
    }

    private var handle: String { draft.choice.name.isEmpty ? ManagedSecret.handle(from: prompt.label) : draft.choice.name }

    private func save() {
        guard canSave else { return }
        Task { await model.saveSecret(request, draft: draft) }
    }
}

/// An app approval: what, where, Allow Once / Always for this scope / Deny.
struct AppApprovalCard: View {
    let model: PendingRequestStackModel
    let request: AppRequest
    let approval: AppApproval
    let count: Int

    var body: some View {
        let submitting = model.isSubmitting(.app(request))
        CardChrome(tone: .warning) {
            RequestHeader(
                model: model, symbol: "exclamationmark.shield", tone: .warning, title: approval.title,
                request: .app(request), count: count)
            VStack(alignment: .leading, spacing: DS.Space.s8) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s8) {
                    Image(systemName: Self.symbol(approval.action))
                        .font(.system(size: DS.Size.iconPointRow))
                        .foregroundStyle(SwiftUI.Color.ds.icon)
                        .accessibilityHidden(true)
                    Text(approval.detail)
                        .font(.ds(.body))
                        .foregroundStyle(SwiftUI.Color.ds.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(scopeText)
                    .font(.ds(.label))
                    .foregroundStyle(SwiftUI.Color.ds.text3)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = model.replyError, !submitting { ReplyErrorLabel(text: error) }
                HStack(spacing: DS.Space.s8) {
                    Spacer(minLength: DS.Space.s8)
                    if submitting { SubmittingIndicator() }
                    Button("Deny") {
                        Task { await model.respond(request, .decline) }
                    }
                    .buttonStyle(DSButtonStyle(.outline, hint: AgentShortcut.deny.display))
                    .keyboardShortcut(.deny)
                    .help(denyHelp)
                    if approval.allowsAlways {
                        Button(alwaysTitle) {
                            Task { await model.respond(request, .approve(always: true)) }
                        }
                        .buttonStyle(DSButtonStyle(.outline, hint: AgentShortcut.allowAlways.display))
                        .keyboardShortcut(.allowAlways)
                        .help(scopeText)
                    }
                    Button("Allow Once") {
                        Task { await model.respond(request, .approve(always: false)) }
                    }
                    .buttonStyle(DSButtonStyle(.primary, hint: AgentShortcut.allowOnce.display))
                    .keyboardShortcut(.allowOnce)
                }
                .disabled(submitting)
            }
            .padding(.leading, DS.Size.iconBox + DS.Space.s8)
        }
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval needed: \(approval.title)")
    }

    static func symbol(_ action: AppApproval.Action) -> String {
        switch action {
        case .schedule: "calendar.badge.clock"
        case .secretCommand: "key"
        case .network: "network"
        case .gitlabBabysit: "eye"
        case .gitlabWrite: "arrow.triangle.pull"
        case .serviceRestart: "arrow.clockwise"
        case .gitPush: "arrow.up"
        case .gitForcePush: "exclamationmark.arrow.triangle.2.circlepath"
        case .browserMCP: "globe"
        }
    }

    private var alwaysTitle: String {
        switch approval.action {
        case .schedule: "Always in This Project"
        case .network: "Always for These Hosts"
        case .secretCommand: "Always for This Command"
        case .gitlabBabysit: "Always in This Project"
        case .gitlabWrite: "Always"
        case .serviceRestart: "Always in This Project"
        case .gitPush, .gitForcePush: "Always"
        case .browserMCP: "Always in This Project"
        }
    }

    private var denyHelp: String {
        switch approval.action {
        case .schedule: approval.allowsAlways ? "The scheduled task is deleted." : "The task keeps the version you approved."
        case .network: "The visual stays offline."
        case .secretCommand: "The command does not run and the secret is not used."
        case .gitlabBabysit: "The merge request stays linked but does not wake the thread."
        case .gitlabWrite: "Nothing is sent to GitLab; the agent is told."
        case .serviceRestart: "The service keeps running as it is."
        case .gitPush, .gitForcePush: "Nothing is pushed; the agent is told."
        case .browserMCP: "The agent gets no browser tools; it is told."
        }
    }

    private var scopeText: String {
        switch approval.action {
        case .schedule:
            "Project: \(approval.scope). “Always” lets agents create scheduled tasks in this project without asking again (Settings ▸ Scheduled Tasks can revoke it)."
        case .network:
            "Hosts: \(approval.scope). “Always” lets HTML visuals load from these hosts without asking again."
        case .secretCommand:
            "Project: \(approval.scope). The command can reveal this value: it receives the value and can print, encode, send or save it. Allow only a command you trust with it. “Always” runs exactly this command with this secret, in this project, without asking again (deleting the secret revokes it)."
        case .gitlabBabysit:
            "Project: \(approval.scope). Babysitting reads the merge request with your GitLab token and wakes this thread on its events (within the wake budget). “Always” lets agents babysit merge requests in this project without asking again."
        case .gitlabWrite:
            "GitLab: \(approval.scope). Sent once, with your token, exactly as shown; GitLab's own permissions and branch rules still apply. Agents can never approve, merge or close."
        case .serviceRestart:
            "Project: \(approval.scope). Restarting stops the service briefly; its data volumes are kept. “Always” lets agents restart this project's services without asking again."
        case .gitPush:
            "Remote: \(approval.scope). Pushed once from this Mac with your GitLab token, exactly as shown; GitLab's branch rules still apply."
        case .gitForcePush:
            "Remote: \(approval.scope). A force push replaces the remote branch's history: commits only on the remote are lost there. Sent with --force-with-lease, so it fails if the remote moved since this card."
        case .browserMCP:
            "Project: \(approval.scope). The shared Chrome is signed in as you, and its sign-ins are shared by every thread allowed to use it: an agent can read and act on any site you are signed in to there. “Allow Once” covers this thread only; “Always” covers every thread of this project (Settings ▸ Browser can revoke it)."
        }
    }
}
