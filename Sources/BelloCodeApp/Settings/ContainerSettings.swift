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
    @Published var caches: [CacheVolume] = []
    @Published var allowlist: String
    @Published var requireDigest: Bool
    @Published var pullPolicy: ImagePolicy.PullPolicy
    @Published var requireSignature: Bool

    /// The model of the open Settings ▸ Containers pane (the Window menu's Prune command uses it).
    static weak var last: ContainersSettingsModel?

    init(engine: Engine) {
        self.engine = engine
        engine.environments.reloadManagedPolicy()
        defaultImage = engine.environments.defaultImage ?? ""
        let policy = engine.environments.imagePolicy
        allowlist = policy.allowedPrefixes.joined(separator: "\n")
        requireDigest = policy.requireDigest
        pullPolicy = policy.pullPolicy
        requireSignature = policy.requireSignature
    }

    /// Saves the image policy set here (ignored while an administrator manages it).
    func savePolicy() async {
        guard service.managedPolicy == nil else { return }
        var defaults = service.defaults
        let prefixes = allowlist.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        defaults.imagePolicy = ImagePolicy(allowedPrefixes: prefixes, requireDigest: requireDigest, pullPolicy: pullPolicy, requireSignature: requireSignature)
        await service.setDefaults(defaults)
        message = prefixes.isEmpty && !requireDigest && !requireSignature
            ? "Image policy saved: any image may run." : "Image policy saved. Projects outside it are refused until their image is changed."
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

    func reload() async {
        containers = await service.managedContainers()
        caches = await service.cacheVolumes()
    }

    /// "Prune BelloCode Resources…": lists exactly what would be removed (stopped BelloCode containers, unused
    /// BelloCode volumes of projects BelloCode no longer has, unattached BelloCode networks, unused images BelloCode
    /// pulled), asks once (cannot be undone), then removes only those that still qualify.
    func confirmPrune() async {
        let plan: PrunePlan
        do { plan = try await service.prunePlan() } catch {
            message = "Could not list BelloCode's resources: \(error)"
            return
        }
        guard !plan.isEmpty else {
            message = "Nothing to prune: no stopped BelloCode containers, unused volumes, networks or pulled images."
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Remove \(plan.count) BelloCode resource\(plan.count == 1 ? "" : "s")?"
        var sections: [String] = []
        func section(_ title: String, _ items: [PrunePlan.Item]) {
            guard !items.isEmpty else { return }
            sections.append(title + ":\n" + items.map { "• \($0.name) (\($0.detail))" }.joined(separator: "\n"))
        }
        section("Stopped containers", plan.containers)
        section("Unused volumes", plan.volumes)
        section("Unused networks", plan.networks)
        section("Unused images BelloCode pulled", plan.images)
        sections.append("Only resources labelled as BelloCode's are listed; nothing else on Rancher Desktop is touched. Volume contents are lost. This cannot be undone.")
        alert.informativeText = sections.joined(separator: "\n\n")
        let remove = alert.addButton(withTitle: "Remove \(plan.count) Item\(plan.count == 1 ? "" : "s")")
        remove.hasDestructiveAction = true
        remove.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let result = try await service.prune(plan)
            message = "Removed \(result.removed.count) item\(result.removed.count == 1 ? "" : "s")."
                + (result.kept.isEmpty ? "" : " Kept \(result.kept.count) that changed since: \(result.kept.joined(separator: ", ")).")
        } catch {
            message = "Prune failed: \(error)"
        }
        await reload()
    }

    /// "Clean…" on a cache: confirms (the contents are deleted), then deletes the volume.
    func confirmClean(_ cache: CacheVolume) async {
        let alert = NSAlert()
        alert.messageText = "Empty the \(cache.cache?.title ?? "") cache “\(cache.name)”?"
        alert.informativeText = "Its contents are deleted (\(cache.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "size unknown")); packages are downloaded again when needed. Stopped containers that use it are recreated on next use. This cannot be undone."
        let clean = alert.addButton(withTitle: "Empty Cache")
        clean.hasDestructiveAction = true
        clean.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try await service.cleanCache(cache.name)
            message = "Emptied \(cache.name)."
        } catch {
            message = "Not emptied: \(error)"
        }
        await reload()
    }

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
            if let problem = service.helperConfigProblem {
                SettingsRow(problem, divided: false) { DSPillView("Commands refused", tone: .danger, symbolName: "xmark.octagon") }
            }
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
                if let managed = service.managedPolicy?.defaultImage {
                    SettingsRow(managed, detail: "Set by your organisation", divided: false) {
                        DSPillView("Managed", tone: .info, symbolName: "building.2")
                    }
                } else {
                    SettingsFieldRow(divided: false) {
                        TextField("", text: $model.defaultImage, prompt: Text("registry.example.com/dev/base:2026.11"))
                            .textFieldStyle(DSTextFieldStyle()).accessibilityLabel("Default container image")
                        Button("Save") { Task { await model.saveDefaultImage() } }.buttonStyle(DSButtonStyle(.outline, size: .small))
                    }
                }
            }
            SettingsGroup("Image policy", footer: model.service.managedPolicy == nil
                ? "Applies to every project's image and its services. One registry (registry.acme.internal) or repository prefix (registry.acme.internal/dev/) per line; empty allows any image. Administrators can manage this policy (docs/features/containers.md)."
                : "Set by your organisation (\(model.service.managedPolicy?.source ?? "")). Images outside it are refused for the workspace and every service.") {
                ImagePolicySettingsView(model: model)
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
            SettingsGroup("Caches", footer: "Package-manager caches kept across container rebuilds. Each project has its own unless a cache is shared (Project Settings ▸ Environment ▸ Caches).") {
                CacheVolumesView(caches: model.caches, projects: model.engine.root.projects.map { ($0.directory, $0.name) }) { cache in
                    Task { await model.confirmClean(cache) }
                }
            }
            SettingsGroup("Host requirements") {
                ForEach(Array(model.requirements.enumerated()), id: \.element.id) { index, item in
                    SettingsRow(item.name, detail: item.detail, divided: index > 0) {
                        DSPillView(item.ok ? "Found" : "Missing", tone: item.ok ? .success : .danger, symbolName: item.ok ? "checkmark" : "xmark")
                    }
                }
            }
            SettingsGroup("Containers", footer: "Prune removes stopped BelloCode containers, unused BelloCode volumes of projects no longer in BelloCode, unattached BelloCode networks and unused images BelloCode pulled, after listing them. Nothing else is touched.") {
                SettingsActionsRow(divided: false) {
                    Text("\(model.containers.count) container\(model.containers.count == 1 ? "" : "s")").font(.ds(.label)).foregroundStyle(DSColor.text2)
                    Spacer()
                    Button("Prune BelloCode Resources…") { Task { await model.confirmPrune() } }.buttonStyle(DSButtonStyle(.outline, size: .small))
                        .disabled(service.runtime?.isReady != true)
                }
                if model.containers.isEmpty {
                    SettingsRow(service.runtime?.isReady == true ? "No BelloCode containers" : "Containers are listed while Rancher Desktop runs", divided: false) {
                        EmptyView()
                    }
                }
                ForEach(Array(model.containers.enumerated()), id: \.element.id) { index, container in
                    SettingsRow((container.projectDirectory.map { ($0 as NSString).lastPathComponent } ?? container.name)
                                    + (container.service.map { " · service \($0)" } ?? " · workspace"),
                                detail: "\(container.image) · \(container.status)", divided: index > 0) {
                        HStack(spacing: DS.Space.s2) {
                            ManagedContainerPill(container: container).padding(.trailing, DS.Space.s4)
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

/// A managed container's state as glyph + word: health first when it has a healthcheck.
struct ManagedContainerPill: View {
    let container: ManagedContainer
    var body: some View {
        let (word, tone, symbol): (String, DS.Tone, String) = switch (container.isRunning, container.health) {
        case (true, "healthy"?): ("Healthy", .success, "checkmark.circle")
        case (true, "unhealthy"?): ("Unhealthy", .warning, "exclamationmark.triangle")
        case (true, "starting"?): ("Checking health", .info, "arrow.triangle.2.circlepath")
        case (true, _): ("Running", .success, container.service == nil ? "shippingbox.fill" : "cylinder.split.1x2")
        default: (container.state.capitalized, .neutral, container.service == nil ? "shippingbox" : "cylinder.split.1x2")
        }
        DSPillView(word, tone: tone, symbolName: symbol)
    }
}

/// The image policy: editable rows, or the administrator's values read-only with a "Managed" pill.
struct ImagePolicySettingsView: View {
    @ObservedObject var model: ContainersSettingsModel

    var body: some View {
        let service = model.service
        if let managed = service.managedPolicy {
            let policy = managed.policy
            SettingsRow("Allowed images", detail: policy.allowedPrefixes.isEmpty ? "Any image" : policy.allowedPrefixes.joined(separator: ", "), divided: false) {
                DSPillView("Managed", tone: .info, symbolName: "building.2")
            }
            SettingsRow("Pinned by digest", detail: policy.requireDigest ? "Required" : "Not required") { EmptyView() }
            SettingsRow("Pulling", detail: Self.pullText(policy.pullPolicy)) { EmptyView() }
            SettingsRow("Verified signatures", detail: policy.requireSignature
                ? "Required: BelloCode cannot verify signatures yet, so every image is refused" : "Not required") {
                if policy.requireSignature { DSPillView("Refusing all", tone: .danger, symbolName: "hand.raised") } else { EmptyView() }
            }
        } else {
            VStack(alignment: .trailing, spacing: DS.Space.s8) {
                TextEditor(text: $model.allowlist).font(.ds(.codeSmall)).scrollContentBackground(.hidden)
                    .frame(height: 48).padding(DS.Space.s4)
                    .background(DSColor.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(DSColor.borderStrong, lineWidth: 1))
                    .accessibilityLabel("Allowed registries or repository prefixes, one per line")
            }
            .padding(DS.Space.s12)
            SettingsToggleRow("Require images pinned by digest", detail: "name@sha256:…, so a tag cannot change under a project.", isOn: $model.requireDigest)
            SettingsRow("Pulling") {
                DSSegmentedPicker(options: [(id: ImagePolicy.PullPolicy.missing, title: "When missing"), (id: .always, title: "Always"), (id: .never, title: "Never")],
                                  selection: $model.pullPolicy).fixedSize()
            }
            SettingsToggleRow("Require verified signatures", detail: "BelloCode cannot verify signatures yet: turning this on refuses every image.",
                              isOn: $model.requireSignature)
            SettingsActionsRow {
                Spacer()
                Button("Save Policy") { Task { await model.savePolicy() } }.buttonStyle(DSButtonStyle(.primary, size: .small))
            }
        }
    }

    static func pullText(_ policy: ImagePolicy.PullPolicy) -> String {
        switch policy {
        case .missing: "When an image is not on this Mac"
        case .always: "Before every container is created (follows moved tags)"
        case .never: "Never: images must be loaded on this Mac by other means"
        }
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
    @Published var newMCPName = ""
    @Published var newMCPCommand = ""
    /// The last removed MCP server, for Undo (reversible: applied at once).
    @Published var removedMCP: MCPServerSetting?
    /// Services defined in the pane (compose subset), edited here when the project has no compose file.
    @Published var servicesYAML = ""
    @Published var cacheChoices: [PackageCache: CacheSelection] = [:]
    @Published var serviceLogs: (name: String, text: String)?
    var openTerminal: (String) -> Void = { _ in }
    var openServiceTerminal: (String, String) -> Void = { service, directory in
        EnvironmentSettingsModel.openServiceTerminalInFrontWindow(service: service, projectDirectory: directory)
    }
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

    /// Opens a terminal tab with a shell in one of the project's service containers, in the frontmost main window.
    static func openServiceTerminalInFrontWindow(service: String, projectDirectory: String) {
        guard let controller = NSApp.orderedWindows.compactMap({ $0.windowController as? MainWindowController }).first else { return }
        controller.window?.makeKeyAndOrderFront(nil)
        controller.terminals?.newServiceTerminal(service: service, projectDirectory: projectDirectory)
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
        servicesYAML = settings.servicesYAML ?? ""
        let declared = environment.record.imageCaches ?? [:]
        cacheChoices = Dictionary(uniqueKeysWithValues: PackageCache.allCases.map { cache in
            (cache, settings.caches.first { $0.cache == cache } ?? CacheSelection(cache: cache, enabled: declared[cache] != nil))
        })
    }

    func saveCaches() async {
        guard let directory, let environment else { return }
        var settings = environment.settings
        let declared = environment.record.imageCaches ?? [:]
        // Store only what differs from the image's declaration (so a later image change still applies).
        settings.caches = PackageCache.allCases.compactMap { cache in
            guard let choice = cacheChoices[cache] else { return nil }
            let byImage = declared[cache] != nil
            return choice.enabled == byImage && !choice.shared ? nil : choice
        }
        await service.update(directory, settings: settings)
        message = "Caches saved. The container is recreated on next use; cache contents are kept."
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

    // MARK: Services

    func saveServices() async {
        guard let directory, let environment else { return }
        let trimmed = servicesYAML.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let parse = ComposeParser.parse(servicesYAML)
            if !parse.isUsable {
                message = parse.errors.joined(separator: " ")
                return
            }
        }
        var settings = environment.settings
        settings.servicesYAML = trimmed.isEmpty ? nil : servicesYAML
        await service.update(directory, settings: settings)
        message = trimmed.isEmpty ? "Services removed from this project's settings (their volumes are kept)." : "Services saved. They start with the project's container."
    }

    func showServiceLogs(_ name: String) async {
        guard let directory else { return }
        do {
            let (text, truncated) = try await service.serviceLogs(directory, name: name, tail: 300, limit: 256 * 1024)
            serviceLogs = (name, (truncated ? "[older output omitted]\n" : "") + text)
        } catch {
            message = "\(error)"
        }
    }

    func restartService(_ name: String) async {
        guard let directory else { return }
        do { try await service.restartService(directory, name: name) } catch { message = "Could not restart \(name): \(error)" }
    }

    func openServicePort(_ name: String, port: Int) {
        guard let directory else { return }
        do { openBrowser(try service.forwardService(directory, name: name, port: port)) } catch { message = "Could not forward \(name):\(port): \(error)" }
    }

    /// "Delete Service Data…": lists the service's volumes, asks once (cannot be undone), deletes only those.
    func confirmDeleteServiceData(_ name: String) async {
        guard let directory else { return }
        let volumes: [String]
        do { volumes = try await service.serviceDataToDelete(directory, name: name) } catch {
            message = "Could not list \(name)'s data: \(error)"
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete the data of the service “\(name)”?"
        alert.informativeText = (volumes.isEmpty ? "The service has no data volumes; its container is removed." :
            "Volumes:\n" + volumes.map { "• \($0)" }.joined(separator: "\n") + "\n\nThe service's container is removed too.")
            + " It is created again, empty, the next time services start. This cannot be undone."
        let delete = alert.addButton(withTitle: "Delete Service Data")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try await service.deleteServiceData(directory, name: name, confirmed: volumes)
            message = "Deleted \(name)'s container and \(volumes.count) volume(s)."
        } catch {
            message = "Not deleted: \(error)"
        }
    }

    // MARK: MCP servers (applied at once; removal has Undo)

    func addMCPServer() async {
        guard let directory, let environment else { return }
        let server = MCPServerSetting(name: newMCPName.trimmingCharacters(in: .whitespaces), command: MCPServerSetting.split(commandLine: newMCPCommand))
        var settings = environment.settings
        settings.mcpServers.removeAll { $0.name == server.name }
        settings.mcpServers.append(server)
        let errors = server.validationErrors()
        guard errors.isEmpty else {
            message = errors.joined(separator: " ")
            return
        }
        await service.update(directory, settings: settings)
        newMCPName = ""
        newMCPCommand = ""
        removedMCP = nil
        message = "Added MCP server “\(server.name)”. It runs in this project's container and starts when the container is ready."
        await service.refreshMCPStatus(directory)
    }

    func removeMCPServer(_ server: MCPServerSetting) async {
        guard let directory, let environment else { return }
        var settings = environment.settings
        settings.mcpServers.removeAll { $0.name == server.name }
        await service.update(directory, settings: settings)
        removedMCP = server
        message = nil
    }

    func undoRemoveMCPServer() async {
        guard let directory, let environment, let server = removedMCP else { return }
        var settings = environment.settings
        settings.mcpServers.append(server)
        await service.update(directory, settings: settings)
        removedMCP = nil
    }

    func setMCPServer(_ server: MCPServerSetting, enabled: Bool) async {
        guard let directory, let environment else { return }
        var settings = environment.settings
        guard let index = settings.mcpServers.firstIndex(where: { $0.name == server.name }) else { return }
        settings.mcpServers[index].enabled = enabled
        await service.update(directory, settings: settings)
    }

    func showLogs() async {
        guard let id = environment?.record.containerID else { logs = "No container yet."; return }
        logs = await service.logs(containerID: id)
    }

    /// "Delete Container and Data…": lists exactly what will be deleted (containers and volumes, including the
    /// persistent home), asks once (it cannot be undone), then deletes only that. Archiving a project never does this.
    func confirmPurge() async {
        guard let directory else { return }
        let storage: WorkspaceStorage
        do { storage = try await service.storageToPurge(directory) } catch {
            message = "Could not list the project's container data: \(error)"
            return
        }
        guard !storage.isEmpty else {
            message = "This project has no container or container data to delete."
            return
        }
        let name = (directory as NSString).lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete the container and data of “\(name)”?"
        var lines: [String] = []
        if !storage.containers.isEmpty { lines.append("Containers:\n" + storage.containers.map { "• \($0)" }.joined(separator: "\n")) }
        if !storage.volumes.isEmpty {
            lines.append("Volumes (the container's home folder, caches and service data):\n" + storage.volumes.map { "• \($0)" }.joined(separator: "\n"))
        }
        if !storage.networks.isEmpty { lines.append("Networks:\n" + storage.networks.map { "• \($0)" }.joined(separator: "\n")) }
        lines.append("Files saved only inside the container are lost. The project folder on this Mac is not touched. This cannot be undone.")
        alert.informativeText = lines.joined(separator: "\n\n")
        let delete = alert.addButton(withTitle: "Delete Container and Data")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        delete.keyEquivalent = ""
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try await service.purge(directory, confirmed: storage)
            message = "Deleted \(storage.containers.count) container(s) and \(storage.volumes.count) volume(s)."
        } catch {
            message = "Not deleted: \(error)"
        }
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
        if let problem = service.helperConfigProblem {
            SettingsRow(problem, divided: false) { DSPillView("Commands refused", tone: .danger, symbolName: "xmark.octagon") }
        }
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
        SettingsGroup("Services", footer: ServicesSectionView.footer(environment)) {
            ServicesSectionView(model: model, environment: environment)
        }
        SettingsGroup("Caches", footer: "Named volumes for package-manager caches, kept when the container is rebuilt. “Shared” uses one volume for every project that also shares it; otherwise the cache is this project's own.") {
            ProjectCachesView(model: model, environment: environment)
        }
        SettingsGroup("MCP servers", footer: "Local (stdio) MCP servers of this project run in its container through bellocode-exec --stdio; only their input and output cross to this Mac. Servers configured for all projects are refused.") {
            MCPServersListView(model: model, environment: environment)
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
                Button("Delete Container and Data…") { Task { await model.confirmPurge() } }
                    .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                    .help("Deletes the project's container and its volumes (home folder and caches) after listing them. Cannot be undone.")
            }
        }
        SettingsGroup("Isolation") {
            IsolationReportView(report: service.isolation.flatMap { $0.directory == environment.directory ? $0 : nil },
                                running: service.isVerifyingIsolation) {
                Task { await service.verifyIsolation(directory: environment.directory, full: true) }
            }
        }
        if let logs = model.logs { LogsView(title: environment.containerName, text: logs) { model.logs = nil } }
        if let logs = model.serviceLogs { LogsView(title: "service \(logs.name)", text: logs.text) { model.serviceLogs = nil } }
    }
}

/// The project's services: one row per service (name, image, ports; state as glyph + word with health; Open per port
/// into the built-in browser, Logs, Terminal, Restart, Delete Data…), what the definition left out (ignored and
/// refused keys), and the definition itself (the compose file's path, or an editor for services defined here).
struct ServicesSectionView: View {
    @ObservedObject var model: EnvironmentSettingsModel
    let environment: ProjectEnvironment

    static func footer(_ environment: ProjectEnvironment) -> String {
        switch environment.servicesSource {
        case .file(let path): "Defined in \((path as NSString).lastPathComponent) (checked in). Services share the project's own network: reach them by name (db:5432). Nothing is published; Open forwards a port to this Mac's loopback only."
        case .pane: "Defined here (compose subset). Services share the project's own network: reach them by name (db:5432). Nothing is published; Open forwards a port to this Mac's loopback only."
        case .none: "Supporting containers (databases, caches, queues) for this project, from a checked-in compose.yaml or defined below. They start and stop with the project's container."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if environment.services.isEmpty, environment.servicesParse?.isUsable != false {
                SettingsRow("No services", detail: "Add a compose.yaml to the project, or define services below.", divided: false) { EmptyView() }
            }
            ForEach(environment.servicesParse?.errors ?? [], id: \.self) { error in
                SettingsRow("The definition cannot be used", detail: error, divided: false) {
                    DSPillView("Not used", tone: .danger, symbolName: "xmark.octagon")
                }
            }
            ForEach(Array(environment.services.enumerated()), id: \.element.id) { index, service in
                ServiceRowView(model: model, environment: environment, service: service, divided: index > 0)
            }
            if let parse = environment.servicesParse, !parse.rejected.isEmpty || !parse.ignored.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.s4) {
                    if !parse.rejected.isEmpty {
                        Text("Refused (the service does not start): " + parse.rejected.map { "\($0.path): \($0.reason)" }.joined(separator: "; "))
                            .font(.ds(.meta)).foregroundStyle(DSColor.dangerText).fixedSize(horizontal: false, vertical: true)
                    }
                    if !parse.ignored.isEmpty {
                        Text("Ignored: " + parse.ignored.map { "\($0.path) (\($0.reason))" }.joined(separator: "; "))
                            .font(.ds(.meta)).foregroundStyle(DSColor.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, DS.Space.s12).padding(.vertical, DS.Space.s8)
                .overlay(alignment: .top) { Rectangle().fill(DSColor.border).frame(height: 1).padding(.leading, DS.Space.s12) }
            }
            if case .file = environment.servicesSource {
                SettingsActionsRow {
                    Spacer()
                    Button("Reload") { model.service.reloadServices(environment.directory) }.buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                        .help("Reads the compose file again and starts what changed")
                }
            } else {
                VStack(alignment: .trailing, spacing: DS.Space.s8) {
                    TextEditor(text: $model.servicesYAML).font(.ds(.codeSmall)).scrollContentBackground(.hidden)
                        .frame(height: 84).padding(DS.Space.s4)
                        .background(DSColor.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(DSColor.borderStrong, lineWidth: 1))
                        .accessibilityLabel("Services, in the compose file format")
                    Button("Save Services") { Task { await model.saveServices() } }.buttonStyle(DSButtonStyle(.primary, size: .small))
                }
                .padding(DS.Space.s12)
                .overlay(alignment: .top) { Rectangle().fill(DSColor.border).frame(height: 1).padding(.leading, DS.Space.s12) }
            }
        }
        .task(id: environment.directory) { await model.service.refreshServices(environment.directory) }
    }
}

struct ServiceRowView: View {
    @ObservedObject var model: EnvironmentSettingsModel
    let environment: ProjectEnvironment
    let service: ServiceState
    let divided: Bool

    var body: some View {
        let detail = ([service.image.isEmpty ? nil : service.image,
                       service.ports.isEmpty ? nil : service.ports.map { "\(service.name):\($0)" }.joined(separator: ", "),
                       service.outdated ? "definition changed: Restart applies it" : nil, service.message]
            .compactMap { $0 }).joined(separator: " · ")
        SettingsRow(service.name, detail: detail, divided: divided) {
            HStack(spacing: DS.Space.s2) {
                DSPillView(service.label, tone: service.tone.ds, symbolName: service.symbolName).padding(.trailing, DS.Space.s4)
                if service.phase == .running {
                    ForEach(service.ports.prefix(2), id: \.self) { port in
                        let forwarded = environment.serviceForwards.contains { $0.service == service.name && $0.port == port }
                        Button(forwarded ? "Open :\(port) Again" : "Open :\(port)") { model.openServicePort(service.name, port: port) }
                            .buttonStyle(DSButtonStyle(.outline, size: .small))
                            .help("Forwards the port to this Mac's loopback only and opens it in the built-in browser")
                    }
                    Button("Terminal") { model.openServiceTerminal(service.name, environment.directory) }
                        .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true)).help("A shell inside the service's container")
                }
                if service.containerID != nil {
                    Button("Logs") { Task { await model.showServiceLogs(service.name) } }.buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                }
                if service.phase != .refused {
                    Button(service.phase == .running ? "Restart" : "Start") { Task { await model.restartService(service.name) } }
                        .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                    Button("Delete Data…") { Task { await model.confirmDeleteServiceData(service.name) } }
                        .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                        .help("Removes the service's container and its data volumes after listing them. Cannot be undone.")
                }
            }
        }
    }
}

/// Settings ▸ Containers ▸ Caches: every cache volume with its scope and size, and Clean.
struct CacheVolumesView: View {
    let caches: [CacheVolume]
    let projects: [(directory: String, name: String)]
    let clean: (CacheVolume) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if caches.isEmpty {
                SettingsRow("No caches yet", detail: "Turn one on in Project Settings ▸ Environment ▸ Caches.", divided: false) { EmptyView() }
            }
            ForEach(Array(caches.enumerated()), id: \.element.id) { index, cache in
                let scope = cache.shared ? "Shared across projects"
                    : cache.projectDirectory.map { directory in projects.first { $0.directory == directory }?.name ?? (directory as NSString).lastPathComponent } ?? "Project"
                SettingsRow("\(cache.cache?.title ?? cache.name) · \(scope)",
                            detail: [cache.name, cache.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "size unknown",
                                     cache.users.map { $0 == 0 ? "unused" : "used by \($0) container\($0 == 1 ? "" : "s")" }].compactMap { $0 }.joined(separator: " · "),
                            divided: index > 0) {
                    HStack(spacing: DS.Space.s4) {
                        if cache.shared { DSPillView("Shared", tone: .info, symbolName: "person.2") }
                        Button("Clean…") { clean(cache) }.buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                            .help("Deletes the cache's contents (downloaded again when needed)")
                    }
                }
            }
        }
    }
}

