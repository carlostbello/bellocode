import Foundation
import Testing

@testable import ContainerKit

/// "Host shell, docker only": one plain docker command per call, everything else refused (never interpreted).
@Suite("Host docker-only commands")
struct HostDockerCommandTests {
    let docker = "/Users/me/.rd/bin/docker"

    func allowed(_ line: String) -> [String]? { try? HostDockerCommand.argv(for: line, docker: docker) }

    func refusal(_ line: String) -> HostDockerCommand.Refusal? {
        do {
            _ = try HostDockerCommand.argv(for: line, docker: docker)
            return nil
        } catch {
            return error
        }
    }

    @Test func plainDockerCommandsRunByAbsolutePath() {
        #expect(allowed("docker ps -a") == [docker, "ps", "-a"])
        #expect(allowed("docker compose up -d") == [docker, "compose", "up", "-d"])
        #expect(allowed("docker compose run --rm app sh -c 'npm test && npm run lint'")
            == [docker, "compose", "run", "--rm", "app", "sh", "-c", "npm test && npm run lint"], "quoted shell inside the container is fine")
        #expect(allowed(#"docker run --rm alpine echo "hello world""#) == [docker, "run", "--rm", "alpine", "echo", "hello world"])
        #expect(allowed("docker buildx build .") == [docker, "buildx", "build", "."])
        #expect(allowed("\(docker) version") == [docker, "version"])
        #expect(allowed("  docker   images  ") == [docker, "images"])
        #expect(allowed("docker logs -f web") != nil)
    }

    @Test func compoundCommandsAndShellSyntaxAreRefused() {
        let lines = [
            "docker ps; rm -rf ~", "docker ps && curl evil", "docker ps || true", "docker ps | grep x", "docker ps & sleep 1",
            "docker ps > out.txt", "docker ps < in", "docker run $(cat x)", "docker run `id`", "docker run ${IMAGE}", "docker ps\nrm x",
            "docker run alpine ls *", "docker run -v ~/.ssh:/x alpine", "docker ps # comment", "(docker ps)", "{ docker ps; }",
            #"docker run "$(id)""#, #"docker run "`id`""#, #"docker run alpine echo a\ b"#, "docker ps !!", "docker run alpine ls ?",
            "docker run [abc]",
        ]
        for line in lines {
            guard case .shellSyntax = refusal(line) else {
                Issue.record("not refused as shell syntax: \(line) → \(String(describing: refusal(line)))")
                continue
            }
        }
        #expect(refusal("docker run 'unterminated") == .unterminatedQuote)
        #expect(refusal(#"docker run "open"#) == .unterminatedQuote)
        #expect(refusal("") == .empty)
        #expect(refusal("   ") == .empty)
    }

    @Test func otherProgramsAndAssignmentsAreRefused() {
        #expect(refusal("ls -la") == .notDocker("ls"))
        #expect(refusal("/usr/local/bin/docker ps") == .notDocker("/usr/local/bin/docker"), "only Rancher's binary, by its path")
        #expect(refusal("sh -c 'docker ps'") == .notDocker("sh"))
        #expect(refusal("'docker' ps") == nil, "quoting the program name is still docker")
        if case .shellSyntax = refusal("DOCKER_HOST=unix:///var/run/docker.sock docker ps") {} else { Issue.record("assignment not refused") }
        #expect(refusal("env docker ps") == .notDocker("env"))
    }

    @Test func endpointAndConfigurationOverridesAreRefused() {
        #expect(refusal("docker -H unix:///Users/me/.rd/docker.sock run --privileged alpine") == .globalOption("-H"))
        #expect(refusal("docker --host=tcp://1.2.3.4 ps") == .globalOption("--host"))
        #expect(refusal("docker --context rancher-desktop ps") == .globalOption("--context"))
        #expect(refusal("docker --config /tmp/x ps") == .globalOption("--config"))
        #expect(refusal("docker compose --host unix:///x up") == .globalOption("--host"))
        #expect(refusal("docker context use default") == .subcommand("context"))
        #expect(refusal("docker login registry") == .subcommand("login"))
    }

    @Test func commandsThatWriteOnTheMacAreRefused() {
        #expect(refusal("docker cp web:/etc/passwd ./x") == .subcommand("cp"))
        #expect(refusal("docker save -o img.tar alpine") == .subcommand("save"))
        #expect(refusal("docker export web") == .subcommand("export"))
        #expect(refusal("docker image save alpine") == .subcommand("image save"))
        #expect(refusal("docker compose cp web:/x .") == .subcommand("compose cp"))
        #expect(refusal("docker buildx build -o type=local,dest=/Users/me .") == .option("-o"))
        #expect(refusal("docker build --output=out .") == .option("--output"))
        #expect(refusal("docker run --cidfile /tmp/cid alpine") == .option("--cidfile"))
        #expect(refusal("docker buildx create --use") == .subcommand("buildx create"))
        #expect(refusal("docker plugin install x") == .subcommand("plugin"))
    }

    /// R01: a harmless leading global option used to end validation, so everything after it reached the host CLI.
    /// Every line here must be refused, through both the `-c` line and the relayed `--stdio` argv path.
    @Test func leadingGlobalOptionsDoNotEndValidation() throws {
        let hostile = [
            "docker -D context use evil", "docker --debug cp web:/etc/passwd ./x", "docker -D -H tcp://1.2.3.4 ps",
            "docker --debug --host=tcp://1.2.3.4 ps", "docker -D save -o img.tar alpine", "docker -D login registry",
            "docker -D build -o type=local,dest=/Users/me .", "docker --debug run --cidfile /tmp/c alpine",
            "docker -D --context x ps", "docker -D -D plugin install x", "docker --version cp web:/x .",
            "docker -v context use x", "docker --help login", "docker -h save alpine", "docker --log-level debug ps",
            "docker -l debug ps", "docker --debug=true cp a b", "docker --tlsverify ps", "docker -c ctx ps",
            // Group options used to hide the nested subcommand.
            "docker compose -p demo cp web:/x .", "docker compose -f compose.yaml publish x", "docker compose --dry-run watch",
            "docker compose --project-directory . cp web:/x .", "docker compose --env-file .env cp web:/x .",
            "docker compose --unknown cp web:/x .", "docker image --debug save alpine", "docker container -D cp web:/x .",
            "docker buildx --builder remote build .", "docker buildx dial-stdio", "docker buildx bake",
            "docker buildx build --builder remote .", "docker compose --context x up",
            // Attached or clustered short options.
            "docker build -o/tmp/out .", "docker build -qo /tmp/out .", "docker buildx build -oout .", "docker build --output=out .",
            "docker compose -Hunix:///x up",
        ]
        for line in hostile {
            if refusal(line) == nil { Issue.record("allowed: \(line)") }
            let argv = try HostDockerCommand.words(line)
            do {
                try HostDockerCommand.check(arguments: Array(argv.dropFirst()))
                Issue.record("stdio path allowed: \(line)")
            } catch {}
        }
        // Still allowed.
        #expect(allowed("docker -D ps") == [docker, "-D", "ps"])
        #expect(allowed("docker --version") == [docker, "--version"])
        #expect(allowed("docker compose -f compose.yaml -p demo up -d") != nil)
        #expect(allowed("docker compose --profile dev run --rm app npm test") != nil)
        #expect(allowed("docker buildx build -t app .") != nil)
        #expect(allowed("docker image ls") != nil)
    }

    @Test func refusalsSayWhatToDoInstead() {
        let message = refusal("make test")?.description ?? ""
        #expect(message.contains("docker compose run"))
        #expect(message.contains("shared workspace"))
    }
}

