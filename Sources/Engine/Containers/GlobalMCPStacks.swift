import ContainerKit
import Foundation
import OpenCodeKit

/// What a prepared stack runs with: compose project, files (the person's, then BelloCode's override), the endpoint's
/// container, and the normalised model.
struct StackPlan: Sendable, Equatable {
    var id: String
    var project: String
    var files: [URL]
    var workingDirectory: URL?
    var endpointContainer: String
    var model: ComposeModel
    var executable: URL
    var configDirectory: URL

    func run(_ runtime: any WorkspaceRuntime, _ command: [String], timeout: Duration) async throws -> ComposeCLI.Result {
        try await runtime.compose(executable: executable, configDirectory: configDirectory, project: project, files: files,
                                  workingDirectory: workingDirectory, command: command, timeout: timeout)
    }
}

/// Starts a stack at most once at a time. The first connection after the stack was prepared always runs `up` (it is
/// idempotent and recreates only services whose definition changed); later ones check with `ps` at most every 5 s (an
/// MCP client opens a connection per request).
actor StackGate {
    private var upped = false
    private var confirmed: ContinuousClock.Instant?
    func reset() { confirmed = nil }

    func ensureUp(_ plan: StackPlan, runtime: any WorkspaceRuntime) async -> Bool {
        if let confirmed, ContinuousClock.now - confirmed < .seconds(5) { return true }
        let service = plan.model.services.first { plan.model.containerName($0.name) == plan.endpointContainer }?.name
        if upped, let ps = try? await plan.run(runtime, ["ps", "--format", "json"], timeout: .seconds(30)),
           ComposeServiceStatus.parse(ps.text).contains(where: { $0.service == service && $0.state == "running" }) {
            confirmed = .now
            return true
        }
        let up = try? await plan.run(runtime, ["up", "--detach", "--wait", "--quiet-pull", "--remove-orphans"], timeout: .seconds(600))
        guard up?.status == 0 else { return false }
        upped = true
        confirmed = .now
        return true
    }
}

/// Compose-stack MCP servers (docs/features/containers.md, "Global MCP servers"), run by Rancher Desktop's
/// `docker compose` (`ComposeCLI`: explicit path, Rancher's socket, BelloCode's own `DOCKER_CONFIG`) as project
/// `bellocode-mcp-<key>`. `docker compose config` normalises the file first: elevated features need "Run as written",
/// the engine socket is refused, image-only services follow the image policy. BelloCode's override labels every
/// container, adds the enterprise certificates and proxies (also to builds), and resets published ports: the endpoint
/// (service, port, path) is forwarded to `127.0.0.1:<port>` on the Mac through a relay in the endpoint's container and
/// registered with opencode as a remote server. The stack starts on the first connection and stops when idle.
extension EnvironmentService {
    nonisolated static let stackLabel = "app.bellocode.mcp-stack"

    nonisolated static func stackKey(_ id: String) -> String { WorkspaceSpec.projectKey(for: "bellocode-mcp-stack:\(id)") }
    nonisolated static func stackProject(_ id: String) -> String { "bellocode-mcp-\(stackKey(id))" }

    var stackFolder: URL {
        configuration?.stackDirectory ?? FileManager.default.temporaryDirectory.appending(path: "bellocode-mcp-stacks", directoryHint: .isDirectory)
    }

    /// Normalises the file with `docker compose config`, checks it, and writes BelloCode's override. Throws a message.
    func prepareStack(_ server: GlobalMCPServer) async throws -> StackPlan {
        guard let stack = server.stack else { throw EnvironmentBlockedError(message: "no compose file") }
        guard let executable = configuration?.composeExecutable() else {
            throw EnvironmentBlockedError(message: "Rancher Desktop's docker-compose was not found at ~/.rd/bin/docker-compose. Install or repair Rancher Desktop.")
        }
        let folder = stackFolder.appending(path: server.id, directoryHint: .isDirectory)
        let dockerConfig = stackFolder.appending(path: "docker-config", directoryHint: .isDirectory)
        let project = Self.stackProject(server.id)
        let file: URL
        let workingDirectory: URL
        if let path = stack.composeFile {
            file = URL(filePath: path)
            workingDirectory = file.deletingLastPathComponent()
        } else {
            file = folder.appending(path: "compose.yaml")
            workingDirectory = folder
            try await Self.writeFile(Data(stack.composeYAML.utf8), to: file)
        }
        try await verifyStackOwnership(project: project, id: server.id)
        let probe = StackPlan(id: server.id, project: project, files: [file], workingDirectory: workingDirectory, endpointContainer: "",
                              model: ComposeModel(name: project, services: []), executable: executable, configDirectory: dockerConfig)
        let config = try await probe.run(activeRuntime, ["config", "--format", "json"], timeout: .seconds(60))
        guard config.status == 0 else { throw EnvironmentBlockedError(message: "docker compose cannot read the file: \(config.errorSummary)") }
        let model = try ComposeModel.parse(config.stdout)
        if let forbidden = model.forbidden.first { throw EnvironmentBlockedError(message: "Refused: \(forbidden).") }
        if !stack.allowElevated, !model.elevated.isEmpty {
            throw EnvironmentBlockedError(message: "Not started: the file asks for \(model.elevated.joined(separator: ", ")). Review it and turn on “Run as written” to allow this.")
        }
        for service in model.services where !service.hasBuild {
            if let image = service.image, let refusal = imageRefusal(image) { throw EnvironmentBlockedError(message: "\(service.name): \(refusal)") }
        }
        guard let endpoint = model.containerName(stack.service) else {
            throw EnvironmentBlockedError(message: "The compose file has no service “\(stack.service)”.")
        }
        let override = folder.appending(path: "bellocode.override.yaml")
        let corporate = network.corporate.isEmpty ? nil : network.corporate
        try await Self.writeFile(Data(model.override(label: (Self.stackLabel, server.id), corporate: corporate).utf8), to: override)
        return StackPlan(id: server.id, project: project, files: [file, override], workingDirectory: workingDirectory, endpointContainer: endpoint,
                         model: model, executable: executable, configDirectory: dockerConfig)
    }

