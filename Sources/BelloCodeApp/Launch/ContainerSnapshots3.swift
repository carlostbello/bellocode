import AppKit
import BelloCore
import ContainerKit
import DesignSystem
import Engine
import Foundation
import SwiftUI

/// `--snapshot containers3` (Containers 3, docs/features/containers.md): mock data on the scripted runtime with the
/// administrator's image policy (registry.acme.internal only) and two scripted enterprise roots. States: Settings ▸ MCP
/// Servers with the three kinds, the image server editor, the Import review, Network diagnostics results, the
/// certificate trust setting, and a project's opt-out; light and dark.
extension SnapshotRunner {
    func runContainers3() async -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("FAIL cannot create \(directory.path): \(error)")
            return false
        }
        let engine = runtime.engine
        guard SnapshotWorkspaceRuntime.current != nil else {
            log("FAIL container execution is not configured for the snapshot")
            return false
        }
        func wanted(_ state: String) -> Bool { only.isEmpty || only.contains(state) }
        await engine.start()
        guard await waitUntil(timeout: .seconds(20), { engine.root.connection == .live && !engine.root.projects.isEmpty }) else {
            log("FAIL mock never became live")
            return false
        }
        let environments = engine.environments
        _ = await waitUntil(timeout: .seconds(5)) { environments.runtime?.isReady == true }
        let project = engine.root.projects[0].directory
        let created = !FileManager.default.fileExists(atPath: project)
        if created { try? FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true) }
        defer { if created { try? FileManager.default.removeItem(atPath: project) } }
        var written: [String] = []

        // Three kinds: the company gateway (remote, bearer token in the Keychain), an image server, a compose stack.
        let gateway = GlobalMCPServer(
            id: "snapgw0001", name: "company-gateway", kind: .remote,
            remote: RemoteMCPSetting(url: "https://mcp-gateway.acme.internal/mcp",
                                     headers: [MCPKeyValue(name: "Authorization", secret: true), MCPKeyValue(name: "X-Team", value: "platform")]))
        let github = GlobalMCPServer(
            id: "snapim0001", name: "github", kind: .image,
            image: ImageMCPSetting(image: "registry.acme.internal/mcp/github-mcp-server:0.9", args: ["stdio"],
                                   environment: [MCPKeyValue(name: "GITHUB_PERSONAL_ACCESS_TOKEN", secret: true), MCPKeyValue(name: "GITHUB_TOOLSETS", value: "repos,issues")]),
            source: "Claude Desktop (~/Library/Application Support/Claude/claude_desktop_config.json)")
        let docs = GlobalMCPServer(
            id: "snapim0002", name: "docs-search", kind: .image,
            image: ImageMCPSetting(image: "registry.acme.internal/mcp/docs-search:2026.11", mounts: [UserMount(path: "/Volumes/Shared/handbook", readOnly: true)],
                                   network: .none, shared: true))
        let notes = GlobalMCPServer(
            id: "snapst0001", name: "team-notes", kind: .stack,
            stack: StackMCPSetting(composeYAML: Self.stackYAML, service: "mcp", port: 8080, path: "/mcp", hostPort: 51834))
        try? await environments.saveGlobalMCP([gateway, github, docs, notes], secrets: [
            GlobalMCPSecrets.account(server: gateway.id, header: "Authorization"): SecretValue("Bearer snapshot"),
            GlobalMCPSecrets.account(server: github.id, variable: "GITHUB_PERSONAL_ACCESS_TOKEN"): SecretValue("snapshot"),
        ])
        _ = await waitUntil(timeout: .seconds(5)) { environments.globalMCPStates[github.id]?.imagePresent != nil }
        try? await Task.sleep(for: .milliseconds(200))
        let projects = engine.root.projects.map { ($0.directory as NSString).lastPathComponent }
        var connected = GlobalMCPState()
        connected.connected = Array(projects.prefix(2))
        environments.previewGlobalMCPState(gateway.id, connected)
        var image = connected
        image.imagePresent = true
        environments.previewGlobalMCPState(github.id, image)
        var missing = GlobalMCPState()
        missing.imagePresent = false
        missing.problem = "The image registry.acme.internal/mcp/docs-search:2026.11 is not on this Mac yet. Pull it to use this server."
        environments.previewGlobalMCPState(docs.id, missing)
        var stack = GlobalMCPState()
        stack.connected = [projects[0]]
        stack.hostPort = 51834
        stack.services = [
            ServiceState(name: "mcp", image: "registry.acme.internal/mcp/notes:1.2", ports: [8080], phase: .running, health: "healthy"),
            ServiceState(name: "db", image: "registry.acme.internal/library/postgres:16", ports: [5432], phase: .running, health: "healthy"),
        ]
        environments.previewGlobalMCPState(notes.id, stack)

        let model = MCPServersSettingsModel(engine: engine)
        if wanted("mcp-servers") {
            written += await renderComponent(state: "mcp-servers") { MCPServersSettingsView(model: model, service: environments) }
        }
        if wanted("mcp-editor") {
            await model.edit(github)
            written += await renderComponent(state: "mcp-editor") { MCPServersSettingsView(model: model, service: environments) }
            model.draft = nil
        }
        if wanted("import-review") {
            let existing = Set(environments.globalMCP.servers.map(\.name))
            let candidates = MCPImport.parse(Data(Self.cursorJSON.utf8), format: .cursor, source: "Cursor (~/.cursor/mcp.json)", existingNames: existing)
                + MCPImport.parse(Data(Self.vscodeJSON.utf8), format: .vscode, source: "VS Code (~/Library/Application Support/Code/User/mcp.json)",
                                  existingNames: existing)
            model.importRows = candidates.map { MCPImportRow(candidate: $0, selected: $0.isConvertible) }
            written += await renderComponent(state: "import-review") {
                SettingsPaneBody {
                    SettingsGroup("Import review", footer: "Read once from the files listed, which are not changed. Selected servers are added and enabled when you choose Add Selected; secret values found in the files go to your Keychain then. Mounts are left out unless you include them.") {
                        MCPImportReviewView(model: model, rows: model.importRows ?? [])
                    }
                }
            }
            model.importRows = nil
        }
        let containers = ContainersSettingsModel(engine: engine)
        await environments.refreshCorporateNetwork()
        if wanted("certificate-trust") {
            written += await renderComponent(state: "certificate-trust") {
                SettingsPaneBody {
                    SettingsGroup("Corporate network", footer: "A transparent proxy needs no settings. If it inspects TLS with your organisation's root certificate, the Mac trusts it but containers do not until it is added here. Applies to new containers (existing ones are recreated on next use).") {
                        CorporateNetworkSettingsView(model: containers.network, service: environments)
                    }
                }
            }
        }
        if wanted("network-diagnostics") {
            let issuer = "Acme Corp TLS Inspection CA"
            environments.previewNetworkDiagnostics(NetworkDiagnostics(
                project: projects[0],
                container: [
                    NetworkProbeResult(url: "https://gitlab.novacoast.com", ok: true, status: 302, issuer: "CN=\(issuer), O=Acme Corp", tool: "curl"),
                    NetworkProbeResult(url: "https://registry.npmjs.org", ok: true, status: 200, issuer: "CN=\(issuer), O=Acme Corp",
                                       proxyHeaders: ["via: 1.1 proxy.acme.internal"], tool: "curl"),
                    NetworkProbeResult(url: "https://pypi.org/simple/", ok: false, issuer: "CN=\(issuer), O=Acme Corp",
                                       error: "curl: (60) SSL certificate problem: unable to get local issuer certificate", tool: "curl"),
                ],
                mac: [
                    NetworkProbeResult(url: "https://gitlab.novacoast.com", ok: true, status: 302, issuer: issuer, tool: "URLSession"),
                    NetworkProbeResult(url: "https://registry.npmjs.org", ok: true, status: 200, issuer: issuer, tool: "URLSession"),
                    NetworkProbeResult(url: "https://pypi.org/simple/", ok: true, status: 200, issuer: issuer, tool: "URLSession"),
                ],
                interceptedBy: ["Acme Corp TLS Inspection CA"]))
            written += await renderComponent(state: "network-diagnostics") {
                SettingsPaneBody {
                    SettingsGroup("Network diagnostics", footer: "Fetches each URL from inside a running project container and from this Mac, as opencode would (its built-in roots plus the selected enterprise roots), and shows the certificate issuer and any proxy headers.") {
                        NetworkDiagnosticsView(model: containers.network, service: environments)
                    }
                }
            }
        }
        if wanted("project-opt-out") {
            var settings = environments.environment(for: project).settings
            settings.globalMCPOptOut = [docs.id]
            await environments.update(project, settings: settings)
            let environmentModel = EnvironmentSettingsModel(engine: engine, directory: project)
            environmentModel.load()
            written += await renderComponent(state: "project-opt-out") {
                SettingsPaneBody {
                    SettingsGroup("MCP servers for all projects", footer: "Set up in Settings ▸ MCP Servers. Turn them off here for this project only; a project server of the same name wins.") {
                        GlobalMCPOptOutView(model: environmentModel, environment: environments.environment(for: project), service: environments)
                    }
                }
            }
        }
        for path in written { log("wrote \(path)") }
        log(written.isEmpty ? "FAIL nothing written" : "PASS \(written.count) images")
        return !written.isEmpty
    }

    static let stackYAML = """
        services:
          mcp:
            image: registry.acme.internal/mcp/notes:1.2
            ports: ["8080"]
            depends_on:
              db:
                condition: service_healthy
          db:
            image: registry.acme.internal/library/postgres:16
            healthcheck:
              test: ["CMD-SHELL", "pg_isready -U postgres"]
        """

    static let cursorJSON = """
        { "mcpServers": {
          "linear": { "url": "https://mcp.linear.app/sse" },
          "playwright": { "command": "docker", "args": ["run", "-i", "--rm", "-t", "--pull", "always", "registry.acme.internal/mcp/playwright:1", "--headless"] },
          "filesystem": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/src"] }
        } }
        """

    static let vscodeJSON = """
        { "servers": {
          "gitlab": { "type": "stdio", "command": "docker",
                      "args": ["run", "-i", "--rm", "-e", "GITLAB_TOKEN", "-v", "~/.config/glab:/config:ro", "registry.acme.internal/mcp/gitlab:1"],
                      "env": { "GITLAB_TOKEN": "${input:gitlab-token}" } },
          "root-tool": { "type": "stdio", "command": "docker", "args": ["run", "-i", "--privileged", "acme/root-tool"] }
        } }
        """
}

/// Two scripted enterprise roots for snapshots (never the Mac's Keychain): one installed for all users by a profile,
/// one trusted only in the login keychain.
struct SnapshotCertificates: TrustedCertificateSource {
    func trustedCertificates() -> [TrustedCertificate] {
        [
            TrustedCertificate(der: Data("snapshot acme root".utf8), subject: "Acme Corp TLS Inspection CA", domain: .admin, isSelfSigned: true,
                               isCertificateAuthority: true, notAfter: Date(timeIntervalSince1970: 2_051_222_400)),
            TrustedCertificate(der: Data("snapshot dev root".utf8), subject: "Local Development CA", domain: .user, isSelfSigned: true,
                               isCertificateAuthority: true, notAfter: Date(timeIntervalSince1970: 1_830_297_600)),
        ]
    }
    func systemAnchors() -> [Data] { [] }
}
