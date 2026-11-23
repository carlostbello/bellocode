import BelloCore
import ContainerKit
import Foundation
import OpenCodeKit

/// The project-service app tools (client MCP, `bellocode_app_<name>`; docs/features/containers.md "Services"). Scoped to
/// the calling thread's project. Agents can list services, read bounded logs and restart a service (the person
/// approves the first restart per project); no tool removes a service's data.
public enum ContainerTools {
    public static let listServices = "list_services"
    public static let serviceLogs = "service_logs"
    public static let restartService = "restart_service"
    public static let all = [listServices, serviceLogs, restartService]

    /// Most lines and bytes `service_logs` returns.
    public static let maxLines = 500

    /// The `lines` argument, clamped as a Double first: an out-of-range number from an agent must not trap the app.
    static func logLines(_ value: JSONValue?) -> Int {
        let requested = value?.numberValue ?? 100
        guard requested.isFinite else { return 100 }
        return Int(min(max(requested, 1), Double(maxLines)))
    }
    public static let maxBytes = 16 * 1024

    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string))])
    }

    public static let definitions: [ClientMCPTool] = [
        ClientMCPTool(
            name: listServices,
            description: "List this project's supporting services (databases, caches, queues) with their state, health and ports. Services run in containers on the project's own network: reach them from commands by service name and port (e.g. postgres:5432), never localhost.",
            inputSchema: object([:])),
        ClientMCPTool(
            name: serviceLogs,
            description: "Read the most recent output of one of this project's services (bounded: at most \(maxLines) lines and \(maxBytes / 1024) KB; older output is cut and marked).",
            inputSchema: object([
                "service": .object(["type": .string("string"), "description": .string("The service name from list_services.")]),
                "lines": .object(["type": .string("number"), "description": .string("How many recent lines (default 100, at most \(maxLines)).")]),
            ], required: ["service"])),
        ClientMCPTool(
            name: restartService,
            description: "Restart one of this project's services (recreated if its definition changed). Its data is kept. The first restart in a project asks the user; end your turn after calling it if it says so.",
            inputSchema: object([
                "service": .object(["type": .string("string"), "description": .string("The service name from list_services.")]),
            ], required: ["service"])),
    ]

    /// The text `list_services` answers with (pure: tested).
    static func describe(_ services: [ServiceState], source: ServicesSource, parse: ComposeParseResult?, workspaceReady: Bool) -> String {
        guard !services.isEmpty else {
            switch source {
            case .none: return "This project defines no services (no compose.yaml and none in Project Settings ▸ Environment ▸ Services)."
            default:
                return "This project's service definition cannot be used: " + (parse?.errors.joined(separator: " ") ?? "no services.")
            }
        }
        var lines = ["Services (\(sourceText(source))); reach them by name from commands in this project's container:"]
        for service in services {
            var parts = ["\(service.name): \(service.label)"]
            if !service.image.isEmpty { parts.append("image \(service.image)") }
            if !service.ports.isEmpty { parts.append("ports " + service.ports.map { "\(service.name):\($0)" }.joined(separator: ", ")) }
            if let message = service.message { parts.append(message) }
            if service.outdated { parts.append("definition changed: restart to apply") }
            lines.append("- " + parts.joined(separator: " · "))
        }
        if !workspaceReady { lines.append("The project's container is not running; services start with it.") }
        let rejected = parse?.rejected ?? []
        if !rejected.isEmpty { lines.append("Refused keys: " + rejected.map { "\($0.path) (\($0.reason))" }.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }

    static func sourceText(_ source: ServicesSource) -> String {
        switch source {
        case .none: "none"
        case .file(let path): "from \((path as NSString).lastPathComponent)"
        case .pane: "defined in BelloCode"
        }
    }
}

/// A restart waiting for the person's approval (in memory: after a relaunch the card cannot run anything).
struct PendingServiceRestart: Sendable {
    var sessionID: SessionID
    var projectDirectory: String
    var service: String
}

extension Engine {
    /// Runs one container app tool for `caller` (a thread of the project at `projectDirectory`).
    func handleContainerTool(_ call: ClientMCPCall, caller: SessionID, projectDirectory: String) async -> ClientMCPResult {
        let environments = self.environments
        guard environments.isEnabled else { return .error("This project's commands do not run in containers, so it has no services.") }
        let model = environments.environment(for: projectDirectory)
        switch call.tool {
        case ContainerTools.listServices:
            await environments.refreshServices(model.directory)
            return ClientMCPResult(text: ContainerTools.describe(
                model.services, source: model.servicesSource, parse: model.servicesParse, workspaceReady: model.phase == .ready))
        case ContainerTools.serviceLogs:
            guard let service = call.arguments["service"]?.stringValue else { return .error("Give service.") }
            let lines = ContainerTools.logLines(call.arguments["lines"])
            do {
                let (text, truncated) = try await environments.serviceLogs(model.directory, name: service, tail: lines, limit: ContainerTools.maxBytes)
                let header = "Last \(lines) lines of \(service)" + (truncated ? " (older output cut at \(ContainerTools.maxBytes / 1024) KB)" : "") + ":\n"
                return ClientMCPResult(text: header + (text.isEmpty ? "(no output)" : text))
            } catch {
                return .error(EnvironmentService.describe(error))
            }
        case ContainerTools.restartService:
            guard let service = call.arguments["service"]?.stringValue else { return .error("Give service.") }
            await loadServiceRestartGrants()
            guard model.services.contains(where: { $0.name == service }) || environments.loadServices(model)?.services.contains(where: { $0.name == service }) == true else {
                return .error("This project has no service named “\(service)”. Use list_services.")
            }
            if serviceRestartGrants.contains(model.directory) {
                return await restartNow(model.directory, service: service)
            }
            let id = AppRequest.makeID("svc")
            if pendingServiceRestarts.count >= 16, let oldest = pendingServiceRestarts.keys.sorted().first { pendingServiceRestarts[oldest] = nil }
            pendingServiceRestarts[id] = PendingServiceRestart(sessionID: caller, projectDirectory: model.directory, service: service)
            let request = AppRequest(
                id: AppRequest.makeID("svr"), sessionID: caller,
                kind: .approval(AppApproval(
                    action: .serviceRestart, title: "Restart the service “\(service)”",
                    detail: "Service: \(service)\nProject: \(model.directory)\nThe container restarts (recreated if its definition changed); its data volumes are kept.",
                    scope: model.directory, subjectID: id, allowsAlways: true, digest: SHA256Hex.of(model.directory + "\n" + service))),
                received: .now)
            await core.putAppRequest(request)
            return ClientMCPResult(text: "Asked the user to approve restarting “\(service)” (a card shows it). If they allow it, it restarts and you are woken with the result. End your turn now.")
        default:
            return .error("Unknown tool \(call.tool).")
        }
    }

    private func restartNow(_ directory: String, service: String) async -> ClientMCPResult {
        do {
            try await environments.restartService(directory, name: service)
            let state = environments.environment(for: directory).services.first { $0.name == service }
            return ClientMCPResult(text: "Restarted “\(service)”: \(state?.label ?? "unknown state").")
        } catch {
            return .error("Could not restart “\(service)”: \(EnvironmentService.describe(error))")
        }
    }

    /// The person answered a restart card.
    func answerServiceRestart(_ approval: AppApproval, approved: Bool, always: Bool) async {
        guard let pending = pendingServiceRestarts.removeValue(forKey: approval.subjectID),
              approval.digest == SHA256Hex.of(pending.projectDirectory + "\n" + pending.service) else { return }
        let text: String
        if approved {
            if always {
                try? await store.setGrant(.serviceRestart, scope: pending.projectDirectory, granted: true)
                serviceRestartGrants.insert(pending.projectDirectory)
            }
            text = "[BelloCode service] " + (await restartNow(pending.projectDirectory, service: pending.service)).text
        } else {
            text = "[BelloCode service] The user did not allow restarting “\(pending.service)”. It keeps running as it is; do not retry the same restart."
        }
        try? await core.postSynthetic(
            pending.sessionID, text: text, metadata: .object(["bellocode": .object(["wake": .string("service"), "outcome": .string(approved ? "restarted" : "declined")])]))
    }

    private func loadServiceRestartGrants() async {
        guard !serviceRestartGrantsLoaded else { return }
        serviceRestartGrantsLoaded = true
        serviceRestartGrants.formUnion((try? await store.grants(.serviceRestart)) ?? [])
    }
}
