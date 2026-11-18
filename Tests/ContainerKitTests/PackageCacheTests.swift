import Foundation
import Synchronization
import Testing

@testable import ContainerKit

@Suite("Package caches", .timeLimit(.minutes(3)))
struct PackageCacheTests {
    @Test func imagesDeclareCachesAndPaths() {
        let declared = PackageCache.declared(byImageLabels: [
            PackageCache.imageLabel: "npm, PIP,unknown", PackageCache.pathLabel(.pip): "/opt/pip-cache", PackageCache.pathLabel(.go): "/go/mod",
            PackageCache.pathLabel(.npm): "relative/ignored",
        ])
        #expect(declared == [.npm: "/home/bellocode/.npm", .pip: "/opt/pip-cache", .go: "/go/mod"])
        #expect(PackageCache.declared(byImageLabels: nil).isEmpty)
    }

    @Test func mountsAreProjectScopedUnlessShared() throws {
        var spec = WorkspaceSpec(projectRoot: "/Users/a/p", image: "node:22")
        spec.cacheMounts = [CacheMount(cache: .npm, path: PackageCache.npm.defaultPath),
                            CacheMount(cache: .pnpm, path: PackageCache.pnpm.defaultPath, shared: true)]
        let mounts = try #require(spec.createBody(imageID: nil).hostConfig?.mounts)
        #expect(mounts.contains(Mount(type: .volume, source: "bellocode-\(spec.projectKey)-cache-npm", target: "/home/bellocode/.npm")))
        #expect(mounts.contains(Mount(type: .volume, source: "bellocode-shared-cache-pnpm", target: "/home/bellocode/.local/share/pnpm/store")))
        let home = try #require(mounts.firstIndex { $0.target == WorkspaceSpec.home })
        #expect(mounts.firstIndex { $0.target == "/home/bellocode/.npm" }! > home, "the home volume is listed before caches nested in it")
        let projectLabels = spec.cacheMounts![0].volumeLabels(projectRoot: spec.projectRoot, projectKey: spec.projectKey)
        #expect(projectLabels[WorkspaceSpec.labelProjectKey] == spec.projectKey, "a project cache is deleted with the project")
        let sharedLabels = spec.cacheMounts![1].volumeLabels(projectRoot: spec.projectRoot, projectKey: spec.projectKey)
        #expect(sharedLabels[WorkspaceSpec.labelProjectKey] == nil && sharedLabels[PackageCache.sharedLabel] == "1",
                "a shared cache belongs to no project: deleting one project never deletes it")
        let without = WorkspaceSpec(projectRoot: "/Users/a/p", image: "node:22")
        #expect(without.configHash(imageID: "i") != spec.configHash(imageID: "i"), "changing caches recreates the container")
    }

    @Test func cleaningRefusesWhileARunningContainerUsesTheCache() async throws {
        let removed = Mutex<[String]>([])
        let running = Mutex(true)
        let server = try FakeEngineServer { request, stream in
            let path = request.path.replacingOccurrences(of: #"^/v[0-9.]+"#, with: "", options: .regularExpression)
            switch (request.method, path) {
            case ("GET", "/volumes"):
                try await stream.respond(200, json: #"{"Volumes":[{"Name":"bellocode-k-cache-npm","Labels":{"app.bellocode.cache":"npm","app.bellocode.project-key":"k"}}]}"#)
            case ("GET", "/containers/json"):
                let state = running.withLock { $0 } ? "running" : "exited"
                try await stream.respond(200, json: #"[{"Id":"ws1","Names":["/bellocode-ws-k"],"Image":"i","State":"\#(state)","Labels":{"app.bellocode.workspace":"1"}}]"#)
            case ("DELETE", let p):
                removed.withLock { $0.append(p) }
                try await stream.respond(204)
            default:
                try await stream.respond(404, json: #"{"message":"?"}"#)
            }
        }
        defer { server.stop() }
        let manager = WorkspaceManager(client: server.client)
        await #expect(throws: ContainerError.self) { try await manager.cleanCache("bellocode-k-cache-npm") }
        #expect(removed.withLock { $0 }.isEmpty, "nothing removed while in use")
        running.withLock { $0 = false }
        try await manager.cleanCache("bellocode-k-cache-npm")
        #expect(removed.withLock { $0 } == ["/containers/ws1", "/volumes/bellocode-k-cache-npm"])
        await #expect(throws: ContainerError.self) { try await manager.cleanCache("someone-elses-volume") }
    }
}
