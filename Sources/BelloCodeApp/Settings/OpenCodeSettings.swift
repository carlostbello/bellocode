import AppKit
import BelloCore
import DesignSystem
import Engine
import OpenCodeKit
import SwiftUI

// Settings ▸ opencode (docs/features/opencode-config.md): BelloCode's isolated opencode configuration folder, what the
// server loads (with its source), per-project trust of repository configuration, the server-wide repository-config
// policy, reload and restart, and the `bellocode-opencode` command-line tool.

// MARK: - Command-line tool

/// Links `Contents/Helpers/bellocode-opencode` into a folder on PATH. Idempotent; only ever removes or replaces a link
/// that points at a BelloCode bundle's helper, never a file or someone else's link.
struct CommandLineToolInstaller: Sendable {
    static let name = "bellocode-opencode"
    /// The bundled helper (nil in builds without one, such as `swift run`).
    var helper: URL?
    /// `~/.local/bin` first (no administrator rights needed), then `/usr/local/bin` when it is writable.
    var candidates: [URL]

    enum Status: Equatable {
        case unavailable
        case notInstalled
        case installed(URL)
        /// Something else is at the path (a file, or a link to another program).
        case conflict(URL, String)
    }

    static func live(bundle: Bundle = .main) -> CommandLineToolInstaller {
        let helper = bundle.bundleURL.appending(path: "Contents/Helpers/\(name)")
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return CommandLineToolInstaller(
            helper: FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil,
            candidates: [home.appending(path: ".local/bin", directoryHint: .isDirectory), URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)])
    }

    /// A link to any BelloCode bundle's helper (an older copy of the app counts as ours).
    static func isOurs(_ destination: String) -> Bool {
        destination.hasSuffix(".app/Contents/Helpers/\(name)")
    }

    func status() -> Status {
        guard let helper else { return .unavailable }
        var conflict: Status?
        for folder in candidates {
            let link = folder.appending(path: Self.name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: link.path) else { continue }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink,
               let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            {
                if destination == helper.path {
                    // An earlier folder's file of the same name comes first and hides this link (N33).
                    if case .conflict(let earlier, let why) = conflict {
                        return .conflict(earlier, "\(why), and it hides BelloCode's link in \(folder.path)")
                    }
                    return .installed(link)
                }
                if Self.isOurs(destination) { conflict = conflict ?? .conflict(link, "links to another copy of BelloCode (\(destination))") }
                else { conflict = conflict ?? .conflict(link, "links to \(destination)") }
            } else {
                conflict = conflict ?? .conflict(link, "is a file BelloCode did not create")
            }
        }
        return conflict ?? .notInstalled
    }

    /// The folder `install()` uses: the first candidate that is writable, or missing with a writable nearest existing
    /// parent (it is created on install).
    func targetFolder() -> URL? {
        let fileManager = FileManager.default
        for folder in candidates {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue, fileManager.isWritableFile(atPath: folder.path) { return folder }
                continue
            }
            var parent = folder.deletingLastPathComponent()
            while !fileManager.fileExists(atPath: parent.path), parent.path != "/" { parent = parent.deletingLastPathComponent() }
            if fileManager.isWritableFile(atPath: parent.path) { return folder }
        }
        return nil
    }

    enum InstallError: Error, Equatable, CustomStringConvertible {
        case unavailable, noFolder, occupied(String)
        var description: String {
            switch self {
            case .unavailable: "This build has no bundled \(CommandLineToolInstaller.name)."
            case .noFolder: "No writable folder for the link (~/.local/bin could not be created)."
            case .occupied(let why): why
            }
        }
    }

    /// Creates (or repairs) the link. Replaces only a link to another BelloCode copy.
    @discardableResult
    func install() throws -> URL {
        guard let helper else { throw InstallError.unavailable }
        guard let folder = targetFolder() else { throw InstallError.noFolder }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appending(path: Self.name)
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            if destination == helper.path { return link }
            guard Self.isOurs(destination) else { throw InstallError.occupied("\(link.path) already links to \(destination); remove it first.") }
            try FileManager.default.removeItem(at: link)
        } else if FileManager.default.fileExists(atPath: link.path) {
            throw InstallError.occupied("\(link.path) is a file BelloCode did not create; remove it first.")
        }
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: helper.path)
        return link
    }

    /// Removes BelloCode's links; returns the paths removed.
    @discardableResult
    func uninstall() throws -> [URL] {
        var removed: [URL] = []
        for folder in candidates {
            let link = folder.appending(path: Self.name)
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), Self.isOurs(destination) else { continue }
            try FileManager.default.removeItem(at: link)
            removed.append(link)
        }
        return removed
    }
}

