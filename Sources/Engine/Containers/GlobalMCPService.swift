import BelloCore
import ContainerKit
import Foundation
import OpenCodeKit

/// What BelloCode knows of one global MCP server (Settings ▸ MCP Servers rows).
public struct GlobalMCPState: Sendable, Equatable {
    /// Projects (folder names) where opencode reports it connected, starting, failed (with the error) or needing sign-in.
    public var connected: [String] = []
    public var pending: [String] = []
    public var failed: [String: String] = [:]
    public var needsAuth: [String] = []
    /// Why it cannot run at all (image refused or missing, secret missing, compose refused), with the fix in words.
    public var problem: String?
    /// Image servers: whether the image is on this Mac (nil: not checked yet), and pull progress while pulling.
    public var imagePresent: Bool?
    public var pullFraction: Double?
    public var isPulling = false
    /// Stack servers: each service's state, the loopback port of the forwarded endpoint, active connections.
    public var services: [ServiceState] = []
    public var hostPort: Int?
    public var activeConnections = 0

    public init() {}
}

/// Global MCP servers (docs/features/containers.md, "Global MCP servers"): stored as an app preference, secrets in the
/// Keychain, registered with opencode for every project the person uses (a project can opt out of all or some).
///
/// Registration is per location, like project servers, and happens when a thread of the project is shown
/// (`projectInUse`), when the project's container becomes ready, after the server reconnects and whenever the list or a
/// project's opt-out changes. Image servers of a project whose container was stopped when idle are unregistered (their
/// containers end with the connection) and come back when the project is used again.
///
/// Threading: `@MainActor` (part of `EnvironmentService`); Keychain reads and server calls run in the service's tasks.
extension EnvironmentService {
    // MARK: Loading and saving

    func loadGlobalMCP() async {
        if let saved = try? await store.preference(GlobalMCPList.preferenceKey, as: GlobalMCPList.self) { globalMCP = saved }
        reloadConfigImageServers()
        await refreshCorporateNetwork()
        for server in globalMCP.servers where globalMCPStates[server.id] == nil { globalMCPStates[server.id] = GlobalMCPState() }
    }

    /// Image servers from `docker run` entries of BelloCode's isolated configuration files (the same classification the
    /// server launch used to route them, `MCPRouting.globalLocalServers`).
    func reloadConfigImageServers() {
        guard let directory = configuration?.opencodeConfigDirectory else { return }
        let locals = MCPRouting.globalLocalServers(configDirectory: directory).servers
        configImageServers = locals.values.compactMap { local -> ImageMCPSpec? in
            guard let run = local.image else { return nil }
            return ImageMCPSpec(
                id: MCPRouting.configServerID(local.name), name: local.name, image: run.image, entrypoint: run.entrypoint, args: run.args,
                environment: run.environment, secretNames: run.passthrough,
                network: run.network == "none" ? .none : .bridge, blocked: imageRefusal(run.image))
        }.sorted { $0.id < $1.id }
    }

    /// Replaces the list. `secrets` are new values by Keychain account (from the editor or Import); a secret field with
    /// no new value keeps its stored one. Values of fields that are gone or no longer secret are deleted. Throws when
    /// the Keychain refuses a write (nothing is saved then).
    public func saveGlobalMCP(_ servers: [GlobalMCPServer], secrets: [String: SecretValue] = [:]) async throws {
        let vault = configuration?.mcpVault
        let previous = globalMCP.servers
        let accounts = Set(servers.flatMap { $0.secretEntries.map(\.account) })
        let stale = previous.flatMap { $0.secretEntries.map(\.account) }.filter { !accounts.contains($0) }
        try await VaultIO.run {
            for (account, value) in secrets where accounts.contains(account) {
                try vault?.store(account: account, label: "BelloCode MCP secret", value: value)
            }
            for account in stale { try? vault?.delete(account: account) }
        }
        globalMCP = GlobalMCPList(servers: servers)
        try? await store.setPreference(GlobalMCPList.preferenceKey, globalMCP)
        for server in servers where globalMCPStates[server.id] == nil { globalMCPStates[server.id] = GlobalMCPState() }
        for id in Set(globalMCPStates.keys).subtracting(servers.map(\.id)) { globalMCPStates[id] = nil }
        let changedServers = previous.filter { old in servers.first { $0.id == old.id }.map { $0 != old && $0.enabled == old.enabled } ?? false }
        globalMCPChanged(restarting: Set(changedServers.map(\.name)), changedIDs: Set(changedServers.map(\.id)))
    }

