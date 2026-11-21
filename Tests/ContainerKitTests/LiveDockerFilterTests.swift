import Darwin
import Foundation
import Testing

@testable import ContainerKit

/// Opt-in, against a real Rancher Desktop (dockerd): `BELLOCODE_CONTAINER_TESTS=1 swift test --filter LiveDockerFilter`.
/// Needs `bellocode-test-ws:1` (node:22 + the Docker CLI and Compose, see docs/features/workspace-image.Dockerfile) and
/// `redis:7-alpine` present. Code roots are temporary folders; everything is labelled `app.bellocode.test=1` or with the
/// test scope and removed afterwards.
@Suite("Live Docker filter", .serialized, .timeLimit(.minutes(10)),
       .enabled(if: ProcessInfo.processInfo.environment["BELLOCODE_CONTAINER_TESTS"] == "1"))
struct LiveDockerFilterTests {
    static let image = "bellocode-test-ws:1"
    let socket = NSHomeDirectory() + "/.rd/docker.sock"
    var client: EngineClient { EngineClient(socketPath: socket) }

    struct Fixture {
        var base: String
        var root: String
        var repoA: String
        var repoB: String
        var elsewhere: String
    }

    func makeFixture() throws -> Fixture {
        let base = (CodeRootPaths.canonical(NSTemporaryDirectory()) ?? NSTemporaryDirectory()) + "/bc-live-\(UUID().uuidString.prefix(8))"
        let fixture = Fixture(base: base, root: base + "/Repos", repoA: base + "/Repos/a", repoB: base + "/Repos/b", elsewhere: base + "/elsewhere/c")
        for path in [fixture.repoA, fixture.repoB, fixture.elsewhere] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        try "from repo b\n".write(toFile: fixture.repoB + "/hello.txt", atomically: true, encoding: .utf8)
        try """
        services:
          cache:
            image: redis:7-alpine
          probe:
            image: redis:7-alpine
            command: ["sh", "-c", "until redis-cli -h cache ping > /out/ping.txt 2>/dev/null; do sleep 0.3; done; sleep 3600"]
            volumes: ["./out:/out"]
            depends_on: [cache]
        """.write(toFile: fixture.repoA + "/compose.yaml", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: fixture.repoA + "/out", withIntermediateDirectories: true)
        try "FROM redis:7-alpine\nRUN echo built > /built.txt\n".write(toFile: fixture.repoA + "/Dockerfile", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: fixture.repoA + "/escape", withDestinationPath: fixture.base + "/elsewhere")
        return fixture
    }

    func sh(_ id: String, _ script: String, in directory: String, env: [String: String], user: String) async throws -> (Int, String, String) {
        let result = try await ExecSession.run(client: client, container: id, argv: ["/bin/sh", "-c", script], workingDir: directory,
                                               environment: env, user: user, limit: 1 << 20, timeout: .seconds(240))
        return (result.exitCode, String(decoding: result.stdout, as: UTF8.self), String(decoding: result.stderr, as: UTF8.self))
    }

    /// Removes everything a scope created (containers, then networks and volumes), and built test images.
    func cleanUp(scopes: [String], specs: [WorkspaceSpec], fixture: Fixture) async {
        for scope in scopes {
            let label = "\(DockerAgentLabels.scope)=\(scope)"
            for container in (try? await client.listContainers(labels: [label])) ?? [] { try? await client.removeContainer(container.id, force: true, volumes: true) }
            for network in (try? await client.listNetworks(labels: [label])) ?? [] { try? await client.removeNetwork(network) }
            for volume in (try? await client.listVolumes(labels: [label])) ?? [] { try? await client.removeVolume(volume, force: true) }
            for image in ((try? await client.listImages()) ?? []) where image.repoTags.contains(where: { $0.hasPrefix("bctest-built") }) {
                try? await client.removeImage(image.id, force: true)
            }
        }
        for spec in specs {
            if let storage = try? await WorkspaceManager(client: client).storage(projectKey: spec.projectKey) {
                try? await WorkspaceManager(client: client).purge(storage)
            }
        }
        try? FileManager.default.removeItem(atPath: fixture.base)
    }

