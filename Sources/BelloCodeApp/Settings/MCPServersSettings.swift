import AppKit
import BelloCore
import ContainerKit
import DesignSystem
import Engine
import SwiftUI

// Settings ▸ MCP Servers (docs/features/containers.md, "Global MCP servers"): servers registered with opencode for
// every project, of three kinds (remote endpoint, container image, compose stack), an inline editor (no sheet), and
// the read-only Import review. Secret values are typed into secure fields, go straight to the Keychain on Save, and
// are never shown again ("Saved in Keychain").

/// One editable header or variable row. A secret's value is never loaded back: `stored` says one is in the Keychain,
/// `newValue` replaces it when typed.
struct MCPFieldDraft: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var value: String
    var secret: Bool
    var stored: Bool = false
    var newValue: String = ""
}

/// The editor's working copy of one server.
struct MCPServerDraft: Equatable {
    var id: String
    var isNew: Bool
    var kind: GlobalMCPServer.Kind
    var name: String
    var enabled = true
    var source: String?
    // Remote
    var url = ""
    var headers: [MCPFieldDraft] = []
    // Image
    var image = ""
    var entrypoint = ""
    var args = ""
    var variables: [MCPFieldDraft] = []
    var mounts: [UserMount] = []
    var newMount = ""
    var newMountReadOnly = true
    var network: ImageMCPSpec.Network = .bridge
    var shared = false
    var idleMinutes = 15
    // Stack
    var compose = ""
    var service = ""
    var port = ""
    var path = "/mcp"
    var hostPort: Int?

    init(kind: GlobalMCPServer.Kind) {
        id = GlobalMCPServer.makeID()
        isNew = true
        self.kind = kind
        name = ""
        if kind == .stack { idleMinutes = 30 }
    }

    init(_ server: GlobalMCPServer) {
        id = server.id
        isNew = false
        kind = server.kind
        name = server.name
        enabled = server.enabled
        source = server.source
        if let remote = server.remote {
            url = remote.url
            headers = remote.headers.map { MCPFieldDraft(name: $0.name, value: $0.value ?? "", secret: $0.secret) }
        }
        if let image = server.image {
            self.image = image.image
            entrypoint = image.entrypoint.map { MCPServerSetting(name: "x", command: $0).commandLine } ?? ""
            args = MCPServerSetting(name: "x", command: image.args).commandLine
            variables = image.environment.map { MCPFieldDraft(name: $0.name, value: $0.value ?? "", secret: $0.secret) }
            mounts = image.mounts
            network = image.network
            shared = image.shared
            idleMinutes = image.idleStopMinutes
        }
        if let stack = server.stack {
            compose = stack.composeYAML
            service = stack.service
            port = String(stack.port)
            path = stack.path
            hostPort = stack.hostPort
            idleMinutes = stack.idleStopMinutes
        }
    }

    /// The server and the secret values typed (by Keychain account).
    func build() -> (GlobalMCPServer, [String: SecretValue]) {
        var secrets: [String: SecretValue] = [:]
        func fields(_ drafts: [MCPFieldDraft], account: (String) -> String) -> [MCPKeyValue] {
            drafts.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.map { draft in
                let name = draft.name.trimmingCharacters(in: .whitespaces)
                if draft.secret, !draft.newValue.isEmpty { secrets[account(name)] = SecretValue(draft.newValue) }
                return MCPKeyValue(name: name, value: draft.value, secret: draft.secret)
            }
        }
        var server = GlobalMCPServer(id: id, name: name.trimmingCharacters(in: .whitespaces), enabled: enabled, kind: kind, source: source)
        switch kind {
        case .remote:
            server.remote = RemoteMCPSetting(url: url.trimmingCharacters(in: .whitespaces),
                                             headers: fields(headers) { GlobalMCPSecrets.account(server: id, header: $0) })
        case .image:
            let entry = MCPServerSetting.split(commandLine: entrypoint)
            server.image = ImageMCPSetting(
                image: image.trimmingCharacters(in: .whitespaces), entrypoint: entry.isEmpty ? nil : entry,
                args: MCPServerSetting.split(commandLine: args),
                environment: fields(variables) { GlobalMCPSecrets.account(server: id, variable: $0) }, mounts: mounts,
                network: network, shared: shared, idleStopMinutes: idleMinutes)
        case .stack:
            server.stack = StackMCPSetting(composeYAML: compose, service: service.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 0,
                                           path: path.isEmpty ? "/" : path, hostPort: hostPort, idleStopMinutes: idleMinutes)
        }
        return (server, secrets)
    }
}

