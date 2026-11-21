import BelloCore
import ContainerKit
import Foundation
import Synchronization
import Testing

@testable import Engine

/// Dev-container image builds (docs/reviews/release-1.0-review.md R14, R15, R16, R31) with a scripted builder in place
/// of Rancher Desktop's docker. Projects are temporary folders.
@MainActor
@Suite("Dev container builds", .timeLimit(.minutes(1)))
struct DevContainerBuildTests {
    let base: String
    let project: String
    let runtime = FakeWorkspaceRuntime()
    let builds = Builds()

    final class Builds: Sendable {
        let list = Mutex<[DevImageBuildRequest]>([])
        var count: Int { list.withLock { $0.count } }
        func append(_ request: DevImageBuildRequest) { list.withLock { $0.append(request) } }
    }

    init() throws {
        // The canonical spelling (/private/var/…): parsing once dropped the /private and refused the context (R16).
        base = (CodeRootPaths.canonical(NSTemporaryDirectory()) ?? NSTemporaryDirectory()) + "/bc-devbuild-\(UUID().uuidString.prefix(8))"
        project = base + "/project"
        try FileManager.default.createDirectory(atPath: project + "/.devcontainer", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: project + "/src", withIntermediateDirectories: true)
        try #"{"build": {"dockerfile": "Dockerfile", "context": ".."}}"#.write(toFile: project + "/.devcontainer/devcontainer.json", atomically: true, encoding: .utf8)
        try write("FROM registry.acme.internal/base:1\nCOPY src /src\n", "/.devcontainer/Dockerfile")
        try write("console.log(1)\n", "/src/main.js")
    }

    func write(_ text: String, _ relative: String) throws {
        try text.write(toFile: project + relative, atomically: true, encoding: .utf8)
    }

    /// The tag a build request produced (after `-t`).
    nonisolated static func tag(_ request: DevImageBuildRequest) -> String? {
        request.arguments.firstIndex(of: "-t").map { request.arguments[$0 + 1] }
    }

    func makeService(policy: ImagePolicy = .open,
                     builder: (@Sendable (DevImageBuildRequest) async -> DevImageBuildResult)? = nil) async throws -> EnvironmentService {
        var configuration = ContainerConfiguration(
            helperURL: URL(filePath: "/Applications/BelloCode.app/Contents/Helpers/bellocode-exec"),
            execConfigURL: URL(filePath: base + "/exec.json"), opencodeDataDirectory: nil, runtime: runtime, registryVault: InMemorySecretVault())
        configuration.managedPolicy = { .init(policy: policy, source: "test") }
        let runtime = runtime
        let builds = builds
        // Default: the build succeeds and the image then exists.
        configuration.devImageBuilder = builder ?? { request in
            builds.append(request)
            if let tag = Self.tag(request) { _ = runtime.state.withLock { $0.images.insert(tag) } }
            return DevImageBuildResult(status: 0, tail: "")
        }
        let store = try ProjectionStore(location: .inMemory)
        try await store.setPreference(EnvironmentDefaults.preferenceKey, EnvironmentDefaults(defaultImage: "default:1"))
        let service = EnvironmentService(configuration: configuration, store: store)
        service.worktreeParent = { [base] directory in base + "/worktrees/" + (directory as NSString).lastPathComponent }
        await service.start()
        var settings = ProjectEnvironmentSettings(executionMode: .projectContainer)
        settings.useDevContainer = true
        await service.update(project, settings: settings)
        return service
    }

    func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: R14

