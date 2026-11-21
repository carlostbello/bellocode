import ContainerKit
import Foundation
import SecretKit
import Synchronization

/// The production `BrowserRuntime`: Rancher Desktop's Engine API for the container and volume, Rancher's `docker
/// buildx` for the image (built locally, cached by input hash, rebuilt when an input changes; one previous image is
/// kept as the known-good fallback), the installation's packing key from the Keychain.
public struct DockerBrowserRuntime: BrowserRuntime {
    public let socketPath: String
    public let docker: URL?
    public let contextDirectory: URL?
    public let configDirectory: URL
    /// The packing key PEM (Keychain `app.bellocode.browser-extension-key`, made on first use).
    public let key: @Sendable () async throws -> String
    /// The egress `browser` scope: network, proxy and certificate folder (SecretManager); nil = no network.
    public let network: (@Sendable (_ image: String) async throws -> BrowserNetworkPlacement)?
    public let containerName: String
    public let volume: String
    public let extraLabels: [String: String]
    /// The image tag in use (set by `prepareImage`, read by `prepareNetwork`: the gateway runs the same image).
    private let currentImage = LockedBox<String?>(nil)

    public init(socketPath: String, docker: URL?, contextDirectory: URL?, configDirectory: URL, key: @escaping @Sendable () async throws -> String,
                network: (@Sendable (_ image: String) async throws -> BrowserNetworkPlacement)?, containerName: String = BrowserContainerSpec.containerName,
                volume: String = BrowserContainerSpec.profileVolume, extraLabels: [String: String] = [:]) {
        self.socketPath = socketPath
        self.docker = docker
        self.contextDirectory = contextDirectory
        self.configDirectory = configDirectory
        self.key = key
        self.network = network
        self.containerName = containerName
        self.volume = volume
        self.extraLabels = extraLabels
    }

    var client: EngineClient { EngineClient(socketPath: socketPath) }

    public func context() throws -> BrowserImageContext {
        guard let contextDirectory else {
            throw BrowserStartError.unavailable("BelloCode's browser image files are missing from this build (Resources/browser-image).")
        }
        return try BrowserImageContext(directory: contextDirectory)
    }

    public func expectedTag() async throws -> String {
        let pem = try await key()
        return try context().tag(extensionID: try BrowserExtensionKey.extensionID(privateKeyPEM: pem))
    }

    public func prepareImage(progress: @escaping @Sendable (String) -> Void) async throws -> String {
        let context = try context()
        let pem = try await key()
        let tag = context.tag(extensionID: try BrowserExtensionKey.extensionID(privateKeyPEM: pem))
        if try await client.inspectImage(tag) != nil {
            currentImage.set(tag)
            return tag
        }
        guard let docker else { throw BrowserStartError.unavailable("Rancher Desktop's docker (~/.rd/bin/docker) is needed to build the browser image.") }
        // arm64 only (R29): refuse an amd64 engine before a long build that would fail or produce unusable binaries.
        if let refusal = BrowserImageContext.architectureRefusal(engineArch: try await client.version().arch) {
            throw BrowserStartError.unavailable(refusal)
        }
        progress("Building the browser image (first use or a pinned version changed)")
        let result = try await BrowserImageBuilder(docker: docker, socketPath: socketPath, configDirectory: configDirectory)
            .build(context: context, keyPEM: pem, extraLabels: extraLabels, progress: progress)
        guard result.succeeded else {
            throw BrowserStartError.unavailable("Building the browser image failed (exit \(result.status)): \(result.tail.split(separator: "\n").suffix(2).joined(separator: " "))")
        }
        currentImage.set(tag)
        await pruneOldImages(keeping: tag)
        return tag
    }

    /// Keeps the new image and one previous one (the known-good fallback); removes older BelloCode browser images.
    func pruneOldImages(keeping tag: String) async {
        guard let images = try? await client.listImages(labels: ["\(BrowserImageContext.labelBrowser)=1"]) else { return }
        let others = images.filter { !$0.repoTags.contains(tag) && $0.repoTags.contains { $0.hasPrefix(BrowserImageContext.repository + ":") } }
        for image in others.dropFirst() { try? await client.removeImage(image.id) }
    }

    public func prepareNetwork() async throws -> BrowserNetworkPlacement {
        guard let network, let image = currentImage.get() else { return BrowserNetworkPlacement() }
        return try await network(image)
    }

    /// The labels that prove the container and the profile volume are BelloCode's (R07: a same-name container or
    /// volume of a manual setup or another tool is never stopped, removed or adopted; the start fails with
    /// `ForeignResourceError`, which names it).
    static let containerOwnership = [BrowserImageContext.labelBrowser: "1", BrowserContainerSpec.labelRole: "browser"]
    static let volumeOwnership = [BrowserImageContext.labelBrowser: "1"]

