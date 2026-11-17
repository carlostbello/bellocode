import AppKit
import BelloCore
import ContainerKit
import DesignSystem
import Engine
import SwiftUI

// Containerised execution UI (docs/features/containers.md): the runtime status item, the blocked-command banner for
// threads and terminals, Settings ▸ Containers (runtime, default image, registry sign-in, isolation, host requirements,
// BelloCode-managed containers) and Settings ▸ Environment (one project's image, limits, variables, network, ports,
// logs, terminal). New visual language: DS tokens, DSButtonStyle, DSToggleStyle, DSPillView; no stock bezels.

extension EnvironmentTone {
    var ds: DS.Tone {
        switch self {
        case .neutral: .neutral
        case .info: .info
        case .success: .success
        case .warning: .warning
        case .danger: .danger
        }
    }
}

typealias DSColor = DS.SwiftUIColor

/// Runtime state as glyph + word (never colour only).
struct RuntimeStatusLabel: View {
    let runtime: RuntimeState?
    let enabled: Bool

    var body: some View {
        HStack(spacing: DS.Space.s4) {
            Image(systemName: symbol).foregroundStyle(SwiftUI.Color(nsColor: DS.Color.tone(tone).text)).accessibilityHidden(true)
            Text(text).font(.ds(.label)).foregroundStyle(DSColor.text2)
        }
        .accessibilityElement(children: .combine)
    }

    var text: String {
        guard enabled else { return "Containers off" }
        guard let runtime else { return "Checking containers" }
        return runtime.isReady ? "Containers ready" : "Containers: \(runtime.shortLabel)"
    }
    var symbol: String {
        guard enabled, let runtime else { return "shippingbox" }
        return runtime.isReady ? "shippingbox.fill" : "xmark.octagon"
    }
    var tone: DS.Tone {
        guard enabled, let runtime else { return .neutral }
        return runtime.isReady ? .success : .danger
    }
}

/// The banner shown above a thread's composer and over a terminal when commands cannot run in the project.
struct EnvironmentBannerView: View {
    let notice: EnvironmentNotice
    var progress: Double?
    let fix: (EnvironmentFix) -> Void
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s8) {
            Image(systemName: notice.symbolName)
                .foregroundStyle(SwiftUI.Color(nsColor: DS.Color.tone(notice.tone.ds).text)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text(notice.title).font(.ds(.bodyEmph)).foregroundStyle(DSColor.text)
                Text(notice.message).font(.ds(.meta)).foregroundStyle(DSColor.text2).fixedSize(horizontal: false, vertical: true)
                if let progress { DSProgressBar(value: progress).frame(maxWidth: 240).padding(.top, DS.Space.s4) }
            }
            Spacer(minLength: DS.Space.s8)
            if let action = notice.fix {
                Button(action.title) { fix(action) }.buttonStyle(DSButtonStyle(.primary, size: .small))
            }
            Button("Retry") { retry() }.buttonStyle(DSButtonStyle(.outline, size: .small))
                .help("Check again; commands run as soon as the environment is ready (no restart needed)")
        }
        .padding(.horizontal, DS.Space.s12)
        .padding(.vertical, DS.Space.s10)
        .background(SwiftUI.Color(nsColor: DS.Color.tone(notice.tone.ds).surface), in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(notice.title). \(notice.message)")
    }
}

/// Opens Rancher Desktop or a Settings pane for a fix (the app owns these actions).
@MainActor
enum EnvironmentFixes {
    static func perform(_ fix: EnvironmentFix, directory: String?, engine: Engine, openSettings: (String) -> Void) {
        switch fix {
        case .startRancher, .switchEngine, .updateRuntime:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.rancherdesktop.app") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .installRancher:
            if let url = URL(string: "https://rancherdesktop.io") { NSWorkspace.shared.open(url) }
        case .chooseImage, .signIn, .openSettings:
            openSettings(directory == nil ? "containers" : "environment")
        case .retry:
            if let directory { Task { await engine.environments.retry(directory) } } else { Task { await engine.environments.recheckRuntime() } }
        }
    }
}

// MARK: - Settings ▸ Containers

