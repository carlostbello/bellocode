import Foundation
import Testing

@testable import OpenCodeKit

/// `docker run` command lines as MCP clients configure image-based stdio servers, read (never run) so BelloCode runs
/// the image itself; and the isolated configuration's `docker run` entries routed to their own containers.
@Suite("docker run conversion")
struct DockerRunCommandTests {
    let helper = "/Applications/BelloCode.app/Contents/Helpers/bellocode-exec"

    @Test func theCommonImageServerFormConverts() throws {
        let run = try DockerRunCommand.parse([
            "docker", "run", "-i", "--rm", "-e", "GITHUB_PERSONAL_ACCESS_TOKEN", "-e", "GITHUB_TOOLSETS=repos,issues", "--name", "gh",
            "ghcr.io/github/github-mcp-server", "stdio", "--read-only",
        ])
        #expect(run.image == "ghcr.io/github/github-mcp-server")
        #expect(run.args == ["stdio", "--read-only"], "everything after the image belongs to the server")
        #expect(run.passthrough == ["GITHUB_PERSONAL_ACCESS_TOKEN"])
        #expect(run.environment == ["GITHUB_TOOLSETS": "repos,issues"])
        #expect(run.notes.contains { $0.contains("--name") })
        #expect(run.mounts.isEmpty && run.network == nil)
    }

    @Test func combinedFlagsInlineValuesMountsNetworkAndEntrypoint() throws {
        let run = try DockerRunCommand.parse([
            "/usr/local/bin/docker", "container", "run", "-it", "--network=none", "-eMODE=x", "-v", "/Users/me/docs:/docs:ro",
            "--entrypoint", "/bin/server", "acme/tool:2",
        ])
        #expect(run.image == "acme/tool:2")
        #expect(run.network == "none")
        #expect(run.environment == ["MODE": "x"])
        #expect(run.mounts == [.init(source: "/Users/me/docs", target: "/docs", readOnly: true)])
        #expect(run.entrypoint == ["/bin/server"])
        #expect(run.notes.contains { $0.contains("-t") }, "-t is dropped: stdio needs no terminal")
    }

    @Test func optionsThatCannotBeConvertedSafelyAreRefusedWithTheReason() {
        func refusal(_ argv: [String]) -> String? {
            do {
                _ = try DockerRunCommand.parse(argv)
                return nil
            } catch {
                return error.description
            }
        }
        #expect(refusal(["docker", "run", "--privileged", "img"])?.contains("--privileged") == true)
        #expect(refusal(["docker", "run", "--network", "host", "img"])?.contains("host") == true)
        #expect(refusal(["docker", "run", "--env-file", ".env", "img"])?.contains("--env-file") == true)
        #expect(refusal(["docker", "run", "-v", "/var/run/docker.sock:/var/run/docker.sock", "img"])?.contains("docker.sock") == true)
        #expect(refusal(["docker", "run", "-v", "data:/data", "img"])?.contains("named volume") == true)
        #expect(refusal(["docker", "run", "-i", "--rm"])?.contains("no image") == true)
        #expect(refusal(["docker", "run", "--frobnicate", "img"])?.contains("unknown option") == true)
        #expect(refusal(["npx", "-y", "server"]) == "not a docker run command")
        #expect(DockerRunCommand.isDockerRun(["podman", "run", "img"]))
        #expect(!DockerRunCommand.isDockerRun(["docker", "compose", "up"]))
    }

    @Test func aDockerRunEntryOfTheIsolatedConfigurationRunsItsImageOthersStayRefused() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-docker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "opencode")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
        { "mcp": { "servers": {
          "gh": { "type": "local", "command": ["docker", "run", "-i", "--rm", "-e", "TOKEN", "ghcr.io/acme/gh-mcp:1"], "environment": { "TOKEN": "t0k" } },
          "docs": { "type": "local", "command": ["docker", "run", "-i", "-v", "/Users/me:/me", "acme/docs"] },
          "npx": { "type": "local", "command": ["npx", "-y", "tools"] }
        } } }
        """.utf8).write(to: folder.appending(path: "opencode.json"))
        let (locals, _) = MCPRouting.globalLocalServers(configDirectory: root)
        #expect(locals["gh"]?.image?.image == "ghcr.io/acme/gh-mcp:1")
        #expect(locals["docs"]?.refusal?.contains("mounts folders") == true, "mounts need review in Settings")
        #expect(locals["npx"]?.refusal == "its command runs a program, not an image")
        let (servers, _) = MCPRouting.globalOverrides(configDirectory: root, helper: helper)
        let command = servers["gh"]?["command"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(command == [helper, "--stdio", "--mcp", "cfg-gh"])
        #expect(servers["gh"]?["environment"]?["TOKEN"]?.stringValue == "t0k", "the -e NAME value reaches the helper's environment")
        #expect(MCPRouting.route(of: command, helper: helper) == .image(id: "cfg-gh"))
        #expect(servers["docs"]?["command"]?.arrayValue?.compactMap(\.stringValue) == [helper, "--stdio", "--refuse", "docs"])
        #expect(servers["npx"]?["command"]?.arrayValue?.compactMap(\.stringValue) == [helper, "--stdio", "--refuse", "npx"])
    }

    @Test func registrationConfigsCarrySecretsOnlyInTheRequest() {
        let image = MCPRouting.imageServerConfig(helper: helper, id: "abc", project: "/p", secrets: ["TOKEN": "s"])
        #expect(image["command"]?.arrayValue?.compactMap(\.stringValue) == [helper, "--stdio", "--mcp", "abc", "--project", "/p"])
        #expect(image["environment"]?["TOKEN"]?.stringValue == "s")
        let remote = MCPRouting.remoteServerConfig(url: "https://gw.example.com/mcp", headers: ["Authorization": "Bearer x"])
        #expect(remote["type"]?.stringValue == "remote")
        #expect(remote["headers"]?["Authorization"]?.stringValue == "Bearer x")
        #expect(remote["oauth"]?.boolValue == false, "header-authenticated: no OAuth discovery")
        #expect(MCPRouting.remoteServerConfig(url: "https://x", headers: [:])["oauth"] == nil)
    }
}
