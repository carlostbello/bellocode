import AppKit
import BelloCore
import ContainerKit
import DesignSystem
import Engine
import Foundation
import SwiftUI

/// Containers 2 states of `--snapshot containers` (docs/features/containers.md), on the scripted runtime with the
/// administrator's policy "registry.acme.internal only" (AppRuntime): the Services and MCP sections of the Environment
/// pane, the Containers view with service containers and the policy, the isolation report with a routed MCP server,
/// cache settings, and a thread in a project whose image the policy refuses (banner above the composer).
extension SnapshotRunner {
    func runContainers2(engine: Engine, project: String, driver: ShellDriver, workspace: WorkspaceController,
                        fake: SnapshotWorkspaceRuntime) async -> [String] {
        func wanted(_ state: String) -> Bool { only.isEmpty || only.contains(state) }
        var written: [String] = []
        let environments = engine.environments
        fake.projectDirectory.withLock { $0 = project }
        let compose = URL(filePath: project).appending(path: "compose.yaml")
        let composeExisted = FileManager.default.fileExists(atPath: compose.path)
        if !composeExisted { try? Data(Self.compose.utf8).write(to: compose) }
        defer { if !composeExisted { try? FileManager.default.removeItem(at: compose) } }

        var settings = environments.environment(for: project).settings
        settings.mcpServers = [MCPServerSetting(name: "echo", command: ["node", "tools/echo-mcp.js"]),
                               MCPServerSetting(name: "docs", command: ["python3", "-m", "docs_mcp", "--stdio"], enabled: false)]
        settings.caches = [CacheSelection(cache: .pnpm, shared: true), CacheSelection(cache: .pip)]
        await environments.update(project, settings: settings)
        environments.activate(project)
        let environment = environments.environment(for: project)
        _ = await waitUntil(timeout: .seconds(5)) { environment.phase == .ready }
        await environments.refreshServices(project)
        _ = await waitUntil(timeout: .seconds(5)) { environment.services.contains { $0.health == "healthy" } }

        let model = EnvironmentSettingsModel(engine: engine, directory: project)
        model.load()
        if wanted("services") {
            written += await renderComponent(state: "services") {
                SettingsPaneBody {
                    SettingsGroup("Services", footer: ServicesSectionView.footer(environment)) {
                        ServicesSectionView(model: model, environment: environment)
                    }
                    SettingsGroup("MCP servers", footer: "Local (stdio) MCP servers of this project run in its container through bellocode-exec --stdio; only their input and output cross to this Mac. Servers configured for all projects are refused.") {
                        MCPServersListView(model: model, environment: environment)
                    }
                }
            }
        }
        if wanted("containers-view") {
            let containers = ContainersSettingsModel(engine: engine)
            await containers.reload()
            written += await renderComponent(state: "containers-view") {
                SettingsPaneBody {
                    SettingsGroup("Image policy", footer: "Set by your organisation (configuration profile). Images outside it are refused for the workspace and every service.") {
                        ImagePolicySettingsView(model: containers)
                    }
                    SettingsGroup("Containers", footer: "Prune removes stopped BelloCode containers, unused BelloCode volumes of projects no longer in BelloCode, unattached BelloCode networks and unused images BelloCode pulled, after listing them. Nothing else is touched.") {
                        ManagedContainersListView(model: containers, service: environments, confirmRemove: { _ in false })
                    }
                }
            }
        }
        if wanted("caches") {
            let containers = ContainersSettingsModel(engine: engine)
            await containers.reload()
            written += await renderComponent(state: "caches") {
                SettingsPaneBody {
                    SettingsGroup("Caches", footer: "Named volumes for package-manager caches, kept when the container is rebuilt. “Shared” uses one volume for every project that also shares it; otherwise the cache is this project's own.") {
                        ProjectCachesView(model: model, environment: environment)
                    }
                    SettingsGroup("Caches on this Mac", footer: "Settings ▸ Containers: every cache volume, its scope and size.") {
                        CacheVolumesView(caches: containers.caches, projects: engine.root.projects.map { ($0.directory, $0.name) }) { _ in }
                    }
                }
            }
        }
        if wanted("isolation-mcp") {
            // The checks and their wording as the live smoke run reports them (`make smoke`), for this project.
            let report = IsolationReport(date: Date(), directory: project, full: true, checks: [
                .init("Host git", .confined("43 hostile settings and hooks; nothing ran (status, diff, add, commit, log, fetch, opencode's git)")),
                .init("Configured shell", .container("every shell setting is bellocode-exec")),
                .init("Formatters", .off("off")),
                .init("Language servers", .off("off")),
                .init("Local MCP servers", .container("routed into the project's container (bellocode-exec --stdio): echo; refused (configured for all projects): team-tools")),
                .init("Worktree start commands", .off("none set (setup scripts run in the container)")),
                .init("Plugin guard", .container("shell.create.before forces bellocode-exec")),
                .init("Shell tool (/api/shell)", .container("shell job: container Linux")),
                .init("PTY ($SHELL)", .container("PTY ($SHELL): container Linux")),
                .init("MCP server (stdio)", .container("MCP server (stdio): container Linux")),
                .init("Command template (!`…`)", .container("command template: container Linux")),
                .init("Automations", .off("opencode automations are disabled in this configuration")),
                .init("Terminal (persistent PTY)", .container("terminal: container Linux")),
            ])
            written += await renderComponent(state: "isolation-mcp") {
                SettingsPaneBody {
                    SettingsGroup("Isolation") { IsolationReportView(report: report, running: false) {} }
                }
            }
        }
        if wanted("policy-refused"), let item = engine.root.projects.first(where: { $0.directory == project }),
           let thread = workspace.projectModel(item)?.sessionIDs.first {
            // The project's image is outside the administrator's policy: refused before anything is pulled or run.
            var refused = environments.environment(for: project).settings
            refused.image = "node:22-bookworm-slim"
            await environments.update(project, settings: refused)
            _ = await driver.select(.thread(thread))
            _ = await waitUntil(timeout: .seconds(5)) { environments.environment(for: project).notice != nil }
            driver.settle(10)
            try? await Task.sleep(for: .milliseconds(300))
            driver.settle(6)
            written += await render(driver, state: "policy-refused")
            await environments.update(project, settings: settings)
            environments.activate(project)
            _ = await waitUntil(timeout: .seconds(5)) { environments.environment(for: project).phase == .ready }
        }
        settings.mcpServers = []
        settings.caches = []
        await environments.update(project, settings: settings)
        return written
    }

