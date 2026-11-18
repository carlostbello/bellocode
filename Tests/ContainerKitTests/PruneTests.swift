import Foundation
import Synchronization
import Testing

@testable import ContainerKit

/// "Prune BelloCode Resources": selection and removal against a fake daemon that also holds other software's resources.
@Suite("Prune", .timeLimit(.minutes(3)))
struct PruneTests {
    struct Container: Sendable { var id: String; var name: String; var state: String; var labels: [String: String]; var image: String; var volumes: [String] }
    struct Volume: Sendable { var name: String; var labels: [String: String] }
    struct Network: Sendable { var id: String; var name: String; var labels: [String: String]; var containers: [String] }
    struct Image: Sendable { var id: String; var tag: String }

    final class Daemon: Sendable {
        let containers: Mutex<[Container]>
        let volumes: Mutex<[Volume]>
        let networks: Mutex<[Network]>
        let images: Mutex<[Image]>
        let deleted = Mutex<[String]>([])

        init(containers: [Container], volumes: [Volume], networks: [Network], images: [Image]) {
            self.containers = Mutex(containers)
            self.volumes = Mutex(volumes)
            self.networks = Mutex(networks)
            self.images = Mutex(images)
        }

        static func filters(_ target: String) -> [String: [String]] {
            guard let raw = URLComponents(string: target)?.queryItems?.first(where: { $0.name == "filters" })?.value,
                  let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: [String]] else { return [:] }
            return object
        }

        static func matches(_ labels: [String: String], _ filters: [String]) -> Bool {
            filters.allSatisfy { filter in
                let parts = filter.split(separator: "=", maxSplits: 1).map(String.init)
                return parts.count == 1 ? labels[parts[0]] != nil : labels[parts[0]] == parts[1]
            }
        }

