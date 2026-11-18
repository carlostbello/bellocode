import AppKit
import BelloCore
import SwiftUI
import DesignSystem

// Cards for BelloCode's own requests (docs/features/orchestration-extras.md): a secret the agent asked for, and app
// approvals (an agent's first scheduled task in a project, network hosts for an HTML visual). Same visual family as
// the permission and question cards: pinned above the composer, same chrome, same shortcuts, never auto-dismissed.

extension PendingRequestSource {
    public func respond(to request: AppRequest, _ response: AppRequestResponse) async {}
    public func savedSecretExists(label: String) -> Bool { false }
}

extension PendingRequestStackModel {
    public func respond(_ request: AppRequest, _ response: AppRequestResponse) async {
        guard !source.submittingRequestIDs.contains(request.id) else { return }
        await source.respond(to: request, response)
        requestsChanged()
    }
}

/// The secret card: label, why, an optional setup link, a secure field. The typed value goes straight to the
/// Keychain through `respond`; the field is cleared at once and the value is never shown again.
struct SecretRequestCard: View {
    let model: PendingRequestStackModel
    let request: AppRequest
    let prompt: SecretPrompt
    let count: Int
    @Bindable var draft: SecretDraft

    var body: some View {
        let submitting = model.isSubmitting(.app(request))
        let saved = model.source.savedSecretExists(label: prompt.label)
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
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s6) {
                    Image(systemName: "lock").font(.system(size: DS.Size.iconPointMeta)).foregroundStyle(SwiftUI.Color.ds.text3)
                    Text(
                        prompt.delivery == .file
                            ? "Saved in your Keychain. The agent gets a path that yields the value once to the first command that reads it; that command, which the agent chooses, can reveal it."
                            : "Saved in your Keychain. The agent gets a one-use reference, not the value. In a container project you approve the exact command that receives it; any command that receives it can reveal it."
                    )
                    .font(.ds(.label))
                    .foregroundStyle(SwiftUI.Color.ds.text3)
                    .fixedSize(horizontal: false, vertical: true)
                }
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
                        .help("Give the agent a new reference to the value already saved as “\(prompt.label)”")
                    }
                    Button("Save Securely") { save() }
                        .buttonStyle(DSButtonStyle(.primary, hint: AgentShortcut.submitAnswer.display))
                        .keyboardShortcut(.submitAnswer)
                        .disabled(draft.text.isEmpty)
                }
                .disabled(submitting)
            }
            .padding(.leading, DS.Size.iconBox + DS.Space.s8)
        }
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The agent asks for a secret: \(prompt.label)")
    }

    private func save() {
        guard !draft.text.isEmpty else { return }
        let secret = SecretValue(draft.text)
        draft.text = ""
        Task { await model.respond(request, .saveSecret(secret)) }
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
        }
    }

    private var scopeText: String {
        switch approval.action {
        case .schedule:
            "Project: \(approval.scope). “Always” lets agents create scheduled tasks in this project without asking again (Settings ▸ Scheduled Tasks can revoke it)."
        case .network:
            "Hosts: \(approval.scope). “Always” lets HTML visuals load from these hosts without asking again."
        case .secretCommand:
            "Project: \(approval.scope). The command receives the value and can reveal it (print, encode, send or save it): allow only a command you trust with it. “Always” runs exactly this command with this secret, in this project, without asking again (deleting the secret revokes it)."
        case .gitlabBabysit:
            "Project: \(approval.scope). Babysitting reads the merge request with your GitLab token and wakes this thread on its events (within the wake budget). “Always” lets agents babysit merge requests in this project without asking again."
        case .gitlabWrite:
            "GitLab: \(approval.scope). Sent once, with your token, exactly as shown; GitLab's own permissions and branch rules still apply. Agents can never approve, merge or close."
        case .serviceRestart:
            "Project: \(approval.scope). Restarting stops the service briefly; its data volumes are kept. “Always” lets agents restart this project's services without asking again."
        }
    }
}