    @Test func sharedWorkspaceRunsMultiRepoAndComposeThroughTheFilter() async throws {
        guard try await client.inspectImage(Self.image) != nil, try await client.inspectImage("redis:7-alpine") != nil else {
            Issue.record("needs \(Self.image) and redis:7-alpine present")
            return
        }
        let fixture = try makeFixture()
        let proxy = try DockerFilterProxy(daemonSocket: socket)
        let run = Task { await proxy.run() }
        let sharedScope = "test-shared-\(UUID().uuidString.prefix(6))"
        let projectScope = "test-project-\(UUID().uuidString.prefix(6))"
        var shared = WorkspaceSpec.shared(roots: [fixture.root], image: Self.image, extraLabels: ["app.bellocode.test": "1"])
        shared.sharedKeySeed = sharedScope  // never the developer's real shared workspace
        let project = WorkspaceSpec(projectRoot: fixture.elsewhere, image: Self.image, extraLabels: ["app.bellocode.test": "1"])
        defer { run.cancel(); proxy.stop() }
        do {
            let sharedToken = proxy.register(DockerScope(key: sharedScope, roots: shared.workspaceRoots))
            let projectToken = proxy.register(DockerScope(key: projectScope, roots: project.workspaceRoots))
            let env = ExecHelperConfig.DockerAccess(host: "tcp://host.docker.internal:\(proxy.port)/\(sharedToken)").environment
            let start = ContinuousClock.now
            let id = try await WorkspaceManager(client: client).ensureRunning(shared)
            let ready = ContinuousClock.now - start

            // Multi-repo: a command in repo A reads repo B (same absolute paths), and the working directory is A.
            let (code, out, _) = try await sh(id, "pwd; cat ../b/hello.txt", in: fixture.repoA, env: env, user: shared.user)
            #expect(code == 0)
            #expect(out == "\(fixture.repoA)\nfrom repo b\n")

            // docker ps sees nothing of BelloCode's (not even this workspace).
            let (psCode, psOut, psErr) = try await sh(id, "docker ps -a --format '{{.Names}}'", in: fixture.repoA, env: env, user: shared.user)
            #expect(psCode == 0, "\(psErr)")
            #expect(!psOut.contains("bellocode-ws"), "\(psOut)")

            // A two-service compose stack from inside the shared workspace, with a relative bind mount in the project.
            let composeStart = ContinuousClock.now
            let (upCode, _, upErr) = try await sh(id, "docker compose up -d 2>&1", in: fixture.repoA, env: env, user: shared.user)
            #expect(upCode == 0, "\(upErr)")
            var pong = ""
            for _ in 0..<60 where pong.isEmpty {
                pong = (try? String(contentsOfFile: fixture.repoA + "/out/ping.txt", encoding: .utf8)) ?? ""
                if pong.isEmpty { try await Task.sleep(for: .milliseconds(500)) }
            }
            let composeTime = ContinuousClock.now - composeStart
            #expect(pong.contains("PONG"), "the probe reached the cache by service name and wrote into the project on the Mac")
            let (execCode, execOut, execErr) = try await sh(id, "docker compose exec -T cache redis-cli ping; docker compose ps --format '{{.Service}} {{.State}}'; docker compose logs --tail 2 cache >/dev/null && echo logs-ok",
                                                         in: fixture.repoA, env: env, user: shared.user)
            #expect(execCode == 0, "\(execErr)")
            #expect(execOut.contains("PONG") && execOut.contains("cache running") && execOut.contains("logs-ok"), "\(execOut)")
            let (runCode, runOut, runErr) = try await sh(id, "docker compose run --rm -T cache redis-cli -h cache ping", in: fixture.repoA, env: env, user: shared.user)
            #expect(runCode == 0 && runOut.contains("PONG"), "\(runOut) \(runErr)")
            // Classic build (DOCKER_BUILDKIT=0) of the project's Dockerfile, then remove the image it built.
            let (buildCode, _, buildErr) = try await sh(id, "docker build -q -t bctest-built:1 . && docker run --rm bctest-built:1 cat /built.txt && docker rmi bctest-built:1",
                                                     in: fixture.repoA, env: env, user: shared.user)
            #expect(buildCode == 0, "\(buildErr)")
            // docker compose build of a service with build: (Compose uses the classic builder with DOCKER_BUILDKIT=0).
            try "services:\n  built:\n    build: .\n    image: bctest-built:2\n".write(toFile: fixture.repoA + "/compose.build.yaml", atomically: true, encoding: .utf8)
            let (cbCode, cbOut, cbErr) = try await sh(id, "docker compose -f compose.build.yaml build 2>&1 && docker run --rm bctest-built:2 cat /built.txt && docker rmi bctest-built:2",
                                                   in: fixture.repoA, env: env, user: shared.user)
            #expect(cbCode == 0 && cbOut.contains("built"), "compose build: \(cbOut) \(cbErr)")
            // Everything it created carries the scope's labels.
            let labelled = try await client.listContainers(labels: ["\(DockerAgentLabels.scope)=\(sharedScope)"])
            #expect(labelled.count >= 2)

            // The hostile matrix through the real CLI and daemon: each is refused, nothing runs.
            let hostile = [
                "docker run --rm -v /:/host alpine true", "docker run --rm -v /etc:/x redis:7-alpine true",
                "docker run --rm -v \(fixture.base)/elsewhere:/x redis:7-alpine true", "docker run --rm -v \(fixture.repoA)/escape:/x redis:7-alpine true",
                "docker run --rm -v /var/run/docker.sock:/s redis:7-alpine true", "docker run --rm --mount type=bind,src=/Users,dst=/u redis:7-alpine true",
                "docker run --rm --privileged redis:7-alpine true", "docker run --rm --cap-add SYS_ADMIN redis:7-alpine true",
                "docker run --rm --network host redis:7-alpine true", "docker run --rm --pid host redis:7-alpine true",
                "docker run --rm --ipc host redis:7-alpine true", "docker run --rm --security-opt seccomp=unconfined redis:7-alpine true",
                "docker run --rm --device /dev/kvm redis:7-alpine true", "docker run --rm -p 0.0.0.0:18080:80 redis:7-alpine true",
                "docker run --rm --volumes-from \(shared.containerName) redis:7-alpine true", "docker exec \(shared.containerName) id",
                "docker attach \(shared.containerName)", "docker inspect \(shared.containerName)", "docker rmi redis:7-alpine",
                "docker volume create -o type=none -o o=bind -o device=/ bad", "docker run --rm -l app.bellocode.workspace=1 redis:7-alpine true",
                "docker network connect bridge \(shared.containerName)", "docker kill \(shared.containerName)",
                "docker cp \(shared.containerName):/etc/hostname /tmp/x",
            ]
            for command in hostile {
                let (code, out, err) = try await sh(id, command + " 2>&1", in: fixture.repoA, env: env, user: shared.user)
                #expect(code != 0, "\(command) succeeded: \(out)")
                #expect((out + err).contains("BelloCode refused") || (out + err).contains("not created through this workspace"), "\(command): \(out) \(err)")
            }
            // Raw socket access is impossible: the CLI cannot bypass DOCKER_HOST to Rancher's socket from inside.
            let (rawCode, _, _) = try await sh(id, "test -S /var/run/docker.sock || test -S \(NSHomeDirectory())/.rd/docker.sock", in: fixture.repoA, env: env, user: shared.user)
            #expect(rawCode != 0, "no daemon socket inside the workspace")
            let (downCode, _, downErr) = try await sh(id, "docker compose down -v -t 1 2>&1", in: fixture.repoA, env: env, user: shared.user)
            #expect(downCode == 0, "\(downErr)")

            // A project-container project alongside: its own container, only its folder, its own Docker scope.
            let projectID = try await WorkspaceManager(client: client).ensureRunning(project)
            #expect(projectID != id)
            let projectEnv = ExecHelperConfig.DockerAccess(host: "tcp://host.docker.internal:\(proxy.port)/\(projectToken)").environment
            let (pCode, pOut, _) = try await sh(projectID, "pwd; test -e \(fixture.repoB)/hello.txt && echo sees-b || echo no-b", in: fixture.elsewhere, env: projectEnv, user: project.user)
            #expect(pCode == 0 && pOut == "\(fixture.elsewhere)\nno-b\n", "\(pOut)")
            let (mCode, mOut, _) = try await sh(projectID, "docker run --rm -v \(fixture.repoB):/x redis:7-alpine true 2>&1", in: fixture.elsewhere, env: projectEnv, user: project.user)
            #expect(mCode != 0 && mOut.contains("BelloCode refused"), "the project scope cannot mount the code roots: \(mOut)")
            let (okCode, okOut, _) = try await sh(projectID, "docker run --rm -v \(fixture.elsewhere):/x redis:7-alpine ls /x 2>&1", in: fixture.elsewhere, env: projectEnv, user: project.user)
            #expect(okCode == 0, "its own folder can be mounted: \(okOut)")
            print("live: shared workspace ready \(ready); compose up to PONG \(composeTime)")
        } catch {
            await cleanUp(scopes: [sharedScope, projectScope], specs: [shared, project], fixture: fixture)
            throw error
        }
        await cleanUp(scopes: [sharedScope, projectScope], specs: [shared, project], fixture: fixture)
        // Nothing of the test is left on the daemon.
        #expect(try await client.listContainers(labels: ["\(DockerAgentLabels.scope)=\(sharedScope)"]).isEmpty)
        #expect(try await client.listContainers(labels: ["\(WorkspaceSpec.labelProjectKey)=\(shared.projectKey)"]).isEmpty)
    }