/// A row of the Import review.
struct MCPImportRow: Identifiable {
    var candidate: MCPImport.Candidate
    var selected: Bool
    var includeMounts = false
    var id: String { candidate.id }
}

@MainActor
final class MCPServersSettingsModel: ObservableObject {
    let engine: Engine
    var service: EnvironmentService { engine.environments }
    @Published var draft: MCPServerDraft?
    @Published var draftErrors: [String] = []
    @Published var importRows: [MCPImportRow]?
    @Published var logs: (title: String, text: String)?
    @Published var removed: EnvironmentService.RemovedGlobalMCP?
    @Published var message: String?

    /// The model of the open pane (snapshots and the Window menu).
    static weak var last: MCPServersSettingsModel?

    init(engine: Engine) { self.engine = engine }

    func add(_ kind: GlobalMCPServer.Kind) {
        draft = MCPServerDraft(kind: kind)
        draftErrors = []
    }

    func edit(_ server: GlobalMCPServer) async {
        var draft = MCPServerDraft(server)
        for index in draft.headers.indices where draft.headers[index].secret {
            draft.headers[index].stored = await service.hasGlobalMCPSecret(GlobalMCPSecrets.account(server: server.id, header: draft.headers[index].name))
        }
        for index in draft.variables.indices where draft.variables[index].secret {
            draft.variables[index].stored = await service.hasGlobalMCPSecret(GlobalMCPSecrets.account(server: server.id, variable: draft.variables[index].name))
        }
        self.draft = draft
        draftErrors = []
    }

    func saveDraft() async {
        guard let draft else { return }
        let (server, secrets) = draft.build()
        var errors = server.validationErrors()
        var servers = service.globalMCP.servers
        if servers.contains(where: { $0.name == server.name && $0.id != server.id }) { errors.append("Another server is named “\(server.name)”.") }
        guard errors.isEmpty else {
            draftErrors = errors
            return
        }
        if let index = servers.firstIndex(where: { $0.id == server.id }) { servers[index] = server } else { servers.append(server) }
        do {
            try await service.saveGlobalMCP(servers, secrets: secrets)
            self.draft = nil
            draftErrors = []
            message = "Saved “\(server.name)”. It is registered with opencode for each project you use."
            if server.kind == .image, service.globalMCPStates[server.id]?.imagePresent != true { service.pullGlobalMCPImage(server.id) }
        } catch {
            draftErrors = ["The Keychain refused the secret (\(error.localizedDescription)). Nothing was saved."]
        }
    }

    func remove(_ server: GlobalMCPServer) async {
        removed = await service.removeGlobalMCP(server.id)
    }

    func undoRemove() async {
        guard let removed else { return }
        await service.undoRemoveGlobalMCP(removed)
        self.removed = nil
    }

    func showLogs(_ server: GlobalMCPServer) async {
        logs = ("Logs: \(server.name)", await service.globalMCPLogs(server.id))
    }

    /// Reads the other tools' files now (the person asked), read-only.
    func startImport() async {
        let existing = Set(service.globalMCP.servers.map(\.name))
        let candidates = await Self.readImports(existing: existing)
        importRows = candidates.map { MCPImportRow(candidate: $0, selected: $0.isConvertible) }
        if candidates.isEmpty { message = "No MCP servers were found in opencode, Claude Desktop, Claude Code, Cursor or VS Code settings on this Mac." }
    }

    @concurrent
    static func readImports(existing: Set<String>) async -> [MCPImport.Candidate] { MCPImport.readAll(existingNames: existing) }

