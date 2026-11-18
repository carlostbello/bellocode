import BelloCore
import ContainerKit
import Foundation
import Testing

@testable import Engine

/// Execution modes (docs/features/containers.md, "Execution modes"): resolution, migration, the shared workspace's
/// helper configuration and the directory checks per mode. Code roots are temporary folders.
@MainActor
@Suite("Execution modes", .timeLimit(.minutes(1)))
struct ExecutionModeTests {
    let base: String
    let codeRoot: String
    let repoA: String
    let repoB: String
    let outside: String
    let runtime = FakeWorkspaceRuntime()

    init() throws {
        base = (CodeRoots.canonical(NSTemporaryDirectory()) ?? NSTemporaryDirectory()) + "/bc-modes-\(UUID().uuidString.prefix(8))"
        codeRoot = base + "/Repos"
        repoA = codeRoot + "/a"
        repoB = codeRoot + "/b"
        outside = base + "/elsewhere/c"
        for path in [repoA + "/src", repoB, outside] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        runtime.state.withLock { $0.images = ["default:1", "own:1"] }
    }

    func makeService(managed: ManagedExecutionPolicy.Managed? = nil, before: ((ProjectionStore) async throws -> Void)? = nil) async throws -> EnvironmentService {
        var configuration = ContainerConfiguration(
            helperURL: URL(filePath: "/Applications/BelloCode.app/Contents/Helpers/bellocode-exec"),
            execConfigURL: URL(filePath: base + "/exec.json"), opencodeDataDirectory: nil, runtime: runtime, registryVault: InMemorySecretVault())
        configuration.managedExecution = { managed }
        let store = try ProjectionStore(location: .inMemory)
        try await before?(store)
        try await store.setPreference(EnvironmentDefaults.preferenceKey, EnvironmentDefaults(defaultImage: "default:1"))
        let service = EnvironmentService(configuration: configuration, store: store)
        service.worktreeParent = { [base] directory in base + "/worktrees/" + (directory as NSString).lastPathComponent }
        await service.start()
        return service
    }

    func project(_ directory: String) -> ProjectItem {
        ProjectItem(entry: ProjectEntry(directory: directory, sortOrder: 0, added: .now), project: nil)
    }

    func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func config() throws -> ExecHelperConfig {
        try JSONDecoder().decode(ExecHelperConfig.self, from: Data(contentsOf: URL(filePath: base + "/exec.json")))
    }

    @Test func newProjectsDefaultToTheSharedWorkspaceAndRootsAreSuggested() async throws {
        let service = try await makeService()
        defer { service.stop() }
        #expect(service.defaultMode == .sharedWorkspace)
        service.projectsChanged([project(repoA), project(repoB)])
        #expect(service.configuredCodeRoots == [codeRoot], "the folder holding the projects")
        #expect(service.codeRootsSource == .suggested)
        #expect(service.trustedRoots.paths == [codeRoot])
        let model = service.environment(for: repoA)
        #expect(await waitFor { model.mode == .sharedWorkspace && model.phase == .idle })
        #expect(model.containerName == WorkspaceSpec.sharedContainerName)
        // One container for both projects.
        #expect(service.environment(for: repoB).containerName == model.containerName)
    }

    @Test func sharedWorkspaceRunsAnyDirectoryInsideTheRootsAndNothingOutside() async throws {
        let service = try await makeService()
        defer { service.stop() }
        await service.setCodeRoots([codeRoot])
        service.projectsChanged([project(repoA)])
        let model = service.environment(for: repoA)
        #expect(await waitFor { model.phase == .idle })
        service.activate(repoA)
        #expect(await waitFor { model.phase == .ready })
        await service.writeConfigNow()
        let config = try config()
        let shared = try #require(config.workspaces.first { $0.mode == .sharedWorkspace })
        #expect(shared.container == WorkspaceSpec.sharedContainerName)
        #expect(shared.roots.first == codeRoot)
        #expect(shared.roots.contains(base + "/worktrees"), "BelloCode's worktree folder is mounted too, whole")
        // The thread's project, another repository under the root (multi-repo) and a new folder all run there.
        #expect(config.resolve(directory: repoA + "/src")?.workspace.container == shared.container)
        #expect(config.resolve(directory: repoB)?.workspace.container == shared.container)
        #expect(config.resolve(directory: repoA + "/src")?.directory == repoA + "/src", "working directory = the thread's folder")
        // Outside the roots: refused (no workspace).
        #expect(config.resolve(directory: outside) == nil)
        #expect(config.resolve(directory: base) == nil)
        // The container mounts every root at the same path, with the shared label and one home volume.
        let spec = try #require(runtime.state.withLock { $0.specs.last })
        #expect(spec.isShared)
        #expect(spec.labels[WorkspaceSpec.labelShared] == "1")
        #expect(spec.createBody(imageID: nil).hostConfig?.mounts?.contains { $0.source == codeRoot && $0.target == codeRoot && $0.readOnly != true } == true)
        #expect(spec.image == "default:1", "the app-wide default image")
    }

    @Test func aProjectOutsideTheRootsIsBlockedWithTheFix() async throws {
        let service = try await makeService()
        defer { service.stop() }
        await service.setCodeRoots([codeRoot])
        let model = service.environment(for: outside)
        #expect(await waitFor { if case .outsideCodeRoots = model.phase { true } else { false } })
        #expect(model.notice?.fix == .openSettings)
        await service.writeConfigNow()
        let entry = try #require(try config().resolve(directory: outside)?.workspace)
        #expect(entry.blocked?.message.contains("outside your code roots") == true)
        #expect(entry.spec == nil)
    }