/// Project Settings ▸ Environment ▸ Caches: one row per package manager (on/off, shared), "from image" when the image
/// declares it, and Save.
struct ProjectCachesView: View {
    @ObservedObject var model: EnvironmentSettingsModel
    let environment: ProjectEnvironment

    var body: some View {
        let declared = environment.record.imageCaches ?? [:]
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(PackageCache.allCases.enumerated()), id: \.element) { index, cache in
                let choice = model.cacheChoices[cache] ?? CacheSelection(cache: cache, enabled: false)
                SettingsRow(cache.title, detail: (declared[cache] ?? cache.defaultPath) + (declared[cache] != nil ? " · declared by the image" : ""),
                            divided: index > 0) {
                    HStack(spacing: DS.Space.s8) {
                        Toggle("Shared", isOn: Binding(get: { choice.shared }, set: { model.cacheChoices[cache]?.shared = $0 }))
                            .toggleStyle(DSToggleStyle(.checkbox)).disabled(!choice.enabled)
                            .help("One volume for every project that also shares this cache")
                        Toggle("", isOn: Binding(get: { choice.enabled }, set: { value in
                            model.cacheChoices[cache, default: CacheSelection(cache: cache, enabled: false)].enabled = value
                        }))
                        .toggleStyle(DSToggleStyle(.switch)).labelsHidden().accessibilityLabel("\(cache.title) cache")
                    }
                }
            }
            SettingsActionsRow {
                Spacer()
                Button("Save Caches") { Task { await model.saveCaches() } }.buttonStyle(DSButtonStyle(.primary, size: .small))
            }
        }
    }
}

