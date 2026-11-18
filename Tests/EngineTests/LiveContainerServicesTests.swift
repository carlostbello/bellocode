import BelloCore
import ContainerKit
import Foundation
import Testing

@testable import Engine

/// Opt-in, against Rancher Desktop (`BELLOCODE_CONTAINER_TESTS=1 swift test --filter LiveContainerServices`): project
/// services, the image policy, shared caches and prune through `EnvironmentService` and `LiveWorkspaceRuntime`. Pulls the
/// public `redis:7-alpine` when missing (once); uses the present `node:22-bookworm-slim`. Every project folder, container,
/// volume and network it creates is removed afterwards. No opencode server, no prompt.
@Suite(
    "Live container services", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BELLOCODE_CONTAINER_TESTS"] == "1", "set BELLOCODE_CONTAINER_TESTS=1"),
    .timeLimit(.minutes(10)))
@MainActor
struct LiveContainerServicesTests {
    static let workspaceImage = "node:22-bookworm-slim"
    static let serviceImage = "redis:7-alpine"
    let client = EngineClient(socketPath: NSHomeDirectory() + "/.rd/docker.sock")

    /// A fresh project folder (shared with Rancher's VM) and a started service over the live runtime.
    func withProject(_ files: [String: String] = [:], policy: ImagePolicy? = nil,
                     _ body: (EnvironmentService, String) async throws -> Void) async throws {
        let project = NSHomeDirectory() + "/Library/Caches/BelloCode/tests/svc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: URL(filePath: project).appending(path: name)) }
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-svc-\(UUID().uuidString.prefix(8))")
        var configuration = ContainerConfiguration(
            helperURL: URL(filePath: "/nonexistent/bellocode-exec"), execConfigURL: root.appending(path: "exec.json"), opencodeDataDirectory: nil,
            runtime: LiveWorkspaceRuntime(), registryVault: InMemorySecretVault()).projectContainerDefault()
        configuration.managedPolicy = { policy.map { .init(policy: $0, defaultImage: nil, source: "test") } }
        let service = EnvironmentService(configuration: configuration, store: try ProjectionStore(location: .inMemory))
        service.worktreeParent = { _ in root.appending(path: "worktrees").path }
        await service.start()
        var failure: (any Error)?
        do {
            try await waitUntil("runtime ready", timeout: .seconds(30)) { service.runtime?.isReady == true }
            try await body(service, project)
        } catch {
            failure = error
        }
        if let storage = try? await service.storageToPurge(project) { try? await service.purge(project, confirmed: storage) }
        service.stop()
        try? FileManager.default.removeItem(atPath: project)
        try? FileManager.default.removeItem(at: root)
        if let failure { throw failure }
    }

    func exec(_ service: EnvironmentService, _ project: String, _ script: String) async throws -> String {
        let (id, spec, _) = try await service.readyContainer(project)
        let result = try await service.activeRuntime.run(container: id, argv: ["/bin/sh", "-c", script], workingDir: project, environment: [:],
                                                         user: spec.user, timeout: .seconds(60))
        return String(decoding: result.stdout + result.stderr, as: UTF8.self)
    }

