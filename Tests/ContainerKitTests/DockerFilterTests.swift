import Darwin
import Foundation
import Synchronization
import Testing

@testable import ContainerKit

/// The filtered Docker endpoint (docs/features/containers.md, "Docker from the workspace"): a hostile request matrix
/// sent over TCP through the real proxy to an in-process fake daemon. A refused request must get a Docker-style 4xx
/// answer and must never reach the daemon; an allowed one reaches it rewritten (labels, limits, canonical paths).
@Suite("Docker filter", .timeLimit(.minutes(3)))
struct DockerFilterTests {
    let scope = "scope1"
    let base: String
    let root: String
    let daemon: FakeEngineServer
    let proxy: DockerFilterProxy
    let token: String

    init() throws {
        base = (CodeRoots.canonical(NSTemporaryDirectory()) ?? NSTemporaryDirectory()) + "/bc-dfilter-\(UUID().uuidString.prefix(8))"
        root = base + "/Repos"
        try FileManager.default.createDirectory(atPath: root + "/app/data", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: base + "/outside", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/app/escape", withDestinationPath: base + "/outside")
        try FileManager.default.createSymbolicLink(atPath: root + "/app/etc", withDestinationPath: "/etc")
        let owned = ["app.bellocode.agent": "1", "app.bellocode.agent-scope": "scope1"]
        let other = ["app.bellocode.agent": "1", "app.bellocode.agent-scope": "other"]
        let workspace = ["app.bellocode.workspace": "1", "app.bellocode.project-key": "abc"]
        daemon = try FakeEngineServer { request, stream in
            // Strip the version prefix the client and lookups use.
            var path = request.path
            if path.hasPrefix("/v"), let slash = path.dropFirst().firstIndex(of: "/") { path = String(path[slash...]) }
            func object(_ id: String, _ name: String, _ labels: [String: String], config: Bool) -> String {
                let labelJSON = String(decoding: try! JSONSerialization.data(withJSONObject: labels, options: [.sortedKeys]), as: UTF8.self)
                return config ? #"{"Id":"\#(id)","Name":"/\#(name)","Config":{"Labels":\#(labelJSON)}}"#
                    : #"{"Id":"\#(id)","Name":"\#(name)","Labels":\#(labelJSON)}"#
            }
            let containers = ["own1": ("own1-full", owned), "own2": ("own2-full", owned), "foreign": ("foreign-full", [String: String]()),
                              "otherscope": ("otherscope-full", other), "bellocode-ws-abc": ("ws-full", workspace)]
            let segments = path.split(separator: "/").map(String.init)
            if request.method == "GET", segments.count == 3, segments[0] == "containers", segments[2] == "json" {
                let key = containers.keys.first { $0 == segments[1] || containers[$0]!.0 == segments[1] }
                if let key, let (id, labels) = containers[key] { return try await stream.respond(200, json: object(id, key, labels, config: true)) }
                return try await stream.respond(404, json: #"{"message":"No such container"}"#)
            }
            if request.method == "GET", segments.count == 2, segments[0] == "volumes" {
                let volumes = ["ownvol": owned, "foreignvol": [String: String]()]
                if let labels = volumes[segments[1]] { return try await stream.respond(200, json: object(segments[1], segments[1], labels, config: false)) }
                return try await stream.respond(404, json: #"{"message":"no such volume"}"#)
            }
            if request.method == "GET", segments.count == 2, segments[0] == "networks" {
                let networks = ["ownnet": owned, "foreignnet": [String: String](), "bridge": [String: String]()]
                if let labels = networks[segments[1]] { return try await stream.respond(200, json: object(segments[1] + "-id", segments[1], labels, config: false)) }
                return try await stream.respond(404, json: #"{"message":"not found"}"#)
            }
            if request.method == "GET", segments.count >= 3, segments[0] == "images", segments.last == "json" {
                let name = segments.dropFirst().dropLast().joined(separator: "/")
                let images = ["ownimg:1": owned, "postgres:16": [String: String](), "registry.acme.internal/base:1": [String: String]()]
                if let labels = images[name] { return try await stream.respond(200, json: object("sha256:" + name, name, labels, config: true)) }
                return try await stream.respond(404, json: #"{"message":"No such image"}"#)
            }
            if request.method == "GET", segments.count == 3, segments[0] == "exec", segments[2] == "json" {
                let execs = ["execown": "own1-full", "execforeign": "foreign-full", "execws": "ws-full"]
                if let container = execs[segments[1]] { return try await stream.respond(200, json: #"{"ID":"\#(segments[1])","ContainerID":"\#(container)"}"#) }
                return try await stream.respond(404, json: #"{"message":"No such exec instance"}"#)
            }
            if request.method == "GET", path == "/containers/json" { return try await stream.respond(200, json: "[]") }
            if request.method == "POST", path == "/volumes/create" { return try await stream.respond(201, json: #"{"Name":"x"}"#) }
            if request.method == "POST", segments.last == "attach" || (segments.first == "exec" && segments.last == "start") {
                try await stream.write(Data("HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.raw-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\nhijacked".utf8))
                return
            }
            try await stream.respond(200, json: #"{"ok":true}"#)
        }
        proxy = try DockerFilterProxy(daemonSocket: daemon.path, imageRefusal: { image in
            image.hasPrefix("evil.example.com") ? "The image \(image) is not in the image policy (allowed: registry.acme.internal)." : nil
        })
        token = proxy.register(DockerScope(key: scope, roots: [root], limits: ResourceLimits(cpus: 2, memoryBytes: 4 << 30, pidsLimit: 512)))
        let proxy = proxy
        Task { await proxy.run() }
    }

    struct Answer {
        var status: Int
        var body: String
    }

    /// Sends one raw HTTP request to the proxy and reads the whole answer.
    func send(_ method: String, _ path: String, json: String? = nil, token: String? = nil, raw: Data? = nil, extraHeaders: String = "") async throws -> Answer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(proxy.port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(connected == 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let stream = FileStream(fd: fd, owned: true, isSocket: true)
        defer { stream.cancel() }
        if let raw {
            try await stream.write(raw)
        } else {
            let body = Data((json ?? "").utf8)
            var head = "\(method) /\(token ?? self.token)/v1.47\(path) HTTP/1.1\r\nHost: docker\r\nUser-Agent: Docker-Client/test\r\n\(extraHeaders)"
            if json != nil { head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" }
            head += "\r\n"
            try await stream.write(Data(head.utf8) + body)
        }
        var data = Data()
        while let chunk = try? await stream.read(), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 1 << 20 { break }
        }
        let text = String(decoding: data, as: UTF8.self)
        let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0
        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        return Answer(status: status, body: body)
    }

    /// Requests that reached the daemon from a client (not the proxy's own ownership lookups).
    var forwarded: [FakeEngineServer.Request] {
        daemon.requests.withLock { $0 }.filter { $0.headers["user-agent"] != "BelloCode-ContainerKit" }
    }

    func create(_ hostConfig: String, extra: String = "", name: String? = nil) -> (String, String) {
        ("/containers/create" + (name.map { "?name=\($0)" } ?? ""), #"{"Image":"postgres:16"\#(extra),"HostConfig":\#(hostConfig)}"#)
    }

    // MARK: The hostile matrix

    @Test func hostileMatrixIsRefusedAndNeverReachesTheDaemon() async throws {
        defer { proxy.stop(); daemon.stop() }
        let cases: [(String, String, String, String?)] = [
            // name, method, path, body
            ("-v /etc", "POST", create(#"{"Binds":["/etc:/host-etc"]}"#).0, create(#"{"Binds":["/etc:/host-etc"]}"#).1),
            ("-v outside the roots", "POST", create(#"{"Binds":["\#(base)/outside:/x"]}"#).0, create(#"{"Binds":["\#(base)/outside:/x"]}"#).1),
            ("-v with ..", "POST", create(#"{"Binds":["\#(root)/../outside:/x"]}"#).0, create(#"{"Binds":["\#(root)/../outside:/x"]}"#).1),
            ("-v through a link out of the root", "POST", create(#"{"Binds":["\#(root)/app/escape:/x"]}"#).0, create(#"{"Binds":["\#(root)/app/escape:/x"]}"#).1),
            ("-v through a link to /etc", "POST", create(#"{"Binds":["\#(root)/app/etc/passwd:/x"]}"#).0, create(#"{"Binds":["\#(root)/app/etc/passwd:/x"]}"#).1),
            ("-v docker.sock", "POST", create(#"{"Binds":["/var/run/docker.sock:/var/run/docker.sock"]}"#).0, create(#"{"Binds":["/var/run/docker.sock:/var/run/docker.sock"]}"#).1),
            ("-v / ", "POST", create(#"{"Binds":["/:/host"]}"#).0, create(#"{"Binds":["/:/host"]}"#).1),
            ("-v home", "POST", create(#"{"Binds":["\#(NSHomeDirectory()):/h"]}"#).0, create(#"{"Binds":["\#(NSHomeDirectory()):/h"]}"#).1),
            ("-v rshared propagation", "POST", create(#"{"Binds":["\#(root)/app:/x:rshared"]}"#).0, create(#"{"Binds":["\#(root)/app:/x:rshared"]}"#).1),
            ("-v foreign volume", "POST", create(#"{"Binds":["foreignvol:/data"]}"#).0, create(#"{"Binds":["foreignvol:/data"]}"#).1),
            ("-v BelloCode's home volume", "POST", create(#"{"Binds":["bellocode-abc-home:/data"]}"#).0, create(#"{"Binds":["bellocode-abc-home:/data"]}"#).1),
            ("--mount bind ~/.ssh", "POST", create(#"{"Mounts":[{"Type":"bind","Source":"\#(NSHomeDirectory())/.ssh","Target":"/s"}]}"#).0, create(#"{"Mounts":[{"Type":"bind","Source":"\#(NSHomeDirectory())/.ssh","Target":"/s"}]}"#).1),
            ("compose volumes: bind /", "POST", create(#"{"Mounts":[{"Type":"bind","Source":"/","Target":"/host","ReadOnly":true}]}"#).0, create(#"{"Mounts":[{"Type":"bind","Source":"/","Target":"/host","ReadOnly":true}]}"#).1),
            ("--mount bind rshared", "POST", create(#"{"Mounts":[{"Type":"bind","Source":"\#(root)/app","Target":"/x","BindOptions":{"Propagation":"rshared"}}]}"#).0, create(#"{"Mounts":[{"Type":"bind","Source":"\#(root)/app","Target":"/x","BindOptions":{"Propagation":"rshared"}}]}"#).1),
            ("--mount volume with driver options (device=/)", "POST", create(#"{"Mounts":[{"Type":"volume","Source":"v","Target":"/x","VolumeOptions":{"DriverConfig":{"Name":"local","Options":{"type":"none","o":"bind","device":"/"}}}}]}"#).0, create(#"{"Mounts":[{"Type":"volume","Source":"v","Target":"/x","VolumeOptions":{"DriverConfig":{"Name":"local","Options":{"type":"none","o":"bind","device":"/"}}}}]}"#).1),
            ("--mount npipe", "POST", create(#"{"Mounts":[{"Type":"npipe","Source":"x","Target":"/x"}]}"#).0, create(#"{"Mounts":[{"Type":"npipe","Source":"x","Target":"/x"}]}"#).1),
            ("--mount image", "POST", create(#"{"Mounts":[{"Type":"image","Source":"alpine","Target":"/x"}]}"#).0, create(#"{"Mounts":[{"Type":"image","Source":"alpine","Target":"/x"}]}"#).1),
            ("--volumes-from foreign", "POST", create(#"{"VolumesFrom":["foreign"]}"#).0, create(#"{"VolumesFrom":["foreign"]}"#).1),
            ("--volumes-from the workspace", "POST", create(#"{"VolumesFrom":["bellocode-ws-abc:ro"]}"#).0, create(#"{"VolumesFrom":["bellocode-ws-abc:ro"]}"#).1),
            ("--device", "POST", create(#"{"Devices":[{"PathOnHost":"/dev/kvm","PathInContainer":"/dev/kvm","CgroupPermissions":"rwm"}]}"#).0, create(#"{"Devices":[{"PathOnHost":"/dev/kvm","PathInContainer":"/dev/kvm","CgroupPermissions":"rwm"}]}"#).1),
            ("--gpus", "POST", create(#"{"DeviceRequests":[{"Count":-1,"Capabilities":[["gpu"]]}]}"#).0, create(#"{"DeviceRequests":[{"Count":-1,"Capabilities":[["gpu"]]}]}"#).1),
            ("--privileged", "POST", create(#"{"Privileged":true}"#).0, create(#"{"Privileged":true}"#).1),
            ("--cap-add SYS_ADMIN", "POST", create(#"{"CapAdd":["SYS_ADMIN"]}"#).0, create(#"{"CapAdd":["SYS_ADMIN"]}"#).1),
            ("--network host", "POST", create(#"{"NetworkMode":"host"}"#).0, create(#"{"NetworkMode":"host"}"#).1),
            ("--network foreign", "POST", create(#"{"NetworkMode":"foreignnet"}"#).0, create(#"{"NetworkMode":"foreignnet"}"#).1),
            ("--network container:workspace", "POST", create(#"{"NetworkMode":"container:bellocode-ws-abc"}"#).0, create(#"{"NetworkMode":"container:bellocode-ws-abc"}"#).1),
            ("EndpointsConfig foreign network", "POST", create("{}", extra: #","NetworkingConfig":{"EndpointsConfig":{"foreignnet":{}}}"#).0, create("{}", extra: #","NetworkingConfig":{"EndpointsConfig":{"foreignnet":{}}}"#).1),
            ("--pid host", "POST", create(#"{"PidMode":"host"}"#).0, create(#"{"PidMode":"host"}"#).1),
            ("--pid container:foreign", "POST", create(#"{"PidMode":"container:foreign"}"#).0, create(#"{"PidMode":"container:foreign"}"#).1),
            ("--ipc host", "POST", create(#"{"IpcMode":"host"}"#).0, create(#"{"IpcMode":"host"}"#).1),
            ("--uts host", "POST", create(#"{"UTSMode":"host"}"#).0, create(#"{"UTSMode":"host"}"#).1),
            ("--userns host", "POST", create(#"{"UsernsMode":"host"}"#).0, create(#"{"UsernsMode":"host"}"#).1),
            ("--cgroupns host", "POST", create(#"{"CgroupnsMode":"host"}"#).0, create(#"{"CgroupnsMode":"host"}"#).1),
            ("--security-opt seccomp=unconfined", "POST", create(#"{"SecurityOpt":["seccomp=unconfined"]}"#).0, create(#"{"SecurityOpt":["seccomp=unconfined"]}"#).1),
            ("--security-opt apparmor=unconfined", "POST", create(#"{"SecurityOpt":["apparmor=unconfined"]}"#).0, create(#"{"SecurityOpt":["apparmor=unconfined"]}"#).1),
            ("--security-opt label=disable", "POST", create(#"{"SecurityOpt":["label=disable"]}"#).0, create(#"{"SecurityOpt":["label=disable"]}"#).1),
            ("--sysctl", "POST", create(#"{"Sysctls":{"kernel.core_pattern":"|/x"}}"#).0, create(#"{"Sysctls":{"kernel.core_pattern":"|/x"}}"#).1),
            ("--cgroup-parent", "POST", create(#"{"CgroupParent":"/"}"#).0, create(#"{"CgroupParent":"/"}"#).1),
            ("--runtime", "POST", create(#"{"Runtime":"kata"}"#).0, create(#"{"Runtime":"kata"}"#).1),
            ("unmask /proc", "POST", create(#"{"MaskedPaths":[]}"#).0, #"{"Image":"postgres:16","HostConfig":{"MaskedPaths":["/x"]}}"#),
            ("--log-driver syslog", "POST", create(#"{"LogConfig":{"Type":"syslog","Config":{"syslog-address":"tcp://1.2.3.4:514"}}}"#).0, create(#"{"LogConfig":{"Type":"syslog","Config":{"syslog-address":"tcp://1.2.3.4:514"}}}"#).1),
            ("-p 0.0.0.0", "POST", create(#"{"PortBindings":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"}]}}"#).0, create(#"{"PortBindings":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"}]}}"#).1),
            ("-P", "POST", create(#"{"PublishAllPorts":true}"#).0, create(#"{"PublishAllPorts":true}"#).1),
            ("unknown host setting", "POST", create(#"{"NewDangerousThing":true}"#).0, create(#"{"NewDangerousThing":true}"#).1),
            ("label spoofing a workspace", "POST", create("{}", extra: #","Labels":{"app.bellocode.workspace":"1"}"#).0, create("{}", extra: #","Labels":{"app.bellocode.workspace":"1"}"#).1),
            ("label spoofing another scope", "POST", create("{}", extra: #","Labels":{"app.bellocode.agent-scope":"other"}"#).0, create("{}", extra: #","Labels":{"app.bellocode.agent-scope":"other"}"#).1),
            ("name squatting the workspace", "POST", create("{}", name: "bellocode-ws-abc").0, create("{}", name: "bellocode-ws-abc").1),
            ("image outside the policy", "POST", "/containers/create", #"{"Image":"evil.example.com/x:1","HostConfig":{}}"#),
            ("exec into a foreign container", "POST", "/containers/foreign/exec", #"{"Cmd":["sh"]}"#),
            ("exec into the workspace", "POST", "/containers/bellocode-ws-abc/exec", #"{"Cmd":["sh"]}"#),
            ("exec into another scope's container", "POST", "/containers/otherscope/exec", #"{"Cmd":["sh"]}"#),
            ("privileged exec in own container", "POST", "/containers/own1/exec", #"{"Cmd":["sh"],"Privileged":true}"#),
            ("start a foreign exec", "POST", "/exec/execforeign/start", #"{"Detach":false}"#),
            ("start an exec in the workspace", "POST", "/exec/execws/start", #"{"Detach":false}"#),
            ("attach to the workspace", "POST", "/containers/bellocode-ws-abc/attach?stream=1&stdin=1", nil),
            ("attach to a foreign container", "POST", "/containers/foreign/attach?stream=1", nil),
            ("inspect a foreign container", "GET", "/containers/foreign/json", nil),
            ("copy out of the workspace", "GET", "/containers/bellocode-ws-abc/archive?path=/home", nil),
            ("copy into a foreign container", "PUT", "/containers/foreign/archive?path=/", ""),
            ("kill a foreign container", "POST", "/containers/foreign/kill", nil),
            ("remove the workspace", "DELETE", "/containers/bellocode-ws-abc?force=1", nil),
            ("export a container", "GET", "/containers/own1/export", nil),
            ("update limits", "POST", "/containers/own1/update", #"{"Memory":0}"#),
            ("path traversal", "GET", "/containers/own1/../foreign/json", nil),
            ("delete someone else's image", "DELETE", "/images/postgres:16", nil),
            ("tag a foreign image", "POST", "/images/postgres:16/tag?repo=mine", nil),
            ("overwrite a foreign tag", "POST", "/images/ownimg:1/tag?repo=registry.acme.internal/base&tag=1", nil),
            ("push", "POST", "/images/ownimg:1/push", nil),
            ("pull outside the policy", "POST", "/images/create?fromImage=evil.example.com/x&tag=1", nil),
            ("import from a URL", "POST", "/images/create?fromSrc=http://evil/x.tar", nil),
            ("load an image", "POST", "/images/load", ""),
            ("build from a remote context", "POST", "/build?remote=https://github.com/x/y.git", ""),
            ("build on the host network", "POST", "/build?networkmode=host", ""),
            ("build with a cgroup parent", "POST", "/build?cgroupparent=/", ""),
            ("build overwriting a foreign tag", "POST", "/build?t=registry.acme.internal/base:1", ""),
            ("build with spoofed labels", "POST", "/build?labels=%7B%22app.bellocode.workspace%22%3A%221%22%7D", ""),
            ("BuildKit gRPC", "POST", "/grpc", nil),
            ("network: macvlan", "POST", "/networks/create", #"{"Name":"n","Driver":"macvlan","Options":{"parent":"en0"}}"#),
            ("network: bridge name option", "POST", "/networks/create", #"{"Name":"n","Options":{"com.docker.network.bridge.name":"docker0"}}"#),
            ("network: connect a foreign container", "POST", "/networks/ownnet/connect", #"{"Container":"foreign"}"#),
            ("network: connect the workspace", "POST", "/networks/ownnet/connect", #"{"Container":"bellocode-ws-abc"}"#),
            ("network: delete a foreign one", "DELETE", "/networks/foreignnet", nil),
            ("volume with driver options", "POST", "/volumes/create", #"{"Name":"v","DriverOpts":{"type":"none","o":"bind","device":"/"}}"#),
            ("volume with another driver", "POST", "/volumes/create", #"{"Name":"v","Driver":"sshfs"}"#),
            ("volume: delete a foreign one", "DELETE", "/volumes/foreignvol", nil),
            ("swarm", "POST", "/swarm/init", "{}"),
            ("plugins", "POST", "/plugins/pull?remote=x", "[]"),
            ("secrets", "GET", "/secrets", nil),
            ("registry login", "POST", "/auth", "{}"),
            ("system df", "GET", "/system/df", nil),
        ]
        for (name, method, path, body) in cases {
            let before = forwarded.count
            let answer = try await send(method, path, json: body)
            #expect((400..<500).contains(answer.status), "\(name): status \(answer.status)")
            #expect(answer.body.contains("message"), "\(name): Docker-style error body")
            #expect(forwarded.count == before, "\(name): reached the daemon")
        }
        // The refusals say what to do (the agent reads them in the CLI's "Error response from daemon: …").
        let host = try await send("POST", create(#"{"Binds":["/etc:/x"]}"#).0, json: create(#"{"Binds":["/etc:/x"]}"#).1)
        #expect(host.body.contains("BelloCode refused this Docker request"))
        #expect(host.body.contains("named volume"))
        #expect(proxy.recentRefusals.count >= 50, "every refusal is recorded for the app (bounded)")
    }

    @Test func requestsWithoutTheTokenAreRefusedBeforeAnything() async throws {
        defer { proxy.stop(); daemon.stop() }
        for bad in ["", "wrong-token-value", String(token.dropLast()) + "0", "../" + token] {
            let answer = try await send("GET", "/containers/json", token: bad)
            #expect(answer.status == 401 || answer.status == 400, "token \(bad)")
        }
        // No token segment at all.
        let raw = try await send("", "", raw: Data("GET /v1.47/containers/json HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        #expect(raw.status == 401)
        // A removed scope's token stops working.
        proxy.unregister(scope: scope)
        #expect(try await send("GET", "/_ping").status == 401)
        #expect(forwarded.isEmpty)
    }

    @Test func aSecondRequestOnTheSameConnectionIsNeverForwarded() async throws {
        defer { proxy.stop(); daemon.stop() }
        let smuggled = #"{"Image":"alpine","HostConfig":{"Privileged":true}}"#
        let raw = "GET /\(token)/v1.47/_ping HTTP/1.1\r\nHost: x\r\n\r\n"
            + "POST /\(token)/v1.47/containers/create HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: \(smuggled.utf8.count)\r\n\r\n\(smuggled)"
        _ = try await send("", "", raw: Data(raw.utf8))
        let paths = forwarded.map(\.path)
        #expect(paths == ["/v1.47/_ping"], "only the first, checked request: \(paths)")
        // A body that hides a second request behind Content-Length / chunked conflicts is refused.
        let conflicting = "POST /\(token)/v1.47/containers/own1/start HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        let answer = try await send("", "", raw: Data(conflicting.utf8))
        #expect(answer.status == 400)
    }

    // MARK: What is allowed, and how it is rewritten

    @Test func ownContainerInsideTheRootsIsCreatedWithLabelsLimitsAndCanonicalPaths() async throws {
        defer { proxy.stop(); daemon.stop() }
        let body = #"{"Image":"postgres:16","Labels":{"com.docker.compose.project":"app"},"HostConfig":{"Binds":["\#(root)/app/data:/data:ro","cache:/cache"],"Mounts":[{"Type":"bind","Source":"\#(root)/app","Target":"/src"},{"Type":"tmpfs","Target":"/tmp"}],"PortBindings":{"5432/tcp":[{"HostIp":"","HostPort":"5432"}]},"Memory":68719476736,"NetworkMode":"ownnet"}}"#
        let answer = try await send("POST", "/containers/create?name=db", json: body)
        #expect(answer.status == 200)
        let request = try #require(forwarded.last)
        #expect(request.path == "/v1.47/containers/create")
        let json = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let labels = try #require(json["Labels"] as? [String: String])
        #expect(labels["app.bellocode.agent-scope"] == scope && labels["app.bellocode.agent"] == "1")
        #expect(labels["com.docker.compose.project"] == "app", "the client's own labels are kept")
        let host = try #require(json["HostConfig"] as? [String: Any])
        #expect((host["Binds"] as? [String])?.first == "\(root)/app/data:/data:ro")
        #expect((host["Memory"] as? NSNumber)?.int64Value == 4 << 30, "clamped to the scope's limit")
        #expect((host["PidsLimit"] as? NSNumber)?.int64Value == 512, "a default limit is added")
        #expect((host["SecurityOpt"] as? [String]) == ["no-new-privileges:true"])
        let binding = ((host["PortBindings"] as? [String: Any])?["5432/tcp"] as? [[String: Any]])?.first
        #expect(binding?["HostIp"] as? String == "127.0.0.1", "published on the Mac's loopback only")
        // A missing named volume was created first, with the scope's labels (never by the daemon, unlabelled).
        let volumeCreate = daemon.requests.withLock { $0 }.first { $0.path.hasSuffix("/volumes/create") }
        #expect(volumeCreate.map { String(decoding: $0.body, as: UTF8.self).contains("app.bellocode.agent-scope") } == true)
    }

    @Test func listsEventsAndPrunesSeeOnlyTheScope() async throws {
        defer { proxy.stop(); daemon.stop() }
        _ = try await send("GET", "/containers/json?all=1&filters=%7B%22label%22%3A%7B%22com.docker.compose.project%3Dapp%22%3Atrue%7D%7D")
        let query = try #require(forwarded.last?.target.split(separator: "?").last).removingPercentEncoding ?? ""
        #expect(query.contains(#""label":["app.bellocode.agent-scope=scope1","com.docker.compose.project=app"]"#), "\(query)")
        for path in ["/networks", "/volumes", "/events?since=1", "/containers/prune"] {
            _ = try await send(path == "/containers/prune" ? "POST" : "GET", path)
            let target = (forwarded.last?.target ?? "").removingPercentEncoding ?? ""
            #expect(target.contains("app.bellocode.agent-scope=scope1"), "\(path): \(target)")
        }
    }

    @Test func ownObjectsExecAttachPullBuildAndCleanUpAreAllowed() async throws {
        defer { proxy.stop(); daemon.stop() }
        let allowed: [(String, String, String?)] = [
            ("GET", "/_ping", nil), ("GET", "/version", nil), ("GET", "/containers/own1/json", nil), ("POST", "/containers/own1/start", nil),
            ("GET", "/containers/own1/logs?stdout=1", nil), ("POST", "/containers/own1/exec", #"{"Cmd":["npm","test"]}"#),
            ("GET", "/exec/execown/json", nil), ("POST", "/containers/own1/stop", nil), ("DELETE", "/containers/own1?v=1", nil),
            ("POST", "/images/create?fromImage=registry.acme.internal/base&tag=1", nil), ("GET", "/images/postgres:16/json", nil),
            ("POST", "/images/ownimg:1/tag?repo=mine&tag=2", nil), ("DELETE", "/images/ownimg:1", nil),
            ("POST", "/networks/create", #"{"Name":"app_default","Driver":"bridge","Labels":{"com.docker.compose.network":"default"}}"#),
            ("POST", "/networks/ownnet/connect", #"{"Container":"own2"}"#), ("DELETE", "/networks/ownnet", nil),
            ("POST", "/volumes/create", #"{"Name":"app_data","Labels":{"com.docker.compose.volume":"data"}}"#), ("DELETE", "/volumes/ownvol", nil),
            ("POST", "/build?t=mine:1&dockerfile=Dockerfile", ""), ("POST", "/containers/own1/kill?signal=TERM", nil),
            ("PUT", "/containers/own1/archive?path=/tmp", ""), ("GET", "/containers/own1/archive?path=/tmp", nil),
        ]
        for (method, path, body) in allowed {
            let answer = try await send(method, path, json: body)
            #expect((200..<300).contains(answer.status), "\(method) \(path): \(answer.status) \(answer.body)")
        }
        // Owned containers are addressed by full ID when forwarded (no name swap between check and use).
        #expect(forwarded.contains { $0.path == "/v1.47/containers/own1-full/start" })
        // Builds carry the scope's labels; network and volume creation too.
        let build = try #require(forwarded.first { $0.path == "/v1.47/build" })
        #expect((build.target.removingPercentEncoding ?? "").contains("app.bellocode.agent-scope"))
        #expect(build.headers["transfer-encoding"] == "chunked", "the build context streams through")
        let network = try #require(forwarded.first { $0.path == "/v1.47/networks/create" })
        #expect(String(decoding: network.body, as: UTF8.self).contains("app.bellocode.agent-scope"))
    }

    @Test func attachAndExecStartOnOwnContainersBecomeRawStreams() async throws {
        defer { proxy.stop(); daemon.stop() }
        let answer = try await send("POST", "/containers/own1/attach?stream=1&stdout=1", extraHeaders: "Connection: Upgrade\r\nUpgrade: tcp\r\n")
        #expect(answer.status == 101)
        #expect(answer.body == "hijacked")
        let exec = try await send("POST", "/exec/execown/start", json: #"{"Detach":false,"Tty":false}"#, extraHeaders: "Connection: Upgrade\r\nUpgrade: tcp\r\n")
        #expect(exec.status == 101)
        let odd = try await send("POST", "/containers/own1/attach?stream=1", extraHeaders: "Connection: Upgrade\r\nUpgrade: websocket\r\n")
        #expect(odd.status == 400, "only tcp and h2c upgrades")
    }
}
