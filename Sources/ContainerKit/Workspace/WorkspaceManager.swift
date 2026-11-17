import Foundation
import os

/// The workspace container of one project: what exists and whether it matches the current setting.
public struct WorkspaceStatus: Sendable, Equatable {
    public enum Phase: String, Sendable { case absent, stopped, running, outdated }
    public var phase: Phase
    public var containerID: String?
    public var imageID: String?
    /// Published container port → host loopback port.
    public var ports: [Int: Int]
}

private let signposter = OSSignposter(subsystem: "app.bellocode.ContainerKit", category: "workspace")

/// Lifecycle of workspace containers: create on first use, start, rebuild when the image or setting changed, stop when
/// idle, remove with the project. Every resource is found by label, never by name alone.
public struct WorkspaceManager: Sendable {
    public let client: EngineClient

    public init(client: EngineClient) { self.client = client }

    public func status(_ spec: WorkspaceSpec) async throws -> WorkspaceStatus {
        let image = try await client.inspectImage(spec.image)
        guard let summary = try await client.listContainers(labels: [
            "\(WorkspaceSpec.labelWorkspace)=1", "\(WorkspaceSpec.labelProject)=\(spec.projectRoot)",
        ]).first, let inspect = try await client.inspectContainer(summary.id) else {
            return WorkspaceStatus(phase: .absent, containerID: nil, imageID: image?.id, ports: [:])
        }
        let current = inspect.config.labels?[WorkspaceSpec.labelConfig]
        let phase: WorkspaceStatus.Phase =
            current != spec.configHash(imageID: image?.id) ? .outdated : inspect.state.running ? .running : .stopped
        var ports: [Int: Int] = [:]
        for (key, bindings) in inspect.ports ?? [:] {
            guard let port = Int(key.split(separator: "/").first ?? ""), let host = bindings?.first.flatMap({ Int($0.hostPort) }) else { continue }
            ports[port] = host
        }
        return WorkspaceStatus(phase: phase, containerID: inspect.id, imageID: image?.id, ports: ports)
    }

    /// Makes sure the container exists, matches the setting and runs. Returns its ID.
    /// `pull` decides whether a missing image may be pulled (the UI shows progress through `progress`).
    @discardableResult
    public func ensureRunning(_ spec: WorkspaceSpec, pull: Bool = true,
                              progress: @Sendable (ProgressMessage) -> Void = { _ in }) async throws -> String {
        let state = signposter.beginInterval("ensureRunning")
        defer { signposter.endInterval("ensureRunning", state) }
        var status = try await status(spec)
        if status.imageID == nil {
            guard pull else { throw EngineError.notFound("image \(spec.image) is not present") }
            try await client.pullImage(spec.image, progress: progress)
            status = try await self.status(spec)
        }
        switch status.phase {
        case .running:
            return status.containerID!
        case .stopped:
            try await client.startContainer(status.containerID!)
            return status.containerID!
        case .outdated:
            try await client.removeContainer(status.containerID!, force: true)
            fallthrough
        case .absent:
            for cache in Array(spec.caches.keys) + ["home"] {
                // Idempotent: creating an existing volume with the same name succeeds.
                try await client.createVolume(name: spec.volumeName(cache), labels: [
                    WorkspaceSpec.labelWorkspace: "1", WorkspaceSpec.labelProject: spec.projectRoot,
                ].merging(spec.extraLabels) { a, _ in a })
            }
            var body = spec.createBody(imageID: status.imageID)
            body.labels?[WorkspaceSpec.labelConfig] = spec.configHash(imageID: status.imageID)
            let id: String
            do {
                id = try await client.createContainer(name: spec.containerName, body)
            } catch EngineError.conflict {
                // A container with our name but not our labels: never adopt or delete it silently.
                throw EngineError.conflict("a container named \(spec.containerName) exists and is not BelloCode's workspace")
            }
            try await client.startContainer(id)
            try await prepareHome(id, spec: spec)
            return id
        }
    }

    /// Creates $HOME for the non-root user (a fresh volume belongs to root). Runs as root, issued by BelloCode only.
    func prepareHome(_ id: String, spec: WorkspaceSpec) async throws {
        let exec = try await client.createExec(id, ExecConfig(
            cmd: ["/bin/sh", "-c", "mkdir -p \"$HOME\" /tmp/.bellocode && chown \(spec.user) \"$HOME\" && chmod 1777 /tmp/.bellocode"],
            user: "0:0"))
        let connection = try await client.startExec(exec, tty: false)
        while try await !connection.readRaw().isEmpty {}
        connection.cancel()
        let result = try await client.inspectExec(exec)
        if result.exitCode != 0 { throw EngineError.http(status: 500, message: "preparing $HOME failed (\(result.exitCode ?? -1))") }
    }

    public func stop(_ spec: WorkspaceSpec) async throws {
        if let id = try await status(spec).containerID { try await client.stopContainer(id, timeout: 3) }
    }

    /// Removes the container and, if asked, its caches (project removal).
    public func remove(_ spec: WorkspaceSpec, caches: Bool) async throws {
        if let id = try await status(spec).containerID { try await client.removeContainer(id, force: true) }
        if caches {
            for name in try await client.listVolumes(labels: ["\(WorkspaceSpec.labelProject)=\(spec.projectRoot)"]) {
                try await client.removeVolume(name, force: true)
            }
        }
    }
}
