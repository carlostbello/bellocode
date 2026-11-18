import CryptoKit
import Foundation
import os

private let signposter = OSSignposter(subsystem: "app.bellocode.ContainerKit", category: "mcp")

/// A stdio MCP server configured for every project, run from a container image: the equivalent of
/// `docker run -i --rm IMAGE ARGS` (docs/features/containers.md, "Global MCP servers"). Written by the app into the
/// helper's configuration (no secret values: secret variable *names* only; their values reach the helper in its own
/// environment from opencode's runtime registration, and the container through the create or exec request).
///
/// **No project folder is ever mounted.** Only `mounts` (explicit, listed with their access, off by default) and the
/// enterprise certificate bundle (read-only) are.
public struct ImageMCPSpec: Codable, Sendable, Equatable, Hashable {
    public enum Network: String, Codable, Sendable, CaseIterable, Hashable {
        /// Outbound access, nothing inbound.
        case bridge
        /// No network at all.
        case none
    }

    public var id: String
    public var name: String
    public var image: String
    public var entrypoint: [String]?
    public var args: [String]
    /// Non-secret variables.
    public var environment: [String: String]
    /// Variables whose values come from the helper's environment (opencode's registration; Keychain in the app).
    public var secretNames: [String]
    public var mounts: [UserMount]
    public var network: Network
    /// One long-lived container for every project; each connection is an exec in it (the image needs `/bin/sh`).
    public var shared: Bool
    public var resources: ResourceLimits
    /// Enterprise certificates and proxy variables (Corporate network), applied at creation.
    public var corporateNetwork: CorporateNetwork?
    public var extraLabels: [String: String]
    /// Set when the app knows the server cannot run (image refused by policy, not on this Mac, runtime down): the
    /// helper reports it instead of running.
    public var blocked: String?

    public static let defaultResources = ResourceLimits(cpus: 1, memoryBytes: 1 << 30, pidsLimit: 512)

    public init(id: String, name: String, image: String, entrypoint: [String]? = nil, args: [String] = [], environment: [String: String] = [:],
                secretNames: [String] = [], mounts: [UserMount] = [], network: Network = .bridge, shared: Bool = false,
                resources: ResourceLimits = ImageMCPSpec.defaultResources, corporateNetwork: CorporateNetwork? = nil,
                extraLabels: [String: String] = [:], blocked: String? = nil) {
        self.id = id
        self.name = name
        self.image = image
        self.entrypoint = entrypoint
        self.args = args
        self.environment = environment
        self.secretNames = secretNames
        self.mounts = mounts
        self.network = network
        self.shared = shared
        self.resources = resources
        self.corporateNetwork = corporateNetwork
        self.extraLabels = extraLabels
        self.blocked = blocked
    }

    /// Marks a global MCP server container; the value is the server's id.
    public static let label = "app.bellocode.mcp"
    /// `shared`, or the project key of the connection.
    public static let labelScope = "app.bellocode.mcp-scope"
    public static let sharedScope = "shared"

    /// `bellocode-mcp-<id>` (shared) or `bellocode-mcp-<id>-<projectKey>` (one connection of one project).
    public func containerName(scope: String?) -> String {
        "bellocode-mcp-\(id)" + (scope.map { "-\($0)" } ?? "")
    }

    public func labels(scope: String?) -> [String: String] {
        [Self.label: id, Self.labelScope: scope ?? Self.sharedScope, WorkspaceSpec.labelImage: image]
            .merging(extraLabels) { a, _ in a }
    }

    /// The program `docker run IMAGE ARGS` would start: the entrypoint (overridden or the image's) followed by the
    /// arguments, or the image's CMD when none are given and the entrypoint was not overridden.
    public func resolvedArgv(imageEntrypoint: [String]?, imageCmd: [String]?) -> [String] {
        let entry = entrypoint ?? imageEntrypoint ?? []
        let rest = !args.isEmpty ? args : (entrypoint != nil ? [] : imageCmd ?? [])
        return entry + rest
    }

    /// The keep-alive of a shared container (connections are execs in it).
    static let keepAlive = ["/bin/sh", "-c", "trap 'exit 0' TERM INT; while :; do sleep 3600 & wait $!; done", "bellocode-mcp"]

