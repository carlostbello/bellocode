import ContainerKit
import Foundation
import Testing

@testable import ContainerKit
@testable import Engine

/// R07: the shared browser's runtime never stops, removes or adopts a same-name container or profile volume that
/// BelloCode did not create (a manual setup or another installation); it fails with a message naming it.
@Suite("Shared browser resource ownership", .timeLimit(.minutes(3)))
struct BrowserOwnershipTests {
    static func daemon(containerLabels: String?, volumeLabels: String?) throws -> FakeEngineServer {
        try FakeEngineServer { request, stream in
            let path = request.path
            if request.method == "GET", path.contains("/containers/"), path.hasSuffix("/json"), !path.contains("/containers/json") {
                if let containerLabels {
                    try await stream.respond(200, json: #"{"Id":"theirs","Name":"/bellocode-browser","Image":"sha256:x","State":{"Status":"running","Running":true},"Config":{"Labels":\#(containerLabels)}}"#)
                } else {
                    try await stream.respond(404, json: #"{"message":"No such container"}"#)
                }
            } else if request.method == "GET", path.contains("/volumes/") {
                if let volumeLabels {
                    try await stream.respond(200, json: #"{"Name":"bellocode-browser-profile","Labels":\#(volumeLabels)}"#)
                } else {
                    try await stream.respond(404, json: #"{"message":"no such volume"}"#)
                }
            } else {
                try await stream.respond(request.method == "DELETE" ? 204 : 201, json: #"{"Id":"new"}"#)
            }
        }
    }

    static func runtime(_ server: FakeEngineServer) -> DockerBrowserRuntime {
        DockerBrowserRuntime(socketPath: server.path, docker: nil, contextDirectory: nil, configDirectory: FileManager.default.temporaryDirectory,
                             key: { "" }, network: nil)
    }

    static func mutations(_ server: FakeEngineServer) -> [String] {
        server.requests.withLock { $0 }.filter { $0.method != "GET" }.map { "\($0.method) \($0.path)" }
    }

    static let spec = BrowserContainerSpec(image: "bellocode-browser:test", seccompProfile: "{}")

    @Test func aSameNameContainerOfSomeoneElseIsNeverStoppedOrRemoved() async throws {
        let server = try Self.daemon(containerLabels: #"{"com.example.owner":"someone"}"#, volumeLabels: nil)
        defer { server.stop() }
        let runtime = Self.runtime(server)
        let refusal = ForeignResourceError(kind: .container, name: BrowserContainerSpec.containerName)
        await #expect(throws: refusal) { _ = try await runtime.inspect() }
        await #expect(throws: refusal) { try await runtime.createAndStart(Self.spec) }
        await #expect(throws: refusal) { try await runtime.stop(timeout: 1) }
        await #expect(throws: refusal) { try await runtime.remove() }
        await #expect(throws: refusal) { try await runtime.start() }
        // N12: status, downloads and the browse/viewer address resolve the owned container first: no exec by name.
        await #expect(throws: refusal) { _ = try await runtime.status() }
        await #expect(throws: refusal) { _ = try await runtime.downloads() }
        await #expect(throws: refusal) { _ = try await runtime.download("x.pdf") }
        await #expect(throws: refusal) { _ = try await runtime.ownedContainerID() }
        #expect(Self.mutations(server).isEmpty, "\(Self.mutations(server))")
        #expect(BrowserSupervisor.describe(refusal).contains("not created by BelloCode"), "the browser pane shows why")
    }

    @Test func aSameNameProfileVolumeOfSomeoneElseIsNeverAdoptedOrCleared() async throws {
        let server = try Self.daemon(containerLabels: nil, volumeLabels: #"{"com.example.owner":"someone"}"#)
        defer { server.stop() }
        let runtime = Self.runtime(server)
        let refusal = ForeignResourceError(kind: .volume, name: BrowserContainerSpec.profileVolume)
        await #expect(throws: refusal) { try await runtime.createAndStart(Self.spec) }
        await #expect(throws: refusal) { try await runtime.removeProfile() }
        #expect(Self.mutations(server).isEmpty, "no container created on their profile, nothing deleted: \(Self.mutations(server))")
    }

    @Test func BelloCodesOwnContainerAndProfileAreStillReplacedAndCleared() async throws {
        let server = try Self.daemon(containerLabels: #"{"app.bellocode.browser":"1","app.bellocode.browser-role":"browser"}"#,
                                     volumeLabels: #"{"app.bellocode.browser":"1"}"#)
        defer { server.stop() }
        let runtime = Self.runtime(server)
        try await runtime.createAndStart(Self.spec)
        try await runtime.removeProfile()
        let mutations = Self.mutations(server)
        #expect(mutations.contains { $0.hasPrefix("DELETE") && $0.hasSuffix("/containers/theirs") })
        #expect(mutations.contains { $0.hasPrefix("POST") && $0.hasSuffix("/containers/create") })
        #expect(mutations.contains { $0.hasPrefix("DELETE") && $0.hasSuffix("/volumes/\(BrowserContainerSpec.profileVolume)") })
    }
}