    /// The registry allowlist applies to the Dockerfile's base images, not to the tag BelloCode gives the local build.
    @Test func theAllowlistAppliesToBaseImagesNotTheLocalTag() async throws {
        let service = try await makeService(policy: ImagePolicy(allowedPrefixes: ["registry.acme.internal"]))
        defer { service.stop() }
        let model = service.environment(for: project)
        #expect(await waitFor { builds.count == 1 }, "an allowed base image is built: \(model.phase)")
        if case .imageRefused(let message) = model.phase { Issue.record("the local tag was refused: \(message)") }

        try write("ARG BASE=evil.example.com/miner:1\nFROM ${BASE}\n", "/.devcontainer/Dockerfile")
        await service.retry(project)
        #expect(await waitFor { if case .imageRefused = model.phase { true } else { false } }, "\(model.phase)")
        if case .imageRefused(let message) = model.phase { #expect(message.contains("evil.example.com/miner:1")) }
        #expect(builds.count == 1, "nothing is built from a refused base image")
    }

    // MARK: R16

    /// The build gets the verified canonical context and the Dockerfile's bytes on standard input; a context replaced
    /// by a link to a folder outside the project after the file was read is caught right before the build.
    @Test func theBuildGetsVerifiedInputsAndALinkedContextIsCaughtBeforeIt() async throws {
        let service = try await makeService()
        defer { service.stop() }
        let model = service.environment(for: project)
        #expect(await waitFor { builds.count == 1 }, "\(model.phase)")
        let first = try #require(builds.list.withLock { $0.first })
        // A18: the builder gets a private copy of the context (removed after the build), never the project folder.
        let staged = try #require(first.arguments.last)
        #expect(staged != CodeRootPaths.canonical(project) && !staged.hasPrefix(project) && staged.contains("bellocode-devctx-"))
        #expect(await waitFor { !FileManager.default.fileExists(atPath: staged) }, "the copy is removed after the build")
        #expect(first.arguments.firstIndex(of: "-f").map { first.arguments[$0 + 1] } == "-")
        #expect(first.dockerfile == Data("FROM registry.acme.internal/base:1\nCOPY src /src\n".utf8))

        // Point the file at a context folder, let it be read, then swap the folder for a link outside the project.
        let outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: project + "/ctx", withIntermediateDirectories: true)
        try #"{"build": {"dockerfile": "Dockerfile", "context": "../ctx"}}"#.write(toFile: project + "/.devcontainer/devcontainer.json", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: project + "/.devcontainer/devcontainer.json")
        #expect(service.devContainerFile(project)?.isUsable == true)
        try FileManager.default.removeItem(atPath: project + "/ctx")
        try FileManager.default.createSymbolicLink(atPath: project + "/ctx", withDestinationPath: outside)
        try write("FROM registry.acme.internal/base:2\n", "/.devcontainer/Dockerfile")
        await service.retry(project)
        #expect(await waitFor { if case .failed = model.phase { true } else { false } }, "\(model.phase)")
        if case .failed(let message) = model.phase { #expect(message.contains("inside the project")) }
        #expect(builds.count == 1, "nothing outside the project reaches the builder")
    }

    // MARK: A18, N09

    /// A18: a save while the build runs changes neither what was built nor the tag it got: the builder reads a private
    /// copy, the tag is that copy's digest, and the next refresh sees the save and builds again under a new tag.
    @Test func aSaveDuringTheBuildDoesNotChangeWhatTheTagDescribes() async throws {
        let observed = Mutex<[(tag: String, content: String)]>([])
        let project = project
        let runtime = runtime
        let builds = builds
        let service = try await makeService(builder: { request in
            builds.append(request)
            let tag = Self.tag(request) ?? ""
            let staged = request.arguments.last ?? ""
            if builds.count == 1 {
                // The save lands while the build runs.
                try? "console.log('saved during the build')\n".write(toFile: project + "/src/main.js", atomically: false, encoding: .utf8)
            }
            let content = (try? String(contentsOfFile: staged + "/src/main.js", encoding: .utf8)) ?? "missing"
            observed.withLock { $0.append((tag, content)) }
            _ = runtime.state.withLock { $0.images.insert(tag) }
            return DevImageBuildResult(status: 0, tail: "")
        })
        defer { service.stop() }
        let model = service.environment(for: project)
        #expect(await waitFor { builds.count == 1 }, "\(model.phase)")
        let first = try #require(observed.withLock { $0.first })
        #expect(first.content == "console.log(1)\n", "the builder read the copy, not the saved file")
        // The tag of the original content (the copy's digest), not of the save.
        let original = try #require(DevContainerPlan.load(projectRoot: project)?.build)
        let inputs = try DevContainerBuildInputs.verify(original, projectRoot: project).get()
        let savedTag = try inputs.tag(projectKey: model.projectKey, build: original, cache: DevContextDigestCache()).get()
        #expect(first.tag != savedTag)
        // The next refresh sees the save and builds it under its own tag.
        await service.retry(project)
        #expect(await waitFor { builds.count == 2 }, "\(model.phase)")
        let second = try #require(observed.withLock { $0.last })
        #expect(second.tag == savedTag && second.content.contains("saved during the build"))
    }

    /// N09: under enforced egress, the dev container build's `RUN` steps get no network.
    @Test func underEnforcedEgressTheBuildHasNoNetwork() async throws {
        let service = try await makeService()
        defer { service.stop() }
        service.egress = EgressHooks(
            attachment: { key, services in (EgressAttachment(network: EgressGateway.networkName(key), caFingerprint: "f", noProxy: services), nil) },
            preflight: { _ in }, servicesStarted: { _ in })
        let model = service.environment(for: project)
        service.rebuild(project)
        #expect(await waitFor { builds.list.withLock { $0.contains { $0.arguments.contains("--network") } } }, "\(model.phase)")
        let request = try #require(builds.list.withLock { $0.last })
        #expect(request.arguments.firstIndex(of: "--network").map { request.arguments[$0 + 1] } == "none")
    }

    // MARK: R15

    /// A file copied into the image changes the tag, so the image is built again; an ignored file does not. Rebuild
    /// runs the build plan (never a pull of the local tag), also under pull policy "always".
    @Test func contextChangesRebuildAndALocalTagIsNeverPulled() async throws {
        try write("node_modules\n*.log\n", "/.dockerignore")
        let service = try await makeService(policy: ImagePolicy(pullPolicy: .always))
        defer { service.stop() }
        let model = service.environment(for: project)
        #expect(await waitFor { builds.count == 1 }, "\(model.phase)")
        let first = try #require(builds.list.withLock { $0.first }.flatMap(Self.tag))
        #expect(await waitFor { model.image == first })
        service.activate(project)
        #expect(await waitFor { model.phase == .ready }, "\(model.phase)")

        // An ignored file: same tag, nothing built.
        try FileManager.default.createDirectory(atPath: project + "/node_modules", withIntermediateDirectories: true)
        try write("x", "/node_modules/big.js")
        try write("x", "/debug.log")
        await service.retry(project)
        try await Task.sleep(for: .milliseconds(200))
        #expect(builds.count == 1 && model.image == first, "ignored files leave the tag alone")

        // A file the Dockerfile copies: a new tag, built (not pulled), and the container follows it.
        try write("console.log(2)\n", "/src/main.js")
        await service.retry(project)
        #expect(await waitFor { builds.count == 2 }, "\(model.phase)")
        let second = try #require(builds.list.withLock { $0.last }.flatMap(Self.tag))
        #expect(second != first)
        #expect(await waitFor { model.image == second })

        // Rebuild: the build plan runs again (same tag), never a pull.
        service.rebuild(project)
        #expect(await waitFor { builds.count == 3 }, "\(model.phase)")
        #expect(builds.list.withLock { $0.last }.flatMap(Self.tag) == second)
        service.activate(project)
        try await Task.sleep(for: .milliseconds(100))
        let pulled = runtime.state.withLock { $0.pulled }
        #expect(!pulled.contains { $0.hasPrefix("bellocode-dev-") }, "a locally built tag is never pulled: \(pulled)")
    }

    // MARK: R31

    /// A build in progress is cancelled when the project stops being a dev container built here, and its result is
    /// never published; stopping the service cancels it too.
    @Test func aBuildIsCancelledWhenTheProjectChangesAndWhenTheServiceStops() async throws {
        let started = Builds()
        let cancelled = Mutex(0)
        let service = try await makeService(builder: { request in
            started.append(request)
            // A build that never finishes on its own; only cancellation ends it.
            await withTaskCancellationHandler {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            } onCancel: {
                cancelled.withLock { $0 += 1 }
            }
            return DevImageBuildResult(status: 0, tail: "")
        })
        let model = service.environment(for: project)
        #expect(await waitFor { started.count == 1 }, "\(model.phase)")
        var settings = model.settings
        settings.executionMode = .sharedWorkspace
        await service.update(project, settings: settings)
        #expect(await waitFor { cancelled.withLock { $0 } == 1 }, "the build is stopped with the project change")
        try await Task.sleep(for: .milliseconds(100))
        if case .pulling(let progress) = model.phase { Issue.record("still shown as building: \(progress.detail)") }

        settings.executionMode = .projectContainer
        await service.update(project, settings: settings)
        #expect(await waitFor { started.count == 2 }, "\(model.phase)")
        service.stop()
        #expect(await waitFor { cancelled.withLock { $0 } == 2 }, "stopping the service stops the build")
    }
}

/// R31: Rancher Desktop's docker as a child process of the build: owned by the task, stopped on cancellation or at its
/// deadline (TERM, then KILL), always reaped. A shell script stands in for docker.
@Suite("Dev container build process", .timeLimit(.minutes(3)))
struct DevBuildProcessTests {
    let folder: String

