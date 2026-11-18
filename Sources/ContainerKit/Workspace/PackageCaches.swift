import Foundation

/// Package-manager caches kept in named volumes across container rebuilds (docs/features/containers.md, "Caches").
/// Per project unless the person shares one cache across projects; declared by the project's setting or by the image
/// (labels), mounted at the image's expected path inside the container's home.
public enum PackageCache: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case npm, pnpm, pip, cargo, go, gradle, maven

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .npm: "npm"
        case .pnpm: "pnpm"
        case .pip: "pip"
        case .cargo: "Cargo"
        case .go: "Go modules"
        case .gradle: "Gradle"
        case .maven: "Maven"
        }
    }

    /// Where the tool keeps its cache for a user whose home is `WorkspaceSpec.home` (the tools' Linux defaults).
    public var defaultPath: String {
        let home = WorkspaceSpec.home
        switch self {
        case .npm: return home + "/.npm"
        case .pnpm: return home + "/.local/share/pnpm/store"
        case .pip: return home + "/.cache/pip"
        case .cargo: return home + "/.cargo/registry"
        case .go: return home + "/go/pkg/mod"
        case .gradle: return home + "/.gradle/caches"
        case .maven: return home + "/.m2/repository"
        }
    }

    /// Image label listing the caches an image wants (`npm,pnpm`).
    public static let imageLabel = "app.bellocode.caches"
    /// Image label overriding one cache's path (`app.bellocode.cache.npm=/opt/npm-cache`).
    public static func pathLabel(_ cache: PackageCache) -> String { "app.bellocode.cache.\(cache.rawValue)" }
    /// Marks a cache volume (value: the cache kind).
    public static let volumeLabel = "app.bellocode.cache"
    /// Marks a cache volume shared across projects.
    public static let sharedLabel = "app.bellocode.cache-shared"

    public static func volumeName(_ cache: PackageCache, projectKey: String?) -> String {
        projectKey.map { "bellocode-\($0)-cache-\(cache.rawValue)" } ?? "bellocode-shared-cache-\(cache.rawValue)"
    }

    /// The caches an image declares, with their paths (`imageLabel` plus optional `pathLabel` overrides).
    public static func declared(byImageLabels labels: [String: String]?) -> [PackageCache: String] {
        guard let labels else { return [:] }
        var result: [PackageCache: String] = [:]
        for name in (labels[imageLabel] ?? "").split(separator: ",") {
            guard let cache = PackageCache(rawValue: name.trimmingCharacters(in: .whitespaces).lowercased()) else { continue }
            result[cache] = labels[pathLabel(cache)].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? cache.defaultPath
        }
        for cache in PackageCache.allCases where result[cache] == nil {
            if let path = labels[pathLabel(cache)], path.hasPrefix("/") { result[cache] = path }
        }
        return result
    }
}

/// One cache volume mounted into a workspace container.
public struct CacheMount: Codable, Sendable, Equatable, Hashable {
    public var cache: PackageCache
    public var path: String
    /// Shared across projects (the person opted in for this cache); otherwise the project's own volume.
    public var shared: Bool

    public init(cache: PackageCache, path: String, shared: Bool = false) {
        self.cache = cache
        self.path = path
        self.shared = shared
    }

    public func volumeName(projectKey: String) -> String { PackageCache.volumeName(cache, projectKey: shared ? nil : projectKey) }

    /// Labels of the volume: a project cache carries the project's key (purged with the project); a shared one does not.
    public func volumeLabels(projectRoot: String, projectKey: String) -> [String: String] {
        shared
            ? [PackageCache.volumeLabel: cache.rawValue, PackageCache.sharedLabel: "1"]
            : [PackageCache.volumeLabel: cache.rawValue, WorkspaceSpec.labelWorkspace: "1", WorkspaceSpec.labelProject: projectRoot,
               WorkspaceSpec.labelProjectKey: projectKey]
    }
}

/// A cache volume as Settings lists it.
public struct CacheVolume: Sendable, Equatable, Identifiable {
    public var name: String
    public var cache: PackageCache?
    public var shared: Bool
    /// The project folder for a project cache.
    public var projectDirectory: String?
    public var size: Int64?
    /// Containers that use it (running or stopped), when known.
    public var users: Int?
    public var id: String { name }

    public init(name: String, cache: PackageCache?, shared: Bool, projectDirectory: String?, size: Int64?, users: Int?) {
        self.name = name
        self.cache = cache
        self.shared = shared
        self.projectDirectory = projectDirectory
        self.size = size
        self.users = users
    }

    public init(_ info: VolumeInfo) {
        self.init(name: info.name, cache: info.labels[PackageCache.volumeLabel].flatMap(PackageCache.init(rawValue:)),
                  shared: info.labels[PackageCache.sharedLabel] == "1", projectDirectory: info.labels[WorkspaceSpec.labelProject],
                  size: info.size, users: info.refCount)
    }
}

extension WorkspaceManager {
    /// Every cache volume BelloCode made, with sizes when the daemon reports them.
    public func cacheVolumes() async throws -> [CacheVolume] {
        let usage = Dictionary((try? await client.volumeUsage())?.map { ($0.name, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        return try await client.listVolumeInfos(labels: [PackageCache.volumeLabel]).map { info in
            CacheVolume(usage[info.name].map { used in VolumeInfo(name: info.name, labels: info.labels, size: used.size, refCount: used.refCount) } ?? info)
        }.sorted { ($0.shared ? 0 : 1, $0.projectDirectory ?? "", $0.name) < ($1.shared ? 0 : 1, $1.projectDirectory ?? "", $1.name) }
    }

    /// Empties a cache by deleting its volume (it is created again, empty, on the next container start). Stopped
    /// BelloCode workspace containers that mount it are removed first (they are recreated on next use); a running one
    /// makes this refuse, so no running command loses its cache mid-way. Only volumes labelled as caches.
    public func cleanCache(_ name: String) async throws {
        guard try await client.listVolumeInfos(labels: [PackageCache.volumeLabel]).contains(where: { $0.name == name }) else {
            throw ContainerError.notFound("\(name) is not a BelloCode cache")
        }
        let users = try await client.listContainersUsing(volume: name)
        if let running = users.first(where: \.isRunning) {
            throw ContainerError.conflict("the cache is in use by \(running.name), which is running; stop that project's container first")
        }
        for container in users {
            guard container.labels[WorkspaceSpec.labelWorkspace] == "1" else {
                throw ContainerError.conflict("the cache is mounted by \(container.name), which is not a BelloCode workspace")
            }
            try await client.removeContainer(container.id, force: true)
        }
        try await client.removeVolume(name)
    }
}

extension EngineClient {
    /// Containers (running or not) that mount `volume`.
    public func listContainersUsing(volume: String) async throws -> [ContainerSummary] {
        try decode([ContainerSummary].self, try await call(
            "GET", "/containers/json", query: [("all", "1"), ("filters", Self.filters(["volume": [volume]]))]))
    }
}
