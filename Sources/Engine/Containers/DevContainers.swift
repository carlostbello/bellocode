import ContainerKit
import Foundation
import Synchronization

// Dev containers behind Project container mode (docs/features/containers.md, "Dev containers").

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
        guard let docker = Self.rancherDocker(), let arguments = plan.buildArguments(tag: tag) else {
            model.phase = .failed("Building the dev container needs Rancher Desktop's docker (~/.rd/bin/docker), which was not found.")
            scheduleConfigWrite()
            return
        }
        model.phase = .pulling(PullProgress(detail: "building the dev container image"))
        scheduleConfigWrite()
        let socket = activeRuntime.socketPath
        let config = configuration.map { Self.prepareHostDockerConfig(next: $0.execConfigURL) } ?? nil
        tasks.set("devbuild-\(model.projectKey)", Task { [weak self] in
            let result = await Self.runDocker(docker, arguments: arguments, socket: socket, config: config)
            guard let self, !Task.isCancelled else { return }
            if result.status == 0 {
                model.phase = .unknown
                self.refreshImageAndPhase(model)
            } else {
                model.phase = .failed("Building the dev container image failed (exit \(result.status)): \(result.tail)")
                self.scheduleConfigWrite()
            }
        })
    }

    /// Runs Rancher Desktop's docker with argv (no shell), a minimal environment and the raw socket (BelloCode itself,
    /// never the agent). Returns the exit status and the last lines of output.
    @concurrent
    nonisolated static func runDocker(_ docker: String, arguments: [String], socket: String, config: String?) async -> (status: Int32, tail: String) {
        let process = Process()
        process.executableURL = URL(filePath: docker)
        process.arguments = arguments
        var environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "DOCKER_HOST": "unix://" + socket]
        if let config { environment["DOCKER_CONFIG"] = config }
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
        return (status, status == 127 && text.isEmpty ? "could not start docker" : String(lines.prefix(600)))
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
