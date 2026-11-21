import BelloCore
import ContainerKit
import Foundation

/// Where a project's services are defined.
public enum ServicesSource: Sendable, Equatable {
    case none
    /// A checked-in compose file in the project folder (its path).
    case file(String)
    /// The Environment pane (`ProjectEnvironmentSettings.servicesYAML`).
    case pane
}

/// One service as the Services section and the agent tools show it. Status is glyph + word.
public struct ServiceState: Sendable, Equatable, Identifiable {
    public enum Phase: String, Sendable, Equatable {
        case notStarted, pulling, starting, running, stopped, failed, blocked, refused
    }

    public var name: String
    public var image: String
    public var ports: [Int]
    public var phase: Phase
    /// `starting`, `healthy` or `unhealthy` when the service has a healthcheck.
    public var health: String?
    public var containerID: String?
    /// Why it failed, is blocked or refused.
    public var message: String?
    public var outdated: Bool
    public var id: String { name }

    public init(name: String, image: String, ports: [Int] = [], phase: Phase = .notStarted, health: String? = nil, containerID: String? = nil,
                message: String? = nil, outdated: Bool = false) {
        self.name = name
        self.image = image
        self.ports = ports
        self.phase = phase
        self.health = health
        self.containerID = containerID
        self.message = message
        self.outdated = outdated
    }

    public var label: String {
        switch phase {
        case .notStarted: "Not started"
        case .pulling: "Pulling"
        case .starting: "Starting"
        case .running:
            switch health {
            case "healthy"?: "Healthy"
            case "unhealthy"?: "Unhealthy"
            case "starting"?: "Checking health"
            default: "Running"
            }
        case .stopped: "Stopped"
        case .failed: "Failed"
        case .blocked: "Waiting"
        case .refused: "Refused"
        }
    }

    public var symbolName: String {
        switch phase {
        case .running: health == "unhealthy" ? "exclamationmark.triangle" : health == "starting" ? "arrow.triangle.2.circlepath" : "checkmark.circle"
        case .starting, .pulling: "arrow.triangle.2.circlepath"
        case .notStarted, .stopped: "pause.circle"
        case .failed, .refused: "xmark.octagon"
        case .blocked: "hourglass"
        }
    }

    public var tone: EnvironmentTone {
        switch phase {
        case .running: health == "unhealthy" ? .warning : health == "starting" ? .info : .success
        case .starting, .pulling: .info
        case .notStarted, .stopped: .neutral
        case .failed, .refused: .danger
        case .blocked: .warning
        }
    }
}

/// A service port forwarded to the Mac's loopback.
public struct ServiceForwardInfo: Sendable, Equatable, Identifiable {
    public var service: String
    public var port: Int
    public var url: URL
    public var id: String { "\(service):\(port)" }
}

