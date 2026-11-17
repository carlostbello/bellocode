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
                if let progress { ProgressView(value: progress).progressViewStyle(.linear).frame(maxWidth: 240) }
            }
            Spacer(minLength: DS.Space.s8)
            if let action = notice.fix {
                Button(action.title) { fix(action) }.buttonStyle(DSButtonStyle(.primary, size: .small))
            }
            Button("Retry") { retry() }.buttonStyle(DSButtonStyle(.outline, size: .small))
                .help("Check again; commands run as soon as the environment is ready (no restart needed)")
        }
        .padding(DS.Space.s8)
        .background(SwiftUI.Color(nsColor: DS.Color.tone(notice.tone.ds).surface), in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(notice.title). \(notice.message)")
    }
}

/// A field drawn in the new visual language (no bezel).
private struct DSField: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(.ds(.body))
            .padding(.horizontal, DS.Space.s8).frame(height: DS.Size.control)
            .background(DSColor.fillSubtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).stroke(DSColor.borderStrong, lineWidth: 1))
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.ds(.labelEmph)).foregroundStyle(DSColor.text3).padding(.top, DS.Space.s8) }
}

private struct Row<Trailing: View>: View {
    let title: String
    let detail: String?
    let trailing: Trailing
    init(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }
    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.s8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ds(.body)).foregroundStyle(DSColor.text)
                if let detail { Text(detail).font(.ds(.meta)).foregroundStyle(DSColor.text3).lineLimit(2) }
            }
            Spacer(minLength: DS.Space.s8)
            trailing
        }
        .frame(minHeight: DS.Size.sidebarRow)
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
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s6) {
                Text("Everything the agent or you run executes in a Linux container on Rancher Desktop, with the project at the same path. Nothing falls back to this Mac.")
                    .font(.ds(.meta)).foregroundStyle(DSColor.text2).fixedSize(horizontal: false, vertical: true)
                SectionLabel("Runtime")
                Row(service.isEnabled ? (service.runtime?.userMessage ?? "Checking Rancher Desktop…") : "Container execution is off in this build.",
                    detail: runtimeDetail) {
                    RuntimeStatusLabel(runtime: service.runtime, enabled: service.isEnabled)
                }
                HStack(spacing: DS.Space.s6) {
                    if let fix = service.runtime?.fix {
                        Button(fix.rawValue) { EnvironmentFixes.perform(EnvironmentFix(fix) ?? .retry, directory: nil, engine: model.engine, openSettings: { _ in }) }
                            .buttonStyle(DSButtonStyle(.primary, size: .small))
                    }
                    Button("Check Again") { Task { await service.recheckRuntime() } }.buttonStyle(DSButtonStyle(.outline, size: .small))
                }

                SectionLabel("Default image")
                Text("Used by projects without their own image. There is no built-in public default: point this at your organisation's registry.")
                    .font(.ds(.meta)).foregroundStyle(DSColor.text3).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("", text: $model.defaultImage, prompt: Text("registry.example.com/dev/base:2026.11")).modifier(DSField())
                        .accessibilityLabel("Default container image")
                    Button("Save") { Task { await model.saveDefaultImage() } }.buttonStyle(DSButtonStyle(.outline, size: .small))
                }

                SectionLabel("Registry sign-in")
                HStack {
                    TextField("", text: $model.registry, prompt: Text("registry.example.com")).modifier(DSField()).accessibilityLabel("Registry host")
                    TextField("", text: $model.username, prompt: Text("User")).modifier(DSField()).frame(width: 120).accessibilityLabel("Registry user")
                    SecureField("", text: $model.password, prompt: Text("Password or token")).modifier(DSField()).frame(width: 150)
                        .accessibilityLabel("Registry password")
                    Button("Sign In") { model.signIn() }.buttonStyle(DSButtonStyle(.outline, size: .small))
                        .disabled(model.registry.isEmpty || model.username.isEmpty || model.password.isEmpty)
                }

                SectionLabel("Isolation")
                IsolationReportView(report: service.isolation, running: service.isVerifyingIsolation) {
                    Task { await service.verifyIsolation(full: true) }
                }

                SectionLabel("Host requirements")
                ForEach(model.requirements) { item in
                    Row(item.name, detail: item.detail) {
                        DSPillView(item.ok ? "Found" : "Missing", tone: item.ok ? .success : .danger, symbolName: item.ok ? "checkmark" : "xmark")
                    }
                }

                SectionLabel("Containers")
                if model.containers.isEmpty {
                    Text(service.runtime?.isReady == true ? "No BelloCode containers." : "Containers are listed while Rancher Desktop runs.")
                        .font(.ds(.meta)).foregroundStyle(DSColor.text3)
                }
                ForEach(model.containers) { container in
                    Row(container.projectDirectory.map { ($0 as NSString).lastPathComponent } ?? container.name,
                        detail: "\(container.image) · \(container.status)") {
                        DSPillView(container.isRunning ? "Running" : container.state.capitalized, tone: container.isRunning ? .success : .neutral,
                                   symbolName: container.isRunning ? "shippingbox.fill" : "shippingbox")
                        if container.isRunning {
                            Button("Stop") { Task { await model.perform(.stop, container) } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                            Button("Restart") { Task { await model.perform(.restart, container) } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                        } else {
                            Button("Start") { Task { await model.perform(.start, container) } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                        }
                        Button("Logs") { Task { await model.showLogs(container) } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                        Button("Remove…") { if confirmRemove(container) { Task { await model.perform(.remove, container) } } }
                            .buttonStyle(DSButtonStyle(.ghost, size: .small))
                    }
                }
                if let logs = model.logs { LogsView(title: logs.title, text: logs.text) { model.logs = nil } }
                if let message = model.message { Text(message).font(.ds(.meta)).foregroundStyle(DSColor.text2) }
            }
            .padding(DS.Space.s20)
        }
        .frame(width: 640, height: 620)
        .background(DSColor.canvas)
        .task { await model.reload() }
    }

    private var runtimeDetail: String? {
        guard case .ready(let ready) = service.runtime else { return service.runtime.map { _ in "Socket \(service.isEnabled ? "~/.rd/docker.sock" : "")" } }
        let rancher = ready.rancherVersion.map { "Rancher Desktop \($0) · " } ?? ""
        return "\(rancher)Docker Engine \(ready.engineVersion), API \(ready.apiVersion), \(ready.arch)" + (ready.notes.isEmpty ? "" : " · " + ready.notes.joined(separator: "; "))
    }
}

