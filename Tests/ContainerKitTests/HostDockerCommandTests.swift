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
