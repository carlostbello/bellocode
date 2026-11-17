import AppKit
import BelloCore
import Engine
import SwiftUI
import DesignSystem

/// Inputs for one integration's sign-in, kept while the user switches providers or methods, retries, or the attempt
/// fails, so nothing typed is lost. The API key lives only here (in memory) and is cleared after a successful connect.
@MainActor
@Observable
final class ConnectInputs {
    var apiKey = ""
    var label = ""
    var code = ""
    var methodID: String?
    private var forms: [String: QuestionFormModel] = [:]

    func form(for method: AuthMethod) -> QuestionFormModel {
        if let form = forms[method.id] { return form }
        let form = QuestionFormModel(fields: method.fields)
        forms[method.id] = form
        return form
    }
}

extension ConnectInputs: CustomStringConvertible {
    nonisolated var description: String { "ConnectInputs(<redacted>)" }
}

/// Searchable provider list and the sign-in form for the chosen provider: the right method per provider (API key,
/// browser sign-in, code, command, external), inline validation, clear errors with retry, cancel and expiry.
public struct ProviderConnectView: View {
    @Environment(\.agentUIStyle) private var style
    @Bindable var auth: AuthService
    let onDone: (() -> Void)?
    @StateObject private var search = ViewState("")
    @StateObject private var selected: ViewState<String?>
    @StateObject private var inputs = ViewState<[String: ConnectInputs]>([:])

    /// - Parameters:
    ///   - initialIntegrationID: preselects a provider (for "Connect…" from the model picker).
    ///   - onDone: shows a "Done" button after success (onboarding, settings "Back").
    public init(auth: AuthService, initialIntegrationID: String? = nil, onDone: (() -> Void)? = nil) {
        self.auth = auth
        self.onDone = onDone
        _selected = StateObject(wrappedValue: ViewState(initialIntegrationID))
    }