struct IsolationReportView: View {
    let report: IsolationReport?
    let running: Bool
    let verify: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack {
                if let report {
                    DSPillView(report.passed ? "Isolated" : "Problem", tone: report.passed ? .success : .danger,
                               symbolName: report.passed ? "checkmark.shield" : "exclamationmark.shield")
                    Text(report.summary).font(.ds(.meta)).foregroundStyle(DSColor.text2).lineLimit(2)
                } else {
                    Text("Not checked yet.").font(.ds(.meta)).foregroundStyle(DSColor.text3)
                }
                Spacer()
                Button(running ? "Verifying…" : "Verify Isolation") { verify() }.buttonStyle(DSButtonStyle(.outline, size: .small)).disabled(running)
                    .help("Runs a shell command, a PTY, a command template, a schedule condition and a terminal and proves where each one ran")
            }
            if let report {
                ForEach(report.checks) { check in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s6) {
                        Text(check.outcome.word).font(.ds(.metaEmph))
                            .foregroundStyle(check.outcome.isProblem ? DSColor.dangerText : DSColor.text2).frame(width: 70, alignment: .leading)
                        Text(check.name).font(.ds(.meta)).foregroundStyle(DSColor.text).frame(width: 170, alignment: .leading)
                        Text(check.outcome.detail).font(.ds(.meta)).foregroundStyle(DSColor.text3).lineLimit(2)
                    }
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
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s6) {
                HStack {
                    Menu {
                        ForEach(model.projects, id: \.directory) { project in
                            Button(project.name) { model.directory = project.directory }
                        }
                    } label: {
                        Label(model.directory.map { ($0 as NSString).lastPathComponent } ?? "No project", systemImage: "folder")
                            .font(.ds(.bodyEmph)).foregroundStyle(DSColor.text)
                    }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Project")
                    Spacer()
                    if let environment = model.environment {
                        DSPillView(environment.phase.label, tone: environment.phase.tone.ds, symbolName: environment.phase.symbolName)
                    }
                }
                if let directory = model.directory {
                    Text(directory).font(.ds(.meta)).foregroundStyle(DSColor.text3).lineLimit(1).truncationMode(.middle)
                }
                if let environment = model.environment {
                    content(environment)
                } else {
                    Text("Open a project to set its environment.").font(.ds(.body)).foregroundStyle(DSColor.text3)
                }
                if let message = model.message { Text(message).font(.ds(.meta)).foregroundStyle(DSColor.text2) }
            }
            .padding(DS.Space.s20)
        }
        .frame(width: 640, height: 640)
        .background(DSColor.canvas)
    }

    @ViewBuilder
    private func content(_ environment: ProjectEnvironment) -> some View {
        let service = model.service
        if let notice = environment.notice {
            EnvironmentBannerView(notice: notice, progress: { if case .pulling(let p) = environment.phase { p.fraction } else { nil } }(),
                                  fix: { fix in EnvironmentFixes.perform(fix, directory: environment.directory, engine: model.engine, openSettings: { _ in }) },
                                  retry: { Task { await service.retry(environment.directory) } })
        }
        SectionLabel("Image")
        HStack {
            TextField("", text: $model.image, prompt: Text(service.defaults.defaultImage.map { "Default: \($0)" } ?? "registry.example.com/team/image:tag"))
                .modifier(DSField()).accessibilityLabel("Container image")
            Button("Pull") { service.pull(environment) }.buttonStyle(DSButtonStyle(.outline, size: .small)).disabled(environment.image == nil)
            Button("Rebuild") { service.rebuild(environment.directory) }.buttonStyle(DSButtonStyle(.outline, size: .small))
                .help("Removes the container and creates it again from the image (the project folder is untouched)")
        }
        if let inventory = environment.record.inventory {
            Text("\(inventory.os) · \(inventory.arch) · \(inventory.tools.joined(separator: ", "))").font(.ds(.meta)).foregroundStyle(DSColor.text3)
        }
        if let reason = environment.outdatedReason {
            Text("Out of date (\(reason)): recreated on next use.").font(.ds(.meta)).foregroundStyle(DSColor.warningText)
        }

        SectionLabel("Limits and network")
        HStack(spacing: DS.Space.s8) {
            Text("CPUs").font(.ds(.label)).foregroundStyle(DSColor.text2)
            TextField("", text: $model.cpus).modifier(DSField()).frame(width: 60).accessibilityLabel("CPU limit")
            Text("Memory (GB)").font(.ds(.label)).foregroundStyle(DSColor.text2)
            TextField("", text: $model.memoryGB).modifier(DSField()).frame(width: 60).accessibilityLabel("Memory limit")
            Spacer()
            DSSegmentedPicker(options: [(id: WorkspaceSpec.Network.bridge, title: "Network"), (id: .none, title: "Offline")], selection: $model.network)
                .fixedSize()
        }
        Toggle("Forward file changes from this Mac to watchers in the container", isOn: $model.fileWatchBridge)
            .toggleStyle(DSToggleStyle(.checkbox)).font(.ds(.body))

        SectionLabel("Environment variables")
        TextEditor(text: $model.variables).font(.ds(.codeSmall)).scrollContentBackground(.hidden)
            .frame(height: 64).padding(DS.Space.s4)
            .background(DSColor.fillSubtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).stroke(DSColor.borderStrong, lineWidth: 1))
            .accessibilityLabel("Environment variables, one NAME=value per line")
        Text("One NAME=value per line. Visible to every command in the container: use Secrets for tokens.")
            .font(.ds(.meta)).foregroundStyle(DSColor.text3)
        HStack {
            Spacer()
            Button("Save Environment") { Task { await model.save() } }.buttonStyle(DSButtonStyle(.primary, size: .small))
        }

        SectionLabel("Ports")
        PortsListView(environment: environment, refresh: { Task { await service.refreshPorts(environment.directory) } },
                      open: { model.forward($0) }, stop: { service.stopForward(environment.directory, port: $0) })

        SectionLabel("Container")
        HStack(spacing: DS.Space.s6) {
            Button("Open Terminal in Container") { model.openTerminal(environment.directory) }.buttonStyle(DSButtonStyle(.outline, size: .small))
            Button("Logs") { Task { await model.showLogs() } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
            Button("Stop") { service.stopContainer(environment.directory) }.buttonStyle(DSButtonStyle(.ghost, size: .small))
            Button("Clean Up Processes") { Task { _ = await service.cleanUpProcesses(environment.directory) } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                .help("Ends processes left behind by cancelled commands")
        }
        SectionLabel("Isolation")
        IsolationReportView(report: service.isolation.flatMap { $0.directory == environment.directory ? $0 : nil },
                            running: service.isVerifyingIsolation) {
            Task { await service.verifyIsolation(directory: environment.directory, full: true) }
        }
        if let logs = model.logs { LogsView(title: environment.containerName, text: logs) { model.logs = nil } }
    }
}