    @Test func twoServicesWithHealthGatingReachableByNameAndNeverPublished() async throws {
        guard try await client.inspectImage(Self.workspaceImage) != nil else { Issue.record("needs \(Self.workspaceImage)"); return }
        let compose = """
            services:
              cache:
                image: \(Self.serviceImage)
                ports: ["6379"]
                healthcheck:
                  test: ["CMD", "redis-cli", "ping"]
                  interval: 1s
                  timeout: 2s
                  retries: 10
                volumes: [cache-data:/data]
              app:
                image: \(Self.serviceImage)
                command: ["sh", "-c", "redis-cli -h cache set from-app ok && sleep 3600"]
                depends_on:
                  cache:
                    condition: service_healthy
              ignored-host:
                image: \(Self.serviceImage)
                privileged: true
            volumes:
              cache-data:
            """
        try await withProject(["compose.yaml": compose]) { service, project in
            var settings = service.environment(for: project).settings
            settings.image = Self.workspaceImage
            await service.update(project, settings: settings)
            service.activate(project)
            let model = service.environment(for: project)
            try await waitUntil("workspace ready", timeout: .seconds(120)) { model.phase == .ready }
            #expect(model.servicesSource == .file(project + "/compose.yaml"))
            #expect(model.services.first { $0.name == "ignored-host" }?.phase == .refused, "a privileged service is refused, not run")
            let started = await waitUntilAsync(timeout: .seconds(240)) {
                await service.refreshServices(project)
                return model.services.first { $0.name == "app" }?.phase == .running && model.services.first { $0.name == "cache" }?.health == "healthy"
            }
            #expect(started, "\(model.services)")

            // The app service reached the cache by name once it was healthy (gating), and wrote through it.
            let (logs, _) = try await service.serviceLogs(project, name: "app", tail: 20)
            #expect(logs.contains("OK"), "app's output: \(logs)")
            // The workspace container reaches the cache by name on the project network (Node, no client library).
            let reply = try await exec(service, project, """
                node -e "const s=require('net').connect(6379,'cache',()=>s.write('GET from-app\\r\\n'));s.on('data',d=>{process.stdout.write(d.toString());s.end()});s.on('error',e=>{console.log('ERR '+e.code);process.exit(1)})"
                """)
            #expect(reply.contains("ok"), "workspace → cache: \(reply)")

            // Nothing is published on the Mac; the network is the project's own.
            let cacheID = try #require(model.services.first { $0.name == "cache" }?.containerID)
            let inspect = try #require(try await client.inspectContainer(cacheID))
            #expect((inspect.ports ?? [:]).values.allSatisfy { ($0 ?? []).isEmpty }, "no published port")
            #expect(inspect.hostConfig?.networkMode == ServiceLabels.networkName(projectKey: model.projectKey, offline: false))

            // Forwarded on demand to loopback through the workspace container.
            let url = try service.forwardService(project, name: "cache", port: 6379)
            #expect(url.host == "127.0.0.1")
            service.stopServiceForward(project, name: "cache", port: 6379)

            // Restart keeps data; the data volume is listed for the explicit delete and nothing else deletes it.
            try await service.restartService(project, name: "cache")
            let volumes = try await service.serviceDataToDelete(project, name: "cache")
            #expect(volumes == ["bellocode-\(model.projectKey)-svc-cache-data"])

            // Idle stop takes the services down with the workspace.
            service.stopServices(model)
            let stopped = await waitUntilAsync(timeout: .seconds(60)) {
                await service.refreshServices(project)
                return model.services.filter { $0.phase != .refused }.allSatisfy { $0.phase == .stopped }
            }
            #expect(stopped, "\(model.services)")
            #expect(try await client.listVolumes(labels: [ServiceLabels.volume, "\(WorkspaceSpec.labelProjectKey)=\(model.projectKey)"]).count == 1)
        }
    }

