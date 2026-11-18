import BelloCore
import ContainerKit
import Foundation
import OpenCodeKit
import Testing

@testable import Engine

/// U1 and S3 (docs/reviews/deep-review-1.md): archiving a project only hides it (no container or volume is touched,
/// also after undo, unrelated project updates and a relaunch); the only path that deletes volumes is the explicit purge.
/// A project's saved execution policy is in force before anything can create, publish or use its environment.
@Suite("Project environment lifetime", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct ProjectEnvironmentLifetimeTests {
    @MainActor final class Fixture {
        let root: URL
        let projectA: String
        let projectB: String
        let runtime = FakeWorkspaceRuntime()
        let harness: MockHarness
        var engine: Engine?

        init() async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "bellocode-lifetime-\(UUID().uuidString)", directoryHint: .isDirectory)
            projectA = root.appending(path: "alpha").path
            projectB = root.appending(path: "beta").path
            for project in [projectA, projectB] { try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true) }
            runtime.state.withLock { $0.images = ["img:1", "approved:1", "default:1"] }
            harness = try await MockHarness.start(.empty(directory: projectA))
        }

        func configuration() -> EngineConfiguration {
            var configuration = EngineConfiguration(server: .fixed(harness.connection), store: .file(root.appending(path: "projection.sqlite")))
            configuration.eventBackoff = BackoffPolicy(initial: .milliseconds(20), maximum: .milliseconds(200))
            configuration.writeInterval = .milliseconds(20)
            configuration.secretVault = InMemorySecretVault()
            configuration.startsExtras = false
            configuration.containers = ContainerConfiguration(
                helperURL: URL(filePath: "/Applications/BelloCode.app/Contents/Helpers/bellocode-exec"),
                execConfigURL: root.appending(path: "exec.json"), opencodeDataDirectory: nil, runtime: runtime, registryVault: InMemorySecretVault())
            return configuration
        }

        @discardableResult
        func launch() async throws -> Engine {
            let engine = try await Engine.make(configuration: configuration())
            engine.environments.worktreeParent = { [root] directory in root.appending(path: "worktrees/\((directory as NSString).lastPathComponent)").path }
            self.engine = engine
            await engine.start()
            try await waitUntil("runtime") { engine.environments.runtime?.isReady == true }
            return engine
        }

        func quit() async {
            await engine?.flush()
            await engine?.stop()
            engine = nil
        }

        func helperConfig() throws -> ExecHelperConfig {
            try JSONDecoder().decode(ExecHelperConfig.self, from: Data(contentsOf: root.appending(path: "exec.json")))
        }

        func finish() async {
            await quit()
            await harness.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func archiveUndoUnrelatedUpdatesAndRelaunchNeverRemoveContainersOrVolumes() async throws {
        let fixture = try await Fixture()
        defer { Task { await fixture.finish() } }
        let engine = try await fixture.launch()
        await engine.addProject(directory: fixture.projectA)
        await engine.addProject(directory: fixture.projectB)
        try await waitUntil("projects") { engine.root.projects.count == 2 }
        var settings = ProjectEnvironmentSettings()
        settings.image = "img:1"
        await engine.environments.update(fixture.projectA, settings: settings)
        let model = engine.environments.environment(for: fixture.projectA)
        try await waitUntil("idle") { model.phase == .idle }
        engine.environments.activate(fixture.projectA)
        try await waitUntil("ready") { model.phase == .ready }
        let key = model.projectKey
        #expect(fixture.runtime.state.withLock { $0.volumes[key]?.isEmpty == false }, "the container has a persistent home volume")

        // Archive, an unrelated update to another project, undo (re-add), archive again.
        await engine.removeProject(directory: fixture.projectA)
        try await waitUntil("archived") { engine.root.hiddenProjects.contains { $0.directory == fixture.projectA } }
        await engine.setProjectPinned(directory: fixture.projectB, true)
        try await waitUntil("pinned") { engine.root.projects.first { $0.directory == fixture.projectB }?.isPinned == true }
        await engine.addProject(directory: fixture.projectA)
        try await waitUntil("restored") { engine.root.projects.contains { $0.directory == fixture.projectA } }
        await engine.removeProject(directory: fixture.projectA)
        try await waitUntil("archived again") { engine.root.hiddenProjects.contains { $0.directory == fixture.projectA } }
        await engine.moveProject(directory: fixture.projectB, to: 0)
        await engine.flush()
        await engine.environments.writeConfigNow()
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.runtime.state.withLock { $0.removed }.isEmpty, "archive never removes a container")
        #expect(fixture.runtime.state.withLock { $0.purgedVolumes }.isEmpty, "archive never deletes a volume")
        #expect(model.phase == .ready, "an archived project's environment is left as it was")

        // Relaunch with the project archived: nothing is removed either.
        await fixture.quit()
        let relaunched = try await fixture.launch()
        try await waitUntil("cached projects") { relaunched.root.hiddenProjects.contains { $0.directory == fixture.projectA } }
        await relaunched.environments.writeConfigNow()
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.runtime.state.withLock { $0.removed }.isEmpty)
        #expect(fixture.runtime.state.withLock { $0.purgedVolumes }.isEmpty)

        // Removing only the container (Rebuild-style) keeps the volumes.
        await relaunched.environments.removeContainerNow(fixture.projectA)
        #expect(fixture.runtime.state.withLock { $0.removed } == [key])
        #expect(fixture.runtime.state.withLock { $0.purgedVolumes }.isEmpty)

        // The explicit purge lists what it deletes and deletes exactly that.
        let storage = try await relaunched.environments.storageToPurge(fixture.projectA)
        #expect(storage.volumes == ["bellocode-\(key)-home"])
        try await relaunched.environments.purge(fixture.projectA, confirmed: storage)
        #expect(fixture.runtime.state.withLock { $0.purgedVolumes } == storage.volumes)
        // A list confirmed for one project never deletes another's.
        let other = WorkspaceStorage(projectKey: WorkspaceSpec.projectKey(for: fixture.projectB), containers: [], volumes: ["x"])
        await #expect(throws: EnvironmentBlockedError.self) { try await relaunched.environments.purge(fixture.projectA, confirmed: other) }
    }

    /// Seeds the store the way an earlier launch left it: project B offline with an approved image, an app default image.
    private func seedPolicy(_ fixture: Fixture) async throws {
        let store = try await ProjectionStore.open(location: .file(fixture.root.appending(path: "projection.sqlite")), changes: ChangeBus())
        var settings = ProjectEnvironmentSettings()
        settings.image = "approved:1"
        settings.network = .none
        try await store.saveEnvironment(StoredEnvironment(settings: settings), directory: fixture.projectB)
        try await store.setPreference(EnvironmentDefaults.preferenceKey, EnvironmentDefaults(defaultImage: "default:1"))
    }

    private func assertSavedPolicyInForce(_ fixture: Fixture, _ engine: Engine) async throws {
        let model = engine.environments.environment(for: fixture.projectB)
        #expect(model.settings.network == WorkspaceSpec.Network.none, "the saved offline policy is in force")
        #expect(model.image == "approved:1", "the saved image, not the app default")
        let workspace = try #require(try fixture.helperConfig().workspace(for: fixture.projectB))
        #expect(workspace.spec?.network == WorkspaceSpec.Network.none, "the helper never gets a default (online) spec")
        #expect(workspace.spec?.image == "approved:1")
        try await waitUntil("idle") { model.phase == .idle }
        engine.environments.activate(fixture.projectB)
        try await waitUntil("ready") { model.phase == .ready }
        let specs = fixture.runtime.state.withLock { $0.specs }.filter { $0.projectRoot == fixture.projectB }
        #expect(!specs.isEmpty)
        #expect(specs.allSatisfy { $0.network == WorkspaceSpec.Network.none && $0.image == "approved:1" }, "Docker is only ever asked for the saved policy")
    }

    @Test func warmLaunchWithACachedProjectKeepsTheSavedRestrictivePolicy() async throws {
        let fixture = try await Fixture()
        defer { Task { await fixture.finish() } }
        // First launch: the project is added (so the next launch applies it from the cache before anything else).
        let first = try await fixture.launch()
        await first.addProject(directory: fixture.projectB)
        try await waitUntil("project") { first.root.projects.contains { $0.directory == fixture.projectB } }
        var settings = ProjectEnvironmentSettings()
        settings.image = "approved:1"
        settings.network = .none
        await first.environments.update(fixture.projectB, settings: settings)
        await first.environments.setDefaults(EnvironmentDefaults(defaultImage: "default:1"))
        await fixture.quit()
        try? FileManager.default.removeItem(at: fixture.root.appending(path: "exec.json"))
        fixture.runtime.state.withLock { $0.specs = []; $0.running = [:] }

        let engine = try await fixture.launch()
        #expect(engine.root.projects.contains { $0.directory == fixture.projectB }, "warm: the cached project list was applied")
        try await assertSavedPolicyInForce(fixture, engine)
    }

    @Test func coldLaunchKeepsTheSavedRestrictivePolicy() async throws {
        let fixture = try await Fixture()
        defer { Task { await fixture.finish() } }
        try await seedPolicy(fixture)
        let engine = try await fixture.launch()
        await engine.addProject(directory: fixture.projectB)
        try await waitUntil("project") { engine.root.projects.contains { $0.directory == fixture.projectB } }
        await engine.environments.writeConfigNow()
        try await assertSavedPolicyInForce(fixture, engine)
    }

    @Test func anUnreadableSavedPolicyBlocksInsteadOfApplyingDefaults() async throws {
        let fixture = try await Fixture()
        defer { Task { await fixture.finish() } }
        try await seedPolicy(fixture)
        let store = try await ProjectionStore.open(location: .file(fixture.root.appending(path: "projection.sqlite")), changes: ChangeBus())
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE app_environment SET json = ? WHERE directory = ?", arguments: [Data("{not json".utf8), fixture.projectB])
        }
        let engine = try await fixture.launch()
        await engine.addProject(directory: fixture.projectB)
        let model = engine.environments.environment(for: fixture.projectB)
        try await waitUntil("blocked") { if case .policyUnavailable = model.phase { true } else { false } }
        await #expect(throws: EnvironmentBlockedError.self) { _ = try await engine.environments.readyContainer(fixture.projectB) }
        engine.environments.activate(fixture.projectB)
        await engine.environments.writeConfigNow()
        let workspace = try #require(try fixture.helperConfig().workspace(for: fixture.projectB))
        #expect(workspace.blocked != nil && workspace.spec == nil, "the helper refuses rather than using defaults")
        #expect(fixture.runtime.state.withLock { $0.specs }.isEmpty, "no container is created under a guessed policy")
        // Saving the setting again makes it the policy.
        var settings = ProjectEnvironmentSettings()
        settings.image = "approved:1"
        settings.network = .none
        await engine.environments.update(fixture.projectB, settings: settings)
        try await waitUntil("unblocked") { model.phase == .idle }
    }
}