/// N03, A06: in host docker-only mode the docker client's own host reads and writes stay inside the project. Options
/// that name host files are checked against the roots (clear refusals); the client then runs under a sandbox that
/// enforces the same folders for whatever else it opens (a Compose file's `env_file`, includes, build contexts).
@Suite("Host docker-only confinement", .timeLimit(.minutes(3)))
struct HostDockerConfinementTests {
    let docker = "/Users/me/.rd/bin/docker"
    let base: String
    let root: String
    let outside: String

    init() throws {
        base = (CodeRootPaths.canonical(NSTemporaryDirectory()) ?? NSTemporaryDirectory()) + "/bc-hostdocker-\(UUID().uuidString.prefix(8))"
        root = base + "/project"
        outside = base + "/private"
        for folder in [root + "/ci", outside] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        try "SECRET_VALUE=do-not-read\n".write(toFile: outside + "/secret.env", atomically: true, encoding: .utf8)
        try "FOO=bar\n".write(toFile: root + "/ok.env", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/escape", withDestinationPath: outside)
    }

    func refusal(_ line: String) -> HostDockerCommand.Refusal? {
        do {
            _ = try HostDockerCommand.argv(for: line, docker: docker, roots: [root], cwd: root)
            return nil
        } catch {
            return error
        }
    }

    @Test func optionsNamingHostFilesOutsideTheProjectAreRefused() {
        let outsideLines = [
            "docker run --env-file \(outside)/secret.env alpine printenv",
            "docker run --env-file=\(outside)/secret.env alpine printenv",
            "docker run --label-file \(outside)/secret.env alpine true",
            "docker container create --env-file ../private/secret.env alpine",
            "docker run --env-file escape/secret.env alpine printenv",
            "docker exec --env-file \(outside)/secret.env web env",
            "docker build -f \(outside)/secret.env .",
            "docker build --file=\(outside)/secret.env .",
            "docker build -f../private/secret.env .",
            "docker build \(outside)",
            "docker build -t x:1 escape",
            "docker image build ..",
            "docker buildx build -t a \(NSHomeDirectory())/.ssh",
            "docker compose -f \(outside)/compose.yaml config",
            "docker compose --file=escape/compose.yaml up",
            "docker compose --env-file \(outside)/secret.env config",
            "docker compose --project-directory \(outside) up",
            "docker compose run --env-from-file \(outside)/secret.env app env",
        ]
        for line in outsideLines {
            guard case .outsidePath = refusal(line) else {
                Issue.record("not refused as outside the project: \(line) → \(String(describing: refusal(line)))")
                continue
            }
        }
        let hostInput = [
            "docker buildx build --secret id=x,src=\(outside)/secret.env .", "docker build --ssh default .",
            "docker buildx build --build-context x=\(outside) .", "docker buildx build --cache-to type=local,dest=\(outside) .",
            "docker buildx build --cache-from type=local,src=\(outside) .", "docker buildx build --cache-from=type=local,src=/x .",
            "docker build https://github.com/acme/repo.git", "docker build git@github.com:acme/repo.git",
            "docker compose build --ssh default", "docker buildx build --attest type=sbom .",
        ]
        for line in hostInput {
            guard case .hostInput = refusal(line) else {
                Issue.record("not refused as a host input: \(line) → \(String(describing: refusal(line)))")
                continue
            }
        }
        // Inside the project: allowed, as are options spelled like file options that mean something else.
        for line in ["docker run --env-file ok.env alpine env", "docker run --env-file \(root)/ok.env alpine env", "docker build -f ci/Dockerfile .",
                     "docker build -t app:1 .", "docker build --cache-from app:1 -t app:2 .", "docker compose -f compose.yaml up -d",
                     "docker logs -f web", "docker rm -f web", "docker inspect -f '{{.Id}}' web", "docker ps -f name=web",
                     "docker compose logs -f", "docker compose -f compose.yaml run --rm app sh", "docker build -f - .",
                     "docker run --env-file ci/new.env alpine env"] {
            #expect(refusal(line) == nil, "\(line) → \(String(describing: refusal(line)))")
        }
    }

    /// The profile is real: under it, a client-side read outside the folders fails, a read inside works, writes outside
    /// fail, and only the endpoint's port is reachable. (`cat` and `curl` stand in for docker's client, which opens
    /// files and sockets the same way.)
    @Test func theSandboxConfinesReadsWritesAndTheNetwork() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let listener = try LoopbackListener()
        let other = try LoopbackListener()
        let paths = HostDockerSandbox.Paths(readWrite: [root], readOnly: [])
        func run(_ argv: [String]) throws -> (Int32, String) {
            let wrapped = try #require(HostDockerSandbox.wrap(argv, paths: paths, port: listener.port))
            let process = Process()
            process.executableURL = URL(filePath: wrapped[0])
            process.arguments = Array(wrapped.dropFirst())
            process.currentDirectoryURL = URL(filePath: root)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let inside = try run(["/bin/cat", root + "/ok.env"])
        #expect(inside.0 == 0 && inside.1.contains("FOO=bar"), "\(inside)")
        for path in [outside + "/secret.env", root + "/escape/secret.env", NSHomeDirectory() + "/.zshrc"] {
            let read = try run(["/bin/cat", path])
            #expect(read.0 != 0 && !read.1.contains("do-not-read"), "read \(path): \(read)")
        }
        let wrote = try run(["/usr/bin/touch", outside + "/written"])
        #expect(wrote.0 != 0 && !FileManager.default.fileExists(atPath: outside + "/written"))
        let wroteInside = try run(["/usr/bin/touch", root + "/written"])
        #expect(wroteInside.0 == 0 && FileManager.default.fileExists(atPath: root + "/written"))
        let allowed = try run(["/usr/bin/curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "http://127.0.0.1:\(listener.port)/"])
        #expect(allowed.1.contains("200"), "endpoint reachable: \(allowed)")
        let blocked = try run(["/usr/bin/curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "http://127.0.0.1:\(other.port)/"])
        #expect(!blocked.1.contains("200"), "another local port: \(blocked)")
        let raw = try run(["/usr/bin/curl", "-s", "--max-time", "5", "--unix-socket", NSHomeDirectory() + "/.rd/docker.sock", "http://d/_ping"])
        #expect(raw.0 != 0 && !raw.1.contains("OK"), "Rancher's raw socket: \(raw)")
        listener.stop()
        other.stop()
    }

    @Test func noSandboxMeansNoCommand() {
        #expect(HostDockerSandbox.wrap(["/bin/echo"], paths: .init(readWrite: [root], readOnly: []), port: 1234, sandbox: "/nonexistent/sandbox-exec") == nil)
        #expect(HostDockerSandbox.wrap(["/bin/echo"], paths: .init(readWrite: ["/"], readOnly: []), port: 1234) == nil, "never the whole disk")
        #expect(HostDockerSandbox.wrap(["/bin/echo"], paths: .init(readWrite: [NSHomeDirectory()], readOnly: []), port: 1234) == nil, "never the home folder")
        #expect(HostDockerSandbox.port(dockerHost: "tcp://127.0.0.1:4567/bctoken") == 4567)
        #expect(HostDockerSandbox.port(dockerHost: "unix:///var/run/docker.sock") == nil)
        // Paths are parameters, never profile text.
        let wrapped = HostDockerSandbox.wrap(["/bin/echo"], paths: .init(readWrite: [root], readOnly: []), port: 1234) ?? []
        #expect(!(wrapped.first { $0.hasPrefix("(version") } ?? "").contains(root))
    }
}

/// A loopback HTTP listener answering every connection with 200 (for the sandbox's network rule).
final class LoopbackListener: Sendable {
    let fd: Int32
    let port: Int

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 8)
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        self.fd = fd
        port = Int(UInt16(bigEndian: actual.sin_port))
        DispatchQueue(label: "bc.test.loopback").async {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                var buffer = [UInt8](repeating: 0, count: 4096)
                _ = read(client, &buffer, buffer.count)
                let answer = Array("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                _ = write(client, answer, answer.count)
                close(client)
            }
        }
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}