    /// Adds what the person kept selected (their secrets go to the Keychain now).
    func addImported() async {
        guard let rows = importRows else { return }
        var servers = service.globalMCP.servers
        var secrets: [String: SecretValue] = [:]
        var added = 0
        for row in rows where row.selected {
            guard var server = row.candidate.server else { continue }
            if row.includeMounts { server.image?.mounts = row.candidate.mounts }
            servers.append(server)
            secrets.merge(row.candidate.secrets) { a, _ in a }
            added += 1
        }
        do {
            try await service.saveGlobalMCP(servers, secrets: secrets)
            importRows = nil
            message = added == 0 ? "Nothing was imported." : "Imported \(added) server\(added == 1 ? "" : "s"). Images not on this Mac are pulled when you choose Pull."
        } catch {
            message = "The Keychain refused a secret (\(error.localizedDescription)). Nothing was imported."
        }
    }
}

struct MCPServersSettingsView: View {
    @ObservedObject var model: MCPServersSettingsModel
    let service: EnvironmentService

    var body: some View {
        SettingsPaneBody {
            SettingsNote("MCP servers available to the agent in every project. None runs on this Mac: remote endpoints are reached over HTTPS, image servers run in their own container (no project folder mounted), and compose stacks run on their own network with only the endpoint forwarded to this Mac.")
            SettingsGroup("Servers for all projects", footer: "A project can turn these off in Project Settings ▸ Environment ▸ MCP servers. A company MCP gateway is one remote endpoint: its URL and an authorization header.") {
                GlobalMCPListView(model: model, service: service)
            }
            if let draft = model.draft {
                SettingsGroup(draft.isNew ? "New \(draft.kind.title.lowercased())" : "Edit “\(draft.name)”", footer: Self.editorFooter(draft.kind)) {
                    MCPServerEditorView(model: model)
                }
            }
            if let rows = model.importRows {
                SettingsGroup("Import review", footer: "Read once from the files listed, which are not changed. Selected servers are added and enabled when you choose Add Selected; secret values found in the files go to your Keychain then. Mounts are left out unless you include them.") {
                    MCPImportReviewView(model: model, rows: rows)
                }
            }
            if let logs = model.logs { LogsView(title: logs.title, text: logs.text) { model.logs = nil } }
            if let message = model.message { SettingsNote(message) }
        }
    }

    static func editorFooter(_ kind: GlobalMCPServer.Kind) -> String {
        switch kind {
        case .remote: "Streamable HTTP (opencode falls back to SSE). Certificates are checked against the Mac's roots and the enterprise roots in Settings ▸ Containers. Secret header values are kept in your Keychain and given only to opencode."
        case .image: "Like docker run -i --rm IMAGE ARGS, in a container BelloCode manages: no project folder is mounted, no extra privileges. Secret variables are kept in your Keychain and passed when the server starts."
        case .stack: "The compose subset of project services (build, bind mounts and privileges are refused). The stack starts on the first connection, on its own network; only the endpoint is forwarded to this Mac's loopback."
        }
    }
}

