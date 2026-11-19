import AppKit
import BelloCore
import Engine
import SwiftUI
import DesignSystem

// MARK: - Import

/// Import credentials from an existing opencode install: strictly opt-in. Nothing is read until the user presses
/// "Look for Accounts", and nothing is imported until they confirm the listed accounts.
public struct ImportCredentialsView: View {
    @Environment(\.agentUIStyle) private var style
    @Bindable var auth: AuthService
    let source: CredentialImportSource?
    let onDone: (() -> Void)?

    enum Phase: Equatable {
        case intro
        case looking
        case preview([ImportableCredential])
        case importing
        case done(CredentialImportResult)
        case failed(String)
    }

    @StateObject private var phase = ViewState(Phase.intro)

    public init(auth: AuthService, source: CredentialImportSource?, onDone: (() -> Void)? = nil) {
        self.auth = auth
        self.source = source
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: style.spacing * 3) {
            Text("Import from opencode").font(style.titleFont)
            if let source {
                Text("BelloCode runs its own private copy of opencode. If you already use opencode, you can copy its saved accounts here. "
                    + "BelloCode reads them only when you ask, using opencode’s own export and import, and never keeps a copy itself.")
                    .font(style.smallFont).foregroundStyle(style.secondaryText).fixedSize(horizontal: false, vertical: true)
                Label(source.displayName, systemImage: "shippingbox").font(style.smallFont).foregroundStyle(style.secondaryText)
                content(source)
            } else {
                Text("No opencode installation was found in the usual places (~/.opencode/bin, Homebrew, ~/.local/bin). "
                    + "Connect a provider instead, or install opencode and try again.")
                    .font(style.smallFont).foregroundStyle(style.secondaryText).fixedSize(horizontal: false, vertical: true)
                if let onDone { Button("Back", action: onDone) }
            }
        }
        .buttonStyle(DSButtonStyle(.outline))
        .toggleStyle(DSToggleStyle(.checkbox))
        .noImplicitAnimation()
    }

    @ViewBuilder
    private func content(_ source: CredentialImportSource) -> some View {
        switch phase.value {
        case .intro:
            HStack {
                Button("Look for Accounts") { look(source) }.buttonStyle(DSButtonStyle(.primary))
                if let onDone { Button("Cancel", action: onDone) }
            }
        case .looking, .importing:
            HStack(spacing: style.spacing * 2) {
                StatusLabel(.running, showsText: false)
                Text(phase.value == .looking ? "Reading the account list…" : "Importing…").font(style.smallFont)
            }
        case .preview(let items) where items.isEmpty:
            Text("That opencode install has no saved accounts.").font(style.smallFont)
            if let onDone { Button("Back", action: onDone) }
        case .preview(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    HStack {
                        Text(item.integrationName).font(style.bodyFont)
                        Text(item.label).font(style.smallFont).foregroundStyle(style.secondaryText)
                        Spacer()
                        Text(item.method == "oauth" ? "Signed in" : item.method == "key" ? "API key" : item.method)
                            .font(style.smallFont).foregroundStyle(style.secondaryText)
                    }
                }
            }
            .padding(style.spacing * 2)
            .background(style.inset, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            Text("Accounts already in BelloCode are skipped. The secrets travel only between the two opencode programs.")
                .font(style.smallFont).foregroundStyle(style.secondaryText)
            HStack {
                Button("Import \(items.count) \(items.count == 1 ? "Account" : "Accounts")") { run(source) }
                    .buttonStyle(DSButtonStyle(.primary))
                Button("Cancel") { if let onDone { onDone() } else { phase.value = .intro } }
            }
        case .done(let result):
            Label(
                "Imported \(result.imported) \(result.imported == 1 ? "account" : "accounts")"
                    + (result.skipped > 0 ? " (\(result.skipped) already here)" : "") + ".",
                systemImage: "checkmark")
                .foregroundStyle(style.success)
            if let onDone { Button("Done", action: onDone).buttonStyle(DSButtonStyle(.primary)) }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(style.danger).font(style.smallFont)
            HStack {
                Button("Try Again") { look(source) }
                if let onDone { Button("Cancel", action: onDone) }
            }
        }
    }

    private func look(_ source: CredentialImportSource) {
        phase.value = .looking
        Task {
            do {
                phase.value = .preview(try await auth.previewImport(from: source))
            } catch {
                phase.value = .failed((error as? EngineError)?.userMessage ?? "Something went wrong.")
            }
        }
    }

    private func run(_ source: CredentialImportSource) {
        phase.value = .importing
        Task {
            do {
                phase.value = .done(try await auth.importCredentials(from: source))
            } catch {
                phase.value = .failed((error as? EngineError)?.userMessage ?? "Something went wrong.")
            }
        }
    }
}

