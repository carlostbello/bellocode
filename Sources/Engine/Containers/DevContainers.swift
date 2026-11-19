import ContainerKit
import Foundation
import Synchronization

// Dev containers behind Project container mode (docs/features/containers.md, "Dev containers").

/// One dev-container image build: Rancher Desktop's docker with these arguments (no shell), the Dockerfile's bytes on
/// standard input when given (`-f -`), the raw socket and BelloCode's own `DOCKER_CONFIG`.
public struct DevImageBuildRequest: Sendable, Equatable {
    public var docker: String
    public var arguments: [String]
    public var dockerfile: Data?
    public var socket: String
    public var config: String?
}

public struct DevImageBuildResult: Sendable, Equatable {
    public var status: Int32
    /// The last lines of output (bounded).
    public var tail: String
    public init(status: Int32, tail: String) {
        self.status = status
        self.tail = tail
    }
}

extension EnvironmentService {
    /// The project's dev container plan when it uses one (Project container mode, chosen in the pane, file usable).
    func devContainerPlan(_ model: ProjectEnvironment) -> DevContainerPlan? {
        guard model.settings.useDevContainer, mode(for: model) == .projectContainer, let plan = devContainerFile(model.directory),
              plan.isUsable else { return nil }
        return plan
    }

    /// The parsed file (cached by modification time and size), usable or not, for the pane.
    public func devContainerFile(_ directory: String) -> DevContainerPlan? {
        guard let file = DevContainerPlan.find(projectRoot: directory) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file)
        let stamp = "\(file)|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((attributes?[.size] as? NSNumber)?.intValue ?? 0)"
        if let cached = devContainerCache[directory], cached.stamp == stamp { return cached.plan }
        let plan = DevContainerPlan.load(projectRoot: directory)
        devContainerCache[directory] = (stamp, plan)
        return plan
    }

    /// Builds the dev container image with Rancher Desktop's `docker buildx` (BelloCode's own use of the host CLI;
    /// the Dockerfile's steps run in the builder, never on the Mac), then re-evaluates the project.
    func buildDevImage(_ model: ProjectEnvironment, plan: DevContainerPlan, tag: String) {
        let builder = configuration?.devImageBuilder
        guard let docker = Self.rancherDocker() ?? (builder != nil ? "docker" : nil), let arguments = plan.buildArguments(tag: tag) else {
            model.phase = .failed("Building the dev container needs Rancher Desktop's docker (~/.rd/bin/docker), which was not found.")
            scheduleConfigWrite()
            return
        }
        model.phase = .pulling(PullProgress(detail: "building the dev container image"))
        scheduleConfigWrite()
        let socket = activeRuntime.socketPath
        let config = configuration.map { Self.prepareHostDockerConfig(next: $0.execConfigURL) } ?? nil
        let dockerfile = plan.build?.dockerfile ?? ""
        let buildArgs = plan.build?.args ?? [:]
        tasks.set("devbuild-\(model.projectKey)", Task { [weak self] in
            // The base images the Dockerfile pulls are under the image policy (R14), checked before anything is built.
            let bases = await Self.dockerfileBases(dockerfile, buildArgs: buildArgs)
            guard let self, !Task.isCancelled else { return }
            if let refusal = self.baseImageRefusal(bases) {
                model.phase = .imageRefused(refusal)
                self.scheduleConfigWrite()
                return
            }
            let request = DevImageBuildRequest(docker: docker, arguments: arguments, dockerfile: nil, socket: socket, config: config)
            let result = if let builder { await builder(request) } else { await Self.runDocker(request) }
            guard !Task.isCancelled else { return }
            if result.status == 0 {
                model.phase = .unknown
                self.refreshImageAndPhase(model)
            } else {
                model.phase = .failed("Building the dev container image failed (exit \(result.status)): \(result.tail)")
                self.scheduleConfigWrite()
            }
        })
    }

    /// Why the Dockerfile's base images may not be used, or nil (each one under the image policy).
    func baseImageRefusal(_ bases: Result<[String], DockerfileBases.Refusal>) -> String? {
        switch bases {
        case .failure(let refusal): return "The dev container's Dockerfile cannot be checked: \(refusal.reason)."
        case .success(let images):
            for image in images {
                if let refusal = imageRefusal(image) { return "The dev container's Dockerfile uses the base image \(image): \(refusal)" }
            }
            return nil
        }
    }

    /// Reads the Dockerfile (bounded) off the main actor and lists the images it pulls.
    @concurrent
    nonisolated static func dockerfileBases(_ path: String, buildArgs: [String: String]) async -> Result<[String], DockerfileBases.Refusal> {
        guard let data = FileManager.default.contents(atPath: path), data.count <= 1 << 20 else {
            return .failure(.init("the Dockerfile could not be read (or is larger than 1 MiB)"))
        }
        return DockerfileBases.images(in: String(decoding: data, as: UTF8.self), buildArgs: buildArgs)
    }

    /// Runs Rancher Desktop's docker with argv (no shell), a minimal environment and the raw socket (BelloCode itself,
    /// never the agent). Returns the exit status and the last lines of output.
    @concurrent
    nonisolated static func runDocker(_ request: DevImageBuildRequest) async -> DevImageBuildResult {
        let process = Process()
        process.executableURL = URL(filePath: request.docker)
        process.arguments = request.arguments
        var environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "DOCKER_HOST": "unix://" + request.socket]
        if let config = request.config { environment["DOCKER_CONFIG"] = config }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        // Drained as it arrives (bounded tail); the exit is awaited without holding a thread.
        let tail = Mutex(Data())
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            tail.withLock { buffer in
                buffer.append(data)
                if buffer.count > 16_384 { buffer = buffer.suffix(8_192) }
            }
        }
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(returning: 127)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let text = String(decoding: tail.withLock { $0 }, as: UTF8.self)
        let lines = text.split(separator: "\n").suffix(4).joined(separator: " · ")
        return DevImageBuildResult(status: status, tail: status == 127 && text.isEmpty ? "could not start docker" : String(lines.prefix(600)))
    }

    /// After the container runs: forward the file's ports and run its lifecycle commands once the person approved them
    /// (postCreate after a new container, postStart after each start).
    func devContainerStarted(_ model: ProjectEnvironment, container: String, user: String, created: Bool, wasStopped: Bool) {
        guard let plan = devContainerPlan(model) else { return }
        for port in plan.forwardPorts where !model.forwards.contains(where: { $0.containerPort == port }) {
            _ = try? forward(model.directory, port: port)
        }
        guard let digest = plan.lifecycleDigest, created || wasStopped else { return }
        guard model.settings.approvedDevLifecycle == digest else {
            model.lastError = "The dev container's lifecycle commands have not been reviewed, so they did not run. Review them in Project Settings ▸ Environment ▸ Dev container."
            return
        }
        let commands = [created ? plan.postCreate : nil, plan.postStart].compactMap { $0 }
        let runtimeRef = activeRuntime
        let shell = shell(model)
        let directory = model.directory
        let environment = plan.remoteEnv
        tasks.set("devlifecycle-\(model.projectKey)", Task { [weak self] in
            for command in commands {
                let result = try? await runtimeRef.run(container: container, argv: [shell, "-c", command], workingDir: directory,
                                                       environment: environment, user: user, timeout: .seconds(900))
                guard let self else { return }
                if result?.exitCode != 0 {
                    model.lastError = "The dev container command “\(command.prefix(80))” failed (exit \(result.map { String($0.exitCode) } ?? "unknown"))."
                    return
                }
            }
        })
    }

    /// The person reviewed the lifecycle commands shown in the pane: they run from now on (until they change).
    public func approveDevLifecycle(_ directory: String) async {
        guard let digest = devContainerFile(directory)?.lifecycleDigest else { return }
        var settings = environment(for: directory).settings
        settings.approvedDevLifecycle = digest
        await update(directory, settings: settings)
    }
}