    /// The name of a container in the compose project that BelloCode's override did not label for this server, if any.
    nonisolated static func foreignStackContainer(_ containers: [ContainerSummary], id: String) -> String? {
        containers.first { $0.labels[stackLabel] != id }.map { $0.name }
    }

    /// R07: `up --remove-orphans`, `stop` and `down` act on every container of the compose project. When the project
    /// holds a container BelloCode did not create for this server (a manual stack that happens to share the name),
    /// nothing is run and the server shows why.
    func verifyStackOwnership(project: String, id: String) async throws {
        let containers = try await activeRuntime.composeProjectContainers(project)
        if let name = Self.foreignStackContainer(containers, id: id) {
            throw EnvironmentBlockedError(message: ForeignResourceError(kind: .container, name: name).description
                + " It is part of the compose project \(project), which BelloCode uses for this MCP server.")
        }
    }

    /// Starts forwarders for enabled stack servers and stops those that are off or gone (their stack stops; a removed
    /// one is taken down, volumes kept). `force` prepares them again (definition or network settings changed).
    func reconcileStacks(force: Bool = false, changed: Set<String> = []) {
        guard isEnabled, runtime?.isReady == true else { return }
        let wanted = globalMCP.servers.filter { $0.enabled && $0.kind == .stack && $0.validationErrors().isEmpty }
        let known = Set(globalMCP.servers.map(\.id))
        for (id, forwarder) in stackForwarders where force || changed.contains(id) || !wanted.contains(where: { $0.id == id }) {
            forwarder.stop()
            stackForwarders[id] = nil
            if !wanted.contains(where: { $0.id == id }), let plan = stackPlans[id] {
                stackPlans[id] = nil
                runCompose(plan, known.contains(id) ? ["stop"] : ["down", "--remove-orphans"], key: "stack-stop-\(id)")
            }
        }
        for server in wanted where stackForwarders[server.id] == nil {
            tasks.set("stack-prepare-\(server.id)", Task { [weak self] in await self?.startStackForwarder(server) })
        }
    }

    private func startStackForwarder(_ server: GlobalMCPServer) async {
        guard let stack = server.stack else { return }
        var state = globalMCPStates[server.id] ?? GlobalMCPState()
        let plan: StackPlan
        do {
            plan = try await prepareStack(server)
        } catch {
            state.problem = Self.describe(error)
            globalMCPStates[server.id] = state
            return
        }
        guard globalMCP.servers.contains(where: { $0.id == server.id && $0.enabled }), stackForwarders[server.id] == nil else { return }
        stackPlans[server.id] = plan
        let runtimeRef = activeRuntime
        let gate = StackGate()
        let id = server.id
        let prepare: @Sendable () async -> Bool = {
            let up = await gate.ensureUp(plan, runtime: runtimeRef)
            await MainActor.run { [weak self] in self?.refreshStack(id) }
            return up
        }
        do {
            let forwarder = try runtimeRef.makeStackForwarder(container: plan.endpointContainer, port: stack.port, hostPort: stack.hostPort ?? 0,
                                                              prepare: prepare)
            stackForwarders[server.id] = forwarder
            stackGates[server.id] = gate
            stackLastUse[server.id] = .now
            tasks.set("stack-forward-\(server.id)", Task { await forwarder.run() })
            state.hostPort = forwarder.hostPort
            state.problem = nil
            globalMCPStates[server.id] = state
            if stack.hostPort != forwarder.hostPort { rememberStackPort(server.id, port: forwarder.hostPort) }
            for model in models.values where projectsInUse.contains(model.directory) { syncMCPServers(model) }
            refreshStack(server.id)
        } catch {
            // The remembered port is taken: pick another (opencode is registered again with the new URL).
            if stack.hostPort != nil {
                rememberStackPort(server.id, port: nil)
                return
            }
            state.problem = "The endpoint could not be forwarded to this Mac: \(Self.describe(error))"
            globalMCPStates[server.id] = state
        }
    }

