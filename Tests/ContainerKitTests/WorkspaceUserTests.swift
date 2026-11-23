import Foundation
import Synchronization
import Testing

@testable import ContainerKit

/// AF09, AF10: a workspace runs as a numeric, non-root user known before any program of its image starts, nothing in it
/// runs as root, and only a container that runs as such a user is reused or adopted.
@Suite("Workspace user", .timeLimit(.minutes(3)))
struct WorkspaceUserTests {
    static let passwd = """
        root:x:0:0:root:/root:/bin/bash
        node:x:1000:1000::/home/node:/bin/sh
        dev:x:0:0:looks harmless:/home/dev:/bin/sh
        app:x:1001:50::/home/app:/bin/sh

        """
    static let group = "root:x:0:\nstaff:x:50:app\nnode:x:1000:\n"

    func resolve(_ value: String) -> WorkspaceUser? { WorkspaceUser.resolve(value, passwd: Self.passwd, group: Self.group) }

    @Test func namesAndGroupsResolveAsDockerDoes() {
        #expect(resolve("node") == WorkspaceUser(uid: 1000, gid: 1000))
        #expect(resolve("dev") == WorkspaceUser(uid: 0, gid: 0), "a plausible name can be uid 0")
        #expect(resolve("app") == WorkspaceUser(uid: 1001, gid: 50), "the primary group from /etc/passwd")
        #expect(resolve("node:staff") == WorkspaceUser(uid: 1000, gid: 50))
        #expect(resolve("node:7") == WorkspaceUser(uid: 1000, gid: 7))
        #expect(resolve("1000") == WorkspaceUser(uid: 1000, gid: 1000), "a number with an entry takes its group")
        #expect(resolve("4242") == WorkspaceUser(uid: 4242, gid: nil))
        #expect(resolve(" node ") == WorkspaceUser(uid: 1000, gid: 1000))
        #expect(resolve("nobody") == nil)
        #expect(resolve("node:nogroup") == nil)
        #expect(WorkspaceUser.resolve("node", passwd: nil, group: nil) == nil, "no /etc/passwd: a name cannot be resolved")
        #expect(resolve("") == nil)
    }

    @Test func onlyNumbersAreTakenWithoutTheImage() {
        #expect(WorkspaceUser.numeric("501:20") == WorkspaceUser(uid: 501, gid: 20))
        #expect(WorkspaceUser.numeric("501") == WorkspaceUser(uid: 501, gid: nil))
        for value in ["node", "1000:staff", "-1", "+5", "1e3", "", ":20", "99999999999"] {
            #expect(WorkspaceUser.numeric(value) == nil, "\(value)")
        }
        #expect(WorkspaceUser(uid: 501, gid: 20).numeric == "501:20")
        #expect(WorkspaceUser(uid: 501, gid: nil).numeric == "501")
    }