    @Test func anImageOutsideThePolicyIsRefusedBeforeAnythingRuns() async throws {
        let policy = ImagePolicy(allowedPrefixes: ["registry.acme.internal/"])
        try await withProject(["compose.yaml": "services:\n  cache:\n    image: \(Self.serviceImage)\n"], policy: policy) { service, project in
            var settings = service.environment(for: project).settings
            settings.image = Self.workspaceImage
            await service.update(project, settings: settings)
            service.activate(project)
            let model = service.environment(for: project)
            try await waitUntil("refused", timeout: .seconds(20)) { if case .imageRefused = model.phase { true } else { false } }
            #expect(model.notice?.title == "Commands cannot run: the image is not allowed")
            #expect(model.services.first?.phase == .refused)
            #expect(service.helperConfig().workspaces.first { $0.container == model.containerName }?.blocked?.message.contains("image policy") == true,
                    "the helper refuses commands with the policy's message")
            #expect(try await client.listContainers(labels: ["\(WorkspaceSpec.labelProjectKey)=\(model.projectKey)"]).isEmpty, "nothing was created")
        }
    }

    @Test func aCacheVolumeSurvivesAWorkspaceRecreate() async throws {
        guard try await client.inspectImage(Self.workspaceImage) != nil else { Issue.record("needs \(Self.workspaceImage)"); return }
        try await withProject { service, project in
            var settings = service.environment(for: project).settings
            settings.image = Self.workspaceImage
            settings.caches = [CacheSelection(cache: .npm), CacheSelection(cache: .pnpm)]
            await service.update(project, settings: settings)
            service.activate(project)
            let model = service.environment(for: project)
            try await waitUntil("ready", timeout: .seconds(120)) { model.phase == .ready && model.record.containerID != nil }
            let first = try #require(model.record.containerID)
            // The user owns the cache folders (and the parents the daemon created in $HOME).
            let owned = try await exec(service, project, "echo kept > $HOME/.npm/marker && touch $HOME/.local/share/pnpm/store/x && stat -c %u $HOME/.npm $HOME/.local && cat $HOME/.npm/marker")
            #expect(owned.contains("\(getuid())\n\(getuid())\nkept"), "\(owned)")

            settings.environment = ["RECREATE": "1"]
            await service.update(project, settings: settings)
            try await waitUntil("recreated", timeout: .seconds(120)) { model.phase == .ready && model.record.containerID != nil && model.record.containerID != first }
            let after = try await exec(service, project, "cat $HOME/.npm/marker; echo $RECREATE")
            #expect(after == "kept\n1\n", "the cache volume outlived the container: \(after)")
            let caches = await service.cacheVolumes()
            #expect(Set(caches.filter { $0.projectDirectory == project }.compactMap(\.cache)) == [.npm, .pnpm])
        }
    }

    @Test func pruneRemovesOnlyTheListedBelloCodeResources() async throws {
        guard try await client.inspectImage(Self.workspaceImage) != nil else { Issue.record("needs \(Self.workspaceImage)"); return }
        let foreign = "bellocode-test-foreign-\(UUID().uuidString.prefix(6).lowercased())"
        try await client.createVolume(name: foreign, labels: ["app.bellocode.test": "1"])
        do {
            try await pruneScenario(foreign: foreign)
        } catch {
            try? await client.removeVolume(foreign)
            throw error
        }
        try? await client.removeVolume(foreign)
    }

    func pruneScenario(foreign: String) async throws {
        try await withProject(["compose.yaml": "services:\n  cache:\n    image: \(Self.serviceImage)\n"]) { service, project in
            var settings = service.environment(for: project).settings
            settings.image = Self.workspaceImage
            await service.update(project, settings: settings)
            service.activate(project)
            let model = service.environment(for: project)
            try await waitUntil("ready", timeout: .seconds(120)) { model.phase == .ready }
            let running = await waitUntilAsync(timeout: .seconds(120)) {
                await service.refreshServices(project)
                return model.services.first?.phase == .running
            }
            #expect(running)
            // Stop everything: the workspace and the service are now stopped BelloCode containers.
            service.stopServices(model)
            service.stopContainer(project)
            let stopped = await waitUntilAsync(timeout: .seconds(60)) {
                let containers = (try? await client.listContainers(labels: ["\(WorkspaceSpec.labelProjectKey)=\(model.projectKey)"])) ?? []
                return containers.count == 2 && containers.allSatisfy { !$0.isRunning }
            }
            #expect(stopped)
            // As if the project were gone from BelloCode; confirm only this project's items (other sessions' stay).
            let full = try await service.activeRuntime.prunePlan(keepProjectKeys: [], pulledImageIDs: [])
            var plan = PrunePlan()
            plan.containers = full.containers.filter { $0.name.contains(model.projectKey) }
            plan.networks = full.networks.filter { $0.name.contains(model.projectKey) }
            #expect(plan.containers.count == 2 && plan.networks.count == 1, "\(full)")
            #expect(!full.volumes.contains { $0.name == foreign }, "an unlabelled volume is never a candidate")
            let result = try await service.activeRuntime.prune(plan, keepProjectKeys: [], pulledImageIDs: [])
            #expect(result.removed.count == 3 && result.kept.isEmpty, "\(result)")
            #expect(try await client.listContainers(labels: ["\(WorkspaceSpec.labelProjectKey)=\(model.projectKey)"]).isEmpty)
            #expect(try await client.listVolumes(labels: []).contains(foreign), "nothing outside the confirmed list is touched")
            #expect(try await client.listVolumes(labels: ["\(WorkspaceSpec.labelProjectKey)=\(model.projectKey)"]).contains("bellocode-\(model.projectKey)-home"),
                    "a volume that was in use when listed is not removed")
        }
    }
}