    /// The create body. `secrets` are set only for a per-connection container (`docker run -e`); a shared container
    /// gets them per exec instead, so they are never in its persisted configuration.
    public func createBody(imageID: String?, scope: String?, secrets: [String: String] = [:]) -> ContainerCreate {
        var body = ContainerCreate(image: imageID ?? image)
        var env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        if shared {
            body.entrypoint = Self.keepAlive
            body.cmd = []
        } else {
            body.entrypoint = entrypoint
            if !args.isEmpty { body.cmd = args }
            body.openStdin = true
            body.stdinOnce = true
            body.attachStdin = true
            body.attachStdout = true
            body.attachStderr = true
            env += secrets.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        }
        body.tty = false
        var host = HostConfig()
        host.init_ = true
        host.privileged = false
        host.capDrop = ["ALL"]
        host.securityOpt = ["no-new-privileges:true"]
        host.nanoCPUs = Int64(resources.cpus * 1_000_000_000)
        host.memory = resources.memoryBytes
        host.pidsLimit = resources.pidsLimit
        host.networkMode = network.rawValue
        // Only what the person listed, never a project folder.
        host.mounts = mounts.map { Mount(type: .bind, source: $0.path, target: $0.path, readOnly: $0.readOnly, createMountpoint: false) }
        body.env = env
        body.labels = labels(scope: scope)
        body.stopSignal = "SIGTERM"
        body.stopTimeout = 3
        body.hostConfig = host
        corporateNetwork?.apply(to: &body, noProxyExtra: [])
        return body
    }