        static func json(_ value: Any) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), as: UTF8.self) }

        func handle(_ request: FakeEngineServer.Request, _ stream: FileStream) async throws {
            let path = request.path.replacingOccurrences(of: #"^/v[0-9.]+"#, with: "", options: .regularExpression)
            let filters = Self.filters(request.target)
            switch (request.method, path) {
            case ("GET", "/containers/json"):
                let rows = containers.withLock { $0 }.filter { container in
                    Self.matches(container.labels, filters["label"] ?? []) && (filters["volume"].map { $0.allSatisfy(container.volumes.contains) } ?? true)
                }.map { ["Id": $0.id, "Names": ["/" + $0.name], "Image": $0.image, "ImageID": $0.image, "State": $0.state, "Labels": $0.labels] as [String: Any] }
                try await stream.respond(200, json: Self.json(rows))
            case ("GET", "/volumes"):
                let rows = volumes.withLock { $0 }.filter { Self.matches($0.labels, filters["label"] ?? []) }.map { ["Name": $0.name, "Labels": $0.labels] as [String: Any] }
                try await stream.respond(200, json: Self.json(["Volumes": rows]))
            case ("GET", "/networks"):
                let rows = networks.withLock { $0 }.filter { Self.matches($0.labels, filters["label"] ?? []) }.map { ["Id": $0.id] }
                try await stream.respond(200, json: Self.json(rows))
            case ("GET", let p) where p.hasPrefix("/networks/"):
                let id = String(p.dropFirst("/networks/".count))
                guard let network = networks.withLock({ $0.first { $0.id == id } }) else { return try await stream.respond(404, json: #"{"message":"no"}"#) }
                let attached = Dictionary(uniqueKeysWithValues: network.containers.map { ($0, [String: Any]()) })
                try await stream.respond(200, json: Self.json(["Id": network.id, "Name": network.name, "Labels": network.labels, "Containers": attached] as [String: Any]))
            case ("GET", "/images/json"):
                try await stream.respond(200, json: Self.json(images.withLock { $0 }.map { ["Id": $0.id, "RepoTags": [$0.tag], "Size": 1000] as [String: Any] }))
            case ("DELETE", let p):
                deleted.withLock { $0.append(p) }
                try await stream.respond(204)
            default:
                try await stream.respond(404, json: #"{"message":"unexpected"}"#)
            }
        }
    }

    static let ws = WorkspaceSpec.labelWorkspace
    static let key = WorkspaceSpec.labelProjectKey

    func daemon() -> Daemon {
        Daemon(
            containers: [
                Container(id: "c-stopped", name: "bellocode-ws-gone", state: "exited", labels: [Self.ws: "1", Self.key: "gone"], image: "sha256:node", volumes: []),
                Container(id: "c-running", name: "bellocode-ws-live", state: "running", labels: [Self.ws: "1", Self.key: "live"], image: "sha256:node", volumes: ["bellocode-live-home"]),
                Container(id: "c-svc", name: "bellocode-svc-gone-db", state: "exited", labels: [ServiceLabels.service: "db", Self.key: "gone"], image: "sha256:pg", volumes: []),
                Container(id: "c-secret", name: "bellocode-secret-x", state: "created", labels: [WorkspaceSpec.labelSecretCommand: "1"], image: "sha256:node", volumes: []),
                Container(id: "c-foreign", name: "someone-elses-db", state: "exited", labels: ["com.example": "1"], image: "sha256:redis", volumes: ["foreign-data"]),
            ],
            volumes: [
                Volume(name: "bellocode-gone-home", labels: [Self.ws: "1", Self.key: "gone"]),
                Volume(name: "bellocode-live-home", labels: [Self.ws: "1", Self.key: "live"]),
                Volume(name: "bellocode-kept-home", labels: [Self.ws: "1", Self.key: "kept"]),
                Volume(name: "bellocode-shared-cache-npm", labels: [PackageCache.volumeLabel: "npm", PackageCache.sharedLabel: "1"]),
                Volume(name: "bellocode-gone-svc-data", labels: [ServiceLabels.volume: "data", Self.key: "gone"]),
                Volume(name: "foreign-data", labels: [:]),
            ],
            networks: [
                Network(id: "n-empty", name: "bellocode-net-gone", labels: [ServiceLabels.network: "1"], containers: []),
                Network(id: "n-used", name: "bellocode-net-live", labels: [ServiceLabels.network: "1"], containers: ["c-running"]),
                Network(id: "n-foreign", name: "other", labels: [:], containers: []),
            ],
            images: [
                Image(id: "sha256:pulled-unused", tag: "redis:7-alpine"), Image(id: "sha256:node", tag: "node:22"),
                Image(id: "sha256:theirs", tag: "theirs:1"),
            ])
    }

    @Test func listsOnlyBelloCodesUnusedResources() async throws {
        let daemon = daemon()
        let server = try FakeEngineServer { try await daemon.handle($0, $1) }
        defer { server.stop() }
        let plan = try await WorkspaceManager(client: server.client).prunePlan(
            keepProjectKeys: ["kept", "live"], pulledImageIDs: ["sha256:pulled-unused", "sha256:node"])
        #expect(plan.containers.map(\.name) == ["bellocode-secret-x", "bellocode-svc-gone-db", "bellocode-ws-gone"],
                "stopped BelloCode containers only: not the running one, not another program's")
        #expect(plan.volumes.map(\.name) == ["bellocode-gone-home", "bellocode-gone-svc-data"],
                "a known project's volumes, a used one, a shared cache and foreign volumes are kept")
        #expect(plan.networks.map(\.name) == ["bellocode-net-gone"])
        #expect(plan.images.map(\.name) == ["redis:7-alpine"], "an image in use or not pulled by BelloCode is kept")
        #expect(plan.count == 7)
    }

    @Test func removesOnlyWhatStillQualifies() async throws {
        let daemon = daemon()
        let server = try FakeEngineServer { try await daemon.handle($0, $1) }
        defer { server.stop() }
        let manager = WorkspaceManager(client: server.client)
        let plan = try await manager.prunePlan(keepProjectKeys: ["kept", "live"], pulledImageIDs: ["sha256:pulled-unused"])
        // Between the listing and the confirmation, the stopped workspace starts again.
        daemon.containers.withLock { containers in
            if let index = containers.firstIndex(where: { $0.id == "c-stopped" }) { containers[index].state = "running" }
        }
        let result = try await manager.prune(plan, keepProjectKeys: ["kept", "live"], pulledImageIDs: ["sha256:pulled-unused"])
        #expect(result.kept == ["bellocode-ws-gone"])
        let deleted = daemon.deleted.withLock { $0 }
        #expect(Set(deleted) == ["/containers/c-secret", "/containers/c-svc", "/networks/n-empty", "/volumes/bellocode-gone-home",
                                 "/volumes/bellocode-gone-svc-data", "/images/sha256:pulled-unused"], "\(deleted)")
        #expect(!deleted.contains { $0.contains("foreign") || $0.contains("other") || $0.contains("theirs") || $0.contains("shared") })
    }
}
