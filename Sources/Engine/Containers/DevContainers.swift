import BelloCore
import ContainerKit
import Darwin
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
    /// The build is stopped past this (R31): TERM, then KILL after `grace`.
    public var timeout: Duration = DevImageBuildRequest.defaultTimeout
    public var grace: Duration = .seconds(10)

    public static let defaultTimeout: Duration = .seconds(60 * 60)

    public init(docker: String, arguments: [String], dockerfile: Data?, socket: String, config: String?,
                timeout: Duration = DevImageBuildRequest.defaultTimeout, grace: Duration = .seconds(10)) {
        self.docker = docker
        self.arguments = arguments
        self.dockerfile = dockerfile
        self.socket = socket
        self.config = config
        self.timeout = timeout
        self.grace = grace
    }
}

/// The exit status of one child, awaited by a continuation (not a stream: waiting must outlast a cancellation until
/// the child is really gone).
final class ChildExit: Sendable {
    private let state = Mutex<(status: Int32?, waiter: CheckedContinuation<Int32, Never>?)>((nil, nil))

    func exited(_ status: Int32) {
        let waiter = state.withLock { state -> CheckedContinuation<Int32, Never>? in
            state.status = status
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let status = state.withLock { state -> Int32? in
                if state.status == nil { state.waiter = continuation }
                return state.status
            }
            if let status { continuation.resume(returning: status) }
        }
    }
}

