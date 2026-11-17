import AppKit
import BelloCore
import SwiftUI
import DesignSystem

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
                .padding(.horizontal, DS.Space.s8)
                .padding(.vertical, DS.Space.s4)
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
                let shape = UnevenRoundedRectangle(bottomLeadingRadius: DS.Radius.lg, bottomTrailingRadius: DS.Radius.lg, style: .continuous)
                shape
                    .fill(SwiftUI.Color.ds.raised)
                    .overlay(shape.strokeBorder(SwiftUI.Color.ds.composerOutline, lineWidth: 1))
                    .frame(height: 4)
                    .padding(.horizontal, CGFloat(index + 1) * 8)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Header shared by every card (visual-language.md §6 "Approval and question cards"): a 16 pt glyph in the tone's text
/// colour, the title (`title`), a one-line reason (`text2`), the child thread it came from, the age (`meta text4`) and
/// the "1 of 3" navigator. No caps label, no accent bar: the glyph shape and the title say what it is.
struct RequestHeader: View {
    let model: PendingRequestStackModel
    let symbol: String
    let tone: DS.Tone
    let title: String
    var reason: String?
    let request: PendingRequest
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s8) {
            Image(systemName: symbol)
                .font(.system(size: DS.Size.iconPoint + 1, weight: .regular))
                .foregroundStyle(SwiftUI.Color(nsColor: DS.Color.tone(tone).text))
                .frame(width: DS.Size.iconBox)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
            Text(title)
                .font(.ds(.title))
                .foregroundStyle(SwiftUI.Color.ds.text)
                .lineLimit(1)
                .layoutPriority(2)
            if let reason, !reason.isEmpty {
                Text(reason)
                    .font(.ds(.body))
                    .foregroundStyle(SwiftUI.Color.ds.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reason)
            }
            if let origin = model.origin(of: request) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: DS.Size.iconPointMeta))
                    Text("from \(origin)")
                }
                .font(.ds(.meta))
                .foregroundStyle(SwiftUI.Color.ds.text3)
                .lineLimit(1)
                .help("Asked by the sub-agent thread “\(origin)”")
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: DS.Space.s8)
            AgeText(date: request.received.date)
                .font(.ds(.meta))
                .foregroundStyle(SwiftUI.Color.ds.text4)
                .fixedSize()
                .accessibilityLabel("waiting")
            if count > 1 {
                HStack(spacing: 0) {
                    Button(action: model.showPrevious) { Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                        .keyboardShortcut(.previousRequest)
                        .help("Previous request (\(AgentShortcut.previousRequest.display))")
                        .accessibilityLabel("Previous request")
                    Text("\(model.currentIndex + 1) of \(count)")
                        .font(.ds(.meta).monospacedDigit())
                        .foregroundStyle(SwiftUI.Color.ds.text3)
                        .fixedSize()
                    Button(action: model.showNext) { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                        .keyboardShortcut(.nextRequest)
                        .help("Next request (\(AgentShortcut.nextRequest.display))")
                        .accessibilityLabel("Next request")
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
        }
    }
}

/// The card surface: the composer's glass recipe (solid `raised` here, with a 4.5 % tint of the request's tone),
/// `r.xl`, `composerOutline` ring, the dark inner highlight and the composer shadow. Attached above the composer.
/// `attachedOverlap`: extra bottom room when the host overlaps the composer onto the card (T3's attached look).
struct CardChrome<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.agentUIAttachedOverlap) private var attachedOverlap
    let tone: DS.Tone
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
        let dark = colorScheme == .dark
        VStack(alignment: .leading, spacing: DS.Space.s10) { content }
            .padding(.horizontal, DS.Space.s14)
            .padding(.top, DS.Space.s12)
            .padding(.bottom, DS.Space.s12 + attachedOverlap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                shape.fill(SwiftUI.Color.ds.raised)
                    .overlay(shape.fill(SwiftUI.Color(nsColor: DS.Color.tone(tone).fill).opacity(0.045)))
                    .shadow(color: .black.opacity(dark ? 0.55 : 0.05), radius: dark ? 12 : 1, y: dark ? 8 : 1))
            .overlay(
                shape.inset(by: 0.5)
                    .stroke(LinearGradient(
                        colors: [dark ? SwiftUI.Color.white.opacity(0.08) : SwiftUI.Color.ds.composerOutline, SwiftUI.Color.ds.composerOutline],
                        startPoint: .top, endPoint: .init(x: 0.5, y: 0.08)), lineWidth: 1))
    }
}