    init() throws {
        folder = NSTemporaryDirectory() + "bc-devproc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    /// A stand-in docker: writes its process ID to the file named by its first argument, then runs `body`.
    func script(_ body: String) throws -> String {
        let path = folder + "/docker-\(UUID().uuidString.prefix(6))"
        try "#!/bin/sh\necho $$ > \"$1\"\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func pid(_ file: String) async -> pid_t? {
        for _ in 0..<200 {
            if let text = try? String(contentsOfFile: file, encoding: .utf8), let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    static func gone(_ pid: pid_t) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }

    @Test func cancellingTheTaskStopsAndReapsTheChild() async throws {
        let pidFile = folder + "/cancel.pid"
        let docker = try script("exec /bin/sleep 60")
        let request = DevImageBuildRequest(docker: docker, arguments: [pidFile], dockerfile: Data("FROM x\n".utf8), socket: "/nonexistent.sock", config: nil)
        let build = Task { await EnvironmentService.runDocker(request) }
        let child = try #require(await pid(pidFile))
        build.cancel()
        let result = await build.value
        #expect(result.stopped && result.tail.contains("cancelled"))
        #expect(Self.gone(child), "the child is gone once the call returns")
    }

    @Test func theDeadlineStopsAChildThatIgnoresTerm() async throws {
        let pidFile = folder + "/deadline.pid"
        let docker = try script("trap '' TERM\nwhile :; do /bin/sleep 0.2; done")
        let request = DevImageBuildRequest(docker: docker, arguments: [pidFile], dockerfile: nil, socket: "/nonexistent.sock", config: nil,
                                           timeout: .milliseconds(300), grace: .milliseconds(300))
        let result = await EnvironmentService.runDocker(request)
        let child = try #require(await pid(pidFile))
        #expect(result.stopped && result.tail.contains("did not finish"))
        #expect(result.status != 0)
        #expect(Self.gone(child), "killed after the grace period and reaped")
    }

    @Test func aFinishedBuildReportsItsStatusAndOutput() async throws {
        let docker = try script("echo step one\necho failed >&2\nexit 3")
        let result = await EnvironmentService.runDocker(DevImageBuildRequest(docker: docker, arguments: [folder + "/ok.pid"], dockerfile: nil,
                                                                             socket: "/nonexistent.sock", config: nil))
        #expect(result.status == 3 && !result.stopped)
        #expect(result.tail.contains("failed"))
    }
}
