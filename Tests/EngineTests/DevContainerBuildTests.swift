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
        #expect(first.arguments.last == CodeRootPaths.canonical(project))
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
}