@MainActor
final class ContainersSettingsModel: ObservableObject {
    let engine: Engine
    var service: EnvironmentService { engine.environments }
    @Published var defaultImage: String
    @Published var registry = ""
    @Published var username = ""
    @Published var password = ""
    @Published var message: String?
    @Published var containers: [ManagedContainer] = []
    @Published var logs: (title: String, text: String)?
    @Published var requirements: [HostRequirement] = HostRequirement.check()

    init(engine: Engine) {
        self.engine = engine
        defaultImage = engine.environments.defaults.defaultImage ?? ""
    }

    func saveDefaultImage() async {
        var defaults = service.defaults
        let trimmed = defaultImage.trimmingCharacters(in: .whitespaces)
        defaults.defaultImage = trimmed.isEmpty ? nil : trimmed
        await service.setDefaults(defaults)
        message = trimmed.isEmpty ? "No default image: each project needs its own." : "Default image saved."
    }

    func signIn() {
        let host = registry.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !username.isEmpty, !password.isEmpty else { return }
        do {
            try service.signIn(registry: host, username: username, password: SecretValue(password))
            message = "Signed in to \(host). The password is in your Keychain and is sent only in that registry's pull requests."
        } catch {
            message = "Could not save the sign-in: \(error)"
        }
        password = ""
    }

    func reload() async { containers = await service.managedContainers() }

    func perform(_ action: EnvironmentService.ContainerAction, _ container: ManagedContainer) async {
        do { try await service.perform(action, on: container.id) } catch { message = "\(action.rawValue.capitalized) failed: \(error)" }
        await reload()
    }

    func showLogs(_ container: ManagedContainer) async {
        logs = (container.name, await service.logs(containerID: container.id))
    }
}

struct ContainersSettingsView: View {
    @ObservedObject var model: ContainersSettingsModel
    let service: EnvironmentService
    let confirmRemove: (ManagedContainer) -> Bool

    var body: some View {
        SettingsPaneBody {
            SettingsNote("Everything the agent or you run executes in a Linux container on Rancher Desktop, with the project at the same path. Nothing falls back to this Mac.")
            SettingsGroup("Runtime") {
                SettingsRow(
                    service.isEnabled ? (service.runtime?.userMessage ?? "Checking Rancher Desktop…") : "Container execution is off in this build.",
                    detail: runtimeDetail, divided: false
                ) {
                    RuntimeStatusLabel(runtime: service.runtime, enabled: service.isEnabled)
                }
                SettingsActionsRow {
                    if let fix = service.runtime?.fix {
                        Button(fix.rawValue) { EnvironmentFixes.perform(EnvironmentFix(fix) ?? .retry, directory: nil, engine: model.engine, openSettings: { _ in }) }
                            .buttonStyle(DSButtonStyle(.primary, size: .small))
                    }
                    Button("Check Again") { Task { await service.recheckRuntime() } }.buttonStyle(DSButtonStyle(.outline, size: .small))
                }
            }
            SettingsGroup(
                "Default image",
                footer: "Used by projects without their own image. There is no built-in public default: point this at your organisation's registry."
            ) {
                SettingsFieldRow(divided: false) {
                    TextField("", text: $model.defaultImage, prompt: Text("registry.example.com/dev/base:2026.11"))
                        .textFieldStyle(DSTextFieldStyle()).accessibilityLabel("Default container image")
                    Button("Save") { Task { await model.saveDefaultImage() } }.buttonStyle(DSButtonStyle(.outline, size: .small))
                }
            }
            SettingsGroup("Registry sign-in", footer: "The password or token is kept in your Keychain.") {
                SettingsFieldRow(divided: false) {
                    TextField("", text: $model.registry, prompt: Text("registry.example.com")).textFieldStyle(DSTextFieldStyle()).accessibilityLabel("Registry host")
                    TextField("", text: $model.username, prompt: Text("User")).textFieldStyle(DSTextFieldStyle()).frame(width: 96).accessibilityLabel("Registry user")
                    SecureField("", text: $model.password, prompt: Text("Password or token")).textFieldStyle(DSTextFieldStyle()).frame(width: 128)
                        .accessibilityLabel("Registry password")
                    Button("Sign In") { model.signIn() }.buttonStyle(DSButtonStyle(.outline, size: .small))
                        .disabled(model.registry.isEmpty || model.username.isEmpty || model.password.isEmpty)
                }
            }
            SettingsGroup("Isolation") {
                IsolationReportView(report: service.isolation, running: service.isVerifyingIsolation) {
                    Task { await service.verifyIsolation(full: true) }
                }
            }
            SettingsGroup("Host requirements") {
                ForEach(Array(model.requirements.enumerated()), id: \.element.id) { index, item in
                    SettingsRow(item.name, detail: item.detail, divided: index > 0) {
                        DSPillView(item.ok ? "Found" : "Missing", tone: item.ok ? .success : .danger, symbolName: item.ok ? "checkmark" : "xmark")
                    }
                }
            }
            SettingsGroup("Containers") {
                if model.containers.isEmpty {
                    SettingsRow(service.runtime?.isReady == true ? "No BelloCode containers" : "Containers are listed while Rancher Desktop runs", divided: false) {
                        EmptyView()
                    }
                }
                ForEach(Array(model.containers.enumerated()), id: \.element.id) { index, container in
                    SettingsRow(container.projectDirectory.map { ($0 as NSString).lastPathComponent } ?? container.name,
                                detail: "\(container.image) · \(container.status)", divided: index > 0) {
                        HStack(spacing: DS.Space.s2) {
                            DSPillView(container.isRunning ? "Running" : container.state.capitalized, tone: container.isRunning ? .success : .neutral,
                                       symbolName: container.isRunning ? "shippingbox" : "shippingbox")
                                .padding(.trailing, DS.Space.s4)
                            if container.isRunning {
                                Button("Stop") { Task { await model.perform(.stop, container) } }.buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                                Button("Restart") { Task { await model.perform(.restart, container) } }.buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                            } else {
                                Button("Start") { Task { await model.perform(.start, container) } }.buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                            }
                            Button("Logs") { Task { await model.showLogs(container) } }.buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                            Button("Remove…") { if confirmRemove(container) { Task { await model.perform(.remove, container) } } }
                                .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                        }
                    }
                }
            }
            if let logs = model.logs { LogsView(title: logs.title, text: logs.text) { model.logs = nil } }
            if let message = model.message { SettingsNote(message) }
        }
        .task { await model.reload() }
    }