/// The footer's risk note: a 12 pt triangle in `warningText` and `label` `text2` (never colour alone).
struct RiskNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: DS.Size.iconPointRow))
                .foregroundStyle(SwiftUI.Color.ds.warningText)
                .accessibilityHidden(true)
            Text(text).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Caution: \(text)")
    }
}

/// "Sending…" with the drawn spinner while a reply is in flight (never claims delivery before the server acknowledges).
struct SubmittingIndicator: View {
    var text = "Sending…"

    var body: some View {
        HStack(spacing: DS.Space.s6) {
            StatusLabel(.running, showsText: false)
            Text(text).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// A failed reply, inline: triangle `dangerText` + the message.
struct ReplyErrorLabel: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s6) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: DS.Size.iconPointRow)).foregroundStyle(SwiftUI.Color.ds.dangerText)
            Text(text).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(text)")
    }
}

// MARK: - Permission

struct PermissionCard: View {
    let model: PendingRequestStackModel
    let request: PermissionRequest
    let count: Int
    @FocusState private var focus: Focus?

    enum Focus: Hashable { case deny, once, always, note }

    var body: some View {
        let presentation = model.presentation(request)
        let submitting = model.isSubmitting(.permission(request))
        let id = request.id.rawValue
        CardChrome(tone: .warning) {
            RequestHeader(
                model: model, symbol: "exclamationmark.shield", tone: .warning, title: presentation.title + "?",
                reason: request.message, request: .permission(request), count: count)
            VStack(alignment: .leading, spacing: DS.Space.s8) {
                targets(presentation)
                contextLine(presentation, id: id)
                if model.expandedDetails.contains(id) { rawDetails(presentation) }
                if model.noteOpen.contains(id) {
                    TextField("Tell the agent why (optional)", text: Binding(
                        get: { model.notes[id] ?? "" }, set: { model.notes[id] = $0 }))
                        .textFieldStyle(DSTextFieldStyle())
                        .focused($focus, equals: .note)
                        .onSubmit { Task { await model.reply(.reject, to: request) } }
                        .onExitCommand { model.noteOpen.remove(id) }
                }
                buttons(presentation, submitting: submitting)
                if let error = model.replyError, !submitting { ReplyErrorLabel(text: error) }
            }
            .padding(.leading, DS.Size.iconBox + DS.Space.s8)
        }
        .focusSection()
        .defaultFocus($focus, .deny)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval needed: \(presentation.title), \(presentation.summary)")
    }