// MARK: - Model

/// Confirmations and opening, injected so snapshots and tests never present alerts or launch apps.
struct OpenCodeSettingsActions {
    /// Confirms an action that interrupts work: (title, detail, button) → proceed.
    var confirm: @MainActor (String, String, String) -> Bool
    var open: @MainActor (URL) -> Void
    var reveal: @MainActor (URL) -> Void
    var report: @MainActor (String) -> Void

    static let live = OpenCodeSettingsActions(
        confirm: { title, detail, button in
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        },
        open: { url in NSWorkspace.shared.open(url) },
        reveal: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) },
        report: { message in
            let alert = NSAlert()
            alert.messageText = message
            alert.runModal()
        })
}

@MainActor
@Observable
final class OpenCodeSettingsModel {
    let service: OpenCodeConfigService
    let settings: AppSettings
    @ObservationIgnored let engine: Engine?
    @ObservationIgnored var actions: OpenCodeSettingsActions
    @ObservationIgnored var installer: CommandLineToolInstaller
    var selectedProject: String?
    private(set) var toolStatus: CommandLineToolInstaller.Status
    private(set) var message: String?
    /// The pane last built (menu commands act on it when Settings is open).
    static weak var last: OpenCodeSettingsModel?
    /// The front window's project when the pane is opened from the menu.
    static var preferredDirectory: String?

    init(service: OpenCodeConfigService, settings: AppSettings, engine: Engine?, actions: OpenCodeSettingsActions = .live,
         installer: CommandLineToolInstaller = .live())
    {
        self.service = service
        self.settings = settings
        self.engine = engine
        self.actions = actions
        self.installer = installer
        toolStatus = installer.status()
        selectedProject = engine?.root.projects.first?.directory
    }

    var projects: [(id: String, title: String)] {
        (engine?.root.projects ?? []).map { (id: $0.directory, title: $0.name) }
    }

    var folderPath: String { service.folder.map { ($0.url.path as NSString).abbreviatingWithTildeInPath } ?? "" }

    func refresh() async {
        toolStatus = installer.status()
        await service.refresh(directory: selectedProject)
    }

    func select(_ directory: String?) {
        selectedProject = directory
        Task { await service.refresh(directory: directory) }
    }

    // Files and folders

    func open(_ file: GlobalConfigFolder.File) {
        Task {
            do { actions.open(try await service.ensure(file)) } catch { message = "Could not create \(file.rawValue): \(error.localizedDescription)" }
        }
    }

    func reveal(_ folder: GlobalConfigFolder.Folder? = nil) {
        Task {
            do {
                if let folder { actions.open(try await service.ensure(folder)) }
                else if let url = service.folder?.url {
                    _ = try await service.ensure(.config)
                    actions.reveal(url)
                }
            } catch { message = "Could not create the folder: \(error.localizedDescription)" }
        }
    }

    // Trust

    var isSelectedTrusted: Bool { selectedProject.map { service.isTrusted($0) } ?? false }

    func setTrusted(_ value: Bool) {
        guard let directory = selectedProject else { return }
        Task { message = await service.setTrusted(directory, value) }
    }

    // Reload and restart

    private var interruptions: String {
        let counts = engine?.root.attention.counts ?? AttentionCounts()
        var parts: [String] = []
        if counts.running > 0 { parts.append("\(counts.running) running thread\(counts.running == 1 ? "" : "s")") }
        let blocked = counts.approvals + counts.questions
        if blocked > 0 { parts.append("\(blocked) pending approval\(blocked == 1 ? "" : "s") or question\(blocked == 1 ? "" : "s")") }
        return parts.joined(separator: " and ")
    }

    /// Reloads opencode's configuration. The result shows in the pane; `notify` also gets it (success or failure) for
    /// a menu command run while the pane is not on screen, so the command is never silent.
    func reload(notify: (@MainActor (String) -> Void)? = nil) {
        let counts = engine?.root.attention.counts ?? AttentionCounts()
        if counts.approvals + counts.questions > 0 {
            guard actions.confirm(
                "Reload opencode's configuration?",
                "Pending approvals and questions are cancelled (\(interruptions)). Running threads continue with the new configuration at their next step.",
                "Reload")
            else { return }
        }
        Task {
            let failure = await service.reload(directory: selectedProject)
            message = failure
            notify?(failure ?? "Reloaded opencode's configuration.")
        }
    }

