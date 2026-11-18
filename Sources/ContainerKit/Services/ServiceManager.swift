import CryptoKit
import Foundation
import os

private let signposter = OSSignposter(subsystem: "app.bellocode.ContainerKit", category: "services")

/// Labels and names of BelloCode's project services ("Rancher workloads", docs/features/containers.md "Services").
public enum ServiceLabels {
    /// Marks a service container; the value is the service name.
    public static let service = "app.bellocode.service"
    /// Marks a project's service network.
    public static let network = "app.bellocode.network"
    /// Marks a service's named volume; the value is the compose volume name.
    public static let volume = "app.bellocode.service-volume"

    /// The project's network: user-defined (DNS by service name), never published. An offline project's network is
    /// internal (no route out), so the workspace and its services stay offline together.
    public static func networkName(projectKey: String, offline: Bool) -> String {
        "bellocode-net-\(projectKey)" + (offline ? "-offline" : "")
    }

    public static func containerName(projectKey: String, service: String) -> String { "bellocode-svc-\(projectKey)-\(service)" }
    public static func volumeName(projectKey: String, volume: String) -> String { "bellocode-\(projectKey)-svc-\(volume)" }
}

/// Everything that decides one service container (its definition plus the project's network and limits). Like the
/// workspace, it is found by label and recreated when this changes (config hash label).
public struct ServiceSpec: Sendable, Equatable {
    public var projectRoot: String
    public var definition: ServiceDefinition
    public var network: String
    public var resources: ResourceLimits
    public var extraLabels: [String: String]
    /// Enterprise certificates and proxy variables (Corporate network); the stack's or project's service names are
    /// added to `NO_PROXY` (`siblings`).
    public var corporateNetwork: CorporateNetwork?
    public var siblings: [String] = []

    public static let defaultResources = ResourceLimits(cpus: 1, memoryBytes: 1 << 30, pidsLimit: 1024)

    public init(projectRoot: String, definition: ServiceDefinition, network: String, resources: ResourceLimits = ServiceSpec.defaultResources,
                extraLabels: [String: String] = [:]) {
        self.projectRoot = projectRoot
        self.definition = definition
        self.network = network
        self.resources = resources
        self.extraLabels = extraLabels
    }

    public var projectKey: String { WorkspaceSpec.projectKey(for: projectRoot) }
    public var name: String { definition.name }
    public var containerName: String { ServiceLabels.containerName(projectKey: projectKey, service: name) }
    public func volumeName(_ volume: String) -> String { ServiceLabels.volumeName(projectKey: projectKey, volume: volume) }

    public var labels: [String: String] {
        [ServiceLabels.service: name, WorkspaceSpec.labelProject: projectRoot, WorkspaceSpec.labelProjectKey: projectKey,
         WorkspaceSpec.labelImage: definition.image].merging(extraLabels) { a, _ in a }
    }

    /// The create body. Services keep their image's user and its default capabilities (databases change users at
    /// start), but never privileges: no extra capabilities, no devices, `no-new-privileges`, limits, the project's
    /// network only (DNS alias = the service name), and nothing published on the Mac.
    public func createBody(imageID: String?) -> ContainerCreate {
        var body = ContainerCreate(image: imageID ?? definition.image)
        if let command = definition.command { body.cmd = command }
        body.env = definition.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        body.labels = labels
        body.hostname = name
        body.stopTimeout = 10
        if let check = definition.healthcheck {
            func ns(_ seconds: Double?) -> Int64? { seconds.map { Int64($0 * 1_000_000_000) } }
            body.healthcheck = HealthConfig(test: check.test, interval: ns(check.intervalSeconds), timeout: ns(check.timeoutSeconds),
                                            startPeriod: ns(check.startPeriodSeconds), retries: check.retries)
        }
        var host = HostConfig()
        host.init_ = true
        host.privileged = false
        host.securityOpt = ["no-new-privileges:true"]
        host.nanoCPUs = Int64(resources.cpus * 1_000_000_000)
        host.memory = resources.memoryBytes
        host.pidsLimit = resources.pidsLimit
        host.networkMode = network
        host.mounts = definition.volumes.map { Mount(type: .volume, source: volumeName($0.name), target: $0.target, readOnly: $0.readOnly ? true : nil) }
        body.hostConfig = host
        body.networkingConfig = NetworkingConfig(endpointsConfig: [network: .init(aliases: [name])])
        corporateNetwork?.apply(to: &body, noProxyExtra: siblings)
        return body
    }