/// The project's MCP servers: name, command (mono), where it runs and opencode's status (glyph + word), enable toggle and
/// Remove (applied at once, with Undo); then an add row.
struct MCPServersListView: View {
    @ObservedObject var model: EnvironmentSettingsModel
    let environment: ProjectEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if environment.settings.mcpServers.isEmpty {
                SettingsRow("No MCP servers", detail: "Add one below: its command runs inside the container.", divided: false) { EmptyView() }
            }
            ForEach(Array(environment.settings.mcpServers.enumerated()), id: \.element.id) { index, server in
                let status = environment.mcpStatus.first { $0.name == server.name }
                SettingsRow(server.name, detail: "\(server.commandLine) · in container" + (status?.error.map { " · \($0)" } ?? ""), divided: index > 0) {
                    HStack(spacing: DS.Space.s4) {
                        MCPStatusPill(enabled: server.enabled, status: status?.status)
                        Toggle("", isOn: Binding(get: { server.enabled }, set: { value in Task { await model.setMCPServer(server, enabled: value) } }))
                            .toggleStyle(DSToggleStyle(.switch)).labelsHidden().accessibilityLabel("Enable \(server.name)")
                        Button("Remove") { Task { await model.removeMCPServer(server) } }.buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                    }
                }
            }
            if let removed = model.removedMCP {
                SettingsRow("Removed “\(removed.name)”", divided: true) {
                    Button("Undo") { Task { await model.undoRemoveMCPServer() } }.buttonStyle(DSButtonStyle(.outline, size: .small))
                }
            }
            SettingsFieldRow {
                TextField("", text: $model.newMCPName, prompt: Text("name")).textFieldStyle(DSTextFieldStyle()).frame(width: 110)
                    .accessibilityLabel("MCP server name")
                TextField("", text: $model.newMCPCommand, prompt: Text("node tools/mcp.js")).textFieldStyle(DSTextFieldStyle()).font(.ds(.codeSmall))
                    .accessibilityLabel("MCP server command, run in the container")
                Button("Add") { Task { await model.addMCPServer() } }.buttonStyle(DSButtonStyle(.outline, size: .small))
                    .disabled(model.newMCPName.isEmpty || model.newMCPCommand.isEmpty)
            }
        }
        .task(id: environment.directory) { await model.service.refreshMCPStatus(environment.directory) }
    }
}

/// An MCP server's state as glyph + word (never colour only).
struct MCPStatusPill: View {
    let enabled: Bool
    let status: String?

    var body: some View {
        let (word, tone, symbol): (String, DS.Tone, String) = switch (enabled, status) {
        case (false, _): ("Off", .neutral, "pause.circle")
        case (true, "connected"): ("Connected", .success, "checkmark.circle")
        case (true, "pending"): ("Starting", .info, "arrow.triangle.2.circlepath")
        case (true, "failed"): ("Failed", .danger, "xmark.octagon")
        case (true, "needs_auth"): ("Sign-in needed", .warning, "exclamationmark.triangle")
        default: ("Starts with container", .neutral, "shippingbox")
        }
        DSPillView(word, tone: tone, symbolName: symbol)
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