    /// Hash of a shared container's configuration (no secrets in it), stored as a label: a change recreates it.
    public func configHash(imageID: String?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(createBody(imageID: imageID, scope: nil))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

/// A program relayed over stdin/stdout: an exec (`ExecSession`) or an attached container (`AttachSession`).
public protocol StdioSession: Sendable {
    func output() -> AsyncThrowingStream<OutputChunk, any Error>
    func write(_ data: Data) async throws
    /// End of input.
    func closeStdin()
    /// The program's exit code after its output ended.
    func exitCode() async throws -> Int
    func close()
}

extension ExecSession: StdioSession {}

/// A container started like `docker run -i --rm`: attached before it starts (no output is missed), stdin open once
/// (closing it ends the program's input), no TTY (bytes pass unchanged), removed when it ends.
public final class AttachSession: StdioSession {
    public let client: EngineClient
    public let containerID: String
    let connection: HTTPConnection

    init(client: EngineClient, containerID: String, connection: HTTPConnection) {
        self.client = client
        self.containerID = containerID
        self.connection = connection
    }

    public func output() -> AsyncThrowingStream<OutputChunk, any Error> {
        let connection = connection
        return EngineClient.outputStream(tty: false, next: {
            let data = try await connection.readRaw()
            return data.isEmpty ? nil : data
        }, cancel: {})
    }

    public func write(_ data: Data) async throws { try await connection.write(data) }
    public func closeStdin() { connection.closeWrite() }

    /// Waits for the container to stop, removes it, and returns its exit code.
    public func exitCode() async throws -> Int {
        let code = try await client.waitContainer(containerID)
        try? await client.removeContainer(containerID, force: true)
        return code
    }

    public func close() { connection.cancel() }

    /// Stops (TERM, KILL after 3 s) and removes the container: the helper was told to stop, or its reader went away.
    public func terminate() async {
        connection.cancel()
        try? await client.stopContainer(containerID, timeout: 3)
        try? await client.removeContainer(containerID, force: true)
    }
}

/// Why an image-based server could not start, phrased by what fixes it.
public enum ImageMCPError: Error, Sendable, Equatable, CustomStringConvertible {
    case imageMissing(String)
    case nameTaken(String)
    /// A shared container's keep-alive did not stay up (most likely no `/bin/sh` in the image).
    case sharedNeedsShell(String)
    case engine(ContainerError)

    public var description: String {
        switch self {
        case .imageMissing(let image): "the image \(image) is not on this Mac yet. Pull it in Settings ▸ MCP Servers."
        case .nameTaken(let name): "a container named \(name) exists and is not BelloCode's; rename or remove it."
        case .sharedNeedsShell(let image):
            "the image \(image) cannot run as a shared container (it has no /bin/sh to keep it running). Turn off “Share one container across projects” for this server."
        case .engine(let error): error.description
        }
    }
}

/// Starts image-based MCP servers (used by `bellocode-exec --stdio --mcp` and by the isolation self-check).
public struct ImageMCPRunner: Sendable {
    public let client: EngineClient

    public init(client: EngineClient) { self.client = client }

    /// Starts one connection of `spec`: a fresh container attached like `docker run -i --rm` (scope = the project's key),
    /// or an exec in the shared container. `secrets` go only into the create (per connection) or the exec (shared).
    /// Never pulls: a missing image is the app's to fetch, under the image policy.
    public func start(_ spec: ImageMCPSpec, scope: String?, secrets: [String: String], token: String) async throws -> any StdioSession {
        let state = signposter.beginInterval("mcp.start")
        defer { signposter.endInterval("mcp.start", state) }
        do {
            guard let image = try await client.inspectImage(spec.image) else { throw ImageMCPError.imageMissing(spec.image) }
            if spec.shared {
                let container = try await ensureShared(spec, imageID: image.id)
                let argv = spec.resolvedArgv(imageEntrypoint: image.entrypoint, imageCmd: image.cmd)
                return try await ExecSession.start(client: client, container: container, argv: StdioRelay.wrapper(token: token, argv),
                                                   workingDir: nil, environment: secrets, user: nil, tty: false)
            }
            let name = spec.containerName(scope: scope)
            if let existing = try await client.inspectContainer(name) {
                // A previous connection's container (its helper was killed): ours, so replace it.
                guard existing.config.labels?[ImageMCPSpec.label] == spec.id else { throw ImageMCPError.nameTaken(name) }
                try await client.removeContainer(existing.id, force: true)
            }
            let id = try await client.createContainer(name: name, spec.createBody(imageID: image.id, scope: scope, secrets: secrets))
            let connection: HTTPConnection
            do {
                connection = try await client.attach(id, stdin: true)
                try await client.startContainer(id)
            } catch {
                try? await client.removeContainer(id, force: true)
                throw error
            }
            return AttachSession(client: client, containerID: id, connection: connection)
        } catch let error as ImageMCPError {
            throw error
        } catch {
            throw ImageMCPError.engine(ContainerError.from(error))
        }
    }

    /// The shared container, created (or recreated when its configuration changed) and running.
    @discardableResult
    public func ensureShared(_ spec: ImageMCPSpec, imageID: String) async throws -> String {
        let name = spec.containerName(scope: nil)
        let hash = spec.configHash(imageID: imageID)
        if let existing = try await client.inspectContainer(name) {
            guard existing.config.labels?[ImageMCPSpec.label] == spec.id else { throw ImageMCPError.nameTaken(name) }
            if existing.config.labels?[WorkspaceSpec.labelConfig] == hash {
                if !existing.state.running { try await client.startContainer(existing.id) }
                return try await confirmRunning(existing.id, image: spec.image)
            }
            try await client.removeContainer(existing.id, force: true)
        }
        var body = spec.createBody(imageID: imageID, scope: nil)
        body.labels?[WorkspaceSpec.labelConfig] = hash
        let id: String
        do {
            id = try await client.createContainer(name: name, body)
        } catch ContainerError.conflict {
            // Two connections raced: adopt the winner.
            if let other = try await client.inspectContainer(name), other.config.labels?[ImageMCPSpec.label] == spec.id {
                if !other.state.running { try await client.startContainer(other.id) }
                return try await confirmRunning(other.id, image: spec.image)
            }
            throw ImageMCPError.nameTaken(name)
        }
        try await client.startContainer(id)
        return try await confirmRunning(id, image: spec.image)
    }

    /// A keep-alive that exits at once (no shell) leaves a stopped container: report it plainly.
    private func confirmRunning(_ id: String, image: String) async throws -> String {
        for attempt in 0..<5 {
            guard let inspect = try await client.inspectContainer(id) else { throw ImageMCPError.sharedNeedsShell(image) }
            if !inspect.state.running { throw ImageMCPError.sharedNeedsShell(image) }
            if attempt == 4 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return id
    }

    /// Every container of global MCP servers (Settings ▸ MCP Servers, Prune, the idle loop).
    public func containers() async throws -> [ContainerSummary] {
        try await client.listContainers(labels: [ImageMCPSpec.label])
    }

    /// Removes containers of connections that ended without cleaning up (a killed helper), and those of servers that
    /// no longer exist. Running per-connection containers of known servers are kept (their connection is live).
    public func removeLeftovers(knownIDs: Set<String>) async {
        guard let all = try? await containers() else { return }
        for container in all {
            let id = container.labels[ImageMCPSpec.label] ?? ""
            if !knownIDs.contains(id) || !container.isRunning {
                try? await client.removeContainer(container.id, force: true)
            }
        }
    }
}

/// The last part of a relayed server's error output, kept for Settings ▸ MCP Servers ▸ Logs (the helper's stderr goes to
/// opencode, which does not keep it). Bounded: past `limit` bytes the file keeps its newest half.
public struct BoundedLogFile: Sendable {
    public let url: URL
    public let limit: Int

    public init(url: URL, limit: Int = 256 * 1024) {
        self.url = url
        self.limit = limit
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let size = ((try? manager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        if size + data.count > limit {
            // Keep the newest half: rewrite the file (0600) with the tail of what it had plus the new bytes.
            let existing = manager.contents(atPath: url.path) ?? Data()
            let keep = (existing + data).suffix(limit / 2)
            try? Data(keep).write(to: url, options: .atomic)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    public func read() -> String {
        FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