/// The list: glyph + word state, kind and summary, per-project status, and the actions.
struct GlobalMCPListView: View {
    @ObservedObject var model: MCPServersSettingsModel
    let service: EnvironmentService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let servers = service.globalMCP.servers
            if servers.isEmpty {
                SettingsRow("No servers yet", detail: "Add a remote endpoint, a container image or a compose stack, or import the servers you already use.", divided: false) {
                    EmptyView()
                }
            }
            ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                let state = service.globalMCPStates[server.id] ?? GlobalMCPState()
                TwoLineRow(title: server.name, detail: Self.detail(server, state), divided: index > 0) {
                    GlobalMCPPill(server: server, state: state)
                } actions: {
                    Toggle(isOn: Binding(get: { server.enabled }, set: { value in Task { await service.setGlobalMCP(server.id, enabled: value) } })) { EmptyView() }
                        .toggleStyle(DSToggleStyle(.switch)).accessibilityLabel("Enable \(server.name)")
                    Button("Edit") { Task { await model.edit(server) } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                    if server.kind == .image, state.imagePresent == false, !state.isPulling {
                        Button("Pull") { service.pullGlobalMCPImage(server.id) }.buttonStyle(DSButtonStyle(.outline, size: .small))
                    }
                    if server.kind != .remote {
                        Button("Logs") { Task { await model.showLogs(server) } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                    }
                    Button("Restart") { Task { await service.restartGlobalMCP(server.id) } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                        .disabled(!server.enabled)
                    Spacer(minLength: 0)
                    Button("Remove") { Task { await model.remove(server) } }.buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                }
                if server.kind == .stack, !state.services.isEmpty {
                    ForEach(state.services) { item in
                        SettingsRow("  \(item.name)", detail: item.image.isEmpty ? item.message : item.image) {
                            ServiceStatePill(state: item)
                        }
                    }
                }
            }
            if let removed = model.removed {
                SettingsRow("Removed “\(removed.server.name)”", divided: true) {
                    Button("Undo") { Task { await model.undoRemove() } }.buttonStyle(DSButtonStyle(.outline, size: .small))
                }
            }
            SettingsActionsRow {
                Button("Add Remote Endpoint…") { model.add(.remote) }.buttonStyle(DSButtonStyle(.outline, size: .small))
                Button("Add Image…") { model.add(.image) }.buttonStyle(DSButtonStyle(.outline, size: .small))
                Button("Add Compose Stack…") { model.add(.stack) }.buttonStyle(DSButtonStyle(.outline, size: .small))
                Spacer()
                Button("Import…") { Task { await model.startImport() } }.buttonStyle(DSButtonStyle(.outline, size: .small))
                    .help("Reads opencode, Claude Desktop, Claude Code, Cursor and VS Code MCP settings (read-only)")
            }
        }
    }

    static func detail(_ server: GlobalMCPServer, _ state: GlobalMCPState) -> String {
        var parts = ["\(server.kind.title) · \(server.summary)"]
        if server.kind == .image, let image = server.image {
            parts.append(image.mounts.isEmpty ? "no folders mounted" : "mounts " + image.mounts.map { "\($0.path) (\($0.readOnly ? "read-only" : "read and write"))" }.joined(separator: ", "))
            if image.shared { parts.append("one shared container") }
        }
        if server.kind == .stack, let port = state.hostPort { parts.append("forwarded to 127.0.0.1:\(port)") }
        if let problem = state.problem { parts.append(problem) }
        if !state.connected.isEmpty { parts.append("connected in " + state.connected.joined(separator: ", ")) }
        for (project, error) in state.failed.sorted(by: { $0.key < $1.key }) { parts.append("failed in \(project): \(error)") }
        if !state.needsAuth.isEmpty { parts.append("sign-in needed in " + state.needsAuth.joined(separator: ", ")) }
        if let source = server.source { parts.append("imported from \(source)") }
        return parts.joined(separator: " · ")
    }
}

/// A global server's state as glyph + word (never colour only).
struct GlobalMCPPill: View {
    let server: GlobalMCPServer
    let state: GlobalMCPState

    var body: some View {
        let (word, tone, symbol): (String, DS.Tone, String) = {
            if !server.enabled { return ("Off", .neutral, "pause.circle") }
            if state.isPulling { return ("Pulling" + (state.pullFraction.map { " \(Int($0 * 100))%" } ?? ""), .info, "arrow.down.circle") }
            if let problem = state.problem {
                return problem.contains("not allowed") || problem.contains("refused") ? ("Refused", .danger, "hand.raised") : ("Needs attention", .warning, "exclamationmark.triangle")
            }
            if !state.failed.isEmpty { return ("Failed", .danger, "xmark.octagon") }
            if !state.needsAuth.isEmpty { return ("Sign-in needed", .warning, "exclamationmark.triangle") }
            if !state.connected.isEmpty { return ("Connected", .success, "checkmark.circle") }
            if !state.pending.isEmpty { return ("Starting", .info, "arrow.triangle.2.circlepath") }
            return ("Ready", .neutral, "circle.dashed")
        }()
        DSPillView(word, tone: tone, symbolName: symbol)
    }
}

