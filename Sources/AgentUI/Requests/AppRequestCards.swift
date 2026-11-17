import AppKit
import BelloCore
import SwiftUI

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
    @Environment(\.agentUIStyle) private var style
    let model: PendingRequestStackModel
    let request: AppRequest
    let prompt: SecretPrompt
    let count: Int
    @Bindable var draft: SecretDraft

    var body: some View {
        let submitting = model.isSubmitting(.app(request))
        let saved = model.source.savedSecretExists(label: prompt.label)
        CardChrome(tint: style.attention) {
            RequestHeader(
                model: model, symbol: "key.fill", tint: style.attention, title: prompt.label, label: "Secret",
                request: .app(request), count: count)
            Text(prompt.reason)
                .font(style.bodyFont)
                .foregroundStyle(style.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: style.spacing * 2) {
                SecureField("Value for \(prompt.label)", text: $draft.text)
                    .textFieldStyle(.roundedBorder)
                    .disabled(submitting)
                    .onSubmit { save() }
                    .accessibilityLabel("Secret value for \(prompt.label)")
                if let link = prompt.setupURL.flatMap(URL.init(string:)), ["https", "http"].contains(link.scheme ?? "") {
                    Button {
                        NSWorkspace.shared.open(link)
                    } label: {
                        Label("Open Setup Page", systemImage: "arrow.up.right.square")
                    }
                    .help("Opens \(link.host ?? link.absoluteString) in your browser")
                }
            }
            Text(
                prompt.delivery == .file
                    ? "Saved in your Keychain. The agent gets a path that yields the value once to one command, never the value itself."
                    : "Saved in your Keychain. The agent gets a one-use reference, never the value itself."
            )
            .font(style.smallFont)
            .foregroundStyle(style.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            if let error = model.replyError, !submitting {
                Label(error, systemImage: "exclamationmark.circle").font(style.smallFont).foregroundStyle(style.danger)
            }
            HStack(spacing: style.spacing * 2) {
                Button {
                    draft.text = ""
                    Task { await model.respond(request, .decline) }
                } label: {
                    HStack(spacing: 6) { Text("Decline"); KeyCap(shortcut: .deny) }
                }
                .keyboardShortcut(.deny)
                .help("Refuse. The agent is told you declined and gets nothing.")
                if saved {
                    Button("Use Saved Value") {
                        draft.text = ""
                        Task { await model.respond(request, .useSavedSecret) }
                    }
                    .help("Give the agent a new reference to the value already saved as “\(prompt.label)”")
                }
                Spacer()
                if submitting {
                    ProgressView().controlSize(.small)
                    Text("Saving…").font(style.smallFont).foregroundStyle(style.secondaryText)
                }
                Button {
                    save()
                } label: {
                    HStack(spacing: 6) { Text("Save Securely"); KeyCap(shortcut: .submitAnswer) }
                }
                .keyboardShortcut(.submitAnswer)
                .buttonStyle(.borderedProminent)
                .disabled(draft.text.isEmpty)
            }
            .disabled(submitting)
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
    @Environment(\.agentUIStyle) private var style
    let model: PendingRequestStackModel
    let request: AppRequest
    let approval: AppApproval
    let count: Int

    var body: some View {
        let submitting = model.isSubmitting(.app(request))
        CardChrome(tint: style.attention) {
            RequestHeader(
                model: model, symbol: approval.action == .schedule ? "calendar.badge.clock" : "network", tint: style.attention,
                title: approval.title, label: "Approval", request: .app(request), count: count)
            Text(approval.detail)
                .font(style.bodyFont)
                .foregroundStyle(style.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(scopeText)
                .font(style.smallFont)
                .foregroundStyle(style.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.replyError, !submitting {
                Label(error, systemImage: "exclamationmark.circle").font(style.smallFont).foregroundStyle(style.danger)
            }
            HStack(spacing: style.spacing * 2) {
                Button {
                    Task { await model.respond(request, .decline) }
                } label: {
                    HStack(spacing: 6) { Text("Deny"); KeyCap(shortcut: .deny) }
                }
                .keyboardShortcut(.deny)
                .help(approval.action == .schedule ? "The scheduled task is deleted." : "The visual stays offline.")
                Spacer()
                if submitting {
                    ProgressView().controlSize(.small)
                    Text("Sending…").font(style.smallFont).foregroundStyle(style.secondaryText)
                }
                if approval.allowsAlways {
                    Button {
                        Task { await model.respond(request, .approve(always: true)) }
                    } label: {
                        HStack(spacing: 6) { Text(alwaysTitle); KeyCap(shortcut: .allowAlways) }
                    }
                    .keyboardShortcut(.allowAlways)
                    .help(scopeText)
                }
                Button {
                    Task { await model.respond(request, .approve(always: false)) }
                } label: {
                    HStack(spacing: 6) { Text("Allow Once"); KeyCap(shortcut: .allowOnce) }
                }
                .keyboardShortcut(.allowOnce)
                .buttonStyle(.borderedProminent)
            }
            .disabled(submitting)
        }
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval needed: \(approval.title)")
    }

    private var alwaysTitle: String {
        approval.action == .schedule ? "Always in This Project" : "Always for These Hosts"
    }

    private var scopeText: String {
        switch approval.action {
        case .schedule:
            "Project: \(approval.scope). “Always” lets agents create scheduled tasks in this project without asking again (Settings ▸ Scheduled Tasks can revoke it)."
        case .network:
            "Hosts: \(approval.scope). “Always” lets HTML visuals load from these hosts without asking again."
        }
    }
}