    /// Renders a SwiftUI section on the settings canvas (520 pt column), light and dark.
    func renderComponent<Content: View>(state: String, @ViewBuilder _ content: () -> Content) async -> [String] {
        let host = NSHostingView(rootView: content().padding(DS.Space.s20).background(SwiftUI.Color(nsColor: DS.Color.canvas)))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 560, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.backgroundColor = DS.Color.canvas
        host.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: max(560, host.fittingSize.width), height: host.fittingSize.height))
        window.orderFront(nil)
        window.makeFirstResponder(nil)
        try? await Task.sleep(for: .milliseconds(300))
        defer { window.orderOut(nil) }
        return await renderWindow(window, state: state)
    }

    static let compose = """
        services:
          db:
            image: registry.acme.internal/library/postgres:16
            ports: ["5432"]
            environment: {POSTGRES_PASSWORD: dev}
            healthcheck:
              test: ["CMD-SHELL", "pg_isready -U postgres"]
              interval: 2s
              retries: 15
            volumes: [pg-data:/var/lib/postgresql/data]
          cache:
            image: registry.acme.internal/library/redis:7
            ports: ["6379"]
          worker:
            image: registry.acme.internal/dev/worker:2026.11
            command: node worker.js
            restart: unless-stopped
            depends_on:
              db:
                condition: service_healthy
          legacy-api:
            build: ./legacy
        volumes:
          pg-data:
        """
}