    private var runtimeDetail: String? {
        guard case .ready(let ready) = service.runtime else { return service.runtime.map { _ in "Socket \(service.isEnabled ? "~/.rd/docker.sock" : "")" } }
        let rancher = ready.rancherVersion.map { "Rancher Desktop \($0) · " } ?? ""
        return "\(rancher)Docker Engine \(ready.engineVersion), API \(ready.apiVersion), \(ready.arch)" + (ready.notes.isEmpty ? "" : " · " + ready.notes.joined(separator: "; "))
    }
}

/// Verify Isolation: the verdict as a status pill (glyph + word) and summary, the button, then one row per check with
/// its outcome word (`dangerText` for problems), name and detail. Lives inside a `SettingsGroup`.
struct IsolationReportView: View {
    let report: IsolationReport?
    let running: Bool
    let verify: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s8) {
                if let report {
                    DSPillView(report.verdict.word, tone: report.verdict == .isolated ? .success : report.verdict == .problem ? .danger : .warning,
                               symbolName: report.verdict == .isolated ? "checkmark.shield" : report.verdict == .problem ? "exclamationmark.shield" : "questionmark.diamond")
                    Text(report.summary).font(.ds(.meta)).foregroundStyle(DSColor.text2).lineLimit(2)
                } else {
                    Text("Not checked yet").font(.ds(.body)).foregroundStyle(DSColor.text2)
                }
                Spacer(minLength: DS.Space.s8)
                Button(running ? "Verifying…" : "Verify Isolation") { verify() }.buttonStyle(DSButtonStyle(.outline, size: .small)).disabled(running)
                    .help("Runs a shell command, a PTY, a command template, a schedule condition and a terminal and proves where each one ran")
            }
            .padding(.horizontal, DS.Space.s12)
            .frame(minHeight: 40)
            if let report {
                ForEach(report.checks) { check in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s8) {
                        Text(check.outcome.word).font(.ds(.metaEmph))
                            .foregroundStyle(check.outcome.isProblem ? DSColor.dangerText : check.outcome.word == "Skipped" ? DSColor.warningText : DSColor.successText)
                            .frame(width: 64, alignment: .leading)
                        Text(check.name).font(.ds(.label)).foregroundStyle(DSColor.text).frame(width: 150, alignment: .leading)
                        Text(check.outcome.detail).font(.ds(.meta)).foregroundStyle(DSColor.text3).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Space.s12)
                    .padding(.vertical, DS.Space.s6)
                    .overlay(alignment: .top) { Rectangle().fill(DSColor.border).frame(height: 1).padding(.leading, DS.Space.s12) }
                }
            }
        }
    }
}