    func restart() {
        if !interruptions.isEmpty {
            guard actions.confirm(
                "Restart the opencode server?", "This interrupts \(interruptions). Interrupted threads can be resumed.", "Restart")
            else { return }
        }
        let policy = settings.repositoryConfigPolicy
        Task { message = await service.restart(policy: policy, directory: selectedProject) }
    }

    /// The server-wide policy: applies at a restart (offered now).
    func setNative(_ native: Bool) {
        let policy: RepositoryConfigPolicy = native ? .native : .bellocode
        guard policy != settings.repositoryConfigPolicy else { return }
        if native {
            guard actions.confirm(
                "Load every repository's opencode configuration?",
                "opencode will load opencode.json, .opencode/ agents, commands, skills and plugins from every project this server opens — not only trusted ones. Repository plugins are code: they run inside opencode on your Mac, outside the container. The opencode server restarts\(interruptions.isEmpty ? "" : " and interrupts \(interruptions)").",
                "Load and Restart")
            else { return }
        } else if !interruptions.isEmpty {
            guard actions.confirm("Stop loading repository configuration?", "The opencode server restarts and interrupts \(interruptions).", "Restart") else { return }
        }
        settings.repositoryConfigPolicy = policy
        Task { message = await service.restart(policy: policy, directory: selectedProject) }
    }

    // Command-line tool

    func installTool() {
        do {
            let link = try installer.install()
            toolStatus = installer.status()
            message = "Installed \(CommandLineToolInstaller.name) at \((link.path as NSString).abbreviatingWithTildeInPath)."
        } catch {
            message = String(describing: error)
        }
    }

    func uninstallTool() {
        do {
            let removed = try installer.uninstall()
            toolStatus = installer.status()
            message = removed.isEmpty ? "No BelloCode link to remove." : "Removed \(removed.map { ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "))."
        } catch {
            message = "Could not remove the link: \(error.localizedDescription)"
        }
    }

    func dismissMessage() { message = nil }

    func refreshToolStatus() { toolStatus = installer.status() }
}

// MARK: - View

struct OpenCodeSettingsView: View {
    @Bindable var model: OpenCodeSettingsModel
    @Environment(\.openCodeSnapshot) private var snapshot
    private var service: OpenCodeConfigService { model.service }

    var body: some View {
        SettingsPaneBody {
            if let message = model.message {
                notice(message, tone: .info, symbol: "info.circle") { model.dismissMessage() }
            }
            folderGroup
            projectGroup
            loadedGroup
            policyGroup
            serverGroup
            toolGroup
        }
        .task { if !snapshot { await model.refresh() } }
    }

    // Global folder

    private var folderGroup: some View {
        SettingsGroup(
            "Global configuration",
            footer: "BelloCode's own opencode folder, separate from ~/.config/opencode. Everything in it applies to every project: opencode.json, AGENTS.md, and the agents, commands, skills and plugins folders. Global plugins are code and run inside opencode on your Mac."
        ) {
            if service.folder == nil {
                SettingsRow("Folder", detail: "Not available: BelloCode is attached to an opencode server it does not manage.", divided: false) { EmptyView() }
            } else {
                SettingsRow("Folder", divided: false) {
                    HStack(spacing: DS.Space.s6) {
                        Text(model.folderPath).font(.ds(.codeSmall)).foregroundStyle(Color.ds.text2).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Reveal in Finder") { model.reveal() }.buttonStyle(DSButtonStyle(.outline, size: .small))
                    }
                }
            }
            if let problem = service.configProblem {
                SettingsRow("opencode.json has a problem", detail: problem) {
                    DSPillView("Not applied", tone: .danger, symbolName: "exclamationmark.triangle.fill")
                }
            }
            if service.folder != nil { folderActions }
        }
    }

    @ViewBuilder
    private var folderActions: some View {
            SettingsActionsRow {
                Button("Open opencode.json") { model.open(.config) }.buttonStyle(DSButtonStyle(.outline, size: .small))
                Button("Open AGENTS.md") { model.open(.instructions) }.buttonStyle(DSButtonStyle(.outline, size: .small))
            }
            SettingsActionsRow {
                Text("Folders").font(.ds(.label)).foregroundStyle(Color.ds.text3)
                ForEach(GlobalConfigFolder.Folder.allCases, id: \.self) { folder in
                    Button(folder.rawValue.capitalized) { model.reveal(folder) }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                        .accessibilityLabel("Open the \(folder.rawValue) folder")
                }
            }
    }