    /// Turns one server on or off.
    public func setGlobalMCP(_ id: String, enabled: Bool) async {
        guard let index = globalMCP.servers.firstIndex(where: { $0.id == id }) else { return }
        var servers = globalMCP.servers
        servers[index].enabled = enabled
        try? await saveGlobalMCP(servers)
    }

    /// What Undo needs to put a removed server back (its secret values, held in memory only).
    public struct RemovedGlobalMCP: Sendable {
        public var server: GlobalMCPServer
        public var index: Int
        var secrets: [String: SecretValue]
    }

    /// Removes a server (its Keychain values too). Undo puts it back with them.
    public func removeGlobalMCP(_ id: String) async -> RemovedGlobalMCP? {
        guard let index = globalMCP.servers.firstIndex(where: { $0.id == id }) else { return nil }
        let server = globalMCP.servers[index]
        let vault = configuration?.mcpVault
        let entries = server.secretEntries.map(\.account)
        let secrets = (try? await VaultIO.run { () -> [String: SecretValue] in
            var values: [String: SecretValue] = [:]
            for account in entries { if let value = try? vault?.read(account: account) { values[account] = value } }
            return values
        }) ?? [:]
        var servers = globalMCP.servers
        servers.remove(at: index)
        try? await saveGlobalMCP(servers)
        return RemovedGlobalMCP(server: server, index: index, secrets: secrets)
    }

    public func undoRemoveGlobalMCP(_ removed: RemovedGlobalMCP) async {
        var servers = globalMCP.servers
        servers.insert(removed.server, at: min(removed.index, servers.count))
        try? await saveGlobalMCP(servers, secrets: removed.secrets)
    }

    /// Whether a secret field has a stored value (the editor shows "Saved in Keychain" without reading it out).
    public func hasGlobalMCPSecret(_ account: String) async -> Bool {
        let vault = configuration?.mcpVault
        return (try? await VaultIO.run { ((try? vault?.read(account: account)) ?? nil)?.isEmpty == false }) ?? false
    }

    // MARK: Projects

    /// A thread of the project is shown: register the global servers there (once; cheap when nothing changed).
    public func projectInUse(_ directory: String) {
        guard isEnabled else { return }
        let model = project(containing: directory) ?? environment(for: directory)
        let wasIdle = idledOut.remove(model.directory) != nil
        guard projectsInUse.insert(model.directory).inserted || wasIdle else { return }
        guard !globalMCP.servers.isEmpty || !configImageServers.isEmpty else { return }
        syncMCPServers(model)
    }

    /// The project's container was stopped when idle: its image servers' connections end.
    func projectIdled(_ model: ProjectEnvironment) {
        idledOut.insert(model.directory)
        if projectsInUse.contains(model.directory) { syncMCPServers(model) }
    }

    /// The list changed: write the helper configuration, re-register everywhere, start or stop stack forwarders, pull
    /// missing images. `restarting` names servers whose definition changed (their connections are replaced).
    func globalMCPChanged(restarting: Set<String> = [], changedIDs: Set<String> = []) {
        reloadConfigImageServers()
        scheduleConfigWrite()
        reconcileStacks(changed: changedIDs)
        checkGlobalImages()
        for name in restarting {
            for directory in registeredMCP.keys { registeredMCP[directory]?[name] = nil }
        }
        for model in models.values where projectsInUse.contains(model.directory) || model.phase == .ready { syncMCPServers(model) }
    }

