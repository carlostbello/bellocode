import Foundation
import Testing

@testable import ContainerKit

/// R07 (docs/reviews/release-1.0-review.md): a Docker object with one of BelloCode's names but without BelloCode's
/// labels belongs to someone else. It is never stopped, removed, recreated or adopted; the operation fails with
/// `ForeignResourceError`, which names it.
@Suite("Docker resource ownership", .timeLimit(.minutes(3)))
struct ResourceOwnershipTests {
    /// A daemon where every container, volume and network exists with someone else's labels (or, for the names in
    /// `owned`, with the given labels), and images exist. Mutations are recorded and answered with success.
    static func daemon(owned: [String: String] = [:], internalNetworks: Bool = true) throws -> FakeEngineServer {
        try FakeEngineServer { request, stream in
            let path = request.path
            func labels(_ name: String) -> String { owned[name] ?? #"{"com.example.owner":"someone"}"# }
            if request.method == "GET", path.contains("/images/") {
                try await stream.respond(200, json: #"{"Id":"sha256:img"}"#)
            } else if request.method == "GET", path.contains("/containers/json") {
                try await stream.respond(200, json: "[]")
            } else if request.method == "GET", let range = path.range(of: "/containers/"), path.hasSuffix("/json") {
                let name = String(path[range.upperBound...].dropLast("/json".count))
                try await stream.respond(200, json: #"{"Id":"id-\#(name)","Name":"/\#(name)","Image":"sha256:img","State":{"Status":"running","Running":true},"Config":{"Labels":\#(labels(name))}}"#)
            } else if request.method == "GET", let range = path.range(of: "/volumes/") {
                let name = String(path[range.upperBound...])
                try await stream.respond(200, json: #"{"Name":"\#(name)","Labels":\#(labels(name))}"#)
            } else if request.method == "GET", let range = path.range(of: "/networks/") {
                let name = String(path[range.upperBound...])
                try await stream.respond(200, json: #"{"Id":"net-\#(name)","Name":"\#(name)","Internal":\#(internalNetworks),"Labels":\#(labels(name))}"#)
            } else {
                try await stream.respond(request.method == "DELETE" ? 204 : 201, json: #"{"Id":"new"}"#)
            }
        }
    }

    static func mutations(_ server: FakeEngineServer) -> [String] {
        server.requests.withLock { $0 }.filter { $0.method != "GET" }.map { "\($0.method) \($0.path)" }
    }

    @Test func theEgressGatewayNeverRemovesOrReplacesASameNameContainerOfSomeoneElse() async throws {
        let key = "k1"
        let server = try Self.daemon(owned: [EgressGateway.networkName(key): #"{"app.bellocode.egress":"1","app.bellocode.egress-scope":"k1"}"#])
        defer { server.stop() }
        let gateway = EgressGateway(client: server.client)
        await #expect(throws: ForeignResourceError(kind: .container, name: EgressGateway.containerName(key))) {
            try await gateway.ensure(EgressGatewaySpec(scopeKey: key, image: "img", proxyPort: 1, token: "t"))
        }
        await gateway.remove(scopeKey: key, network: false)
        await #expect(throws: ForeignResourceError.self) { try await gateway.attach(scopeKey: key, network: "bellocode-net-x") }
        await gateway.detach(scopeKey: key, network: "bellocode-net-x")
        #expect(Self.mutations(server).isEmpty, "nothing stopped, removed, created or connected: \(Self.mutations(server))")
    }

    @Test func theEgressNetworkOfSomeoneElseIsNeitherAdoptedNorRemoved() async throws {
        let server = try Self.daemon()
        defer { server.stop() }
        let gateway = EgressGateway(client: server.client)
        await #expect(throws: ForeignResourceError(kind: .network, name: EgressGateway.networkName("k2"))) {
            try await gateway.ensureNetwork(scopeKey: "k2")
        }
        await gateway.remove(scopeKey: "k2", network: true)
        #expect(Self.mutations(server).isEmpty, "\(Self.mutations(server))")
    }

    @Test func aWorkspaceNeverMountsASameNameVolumeOfSomeoneElse() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bc-own-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let server = try Self.daemon()
        defer { server.stop() }
        let spec = WorkspaceSpec(projectRoot: root, image: "img")
        await #expect(throws: WorkspaceError.foreign(ForeignResourceError(kind: .volume, name: spec.volumeName("home")))) {
            try await WorkspaceManager(client: server.client).ensureRunning(spec)
        }
        #expect(!Self.mutations(server).contains { $0.hasSuffix("/containers/create") || $0.contains("/volumes/create") },
                "no container created over someone else's volume: \(Self.mutations(server))")
    }

    @Test func servicesNeverAdoptASameNameNetworkOrVolumeOfSomeoneElse() async throws {
        let server = try Self.daemon()
        defer { server.stop() }
        await #expect(throws: ForeignResourceError.self) {
            _ = try await ServiceManager(client: server.client).ensureNetwork(projectRoot: "/p", offline: false)
        }
        await #expect(throws: ForeignResourceError(kind: .volume, name: "bellocode-x")) {
            try await server.client.ensureOwnedVolume(name: "bellocode-x", labels: ["a": "1"], required: ["a": "1"])
        }
        #expect(Self.mutations(server).isEmpty, "\(Self.mutations(server))")
    }

    @Test func ownedObjectsAreStillManaged() async throws {
        let key = "k3"
        let ours = #"{"app.bellocode.egress":"1","app.bellocode.egress-scope":"k3"}"#
        let server = try Self.daemon(owned: [EgressGateway.networkName(key): ours, EgressGateway.containerName(key): ours])
        defer { server.stop() }
        await EgressGateway(client: server.client).remove(scopeKey: key, network: true)
        let mutations = Self.mutations(server)
        #expect(mutations.contains { $0.hasPrefix("DELETE") && $0.hasSuffix("/containers/id-\(EgressGateway.containerName(key))") })
        #expect(mutations.contains { $0.hasPrefix("DELETE") && $0.hasSuffix("/networks/net-\(EgressGateway.networkName(key))") })
        #expect(ResourceOwnership.isOwned(["a": "1", "b": "2"], by: ["a": "1"]))
        #expect(!ResourceOwnership.isOwned(["a": "2"], by: ["a": "1"]))
        #expect(!ResourceOwnership.isOwned(nil, by: ["a": "1"]))
        #expect(!ResourceOwnership.isOwned(["a": "1"], by: [:]), "no rule never proves ownership")
    }

    @Test func theRefusalNamesTheObjectAndWhatToDo() {
        let text = ForeignResourceError(kind: .container, name: "bellocode-browser").description
        #expect(text.contains("bellocode-browser") && text.contains("not created by BelloCode") && text.contains("docker container rm"))
        #expect(ContainerError.from(ForeignResourceError(kind: .volume, name: "v")).description.contains("not created by BelloCode"))
    }
}