    // Project trust

    private var projectGroup: some View {
        SettingsGroup(
            "Project",
            footer: service.runningPolicy == .native
                ? "Repository configuration loads natively for every project (see below), so this setting has no effect now."
                : "A repository's AGENTS.md is always added to its threads (text only). Trusting loads its .opencode agents, commands and skills and .agents/skills too. Its opencode.json and plugins never load per project: opencode reads that switch once for the whole server (see below)."
        ) {
            if model.projects.isEmpty {
                SettingsRow("No projects yet", detail: "Add a project to choose what it loads.", divided: false) { EmptyView() }
            } else {
                SettingsRow("Project", divided: false) {
                    DSMenuSelect("Project", options: model.projects, selection: Binding(
                        get: { model.selectedProject ?? model.projects.first?.id ?? "" }, set: { model.select($0) }))
                        .frame(width: 220)
                }
                SettingsToggleRow(
                    "Trust this project's opencode config",
                    detail: service.trustProblem ?? (service.trustPending ? "Saved; not applied yet. Applied when opencode reloads or restarts." : "Applies at once, without restarting opencode."),
                    isOn: Binding(get: { model.isSelectedTrusted }, set: { model.setTrusted($0) }))
            }
        }
    }

    // What the server reports

    private var loadedGroup: some View {
        SettingsGroup(loadedTitle, footer: loadedFooter) {
            if let problem = service.inventory?.pluginProblem {
                SettingsRow("BelloCode's plugin is off", detail: problem, divided: false) {
                    DSPillView("Action needed", tone: .danger, symbolName: "exclamationmark.triangle.fill")
                }
            }
            if let inventory = service.inventory {
                section("Agents", inventory.agents.filter { $0.source != .builtIn }, first: inventory.pluginProblem == nil)
                section("Commands", inventory.commands.filter { $0.source != .builtIn }, first: false)
                section("Skills", inventory.skills.filter { $0.source != .builtIn }, first: false)
                if !inventory.userPlugins.isEmpty {
                    SettingsRow("Global plugins", detail: inventory.userPlugins.joined(separator: ", ")) {
                        DSPillView("Runs on your Mac", tone: .warning, symbolName: "exclamationmark.shield")
                    }
                }
                ForEach(inventory.skipped, id: \.self) { skipped in
                    SettingsRow("Skipped", detail: skipped) { DSPillView("Not loaded", tone: .warning, symbolName: "minus.circle") }
                }
            } else if service.refreshing {
                SettingsRow("Loading…", detail: "Asking opencode what it loaded.", divided: false) { ProgressView().controlSize(.small) }
            } else {
                SettingsRow("Not available", detail: service.refreshError ?? "opencode is not running.", divided: false) { EmptyView() }
            }
            SettingsActionsRow {
                Button("Refresh") { Task { await model.refresh() } }.buttonStyle(DSButtonStyle(.outline, size: .small))
                if service.refreshing { ProgressView().controlSize(.small) }
                if service.inventory != nil, let error = service.refreshError {
                    Text("Stale: \(error)").font(.ds(.meta)).foregroundStyle(Color.ds.warningText).lineLimit(1)
                }
            }
        }
    }

    private var loadedTitle: String {
        guard let project = model.selectedProject else { return "Loaded by opencode" }
        let name = model.projects.first { $0.id == project }?.title ?? URL(fileURLWithPath: project).lastPathComponent
        return "Loaded in \(name)"
    }

