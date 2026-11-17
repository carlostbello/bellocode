import AppKit
import BelloCore
import SwiftUI

/// The pinned decision surface above the composer: one card for the request in front, a count and previous/next when
/// several wait. Zero height when nothing is pending. Requests leave only when the server acknowledged the reply.
public struct PendingRequestStackView: View {
    @Environment(\.agentUIStyle) private var style
    @Bindable var model: PendingRequestStackModel

    public init(model: PendingRequestStackModel) {
        self.model = model
    }

    public var body: some View {
        let requests = model.requests
        Group {
            if let current = model.current {
                VStack(spacing: 0) {
                    card(for: current, count: requests.count)
                        .id(current.id)
                    if requests.count > 1 { stackEdges(min(requests.count - 1, 2)) }
                }
                .padding(.horizontal, style.spacing * 2)
                .padding(.vertical, style.spacing)
            }
        }
        .noImplicitAnimation()
        .onChange(of: requests.map(\.id), initial: true) { _, _ in model.requestsChanged() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(requests.isEmpty ? "" : "\(requests.count) pending \(requests.count == 1 ? "request" : "requests")")
    }

    @ViewBuilder
    private func card(for request: PendingRequest, count: Int) -> some View {
        switch request {
        case .permission(let permission):
            PermissionCard(model: model, request: permission, count: count)
        case .question(let question):
            QuestionCard(model: model, request: question, form: model.form(for: question), count: count)
        case .app(let app):
            switch app.kind {
            case .secret(let prompt): SecretRequestCard(model: model, request: app, prompt: prompt, count: count, draft: model.secretDraft(for: app))
            case .approval(let approval): AppApprovalCard(model: model, request: app, approval: approval, count: count)
            }
        }
    }

    /// Thin edges under the card: more requests wait behind it.
    private func stackEdges(_ count: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                UnevenRoundedRectangle(bottomLeadingRadius: style.cornerRadius, bottomTrailingRadius: style.cornerRadius)
                    .fill(style.surface)
                    .overlay(
                        UnevenRoundedRectangle(bottomLeadingRadius: style.cornerRadius, bottomTrailingRadius: style.cornerRadius)
                            .strokeBorder(style.separator, lineWidth: 0.5))
                    .frame(height: 4)
                    .padding(.horizontal, CGFloat(index + 1) * 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Header shared by both cards: icon, title, origin, age, and the "1 of 3" navigator.
struct RequestHeader: View {
    @Environment(\.agentUIStyle) private var style
    let model: PendingRequestStackModel
    let symbol: String
    let tint: Color
    let title: String
    let label: String
    let request: PendingRequest
    let count: Int

    var body: some View {
        HStack(spacing: style.spacing * 2) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(label)
                .font(style.smallFont.weight(.semibold))
                .foregroundStyle(tint)
                .textCase(.uppercase)
            Text(title).font(style.titleFont).foregroundStyle(style.primaryText).lineLimit(1)
            if let origin = model.origin(of: request) {
                Label("from \(origin)", systemImage: "arrow.turn.down.right")
                    .font(style.smallFont)
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
                    .help("Asked by the sub-agent thread “\(origin)”")
            }
            Spacer(minLength: style.spacing)
            AgeText(date: request.received.date)
                .font(style.smallFont)
                .foregroundStyle(style.secondaryText)
                .accessibilityLabel("waiting")
            if count > 1 {
                HStack(spacing: 0) {
                    Button(action: model.showPrevious) { Image(systemName: "chevron.left") }
                        .keyboardShortcut(.previousRequest)
                        .help("Previous request (\(AgentShortcut.previousRequest.display))")
                        .accessibilityLabel("Previous request")
                    Text("\(model.currentIndex + 1) of \(count)")
                        .font(style.smallFont.monospacedDigit())
                        .foregroundStyle(style.secondaryText)
                        .frame(minWidth: 40)
                    Button(action: model.showNext) { Image(systemName: "chevron.right") }
                        .keyboardShortcut(.nextRequest)
                        .help("Next request (\(AgentShortcut.nextRequest.display))")
                        .accessibilityLabel("Next request")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }
}

/// The card frame: surface, hairline border, attention edge on the leading side.
struct CardChrome<Content: View>: View {
    @Environment(\.agentUIStyle) private var style
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: style.spacing * 2) { content }
            .padding(.vertical, style.spacing * 2.5)
            .padding(.leading, style.spacing * 3.5)
            .padding(.trailing, style.spacing * 3)
            .background(style.surface, in: RoundedRectangle(cornerRadius: style.cornerRadius))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: style.cornerRadius, bottomLeadingRadius: style.cornerRadius)
                    .fill(tint)
                    .frame(width: 3)
            }
            .overlay(RoundedRectangle(cornerRadius: style.cornerRadius).strokeBorder(style.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}

// MARK: - Permission

struct PermissionCard: View {
    @Environment(\.agentUIStyle) private var style
    let model: PendingRequestStackModel
    let request: PermissionRequest
    let count: Int
    @FocusState private var focus: Focus?

    enum Focus: Hashable { case deny, once, always, note }

    var body: some View {
        let presentation = model.presentation(request)
        let submitting = model.isSubmitting(.permission(request))
        let id = request.id.rawValue
        CardChrome(tint: style.attention) {
            RequestHeader(
                model: model, symbol: presentation.symbolName, tint: style.attention, title: presentation.title,
                label: "Approval", request: .permission(request), count: count)
            targets(presentation)
            if let caution = presentation.caution {
                Label(caution, systemImage: "exclamationmark.triangle.fill")
                    .font(style.smallFont)
                    .foregroundStyle(style.primaryText)
                    .symbolRenderingMode(.multicolor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = request.message, !reason.isEmpty {
                Text("“\(reason)”").font(style.smallFont).foregroundStyle(style.secondaryText).italic()
            }
            context
            DisclosureGroup(isExpanded: Binding(
                get: { model.expandedDetails.contains(id) },
                set: { if $0 { model.expandedDetails.insert(id) } else { model.expandedDetails.remove(id) } })
            ) {
                rawDetails(presentation)
            } label: {
                Text("Details").font(style.smallFont).foregroundStyle(style.secondaryText)
            }
            .controlSize(.small)
            if model.noteOpen.contains(id) {
                TextField("Tell the agent why (optional)", text: Binding(
                    get: { model.notes[id] ?? "" }, set: { model.notes[id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .note)
                    .onSubmit { Task { await model.reply(.reject, to: request) } }
                    .onExitCommand { model.noteOpen.remove(id) }
            }
            buttons(presentation, submitting: submitting)
            if let error = model.replyError, !submitting {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(style.smallFont).foregroundStyle(style.danger)
            }
        }
        .focusSection()
        .defaultFocus($focus, .deny)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval needed: \(presentation.title), \(presentation.summary)")
    }

    @ViewBuilder
    private func targets(_ presentation: PermissionPresentation) -> some View {
        let shown = presentation.targets.filter { !$0.isEmpty }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(shown.prefix(6).enumerated()), id: \.offset) { _, target in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if presentation.targetsAreCommands {
                            Text("$").foregroundStyle(style.secondaryText)
                        }
                        Text(target).foregroundStyle(style.primaryText).textSelection(.enabled)
                    }
                }
                if shown.count > 6 {
                    Text("and \(shown.count - 6) more (see Details)").foregroundStyle(style.secondaryText)
                }
            }
            .font(style.monospacedFont)
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, style.spacing * 2)
            .padding(.vertical, style.spacing * 1.5)
            .background(style.inset, in: RoundedRectangle(cornerRadius: style.cornerRadius - 3))
            .overlay(RoundedRectangle(cornerRadius: style.cornerRadius - 3).strokeBorder(style.separator.opacity(0.6), lineWidth: 0.5))
        }
    }

    private var context: some View {
        let session = model.session(of: .permission(request))
        return HStack(spacing: style.spacing * 3) {
            if let directory = session?.directory {
                Label(PermissionPresentation.lastComponent(directory), systemImage: "folder")
                    .help(directory)
                    .accessibilityLabel("Working directory \(directory)")
            }
            if let agent = session?.agent {
                Label(agent, systemImage: "person.crop.circle").accessibilityLabel("Agent \(agent)")
            }
            if let title = session?.title {
                Label(title, systemImage: "text.bubble").lineLimit(1).accessibilityLabel("Thread \(title)")
            }
        }
        .font(style.smallFont)
        .foregroundStyle(style.secondaryText)
        .labelStyle(CompactLabelStyle())
    }

    private func rawDetails(_ presentation: PermissionPresentation) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: style.spacing * 3, verticalSpacing: 2) {
            row("Action", request.action)
            row("Resources", request.resources.isEmpty ? "—" : request.resources.joined(separator: "\n"))
            row("Always rule", presentation.alwaysRules.isEmpty ? "none offered" : presentation.alwaysRules.joined(separator: "\n"))
            row("Directory", model.session(of: .permission(request))?.directory ?? "—")
            row("Session", request.sessionID.rawValue)
            if let call = request.toolCallID { row("Tool call", call) }
            row("Request", request.id.rawValue)
        }
        .font(style.monospacedFont)
        .textSelection(.enabled)
        .padding(.top, style.spacing)
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(style.secondaryText).gridColumnAlignment(.trailing)
            Text(value).foregroundStyle(style.primaryText).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func buttons(_ presentation: PermissionPresentation, submitting: Bool) -> some View {
        let id = request.id.rawValue
        return VStack(alignment: .leading, spacing: style.spacing * 1.5) {
            HStack(spacing: style.spacing * 2) {
                Button {
                    Task { await model.reply(.reject, to: request) }
                } label: {
                    HStack(spacing: 6) { Text(presentation.deny.title); KeyCap(shortcut: .deny) }
                }
                .keyboardShortcut(.deny)
                .focused($focus, equals: .deny)
                .help(presentation.deny.detail)
                .accessibilityHint(presentation.deny.detail)
                if !model.noteOpen.contains(id) {
                    Button("Deny with note…") {
                        model.noteOpen.insert(id)
                        focus = .note
                    }
                    .buttonStyle(.link)
                    .font(style.smallFont)
                    .help("Deny and tell the agent why")
                }
                Spacer(minLength: style.spacing * 2)
                if submitting {
                    ProgressView().controlSize(.small)
                    Text("Sending…").font(style.smallFont).foregroundStyle(style.secondaryText)
                }
                Button {
                    Task { await model.reply(.always, to: request) }
                } label: {
                    HStack(spacing: 6) { Text(presentation.allowAlways.title); KeyCap(shortcut: .allowAlways) }
                }
                .keyboardShortcut(presentation.allowAlways.isAvailable ? .allowAlways : nil)
                .disabled(!presentation.allowAlways.isAvailable)
                .focused($focus, equals: .always)
                .help(presentation.allowAlways.detail)
                .accessibilityHint(presentation.allowAlways.detail)
                Button {
                    Task { await model.reply(.once, to: request) }
                } label: {
                    HStack(spacing: 6) { Text(presentation.allowOnce.title); KeyCap(shortcut: .allowOnce) }
                }
                .keyboardShortcut(.allowOnce)
                .focused($focus, equals: .once)
                .help(presentation.allowOnce.detail)
                .accessibilityHint(presentation.allowOnce.detail)
            }
            .controlSize(.regular)
            .disabled(submitting)
            if presentation.allowAlways.isAvailable {
                Text("Always allow: \(presentation.allowAlways.detail.replacingOccurrences(of: "Saves a rule for", with: "saves a rule for"))")
                    .font(style.smallFont)
                    .foregroundStyle(style.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

// MARK: - Question

struct QuestionCard: View {
    @Environment(\.agentUIStyle) private var style
    let model: PendingRequestStackModel
    let request: QuestionRequest
    let form: QuestionFormModel
    let count: Int

    var body: some View {
        let submitting = model.isSubmitting(.question(request))
        CardChrome(tint: style.accent) {
            RequestHeader(
                model: model, symbol: "questionmark.bubble", tint: style.accent, title: request.title, label: "Question",
                request: .question(request), count: count)
            FormFieldsView(model: form, disabled: submitting)
            if let error = model.replyError, !submitting {
                Label(error, systemImage: "exclamationmark.circle").font(style.smallFont).foregroundStyle(style.danger)
            }
            HStack(spacing: style.spacing * 2) {
                Button {
                    Task { await model.dismiss(request) }
                } label: {
                    HStack(spacing: 6) { Text("Dismiss"); KeyCap(shortcut: .deny) }
                }
                .keyboardShortcut(.deny)
                .help("Close the question without answering. The agent is told it was dismissed.")
                Spacer()
                if submitting {
                    ProgressView().controlSize(.small)
                    Text("Sending…").font(style.smallFont).foregroundStyle(style.secondaryText)
                }
                Button {
                    Task { await model.submit(request) }
                } label: {
                    HStack(spacing: 6) { Text("Submit answer"); KeyCap(shortcut: .submitAnswer) }
                }
                .keyboardShortcut(.submitAnswer)
                .buttonStyle(.borderedProminent)
            }
            .disabled(submitting)
        }
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question from the agent: \(request.title)")
    }
}