// MARK: - Onboarding

/// What the first-run flow ended with.
public enum OnboardingOutcome: Hashable, Sendable {
    case connected, imported, skipped
}

/// What the model catalog offers without an account, as onboarding tells it (R33): free models are promised only when
/// the catalog actually lists some.
public enum OnboardingCatalog: Hashable, Sendable {
    /// The catalog has not arrived yet.
    case loading
    /// It did not arrive in time (or failed): nothing is known about free models.
    case unavailable
    /// It arrived and lists no free model.
    case noFreeModels
    case free([String])

    public static func from(catalogLoaded: Bool, freeModels: [String], timedOut: Bool) -> OnboardingCatalog {
        if !catalogLoaded { return timedOut ? .unavailable : .loading }
        return freeModels.isEmpty ? .noFreeModels : .free(freeModels)
    }

    public var hasFreeModels: Bool { if case .free = self { true } else { false } }

    /// The welcome paragraph.
    var introduction: String {
        let settings = "You can change this any time in Settings ▸ Accounts."
        switch self {
        case .free:
            return "You can start right away: opencode’s free built-in models work without an account. "
                + "Connect a provider when you want your own models, plans or higher limits. " + settings
        case .loading:
            return "Checking which models are available without an account… Connect a provider to use your own models, plans or higher limits. " + settings
        case .unavailable:
            return "The model list could not be loaded yet, so BelloCode cannot tell whether free models are available. "
                + "Connect a provider to start now, or skip and connect one later. " + settings
        case .noFreeModels:
            return "No free models are available right now. Connect a provider (or import your opencode accounts) to start. " + settings
        }
    }

    /// The Skip choice's detail line: never promises free models the catalog does not list.
    var skipDetail: String {
        switch self {
        case .free: "Use the free models. Nothing is sent anywhere until you start a thread."
        case .loading: "Continue without a provider. If free models turn out to be available you can use them; otherwise connect one from the model picker."
        case .unavailable, .noFreeModels:
            "Continue without a provider. Threads need a model: connect one later from the model picker or Settings ▸ Accounts."
        }
    }
}

/// First-run flow. Never blocks the app: it says whether opencode's free built-in models are available now (only when
/// the catalog lists them) and offers "Connect a provider", "Import from opencode" or "Skip".
public struct OnboardingView: View {
    @Environment(\.agentUIStyle) private var style
    @Bindable var auth: AuthService
    /// Read in `body`, so an observable catalog arriving late updates the screen.
    let catalog: @MainActor () -> OnboardingCatalog
    let importSource: CredentialImportSource?
    let onFinish: (OnboardingOutcome) -> Void

    enum Step: Equatable { case welcome, connect, importing }
    @StateObject private var step = ViewState(Step.welcome)

    /// - Parameter freeModels: names of the free models available now (from the catalog), shown as proof it works.
    public init(
        auth: AuthService, freeModels: [String], importSource: CredentialImportSource?,
        onFinish: @escaping (OnboardingOutcome) -> Void
    ) {
        let state: OnboardingCatalog = freeModels.isEmpty ? .noFreeModels : .free(freeModels)
        self.init(auth: auth, catalog: { state }, importSource: importSource, onFinish: onFinish)
    }

    public init(
        auth: AuthService, catalog: @escaping @MainActor () -> OnboardingCatalog, importSource: CredentialImportSource?,
        onFinish: @escaping (OnboardingOutcome) -> Void
    ) {
        self.auth = auth
        self.catalog = catalog
        self.importSource = importSource
        self.onFinish = onFinish
    }