    @Test func noRootsBlocksSharedProjectsUntilOneIsAdded() async throws {
        let service = try await makeService()
        defer { service.stop() }
        let model = service.environment(for: repoA)
        #expect(await waitFor { if case .outsideCodeRoots = model.phase { true } else { false } })
        await service.setCodeRoots([codeRoot])
        #expect(await waitFor { model.phase == .idle })
    }

    @Test func projectContainerInsideARootKeepsItsOwnContainer() async throws {
        let service = try await makeService()
        defer { service.stop() }
        await service.setCodeRoots([codeRoot])
        var settings = ProjectEnvironmentSettings(image: "own:1")
        settings.executionMode = .projectContainer
        await service.update(repoB, settings: settings)
        service.projectsChanged([project(repoA), project(repoB)])
        let b = service.environment(for: repoB)
        #expect(await waitFor { b.phase == .idle && b.mode == .projectContainer })
        await service.writeConfigNow()
        let config = try config()
        #expect(config.resolve(directory: repoB)?.workspace.container == WorkspaceSpec.containerName(for: repoB), "the longer root wins")
        #expect(config.resolve(directory: repoA)?.workspace.container == WorkspaceSpec.sharedContainerName)
    }

    @Test func hostDockerModeHasNoContainerAndOnlyTheProject() async throws {
        let service = try await makeService()
        defer { service.stop() }
        await service.setCodeRoots([codeRoot])
        await service.setMode(.hostDocker, for: repoA)
        let model = service.environment(for: repoA)
        #expect(await waitFor { model.mode == .hostDocker && model.phase == .ready })
        await service.writeConfigNow()
        let config = try config()
        let entry = try #require(config.resolve(directory: repoA + "/src")?.workspace)
        #expect(entry.mode == .hostDocker)
        #expect(entry.spec == nil && entry.container.isEmpty)
        // Another repository under the root is not this project's: it goes to the shared workspace only if one is in use.
        #expect(config.resolve(directory: repoB)?.workspace.mode != .hostDocker)
        #expect(runtime.state.withLock { $0.ensureCount } == 0, "nothing is created")
    }

    @Test func migrationKeepsProjectsWithAContainerOnProjectContainer() async throws {
        let kept = repoA, fresh = repoB
        let service = try await makeService(before: { store in
            var record = EnvironmentRecord()
            record.containerID = "abc"
            try await store.saveEnvironment(StoredEnvironment(settings: ProjectEnvironmentSettings(image: "own:1"), record: record), directory: kept)
            try await store.saveEnvironment(StoredEnvironment(settings: ProjectEnvironmentSettings()), directory: fresh)
        })
        defer { service.stop() }
        #expect(service.environment(for: kept).settings.executionMode == .projectContainer)
        #expect(service.environment(for: fresh).settings.executionMode == nil, "follows the default")
        #expect(service.mode(forDirectory: fresh) == .sharedWorkspace)
        // Saved, and done once: a later launch does not migrate again.
        let saved = try await service.store.environmentsChecked().0
        #expect(saved[kept]?.settings.executionMode == .projectContainer)
        #expect(try await service.store.preference(EnvironmentService.modesMigratedKey, as: Bool.self) == true)
    }

    @Test func administratorDefaultsAndAllowedModesWin() async throws {
        let managed = ManagedExecutionPolicy.Managed(codeRoots: [codeRoot], codeRootsLocked: true, defaultMode: .projectContainer,
                                                     allowedModes: [.projectContainer, .sharedWorkspace], source: "test")
        let service = try await makeService(managed: managed)
        defer { service.stop() }
        #expect(service.defaultMode == .projectContainer)
        #expect(service.codeRootsLocked)
        #expect(service.configuredCodeRoots == [codeRoot])
        await service.setCodeRoots([outside])
        #expect(service.configuredCodeRoots == [codeRoot], "locked")
        await service.setMode(.hostDocker, for: repoA)
        #expect(service.mode(forDirectory: repoA) == .projectContainer, "a refused mode falls back to the default")
        #expect(!service.isAllowed(.hostDocker))
    }

    @Test func trustedRootsReachThePolicyLayerAndTheHelperConfiguration() async throws {
        let service = try await makeService()
        defer { service.stop() }
        await service.setCodeRoots([codeRoot])
        let roots = service.policyRoots(for: repoA)
        #expect(roots.first.flatMap(CodeRoots.canonical) == repoA, "the project first")
        #expect(roots.contains(codeRoot), "then the code roots")
        let trusted = service.trustedRoots
        #expect(trusted.contains(repoB + "/README.md"), "another repository under the root is in scope")
        #expect(!trusted.contains(outside + "/x"), "outside the roots is not")
        #expect(trusted.source == .configured)
        await service.writeConfigNow()
        #expect(try config().trustedRoots == [codeRoot])
        // A project outside the roots gets only its own folders.
        let outsideRoots = service.policyRoots(for: outside).compactMap(CodeRoots.canonical)
        #expect(outsideRoots.first == outside)
        #expect(!outsideRoots.contains(base))
    }
}