    func ownedContainer() async throws -> ContainerInspect? {
        try await client.ownedContainer(containerName, required: Self.containerOwnership)
    }

    /// The ID of the container proven BelloCode's (labels), or nil. Every exec and forward addresses it by this ID,
    /// never by name (R07, N12).
    public func ownedContainerID() async throws -> String? { try await ownedContainer()?.id }

    public func inspect() async throws -> BrowserContainerState? {
        guard let inspect = try await ownedContainer() else { return nil }
        return BrowserContainerState(running: inspect.state.running, configHash: inspect.config.labels?["app.bellocode.config"], exitCode: inspect.state.exitCode)
    }

    public func createAndStart(_ spec: BrowserContainerSpec) async throws {
        // Both checks before anything changes: a foreign volume must not cost the person their own container either.
        let existing = try await ownedContainer()
        let profile = try await client.ownedVolume(volume, required: Self.volumeOwnership)
        if let existing {
            if existing.state.running { try? await client.stopContainer(existing.id, timeout: 30) }
            try await client.removeContainer(existing.id, force: true)
        }
        if profile == nil {
            try await client.ensureOwnedVolume(
                name: volume, labels: [BrowserImageContext.labelBrowser: "1", WorkspaceSpec.labelWorkspace: "1"].merging(extraLabels) { a, _ in a },
                required: Self.volumeOwnership)
        }
        let id = try await client.createContainer(name: containerName, spec.create())
        try await client.startContainer(id)
    }

    public func start() async throws {
        guard let existing = try await ownedContainer() else { throw ContainerError.notFound(containerName) }
        try await client.startContainer(existing.id)
    }

    public func stop(timeout: Int) async throws {
        guard let existing = try await ownedContainer(), existing.state.running else { return }
        try await client.stopContainer(existing.id, timeout: timeout)
    }

    public func remove() async throws {
        if let existing = try await ownedContainer() { try await client.removeContainer(existing.id, force: true) }
    }

    public func removeProfile() async throws {
        if try await client.ownedVolume(volume, required: Self.volumeOwnership) != nil { try await client.removeVolume(volume, force: false) }
    }

    public func status() async throws -> BrowserRuntimeStatus? {
        guard let owned = try await ownedContainer() else { return nil }
        let result = try await ExecSession.run(client: client, container: owned.id, argv: ["/usr/local/bin/bellocode-browser-ctl", "status"],
                                               wrap: false, limit: 64 * 1024, timeout: .seconds(20))
        return BrowserRuntimeStatus.parse(String(decoding: result.stdout, as: UTF8.self))
    }

    /// The per-launch VNC password goes over the exec's stdin (never argv, environment or a log).
    public func setViewerPassword(_ password: String) async throws {
        // Only into the container proven BelloCode's, addressed by its ID.
        guard let owned = try await ownedContainer() else { throw ContainerError.notFound(containerName) }
        let session = try await ExecSession.start(client: client, container: owned.id, argv: ["/usr/local/bin/bellocode-browser-ctl", "vnc-password"],
                                                  workingDir: nil, environment: [:], user: nil, tty: false)
        defer { session.close() }
        try await session.write(Data((password + "\n").utf8))
        session.closeStdin()
        _ = try await withDeadline(.seconds(15), operation: "vnc-password") {
            for try await _ in session.output() {}
        }
        guard try await session.exitCode() == 0 else { throw BrowserStartError.unavailable("Could not set the live view's password.") }
    }

    public func seccompProfile() throws -> String { try context().seccompProfileJSON }

    /// The downloads folder's listing and one file (≤ 256 MiB) for the downloads shelf.
    public func downloads() async throws -> [BrowserDownload] {
        guard let owned = try await ownedContainer() else { return [] }
        let result = try await ExecSession.run(client: client, container: owned.id, argv: ["/usr/local/bin/bellocode-browser-ctl", "downloads"],
                                               wrap: false, limit: 256 * 1024, timeout: .seconds(20))
        return BrowserDownload.parseList(String(decoding: result.stdout, as: UTF8.self))
    }

    public func download(_ name: String) async throws -> Data {
        guard let owned = try await ownedContainer() else { throw ContainerError.notFound(containerName) }
        let result = try await ExecSession.run(client: client, container: owned.id, argv: ["/usr/local/bin/bellocode-browser-ctl", "download", name],
                                               wrap: false, limit: 256 << 20, timeout: .seconds(120))
        guard result.exitCode == 0 else { throw BrowserStartError.unavailable(String(decoding: result.stderr, as: UTF8.self)) }
        return result.stdout
    }
}

/// A small lock-protected value (Sendable state inside a Sendable struct).
final class LockedBox<Value: Sendable>: Sendable {
    private let lock: Mutex<Value>
    init(_ value: Value) { lock = Mutex(value) }
    func get() -> Value { lock.withLock { $0 } }
    func set(_ value: Value) { lock.withLock { $0 = value } }
}