struct LogsView: View {
    let title: String
    let text: String
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack {
                Text("Logs: \(title)").font(.ds(.labelEmph)).foregroundStyle(DSColor.text)
                Spacer()
                Button("Close") { close() }.buttonStyle(DSButtonStyle(.ghost, size: .small))
            }
            ScrollView {
                Text(text.isEmpty ? "No output." : text).font(.ds(.codeSmall)).foregroundStyle(DSColor.text2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160).padding(DS.Space.s6).background(DSColor.codeFill, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
    }
}

/// Executables BelloCode itself needs on the Mac (everything else runs in containers).
struct HostRequirement: Identifiable, Equatable {
    var name: String
    var detail: String
    var ok: Bool
    var id: String { name }

    static func check(bundle: Bundle = .main) -> [HostRequirement] {
        let helpers = bundle.bundleURL.appending(path: "Contents/Helpers").path
        let items: [(String, String, String)] = [
            ("git", "/usr/bin/git", "History, diffs and worktrees on the Mac (hooks never run)"),
            ("/bin/sh", "/bin/sh", "Process plumbing"),
            ("opencode", helpers + "/opencode", "The bundled agent server"),
            ("bellocode-exec", helpers + "/bellocode-exec", "Forwards every command into the project's container"),
            ("rg", helpers + "/rg", "File search for the agent's grep and glob tools"),
        ]
        return items.map { name, path, purpose in
            let ok = FileManager.default.isExecutableFile(atPath: path)
            return HostRequirement(name: name, detail: "\(purpose) · \(path)", ok: ok)
        }
    }
}

// MARK: - Settings ▸ Environment (one project)

@MainActor
final class EnvironmentSettingsModel: ObservableObject {
    let engine: Engine
    var service: EnvironmentService { engine.environments }
    @Published var directory: String? { didSet { load() } }
    @Published var image = ""
    @Published var cpus = ""
    @Published var memoryGB = ""
    @Published var variables = ""
    @Published var network: WorkspaceSpec.Network = .bridge
    @Published var fileWatchBridge = true
    @Published var message: String?
    @Published var logs: String?
    var openTerminal: (String) -> Void = { _ in }
    var openBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }

    init(engine: Engine, directory: String?) {
        self.engine = engine
        self.directory = directory ?? engine.root.projects.first?.directory
        load()
    }

    /// The project the Environment pane opens on (set from the thread being shown); the last model, for snapshots.
    static var preferredDirectory: String?
    static weak var last: EnvironmentSettingsModel?

    /// Opens a terminal (in the project's container) in the frontmost main window's thread.
    static func openTerminalInFrontWindow() {
        guard let controller = NSApp.orderedWindows.compactMap({ $0.windowController as? MainWindowController }).first else { return }
        controller.window?.makeKeyAndOrderFront(nil)
        controller.newTerminal(nil)
    }

    func select(_ directory: String) { self.directory = directory }

    var projects: [(name: String, directory: String)] { engine.root.projects.map { ($0.name, $0.directory) } }
    var environment: ProjectEnvironment? { directory.map { service.environment(for: $0) } }

    func load() {
        guard let environment else { return }
        let settings = environment.settings
        image = settings.image ?? ""
        cpus = String(format: "%g", settings.resources.cpus)
        memoryGB = String(format: "%g", Double(settings.resources.memoryBytes) / Double(1 << 30))
        variables = settings.environment.keys.sorted().map { "\($0)=\(settings.environment[$0] ?? "")" }.joined(separator: "\n")
        network = settings.network
        fileWatchBridge = settings.fileWatchBridge
    }

