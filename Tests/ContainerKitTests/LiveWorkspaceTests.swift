import Darwin
import Foundation
import Synchronization
import Testing

@testable import ContainerKit

/// Opt-in workspace lifecycle checks against a real Rancher Desktop (dockerd):
/// `BELLOCODE_CONTAINER_TESTS=1 swift test --filter LiveWorkspace`. Uses the already-present `node:22-bookworm-slim`
/// image (never pulls), labels everything `app.bellocode.test=1` and removes it.
@Suite("Live workspace", .serialized, .enabled(if: ProcessInfo.processInfo.environment["BELLOCODE_CONTAINER_TESTS"] == "1"))
struct LiveWorkspaceTests {
    static let image = "node:22-bookworm-slim"
    let client = EngineClient(socketPath: NSHomeDirectory() + "/.rd/docker.sock")
    var manager: WorkspaceManager { WorkspaceManager(client: client) }

    /// A project folder under the user's home (shared with Rancher's VM) and its spec.
    func makeProject() throws -> (String, WorkspaceSpec) {
        let root = NSHomeDirectory() + "/Library/Caches/BelloCode/tests/ws-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return (root, WorkspaceSpec(projectRoot: root, image: Self.image, extraLabels: ["app.bellocode.test": "1"]))
    }

    func cleanup(_ spec: WorkspaceSpec) async {
        try? await manager.remove(projectKey: spec.projectKey, volumes: true)
        try? FileManager.default.removeItem(atPath: spec.projectRoot)
    }

    /// Runs `body` with a fresh project and removes its container, volumes and folder afterwards, pass or fail.
    func withProject(_ body: (String, WorkspaceSpec) async throws -> Void) async throws {
        let (root, spec) = try makeProject()
        do {
            try await body(root, spec)
        } catch {
            await cleanup(spec)
            throw error
        }
        await cleanup(spec)
    }

    func sh(_ id: String, _ script: String, env: [String: String] = [:], spec: WorkspaceSpec) async throws -> (Int, String, String) {
        let r = try await ExecSession.run(client: client, container: id, argv: ["/bin/sh", "-c", script], workingDir: spec.projectRoot,
                                          environment: env, user: spec.user)
        return (r.exitCode, String(decoding: r.stdout, as: UTF8.self), String(decoding: r.stderr, as: UTF8.self))
    }

