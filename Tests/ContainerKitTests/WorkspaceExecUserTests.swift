import Foundation
import Synchronization
import Testing

@testable import ContainerKit

/// AF10 follow-up: every exec into a workspace container (commands, probes, port relays) and into a secret-command
/// container runs as the numeric `uid:gid` the container was created with, never as a name Docker would resolve from the
/// container's own (possibly rewritten) /etc/passwd; a container whose user is not a nonzero numeric `uid:gid` gets no
/// exec at all.
@Suite("Workspace exec user", .timeLimit(.minutes(3)))
struct WorkspaceExecUserTests {
    /// A daemon with one workspace container (`ws-id`, configured user `user`), an image whose /etc/passwd defines
    /// `node` as 1000:1000, and execs that end at once (a secret command's exec reads its stdin to the end first).
    static func daemon(user: @escaping @Sendable () -> String) throws -> FakeEngineServer {
        try FakeEngineServer { request, stream in
            let path = request.path
            if request.method == "GET", path.contains("/images/") {
                try await stream.respond(200, json: #"{"Id":"sha256:img"}"#)
            } else if request.method == "GET", path.hasSuffix("/archive") {
                let name = request.target.contains("passwd") ? "passwd" : "group"
                let file = name == "passwd" ? WorkspaceUserTests.passwd : WorkspaceUserTests.group
                let tar = TarArchive([.init(path: name, contents: Data(file.utf8))]).data()
                try await stream.write(Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-tar\r\nContent-Length: \(tar.count)\r\n\r\n".utf8) + tar)
            } else if request.method == "GET", path.hasPrefix("/v1.44/exec/") || path.hasPrefix("/exec/") {
                try await stream.respond(200, json: #"{"ID":"x","Running":false,"ExitCode":0,"Pid":9}"#)
            } else if request.method == "GET", path.hasSuffix("/json"), path.contains("/containers/") {
                let configured = user()
                try await stream.respond(200, json: #"{"Id":"ws-id","Name":"/bellocode-ws-x","Image":"sha256:img","State":{"Status":"running","Running":true},"Config":{"User":"\#(configured)","Labels":{}}}"#)
            } else if request.method == "POST", path.hasSuffix("/exec") {
                let secret = String(decoding: request.body, as: UTF8.self).contains("bellocode-secret")
                try await stream.respond(201, json: secret ? #"{"Id":"secret"}"# : #"{"Id":"plain"}"#)
            } else if request.method == "POST", path.hasSuffix("/start"), path.contains("/exec/") {
                try await stream.write(Data("HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n".utf8))
                if path.contains("/exec/secret/") {
                    while let data = try? await stream.read(), !data.isEmpty {}
                }
            } else if request.method == "POST", path.hasSuffix("/containers/create") {
                try await stream.respond(201, json: #"{"Id":"c\#(UUID().uuidString.prefix(6))"}"#)
            } else if request.method == "POST" || request.method == "DELETE" {
                try await stream.respond(204)
            } else {
                try await stream.respond(404, json: #"{"message":"not in this test"}"#)
            }
        }
    }

    /// The exec-create requests: the container they target and the user they carry.
    static func execs(_ server: FakeEngineServer) throws -> [(container: String, user: String?)] {
        try server.requests.withLock { $0 }.filter { $0.method == "POST" && $0.path.hasSuffix("/exec") }.map { request in
            let parts = request.path.split(separator: "/")
            let object = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            return (String(parts[parts.count - 2]), object["User"] as? String)
        }
    }

    /// Every workspace exec path, each run once against the container named `bellocode-ws-x`.
    static func everyPath(_ manager: WorkspaceManager) -> [(String, @Sendable () async throws -> Void)] {
        let name = "bellocode-ws-x"
        return [
            ("run", { _ = try await manager.run(container: name, argv: ["true"]) }),
            ("start", { try await manager.start(container: name, argv: ["true"], workingDir: nil, environment: [:], tty: true).session.close() }),
            ("listeningPorts", { _ = try await manager.listeningPorts(container: name) }),
            ("processes", { _ = try await manager.processes(container: name) }),
            ("reap", { _ = try await manager.reap(container: name) }),
            ("inventory", { _ = try await manager.inventory(container: name) }),
            ("touch", { try await manager.touch(container: name, paths: ["/w/a"]) }),
        ]
    }

    @Test func everyExecCarriesTheContainersNumericUserAndID() async throws {
        let user = Mutex("1000:1000")
        let server = try Self.daemon { user.withLock { $0 } }
        defer { server.stop() }
        let manager = WorkspaceManager(client: server.client)
        for (name, path) in Self.everyPath(manager) {
            let before = try Self.execs(server).count
            try await path()
            let made = try Self.execs(server).dropFirst(before)
            #expect(made.count == 1, "\(name)")
            for exec in made {
                #expect(exec.user == "1000:1000", "\(name) ran as \(exec.user ?? "the image's user")")
                #expect(exec.container == "ws-id", "\(name) exec'd into \(exec.container), not the inspected container's ID")
            }
        }
        #expect(try await manager.execTarget(container: "bellocode-ws-x") == WorkspaceExecTarget(containerID: "ws-id", user: "1000:1000"))
    }

    /// A container created with a name (an earlier version), without a group, as root, or with the image's default user
    /// gets no exec: Docker would resolve each from the container's own files at the exec.
    @Test func aContainerWithoutAVerifiedNumericUserGetsNoExec() async throws {
        let user = Mutex("")
        let server = try Self.daemon { user.withLock { $0 } }
        defer { server.stop() }
        let manager = WorkspaceManager(client: server.client)
        for configured in ["node", "1000", "0:0", "0:1000", "root", "", "node:1000", "1000:node"] {
            user.withLock { $0 = configured }
            for (name, path) in Self.everyPath(manager) {
                await #expect(throws: WorkspaceError.unverifiedUser(container: "bellocode-ws-x", user: configured), "\(name), \(configured)") {
                    try await path()
                }
            }
        }
        #expect(try Self.execs(server).isEmpty, "no exec was created")
    }

    /// A workspace port relay (dev-server and service forwards, the shared browser's routes) runs as the verified
    /// numbers; without them the connection is closed and nothing is exec'd.
    @Test func workspacePortRelaysRunAsTheVerifiedUser() async throws {
        let user = Mutex("1000:1000")
        let server = try Self.daemon { user.withLock { $0 } }
        defer { server.stop() }
        let forwarder = try PortForwarder(client: server.client, container: "bellocode-ws-x", containerPort: 3000, workspace: true)
        let task = Task { await forwarder.run() }
        defer {
            forwarder.stop()
            task.cancel()
        }
        #expect(PortForwarderTests.connectAndReadToEnd(forwarder.hostPort))
        #expect(try Self.execs(server).map(\.user) == ["1000:1000"])
        #expect(try Self.execs(server).map(\.container) == ["ws-id"])
        user.withLock { $0 = "node" }
        #expect(PortForwarderTests.connectAndReadToEnd(forwarder.hostPort), "closed at once")
        #expect(try Self.execs(server).count == 1, "no relay as a name")
    }

    /// The one-shot secret-command container is created and exec'd as the numbers its image gives the name.
    @Test func aSecretCommandRunsAsTheResolvedNumbers() async throws {
        let server = try Self.daemon { "node" }
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appending(path: "bc-exec-user-\(UUID().uuidString)").path
        var spec = WorkspaceSpec(projectRoot: root, image: "img")
        spec.user = "node"
        _ = try await WorkspaceManager(client: server.client).runSecretCommand(
            spec, shell: "/bin/sh", command: "true", workingDir: root, name: "TOKEN", secret: Data("s".utf8), policy: SecretCommandPolicy())
        let creates = try server.requests.withLock { $0 }.filter { $0.method == "POST" && $0.path.hasSuffix("/containers/create") }
            .compactMap { try JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
        #expect(creates.last?["User"] as? String == "1000:1000")
        #expect(try Self.execs(server).map(\.user) == ["1000:1000"])
    }

    /// The numbers a workspace is created with always include the group, so no exec leaves it to /etc/passwd: a bare
    /// uid takes its primary group from the image's files (group 0 when the image does not list it, as Docker does).
    @Test func aBareUidIsRecordedWithItsGroup() async throws {
        let server = try Self.daemon { "" }
        defer { server.stop() }
        let manager = WorkspaceManager(client: server.client)
        var spec = WorkspaceSpec(projectRoot: "/Users/me/app", image: "img")
        for (configured, expected) in [("1000", "1000:1000"), ("4242", "4242:0"), ("501:20", "501:20"), ("node", "1000:1000"), ("app", "1001:50")] {
            spec.user = configured
            #expect(try await manager.verifiedUser(spec, imageID: "sha256:img").numeric == expected, "\(configured)")
        }
    }
}