    /// The command or targets in a `codeFill` well, mono 12.
    @ViewBuilder
    private func targets(_ presentation: PermissionPresentation) -> some View {
        let shown = presentation.targets.filter { !$0.isEmpty }
        if !shown.isEmpty {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(shown.prefix(6).enumerated()), id: \.offset) { _, target in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s8) {
                        if presentation.targetsAreCommands {
                            Text("$").foregroundStyle(SwiftUI.Color.ds.text4).accessibilityHidden(true)
                        }
                        Text(target).foregroundStyle(SwiftUI.Color.ds.text).textSelection(.enabled)
                    }
                }
                if shown.count > 6 {
                    Text("and \(shown.count - 6) more (see Details)").foregroundStyle(SwiftUI.Color.ds.text3)
                }
            }
            .font(.system(size: DS.TextRole.label.size(base: DS.Typography.current.baseSize), design: .monospaced))
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.s12)
            .padding(.vertical, DS.Space.s8)
            .background(shape.fill(SwiftUI.Color.ds.codeFill))
            .overlay(shape.strokeBorder(SwiftUI.Color.ds.border.opacity(0.7), lineWidth: 1))
        }
    }

    /// Where it acts (UX rule 6) and the secondary actions: Details, Deny with note.
    private func contextLine(_ presentation: PermissionPresentation, id: String) -> some View {
        let session = model.session(of: .permission(request))
        let expanded = model.expandedDetails.contains(id)
        return HStack(spacing: DS.Space.s12) {
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
            Spacer(minLength: DS.Space.s8)
            Button {
                if expanded { model.expandedDetails.remove(id) } else { model.expandedDetails.insert(id) }
            } label: {
                HStack(spacing: 3) {
                    Text("Details")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }
            .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
            .accessibilityLabel(expanded ? "Hide details" : "Show details")
            if !model.noteOpen.contains(id) {
                Button("Deny with note…") {
                    model.noteOpen.insert(id)
                    focus = .note
                }
                .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                .help("Deny and tell the agent why")
            }
        }
        .font(.ds(.meta))
        .foregroundStyle(SwiftUI.Color.ds.text3)
        .labelStyle(CompactLabelStyle())
    }

    private func rawDetails(_ presentation: PermissionPresentation) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Space.s12, verticalSpacing: 2) {
            row("Action", request.action)
            row("Resources", request.resources.isEmpty ? "—" : request.resources.joined(separator: "\n"))
            row("Always rule", presentation.alwaysRules.isEmpty ? "none offered" : presentation.alwaysRules.joined(separator: "\n"))
            row("Directory", model.session(of: .permission(request))?.directory ?? "—")
            row("Session", request.sessionID.rawValue)
            if let call = request.toolCallID { row("Tool call", call) }
            row("Request", request.id.rawValue)
        }
        .font(.system(size: DS.TextRole.codeSmall.size(base: DS.Typography.current.baseSize), design: .monospaced))
        .textSelection(.enabled)
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(SwiftUI.Color.ds.text3).gridColumnAlignment(.trailing)
            Text(value).foregroundStyle(SwiftUI.Color.ds.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Risk note, then outline Deny, outline Always allow and primary Allow once, each with its shortcut hint (hints
    /// drop before titles truncate).
    private func buttons(_ presentation: PermissionPresentation, submitting: Bool) -> some View {
        // The risk note shares the row when it fits on one line; otherwise it goes above the buttons, unclipped.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.s8) {
                if let caution = presentation.caution { RiskNote(text: caution).fixedSize() }
                Spacer(minLength: DS.Space.s8)
                actions(presentation, submitting: submitting)
            }
            VStack(alignment: .leading, spacing: DS.Space.s8) {
                if let caution = presentation.caution { RiskNote(text: caution).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: DS.Space.s8) {
                    Spacer(minLength: 0)
                    actions(presentation, submitting: submitting)
                }
            }
        }
        .disabled(submitting)
    }

    @ViewBuilder
    private func actions(_ presentation: PermissionPresentation, submitting: Bool) -> some View {
        if submitting { SubmittingIndicator() }
        Button(presentation.deny.title) {
            Task { await model.reply(.reject, to: request) }
        }
        .buttonStyle(DSButtonStyle(.outline, hint: AgentShortcut.deny.display))
        .keyboardShortcut(.deny)
        .focused($focus, equals: .deny)
        .help(presentation.deny.detail)
        .accessibilityHint(presentation.deny.detail)
        Button(presentation.allowAlways.title) {
            Task { await model.reply(.always, to: request) }
        }
        .buttonStyle(DSButtonStyle(.outline, hint: AgentShortcut.allowAlways.display))
        .keyboardShortcut(presentation.allowAlways.isAvailable ? .allowAlways : nil)
        .disabled(!presentation.allowAlways.isAvailable)
        .focused($focus, equals: .always)
        .help(presentation.allowAlways.detail)
        .accessibilityHint(presentation.allowAlways.detail)
        Button(presentation.allowOnce.title) {
            Task { await model.reply(.once, to: request) }
        }
        .buttonStyle(DSButtonStyle(.primary, hint: AgentShortcut.allowOnce.display))
        .keyboardShortcut(.allowOnce)
        .focused($focus, equals: .once)
        .help(presentation.allowOnce.detail)
        .accessibilityHint(presentation.allowOnce.detail)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: DS.Size.iconPointMeta))
            configuration.title
        }
    }
}

// MARK: - Question

struct QuestionCard: View {
    let model: PendingRequestStackModel
    let request: QuestionRequest
    let form: QuestionFormModel
    let count: Int

    var body: some View {
        let submitting = model.isSubmitting(.question(request))
        CardChrome(tone: .info) {
            RequestHeader(
                model: model, symbol: "questionmark.bubble", tone: .info, title: request.title,
                request: .question(request), count: count)
            VStack(alignment: .leading, spacing: DS.Space.s10) {
                FormFieldsView(model: form, disabled: submitting)
                if let error = model.replyError, !submitting { ReplyErrorLabel(text: error) }
                HStack(spacing: DS.Space.s8) {
                    Spacer(minLength: DS.Space.s8)
                    if submitting { SubmittingIndicator() }
                    Button("Dismiss") {
                        Task { await model.dismiss(request) }
                    }
                    .buttonStyle(DSButtonStyle(.ghost, hint: AgentShortcut.deny.display))
                    .keyboardShortcut(.deny)
                    .help("Close the question without answering. The agent is told it was dismissed.")
                    Button("Submit answer") {
                        Task { await model.submit(request) }
                    }
                    .buttonStyle(DSButtonStyle(.primary, hint: AgentShortcut.submitAnswer.display))
                    .keyboardShortcut(.submitAnswer)
                }
                .disabled(submitting)
            }
            .padding(.leading, DS.Size.iconBox + DS.Space.s8)
        }
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question from the agent: \(request.title)")
    }
}