    @Test func lifecycleRecreatesOnSettingAndFolderChanges() async throws {
        guard try await client.inspectImage(Self.image) != nil else { Issue.record("needs \(Self.image) present"); return }
        try await withProject { root, original in
        var spec = original
        let id = try await manager.ensureRunning(spec)
        #expect(try await manager.status(spec).phase == .running)
        let (code, out, _) = try await sh(id, "id -u; pwd; echo $HOME; touch made-in-container; ls -ld $HOME | cut -c1-10", spec: spec)
        #expect(code == 0)
        #expect(out.contains("\(getuid())\n\(root)\n/home/bellocode"))
        #expect(FileManager.default.fileExists(atPath: root + "/made-in-container"))
        let attributes = try FileManager.default.attributesOfItem(atPath: root + "/made-in-container")
        #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), "files made in the container belong to the user")

        // Idle stop, then a start on first use (what the helper does).
        try await manager.stop(spec)
        #expect(try await manager.status(spec).phase == .stopped)
        #expect(try await manager.ensureRunning(spec) == id)

        // A setting change recreates.
        spec.environment = ["FEATURE": "on"]
        let status = try await manager.status(spec)
        #expect(status.phase == .outdated && status.outdatedReason == "settings changed")
        let second = try await manager.ensureRunning(spec)
        #expect(second != id)
        #expect(try await sh(second, "echo $FEATURE", spec: spec).1 == "on\n")

        // The project folder deleted and re-created: the old mount would show an empty directory.
        try FileManager.default.removeItem(atPath: root)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "fresh".write(toFile: root + "/marker", atomically: true, encoding: .utf8)
        let replaced = try await manager.status(spec)
        #expect(replaced.phase == .outdated && replaced.outdatedReason == "project folder replaced")
        let third = try await manager.ensureRunning(spec)
        let markerResult = try await sh(third, "cat marker; ls -la", spec: spec)
        #expect(markerResult.1.hasPrefix("fresh"), "\(markerResult)")

        // A missing image is never pulled when pulling is not allowed.
        var missing = spec
        missing.image = "bellocode-test-missing-image:never"
        await #expect(throws: WorkspaceError.imageMissing("bellocode-test-missing-image:never")) {
            try await manager.ensureRunning(missing, pull: false)
        }
        await cleanup(spec)
        }
    }

    @Test func portsForwardingAndWildcardBindingsStayOffTheNetwork() async throws {
        guard try await client.inspectImage(Self.image) != nil else { return }
        try await withProject { _, spec in
        let id = try await manager.ensureRunning(spec)
        let server = """
        const http=require('http');
        for (const [host,port] of [['127.0.0.1',18081],['::1',18082],['0.0.0.0',18083]])
          http.createServer((q,r)=>r.end('hello '+host)).listen(port,host);
        """
        try server.write(toFile: spec.projectRoot + "/server.js", atomically: true, encoding: .utf8)
        let background = try await ExecSession.start(client: client, container: id, argv: ExecWrapper.nonInteractive(["node", "server.js"]),
                                                     workingDir: spec.projectRoot, environment: [:], user: spec.user, tty: false)
        defer { background.closeStdin() }
        var ports: [ListeningPort] = []
        for _ in 0..<40 {
            ports = try await manager.listeningPorts(container: id, user: spec.user)
            if ports.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(ports.map(\.port) == [18081, 18082, 18083])
        #expect(ports.allSatisfy { $0.process == "node" && $0.pid != nil })
        for port in ports {
            let forwarder = try PortForwarder(client: client, container: id, containerPort: port.port, containerHost: port.relayHost,
                                              user: spec.user)
            let task = Task { await forwarder.run() }
            let (data, _) = try await URLSession.shared.data(from: forwarder.url)
            #expect(String(decoding: data, as: UTF8.self).hasPrefix("hello"))
            forwarder.stop()
            task.cancel()
        }
        // Nothing listens on the Mac for the wildcard binding: ports are never published.
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(probe) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(18083).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(connected != 0, "a 0.0.0.0 server in the container is not reachable on the Mac without the forwarder")
        }
    }

    @Test func reaperRemovesEscapedDaemonsAndTouchRaisesInotify() async throws {
        guard try await client.inspectImage(Self.image) != nil else { return }
        try await withProject { _, spec in
        let id = try await manager.ensureRunning(spec)
        // A command that escapes its process group, as the spike found.
        _ = try await sh(id, "setsid sleep 300 >/dev/null 2>&1 < /dev/null & sleep 0.2", spec: spec)
        let before = try await manager.processes(container: id, user: spec.user)
        #expect(before.contains { $0.command.hasPrefix("sleep 300") })
        #expect(try await manager.reap(container: id, user: spec.user) >= 1)
        let after = try await manager.processes(container: id, user: spec.user)
        #expect(!after.contains { $0.command.hasPrefix("sleep 300") })
        #expect(after.contains { $0.command.hasPrefix("sleep infinity") }, "the keep-alive survives")

        // inotify: host edits are invisible to watchers until touched.
        try "a".write(toFile: spec.projectRoot + "/watched.txt", atomically: false, encoding: .utf8)
        let watcher = """
        const fs=require('fs'); let n=0;
        fs.watch('watched.txt',()=>{n++});
        setTimeout(()=>{console.log('events',n);process.exit(0)},2500);
        """
        try watcher.write(toFile: spec.projectRoot + "/watch.js", atomically: true, encoding: .utf8)
        let session = try await ExecSession.start(client: client, container: id, argv: ["node", "watch.js"], workingDir: spec.projectRoot,
                                                  environment: [:], user: spec.user, tty: false)
        try await Task.sleep(for: .milliseconds(500))
        let mtime = try FileManager.default.attributesOfItem(atPath: spec.projectRoot + "/watched.txt")[.modificationDate] as? Date
        try await manager.touch(container: id, user: spec.user, paths: [spec.projectRoot + "/watched.txt", spec.projectRoot + "/gone.txt"])
        var out = Data()
        for try await chunk in session.output() where chunk.stream == .stdout { out += chunk.bytes }
        #expect(String(decoding: out, as: UTF8.self).contains("events 1") || String(decoding: out, as: UTF8.self).contains("events 2"))
        let after2 = try FileManager.default.attributesOfItem(atPath: spec.projectRoot + "/watched.txt")[.modificationDate] as? Date
        #expect(mtime == after2, "touch -m -r f f leaves the modification time as it was")
        }
    }

    @Test func secretsTravelInOneExecOnly() async throws {
        guard try await client.inspectImage(Self.image) != nil else { return }
        try await withProject { _, spec in
        let id = try await manager.ensureRunning(spec)
        let sentinel = "BCSENTINEL-\(UUID().uuidString)"
        let result = try await sh(id, "test \"$API_TOKEN\" = '\(sentinel)' && echo has-it", env: ["API_TOKEN": sentinel], spec: spec)
        #expect(result.1 == "has-it\n")
        #expect(try await sh(id, "echo \"[$API_TOKEN]\"", spec: spec).1 == "[]\n", "the next exec does not see it")
        let inspect = try await client.call("GET", "/containers/\(id)/json")
        #expect(!String(decoding: inspect, as: UTF8.self).contains(sentinel), "not in the container's configuration")
        let logs = try await client.call("GET", "/containers/\(id)/logs", query: [("stdout", "1"), ("stderr", "1")])
        #expect(!String(decoding: logs, as: UTF8.self).contains(sentinel))
        }
    }

    /// C3: a secret command runs in a one-shot container: value on stdin (never in any configuration), no network, the
    /// project read-only, no shared home; the container is gone afterwards.
    @Test func secretCommandRunsInAOneShotOfflineReadOnlyContainer() async throws {
        guard try await client.inspectImage(Self.image) != nil else { return }
        try await withProject { root, spec in
        _ = try await manager.ensureRunning(spec)
        let sentinel = "BCSENTINEL-\(UUID().uuidString)"
        let script = """
            test "$API_TOKEN" = '\(sentinel)' && echo has-it
            (echo x > \(root)/leak.txt) 2>/dev/null && echo wrote || echo read-only
            node -e "require('http').get('http://1.1.1.1',()=>{console.log('net')}).on('error',()=>console.log('offline'))"
            echo "home=$HOME"
            """
        let result = try await manager.runSecretCommand(
            spec, shell: "/bin/sh", command: script, workingDir: root, name: "API_TOKEN", secret: Data(sentinel.utf8), policy: SecretCommandPolicy())
        let output = result.output.stdout.text
        #expect(result.exitCode == 0)
        #expect(output.contains("has-it"), "\(output) \(result.output.stderr.text)")
        #expect(output.contains("read-only"))
        #expect(output.contains("offline"))
        #expect(output.contains("home=/tmp"))
        #expect(!FileManager.default.fileExists(atPath: root + "/leak.txt"))
        // No secret-command container is left behind.
        let left = try await client.listContainers(labels: ["\(WorkspaceSpec.labelSecretCommand)=1"], all: true)
        #expect(left.isEmpty)
        // With network and write access granted, both work.
        let open = try await manager.runSecretCommand(
            spec, shell: "/bin/sh", command: "(echo x > \(root)/ok.txt) && echo wrote", workingDir: root, name: "API_TOKEN", secret: Data(sentinel.utf8),
            policy: SecretCommandPolicy(network: true, writesProject: true))
        #expect(open.output.stdout.text.contains("wrote"))
        }
    }
}