    func save() async {
        guard let directory, let environment else { return }
        var settings = environment.settings
        let trimmed = image.trimmingCharacters(in: .whitespaces)
        settings.image = trimmed.isEmpty ? nil : trimmed
        if let value = Double(cpus), value > 0 { settings.resources.cpus = min(value, 64) }
        if let value = Double(memoryGB), value > 0 { settings.resources.memoryBytes = Int64(min(value, 256) * Double(1 << 30)) }
        var parsed: [String: String] = [:]
        for line in variables.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !ProjectEnvironmentSettings.reservedVariables.contains(name), !name.hasPrefix("BUN_") else {
                message = "\(name) cannot be set (reserved)."
                return
            }
            parsed[name] = parts[1]
        }
        settings.environment = parsed
        settings.network = network
        settings.fileWatchBridge = fileWatchBridge
        await service.update(directory, settings: settings)
        message = "Saved. The container is recreated on next use if anything changed."
    }

    func showLogs() async {
        guard let id = environment?.record.containerID else { logs = "No container yet."; return }
        logs = await service.logs(containerID: id)
    }

    func forward(_ port: Int) {
        guard let directory else { return }
        do { openBrowser(try service.forward(directory, port: port)) } catch { message = "Could not forward port \(port): \(error)" }
    }
}

struct EnvironmentSettingsView: View {
    @ObservedObject var model: EnvironmentSettingsModel

    var body: some View {
        SettingsPaneBody {
            SettingsGroup {
                SettingsRow(
                    model.projects.first { $0.directory == model.directory }?.name ?? model.directory.map { ($0 as NSString).lastPathComponent } ?? "No project",
                    detail: model.directory.map { ($0 as NSString).abbreviatingWithTildeInPath }, divided: false
                ) {
                    HStack(spacing: DS.Space.s8) {
                        if let environment = model.environment {
                            DSPillView(environment.phase.label, tone: environment.phase.tone.ds, symbolName: environment.phase.symbolName)
                        }
                        SettingsMenuPicker(
                            label: "Project", options: model.projects.map { ($0.directory, $0.name) },
                            selection: Binding(get: { model.directory ?? "" }, set: { model.directory = $0 }))
                    }
                }
            }
            if let environment = model.environment {
                content(environment)
            } else {
                SettingsNote("Open a project to set its environment.")
            }
            if let message = model.message { SettingsNote(message) }
        }
    }