/// Project services ("Rancher workloads", docs/features/containers.md "Services"): supporting containers (databases,
/// caches, queues) on the project's own network, reachable from the workspace by service name, never published. Defined
/// by a checked-in compose file (supported subset, `ComposeParser`) or, without one, in the Environment pane. They start
/// with the workspace (dependency order, healthcheck gating), stop with it when idle, are recreated when their
/// definition changes, and their volumes are deleted only by the explicit, confirmed "Delete Service Data…".
extension EnvironmentService {
    /// Reads the definition (compose file first, else the pane's) and updates the model's list. Cheap: a file read.
    @discardableResult
    func loadServices(_ model: ProjectEnvironment) -> ComposeParseResult? {
        var source = ServicesSource.none
        var text: String?
        // The file is read and parsed only when its size or modification date changed (a stat otherwise), so refreshes
        // on the main actor stay cheap.
        for name in ComposeParser.fileNames {
            let path = (model.directory as NSString).appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            let stamp = "\(path)|\((attributes[.size] as? NSNumber)?.intValue ?? -1)|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            source = .file(path)
            if let cached = servicesDefinitionCache[model.directory], cached.stamp == stamp {
                text = cached.text
            } else if let data = FileManager.default.contents(atPath: path), data.count <= 1 << 20 {
                text = String(decoding: data, as: UTF8.self)
                servicesDefinitionCache[model.directory] = (stamp, text ?? "")
            }
            break
        }
        if case .none = source, let yaml = model.settings.servicesYAML, !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = .pane
            text = yaml
        }
        if model.servicesSource != source { model.servicesSource = source }
        guard let text else {
            if model.servicesParse != nil { model.servicesParse = nil }
            if !model.services.isEmpty { model.services = [] }
            return nil
        }
        let parse: ComposeParseResult
        if let cached = servicesParseCache[model.directory], cached.text == text {
            parse = cached.parse
        } else {
            parse = ComposeParser.parse(text)
            servicesParseCache[model.directory] = (text, parse)
        }
        if model.servicesParse != parse { model.servicesParse = parse }
        var states: [ServiceState] = []
        for service in parse.services {
            var state = model.services.first { $0.name == service.name } ?? ServiceState(name: service.name, image: service.image)
            state.image = service.image
            state.ports = service.ports.map(\.containerPort)
            if let refusal = imageRefusal(service.image) {
                state.phase = .refused
                state.message = refusal
            } else if state.phase == .refused {
                state.phase = .notStarted
                state.message = nil
            }
            states.append(state)
        }
        for name in parse.refusedServices where !states.contains(where: { $0.name == name }) {
            let reasons = parse.rejected.filter { $0.path.hasPrefix("services.\(name).") || $0.path == "services.\(name)" }.map(\.reason)
            states.append(ServiceState(name: name, image: "", phase: .refused, message: reasons.joined(separator: "; ")))
        }
        if model.services != states { model.services = states }
        return parse
    }

    /// The containers to run (services refused by the file or the image policy are left out).
    func serviceSpecs(_ model: ProjectEnvironment) -> [ServiceSpec] {
        guard let parse = model.servicesParse else { return [] }
        let network = ServiceLabels.networkName(projectKey: model.projectKey, offline: model.settings.network == .none)
        let runnable = parse.services.filter { imageRefusal($0.image) == nil }
        let names = Set(runnable.map(\.name))
        // A service whose dependency was refused cannot start either.
        return runnable.filter { $0.dependsOn.allSatisfy { names.contains($0.service) } }
            .map { ServiceSpec(projectRoot: model.directory, definition: $0, network: network) }
    }

    /// The project's service network when it declares services (the workspace joins it).
    func serviceNetwork(_ model: ProjectEnvironment) -> String? {
        // BelloCode's own services belong to a project container; elsewhere the project's compose runs through the
        // filtered Docker endpoint instead.
        guard mode(for: model) == .projectContainer else { return nil }
        guard let parse = model.servicesParse, !parse.services.isEmpty else { return nil }
        return ServiceLabels.networkName(projectKey: model.projectKey, offline: model.settings.network == .none)
    }

    /// Starts (or updates) the project's services: pulls missing images under the image policy, then starts them in
    /// dependency order. Owned by the service; a newer start replaces an older one.
    func startServices(_ model: ProjectEnvironment) {
        guard isEnabled, runtime?.isReady == true, policyBlock(model) == nil, mode(for: model) == .projectContainer else { return }
        loadServices(model)
        let specs = serviceSpecs(model)
        guard !specs.isEmpty || model.services.contains(where: { $0.containerID != nil }) else { return }
        let runtimeRef = activeRuntime
        let key = model.projectKey
        var auths: [String: RegistryAuth] = [:]
        for image in Set(specs.map(\.definition.image)) { auths[image] = registryAuth(for: image) }
        let pullPolicy = imagePolicy.pullPolicy
        let authsForPull = auths
        tasks.set("services-\(key)", Task { [weak self] in
            // Images first (the policy decided which may run; the pull policy decides when to fetch).
            var failedPulls: [String: String] = [:]
            for image in Set(specs.map(\.definition.image)).sorted() {
                let present = (try? await runtimeRef.image(image)) != nil
                guard pullPolicy == .always || !present else { continue }
                if pullPolicy == .never {
                    if !present { failedPulls[image] = "The image \(image) is not on this Mac and the image policy does not allow pulling." }
                    continue
                }
                await MainActor.run {
                    for index in model.services.indices where model.services[index].image == image { model.services[index].phase = .pulling }
                }
                do {
                    try await runtimeRef.pull(image, auth: authsForPull[image]) { _ in }
                    await MainActor.run { self?.recordPulled(image) }
                } catch {
                    failedPulls[image] = "Pulling \(image) failed (\(EnvironmentService.describe(error)))."
                }
            }
            let runnable = specs.filter { failedPulls[$0.definition.image] == nil }
            for spec in specs where failedPulls[spec.definition.image] != nil {
                let message = failedPulls[spec.definition.image]
                await MainActor.run { self?.setService(model, spec.name) { $0.phase = .failed; $0.message = message } }
            }
            do {
                _ = try await runtimeRef.ensureServices(runnable, projectKey: key) { name, outcome in
                    Task { @MainActor in
                        self?.setService(model, name) { state in
                            switch outcome {
                            case nil: state.phase = .starting; state.message = nil
                            case .running?: state.phase = .running; state.message = nil
                            case .failed(let message)?: state.phase = .failed; state.message = message
                            case .blocked(let message)?: state.phase = .blocked; state.message = message
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run { model.lastError = "Services could not start: \(EnvironmentService.describe(error))" }
            }
            guard let self, !Task.isCancelled else { return }
            await self.refreshServices(model.directory)
            self.egress?.servicesStarted(model)
        })
    }

    func setService(_ model: ProjectEnvironment, _ name: String, _ change: (inout ServiceState) -> Void) {
        guard let index = model.services.firstIndex(where: { $0.name == name }) else { return }
        var state = model.services[index]
        change(&state)
        if state != model.services[index] { model.services[index] = state }
    }

    /// Reads where each service stands (state, health, outdated) from the runtime.
    public func refreshServices(_ directory: String) async {
        let model = environment(for: directory)
        loadServices(model)
        guard isEnabled, runtime?.isReady == true else { return }
        let specs = serviceSpecs(model)
        guard let statuses = try? await activeRuntime.serviceStatus(projectKey: model.projectKey, specs: specs) else { return }
        for index in model.services.indices {
            var state = model.services[index]
            guard state.phase != .refused else { continue }
            if let status = statuses[state.name] {
                state.containerID = status.containerID
                state.health = status.health
                state.outdated = status.outdated
                switch status.state {
                case "running": if state.phase != .blocked { state.phase = .running }
                case "created", "restarting": state.phase = .starting
                default:
                    if state.phase != .failed && state.phase != .blocked {
                        state.phase = .stopped
                        if let code = status.exitCode, code != 0 { state.message = "exited with \(code)" }
                    }
                }
            } else if state.phase == .running || state.phase == .starting {
                state.phase = .notStarted
                state.containerID = nil
            }
            if state != model.services[index] { model.services[index] = state }
        }
    }

    /// Re-reads the definition and starts what changed (Environment pane "Reload", a saved definition).
    public func reloadServices(_ directory: String) {
        let model = environment(for: directory)
        loadServices(model)
        scheduleConfigWrite()
        if model.phase == .ready { startServices(model) }
    }

    /// Restarts one service (recreates it if its definition changed). Starts it when it is not running.
    public func restartService(_ directory: String, name: String) async throws {
        let model = environment(for: directory)
        loadServices(model)
        guard let spec = serviceSpecs(model).first(where: { $0.name == name }) else {
            throw EnvironmentBlockedError(message: model.services.first { $0.name == name }?.message.map { "“\(name)” cannot run: \($0)" }
                ?? "This project has no service named “\(name)”.")
        }
        if let id = model.services.first(where: { $0.name == name })?.containerID, model.services.first(where: { $0.name == name })?.outdated == false {
            try await activeRuntime.restart(container: id)
        } else {
            _ = try await activeRuntime.ensureServices([spec], projectKey: model.projectKey) { _, _ in }
        }
        model.lastActivity = Date()
        await refreshServices(directory)
    }

    /// Stops the project's services (idle stop, Stop in the pane). Their volumes and containers stay.
    func stopServices(_ model: ProjectEnvironment) {
        guard isEnabled, !model.services.isEmpty else { return }
        for (id, forwarder) in serviceForwarders.removeValue(forKey: model.directory) ?? [:] {
            forwarder.stop()
            tasks.cancel("svcforward-\(model.projectKey)-\(id)")
        }
        model.serviceForwards = []
        let runtimeRef = activeRuntime
        let key = model.projectKey
        tasks.set("services-\(key)", Task { [weak self] in
            try? await runtimeRef.stopServices(projectKey: key)
            await self?.refreshServices(model.directory)
        })
    }

    /// What "Delete Service Data…" would delete: the service's existing named volumes.
    public func serviceDataToDelete(_ directory: String, name: String) async throws -> [String] {
        let model = environment(for: directory)
        guard let definition = model.servicesParse?.services.first(where: { $0.name == name }) else { return [] }
        return try await activeRuntime.serviceVolumes(projectKey: model.projectKey, service: definition)
    }

    /// The explicit destructive action: removes the service's container and exactly the confirmed volumes.
    public func deleteServiceData(_ directory: String, name: String, confirmed volumes: [String]) async throws {
        let model = environment(for: directory)
        try await activeRuntime.deleteServiceData(projectKey: model.projectKey, service: name, volumes: volumes)
        setService(model, name) { $0.containerID = nil; $0.phase = .notStarted; $0.health = nil }
        await refreshServices(directory)
    }

    /// The service's recent output, bounded (display and the agent's `service_logs`). Never logged.
    public func serviceLogs(_ directory: String, name: String, tail: Int = 200, limit: Int = 32 * 1024) async throws -> (text: String, truncated: Bool) {
        let model = environment(for: directory)
        await refreshServices(directory)
        guard let id = model.services.first(where: { $0.name == name })?.containerID else {
            throw EnvironmentBlockedError(message: "“\(name)” has no container yet (it starts with the project's container).")
        }
        return try await activeRuntime.serviceLogs(container: id, tail: min(max(tail, 1), 2000), limit: limit)
    }

    /// Forwards a service port to the Mac's loopback (a relay in the workspace container connects to the service by
    /// name; nothing is published) and returns its URL for the built-in browser.
    @discardableResult
    public func forwardService(_ directory: String, name: String, port: Int) throws -> URL {
        let model = environment(for: directory)
        if let existing = model.serviceForwards.first(where: { $0.service == name && $0.port == port }) { return existing.url }
        guard model.phase == .ready, let id = model.record.containerID, let spec = workspaceSpec(model) else {
            throw EnvironmentBlockedError(message: "The project's container is not running; services are reached through it.")
        }
        let forwarder: PortForwarder
        do {
            forwarder = try activeRuntime.makeServiceForwarder(workspace: id, service: name, port: port, hostPort: port, user: spec.user)
        } catch {
            forwarder = try activeRuntime.makeServiceForwarder(workspace: id, service: name, port: port, hostPort: 0, user: spec.user)
        }
        let forwardID = "\(name):\(port)"
        serviceForwarders[model.directory, default: [:]][forwardID] = forwarder
        tasks.set("svcforward-\(model.projectKey)-\(forwardID)", Task { await forwarder.run() })
        model.serviceForwards.append(ServiceForwardInfo(service: name, port: port, url: forwarder.url))
        model.lastActivity = Date()
        return forwarder.url
    }

    public func stopServiceForward(_ directory: String, name: String, port: Int) {
        let model = environment(for: directory)
        let forwardID = "\(name):\(port)"
        serviceForwarders[model.directory]?.removeValue(forKey: forwardID)?.stop()
        tasks.cancel("svcforward-\(model.projectKey)-\(forwardID)")
        model.serviceForwards.removeAll { $0.id == forwardID }
    }
}
