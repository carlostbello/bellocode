import ContainerKit
import Synchronization
import Foundation

/// BelloCode's filtered Docker endpoint as the app sees it (docs/features/containers.md, "Docker from the
/// workspace"): one listener on the Mac's loopback, one token per scope (the shared workspace, or a project), each
/// scope with the folders its bind mounts may use. The policy itself lives in ContainerKit (`DockerFilterPolicy`).
@MainActor
public final class DockerEndpoint {
    public let port: Int
    /// Rancher Desktop's docker for host docker-only mode (nil when it is not installed).
    public let hostDockerBinary: String?
    /// BelloCode's own `DOCKER_CONFIG` for host docker-only mode.
    public let hostDockerConfig: String?
    let registerScope: @Sendable (DockerScope) -> String

    public init(port: Int, hostDockerBinary: String?, hostDockerConfig: String?, register: @escaping @Sendable (DockerScope) -> String) {
        self.port = port
        self.hostDockerBinary = hostDockerBinary
        self.hostDockerConfig = hostDockerConfig
        registerScope = register
    }

    /// The token commands of `scope` use; registering again updates the scope's folders and keeps the token.
    func token(scope: String, roots: [String]) -> String? {
        guard !roots.isEmpty else { return nil }
        return registerScope(DockerScope(key: scope, roots: roots))
    }
}

/// The image policy, readable from the endpoint's connection tasks.
public final class SharedImagePolicy: Sendable {
    private let state = Mutex(ImagePolicy.open)
    func update(_ policy: ImagePolicy) { state.withLock { $0 = policy } }
    func refusal(_ image: String) -> String? { state.withLock { $0 }.refusal(for: image) }
}

extension EnvironmentService {
    /// Starts the filtered endpoint (once per launch): a loopback listener, Rancher Desktop's socket behind it.
    func startDockerEndpoint() {
        guard let configuration, configuration.dockerEndpoint, dockerProxy == nil else { return }
        let policy = dockerPolicy
        policy.update(imagePolicy)
        do {
            let proxy = try DockerFilterProxy(
                daemonSocket: activeRuntime.socketPath, imageRefusal: { policy.refusal($0) },
                onAfter: { [weak self] _, action in
                    guard case .pulled(let reference) = action else { return }
                    Task { @MainActor in self?.recordPulled(reference) }
                },
                onRefusal: { [weak self] refusal in
                    Task { @MainActor in self?.recordDockerRefusal(refusal) }
                })
            dockerProxy = proxy
            dockerEndpoint = DockerEndpoint(
                port: proxy.port, hostDockerBinary: Self.rancherDocker(), hostDockerConfig: Self.prepareHostDockerConfig(next: configuration.execConfigURL),
                register: { proxy.register($0) })
            tasks.set("docker-endpoint", Task { await proxy.run() })
            // Enforced egress: running gateways start relaying the endpoint (containers reach it through them).
            egress?.dockerEndpointStarted()
        } catch {
            Self.log.error("could not start the filtered Docker endpoint")
        }
    }

    /// Keeps a refused request for the Environment pane (bounded: the newest 20).
    public func recordDockerRefusal(_ refusal: DockerFilterProxy.Refusal) {
        dockerRefusals.append(refusal)
        if dockerRefusals.count > 20 { dockerRefusals.removeFirst(dockerRefusals.count - 20) }
    }

    /// Rancher Desktop's docker CLI, by absolute path (never PATH).
    nonisolated static func rancherDocker(home: String = NSHomeDirectory()) -> String? {
        let path = home + "/.rd/bin/docker"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// BelloCode's own `DOCKER_CONFIG` for host docker-only mode, next to the helper's configuration: an empty
    /// configuration (no credential helpers run) and only Rancher Desktop's compose and buildx plugins.
    nonisolated static func prepareHostDockerConfig(next configURL: URL, home: String = NSHomeDirectory()) -> String? {
        let directory = configURL.deletingLastPathComponent().appending(path: "docker-cli")
        let plugins = directory.appending(path: "cli-plugins")
        do {
            try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(#"{"auths":{}}"#.utf8).write(to: directory.appending(path: "config.json"), options: .atomic)
            for name in ["docker-compose", "docker-buildx"] {
                let link = plugins.appending(path: name).path
                let target = home + "/.rd/bin/" + name
                try? FileManager.default.removeItem(atPath: link)
                if FileManager.default.isExecutableFile(atPath: target) { try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target) }
            }
            return directory.path
        } catch {
            return nil
        }
    }
}