    /// Whether the project uses global servers at all, and which it turned off (Project Settings ▸ Environment).
    func globalServers(for model: ProjectEnvironment) -> [GlobalMCPServer] {
        guard model.settings.useGlobalMCP else { return [] }
        let projectNames = Set(model.settings.mcpServers.map(\.name))
        return globalMCP.servers.filter {
            $0.enabled && $0.validationErrors().isEmpty && !model.settings.globalMCPOptOut.contains($0.id) && !projectNames.contains($0.name)
        }
    }

    /// A global server's registration before secret values are read: the config with the Keychain accounts to fill.
    struct GlobalRegistration: Sendable {
        var name: String
        var serverID: String
        var kind: GlobalMCPServer.Kind
        var url: String?
        var plainHeaders: [String: String] = [:]
        /// header or variable name → Keychain account.
        var secretAccounts: [String: String] = [:]
        var directory: String
        var helper: String
    }

    /// Registrations the project should have now (resolved to configs in `resolve`, off the main actor).
    func globalRegistrations(_ model: ProjectEnvironment) -> [GlobalRegistration] {
        guard projectsInUse.contains(model.directory), let helper = isolationContext?.helperPath ?? configuration?.helperURL.path else { return [] }
        var result: [GlobalRegistration] = []
        for server in globalServers(for: model) {
            var registration = GlobalRegistration(name: server.name, serverID: server.id, kind: server.kind, directory: model.directory, helper: helper)
            for (field, account) in server.secretEntries { registration.secretAccounts[field.name] = account }
            switch server.kind {
            case .remote:
                guard let remote = server.remote else { continue }
                registration.url = remote.url
                for header in remote.headers where !header.secret { registration.plainHeaders[header.name] = header.value ?? "" }
            case .image:
                // Per-connection containers end with the connection: a project stopped when idle has none.
                if idledOut.contains(model.directory) { continue }
                if globalMCPStates[server.id]?.problem != nil { continue }
            case .stack:
                guard let port = stackForwarders[server.id]?.hostPort, let stack = server.stack else { continue }
                registration.url = "http://127.0.0.1:\(port)\(stack.path)"
            }
            result.append(registration)
        }
        // `docker run` entries of the isolated configuration are already in opencode's configuration (all locations).
        return result
    }

    /// Reads the Keychain values and builds opencode's config for each registration. A missing secret leaves the server
    /// out (reported, never registered without it).
    nonisolated static func resolve(_ registrations: [GlobalRegistration], vault: (any SecretVault)?) -> (configs: [String: JSONValue], missing: [String: String]) {
        var configs: [String: JSONValue] = [:]
        var missing: [String: String] = [:]
        for registration in registrations {
            var secrets: [String: String] = [:]
            var absent: [String] = []
            for (name, account) in registration.secretAccounts.sorted(by: { $0.key < $1.key }) {
                if let value = (try? vault?.read(account: account)) ?? nil, !value.isEmpty {
                    secrets[name] = String(decoding: value.utf8, as: UTF8.self)
                } else {
                    absent.append(name)
                }
            }
            if !absent.isEmpty {
                missing[registration.serverID] = "\(absent.joined(separator: ", ")) \(absent.count == 1 ? "has" : "have") no value in the Keychain. Edit the server and enter \(absent.count == 1 ? "it" : "them")."
                continue
            }
            switch registration.kind {
            case .remote:
                guard let url = registration.url else { continue }
                configs[registration.name] = MCPRouting.remoteServerConfig(url: url, headers: registration.plainHeaders.merging(secrets) { _, secret in secret })
            case .image:
                configs[registration.name] = MCPRouting.imageServerConfig(
                    helper: registration.helper, id: registration.serverID, project: registration.directory, secrets: secrets)
            case .stack:
                guard let url = registration.url else { continue }
                configs[registration.name] = MCPRouting.remoteServerConfig(url: url, headers: [:])
            }
        }
        return (configs, missing)
    }

