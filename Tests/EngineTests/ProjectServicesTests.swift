import BelloCore
import ContainerKit
import Foundation
import Testing

@testable import Engine

/// Project services and the image policy in `EnvironmentService`, over the fake runtime.
@MainActor
@Suite("Project services and image policy", .timeLimit(.minutes(1)))
struct ProjectServicesTests {
    let root: URL
    let project: String
    let runtime = FakeWorkspaceRuntime()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "bellocode-svc-\(UUID().uuidString)", directoryHint: .isDirectory)
        project = root.appending(path: "project").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
    }

    func makeService(policy: ImagePolicy? = nil) async throws -> EnvironmentService {
        var configuration = ContainerConfiguration(
            helperURL: URL(filePath: "/Applications/BelloCode.app/Contents/Helpers/bellocode-exec"),
            execConfigURL: root.appending(path: "exec.json"), opencodeDataDirectory: nil, runtime: runtime, registryVault: InMemorySecretVault()).projectContainerDefault()
        configuration.managedPolicy = { policy.map { .init(policy: $0, defaultImage: nil, source: "test") } }
        let service = EnvironmentService(configuration: configuration, store: try ProjectionStore(location: .inMemory))
        service.worktreeParent = { [root] _ in root.appending(path: "worktrees").path }
        await service.start()
        return service
    }

    @Test func aComposeFileDefinesServicesAndTheWorkspaceJoinsTheirNetwork() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("""
            services:
              db: {image: "postgres:16", ports: ["5432"]}
              bad: {image: alpine, privileged: true}
            """.utf8).write(to: URL(filePath: project).appending(path: "compose.yaml"))
        runtime.state.withLock { $0.images = ["node:22"] }
        let service = try await makeService()
        await service.update(project, settings: ProjectEnvironmentSettings(image: "node:22"))
        let model = service.environment(for: project)
        #expect(model.servicesSource == .file(project + "/compose.yaml"))
        #expect(model.services.map(\.name) == ["db", "bad"])
        #expect(model.services.first { $0.name == "bad" }?.phase == .refused)
        let spec = try #require(service.workspaceSpec(model))
        #expect(spec.serviceNetwork == "bellocode-net-\(model.projectKey)")
        #expect(service.serviceSpecs(model).map(\.name) == ["db"])
        #expect(service.helperConfig().workspaces.first { $0.container == model.containerName }?.services == ["db"],
                "only runnable services can be opened in a terminal")
        let text = ContainerTools.describe(model.services, source: model.servicesSource, parse: model.servicesParse, workspaceReady: false)
        #expect(text.contains("db: Not started · image postgres:16 · ports db:5432"))
        #expect(text.contains("Refused keys: services.bad.privileged"))
        #expect(text.contains("services start with it"))

        // Offline projects put the workspace and the services on an internal network.
        var settings = model.settings
        settings.network = .none
        await service.update(project, settings: settings)
        #expect(service.workspaceSpec(model)?.serviceNetwork == "bellocode-net-\(model.projectKey)-offline")
    }

    @Test func servicesDefinedInThePaneApplyWithoutAFile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try await makeService()
        var settings = ProjectEnvironmentSettings(image: "node:22")
        settings.servicesYAML = "services:\n  cache:\n    image: redis:7\n"
        await service.update(project, settings: settings)
        let model = service.environment(for: project)
        #expect(model.servicesSource == .pane && model.services.map(\.name) == ["cache"])
        settings.servicesYAML = nil
        await service.update(project, settings: settings)
        #expect(model.servicesSource == .none && model.services.isEmpty && service.workspaceSpec(model)?.serviceNetwork == nil)
        #expect(ContainerTools.describe([], source: .none, parse: nil, workspaceReady: true).contains("defines no services"))
    }

    @Test func thePolicyRefusesWorkspaceAndServiceImagesWithSpecificMessages() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("services:\n  cache: {image: \"redis:7\"}\n  db: {image: \"registry.acme.internal/db/postgres@sha256:\(String(repeating: "a", count: 64))\"}\n".utf8)
            .write(to: URL(filePath: project).appending(path: "compose.yaml"))
        runtime.state.withLock { $0.images = ["node:22"] }
        let service = try await makeService(policy: ImagePolicy(allowedPrefixes: ["registry.acme.internal"], requireDigest: true))
        await service.update(project, settings: ProjectEnvironmentSettings(image: "node:22"))
        let model = service.environment(for: project)
        guard case .imageRefused(let message) = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(message.contains("node:22 is not allowed by the image policy (allowed: registry.acme.internal)"))
        #expect(model.notice?.fix == .chooseImage)
        #expect(service.workspaceSpec(model) == nil, "no spec: the helper cannot create the container either")
        #expect(service.helperConfig().workspaces.first { $0.container == model.containerName }?.blocked?.message == message)
        #expect(model.services.first { $0.name == "cache" }?.phase == .refused)
        #expect(model.services.first { $0.name == "db" }?.phase == .notStarted, "an allowed, pinned image is not refused")
        service.activate(project)
        service.pull(model)
        #expect(runtime.state.withLock { $0.ensureCount } == 0, "nothing was created or pulled")
    }
}

@Suite("Project caches")
struct ProjectCachesTests {
    @Test func projectChoicesCombineWithTheImagesDeclaration() {
        var settings = ProjectEnvironmentSettings()
        let declared: [PackageCache: String] = [.npm: "/opt/npm", .pip: PackageCache.pip.defaultPath]
        #expect(settings.cacheMounts(imageDeclared: declared) == [CacheMount(cache: .npm, path: "/opt/npm"), CacheMount(cache: .pip, path: PackageCache.pip.defaultPath)])
        settings.caches = [CacheSelection(cache: .pip, enabled: false), CacheSelection(cache: .npm, shared: true), CacheSelection(cache: .cargo)]
        #expect(settings.cacheMounts(imageDeclared: declared) == [
            CacheMount(cache: .cargo, path: PackageCache.cargo.defaultPath), CacheMount(cache: .npm, path: "/opt/npm", shared: true),
        ])
        let old = try? JSONDecoder().decode(ProjectEnvironmentSettings.self, from: Data(#"{"image":"x"}"#.utf8))
        #expect(old?.caches == [])
    }
}