    /// N03, A06, N07 (live): host docker-only mode runs Rancher's real docker client confined to the project, as
    /// `bellocode-exec` does (argument checks, then `sandbox-exec`). Client-only operations that read or write outside
    /// the project fail on the Mac before any request (a mock daemon seeing no request would prove nothing); work inside
    /// the project (env files, compose, a classic build with a context above 4 MiB) goes through the filtered endpoint.
    @Test func hostDockerClientIsConfinedToTheProject() async throws {
        let docker = NSHomeDirectory() + "/.rd/bin/docker"
        guard FileManager.default.isExecutableFile(atPath: docker), try await client.inspectImage("redis:7-alpine") != nil else {
            Issue.record("needs Rancher Desktop's docker and redis:7-alpine present")
            return
        }
        let fixture = try makeFixture()
        let proxy = try DockerFilterProxy(daemonSocket: socket)
        let run = Task { await proxy.run() }
        let scope = "test-host-\(UUID().uuidString.prefix(6).lowercased())"
        defer { run.cancel(); proxy.stop() }
        let token = proxy.register(DockerScope(key: scope, roots: [fixture.repoA]))
        // BelloCode's own docker configuration (as EnvironmentService prepares it): no credential helpers, Rancher's plugins.
        let config = fixture.base + "/docker-cli"
        try FileManager.default.createDirectory(atPath: config + "/cli-plugins", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: config + "/buildx", withIntermediateDirectories: true)
        try #"{"auths":{}}"#.write(toFile: config + "/config.json", atomically: true, encoding: .utf8)
        for name in ["docker-compose", "docker-buildx"] {
            try? FileManager.default.createSymbolicLink(atPath: config + "/cli-plugins/" + name, withDestinationPath: NSHomeDirectory() + "/.rd/bin/" + name)
        }
        let secretText = "SECRET_VALUE=host-file-\(UUID().uuidString.prefix(6))"
        try "\(secretText)\n".write(toFile: fixture.base + "/elsewhere/secret.env", atomically: true, encoding: .utf8)
        try "FOO=from-project\n".write(toFile: fixture.repoA + "/ok.env", atomically: true, encoding: .utf8)
        let access = ExecHelperConfig.DockerAccess(host: "tcp://127.0.0.1:\(proxy.port)/\(token)", binary: docker, configDirectory: config)
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"].merging(access.environment) { _, new in new }
        let paths = HostDockerSandbox.Paths(readWrite: [fixture.repoA, config + "/buildx"], readOnly: HostDockerSandbox.installationFolders(docker: docker, configDirectory: config))

        /// Runs a line as bellocode-exec does; with `unchecked`, skips the argument check (the sandbox alone).
        func host(_ line: String, unchecked: Bool = false, directory: String? = nil) throws -> (Int32, String) {
            let argv: [String]
            if unchecked {
                argv = [docker] + (try HostDockerCommand.words(line).dropFirst())
            } else {
                do { argv = try HostDockerCommand.argv(for: line, docker: docker, roots: [fixture.repoA], cwd: directory ?? fixture.repoA) } catch {
                    return (126, "refused: \(error.description)")
                }
            }
            let wrapped = try #require(HostDockerSandbox.wrap(argv, paths: paths, port: proxy.port))
            let process = Process()
            process.executableURL = URL(filePath: wrapped[0])
            process.arguments = Array(wrapped.dropFirst())
            process.environment = environment
            process.currentDirectoryURL = URL(filePath: directory ?? fixture.repoA)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        do {
            // Inside the project: env file, a run, compose, and a classic build whose context is above 4 MiB (N07).
            let (envCode, envOut) = try host("docker run --rm --env-file ok.env redis:7-alpine sh -c 'echo $FOO'")
            #expect(envCode == 0 && envOut.contains("from-project"), "\(envOut)")
            try Data((0..<(6 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: URL(filePath: fixture.repoA + "/blob.bin"))
            let (buildCode, buildOut) = try host("docker build -q -t bctest-built-host:1 .")
            #expect(buildCode == 0, "a 6 MiB context builds through the filter: \(buildOut)")
            let (sizeCode, sizeOut) = try host("docker run --rm bctest-built-host:1 cat /built.txt")
            #expect(sizeCode == 0 && sizeOut.contains("built"), "\(sizeOut)")
            _ = try host("docker rmi bctest-built-host:1")
            try "services:\n  probe:\n    image: redis:7-alpine\n    env_file: [ok.env]\n    command: [\"sh\", \"-c\", \"echo $$FOO\"]\n".write(
                toFile: fixture.repoA + "/compose.host.yaml", atomically: true, encoding: .utf8)
            let (composeCode, composeOut) = try host("docker compose -f compose.host.yaml run --rm -T probe")
            #expect(composeCode == 0 && composeOut.contains("from-project"), "compose inside the project: \(composeOut)")

            // buildx's own state is writable (its folder only).
            let (lsCode, lsOut) = try host("docker buildx ls")
            #expect(lsCode == 0, "buildx ls: \(lsOut)")

            // Options naming files outside: refused before docker runs.
            for line in ["docker run --rm --env-file \(fixture.base)/elsewhere/secret.env redis:7-alpine printenv",
                         "docker run --rm --env-file escape/secret.env redis:7-alpine printenv",
                         "docker build -f \(fixture.base)/elsewhere/secret.env .", "docker compose --env-file escape/secret.env config"] {
                let (code, out) = try host(line)
                #expect(code == 126 && out.contains("outside this project"), "\(line): \(out)")
            }
            // The sandbox alone (argument check skipped): docker's own reads outside fail on the Mac.
            for line in ["docker run --rm --env-file \(fixture.base)/elsewhere/secret.env redis:7-alpine printenv",
                         "docker run --rm --label-file escape/secret.env redis:7-alpine true",
                         "docker build -f \(fixture.base)/elsewhere/secret.env ."] {
                let (code, out) = try host(line, unchecked: true)
                #expect(code != 0 && !out.contains(secretText), "\(line): \(out)")
                #expect(out.contains("operation not permitted"), "\(line): \(out)")
            }
            // A Compose file inside the project naming a host file outside (client-only: `config` sends no request).
            try "services:\n  leak:\n    image: redis:7-alpine\n    env_file: [\(fixture.base)/elsewhere/secret.env]\n".write(
                toFile: fixture.repoA + "/compose.leak.yaml", atomically: true, encoding: .utf8)
            let (leakCode, leakOut) = try host("docker compose -f compose.leak.yaml config")
            #expect(leakCode != 0 && !leakOut.contains(secretText), "compose env_file outside: \(leakOut)")
            try "services:\n  inc:\n    image: redis:7-alpine\n    build: \(NSHomeDirectory())/.ssh\n".write(
                toFile: fixture.repoA + "/compose.ctx.yaml", atomically: true, encoding: .utf8)
            let (ctxCode, ctxOut) = try host("docker compose -f compose.ctx.yaml build")
            #expect(ctxCode != 0, "a compose build context outside the project: \(ctxOut)")
            // Writes outside (argument check skipped): nothing appears.
            let (_, writeOut) = try host("docker compose -f compose.host.yaml config -o \(fixture.base)/elsewhere/written.yaml", unchecked: true)
            #expect(!FileManager.default.fileExists(atPath: fixture.base + "/elsewhere/written.yaml"), "\(writeOut)")
            // Another daemon: Rancher's raw socket cannot be reached even if the endpoint is overridden.
            let (rawCode, rawOut) = try host("docker -H unix://\(socket) ps", unchecked: true)
            #expect(rawCode != 0, "raw socket from the sandbox: \(rawOut)")
            try "DOCKER_HOST=unix://\(socket)\n".write(toFile: fixture.repoA + "/.env", atomically: true, encoding: .utf8)
            let (dotCode, dotOut) = try host("docker compose -f compose.host.yaml ps -a --format '{{.Name}}'")
            #expect(dotCode != 0 || !dotOut.contains("bellocode-"), "a .env DOCKER_HOST reaches nothing else: \(dotOut)")
            try? FileManager.default.removeItem(atPath: fixture.repoA + "/.env")
        } catch {
            await cleanUp(scopes: [scope], specs: [], fixture: fixture)
            throw error
        }
        await cleanUp(scopes: [scope], specs: [], fixture: fixture)
        for image in ((try? await client.listImages()) ?? []) where image.repoTags.contains("bctest-built-host:1") {
            try? await client.removeImage(image.id, force: true)
        }
    }
}
