import Foundation
import Synchronization
import Testing

@testable import ContainerKit

@Suite("Engine client against a fake daemon")
struct EngineClientTests {
    @Test func pingAndVersion() async throws {
        let server = try FakeEngineServer { request, stream in
            switch request.path {
            case "/_ping": try await stream.respond(200, json: "OK", headers: ["Api-Version": "1.56"])
            default:
                try await stream.respond(200, json: #"{"Version":"29.9.2","ApiVersion":"1.56","MinAPIVersion":"1.41","Os":"linux","Arch":"arm64","KernelVersion":"6.18"}"#)
            }
        }
        defer { server.stop() }
        #expect(try await server.client.ping() == "1.56")
        let version = try await server.client.version()
        #expect(version.apiVersion == "1.56" && version.arch == "arm64")
        #expect(server.requests.withLock { $0.map(\.target) } == ["/_ping", "/v1.45/version"])
    }

    @Test func createContainerSendsTheSpecAndMapsErrors() async throws {
        let server = try FakeEngineServer { request, stream in
            if request.path.hasSuffix("/containers/create") {
                try await stream.respond(201, json: #"{"Id":"abc123","Warnings":[]}"#)
            } else if request.path.contains("/images/") {
                try await stream.respond(404, json: #"{"message":"No such image: x"}"#)
            } else {
                try await stream.respond(409, json: #"{"message":"container is not running"}"#)
            }
        }
        defer { server.stop() }
        let spec = WorkspaceSpec(projectRoot: "/Users/me/src/app", extraMounts: ["/Users/me/wt"], image: "img:1", user: "501:20",
                                 publishedPorts: [3000], environment: ["CI": "1"], extraLabels: ["bellocode.spike": "1"])
        let id = try await server.client.createContainer(name: spec.containerName, spec.createBody(imageID: "sha256:1"))
        #expect(id == "abc123")
        let request = try #require(server.requests.withLock { $0.first })
        #expect(request.target.contains("name=bellocode-ws-"))
        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["Image"] as? String == "sha256:1")
        #expect(body["User"] as? String == "501:20")
        #expect(body["WorkingDir"] as? String == "/Users/me/src/app")
        let host = try #require(body["HostConfig"] as? [String: Any])
        #expect(host["Privileged"] as? Bool == false)
        #expect(host["CapDrop"] as? [String] == ["ALL"])
        let mounts = try #require(host["Mounts"] as? [[String: Any]])
        #expect(mounts.contains { $0["Source"] as? String == "/Users/me/src/app" && $0["Target"] as? String == "/Users/me/src/app" })
        let bindings = try #require((host["PortBindings"] as? [String: [[String: String]]])?["3000/tcp"])
        #expect(bindings == [["HostIp": "127.0.0.1", "HostPort": ""]], "loopback only")
        #expect(try await server.client.inspectImage("x") == nil)
        await #expect(throws: EngineError.conflict("container is not running")) { try await server.client.killContainer("abc123") }
    }

    @Test func chunkedEventStreamIsDecodedIncrementally() async throws {
        let server = try FakeEngineServer { _, stream in
            let first = Data(#"{"Type":"container","Action":"start","Actor":{"ID":"c1","Attributes":{"app.bellocode.workspace":"1"}},"time":1}"#.utf8)
            let second = Data("\n{\"Type\":\"container\",\"Action\":\"die\",\"Actor\":{\"ID\":\"c1\",\"Attributes\":{}}}\n".utf8)
            // Split a JSON line across chunks.
            try await stream.respondChunked(200, chunks: [first.prefix(20), first.dropFirst(20), second])
        }
        defer { server.stop() }
        var actions: [String] = []
        for try await event in try await server.client.events(labels: ["app.bellocode.workspace=1"]) { actions.append(event.action) }
        #expect(actions == ["start", "die"])
        let target = server.requests.withLock { $0.first?.target ?? "" }
        #expect(target.contains("filters="))
    }

    @Test func pullReportsDaemonErrors() async throws {
        let server = try FakeEngineServer { _, stream in
            try await stream.respondChunked(200, chunks: [
                Data(#"{"status":"Pulling from library/x","id":"1"}"#.utf8 + Data("\n".utf8)),
                Data(#"{"errorDetail":{"message":"denied"},"error":"denied: requested access to the resource is denied"}"#.utf8 + Data("\n".utf8)),
            ])
        }
        defer { server.stop() }
        let seen = Mutex(0)
        await #expect(throws: EngineError.progress("denied: requested access to the resource is denied")) {
            try await server.client.pullImage("x:1") { _ in seen.withLock { $0 += 1 } }
        }
        #expect(seen.withLock { $0 } == 1)
    }

    @Test func execHijackCarriesStdinAndDemultiplexedOutput() async throws {
        let server = try FakeEngineServer { request, stream in
            switch request.path {
            case let path where path.hasSuffix("/exec"):
                try await stream.respond(201, json: #"{"Id":"exec1"}"#)
            case let path where path.hasSuffix("/start"):
                try await stream.write(Data("HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n".utf8)
                                       + StreamDemuxer.frame(.stdout, Data("ready\n".utf8)))
                // Echo stdin back as stdout and stderr frames until the client half-closes.
                while let data = try? await stream.read(), !data.isEmpty {
                    try await stream.write(StreamDemuxer.frame(.stdout, data) + StreamDemuxer.frame(.stderr, Data("e".utf8)))
                }
                try await stream.write(StreamDemuxer.frame(.stdout, Data("bye".utf8)))
            case let path where path.hasSuffix("/json"):
                try await stream.respond(200, json: #"{"ID":"exec1","Running":false,"ExitCode":3,"Pid":9}"#)
            default:
                try await stream.respond(404, json: #"{"message":"?"}"#)
            }
        }
        defer { server.stop() }
        let session = try await ExecSession.start(client: server.client, container: "c1", argv: ["cat"], workingDir: "/w",
                                                  environment: ["SECRET": "s3cr3t"], tty: false)
        var out = Data(), err = Data()
        var sent = false
        for try await chunk in session.output() {
            if chunk.stream == .stderr { err += chunk.bytes } else { out += chunk.bytes }
            if !sent, out == Data("ready\n".utf8) {
                sent = true
                try await session.write(Data("ping".utf8))
            } else if out.count >= 10, err.count == 1, sent {
                session.closeStdin()
            }
        }
        #expect(String(decoding: out, as: UTF8.self) == "ready\npingbye")
        #expect(err == Data("e".utf8))
        #expect(try await session.exitCode() == 3)
        let create = try #require(server.requests.withLock { $0.first { $0.path.hasSuffix("/exec") } })
        let body = try #require(try JSONSerialization.jsonObject(with: create.body) as? [String: Any])
        #expect(body["AttachStdin"] as? Bool == true)
        #expect(body["Env"] as? [String] == ["SECRET=s3cr3t"], "secrets travel per exec, in the request body only")
        let start = try #require(server.requests.withLock { $0.first { $0.path.hasSuffix("/start") } })
        #expect(start.headers["upgrade"] == "tcp")
    }

    @Test func refusedSocketIsReportedAsNotRunning() async throws {
        let client = EngineClient(socketPath: "/tmp/bcck-missing-\(UUID().uuidString.prefix(6)).sock")
        do {
            _ = try await client.ping()
            Issue.record("expected a failure")
        } catch let error as SocketError {
            #expect(error.isConnectionRefusedOrMissing)
        }
    }
}