public struct DevImageBuildResult: Sendable, Equatable {
    public var status: Int32
    /// The last lines of output (bounded).
    public var tail: String
    /// Stopped by BelloCode (cancelled or past its deadline), not finished.
    public var stopped: Bool
    public init(status: Int32, tail: String, stopped: Bool = false) {
        self.status = status
        self.tail = tail
        self.stopped = stopped
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
    nonisolated static let checkingDevContext = "checking the dev container's build context"
    nonisolated static let buildingDevImage = "building the dev container image"

    /// Computes the content tag of the project's dev container build in the background (R15). One computation per
    /// project at a time; a refresh meanwhile asks for one more after it. A changed tag re-evaluates the project: the
    /// missing image is built, and the running container is replaced on its next activation.
    func refreshDevTag(_ model: ProjectEnvironment, plan: DevContainerPlan) {
        guard let build = plan.build else { return }
        let directory = model.directory
        guard !devTagsInFlight.contains(directory) else {
            devTagsStale.insert(directory)
            return
        }
        devTagsInFlight.insert(directory)
        let cache = devDigestCache
        let key = model.projectKey
        tasks.set("devtag-\(key)", Task { [weak self] in
            let result = await Self.computeDevTag(build, projectRoot: directory, projectKey: key, cache: cache)
            guard let self else { return }
            self.devTagsInFlight.remove(directory)
            guard !Task.isCancelled else { return }
            let again = self.devTagsStale.remove(directory) != nil
            // The file may have changed meanwhile (another build section): only a result for the current plan counts.
            guard let current = self.devContainerPlan(model), current.build == build else {
                if again, let current = self.devContainerPlan(model), current.build != nil { self.refreshDevTag(model, plan: current) }
                return
            }
            switch result {
            case .failure(let problem):
                // The build inputs are no longer valid: nothing may start from the old tag meanwhile.
                self.devTags[directory] = nil
                _ = self.nextGeneration(directory)
                model.phase = .failed(problem.description)
                self.scheduleConfigWrite()
            case .success(let tag):
                let changed = self.devTags[directory] != tag
                self.devTags[directory] = tag
                if case .pulling(let progress) = model.phase, progress.detail == Self.checkingDevContext { model.phase = .unknown }
                if changed || again { self.refreshImageAndPhase(model) }
            }
        })
    }

    @concurrent
    nonisolated static func computeDevTag(_ build: DevContainerPlan.Build, projectRoot: String, projectKey: String,
                                          cache: DevContextDigestCache) async -> Result<String, DevContainerBuildInputs.Problem> {
        switch DevContainerBuildInputs.verify(build, projectRoot: projectRoot) {
        case .failure(let problem): return .failure(problem)
        case .success(let inputs): return inputs.tag(projectKey: projectKey, build: build, cache: cache)
        }
    }

    /// Builds the dev container image with Rancher Desktop's `docker buildx` (BelloCode's own use of the host CLI;
    /// the Dockerfile's steps run in the builder, never on the Mac), then re-evaluates the project. The tag is the
    /// content tag of exactly the inputs built (R15). With `recreate` (Rebuild) the container is replaced once the build
    /// succeeded.
    func buildDevImage(_ model: ProjectEnvironment, plan: DevContainerPlan, recreate: Bool = false) {
        let builder = configuration?.devImageBuilder
        guard let docker = Self.rancherDocker() ?? (builder != nil ? "docker" : nil), let build = plan.build else {
            model.phase = .failed("Building the dev container needs Rancher Desktop's docker (~/.rd/bin/docker), which was not found.")
            scheduleConfigWrite()
            return
        }
        model.phase = .pulling(PullProgress(detail: Self.buildingDevImage))
        scheduleConfigWrite()
        let socket = activeRuntime.socketPath
        let config = configuration.map { Self.prepareHostDockerConfig(next: $0.execConfigURL) } ?? nil
        let projectRoot = model.directory
        let projectKey = model.projectKey
        let cache = devDigestCache
        tasks.set("devbuild-\(model.projectKey)", Task { [weak self] in
            // Right before the CLI runs (R16): links resolved, the context and Dockerfile proven inside the project, the
            // Dockerfile's bytes read once. The CLI gets the canonical context and those bytes on standard input.
            let verified = await Self.verifyBuildInputs(build, projectRoot: projectRoot, projectKey: projectKey, cache: cache)
            guard let self, !Task.isCancelled else { return }
            let inputs: DevContainerBuildInputs
            let tag: String
            switch verified {
            case .failure(let problem):
                model.phase = .failed(problem.description)
                self.scheduleConfigWrite()
                return
            case .success(let value): (inputs, tag) = value
            }
            // The base images the Dockerfile pulls are under the image policy (R14), checked before anything is built.
            let bases = DockerfileBases.images(in: String(decoding: inputs.dockerfile, as: UTF8.self), buildArgs: build.args)
            if let refusal = self.baseImageRefusal(bases) {
                model.phase = .imageRefused(refusal)
                self.scheduleConfigWrite()
                return
            }
            guard let arguments = plan.buildArguments(tag: tag, context: inputs.context) else { return }
            let request = DevImageBuildRequest(docker: docker, arguments: arguments, dockerfile: inputs.dockerfile, socket: socket, config: config)
            let result = if let builder { await builder(request) } else { await Self.runDocker(request) }
            // Published only for the project as it is now (R31): same mode and build section, not cancelled.
            guard !Task.isCancelled, self.mode(for: model) == .projectContainer, self.devContainerPlan(model)?.build == build else { return }
            if result.stopped {
                model.phase = .failed("Building the dev container image was stopped (\(result.tail)). Retry to build it again.")
                self.scheduleConfigWrite()
            } else if result.status == 0 {
                self.devTags[projectRoot] = tag
                model.phase = .unknown
                self.refreshImageAndPhase(model, recreate: recreate)
            } else {
                model.phase = .failed("Building the dev container image failed (exit \(result.status)): \(result.tail)")
                self.scheduleConfigWrite()
            }
        })
    }

    /// The verified inputs and their content tag, off the main actor.
    @concurrent
    nonisolated static func verifyBuildInputs(_ build: DevContainerPlan.Build, projectRoot: String, projectKey: String,
                                              cache: DevContextDigestCache) async
        -> Result<(DevContainerBuildInputs, String), DevContainerBuildInputs.Problem> {
        switch DevContainerBuildInputs.verify(build, projectRoot: projectRoot) {
        case .failure(let problem): return .failure(problem)
        case .success(let inputs): return inputs.tag(projectKey: projectKey, build: build, cache: cache).map { (inputs, $0) }
        }
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
        // The verified Dockerfile goes on standard input (`-f -`); otherwise nothing.
        let input = request.dockerfile.map { _ in Pipe() }
        // A docker that already exited must not SIGPIPE the app.
        if let input { _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }
        process.standardInput = input ?? FileHandle.nullDevice
        // Drained as it arrives (bounded tail); the exit is awaited without holding a thread.
        let tail = Mutex(Data())
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // EOF: an installed handler would re-fire at full CPU until the process exits (N18).
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            tail.withLock { buffer in
                buffer.append(data)
                if buffer.count > 16_384 { buffer = buffer.suffix(8_192) }
            }
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        let exit = ChildExit()
        process.terminationHandler = { finished in exit.exited(finished.terminationStatus) }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            return DevImageBuildResult(status: 127, tail: "could not start docker")
        }
        if let input, let dockerfile = request.dockerfile {
            // Bounded (≤ 1 MiB); written off this task so a docker that never reads cannot hold it.
            let writer = input.fileHandleForWriting
            DispatchQueue.global(qos: .utility).async {
                try? writer.write(contentsOf: dockerfile)
                try? writer.close()
            }
        }
        // R31: the build is owned by the calling task. Cancellation (project changed, service stopped) or the deadline
        // sends TERM (buildx cancels the build in the builder), then KILL after the grace period; the child is always
        // awaited until it is gone.
        let stopped = Mutex<String?>(nil)
        let killer = ContinuousDeadline()
        let pid = process.processIdentifier
        let stop: @Sendable (String) -> Void = { reason in
            let first = stopped.withLock { current -> Bool in
                defer { if current == nil { current = reason } }
                return current == nil
            }
            guard first else { return }
            if process.isRunning { kill(pid, SIGTERM) }
            killer.schedule(after: request.grace) { if process.isRunning { kill(pid, SIGKILL) } }
        }
        let minutes = max(1, Int(request.timeout.components.seconds / 60))
        let watchdog = ContinuousDeadline(after: request.timeout) {
            stop(request.timeout < .seconds(60) ? "it did not finish in time" : "it did not finish within \(minutes) minutes")
        }
        let status = await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            stop("it was cancelled")
        }
        watchdog.cancel()
        killer.cancel()
        if let reason = stopped.withLock({ $0 }) {
            return DevImageBuildResult(status: status == 0 ? 130 : status, tail: reason, stopped: true)
        }
        let text = String(decoding: tail.withLock { $0 }, as: UTF8.self)
        let lines = text.split(separator: "\n").suffix(4).joined(separator: " · ")
        return DevImageBuildResult(status: status, tail: String(lines.prefix(600)))
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