    @Test func onlyANonzeroNumericContainerUserIsVerified() {
        for value in ["1000:1000", "501", "65534:65534"] { #expect(WorkspaceUser.isVerifiedContainerUser(value), "\(value)") }
        for value in ["0", "0:0", "00", "root", "node", "", "1000:staff"] as [String] {
            #expect(!WorkspaceUser.isVerifiedContainerUser(value), "\(value)")
        }
        #expect(!WorkspaceUser.isVerifiedContainerUser(nil))
    }

    @Test func theAccountFileIsReadOnlyWhenTheArchiveHoldsARegularFile() {
        let contents = Data(Self.passwd.utf8)
        #expect(WorkspaceUser.regularFile(inTar: TarArchive([.init(path: "passwd", contents: contents)]).data()) == contents)
        // A link (type 2) or a folder is not read.
        var link = [UInt8](TarArchive([.init(path: "passwd", contents: Data())]).data())
        link[156] = UInt8(ascii: "2")
        #expect(WorkspaceUser.regularFile(inTar: Data(link)) == nil)
        #expect(WorkspaceUser.regularFile(inTar: TarArchive([.init(path: "etc", isDirectory: true)]).data()) == nil)
        // An extended header describes the next entry.
        var pax = [UInt8](TarArchive([.init(path: "PaxHeaders/passwd", contents: Data("15 path=passwd\n".utf8)),
                                      .init(path: "passwd", contents: contents)]).data())
        pax[156] = UInt8(ascii: "x")
        #expect(WorkspaceUser.regularFile(inTar: Data(pax)) == contents)
        #expect(WorkspaceUser.regularFile(inTar: Data([1, 2, 3])) == nil)
        #expect(WorkspaceUser.regularFile(inTar: TarArchive([.init(path: "passwd", contents: contents)]).data(), limit: 10) == nil)
    }

    /// AF09: the workspace has no capabilities (nothing runs as root in it); its process-group folder is a tmpfs any
    /// user can write; enterprise roots reach programs that read no variable through read-only compiled bundles.
    @Test func theWorkspaceHasNoCapabilitiesAndNoRootStep() {
        var spec = WorkspaceSpec(projectRoot: "/Users/me/app", image: "img")
        var body = spec.createBody(imageID: nil)
        #expect(body.hostConfig?.capDrop == ["ALL"])
        #expect(body.hostConfig?.capAdd == nil)
        #expect(body.hostConfig?.securityOpt == ["no-new-privileges:true"])
        #expect(body.hostConfig?.tmpfs?["/tmp/.bellocode"]?.contains("mode=1777") == true)
        spec.corporateNetwork = CorporateNetwork(certificateDirectory: "/Users/me/certs")
        body = spec.createBody(imageID: nil)
        for target in CorporateNetwork.compiledBundles {
            let mount = body.hostConfig?.mounts?.first { $0.target == target }
            #expect(mount?.source == "/Users/me/certs/ca-bundle.pem" && mount?.readOnly == true, "\(target)")
        }
        #expect(body.env?.contains("CURL_CA_BUNDLE=/etc/bellocode/certs/ca-bundle.pem") == true)
    }

    /// A daemon whose image maps `dev` to uid 0 (and lies about it in `id`); volumes are this project's. Records every
    /// request and answers what is not listed with success.
    static func daemon(projectKey: String, passwd: String = WorkspaceUserTests.passwd) throws -> FakeEngineServer {
        try FakeEngineServer { request, stream in
            let path = request.path
            if request.method == "GET", path.contains("/images/") {
                try await stream.respond(200, json: #"{"Id":"sha256:img"}"#)
            } else if request.method == "GET", path.hasSuffix("/containers/json") {
                try await stream.respond(200, json: "[]")
            } else if request.method == "GET", path.contains("/volumes/") {
                let name = String(path.split(separator: "/").last ?? "")
                try await stream.respond(200, json: #"{"Name":"\#(name)","Labels":{"app.bellocode.workspace":"1","app.bellocode.project-key":"\#(projectKey)"}}"#)
            } else if request.method == "GET", path.hasSuffix("/archive") {
                let file = request.target.contains("passwd") ? passwd : WorkspaceUserTests.group
                let tar = TarArchive([.init(path: (request.target.contains("passwd") ? "passwd" : "group"), contents: Data(file.utf8))]).data()
                try await stream.write(Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-tar\r\nContent-Length: \(tar.count)\r\n\r\n".utf8) + tar)
            } else if request.method == "DELETE" {
                try await stream.respond(204)
            } else if request.method == "POST", path.hasSuffix("/exec") || path.contains("/exec/") {
                // Never expected: answer so a regression fails at once instead of waiting.
                try await stream.respond(500, json: #"{"message":"no exec in this test"}"#)
            } else {
                try await stream.respond(201, json: #"{"Id":"c\#(UUID().uuidString.prefix(6))"}"#)
            }
        }
    }

    /// AF10: a name the image maps to uid 0 is refused before any container of the image starts: the image's account
    /// files are read from a container that is created (no mounts, no network) and never started, and its own `id`
    /// (which may lie) is never asked.
    @Test func aNameThatIsRootInTheImageIsRefusedBeforeAnythingStarts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bc-user-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        var spec = WorkspaceSpec(projectRoot: root, image: "img")
        spec.user = "dev"
        let server = try Self.daemon(projectKey: spec.projectKey)
        defer { server.stop() }
        await #expect(throws: WorkspaceError.rootUser("dev")) { try await WorkspaceManager(client: server.client).ensureRunning(spec) }
        let requests = server.requests.withLock { $0 }
        #expect(!requests.contains { $0.method == "POST" && ($0.path.hasSuffix("/start") || $0.path.contains("/exec")) },
                "nothing started: \(requests.map { "\($0.method) \($0.path)" })")
        let creates = requests.filter { $0.method == "POST" && $0.path.hasSuffix("/containers/create") }
        #expect(creates.count == 1, "only the account-file container")
        for create in creates {
            let object = try #require(try JSONSerialization.jsonObject(with: create.body) as? [String: Any])
            let host = object["HostConfig"] as? [String: Any]
            #expect((host?["Mounts"] as? [Any]).map(\.isEmpty) ?? true, "no mounts")
            #expect(host?["NetworkMode"] as? String == "none")
            #expect((object["Labels"] as? [String: String])?[WorkspaceSpec.labelWorkspace] == nil, "never taken for the workspace")
        }
        #expect(requests.contains { $0.method == "DELETE" && $0.path.contains("/containers/") }, "removed")
        // The one-shot secret-command container (same image and user) is refused the same way, before it exists.
        await #expect(throws: WorkspaceError.rootUser("dev")) {
            _ = try await WorkspaceManager(client: server.client).runSecretCommand(
                spec, shell: "/bin/sh", command: "true", workingDir: root, name: "TOKEN", secret: Data("s".utf8), policy: SecretCommandPolicy())
        }
        #expect(!server.requests.withLock { $0 }.contains { $0.method == "POST" && $0.path.hasSuffix("/start") })
        #expect(server.requests.withLock { $0 }.filter { $0.method == "POST" && $0.path.hasSuffix("/containers/create") }.count == 2,
                "only the account-file containers")
        // A name the image does not define cannot be shown not to be root.
        spec.user = "ghost"
        await #expect(throws: WorkspaceError.unknownUser("ghost")) { try await WorkspaceManager(client: server.client).ensureRunning(spec) }
    }

    /// AF10: an existing container (reused, or adopted after a concurrent create) counts only when it runs as a
    /// nonzero numeric uid; one created with a name, or as root, is outdated and replaced.
    @Test func onlyAContainerRunningAsAVerifiedUserIsReused() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bc-user-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        var spec = WorkspaceSpec(projectRoot: root, image: "img")
        spec.user = "node"
        let hash = spec.configHash(imageID: "sha256:img")
        let identity = spec.mountIdentity()
        let name = spec.containerName
        let user = Mutex("node")
        let server = try FakeEngineServer { request, stream in
            let path = request.path
            if path.contains("/images/") { return try await stream.respond(200, json: #"{"Id":"sha256:img"}"#) }
            if path.hasSuffix("/containers/json") {
                return try await stream.respond(200, json: #"[{"Id":"ws","Names":["/\#(name)"],"Image":"sha256:img","State":"running","Labels":{}}]"#)
            }
            let labels = #"{"app.bellocode.workspace":"1","app.bellocode.config":"\#(hash)","app.bellocode.mounts":"\#(identity)"}"#
            try await stream.respond(200, json: #"{"Id":"ws","Name":"/x","Image":"sha256:img","State":{"Status":"running","Running":true},"Config":{"User":"\#(user.withLock { $0 })","Labels":\#(labels)}}"#)
        }
        defer { server.stop() }
        let manager = WorkspaceManager(client: server.client)
        for (value, expected) in [("node", WorkspaceStatus.Phase.outdated), ("0:0", .outdated), ("root", .outdated), ("1000:1000", .running)] {
            user.withLock { $0 = value }
            let status = try await manager.status(spec)
            #expect(status.phase == expected, "\(value)")
            if expected == .outdated { #expect(status.outdatedReason == "user not verified", "\(value)") }
        }
    }
}