    /// Recomputes each global server's per-project status from the locations' MCP lists.
    func refreshGlobalStates() {
        for server in globalMCP.servers {
            var state = globalMCPStates[server.id] ?? GlobalMCPState()
            state.connected = []
            state.pending = []
            state.failed = [:]
            state.needsAuth = []
            for model in models.values where projectsInUse.contains(model.directory) {
                guard let status = model.mcpStatus.first(where: { $0.name == server.name }) else { continue }
                let project = (model.directory as NSString).lastPathComponent
                switch status.status {
                case "connected": state.connected.append(project)
                case "pending": state.pending.append(project)
                case "needs_auth": state.needsAuth.append(project)
                case "failed": state.failed[project] = status.error ?? "failed"
                default: break
                }
            }
            state.connected.sort()
            state.pending.sort()
            state.needsAuth.sort()
            if state != globalMCPStates[server.id] { globalMCPStates[server.id] = state }
        }
    }

    // MARK: Images

    /// The helper's view of the enabled image servers (no secret values): Settings' plus the configuration files'.
    func imageServerSpecs() -> [ImageMCPSpec] {
        let corporate = network.corporate
        let settings = globalMCP.servers.filter { $0.enabled && $0.kind == .image }.compactMap { server -> ImageMCPSpec? in
            guard let image = server.image else { return nil }
            return ImageMCPSpec(
                id: server.id, name: server.name, image: image.image, entrypoint: image.entrypoint, args: image.args,
                environment: Dictionary(image.environment.filter { !$0.secret }.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a }),
                secretNames: image.environment.filter(\.secret).map(\.name), mounts: image.mounts, network: image.network, shared: image.shared,
                corporateNetwork: corporate.isEmpty ? nil : corporate, blocked: imageRefusal(image.image))
        }
        let configured = configImageServers.map { spec -> ImageMCPSpec in
            var spec = spec
            spec.corporateNetwork = corporate.isEmpty ? nil : corporate
            spec.blocked = imageRefusal(spec.image)
            return spec
        }
        return settings + configured + (verifyImageSpec.map { [$0] } ?? [])
    }

    /// Checks which image servers' images are on this Mac (and refused ones), pulling none: Settings offers Pull.
    func checkGlobalImages() {
        guard isEnabled, runtime?.isReady == true else { return }
        let runtimeRef = activeRuntime
        let images = globalMCP.servers.compactMap { server in server.image.map { (server.id, $0.image) } }
        tasks.set("mcp-images", Task { [weak self] in
            var present: [String: Bool] = [:]
            for (id, image) in images { present[id] = ((try? await runtimeRef.image(image)) ?? nil) != nil }
            guard let self, !Task.isCancelled else { return }
            for (id, image) in images {
                var state = self.globalMCPStates[id] ?? GlobalMCPState()
                state.imagePresent = present[id]
                if let refusal = self.imageRefusal(image) {
                    state.problem = refusal
                } else if present[id] == false, !state.isPulling {
                    state.problem = "The image \(image) is not on this Mac yet. Pull it to use this server."
                } else {
                    state.problem = nil
                }
                if state != self.globalMCPStates[id] { self.globalMCPStates[id] = state }
            }
            for model in self.models.values where self.projectsInUse.contains(model.directory) { self.syncMCPServers(model) }
        })
    }

    /// Pulls an image server's image (image policy and registry credentials as for workspaces).
    public func pullGlobalMCPImage(_ id: String) {
        guard isEnabled, let server = globalMCP.servers.first(where: { $0.id == id }), let image = server.image?.image else { return }
        var state = globalMCPStates[id] ?? GlobalMCPState()
        if let refusal = imageRefusal(image) {
            state.problem = refusal
            globalMCPStates[id] = state
            return
        }
        state.isPulling = true
        state.pullFraction = nil
        globalMCPStates[id] = state
        let auth = registryAuth(for: image)
        let runtimeRef = activeRuntime
        let aggregator = PullAggregator()
        tasks.set("mcp-pull-\(id)", Task { [weak self] in
            let ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.globalMCPStates[id]?.pullFraction = aggregator.progress.fraction
                }
            }
            defer { ticker.cancel() }
            var failure: String?
            do {
                let existed = ((try? await runtimeRef.image(image)) ?? nil) != nil
                try await runtimeRef.pull(image, auth: auth) { aggregator.add($0) }
                guard let self else { return }
                if !existed { self.recordPulled(image) }
            } catch {
                failure = Self.describe(error)
            }
            guard let self, !Task.isCancelled else { return }
            self.globalMCPStates[id]?.isPulling = false
            self.globalMCPStates[id]?.pullFraction = nil
            if let failure { self.globalMCPStates[id]?.problem = "Pulling \(image) failed: \(failure)" }
            self.checkGlobalImages()
        })
    }

    /// A shared image server's container stops once opencode has had no connection to it for its idle time.
    func stopIdleSharedImageServers() {
        for server in globalMCP.servers where server.kind == .image && server.image?.shared == true {
            let minutes = server.image?.idleStopMinutes ?? 0
            let state = globalMCPStates[server.id] ?? GlobalMCPState()
            if !state.connected.isEmpty || !state.pending.isEmpty || stackLastUse[server.id] == nil {
                stackLastUse[server.id] = .now
                continue
            }
            guard minutes > 0, let last = stackLastUse[server.id], ContinuousClock.now - last > .seconds(minutes * 60) else { continue }
            stackLastUse[server.id] = .now
            let name = ImageMCPSpec(id: server.id, name: server.name, image: "").containerName(scope: nil)
            let runtimeRef = activeRuntime
            tasks.set("mcp-idle-\(server.id)", Task { try? await runtimeRef.stop(container: name) })
        }
    }

    // MARK: Restart and logs

    /// Replaces the server's connections: unregistered and registered again everywhere (a shared container and a stack
    /// are restarted first).
    public func restartGlobalMCP(_ id: String) async {
        guard let server = globalMCP.servers.first(where: { $0.id == id }), let context = isolationContext else { return }
        if server.kind == .image, server.image?.shared == true, let spec = imageServerSpecs().first(where: { $0.id == id }) {
            try? await activeRuntime.removeContainer(spec.containerName(scope: nil))
        }
        if server.kind == .stack { await restartStack(server) }
        let directories = registeredMCP.filter { $0.value[server.name] != nil }.map(\.key)
        if let client = try? await context.client() {
            for directory in directories { try? await client.removeMCPServer(server.name, directory: directory) }
        }
        for directory in directories { registeredMCP[directory]?[server.name] = nil }
        for model in models.values where directories.contains(model.directory) || projectsInUse.contains(model.directory) { syncMCPServers(model) }
    }

    /// The server's recent error output (image: the helper's bounded log; stack: its services' logs; remote: none).
    public func globalMCPLogs(_ id: String) async -> String {
        guard let server = globalMCP.servers.first(where: { $0.id == id }) else { return "" }
        switch server.kind {
        case .remote:
            return "Remote servers keep no log on this Mac. opencode's status for each project is shown in the row."
        case .image:
            guard let directory = configuration?.mcpLogDirectory else { return "" }
            let text = BoundedLogFile(url: directory.appending(path: "\(id).log")).read()
            return text.isEmpty ? "No error output yet." : text
        case .stack:
            return await stackLogs(server)
        }
    }
}

/// Keychain operations run off the main actor (they block on securityd).
enum VaultIO {
    @concurrent
    static func run<T: Sendable>(_ operation: @Sendable () throws -> T) async throws -> T { try operation() }
}

extension EnvironmentService {
    /// Snapshots and previews only (`--snapshot containers3`): shows a state with no runtime or server behind it.
    public func previewGlobalMCPState(_ id: String, _ state: GlobalMCPState) { globalMCPStates[id] = state }
    /// Snapshots and previews only: shows a diagnostics run without fetching anything.
    public func previewNetworkDiagnostics(_ run: NetworkDiagnostics) { network.diagnostics = run }
}
