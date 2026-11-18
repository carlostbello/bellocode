import Foundation

/// What "Prune BelloCode Resources…" would remove, listed exactly before anything is removed
/// (docs/features/containers.md, "Housekeeping"). Only resources labelled as BelloCode's; never anything else on the
/// runtime.
public struct PrunePlan: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Hashable, Identifiable {
        /// The daemon's ID (containers, networks, images) or name (volumes).
        public var id: String
        public var name: String
        public var detail: String
        public init(id: String, name: String, detail: String) {
            self.id = id
            self.name = name
            self.detail = detail
        }
    }

    /// Stopped BelloCode containers (workspaces, services, leftover one-shot secret commands): recreated on next use.
    public var containers: [Item] = []
    /// BelloCode volumes no container uses that belong to no project BelloCode still has (shared caches are emptied
    /// from Settings ▸ Caches instead).
    public var volumes: [Item] = []
    /// BelloCode service networks no container is attached to.
    public var networks: [Item] = []
    /// Images BelloCode pulled (they were not on this Mac before) that no container uses.
    public var images: [Item] = []

    public init() {}

    public var isEmpty: Bool { count == 0 }
    public var count: Int { containers.count + volumes.count + networks.count + images.count }
}

public struct PruneResult: Sendable, Equatable {
    public var removed: [String] = []
    /// Items that were confirmed but changed since (started, used, relabelled) or that the daemon refused: kept.
    public var kept: [String] = []
    public init() {}
}

extension WorkspaceManager {
    /// Label keys that mark a BelloCode container.
    static let containerKinds = [WorkspaceSpec.labelWorkspace, ServiceLabels.service, WorkspaceSpec.labelSecretCommand]
    /// Label keys that mark a BelloCode volume.
    static let volumeKinds = [WorkspaceSpec.labelWorkspace, ServiceLabels.volume, PackageCache.volumeLabel]

    /// Lists what a prune would remove. `keepProjectKeys`: projects BelloCode still has (their unused volumes, such as
    /// a persistent home or service data, are kept); `pulledImageIDs`: images BelloCode pulled itself.
    public func prunePlan(keepProjectKeys: Set<String>, pulledImageIDs: Set<String>) async throws -> PrunePlan {
        var plan = PrunePlan()
        var seen = Set<String>()
        for kind in Self.containerKinds {
            for container in try await client.listContainers(labels: [kind]) where !seen.contains(container.id) {
                seen.insert(container.id)
                guard ["exited", "created", "dead"].contains(container.state) else { continue }
                let project = container.labels[WorkspaceSpec.labelProject].map { ($0 as NSString).lastPathComponent }
                let role = container.labels[ServiceLabels.service].map { "service \($0)" }
                    ?? (container.labels[WorkspaceSpec.labelSecretCommand] != nil ? "one-shot secret command" : "workspace")
                plan.containers.append(.init(id: container.id, name: container.name,
                                             detail: [project, role, container.status ?? container.state].compactMap { $0 }.joined(separator: " · ")))
            }
        }
        var volumeNames = Set<String>()
        for kind in Self.volumeKinds {
            for volume in try await client.listVolumeInfos(labels: [kind]) where !volumeNames.contains(volume.name) {
                volumeNames.insert(volume.name)
                if volume.labels[PackageCache.sharedLabel] == "1" { continue }
                if let key = volume.labels[WorkspaceSpec.labelProjectKey], keepProjectKeys.contains(key) { continue }
                guard try await client.listContainersUsing(volume: volume.name).isEmpty else { continue }
                let project = volume.labels[WorkspaceSpec.labelProject].map { ($0 as NSString).lastPathComponent } ?? "no project"
                plan.volumes.append(.init(id: volume.name, name: volume.name, detail: "\(project) (project no longer in BelloCode)"))
            }
        }
        for id in try await client.listNetworks(labels: [ServiceLabels.network]) {
            guard let network = try await client.inspectNetwork(id), network.containers.isEmpty,
                  network.labels[ServiceLabels.network] != nil else { continue }
            plan.networks.append(.init(id: network.id, name: network.name, detail: "no containers attached"))
        }
        if !pulledImageIDs.isEmpty {
            let inUse = Set(try await client.listContainers(labels: []).compactMap(\.imageID))
            for image in try await client.listImages() where pulledImageIDs.contains(image.id) && !inUse.contains(image.id) {
                let size = image.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "size unknown"
                plan.images.append(.init(id: image.id, name: image.repoTags.first ?? String(image.id.prefix(19)), detail: "pulled by BelloCode, unused · \(size)"))
            }
        }
        plan.containers.sort { $0.name < $1.name }
        plan.volumes.sort { $0.name < $1.name }
        plan.networks.sort { $0.name < $1.name }
        plan.images.sort { $0.name < $1.name }
        return plan
    }

    /// Removes exactly the confirmed items that still qualify now (the plan is computed again; anything that started,
    /// got used or lost its label since is kept). Containers first, then networks and volumes they held, then images.
    public func prune(_ confirmed: PrunePlan, keepProjectKeys: Set<String>, pulledImageIDs: Set<String>) async throws -> PruneResult {
        let current = try await prunePlan(keepProjectKeys: keepProjectKeys, pulledImageIDs: pulledImageIDs)
        var result = PruneResult()
        func run(_ confirmedItems: [PrunePlan.Item], _ currentItems: [PrunePlan.Item], _ remove: (PrunePlan.Item) async throws -> Void) async {
            let still = Set(currentItems.map(\.id))
            for item in confirmedItems {
                guard still.contains(item.id) else {
                    result.kept.append(item.name)
                    continue
                }
                do {
                    try await remove(item)
                    result.removed.append(item.name)
                } catch {
                    result.kept.append(item.name)
                }
            }
        }
        await run(confirmed.containers, current.containers) { try await client.removeContainer($0.id) }
        await run(confirmed.networks, current.networks) { try await client.removeNetwork($0.id) }
        await run(confirmed.volumes, current.volumes) { try await client.removeVolume($0.id) }
        await run(confirmed.images, current.images) { try await client.removeImage($0.id) }
        return result
    }
}
