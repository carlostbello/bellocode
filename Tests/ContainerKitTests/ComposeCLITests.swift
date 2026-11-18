import Foundation
import Testing

@testable import ContainerKit

/// Compose-stack MCP servers through Rancher Desktop's `docker compose`: the child's environment (nothing inherited,
/// Rancher's socket, BelloCode's own Docker configuration), the normalised model's checks, BelloCode's override, and
/// `ps` output.
@Suite("Compose CLI")
struct ComposeCLITests {
    @Test func theChildGetsRanchersSocketAndNoInheritedConfiguration() {
        let cli = ComposeCLI(executable: URL(filePath: "/Users/me/.rd/bin/docker-compose"), socketPath: "/Users/me/.rd/docker.sock",
                             configDirectory: URL(filePath: "/tmp/bc-docker-config"))
        let env = cli.environment()
        #expect(env["DOCKER_HOST"] == "unix:///Users/me/.rd/docker.sock")
        #expect(env["DOCKER_CONFIG"] == "/tmp/bc-docker-config", "never the person's ~/.docker (credential helpers, contexts)")
        #expect(env["PATH"] == "/Users/me/.rd/bin:/usr/bin:/bin", "Rancher's folder only, never an arbitrary PATH")
        #expect(Set(env.keys) == ["DOCKER_HOST", "DOCKER_CONFIG", "HOME", "PATH", "COMPOSE_ANSI", "COMPOSE_STATUS_STDOUT"])
        #expect(ComposeCLI.arguments(project: "p", files: [URL(filePath: "/a.yaml"), URL(filePath: "/b.yaml")], workingDirectory: URL(filePath: "/w"),
                                     command: ["up", "-d"])
            == ["--project-name", "p", "--project-directory", "/w", "--file", "/a.yaml", "--file", "/b.yaml", "up", "-d"])
    }

    static let config = """
        {"name": "bellocode-mcp-abc", "services": {
          "mcp": {"build": {"context": "/src"}, "ports": [{"target": 8080, "published": "8080"}], "environment": {"MODE": "x"}},
          "db": {"image": "postgres:16", "volumes": [{"type": "volume", "source": "data", "target": "/var/lib/postgresql/data"}]},
          "root": {"image": "acme/root:1", "privileged": true, "cap_add": ["NET_ADMIN"], "network_mode": "host",
                   "volumes": [{"type": "bind", "source": "/Users/me/src", "target": "/src", "read_only": true},
                               {"type": "bind", "source": "/var/run/docker.sock", "target": "/var/run/docker.sock"}]},
          "named": {"image": "x", "container_name": "my-mcp"}
        }}
        """

    @Test func theModelNamesWhatReachesPastTheContainers() throws {
        let model = try ComposeModel.parse(Data(Self.config.utf8))
        #expect(model.containerName("mcp") == "bellocode-mcp-abc-mcp-1")
        #expect(model.containerName("named") == "my-mcp")
        #expect(model.containerName("nope") == nil)
        #expect(model.elevated == ["root: privileged", "root: cap_add", "root: network_mode: host", "root: bind mount /Users/me/src (read-only)"])
        #expect(model.forbidden == ["root: mounts the container engine's socket (/var/run/docker.sock)"])
        #expect(model.services.first { $0.name == "db" }?.elevated.isEmpty == true, "named volumes are the stack's own")
    }

    @Test func theOverrideLabelsResetsPortsAndAddsCertificatesProxiesAndBuildContext() throws {
        let model = try ComposeModel.parse(Data(Self.config.utf8))
        let corporate = CorporateNetwork(certificateDirectory: "/Users/me/certs", httpsProxy: "http://proxy:8080")
        let text = model.override(label: ("app.bellocode.mcp-stack", "abc"), corporate: corporate)
        #expect(text.contains("  \"mcp\":\n    labels:\n      \"app.bellocode.mcp-stack\": \"abc\"\n    ports: !reset []"))
        #expect(!text.contains("  \"db\":\n    labels:\n      \"app.bellocode.mcp-stack\": \"abc\"\n    ports"), "only services that publish")
        #expect(text.contains("\"NO_PROXY\": \"localhost,127.0.0.1,::1,db,mcp,named,root\""))
        #expect(text.contains("        source: \"/Users/me/certs\"\n        target: \"/etc/bellocode/certs\"\n        read_only: true"))
        #expect(text.contains("    build:\n      args:\n        \"HTTPS_PROXY\": \"http://proxy:8080\""))
        #expect(text.contains("      additional_contexts:\n        bellocode-ca: \"/Users/me/certs\""))
        #expect(text.components(separatedBy: "additional_contexts").count == 2, "only the service that builds")
        let plain = model.override(label: ("k", "v"), corporate: nil)
        #expect(!plain.contains("environment") && !plain.contains("build:") && plain.contains("ports: !reset []"))
    }

    @Test func psOutputInBothShapes() {
        let lines = #"{"Service":"mcp","State":"running","Health":"healthy","ExitCode":0}"# + "\n" + #"{"Service":"db","State":"exited","Health":"","ExitCode":1}"#
        let parsed = ComposeServiceStatus.parse(lines)
        #expect(parsed == [ComposeServiceStatus(service: "mcp", state: "running", health: "healthy", exitCode: 0),
                           ComposeServiceStatus(service: "db", state: "exited", health: nil, exitCode: 1)])
        #expect(ComposeServiceStatus.parse("[" + #"{"Service":"a","State":"running"}"# + "]").first?.service == "a")
        #expect(ComposeServiceStatus.parse("").isEmpty)
    }
}
