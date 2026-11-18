import BelloCore
import ContainerKit
import Foundation
import OpenCodeKit

/// Project MCP servers (docs/features/containers.md, "MCP servers"). Each enabled server in a project's Environment
/// setting is registered with opencode for the project's location, with its command routed through
/// `bellocode-exec --stdio` (`MCPRouting`): the program runs in the project's container. Registration happens when the
/// project's container is ready (not at launch for every project: a connected server keeps an exec open), again after
/// the server reconnects, and whenever the setting changes; servers removed from the setting are removed.
///
/// Threading: `@MainActor` (part of `EnvironmentService`); server calls run in the service's tasks.
extension EnvironmentService {
    /// The config BelloCode sends for each enabled server of a project (name → local-server config).
    func desiredMCPConfigs(_ model: ProjectEnvironment) -> [String: JSONValue] {
        guard let helper = isolationContext?.helperPath ?? configuration?.helperURL.path else { return [:] }
        var configs: [String: JSONValue] = [:]
        for server in model.settings.mcpServers where server.enabled && server.validationErrors().isEmpty {
            configs[server.name] = MCPRouting.projectServerConfig(
                helper: helper, project: model.directory, argv: server.command, environment: server.environment)
        }
        return configs
    }

    /// Registers the project's servers now (the container is ready, the setting changed, or the server reconnected) and
    /// the global servers when the project is in use (`GlobalMCPService`). Idempotent: a server already registered with
    /// the same config and connected is left alone. Project servers are added only while the project's container is
    /// ready (those already registered stay meanwhile).
    func syncMCPServers(_ model: ProjectEnvironment) {
        guard isEnabled, let context = isolationContext else { return }
        let registered = registeredMCP[model.directory] ?? [:]
        var projectConfigs = desiredMCPConfigs(model)
        if model.phase != .ready {
            projectConfigs = projectConfigs.filter { registered[$0.key] == $0.value }
        }
        let globals = globalRegistrations(model)
        guard !projectConfigs.isEmpty || !globals.isEmpty || !registered.isEmpty else { return }
        let directory = model.directory
        let vault = configuration?.mcpVault
        tasks.set("mcp-\(model.projectKey)", Task { [weak self] in
            let (globalConfigs, missing) = await Self.resolveOffMain(globals, vault: vault)
            var desired = globalConfigs
            desired.merge(projectConfigs) { _, project in project }
            if let self, !missing.isEmpty {
                for (id, problem) in missing where self.globalMCPStates[id]?.problem != problem { self.globalMCPStates[id]?.problem = problem }
            }
            guard let client = try? await context.client() else { return }
            let statuses = (try? await client.mcpServers(directory: directory)) ?? []
            var current = registered
            for name in registered.keys where desired[name] == nil {
                try? await client.removeMCPServer(name, directory: directory)
                current[name] = nil
            }
            for (name, config) in desired.sorted(by: { $0.key < $1.key }) {
                let status = statuses.first { $0.name == name }?.status
                if current[name] == config, status == "connected" || status == "pending" { continue }
                do {
                    try await client.addMCPServer(name, config: config, directory: directory)
                    current[name] = config
                } catch {
                    Self.log.error("could not register a project MCP server")
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.registeredMCP[directory] = current
            model.mcpStatus = (try? await client.mcpServers(directory: directory)) ?? statuses
            self.refreshGlobalStates()
        })
    }

    @concurrent
    nonisolated static func resolveOffMain(_ registrations: [GlobalRegistration], vault: (any SecretVault)?) async
        -> (configs: [String: JSONValue], missing: [String: String]) {
        resolve(registrations, vault: vault)
    }

    /// The server (re)connected: runtime registrations are gone. Re-register for projects whose container is ready.
    public func serverConnected() {
        registeredMCP.removeAll()
        for model in models.values where model.phase == .ready || projectsInUse.contains(model.directory) { syncMCPServers(model) }
    }

    /// Reads the project's MCP servers and their status (Environment pane).
    public func refreshMCPStatus(_ directory: String) async {
        let model = environment(for: directory)
        guard let context = isolationContext, let client = try? await context.client() else { return }
        if let statuses = try? await client.mcpServers(directory: model.directory) { model.mcpStatus = statuses }
        refreshGlobalStates()
    }

    /// Names BelloCode registered for a location (the isolation self-check accounts for them).
    func registeredMCPNames(_ directory: String) -> Set<String> {
        Set((registeredMCP[environment(for: directory).directory] ?? [:]).keys)
    }
}