    public func configHash(imageID: String?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(createBody(imageID: imageID))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

/// Where one service stands.
public struct ServiceStatus: Sendable, Equatable {
    public var name: String
    public var containerID: String?
    /// Docker's state (`running`, `exited`, `created`, …), or `absent`.
    public var state: String
    /// `starting`, `healthy` or `unhealthy` when the service has a healthcheck.
    public var health: String?
    public var exitCode: Int?
    /// The container's config hash no longer matches the definition (recreated on next start).
    public var outdated: Bool

    public init(name: String, containerID: String? = nil, state: String = "absent", health: String? = nil, exitCode: Int? = nil, outdated: Bool = false) {
        self.name = name
        self.containerID = containerID
        self.state = state
        self.health = health
        self.exitCode = exitCode
        self.outdated = outdated
    }

    public var isRunning: Bool { state == "running" }
}

/// How starting one service ended.
public enum ServiceOutcome: Sendable, Equatable {
    case running
    case failed(String)
    /// Not started because a dependency did not reach its condition.
    case blocked(String)
}

/// Lifecycle of a project's service containers: its network, start in dependency order with healthcheck gating,
/// recreate on change, remove services no longer defined (never their volumes), stop, restart, logs, and the explicit
/// removal of a service's volumes. Found by label, never by name alone.
public struct ServiceManager: Sendable {
    public let client: EngineClient
    /// How often health is polled while a dependant waits.
    public var pollInterval: Duration = .milliseconds(500)

    public init(client: EngineClient) { self.client = client }

    static func projectFilter(_ projectKey: String) -> [String] { [ServiceLabels.service, "\(WorkspaceSpec.labelProjectKey)=\(projectKey)"] }

    /// Creates the project's network if it does not exist. Idempotent; a concurrent creator's network is adopted.
    @discardableResult
    public func ensureNetwork(projectRoot: String, offline: Bool, extraLabels: [String: String] = [:]) async throws -> String {
        let key = WorkspaceSpec.projectKey(for: projectRoot)
        let name = ServiceLabels.networkName(projectKey: key, offline: offline)
        if try await client.inspectNetwork(name) != nil { return name }
        let labels = [ServiceLabels.network: "1", WorkspaceSpec.labelProject: projectRoot, WorkspaceSpec.labelProjectKey: key]
            .merging(extraLabels) { a, _ in a }
        do {
            _ = try await client.createNetwork(name: name, labels: labels, isInternal: offline)
        } catch ContainerError.conflict {
            // Created meanwhile by the helper or another window.
        }
        return name
    }

    /// Every service container of the project with its state and health.
    public func status(projectKey: String, specs: [ServiceSpec] = [], imageIDs: [String: String] = [:]) async throws -> [String: ServiceStatus] {
        var result: [String: ServiceStatus] = [:]
        for summary in try await client.listContainers(labels: Self.projectFilter(projectKey)) {
            guard let name = summary.labels[ServiceLabels.service] else { continue }
            let inspect = try await client.inspectContainer(summary.id)
            var outdated = false
            if let spec = specs.first(where: { $0.name == name }) {
                outdated = summary.labels[WorkspaceSpec.labelConfig] != spec.configHash(imageID: imageIDs[spec.definition.image])
            }
            result[name] = ServiceStatus(
                name: name, containerID: summary.id, state: inspect?.state.status ?? summary.state, health: inspect?.state.health?.status,
                exitCode: inspect?.state.exitCode, outdated: outdated)
        }
        return result
    }

    /// Starts the project's services in dependency order. A service whose dependency must be `healthy` waits for it
    /// (bounded by the dependency's healthcheck timing); a dependency that fails, turns unhealthy or exits blocks its
    /// dependants (reported, never retried silently). Services of the project that are no longer defined are removed
    /// (their volumes stay). `progress` reports each service as it changes (any thread).
    public func ensure(_ specs: [ServiceSpec], projectKey: String,
                       progress: @Sendable (String, ServiceOutcome?) -> Void = { _, _ in }) async throws -> [String: ServiceOutcome] {
        let state = signposter.beginInterval("services.ensure")
        defer { signposter.endInterval("services.ensure", state) }
        let byName = Dictionary(specs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let layers: [[String]]
        do { layers = try ComposeParser.startOrder(specs.map(\.definition)) } catch { throw ContainerError.http(status: 400, message: error.description) }
        // Orphans: services no longer defined.
        for summary in try await client.listContainers(labels: Self.projectFilter(projectKey)) {
            if let name = summary.labels[ServiceLabels.service], byName[name] == nil {
                try? await client.removeContainer(summary.id, force: true)
            }
        }
        var outcomes: [String: ServiceOutcome] = [:]
        var containerIDs: [String: String] = [:]
        for layer in layers {
            for name in layer {
                let spec = byName[name]!
                // Dependencies first: each must reach its condition.
                var blocked: String?
                for dependency in spec.definition.dependsOn {
                    guard let id = containerIDs[dependency.service], outcomes[dependency.service] == .running else {
                        blocked = "waiting for \(dependency.service), which did not start"
                        break
                    }
                    if let problem = await waitFor(dependency, container: id, spec: byName[dependency.service]) {
                        blocked = problem
                        break
                    }
                }
                if let blocked {
                    outcomes[name] = .blocked(blocked)
                    progress(name, .blocked(blocked))
                    continue
                }
                progress(name, nil)
                do {
                    containerIDs[name] = try await ensureOne(spec)
                    outcomes[name] = .running
                } catch {
                    outcomes[name] = .failed(ServiceManager.describe(error))
                }
                progress(name, outcomes[name])
            }
        }
        return outcomes
    }

    /// Why `dependency` did not reach its condition in time, or nil when it did.
    func waitFor(_ dependency: ServiceDefinition.Dependency, container: String, spec: ServiceSpec?) async -> String? {
        switch dependency.condition {
        case .started:
            return nil
        case .healthy:
            let limit = spec?.definition.healthcheck?.gateTimeoutSeconds ?? 120
            let deadline = ContinuousClock.now + .seconds(limit)
            while ContinuousClock.now < deadline {
                guard let inspect = try? await client.inspectContainer(container) else { return "\(dependency.service) disappeared" }
                if !inspect.state.running { return "\(dependency.service) stopped (exit \(inspect.state.exitCode ?? -1)) before it was healthy" }
                switch inspect.state.health?.status {
                case "healthy"?: return nil
                case "unhealthy"?: return "\(dependency.service) is unhealthy"
                case nil: return "\(dependency.service) has no healthcheck, so it can never be healthy (add one, or use service_started)"
                default: break
                }
                if Task.isCancelled { return "cancelled" }
                try? await Task.sleep(for: pollInterval)
            }
            return "\(dependency.service) was not healthy within \(Int(limit)) s"
        case .completed:
            let deadline = ContinuousClock.now + .seconds(300)
            while ContinuousClock.now < deadline {
                guard let inspect = try? await client.inspectContainer(container) else { return "\(dependency.service) disappeared" }
                if !inspect.state.running {
                    return inspect.state.exitCode == 0 ? nil : "\(dependency.service) exited with \(inspect.state.exitCode ?? -1)"
                }
                if Task.isCancelled { return "cancelled" }
                try? await Task.sleep(for: pollInterval)
            }
            return "\(dependency.service) did not finish within 300 s"
        }
    }

    /// Creates (or recreates when outdated) and starts one service. The image must be present (the app pulls, under
    /// the image policy).
    @discardableResult
    public func ensureOne(_ spec: ServiceSpec) async throws -> String {
        guard let image = try await client.inspectImage(spec.definition.image) else { throw WorkspaceError.imageMissing(spec.definition.image) }
        let hash = spec.configHash(imageID: image.id)
        let existing = try await client.listContainers(labels: [ServiceLabels.service + "=" + spec.name, "\(WorkspaceSpec.labelProjectKey)=\(spec.projectKey)"])
        if let current = existing.first {
            if current.labels[WorkspaceSpec.labelConfig] == hash {
                if !current.isRunning { try await client.startContainer(current.id) }
                return current.id
            }
            try await client.removeContainer(current.id, force: true)
        }
        for volume in Set(spec.definition.volumes.map(\.name)) {
            try await client.createVolume(name: spec.volumeName(volume), labels: [
                ServiceLabels.volume: volume, WorkspaceSpec.labelProject: spec.projectRoot, WorkspaceSpec.labelProjectKey: spec.projectKey,
            ].merging(spec.extraLabels) { a, _ in a })
        }
        var body = spec.createBody(imageID: image.id)
        body.labels?[WorkspaceSpec.labelConfig] = hash
        let id: String
        do {
            id = try await client.createContainer(name: spec.containerName, body)
        } catch ContainerError.conflict {
            // A container with the name exists but not with our labels for this project: never adopt or remove it.
            if let other = try await client.inspectContainer(spec.containerName), other.config.labels?[ServiceLabels.service] == spec.name,
               other.config.labels?[WorkspaceSpec.labelProjectKey] == spec.projectKey {
                try await client.removeContainer(other.id, force: true)
                return try await ensureOne(spec)
            }
            throw WorkspaceError.nameTaken(spec.containerName)
        }
        try await client.startContainer(id)
        return id
    }

    /// Stops every service of the project (idle stop, runtime shutdown).
    public func stopAll(projectKey: String) async throws {
        for summary in try await client.listContainers(labels: Self.projectFilter(projectKey)) where summary.isRunning {
            try await client.stopContainer(summary.id, timeout: 10)
        }
    }

    /// Removes the project's service containers (not their volumes).
    public func removeAll(projectKey: String) async throws {
        for summary in try await client.listContainers(labels: Self.projectFilter(projectKey)) {
            try await client.removeContainer(summary.id, force: true)
        }
    }

    /// The service's named volumes that exist (what "Delete Service Data…" lists).
    public func volumes(projectKey: String, service: ServiceDefinition) async throws -> [String] {
        let existing = Set(try await client.listVolumes(labels: [ServiceLabels.volume, "\(WorkspaceSpec.labelProjectKey)=\(projectKey)"]))
        return Set(service.volumes.map { ServiceLabels.volumeName(projectKey: projectKey, volume: $0.name) }).intersection(existing).sorted()
    }

    /// The explicit destructive action: removes the service's container, then exactly the listed volumes that still
    /// carry this project's service-volume label (a volume another service still mounts is refused by the daemon).
    public func deleteData(projectKey: String, service: String, volumes: [String]) async throws {
        for summary in try await client.listContainers(labels: [ServiceLabels.service + "=" + service, "\(WorkspaceSpec.labelProjectKey)=\(projectKey)"]) {
            try await client.removeContainer(summary.id, force: true)
        }
        let current = Set(try await client.listVolumes(labels: [ServiceLabels.volume, "\(WorkspaceSpec.labelProjectKey)=\(projectKey)"]))
        for volume in volumes where current.contains(volume) {
            try await client.removeVolume(volume)
        }
    }

    /// The last `tail` lines of the service's output, at most `limit` bytes (display and the agent's bounded read).
    public func logs(container: String, tail: Int, limit: Int = 64 * 1024) async throws -> (text: String, truncated: Bool) {
        var data = Data()
        var truncated = false
        for try await chunk in try await client.logs(container, follow: false, tail: String(tail)) {
            data.append(chunk.bytes)
            if data.count > limit {
                truncated = true
                data = data.suffix(limit)
            }
        }
        return (String(decoding: data, as: UTF8.self), truncated)
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? WorkspaceError { return error.description }
        return ContainerError.from(error).description
    }
}