/// A stack service's state as glyph + word.
struct ServiceStatePill: View {
    let state: ServiceState
    var body: some View {
        let (word, tone, symbol): (String, DS.Tone, String) = switch (state.phase, state.health) {
        case (.running, "healthy"?): ("Healthy", .success, "checkmark.circle")
        case (.running, "unhealthy"?): ("Unhealthy", .warning, "exclamationmark.triangle")
        case (.running, _): ("Running", .success, "cylinder.split.1x2")
        case (.refused, _): ("Refused", .danger, "hand.raised")
        case (.stopped, _): ("Stopped", .neutral, "stop.circle")
        case (.starting, _): ("Starting", .info, "arrow.triangle.2.circlepath")
        default: ("Not started", .neutral, "circle.dashed")
        }
        DSPillView(word, tone: tone, symbolName: symbol)
    }
}

/// The inline editor for one server.
struct MCPServerEditorView: View {
    @ObservedObject var model: MCPServersSettingsModel

    private var draft: Binding<MCPServerDraft> {
        Binding(get: { model.draft ?? MCPServerDraft(kind: .remote) }, set: { model.draft = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsFieldRow(divided: false) {
                label("Name")
                TextField("", text: draft.name, prompt: Text("company-gateway")).textFieldStyle(DSTextFieldStyle()).accessibilityLabel("Server name")
            }
            switch draft.wrappedValue.kind {
            case .remote: remoteFields
            case .image: imageFields
            case .stack: stackFields
            }
            if !model.draftErrors.isEmpty {
                ForEach(model.draftErrors, id: \.self) { error in
                    SettingsRow(error, divided: true) { DSPillView("Fix", tone: .danger, symbolName: "xmark.octagon") }
                }
            }
            SettingsActionsRow {
                Spacer()
                Button("Cancel") { model.draft = nil }.buttonStyle(DSButtonStyle(.ghost, size: .small)).keyboardShortcut(.cancelAction)
                Button("Save") { Task { await model.saveDraft() } }.buttonStyle(DSButtonStyle(.primary, size: .small))
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.ds(.meta)).foregroundStyle(DSColor.text3).frame(width: 84, alignment: .leading)
    }

    @ViewBuilder private var remoteFields: some View {
        SettingsFieldRow {
            label("URL")
            TextField("", text: draft.url, prompt: Text("https://mcp-gateway.example.com/mcp")).textFieldStyle(DSTextFieldStyle())
                .font(.ds(.codeSmall)).accessibilityLabel("Endpoint URL")
        }
        MCPFieldsEditor(title: "Headers", fields: draft.headers, namePrompt: "Authorization", valuePrompt: "Bearer …")
    }

    @ViewBuilder private var imageFields: some View {
        SettingsFieldRow {
            label("Image")
            TextField("", text: draft.image, prompt: Text("ghcr.io/acme/tools-mcp:1.4")).textFieldStyle(DSTextFieldStyle())
                .font(.ds(.codeSmall)).accessibilityLabel("Image reference")
        }
        SettingsFieldRow {
            label("Arguments")
            TextField("", text: draft.args, prompt: Text("--stdio (optional)")).textFieldStyle(DSTextFieldStyle()).font(.ds(.codeSmall))
                .accessibilityLabel("Arguments after the image")
        }
        SettingsFieldRow {
            label("Entrypoint")
            TextField("", text: draft.entrypoint, prompt: Text("the image's (optional)")).textFieldStyle(DSTextFieldStyle()).font(.ds(.codeSmall))
                .accessibilityLabel("Entrypoint override")
        }
        MCPFieldsEditor(title: "Variables", fields: draft.variables, namePrompt: "GITHUB_TOKEN", valuePrompt: "value")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(draft.wrappedValue.mounts.enumerated()), id: \.offset) { index, mount in
                SettingsRow(mount.path, detail: "Mounted at the same path, \(mount.readOnly ? "read-only" : "read and write")") {
                    Button("Remove") { model.draft?.mounts.remove(at: index) }.buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                }
            }
            SettingsFieldRow {
                label("Mount")
                TextField("", text: draft.newMount, prompt: Text("none (folders are off by default)")).textFieldStyle(DSTextFieldStyle())
                    .accessibilityLabel("Folder to mount")
                Toggle(isOn: draft.newMountReadOnly) { Text("Read-only").font(.ds(.meta)) }.toggleStyle(DSToggleStyle(.checkbox))
                Button("Add") {
                    let path = (draft.wrappedValue.newMount as NSString).expandingTildeInPath
                    model.draft?.mounts.append(UserMount(path: path, readOnly: draft.wrappedValue.newMountReadOnly))
                    model.draft?.newMount = ""
                }.buttonStyle(DSButtonStyle(.outline, size: .small)).disabled(draft.wrappedValue.newMount.isEmpty)
            }
        }
        SettingsRow("Network") {
            DSSegmentedPicker(options: [(id: ImageMCPSpec.Network.bridge, title: "Outbound"), (id: .none, title: "None")], selection: draft.network).fixedSize()
        }
        SettingsToggleRow("Share one container across projects",
                          detail: "Off: each project's connection gets its own container, removed when it ends (like --rm). On: one container serves every project; the image needs /bin/sh.",
                          isOn: draft.shared)
    }

