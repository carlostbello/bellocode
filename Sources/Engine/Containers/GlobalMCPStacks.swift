import ContainerKit
import Foundation
import OpenCodeKit

/// Compose-stack MCP servers (docs/features/containers.md, "Global MCP servers"): the compose file (same subset and
/// refusals as project services) runs as a BelloCode-managed stack on its own network `bellocode-net-<key>`, with
/// containers `bellocode-svc-<key>-<service>` labelled `app.bellocode.mcp-stack=<id>`. The endpoint (service, port,
/// path) is forwarded to `127.0.0.1:<port>` on the Mac through a relay in that service's container (nothing is
/// published) and registered with opencode as a remote server. The stack starts on the first connection and stops
/// after its idle time without one.
extension EnvironmentService {
    nonisolated static let stackLabel = "app.bellocode.mcp-stack"

    /// The stack's surrogate project root: keys its containers, volumes and network like a project's.
    nonisolated static func stackRoot(_ id: String) -> String { "bellocode-mcp-stack:\(id)" }
    nonisolated static func stackKey(_ id: String) -> String { WorkspaceSpec.projectKey(for: stackRoot(id)) }

    /// The services to start (refused services are left out and reported).
    func stackSpecs(_ server: GlobalMCPServer) -> (specs: [ServiceSpec], refused: [String], errors: [String]) {
        guard let stack = server.stack else { return ([], [], ["no compose file"]) }
        let parse = ComposeParser.parse(stack.composeYAML)
        guard parse.isUsable else { return ([], [], parse.errors) }
        let root = Self.stackRoot(server.id)
        let network = ServiceLabels.networkName(projectKey: Self.stackKey(server.id), offline: false)
        let usable = parse.services.filter { !parse.refusedServices.contains($0.name) }
        let names = usable.map(\.name)
        let corporate = self.network.corporate.isEmpty ? nil : self.network.corporate
        let specs = usable.map { definition -> ServiceSpec in
            var spec = ServiceSpec(projectRoot: root, definition: definition, network: network, extraLabels: [Self.stackLabel: server.id])
            spec.corporateNetwork = corporate
            spec.siblings = names
            return spec
        }
        let refused = parse.refusedServices + parse.rejected.map { "\($0.path): \($0.reason)" }
        return (specs, refused, [])
    }

    /// Starts forwarders for enabled stack servers and stops those of servers that are off or gone (their stack stops,
    /// volumes are kept). `force` recreates forwarders (the definition or the network settings changed).
    func reconcileStacks(force: Bool = false) {
        guard isEnabled, runtime?.isReady == true else { return }
        let wanted = globalMCP.servers.filter { $0.enabled && $0.kind == .stack && $0.validationErrors().isEmpty }
        for (id, forwarder) in stackForwarders where force || !wanted.contains(where: { $0.id == id }) {
            forwarder.stop()
            stackForwarders[id] = nil
            if !wanted.contains(where: { $0.id == id }) {
                let runtimeRef = activeRuntime
                let key = Self.stackKey(id)
                tasks.set("stack-stop-\(id)", Task { try? await runtimeRef.stopServices(projectKey: key) })
            }
        }
        for server in wanted where stackForwarders[server.id] == nil {
            startStackForwarder(server)
        }
    }

