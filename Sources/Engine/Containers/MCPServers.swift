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
    /// ready (those already registered stay meanwhile). One sync per location at a time: a request while one runs is
    /// coalesced into one more pass after it (never cancelled half-way, which would forget what it registered).
    func syncMCPServers(_ model: ProjectEnvironment) {
        guard isEnabled, let context = isolationContext else { return }
        let directory = model.directory
        if mcpSyncRunning.contains(directory) {
            mcpSyncPending.insert(directory)
            return
        }
        let registered = registeredMCP[directory] ?? [:]
        var projectConfigs = desiredMCPConfigs(model)
        if model.phase != .ready {
            projectConfigs = projectConfigs.filter { registered[$0.key] == $0.value }
        }
        let globals = globalRegistrations(model)
        guard !projectConfigs.isEmpty || !globals.isEmpty || !registered.isEmpty || !(mcpEverRegistered[directory] ?? []).isEmpty else { return }
        let vault = configuration?.mcpVault
        mcpSyncRunning.insert(directory)
        tasks.set("mcp-\(model.projectKey)", Task { [weak self] in
            await self?.performMCPSync(model, context: context, projectConfigs: projectConfigs, globals: globals, vault: vault)
            guard let self else { return }
            self.mcpSyncRunning.remove(directory)
            if self.mcpSyncPending.remove(directory) != nil, !Task.isCancelled { self.syncMCPServers(model) }
        })
    }

    private func performMCPSync(_ model: ProjectEnvironment, context: IsolationCheck.Context, projectConfigs: [String: JSONValue],
                                globals: [GlobalRegistration], vault: (any SecretVault)?) async {
        let directory = model.directory
        let (globalConfigs, missing) = await Self.resolveOffMain(globals, vault: vault)
        var desired = globalConfigs
        desired.merge(projectConfigs) { _, project in project }
        for (id, problem) in missing where globalMCPStates[id]?.problem != problem { globalMCPStates[id]?.problem = problem }
        // An image server's helper reads its definition from the helper configuration: it must be on disk first.
        if globals.contains(where: { $0.kind == .image }) { await writeConfigNow() }
        guard let client = try? await context.client() else {
            if !model.mcpPendingRemoval.isEmpty { scheduleMCPRemovalRetry(model) }
            return
        }
        let listed = try? await client.mcpServers(directory: directory)
        let statuses = listed ?? []
        let registered = registeredMCP[directory] ?? [:]
        var endedConnection = false
        // What BelloCode registered here that opencode still lists, or that is still awaiting a confirmed removal, and
        // that is no longer wanted (R30: a failed or unconfirmed removal is never forgotten).
        let ours = (mcpEverRegistered[directory] ?? []).intersection(statuses.map(\.name))
        var removing: Set<String> = []
        for name in Set(registered.keys).union(ours).union(model.mcpPendingRemoval) where desired[name] == nil {
            removing.insert(name)
            try? await client.removeMCPServer(name, directory: directory)
            // Any removal may end an image server's connection: its container is checked for afterwards (cheap).
            endedConnection = true
        }
        // A server wanted again is no longer being removed.
        model.mcpPendingRemoval.subtract(desired.keys)
        if !removing.isEmpty {
            // Done only when opencode's own list no longer has it; until then it stays registered here and pending.
            let after = try? await client.mcpServers(directory: directory)
            for name in removing {
                if let after, !after.contains(where: { $0.name == name }) {
                    registeredMCP[directory]?[name] = nil
                    model.mcpPendingRemoval.remove(name)
                } else {
                    model.mcpPendingRemoval.insert(name)
                }
            }
        }
        if model.mcpPendingRemoval.isEmpty {
            mcpRemovalAttempts[directory] = nil
        } else {
            Self.log.error("an MCP server removal is not confirmed yet; retrying")
            scheduleMCPRemovalRetry(model)
        }
        for (name, config) in desired.sorted(by: { $0.key < $1.key }) {
            let status = statuses.first { $0.name == name }?.status
            if registeredMCP[directory]?[name] == config, status == "connected" || status == "pending" { continue }
            mcpEverRegistered[directory, default: []].insert(name)
            do {
                try await client.addMCPServer(name, config: config, directory: directory)
                registeredMCP[directory, default: [:]][name] = config
            } catch {
                Self.log.error("could not register an MCP server")
            }
        }
        model.mcpStatus = (try? await client.mcpServers(directory: directory)) ?? statuses
        refreshGlobalStates()
        if endedConnection { scheduleMCPLeftoverCleanup() }
    }

    /// Syncs the location again after a backoff while a removal is unconfirmed (R30).
    func scheduleMCPRemovalRetry(_ model: ProjectEnvironment) {
        let directory = model.directory
        let attempt = (mcpRemovalAttempts[directory] ?? 0) + 1
        mcpRemovalAttempts[directory] = attempt
        let delay = mcpRemovalRetryDelay(attempt)
        tasks.set("mcp-removal-retry-\(model.projectKey)", Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.syncMCPServers(model)
        })
    }

    /// opencode ends a removed server's helper, which removes its container; a helper killed outright cannot, so the
    /// connection's container (stopped once its input closed) or that of a server no longer configured is removed here.
    func scheduleMCPLeftoverCleanup() {
        guard runtime?.isReady == true else { return }
        let runtimeRef = activeRuntime
        tasks.set("mcp-leftovers-after-remove", Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            let known = Set(self.imageServerSpecs().map(\.id))
            await runtimeRef.removeMCPLeftovers(knownIDs: known)
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