    @ViewBuilder
    private func content(_ environment: ProjectEnvironment) -> some View {
        let service = model.service
        if let notice = environment.notice {
            EnvironmentBannerView(notice: notice, progress: { if case .pulling(let p) = environment.phase { p.fraction } else { nil } }(),
                                  fix: { fix in EnvironmentFixes.perform(fix, directory: environment.directory, engine: model.engine, openSettings: { _ in }) },
                                  retry: { Task { await service.retry(environment.directory) } })
        }
        SettingsGroup("Image", footer: environment.record.inventory.map { "\($0.os) · \($0.arch) · \($0.tools.joined(separator: ", "))" }) {
            SettingsFieldRow(divided: false) {
                TextField("", text: $model.image, prompt: Text(service.defaults.defaultImage.map { "Default: \($0)" } ?? "registry.example.com/team/image:tag"))
                    .textFieldStyle(DSTextFieldStyle()).accessibilityLabel("Container image")
                Button("Pull") { service.pull(environment) }.buttonStyle(DSButtonStyle(.outline, size: .small)).disabled(environment.image == nil)
                Button("Rebuild") { service.rebuild(environment.directory) }.buttonStyle(DSButtonStyle(.outline, size: .small))
                    .help("Removes the container and creates it again from the image (the project folder is untouched)")
            }
            if let reason = environment.outdatedReason {
                SettingsRow("Out of date", detail: "\(reason): recreated on next use.") {
                    DSPillView("Outdated", tone: .warning, symbolName: "exclamationmark.triangle")
                }
            }
        }
        SettingsGroup("Limits and network") {
            SettingsRow("Resources", divided: false) {
                HStack(spacing: DS.Space.s6) {
                    Text("CPUs").font(.ds(.label)).foregroundStyle(DSColor.text2)
                    TextField("", text: $model.cpus).textFieldStyle(DSTextFieldStyle()).frame(width: 52).accessibilityLabel("CPU limit")
                    Text("Memory (GB)").font(.ds(.label)).foregroundStyle(DSColor.text2).padding(.leading, DS.Space.s4)
                    TextField("", text: $model.memoryGB).textFieldStyle(DSTextFieldStyle()).frame(width: 52).accessibilityLabel("Memory limit")
                }
            }
            SettingsRow("Network") {
                DSSegmentedPicker(options: [(id: WorkspaceSpec.Network.bridge, title: "Online"), (id: .none, title: "Offline")], selection: $model.network)
                    .fixedSize()
            }
            SettingsToggleRow("Forward file changes to watchers in the container", detail: "Edits made on this Mac reach file watchers (vite, jest) inside it.", isOn: $model.fileWatchBridge)
        }
        SettingsGroup("Environment variables", footer: "One NAME=value per line. Visible to every command in the container: use Secrets for tokens.") {
            VStack(alignment: .trailing, spacing: DS.Space.s8) {
                TextEditor(text: $model.variables).font(.ds(.codeSmall)).scrollContentBackground(.hidden)
                    .frame(height: 64).padding(DS.Space.s4)
                    .background(DSColor.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(DSColor.borderStrong, lineWidth: 1))
                    .accessibilityLabel("Environment variables, one NAME=value per line")
                Button("Save Environment") { Task { await model.save() } }.buttonStyle(DSButtonStyle(.primary, size: .small))
            }
            .padding(DS.Space.s12)
        }
        SettingsGroup("Ports") {
            PortsListView(environment: environment, refresh: { Task { await service.refreshPorts(environment.directory) } },
                          open: { model.forward($0) }, stop: { service.stopForward(environment.directory, port: $0) })
        }
        SettingsGroup("Container") {
            SettingsActionsRow(divided: false) {
                Button("Open Terminal in Container") { model.openTerminal(environment.directory) }.buttonStyle(DSButtonStyle(.outline, size: .small))
                Spacer(minLength: DS.Space.s8)
                Button("Logs") { Task { await model.showLogs() } }.buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                Button("Stop") { service.stopContainer(environment.directory) }.buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                Button("Clean Up Processes") { Task { _ = await service.cleanUpProcesses(environment.directory) } }
                    .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                    .help("Ends processes left behind by cancelled commands")
            }
        }
        SettingsGroup("Isolation") {
            IsolationReportView(report: service.isolation.flatMap { $0.directory == environment.directory ? $0 : nil },
                                running: service.isVerifyingIsolation) {
                Task { await service.verifyIsolation(directory: environment.directory, full: true) }
            }
        }
        if let logs = model.logs { LogsView(title: environment.containerName, text: logs) { model.logs = nil } }
    }
}

/// The Ports list: what listens in the project's container, and what is forwarded to this Mac's loopback. Rows of a
/// `SettingsGroup`: port in mono, process and address in `meta text3`, outline Open, ghost Stop and Refresh.
struct PortsListView: View {
    let environment: ProjectEnvironment
    let refresh: () -> Void
    let open: (Int) -> Void
    let stop: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if environment.ports.isEmpty {
                SettingsRow("Nothing listens in the container", divided: false) {
                    Button("Refresh") { refresh() }.buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                }
            }
            ForEach(Array(environment.ports.enumerated()), id: \.element.port) { index, port in
                let forward = environment.forwards.first { $0.containerPort == port.port }
                SettingsRow(":\(port.port)", detail: [port.process, port.address == "0.0.0.0" || port.address == "::" ? "all interfaces" : port.address,
                                                     forward.map { "→ \($0.url.absoluteString)" }].compactMap { $0 }.joined(separator: " · "),
                            divided: index > 0) {
                    HStack(spacing: DS.Space.s4) {
                        if forward != nil {
                            DSPillView("Forwarded", tone: .success, symbolName: "arrow.up.right")
                            Button("Stop") { stop(port.port) }.buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                        }
                        Button(forward == nil ? "Open" : "Open Again") { open(port.port) }.buttonStyle(DSButtonStyle(.outline, size: .small))
                            .help("Forwards the port to this Mac's loopback only and opens it in the built-in browser")
                    }
                }
            }
            if !environment.ports.isEmpty {
                SettingsActionsRow {
                    Spacer()
                    Button("Refresh") { refresh() }.buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                }
            }
        }
    }
}