    @ViewBuilder private var stackFields: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text("compose.yaml").font(.ds(.meta)).foregroundStyle(DSColor.text3)
            TextEditor(text: draft.compose).font(.ds(.codeSmall)).scrollContentBackground(.hidden)
                .frame(height: 120).padding(DS.Space.s4)
                .background(DSColor.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(DSColor.borderStrong, lineWidth: 1))
                .accessibilityLabel("Compose file")
        }
        .padding(DS.Space.s12)
        SettingsFieldRow {
            label("Endpoint")
            TextField("", text: draft.service, prompt: Text("service")).textFieldStyle(DSTextFieldStyle()).frame(width: 110)
                .accessibilityLabel("Endpoint service")
            TextField("", text: draft.port, prompt: Text("port")).textFieldStyle(DSTextFieldStyle()).frame(width: 64).accessibilityLabel("Endpoint port")
            TextField("", text: draft.path, prompt: Text("/mcp")).textFieldStyle(DSTextFieldStyle()).font(.ds(.codeSmall)).accessibilityLabel("Endpoint path")
        }
    }
}

/// Header or variable rows: name, value or (secret) a secure field that shows "Saved in Keychain" without the value.
struct MCPFieldsEditor: View {
    let title: String
    @Binding var fields: [MCPFieldDraft]
    let namePrompt: String
    let valuePrompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title, detail: "Secret values go to your Keychain and are never shown again.") {
                Button("Add") { fields.append(MCPFieldDraft(name: "", value: "", secret: false)) }.buttonStyle(DSButtonStyle(.outline, size: .small))
            }
            ForEach($fields) { $field in
                SettingsFieldRow {
                    TextField("", text: $field.name, prompt: Text(namePrompt)).textFieldStyle(DSTextFieldStyle()).frame(width: 130)
                        .font(.ds(.codeSmall)).accessibilityLabel("\(title) name")
                    if field.secret {
                        SecureField("", text: $field.newValue, prompt: Text(field.stored ? "Saved in Keychain" : "secret value")).textFieldStyle(DSTextFieldStyle())
                            .accessibilityLabel("\(field.name) secret value")
                    } else {
                        TextField("", text: $field.value, prompt: Text(valuePrompt)).textFieldStyle(DSTextFieldStyle()).font(.ds(.codeSmall))
                            .accessibilityLabel("\(field.name) value")
                    }
                    Toggle(isOn: $field.secret) { Text("Secret").font(.ds(.meta)) }.toggleStyle(DSToggleStyle(.checkbox))
                        .accessibilityLabel("\(field.name) is secret")
                    Button {
                        fields.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true)).accessibilityLabel("Remove \(field.name)")
                }
            }
        }
    }
}

