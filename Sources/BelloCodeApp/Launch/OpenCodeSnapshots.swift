import AppKit
import DesignSystem
import Engine
import OpenCodeKit
import SwiftUI

/// `--snapshot opencode` (docs/features/opencode-config.md): Settings ▸ opencode in light and dark, on fixed data
/// (the mock server has no configuration endpoints): `untrusted` (global agents, commands and skills; the CLI tool not
/// installed), `trusted` (project items, a skipped file, the CLI installed), `problems` (a broken opencode.json, the
/// plugin blocked by a policy, a stale list), and `window` (the pane inside the Settings window).
extension SnapshotRunner {
    func runOpenCode() async -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("FAIL cannot create \(directory.path): \(error)")
            return false
        }
        let engine = runtime.engine
        await engine.start()
        _ = await waitUntil(timeout: .seconds(20)) { engine.root.connection == .live && !engine.root.projects.isEmpty }
        let project = engine.root.projects.first?.directory ?? "/Users/you/Repos/app"
        let temporary = FileManager.default.temporaryDirectory.appending(path: "bellocode-oc-snap-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let directories = OpenCodeDirectories(dataRoot: temporary.appending(path: "Application Support/BelloCode/opencode", directoryHint: .isDirectory))
        let service = OpenCodeConfigService(
            store: engine.store, directories: directories, runningPolicy: .bellocode,
            client: { throw EngineError.offline }, restartServer: nil)
        let settings = AppSettings(defaults: nil)
        let helper = temporary.appending(path: "BelloCode.app/Contents/Helpers/bellocode-opencode")
        try? FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        var installer = CommandLineToolInstaller(helper: helper, candidates: [temporary.appending(path: "home/.local/bin", directoryHint: .isDirectory)])
        let actions = OpenCodeSettingsActions(confirm: { _, _, _ in false }, open: { _ in }, reveal: { _ in }, report: { _ in })

        let global: [OpenCodeItem] = [
            OpenCodeItem(kind: .agent, name: "reviewer", detail: "Reviews a diff for correctness and tests", source: .global),
            OpenCodeItem(kind: .agent, name: "docs-writer", detail: "Writes and updates feature notes", source: .global),
        ]
        let commands: [OpenCodeItem] = [OpenCodeItem(kind: .command, name: "release-notes", detail: "Draft release notes from merged MRs", source: .global)]
        let skills: [OpenCodeItem] = [OpenCodeItem(kind: .skill, name: "company-style", detail: "House style for Swift and docs", source: .global)]
        let projectAgents = [OpenCodeItem(kind: .agent, name: "migrations", detail: "Writes and checks SQLite migrations", source: .project)]
        let projectCommands = [OpenCodeItem(kind: .command, name: "ship", detail: "Run checks, then open a merge request", source: .project)]
        let projectSkills = [
            OpenCodeItem(kind: .skill, name: "deploy-staging", detail: "Deploy this service to staging", source: .project),
            OpenCodeItem(kind: .skill, name: "lint", detail: "Project lint rules", source: .project),
        ]
        var written: [String] = []
        func shoot(_ state: String, _ configure: (OpenCodeSettingsModel) -> Void) async {
            let model = OpenCodeSettingsModel(service: service, settings: settings, engine: engine, actions: actions, installer: installer)
            model.selectedProject = project
            configure(model)
            written += await renderHosted(
                OpenCodeSettingsView(model: model).padding(DS.Space.s24).background(SwiftUI.Color.ds.canvas).environment(\.openCodeSnapshot, true),
                state: state, title: "opencode")
        }

        service.presentForSnapshots(
            inventory: OpenCodeInventory(directory: project, agents: global, commands: commands, skills: skills, userPlugins: []),
            configProblem: nil)
        await shoot("untrusted") { _ in }

        _ = try? installer.install()
        service.presentForSnapshots(
            inventory: OpenCodeInventory(
                directory: project, agents: global + projectAgents, commands: commands + projectCommands, skills: skills + projectSkills,
                userPlugins: ["notify-on-idle.ts"], skipped: [".opencode/agents/strict.md: unsupported fields (permission): use the global agents folder or native mode"]),
            configProblem: nil, trusted: [project])
        await shoot("trusted") { _ in }

        installer = CommandLineToolInstaller(helper: helper, candidates: installer.candidates)
        service.presentForSnapshots(
            inventory: OpenCodeInventory(
                directory: project, agents: global, commands: commands, skills: skills,
                pluginProblem: "BelloCode's opencode plugin is off: opencode.json denies plugins (\"plugin.use\": \"*\"). Orchestration tools, the container guard hook and the environment contract are unavailable until this is fixed."),
            configProblem: "opencode.json, line 7, column 3: Badly formed object around line 7, column 3.",
            refreshError: "offline")
        await shoot("problems") { _ in }

        // The pane inside the real Settings window (top of the pane, as a person first sees it).
        service.presentForSnapshots(
            inventory: OpenCodeInventory(directory: project, agents: global, commands: commands, skills: skills), configProblem: nil)
        let controller = SettingsWindowController(settings: settings, auth: nil, importSource: nil, engine: engine)
        controller.show(pane: "opencode")
        if let model = OpenCodeSettingsModel.last {
            model.actions = actions
        }
        try? await Task.sleep(for: .milliseconds(400))
        if only.isEmpty || only.contains("window") { written += await renderWindow(controller.window, state: "window") }
        controller.close()

        for path in written { log("wrote \(path)") }
        log(written.isEmpty ? "FAIL nothing written" : "PASS \(written.count) images")
        return !written.isEmpty
    }
}

private struct OpenCodeSnapshotKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True while a snapshot renders the pane (its `.task` refresh is skipped so fixed data stays).
    var openCodeSnapshot: Bool {
        get { self[OpenCodeSnapshotKey.self] }
        set { self[OpenCodeSnapshotKey.self] = newValue }
    }
}