/// The Ports list: what listens in the project's container, and what is forwarded to this Mac's loopback.
struct PortsListView: View {
    let environment: ProjectEnvironment
    let refresh: () -> Void
    let open: (Int) -> Void
    let stop: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if environment.ports.isEmpty {
                HStack {
                    Text("Nothing listens in the container.").font(.ds(.meta)).foregroundStyle(DSColor.text3)
                    Spacer()
                    Button("Refresh") { refresh() }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                }
            }
            ForEach(environment.ports, id: \.port) { port in
                let forward = environment.forwards.first { $0.containerPort == port.port }
                Row(":\(port.port)", detail: [port.process, port.address == "0.0.0.0" || port.address == "::" ? "all interfaces" : port.address,
                                              forward.map { "→ \($0.url.absoluteString)" }].compactMap { $0 }.joined(separator: " · ")) {
                    Button(forward == nil ? "Open" : "Open Again") { open(port.port) }.buttonStyle(DSButtonStyle(.outline, size: .small))
                        .help("Forwards the port to this Mac's loopback only and opens it in the built-in browser")
                    if forward != nil {
                        Button("Stop") { stop(port.port) }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                    }
                }
            }
            if !environment.ports.isEmpty {
                HStack { Spacer(); Button("Refresh") { refresh() }.buttonStyle(DSButtonStyle(.ghost, size: .small)) }
            }
        }
    }
}