    private func rememberStackPort(_ id: String, port: Int?) {
        guard let index = globalMCP.servers.firstIndex(where: { $0.id == id }) else { return }
        var servers = globalMCP.servers
        servers[index].stack?.hostPort = port
        globalMCP = GlobalMCPList(servers: servers)
        tasks.set("stack-port-\(id)", Task { [weak self] in
            guard let self else { return }
            try? await self.store.setPreference(GlobalMCPList.preferenceKey, self.globalMCP)
            if port == nil, let server = self.globalMCP.servers.first(where: { $0.id == id }) { await self.startStackForwarder(server) }
            for model in self.models.values where self.projectsInUse.contains(model.directory) { self.syncMCPServers(model) }
        })
    }

    private func runCompose(_ plan: StackPlan, _ command: [String], key: String, then: (@MainActor () -> Void)? = nil) {
        let runtimeRef = activeRuntime
        tasks.set(key, Task { [weak self] in
            do {
                try await self?.verifyStackOwnership(project: plan.project, id: plan.id)
            } catch {
                guard let self, !Task.isCancelled else { return }
                var state = self.globalMCPStates[plan.id] ?? GlobalMCPState()
                state.problem = Self.describe(error)
                self.globalMCPStates[plan.id] = state
                return
            }
            _ = try? await plan.run(runtimeRef, command, timeout: .seconds(120))
            guard self != nil, !Task.isCancelled else { return }
            then?()
        })
    }

    /// Reads the stack's services (state, health) into the server's state.
    public func refreshStack(_ id: String) {
        guard let plan = stackPlans[id] else { return }
        let runtimeRef = activeRuntime
        tasks.set("stack-status-\(id)", Task { [weak self] in
            let ps = try? await plan.run(runtimeRef, ["ps", "--all", "--format", "json"], timeout: .seconds(30))
            let statuses = ComposeServiceStatus.parse(ps?.text ?? "")
            guard let self, !Task.isCancelled else { return }
            var state = self.globalMCPStates[id] ?? GlobalMCPState()
            state.services = plan.model.services.map { service in
                let current = statuses.first { $0.service == service.name }
                let phase: ServiceState.Phase = switch current?.state {
                case "running"?: .running
                case "exited"?, "dead"?: .stopped
                case "created"?, "restarting"?: .starting
                default: .notStarted
                }
                return ServiceState(name: service.name, image: service.image ?? (service.hasBuild ? "built from its Dockerfile" : ""), phase: phase,
                                    health: current?.health, message: current?.exitCode.flatMap { phase == .stopped ? "exit \($0)" : nil })
            }
            state.activeConnections = self.stackForwarders[id]?.activeConnections ?? 0
            if state != self.globalMCPStates[id] { self.globalMCPStates[id] = state }
        })
    }

    func restartStack(_ server: GlobalMCPServer) async {
        guard let plan = stackPlans[server.id] else { return }
        await stackGates[server.id]?.reset()
        _ = try? await plan.run(activeRuntime, ["restart"], timeout: .seconds(120))
        refreshStack(server.id)
    }

    func stackLogs(_ server: GlobalMCPServer) async -> String {
        guard let plan = stackPlans[server.id] else { return globalMCPStates[server.id]?.problem ?? "The stack has not been prepared." }
        let text = (try? await plan.run(activeRuntime, ["logs", "--no-color", "--tail", "100"], timeout: .seconds(30)))?.text ?? ""
        return text.isEmpty ? "No output yet." : String(text.suffix(64 * 1024))
    }

    /// Stacks with no connection for their idle time are stopped (the next connection starts them again).
    func stopIdleStacks() {
        for server in globalMCP.servers where server.kind == .stack {
            guard let forwarder = stackForwarders[server.id], let plan = stackPlans[server.id], let minutes = server.stack?.idleStopMinutes,
                  minutes > 0 else { continue }
            if forwarder.activeConnections > 0 || forwarder.connectionCount != stackSeenConnections[server.id] {
                stackSeenConnections[server.id] = forwarder.connectionCount
                stackLastUse[server.id] = .now
                continue
            }
            guard let last = stackLastUse[server.id], ContinuousClock.now - last > .seconds(minutes * 60) else { continue }
            stackLastUse[server.id] = .now
            let gate = stackGates[server.id]
            tasks.set("stack-gate-\(server.id)", Task { await gate?.reset() })
            runCompose(plan, ["stop"], key: "stack-idle-\(server.id)") { [weak self] in self?.refreshStack(server.id) }
        }
    }

    /// Project keys of stacks (kept for Prune; compose's own volumes carry no BelloCode label and are never listed).
    var stackProjectKeys: Set<String> { Set(globalMCP.servers.filter { $0.kind == .stack }.map { Self.stackKey($0.id) }) }

    /// Stops every forwarder (engine stop). Running stacks stop when idle on the next launch or with Rancher Desktop.
    func stopStackForwarders() {
        for forwarder in stackForwarders.values { forwarder.stop() }
        stackForwarders.removeAll()
    }
}