    public var body: some View {
        Group {
            switch step.value {
            case .welcome: welcome
            case .connect:
                VStack(alignment: .leading, spacing: 0) {
                    backBar(title: "Connect a provider")
                    DSHairline()
                    ProviderConnectView(auth: auth, onDone: { onFinish(.connected) })
                }
            case .importing:
                VStack(alignment: .leading, spacing: 0) {
                    backBar(title: "Import from opencode")
                    DSHairline()
                    ImportCredentialsView(auth: auth, source: importSource, onDone: { onFinish(.imported) })
                        .padding(style.spacing * 6)
                        .frame(maxWidth: 560, alignment: .leading)
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(DSButtonStyle(.outline))
        .toggleStyle(DSToggleStyle(.checkbox))
        .noImplicitAnimation()
    }

    private func backBar(title: String) -> some View {
        HStack {
            Button {
                step.value = .welcome
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(DSButtonStyle(.ghost, size: .small))
            .keyboardShortcut("[", modifiers: .command)
            Text(title).font(style.titleFont)
            Spacer()
            Button("Skip for Now") { onFinish(.skipped) }.buttonStyle(DSButtonStyle(.ghost, size: .small))
        }
        .padding(.horizontal, style.spacing * 4)
        .padding(.vertical, style.spacing * 2.5)
    }

    private var welcome: some View {
        let catalog = catalog()
        return VStack(alignment: .leading, spacing: style.spacing * 5) {
            VStack(alignment: .leading, spacing: style.spacing * 2) {
                Text("Welcome to BelloCode").font(.ds(.proseH1)).foregroundStyle(SwiftUI.Color.ds.text)
                Text(catalog.introduction)
                    .font(style.bodyFont).foregroundStyle(style.secondaryText).fixedSize(horizontal: false, vertical: true)
                switch catalog {
                case .free(let freeModels):
                    Label("Free now: " + freeModels.prefix(4).joined(separator: ", ") + (freeModels.count > 4 ? " and \(freeModels.count - 4) more" : ""),
                          systemImage: "checkmark.seal")
                        .font(style.smallFont).foregroundStyle(style.success)
                case .loading:
                    Label("Loading the model list…", systemImage: "hourglass").font(style.smallFont).foregroundStyle(style.secondaryText)
                case .unavailable:
                    Label("Model list unavailable", systemImage: "exclamationmark.triangle").font(style.smallFont).foregroundStyle(style.secondaryText)
                case .noFreeModels:
                    Label("No free models right now", systemImage: "info.circle").font(style.smallFont).foregroundStyle(style.secondaryText)
                }
            }
            VStack(spacing: style.spacing * 2) {
                choice(
                    "Connect a provider", detail: "Anthropic, OpenAI, GitHub Copilot, OpenRouter and 200+ more, with an API key or by signing in.",
                    symbol: "bolt.horizontal.circle", prominent: true, shortcut: "1"
                ) { step.value = .connect }
                choice(
                    "Import from opencode", detail: "Copy the accounts you already saved in opencode on this Mac.",
                    symbol: "square.and.arrow.down", prominent: false, shortcut: "2"
                ) { step.value = .importing }
                choice(
                    "Skip for now", detail: catalog.skipDetail,
                    symbol: "arrow.right.circle", prominent: false, shortcut: "3"
                ) { onFinish(.skipped) }
            }
            Text("Your API keys go to BelloCode’s private opencode server on this Mac and are sent only to the provider you choose. "
                + "Prompts go to the provider of the model you pick; free models are served by opencode.")
                .font(style.smallFont).foregroundStyle(style.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .padding(style.spacing * 8)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choice(
        _ title: String, detail: String, symbol: String, prominent: Bool, shortcut: Character, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: style.spacing * 3) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(SwiftUI.Color.ds.icon)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(style.bodyFont.weight(.medium)).foregroundStyle(style.primaryText)
                    Text(detail).font(style.smallFont).foregroundStyle(style.secondaryText).multilineTextAlignment(.leading)
                }
                Spacer()
                DSKbdView("⌘\(String(shortcut))")
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(SwiftUI.Color.ds.text4).accessibilityHidden(true)
            }
            .padding(.horizontal, style.spacing * 3)
            .padding(.vertical, style.spacing * 2.5)
            .contentShape(Rectangle())
            .background(SwiftUI.Color.ds.raised, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(prominent ? SwiftUI.Color.ds.borderStrong : SwiftUI.Color.ds.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

// MARK: - Accounts settings

/// The Settings ▸ Accounts pane: connection state per provider, add / switch / rename / remove credentials, import.
/// Adding happens inline (no sheet). Removing a credential cannot be undone, so it alone asks for confirmation.
public struct AccountsSettingsView: View {
    @Environment(\.agentUIStyle) private var style
    @Bindable var auth: AuthService
    let importSource: CredentialImportSource?

    enum Mode: Equatable {
        case list
        case add(String?)
        case importing
    }

    @StateObject private var mode = ViewState(Mode.list)
    @StateObject private var renaming = ViewState<String?>(nil)
    @StateObject private var renameText = ViewState("")
    @StateObject private var confirmRemoval = ViewState<CredentialItem?>(nil)

    public init(auth: AuthService, importSource: CredentialImportSource? = nil) {
        self.auth = auth
        self.importSource = importSource
    }

    public var body: some View {
        Group {
            switch mode.value {
            case .list: list
            case .add(let id):
                VStack(alignment: .leading, spacing: 0) {
                    backBar("Add account")
                    DSHairline()
                    ProviderConnectView(auth: auth, initialIntegrationID: id, onDone: { finishAdding() })
                }
            case .importing:
                VStack(alignment: .leading, spacing: 0) {
                    backBar("Import from opencode")
                    DSHairline()
                    ImportCredentialsView(auth: auth, source: importSource, onDone: { mode.value = .list })
                        .padding(style.spacing * 5)
                    Spacer(minLength: 0)
                }
            }
        }
        .task { if auth.listState == .idle { await auth.refresh() } }
        .alert(
            "Remove “\(confirmRemoval.value?.label ?? "")”?",
            isPresented: Binding(get: { confirmRemoval.value != nil }, set: { if !$0 { confirmRemoval.value = nil } }),
            presenting: confirmRemoval.value
        ) { credential in
            Button("Remove", role: .destructive) {
                Task { await auth.remove(credential.id) }
                confirmRemoval.value = nil
            }
            Button("Cancel", role: .cancel) { confirmRemoval.value = nil }
        } message: { credential in
            Text("opencode deletes this saved \(credential.kind == "key" ? "API key" : "sign-in"). This cannot be undone; you would need to connect again.")
        }
        .buttonStyle(DSButtonStyle(.outline))
        .toggleStyle(DSToggleStyle(.checkbox))
        .noImplicitAnimation()
    }

    /// Opens the add-account flow for a provider (for "Connect…" from the model picker).
    public static func addAccountMode(_ integrationID: String?) -> String? { integrationID }

    private func finishAdding() {
        auth.clearFlow()
        mode.value = .list
    }

    private func backBar(_ title: String) -> some View {
        HStack {
            Button {
                auth.clearFlow()
                mode.value = .list
            } label: { Label("Accounts", systemImage: "chevron.left") }
                .buttonStyle(DSButtonStyle(.ghost, size: .small))
            Text(title).font(style.titleFont)
            Spacer()
        }
        .padding(.horizontal, style.spacing * 4)
        .padding(.vertical, style.spacing * 2.5)
    }

    private var connected: [IntegrationItem] {
        auth.integrations.filter { item in item.isConnected || !auth.credentials(for: item.id).isEmpty || !item.connections.isEmpty }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: style.spacing * 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accounts").font(style.titleFont)
                    Text("Providers BelloCode’s opencode can use. Free built-in models work without any.")
                        .font(style.smallFont).foregroundStyle(style.secondaryText)
                }
                Spacer()
                Button {
                    Task { await auth.refresh() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                    .accessibilityLabel("Refresh accounts")
                Button("Import from opencode…") { mode.value = .importing }
                Button("Add Account…") { mode.value = .add(nil) }.buttonStyle(DSButtonStyle(.primary))
            }
            .padding(style.spacing * 4)
            DSHairline()
            if let error = auth.lastError {
                Label(error.userMessage, systemImage: "exclamationmark.triangle")
                    .font(style.smallFont).foregroundStyle(style.danger)
                    .padding(.horizontal, style.spacing * 4).padding(.top, style.spacing * 2)
            }
            switch auth.listState {
            case .loading where auth.integrations.isEmpty:
                HStack(spacing: style.spacing * 2) {
                    StatusLabel(.running, showsText: false)
                    Text("Loading accounts…").font(style.smallFont)
                }
                .padding(style.spacing * 4)
            case .failed(let message) where auth.integrations.isEmpty:
                VStack(alignment: .leading, spacing: style.spacing * 2) {
                    Text(message).font(style.smallFont)
                    Button("Try Again") { Task { await auth.refresh() } }
                }
                .padding(style.spacing * 4)
            default:
                if connected.isEmpty {
                    VStack(alignment: .leading, spacing: style.spacing * 2) {
                        Text("No accounts yet").font(style.bodyFont.weight(.medium))
                        Text("BelloCode uses opencode’s free models until you connect a provider.")
                            .font(style.smallFont).foregroundStyle(style.secondaryText)
                    }
                    .padding(style.spacing * 4)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: style.spacing * 3) {
                            ForEach(connected) { item in integrationGroup(item) }
                        }
                        .padding(style.spacing * 4)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func integrationGroup(_ item: IntegrationItem) -> some View {
        let credentials = auth.credentials(for: item.id)
        let environment = item.connections.filter { !$0.isCredential }
        return VStack(alignment: .leading, spacing: style.spacing * 1.5) {
            HStack {
                Text(item.name).font(style.bodyFont.weight(.semibold))
                if let problem = item.connections.first(where: { $0.problem != nil })?.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(style.smallFont).foregroundStyle(style.attention)
                } else {
                    Label("Connected", systemImage: "checkmark").font(style.smallFont).foregroundStyle(style.success)
                }
                Spacer()
                Button("Add Account…") { mode.value = .add(item.id) }.buttonStyle(DSButtonStyle(.ghost, size: .small)).font(style.smallFont)
            }
            VStack(spacing: 0) {
                ForEach(credentials) { credential in
                    credentialRow(credential, canSwitch: credentials.count > 1)
                    if credential.id != credentials.last?.id || !environment.isEmpty { DSHairline().padding(.leading, 28) }
                }
                ForEach(environment) { connection in
                    HStack(spacing: style.spacing * 2) {
                        Image(systemName: "terminal").frame(width: 16).foregroundStyle(style.secondaryText)
                        Text("From environment: \(connection.label)").font(style.bodyFont)
                        Spacer()
                    }
                    .padding(.horizontal, style.spacing * 2)
                    .frame(minHeight: 28)
                }
            }
            .background(style.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(SwiftUI.Color.ds.border, lineWidth: 1))
        }
    }

    private func credentialRow(_ credential: CredentialItem, canSwitch: Bool) -> some View {
        HStack(spacing: style.spacing * 2) {
            Button {
                Task { await auth.activate(credential.id) }
            } label: {
                DSToggleMark(kind: .radio, isOn: credential.isActive)
            }
            .buttonStyle(DSButtonStyle(.ghost, size: .small))
            .disabled(credential.isActive)
            .help(credential.isActive ? "In use" : "Use this account")
            .accessibilityLabel(credential.isActive ? "\(credential.label), in use" : "Use \(credential.label)")
            .frame(width: 16)
            if renaming.value == credential.id {
                TextField("Account name", text: $renameText.value)
                    .textFieldStyle(DSTextFieldStyle())
                    .onSubmit {
                        let name = renameText.value
                        renaming.value = nil
                        Task { await auth.rename(credential.id, to: name) }
                    }
                    .onExitCommand { renaming.value = nil }
            } else {
                Text(credential.label).font(style.bodyFont)
                if credential.isActive { Text("in use").font(style.smallFont).foregroundStyle(style.secondaryText) }
            }
            Spacer()
            Text(credential.kind == "oauth" ? "Signed in" : credential.kind == "key" ? "API key" : "External")
                .font(style.smallFont).foregroundStyle(style.secondaryText)
            Menu {
                if !credential.isActive { Button("Use This Account") { Task { await auth.activate(credential.id) } } }
                Button("Rename…") {
                    renameText.value = credential.label
                    renaming.value = credential.id
                }
                DSHairline()
                Button("Remove…", role: .destructive) { confirmRemoval.value = credential }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(credential.label)")
        }
        .padding(.horizontal, style.spacing * 2)
        .frame(minHeight: 28)
        .contextMenu {
            Button("Rename…") {
                renameText.value = credential.label
                renaming.value = credential.id
            }
            Button("Remove…", role: .destructive) { confirmRemoval.value = credential }
        }
    }
}
