import Darwin
import Foundation
import Synchronization
import Testing

@testable import ContainerKit

/// Opt-in workspace lifecycle checks against a real Rancher Desktop (dockerd):
/// `BELLOCODE_CONTAINER_TESTS=1 swift test --filter LiveWorkspace`. Uses the already-present `node:22-bookworm-slim`
/// image (never pulls), labels everything `app.bellocode.test=1` and removes it.
@Suite("Live workspace", .serialized, .timeLimit(.minutes(10)), .enabled(if: ProcessInfo.processInfo.environment["BELLOCODE_CONTAINER_TESTS"] == "1"))
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
        if let storage = try? await manager.storage(projectKey: spec.projectKey) { try? await manager.purge(storage) }
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

    /// NF13: every test needs the image; when it is missing the test fails and says why (never passes having checked
    /// nothing).
    func requireImage(_ image: String = LiveWorkspaceTests.image) async throws {
        try #require(try await client.inspectImage(image) != nil, "needs \(image) present (docker pull \(image) once); nothing was checked")
    }

    func sh(_ id: String, _ script: String, env: [String: String] = [:], spec: WorkspaceSpec) async throws -> (Int, String, String) {
        let r = try await ExecSession.run(client: client, container: id, argv: ["/bin/sh", "-c", script], workingDir: spec.projectRoot,
                                          environment: env, user: spec.user)
        return (r.exitCode, String(decoding: r.stdout, as: UTF8.self), String(decoding: r.stderr, as: UTF8.self))
    }

    @Test func lifecycleRecreatesOnSettingAndFolderChanges() async throws {
        try await requireImage()
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
        try await requireImage()
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
        try await requireImage()
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
        try await requireImage()
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
        try await requireImage()
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

    /// M6: sustained output on both streams keeps each stream's start and end and reports the cut.
    @Test func sustainedOutputIsBoundedVisiblyPerStream() async throws {
        try await requireImage()
        try await withProject { _, spec in
        let id = try await manager.ensureRunning(spec)
        let script = "echo FIRST-OUT; echo FIRST-ERR >&2; head -c 2000000 /dev/zero | tr '\\0' o; head -c 2000000 /dev/zero | tr '\\0' e >&2; echo; echo LAST-OUT; echo LAST-ERR >&2"
        let result = try await ExecSession.run(client: client, container: id, argv: ["/bin/sh", "-c", script], user: spec.user, limit: 64 << 10)
        let out = String(decoding: result.stdout, as: UTF8.self)
        let err = String(decoding: result.stderr, as: UTF8.self)
        #expect(out.hasPrefix("FIRST-OUT") && out.hasSuffix("LAST-OUT\n"))
        #expect(err.hasPrefix("FIRST-ERR") && err.hasSuffix("LAST-ERR\n"))
        #expect(result.stdoutOmitted > 1_900_000 && result.stderrOmitted > 1_900_000)
        #expect(out.contains("bytes of output omitted") && err.contains("bytes of output omitted"))
        }
    }

    /// N09 (live): a container whose user is root in its image (a dev container's remoteUser) is refused and removed,
    /// whatever the name says; the host user and a named non-root user run.
    @Test func aUserThatIsRootInTheImageIsRefused() async throws {
        try await requireImage()
        try await withProject { _, original in
            var spec = original
            spec.user = "root"
            await #expect(throws: WorkspaceError.rootUser("root")) { try await manager.ensureRunning(spec) }
            #expect(try await manager.status(spec).containerID == nil, "the container was removed")
            // `node` is uid 1000 in node:22: allowed.
            spec.user = "node"
            let id = try await manager.ensureRunning(spec)
            let (code, out, _) = try await sh(id, "id -u", spec: spec)
            #expect(code == 0 && out.trimmingCharacters(in: .whitespacesAndNewlines) == "1000")
        }
    }

    /// Runs `body` with a test image built from `node:22-bookworm-slim` with `steps` (no step needs the network), then
    /// removes the image, pass or fail.
    func withTestImage(_ steps: String, _ body: (String) async throws -> Void) async throws {
        try await requireImage()
        let tag = "bctest-ws:\(UUID().uuidString.prefix(8).lowercased())"
        let context = TarArchive([.init(path: "Dockerfile", contents: Data("FROM \(Self.image)\n\(steps)\n".utf8))]).data()
        _ = try await client.buildImage(context: context, tag: tag, labels: ["app.bellocode.test": "1"])
        do {
            try #require(try await client.inspectImage(tag) != nil, "the test image \(tag) was not built")
            try await body(tag)
        } catch {
            try? await client.removeImage(tag, force: true)
            throw error
        }
        try? await client.removeImage(tag, force: true)
    }

    /// AF09 (live): nothing of the project's image runs as root while the workspace is prepared. The image's `chown`
    /// and `mkdir` leave a mark when run (as root they did, from the old `$HOME` step); the workspace has no
    /// capabilities, it runs as the verified numbers, and `$HOME` and a nested cache belong to the user.
    @Test func noProgramOfTheProjectImageRunsAsRoot() async throws {
        try await withTestImage(#"""
            RUN for t in chown mkdir dirname; do p=$(command -v $t); mv "$p" "$p.real"; printf '#!/bin/sh\ntouch "/tmp/ran-%s-$(id -u)" 2>/dev/null\nexec "%s.real" "$@"\n' "$t" "$p" > "$p"; chmod 755 "$p"; done
            """#) { tag in
        try await withProject { _, original in
            var spec = original
            spec.image = tag
            spec.user = "node"
            spec.cacheMounts = [CacheMount(cache: .npm, path: WorkspaceSpec.home + "/.cache/npm")]
            let id = try await manager.ensureRunning(spec)
            let inspect = try #require(try await client.inspectContainer(id))
            #expect(inspect.config.user == "1000:1000", "created with the verified numbers, not the name")
            #expect(inspect.hostConfig?.capAdd?.isEmpty ?? true, "no capabilities: \(inspect.hostConfig?.capAdd ?? [])")
            // Marks of runs as uid 0 only (this test's own command, as the user, may run `mkdir`).
            let (code, out, _) = try await sh(id, "ls /tmp | grep -- '-0$' || true; stat -c %u \"$HOME\" \"$HOME/.cache\" \"$HOME/.cache/npm\"; id -u", spec: spec)
            #expect(code == 0)
            #expect(!out.contains("ran-"), "the image's own tools ran as root: \(out)")
            #expect(out == "1000\n1000\n1000\n1000\n", "\(out)")
        }
        }
    }

    /// AF10 (live): an image that maps a plausible name to uid 0, and whose `id` says 1000, is refused before any
    /// container of it starts; no container of the project is left.
    @Test func aNameMappedToRootIsRefusedWhateverTheImageReports() async throws {
        try await withTestImage(#"""
            RUN echo 'dev:x:0:0:dev:/home/dev:/bin/sh' >> /etc/passwd && printf '#!/bin/sh\necho 1000\n' > /usr/local/bin/id && chmod 755 /usr/local/bin/id
            """#) { tag in
        try await withProject { _, original in
            var spec = original
            spec.image = tag
            spec.user = "dev"
            await #expect(throws: WorkspaceError.rootUser("dev")) { try await manager.ensureRunning(spec) }
            let left = try await client.listContainers(labels: ["\(WorkspaceSpec.labelProjectKey)=\(spec.projectKey)"])
            #expect(left.isEmpty, "no container of the project is left: \(left.map(\.name))")
        }
        }
    }

    /// A18, N09 (live): the dev container build gets a private copy of the context with Rancher's real buildx: a save
    /// after staging does not reach the image; offline (enforced egress) `RUN` steps have no network.
    @Test func devContainerBuildsTheStagedCopy() async throws {
        let docker = NSHomeDirectory() + "/.rd/bin/docker"
        guard FileManager.default.isExecutableFile(atPath: docker), try await client.inspectImage("redis:7-alpine") != nil else {
            Issue.record("needs Rancher's docker and redis:7-alpine present")
            return
        }
        try await withProject { root, _ in
            try FileManager.default.createDirectory(atPath: root + "/.devcontainer", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
            try "staged\n".write(toFile: root + "/src/a.txt", atomically: true, encoding: .utf8)
            let dockerfile = "FROM redis:7-alpine\nCOPY src /src\nRUN (wget -q -T 3 -O /dev/null http://example.com && echo online || echo offline) > /net.txt\n"
            try dockerfile.write(toFile: root + "/.devcontainer/Dockerfile", atomically: true, encoding: .utf8)
            let plan = DevContainerPlan.parse(Data(#"{"build": {"dockerfile": "Dockerfile", "context": ".."}}"#.utf8),
                                              file: root + "/.devcontainer/devcontainer.json", projectRoot: root)
            let build = try #require(plan.build)
            let inputs = try DevContainerBuildInputs.verify(build, projectRoot: root).get()
            let staged = try inputs.stage(projectRoot: root).get()
            defer { staged.remove() }
            try "saved later\n".write(toFile: root + "/src/a.txt", atomically: false, encoding: .utf8)
            let tag = "bctest-devctx:\(UUID().uuidString.prefix(6).lowercased())"
            let argv = try #require(plan.buildArguments(tag: tag, context: staged.directory, offline: true))
            let process = Process()
            process.executableURL = URL(filePath: docker)
            process.arguments = argv
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "DOCKER_HOST": "unix://" + NSHomeDirectory() + "/.rd/docker.sock"]
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: inputs.dockerfile)
            try input.fileHandleForWriting.close()
            let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(log.suffix(800))")
            var spec = WorkspaceSpec(projectRoot: root, image: tag, extraLabels: ["app.bellocode.test": "1"])
            spec.user = "\(getuid()):\(getgid())"
            let id = try await manager.ensureRunning(spec)
            let (code, out, _) = try await sh(id, "cat /src/a.txt /net.txt", spec: spec)
            #expect(code == 0 && out == "staged\noffline\n", "\(out)")
            if let storage = try? await manager.storage(projectKey: spec.projectKey) { try? await manager.purge(storage) }
            try? await client.removeImage(tag, force: true)
        }
    }
}