    public var body: some View {
        HStack(spacing: 0) {
            providerList
                .frame(width: 230)
            SwiftUI.Color.ds.border.frame(width: 1).accessibilityHidden(true)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(DSButtonStyle(.outline))
        .toggleStyle(DSToggleStyle(.checkbox))
        .noImplicitAnimation()
        .task {
            if auth.listState == .idle { await auth.refresh() }
        }
    }

    // MARK: List

    private var providerList: some View {
        let items = auth.search(search.value)
        return VStack(spacing: 0) {
            HStack(spacing: style.spacing * 2) {
                Image(systemName: "magnifyingglass").foregroundStyle(style.secondaryText).accessibilityHidden(true)
                TextField("Search providers", text: $search.value)
                    .textFieldStyle(.plain)
                    .onKeyPress(.downArrow) { moveSelection(items, 1) }
                    .onKeyPress(.upArrow) { moveSelection(items, -1) }
                    .accessibilityLabel("Search providers")
            }
            .padding(style.spacing * 2.5)
            DSHairline()
            switch auth.listState {
            case .loading where auth.integrations.isEmpty:
                VStack(spacing: style.spacing * 2) {
                    StatusLabel(.running, showsText: false)
                    Text("Loading providers…").font(style.smallFont).foregroundStyle(style.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message) where auth.integrations.isEmpty:
                VStack(spacing: style.spacing * 2) {
                    Text(message).font(style.smallFont).foregroundStyle(style.secondaryText).multilineTextAlignment(.center)
                    Button("Try Again") { Task { await auth.refresh() } }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if items.isEmpty {
                                Text("No provider matches “\(search.value)”.").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3)
                                    .padding(DS.Space.s8)
                            }
                            ForEach(items) { item in
                                ProviderListRow(item: item, isSelected: selected.value == item.id) { selected.value = item.id }
                                    .id(item.id)
                            }
                        }
                        .padding(DS.Space.s4)
                    }
                    .onAppear { if let id = selected.value { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    private func moveSelection(_ items: [IntegrationItem], _ delta: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let index = items.firstIndex { $0.id == selected.value } ?? -1
        selected.value = items[max(0, min(items.count - 1, index + delta))].id
        return .handled
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selected.value, let item = auth.integration(id) {
            ConnectDetail(auth: auth, item: item, inputs: inputsFor(id), onDone: onDone)
                .id(id)
        } else {
            VStack(alignment: .leading, spacing: style.spacing * 2) {
                Text("Choose a provider").font(style.titleFont)
                Text("Pick the service whose models you want to use. You can connect more than one, and several accounts per provider.")
                    .font(style.smallFont).foregroundStyle(style.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            .padding(style.spacing * 5)
        }
    }

    private func inputsFor(_ id: String) -> ConnectInputs {
        if let existing = inputs.value[id] { return existing }
        let created = ConnectInputs()
        inputs.value[id] = created
        return created
    }
}

struct ConnectDetail: View {
    @Environment(\.agentUIStyle) private var style
    @Bindable var auth: AuthService
    let item: IntegrationItem
    @Bindable var inputs: ConnectInputs
    let onDone: (() -> Void)?
    @FocusState private var keyFocused: Bool

    private var methods: [AuthMethod] { item.interactiveMethods }

    /// The method of an attempt in progress (or just finished) wins over the picker, so its state shows under the
    /// right method.
    private var method: AuthMethod? {
        if let flow = auth.flow, flow.integrationID == item.id, flow.phase != .idle {
            let attemptMethod = flow.methodID ?? methods.first { $0.kind == .key }?.id
            if let match = methods.first(where: { $0.id == attemptMethod }) { return match }
        }
        return methods.first { $0.id == inputs.methodID } ?? methods.first
    }

    /// The flow for this provider, if the current attempt is for it.
    private var flow: AuthFlowPhase? {
        guard let flow = auth.flow, flow.integrationID == item.id else { return nil }
        return flow.phase
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: style.spacing * 4) {
                header
                if methods.isEmpty {
                    environmentOnly
                } else {
                    if methods.count > 1 { methodPicker }
                    if let method { methodBody(method) }
                }
                environmentNote
            }
            .padding(style.spacing * 5)
            .frame(maxWidth: 520, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: style.spacing) {
            Text(item.name).font(.system(size: NSFont.systemFontSize + 4, weight: .semibold))
            let credentials = auth.credentials(for: item.id)
            if let active = credentials.first(where: \.isActive) {
                Label("Connected as “\(active.label)”" + (credentials.count > 1 ? " (\(credentials.count) accounts)" : ""),
                      systemImage: "checkmark")
                    .foregroundStyle(style.success)
                    .font(style.smallFont)
            } else if let problem = item.connections.first(where: { $0.problem != nil })?.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(style.attention).font(style.smallFont)
            } else if item.isConnected {
                Label("Connected through the environment", systemImage: "checkmark.circle").foregroundStyle(style.success)
                    .font(style.smallFont)
            } else {
                Label("Not connected", systemImage: "circle.dashed").foregroundStyle(style.secondaryText).font(style.smallFont)
            }
        }
    }

    @ViewBuilder
    private var methodPicker: some View {
        let picker = Picker("Sign-in method", selection: Binding(
            get: { method?.id ?? "" }, set: { inputs.methodID = $0 })) {
            ForEach(methods) { method in Text(method.label).tag(method.id) }
        }
        Group {
            if methods.count <= 3 {
                DSSegmentedPicker(
                    options: methods.map { (id: $0.id, title: $0.label) },
                    selection: Binding(get: { method?.id ?? "" }, set: { inputs.methodID = $0 }))
            } else {
                picker.pickerStyle(.menu).menuStyle(.button).buttonStyle(DSButtonStyle(.outline)).fixedSize()
            }
        }
        .labelsHidden()
        .disabled(flow?.isWaiting == true)
        .accessibilityLabel("Sign-in method")
    }

    @ViewBuilder
    private func methodBody(_ method: AuthMethod) -> some View {
        let form = inputs.form(for: method)
        let waiting = flow?.isWaiting == true
        VStack(alignment: .leading, spacing: style.spacing * 3) {
            Text(explanation(method)).font(style.smallFont).foregroundStyle(style.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if method.kind == .key {
                VStack(alignment: .leading, spacing: style.spacing) {
                    Text("API key").font(style.bodyFont.weight(.medium))
                    SecureField("Paste your \(item.name) API key", text: $inputs.apiKey)
                        .textFieldStyle(DSTextFieldStyle())
                        .focused($keyFocused)
                        .onSubmit { connect(method, form) }
                        .accessibilityLabel("\(item.name) API key")
                    Text("Sent once to BelloCode’s private opencode server on this Mac, which stores it. BelloCode keeps no copy.")
                        .font(style.smallFont).foregroundStyle(style.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
            if method.kind == .command, !method.command.isEmpty {
                Text(method.command.joined(separator: " "))
                    .font(style.monospacedFont)
                    .padding(style.spacing * 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(style.inset, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    .textSelection(.enabled)
            }
            if !form.visibleFields.isEmpty {
                FormFieldsView(model: form, disabled: waiting)
            }
            DisclosureGroup("Account name (optional)") {
                TextField("For example “Work”", text: $inputs.label).textFieldStyle(DSTextFieldStyle())
                    .padding(.top, style.spacing)
            }
            .font(style.smallFont)
            .disabled(waiting)
            flowView(method, form)
        }
    }

    // MARK: Flow

    @ViewBuilder
    private func flowView(_ method: AuthMethod, _ form: QuestionFormModel) -> some View {
        switch flow {
        case .waitingForBrowser(let url, let instructions, let canPaste, let expires):
            StatusBox(tint: SwiftUI.Color.ds.info) {
                HStack(spacing: style.spacing * 2) {
                    StatusLabel(.running, showsText: false)
                    Text("Waiting for you to finish in the browser…").font(style.bodyFont.weight(.medium))
                }
                if !instructions.isEmpty { Text(instructions).font(style.smallFont).foregroundStyle(style.secondaryText) }
                if let expires { ExpiryText(expires: expires) }
                HStack {
                    Button("Open the Page Again") { auth.reopenBrowser() }.help(url.absoluteString)
                    Button("Cancel") { Task { await auth.cancel() } }
                }
                if canPaste {
                    Text("If the browser shows a page that cannot be reached, copy its address and paste it here:")
                        .font(style.smallFont).foregroundStyle(style.secondaryText)
                    HStack {
                        TextField("Redirect URL", text: $inputs.code).textFieldStyle(DSTextFieldStyle())
                        Button("Submit") { Task { await auth.submitCode(inputs.code) } }
                            .disabled(inputs.code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        case .waitingForCode(let url, let instructions, let expires, let error):
            StatusBox(tint: SwiftUI.Color.ds.info) {
                Text("Paste the code from your browser").font(style.bodyFont.weight(.medium))
                if !instructions.isEmpty { Text(instructions).font(style.smallFont).foregroundStyle(style.secondaryText) }
                if let expires { ExpiryText(expires: expires) }
                HStack {
                    TextField("Code", text: $inputs.code)
                        .textFieldStyle(DSTextFieldStyle())
                        .onSubmit { Task { await auth.submitCode(inputs.code) } }
                    Button("Submit") { Task { await auth.submitCode(inputs.code) } }
                        .buttonStyle(DSButtonStyle(.primary))
                        .disabled(inputs.code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(style.danger).font(style.smallFont) }
                HStack {
                    Button("Open the Page Again") { auth.reopenBrowser() }.help(url.absoluteString)
                    Button("Cancel") { Task { await auth.cancel() } }
                }
            }
        case .verifying, .submitting, .starting:
            HStack(spacing: style.spacing * 2) {
                StatusLabel(.running, showsText: false)
                Text(flow == .verifying ? "Checking the code…" : "Connecting…").font(style.smallFont)
            }
        case .runningCommand(let output):
            StatusBox(tint: SwiftUI.Color.ds.info) {
                HStack(spacing: style.spacing * 2) {
                    StatusLabel(.running, showsText: false)
                    Text("Running the login command…").font(style.bodyFont.weight(.medium))
                }
                if let output { Text(output).font(style.monospacedFont).foregroundStyle(style.secondaryText).lineLimit(6) }
                Button("Cancel") { Task { await auth.cancel() } }
            }
        case .succeeded:
            StatusBox(tint: style.success) {
                Label("Connected to \(item.name)", systemImage: "checkmark")
                    .font(style.bodyFont.weight(.medium)).foregroundStyle(style.success)
                Text("Its models now appear in the model picker. Manage this account in Settings ▸ Accounts.")
                    .font(style.smallFont).foregroundStyle(style.secondaryText)
                HStack {
                    if let onDone { Button("Done", action: onDone).buttonStyle(DSButtonStyle(.primary)).keyboardShortcut(.defaultAction) }
                    Button("Add Another Account") { auth.clearFlow() }
                }
            }
        case .failed(let message):
            StatusBox(tint: style.danger) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(style.danger).font(style.bodyFont)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing you typed was lost. Check it and try again.").font(style.smallFont).foregroundStyle(style.secondaryText)
                Button("Try Again") { connect(method, form) }.buttonStyle(DSButtonStyle(.primary))
            }
        case .expired:
            StatusBox(tint: style.attention) {
                Label("The sign-in link expired before it was finished.", systemImage: "clock.badge.exclamationmark")
                Button("Start Again") { connect(method, form) }.buttonStyle(DSButtonStyle(.primary))
            }
        case .cancelled, .idle, nil:
            HStack {
                Button(primaryTitle(method)) { connect(method, form) }
                    .buttonStyle(DSButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(method.kind == .key && inputs.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if flow == .cancelled { Text("Cancelled.").font(style.smallFont).foregroundStyle(style.secondaryText) }
            }
        }
    }

    private func primaryTitle(_ method: AuthMethod) -> String {
        switch method.kind {
        case .key: "Connect"
        case .oauth: "Sign In with Browser…"
        case .command: "Run Login Command"
        default: "Connect"
        }
    }

    private func explanation(_ method: AuthMethod) -> String {
        switch method.kind {
        case .key: "Use an API key from your \(item.name) account. Usage is billed by \(item.name)."
        case .oauth: "Opens \(item.name) in your default browser. Sign in there; BelloCode finishes when you return."
        case .command: "opencode runs this command on your Mac to sign in."
        case .external: "Uses credentials you already set up outside opencode, such as a CLI login or profile."
        default: ""
        }
    }

    private func connect(_ method: AuthMethod, _ form: QuestionFormModel) {
        guard form.validateForSubmit() else { return }
        let answers = form.answers()
        let label = inputs.label
        Task {
            switch method.kind {
            case .key:
                await auth.connectKey(integrationID: item.id, key: inputs.apiKey, answers: answers, label: label)
                if case .succeeded? = flow { inputs.apiKey = "" }
            case .oauth:
                inputs.code = ""
                await auth.startOAuth(integrationID: item.id, methodID: method.methodID ?? "", answers: answers, label: label)
            case .external:
                await auth.connectExternal(integrationID: item.id, methodID: method.methodID ?? "", answers: answers, label: label)
            case .command:
                await auth.startCommand(integrationID: item.id, methodID: method.methodID ?? "", label: label)
            default:
                break
            }
        }
    }

    // MARK: Environment

    private var environmentNames: [String] { item.methods.filter { $0.kind == .environment }.flatMap(\.environmentNames) }

    @ViewBuilder
    private var environmentOnly: some View {
        Text("\(item.name) has no sign-in BelloCode can run. Set \(environmentNames.joined(separator: " or ")) in opencode’s environment.")
            .font(style.smallFont).foregroundStyle(style.secondaryText)
    }

    @ViewBuilder
    private var environmentNote: some View {
        if !methods.isEmpty, !environmentNames.isEmpty {
            Text("opencode also reads \(environmentNames.joined(separator: " or ")) from its environment.")
                .font(style.smallFont).foregroundStyle(style.secondaryText)
        }
    }
}

struct StatusBox<Content: View>: View {
    @Environment(\.agentUIStyle) private var style
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: style.spacing * 2) { content }
            .padding(style.spacing * 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(SwiftUI.Color.ds.border, lineWidth: 1))
    }
}

struct ExpiryText: View {
    @Environment(\.agentUIStyle) private var style
    let expires: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let remaining = expires.timeIntervalSince(context.date)
            Text(remaining > 60 ? "Expires in \(Int(remaining / 60)) min" : "Expires in less than a minute")
                .font(style.smallFont)
                .foregroundStyle(style.secondaryText)
        }
    }
}

/// A provider in the connect list: 28 pt, the DS row recipe (hover / selected wash, never accent), a check for
/// connected providers (glyph + accessibility word).
struct ProviderListRow: View {
    let item: IntegrationItem
    let isSelected: Bool
    let select: () -> Void
    @StateObject private var hover = ViewState(false)

    var body: some View {
        Button(action: select) {
            HStack(spacing: DS.Space.s8) {
                Text(item.name).font(.ds(.body)).foregroundStyle(SwiftUI.Color.ds.text).lineLimit(1)
                Spacer()
                if item.isConnected {
                    Image(systemName: "checkmark")
                        .font(.system(size: DS.Size.iconPointMeta, weight: .semibold))
                        .foregroundStyle(SwiftUI.Color.ds.successText)
                        .help("Connected")
                        .accessibilityLabel("Connected")
                }
            }
            .padding(.horizontal, DS.Space.s8)
            .frame(height: DS.Size.sidebarRow)
            .contentShape(Rectangle())
            .dsRowBackground(.resolve(hovered: hover.value, selected: false, active: isSelected))
        }
        .buttonStyle(.plain)
        .onHover { hover.value = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