    private var loadedFooter: String {
        "Built-in agents (build, plan, general…), commands and skills are not listed. Edits to files in the global folder apply after Reload."
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [OpenCodeItem], first: Bool) -> some View {
        SettingsRow(title, detail: items.isEmpty ? "None besides opencode's built-in ones." : nil, divided: !first) {
            Text("\(items.count)").font(.ds(.meta)).monospacedDigit().foregroundStyle(Color.ds.text3)
        }
        ForEach(items) { item in
            HStack(spacing: DS.Space.s8) {
                Text(item.name).font(.ds(.codeSmall)).foregroundStyle(Color.ds.text).lineLimit(1)
                Text(item.detail ?? "").font(.ds(.meta)).foregroundStyle(Color.ds.text3).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: DS.Space.s8)
                sourcePill(item.source)
            }
            .padding(.leading, DS.Space.s24)
            .padding(.trailing, DS.Space.s12)
            .frame(height: 26)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.name), \(item.source.label)\(item.detail.map { ", \($0)" } ?? "")")
        }
    }

    private func sourcePill(_ source: OpenCodeItemSource) -> some View {
        switch source {
        case .global: DSPillView(source.label, tone: .info, symbolName: "globe")
        case .project: DSPillView(source.label, tone: .accent, symbolName: "folder")
        case .bellocode: DSPillView(source.label, tone: .neutral, symbolName: "app.badge")
        case .builtIn: DSPillView(source.label, tone: .neutral, symbolName: "shippingbox")
        case .other: DSPillView(source.label, tone: .warning, symbolName: "puzzlepiece.extension")
        }
    }

    // Server-wide policy

    private var policyGroup: some View {
        SettingsGroup(
            "Repository configuration for all projects",
            footer: "Off (recommended): repository opencode.json and plugins never load; trusted projects get their text configuration through BelloCode. On: opencode loads every repository's opencode.json and .opencode plugins itself, for every project, trusted or not. Repository plugins are code and run inside opencode on your Mac, outside the container. BelloCode's shell, container guard and plugin settings still take precedence over any repository's."
        ) {
            SettingsToggleRow(
                "Load every repository's opencode.json and plugins",
                detail: policyDetail, divided: false,
                isOn: Binding(get: { model.settings.repositoryConfigPolicy == .native }, set: { model.setNative($0) }))
        }
    }

    private var policyDetail: String {
        if model.settings.repositoryConfigPolicy != service.runningPolicy { return "Applies when opencode restarts." }
        return service.runningPolicy == .native ? "On for this server: plugins from any opened repository run on your Mac." : "Restarts opencode when changed."
    }

    // Server

    private var serverGroup: some View {
        SettingsGroup(
            "opencode server",
            footer: "Reload re-reads every configuration file; pending approvals and questions are cancelled, running threads continue at their next step. Restart interrupts running threads."
        ) {
            SettingsActionsRow(divided: false) {
                Button("Reload Configuration") { model.reload() }.buttonStyle(DSButtonStyle(.outline, size: .small))
                Button("Restart Server…") { model.restart() }.buttonStyle(DSButtonStyle(.outline, size: .small))
            }
        }
    }

    // Command-line tool

    private var toolGroup: some View {
        SettingsGroup(
            "Command-line tool",
            footer: "bellocode-opencode runs opencode commands on BelloCode's configuration and credentials, through the running server: bellocode-opencode auth login, auth list, models, mcp list, run. With BelloCode closed only account, model and session commands work. BelloCode's terminals run in Linux containers, where this macOS tool is not available (and the server's password must not reach the agent's container): use Terminal on your Mac."
        ) {
            SettingsRow("Status", detail: toolDetail, divided: false) {
                HStack(spacing: DS.Space.s6) {
                    switch model.toolStatus {
                    case .installed:
                        DSPillView("Installed", tone: .success, symbolName: "checkmark.circle.fill")
                        Button("Uninstall") { model.uninstallTool() }.buttonStyle(DSButtonStyle(.outline, size: .small))
                    case .notInstalled:
                        Button("Install Command Line Tool") { model.installTool() }.buttonStyle(DSButtonStyle(.primary, size: .small))
                    case .conflict:
                        DSPillView("Conflict", tone: .warning, symbolName: "exclamationmark.triangle.fill")
                        Button("Install Command Line Tool") { model.installTool() }.buttonStyle(DSButtonStyle(.outline, size: .small))
                    case .unavailable:
                        DSPillView("Not in this build", tone: .neutral, symbolName: "minus.circle")
                    }
                }
            }
        }
    }

    private var toolDetail: String {
        switch model.toolStatus {
        case .installed(let link): "\((link.path as NSString).abbreviatingWithTildeInPath) → this BelloCode. Make sure its folder is on your PATH."
        case .notInstalled: "Links bellocode-opencode into \(model.installer.targetFolder().map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "~/.local/bin")."
        case .conflict(let link, let why): "\((link.path as NSString).abbreviatingWithTildeInPath) \(why)."
        case .unavailable: "Run BelloCode from its app bundle (make app) to install it."
        }
    }

    private func notice(_ text: String, tone: DS.Tone, symbol: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s8) {
            Image(systemName: symbol).foregroundStyle(Color.ds.text2)
            Text(text).font(.ds(.label)).foregroundStyle(Color.ds.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss", action: dismiss).buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
        }
        .padding(DS.Space.s10)
        .background(Color.ds.raised, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(Color.ds.border, lineWidth: 1))
    }
}