    private func startStackForwarder(_ server: GlobalMCPServer) {
        guard let stack = server.stack else { return }
        let (specs, refused, errors) = stackSpecs(server)
        var state = globalMCPStates[server.id] ?? GlobalMCPState()
        guard errors.isEmpty, let endpoint = specs.first(where: { $0.name == stack.service }) else {
            state.problem = errors.first ?? "The endpoint service “\(stack.service)” is refused: \(refused.joined(separator: "; "))"
            globalMCPStates[server.id] = state
            return
        }
        for spec in specs {
            if let refusal = imageRefusal(spec.definition.image) {
                state.problem = "\(spec.name): \(refusal)"
                globalMCPStates[server.id] = state
                return
            }
        }
        let runtimeRef = activeRuntime
        let root = Self.stackRoot(server.id)
        let container = endpoint.containerName
        let id = server.id
        // Before each connection: the stack runs (started on first use; a running endpoint is a quick check).
        let prepare: @Sendable () async -> Bool = {
            if let status = try? await runtimeRef.serviceStatus(projectKey: WorkspaceSpec.projectKey(for: root), specs: specs),
               status[endpoint.name]?.isRunning == true, status[endpoint.name]?.outdated == false {
                return true
            }
            let outcomes = (try? await runtimeRef.ensureMCPStack(specs, root: root)) ?? [:]
            await MainActor.run { [weak self] in self?.refreshStack(id) }
            return outcomes[endpoint.name] == .running
        }
        do {
            let forwarder = try runtimeRef.makeStackForwarder(container: container, port: stack.port, hostPort: stack.hostPort ?? 0, prepare: prepare)
            stackForwarders[server.id] = forwarder
            stackLastUse[server.id] = .now
            tasks.set("stack-forward-\(server.id)", Task { await forwarder.run() })
            state.hostPort = forwarder.hostPort
            state.problem = nil
            globalMCPStates[server.id] = state
            if stack.hostPort != forwarder.hostPort { rememberStackPort(server.id, port: forwarder.hostPort) }
            refreshStack(server.id)
        } catch {
            // The remembered port is taken: pick another (opencode is re-registered with the new URL).
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
            if port == nil, let server = self.globalMCP.servers.first(where: { $0.id == id }) { self.startStackForwarder(server) }
            for model in self.models.values where self.projectsInUse.contains(model.directory) { self.syncMCPServers(model) }
        })
    }

    /// Reads the stack's services (state, health) into the server's state.
    public func refreshStack(_ id: String) {
        guard let server = globalMCP.servers.first(where: { $0.id == id }), server.kind == .stack else { return }
        let (specs, refused, _) = stackSpecs(server)
        let runtimeRef = activeRuntime
        let key = Self.stackKey(id)
        tasks.set("stack-status-\(id)", Task { [weak self] in
            let status = (try? await runtimeRef.serviceStatus(projectKey: key, specs: specs)) ?? [:]
            guard let self, !Task.isCancelled else { return }
            var state = self.globalMCPStates[id] ?? GlobalMCPState()
            state.services = specs.map { spec in
                let current = status[spec.name]
                let phase: ServiceState.Phase = switch current?.state {
                case "running"?: .running
                case "exited"?, "dead"?: .stopped
                case "created"?, "restarting"?: .starting
                default: .notStarted
                }
                return ServiceState(name: spec.name, image: spec.definition.image, ports: spec.definition.ports.map(\.containerPort), phase: phase,
                                    health: current?.health, containerID: current?.containerID,
                                    message: current?.exitCode.flatMap { phase == .stopped ? "exit \($0)" : nil }, outdated: current?.outdated ?? false)
            } + refused.map { ServiceState(name: $0, image: "", phase: .refused, message: "refused") }
            state.activeConnections = self.stackForwarders[id]?.activeConnections ?? 0
            if state != self.globalMCPStates[id] { self.globalMCPStates[id] = state }
        })
    }

    func restartStack(_ server: GlobalMCPServer) async {
        let (specs, _, _) = stackSpecs(server)
        let root = Self.stackRoot(server.id)
        try? await activeRuntime.stopServices(projectKey: Self.stackKey(server.id))
        _ = try? await activeRuntime.ensureMCPStack(specs, root: root)
        refreshStack(server.id)
    }

    func stackLogs(_ server: GlobalMCPServer) async -> String {
        let (specs, _, _) = stackSpecs(server)
        let status = (try? await activeRuntime.serviceStatus(projectKey: Self.stackKey(server.id), specs: specs)) ?? [:]
        var text = ""
        for spec in specs {
            guard let container = status[spec.name]?.containerID else {
                text += "── \(spec.name): not started\n"
                continue
            }
            let logs: (text: String, truncated: Bool) = (try? await activeRuntime.serviceLogs(container: container, tail: 100, limit: 32 * 1024)) ?? ("", false)
            text += "── \(spec.name)\(logs.truncated ? " (last part)" : "")\n\(logs.text)\n"
        }
        return text.isEmpty ? "No services." : text
    }

    /// Stacks with no connection for their idle time are stopped (the next connection starts them again).
    func stopIdleStacks() {
        for server in globalMCP.servers where server.kind == .stack {
            guard let forwarder = stackForwarders[server.id], let minutes = server.stack?.idleStopMinutes, minutes > 0 else { continue }
            if forwarder.activeConnections > 0 || forwarder.connectionCount != stackSeenConnections[server.id] {
                stackSeenConnections[server.id] = forwarder.connectionCount
                stackLastUse[server.id] = .now
                continue
            }
            guard let last = stackLastUse[server.id], ContinuousClock.now - last > .seconds(minutes * 60) else { continue }
            stackLastUse[server.id] = .now
            let runtimeRef = activeRuntime
            let key = Self.stackKey(server.id)
            tasks.set("stack-idle-\(server.id)", Task { [weak self] in
                try? await runtimeRef.stopServices(projectKey: key)
                self?.refreshStack(server.id)
            })
        }
    }

    /// Project keys of stacks (their volumes are not leftovers for Prune).
    var stackProjectKeys: Set<String> { Set(globalMCP.servers.filter { $0.kind == .stack }.map { Self.stackKey($0.id) }) }

    /// Stops every forwarder (engine stop).
    func stopStackForwarders() {
        for forwarder in stackForwarders.values { forwarder.stop() }
        stackForwarders.removeAll()
    }
}