/// The Import review: one row per server found, convertible ones selected, the rest with the reason.
struct MCPImportReviewView: View {
    @ObservedObject var model: MCPServersSettingsModel
    let rows: [MCPImportRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                SettingsRow("Nothing found", detail: "No MCP servers in the usual settings files of opencode, Claude Desktop, Claude Code, Cursor or VS Code.", divided: false) {
                    EmptyView()
                }
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let candidate = row.candidate
                HStack(alignment: .top, spacing: DS.Space.s8) {
                    if candidate.isConvertible {
                        Toggle(isOn: Binding(get: { row.selected }, set: { value in model.importRows?[index].selected = value })) { EmptyView() }
                            .toggleStyle(DSToggleStyle(.checkbox)).accessibilityLabel("Import \(candidate.name)")
                    } else {
                        Image(systemName: "nosign").foregroundStyle(DSColor.text3).accessibilityHidden(true).frame(width: 16)
                    }
                    VStack(alignment: .leading, spacing: DS.Space.s2) {
                        HStack(spacing: DS.Space.s6) {
                            Text(candidate.server?.name ?? candidate.name).font(.ds(.body)).foregroundStyle(DSColor.text)
                            if let server = candidate.server {
                                DSPillView(server.kind.title, tone: .neutral)
                            } else {
                                DSPillView("Cannot convert", tone: .warning, symbolName: "exclamationmark.triangle")
                            }
                        }
                        Text(candidate.server.map { "\($0.summary) · from \(candidate.source)" } ?? "from \(candidate.source)")
                            .font(.ds(.meta)).foregroundStyle(DSColor.text3).fixedSize(horizontal: false, vertical: true)
                        if let refusal = candidate.refusal {
                            Text(refusal).font(.ds(.meta)).foregroundStyle(DSColor.text2).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(candidate.notes, id: \.self) { note in
                            Text("• " + note).font(.ds(.meta)).foregroundStyle(DSColor.text2).fixedSize(horizontal: false, vertical: true)
                        }
                        if !candidate.mounts.isEmpty {
                            Toggle(isOn: Binding(get: { row.includeMounts }, set: { value in model.importRows?[index].includeMounts = value })) {
                                Text("Include its \(candidate.mounts.count) mount\(candidate.mounts.count == 1 ? "" : "s") (reviewed above)").font(.ds(.meta))
                            }
                            .toggleStyle(DSToggleStyle(.checkbox))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Space.s12)
                .padding(.vertical, DS.Space.s8)
                .overlay(alignment: .top) {
                    if index > 0 { Rectangle().fill(DSColor.border).frame(height: 1).padding(.leading, DS.Space.s12) }
                }
            }
            SettingsActionsRow {
                Spacer()
                Button("Cancel") { model.importRows = nil }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                Button("Add Selected") { Task { await model.addImported() } }.buttonStyle(DSButtonStyle(.primary, size: .small))
                    .disabled(!rows.contains { $0.selected && $0.candidate.isConvertible })
            }
        }
    }
}

/// Project Settings ▸ Environment ▸ MCP servers for all projects: use them here, or turn single ones off.
struct GlobalMCPOptOutView: View {
    @ObservedObject var model: EnvironmentSettingsModel
    let environment: ProjectEnvironment
    let service: EnvironmentService

    var body: some View {
        let servers = service.globalMCP.servers
        VStack(alignment: .leading, spacing: 0) {
            SettingsToggleRow("Use MCP servers for all projects", detail: servers.isEmpty ? "None are set up (Settings ▸ MCP Servers)." : nil, divided: false,
                              isOn: Binding(get: { environment.settings.useGlobalMCP }, set: { value in Task { await model.setUseGlobalMCP(value) } }))
            if environment.settings.useGlobalMCP {
                ForEach(servers) { server in
                    let off = environment.settings.globalMCPOptOut.contains(server.id)
                    let shadowed = environment.settings.mcpServers.contains { $0.name == server.name }
                    SettingsRow(server.name, detail: shadowed ? "This project's own server of the same name is used instead." : "\(server.kind.title) · \(server.summary)") {
                        HStack(spacing: DS.Space.s4) {
                            MCPStatusPill(enabled: server.enabled && !off && !shadowed, status: environment.mcpStatus.first { $0.name == server.name }?.status)
                            Toggle(isOn: Binding(get: { !off }, set: { value in Task { await model.setGlobalMCP(server.id, inProject: value) } })) { EmptyView() }
                                .toggleStyle(DSToggleStyle(.switch)).accessibilityLabel("Use \(server.name) in this project").disabled(!server.enabled)
                        }
                    }
                }
            }
        }
    }
}
