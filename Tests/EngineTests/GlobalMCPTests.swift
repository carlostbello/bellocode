import BelloCore
import ContainerKit
import Darwin
import Foundation
import OpenCodeKit
import Synchronization
import Testing

@testable import Engine

/// Global MCP servers (Settings ▸ MCP Servers) and the corporate network, in the engine: where secrets go (Keychain
/// and opencode's runtime registration only), registration per project with opt-outs, compose stacks forwarded and
/// registered as remote, Import from each supported format, and the enterprise root selection.
@MainActor
@Suite("Global MCP servers", .timeLimit(.minutes(3)))
struct GlobalMCPTests {
    let root: URL
    let project: String
    let runtime = FakeWorkspaceRuntime()
    let vault = InMemorySecretVault()
    let written = Written()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "bellocode-gmcp-\(UUID().uuidString)", directoryHint: .isDirectory)
        project = root.appending(path: "project").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
    }

    func makeService(certificates: [TrustedCertificate] = []) async throws -> (EnvironmentService, ProjectionStore) {
        var configuration = ContainerConfiguration(
            helperURL: URL(filePath: "/Applications/BelloCode.app/Contents/Helpers/bellocode-exec"),
            execConfigURL: root.appending(path: "exec.json"), opencodeDataDirectory: nil, runtime: runtime, registryVault: InMemorySecretVault())
        configuration.mcpVault = vault
        configuration.mcpLogDirectory = root.appending(path: "mcp-logs")
        configuration.certificateSource = FakeCertificates(certificates: certificates)
        configuration.certificateDirectory = root.appending(path: "certs")
        configuration.managedNetwork = { nil }
        configuration.systemProxy = { SystemProxySettings() }
        let store = try ProjectionStore(location: .inMemory)
        let service = EnvironmentService(configuration: configuration, store: store)
        service.worktreeParent = { [root] directory in root.appending(path: "worktrees/\((directory as NSString).lastPathComponent)").path }
        let sink = written
        service.fileSink = { data, url in
            sink.files.withLock { $0[url] = data }
            try ExecHelperConfig.writeAtomically(data, to: url)
        }
        await service.start()
        await service.recheckRuntime()
        return (service, store)
    }

    func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    static let gateway = GlobalMCPServer(
        id: "gw00000001", name: "company-gateway", kind: .remote,
        remote: RemoteMCPSetting(url: "https://mcp-gateway.example.com/mcp",
                                 headers: [MCPKeyValue(name: "Authorization", secret: true), MCPKeyValue(name: "X-Team", value: "platform")]))

    // MARK: Secrets

    @Test func headerSecretsLiveOnlyInTheKeychainAndInOpencodesRegistration() async throws {
        let (service, store) = try await makeService()
        defer { service.stop() }
        let secret = "Bearer gw-token-\(UUID().uuidString)"
        try await service.saveGlobalMCP([Self.gateway], secrets: [GlobalMCPSecrets.account(server: Self.gateway.id, header: "Authorization"): SecretValue(secret)])
        await service.writeConfigNow()

        // The store (app preference) and every file BelloCode wrote never hold the value.
        let saved = try #require(try await store.preference(GlobalMCPList.preferenceKey, as: GlobalMCPList.self))
        #expect(saved.servers.first?.remote?.headers.first?.value == nil)
        #expect(!String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).contains(secret))
        for (url, data) in written.files.withLock({ $0 }) {
            #expect(!String(decoding: data, as: UTF8.self).contains(secret), "\(url.lastPathComponent) must not hold the secret")
        }
        // The Keychain holds it.
        let stored = try vault.read(account: GlobalMCPSecrets.account(server: Self.gateway.id, header: "Authorization"))
        #expect(stored.map { String(decoding: $0.utf8, as: UTF8.self) } == secret)
        #expect(await service.hasGlobalMCPSecret(GlobalMCPSecrets.account(server: Self.gateway.id, header: "Authorization")))

        // opencode's registration for a project in use carries it, with the plain header and OAuth off.
        service.projectInUse(project)
        let registrations = service.globalRegistrations(service.environment(for: project))
        let (configs, missing) = EnvironmentService.resolve(registrations, vault: vault)
        #expect(missing.isEmpty)
        let config = try #require(configs["company-gateway"])
        #expect(config["url"]?.stringValue == "https://mcp-gateway.example.com/mcp")
        #expect(config["headers"]?["Authorization"]?.stringValue == secret)
        #expect(config["headers"]?["X-Team"]?.stringValue == "platform")
        #expect(config["oauth"]?.boolValue == false)

        // Removing deletes the Keychain value; Undo puts it back.
        let removed = try #require(await service.removeGlobalMCP(Self.gateway.id))
        #expect(try vault.read(account: GlobalMCPSecrets.account(server: Self.gateway.id, header: "Authorization")) == nil)
        await service.undoRemoveGlobalMCP(removed)
        #expect(try vault.read(account: GlobalMCPSecrets.account(server: Self.gateway.id, header: "Authorization")) != nil)
    }

    @Test func aMissingSecretKeepsTheServerUnregisteredWithTheReason() async throws {
        let (service, _) = try await makeService()
        defer { service.stop() }
        try await service.saveGlobalMCP([Self.gateway])
        service.projectInUse(project)
        let (configs, missing) = EnvironmentService.resolve(service.globalRegistrations(service.environment(for: project)), vault: vault)
        #expect(configs.isEmpty, "never registered without its secret")
        #expect(missing[Self.gateway.id]?.contains("Authorization") == true)
    }

    // MARK: Registration and opt-out

    @Test func imageServersAreRegisteredPerProjectThroughTheHelperAndProjectsCanOptOut() async throws {
        let (service, _) = try await makeService()
        defer { service.stop() }
        _ = runtime.state.withLock { $0.images.insert("ghcr.io/acme/tools-mcp:1") }
        let tools = GlobalMCPServer(id: "im00000001", name: "tools", kind: .image, image: ImageMCPSetting(
            image: "ghcr.io/acme/tools-mcp:1", args: ["--stdio"], environment: [MCPKeyValue(name: "API_KEY", secret: true), MCPKeyValue(name: "MODE", value: "ro")]))
        try await service.saveGlobalMCP([tools, Self.gateway], secrets: [
            GlobalMCPSecrets.account(server: tools.id, variable: "API_KEY"): SecretValue("k-123"),
            GlobalMCPSecrets.account(server: Self.gateway.id, header: "Authorization"): SecretValue("Bearer x"),
        ])
        #expect(!service.registeredMCPNames(project).contains("tools"), "nothing before the project is used")
        #expect(service.globalRegistrations(service.environment(for: project)).isEmpty)
        service.projectInUse(project)
        var (configs, _) = EnvironmentService.resolve(service.globalRegistrations(service.environment(for: project)), vault: vault)
        let command = configs["tools"]?["command"]?.arrayValue?.compactMap(\.stringValue)
        #expect(command == ["/Applications/BelloCode.app/Contents/Helpers/bellocode-exec", "--stdio", "--mcp", tools.id, "--project", project])
        #expect(configs["tools"]?["environment"]?["API_KEY"]?.stringValue == "k-123")
        #expect(configs["tools"]?["environment"]?["MODE"] == nil, "non-secret values travel in the helper configuration")

        // The helper configuration describes the image, names the secret, and has no value.
        await service.writeConfigNow()
        let helperConfig = try JSONDecoder().decode(ExecHelperConfig.self, from: Data(contentsOf: root.appending(path: "exec.json")))
        let spec = try #require(helperConfig.mcpServers?.first { $0.id == tools.id })
        #expect(spec.image == "ghcr.io/acme/tools-mcp:1" && spec.args == ["--stdio"])
        #expect(spec.secretNames == ["API_KEY"] && spec.environment == ["MODE": "ro"])
        #expect(spec.mounts.isEmpty, "no folder unless the person listed one")
        #expect(!String(decoding: try Data(contentsOf: root.appending(path: "exec.json")), as: UTF8.self).contains("k-123"))

        // Opt out of one server, then of all; a project server of the same name wins.
        var settings = service.environment(for: project).settings
        settings.globalMCPOptOut = [tools.id]
        await service.update(project, settings: settings)
        (configs, _) = EnvironmentService.resolve(service.globalRegistrations(service.environment(for: project)), vault: vault)
        #expect(Set(configs.keys) == ["company-gateway"])
        settings.globalMCPOptOut = []
        settings.mcpServers = [MCPServerSetting(name: "company-gateway", command: ["node", "gw.js"])]
        await service.update(project, settings: settings)
        (configs, _) = EnvironmentService.resolve(service.globalRegistrations(service.environment(for: project)), vault: vault)
        #expect(Set(configs.keys) == ["tools"])
        settings.useGlobalMCP = false
        await service.update(project, settings: settings)
        #expect(service.globalRegistrations(service.environment(for: project)).isEmpty)
    }

    @Test func anImageOutsideThePolicyIsRefusedBeforeAnythingRuns() async throws {
        var (service, _) = try await makeService()
        service.stop()
        var configuration = try #require(service.configuration)
        configuration.managedPolicy = { .init(policy: ImagePolicy(allowedPrefixes: ["registry.acme.internal"]), source: "test") }
        service = EnvironmentService(configuration: configuration, store: try ProjectionStore(location: .inMemory))
        await service.start()
        await service.recheckRuntime()
        defer { service.stop() }
        let tools = GlobalMCPServer(id: "im00000002", name: "tools", kind: .image, image: ImageMCPSetting(image: "docker.io/acme/tools:1"))
        try await service.saveGlobalMCP([tools])
        let spec = try #require(service.imageServerSpecs().first { $0.id == tools.id })
        #expect(spec.blocked?.contains("not allowed by the image policy") == true, "the helper reports it instead of running")
        #expect(await waitFor { service.globalMCPStates[tools.id]?.problem?.contains("not allowed") == true })
        service.projectInUse(project)
        #expect(service.globalRegistrations(service.environment(for: project)).isEmpty)
    }

    // MARK: Compose stacks

    @Test func aStackEndpointIsForwardedRegisteredAsRemoteAndStartsTheStackOnFirstUse() async throws {
        let (service, _) = try await makeService()
        defer { service.stop() }
        let compose = """
            services:
              mcp:
                image: registry.acme.internal/mcp/notes:1
                ports: ["8080"]
                depends_on: [db]
              db:
                image: registry.acme.internal/library/redis:7
              builder:
                build: ./x
            """
        let stack = GlobalMCPServer(id: "st00000001", name: "notes", kind: .stack,
                                    stack: StackMCPSetting(composeYAML: compose, service: "mcp", port: 8080, path: "/mcp"))
        #expect(stack.validationErrors().isEmpty)
        try await service.saveGlobalMCP([stack])
        #expect(await waitFor { service.globalMCPStates[stack.id]?.hostPort != nil })
        let port = try #require(service.globalMCPStates[stack.id]?.hostPort)
        #expect(await waitFor { service.globalMCP.servers.first?.stack?.hostPort == port }, "the port is kept for the next launch")

        service.projectInUse(project)
        let (configs, _) = EnvironmentService.resolve(service.globalRegistrations(service.environment(for: project)), vault: vault)
        #expect(configs["notes"]?["type"]?.stringValue == "remote")
        #expect(configs["notes"]?["url"]?.stringValue == "http://127.0.0.1:\(port)/mcp", "loopback only, nothing published")

        // The refused service is listed and never started; the first connection starts the rest.
        let (specs, refused, _) = service.stackSpecs(stack)
        #expect(Set(specs.map(\.name)) == ["mcp", "db"])
        #expect(refused.contains { $0.contains("builder") })
        #expect(specs.allSatisfy { $0.extraLabels[EnvironmentService.stackLabel] == stack.id })
        #expect(specs.allSatisfy { $0.network == ServiceLabels.networkName(projectKey: EnvironmentService.stackKey(stack.id), offline: false) })
        #expect(runtime.stackEnsures.withLock { $0 }.isEmpty, "nothing runs before a connection")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(connected == 0)
        #expect(await waitFor { !runtime.stackEnsures.withLock { $0 }.isEmpty })
        #expect(Set(runtime.stackEnsures.withLock { $0 }.first ?? []) == ["mcp", "db"])
        #expect(service.stackProjectKeys.contains(EnvironmentService.stackKey(stack.id)), "Prune keeps the stack's volumes")

        // Turned off: no forwarder, no registration.
        await service.setGlobalMCP(stack.id, enabled: false)
        #expect(service.stackForwarders[stack.id] == nil)
        #expect(service.globalRegistrations(service.environment(for: project)).isEmpty)
    }

    // MARK: Import

    static let fixtures = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/mcp-import")

    func candidates(_ file: String, _ format: MCPImport.Format) throws -> [String: MCPImport.Candidate] {
        let data = try Data(contentsOf: Self.fixtures.appending(path: file))
        return Dictionary(uniqueKeysWithValues: MCPImport.parse(data, format: format, source: file).map { ($0.name, $0) })
    }

    @Test func opencodeDockerRunBecomesAnImageServerAndItsTokenMovesToTheKeychain() throws {
        let found = try candidates("opencode.jsonc", .opencode)
        let github = try #require(found["github"]?.server)
        #expect(github.kind == .image && github.image?.image == "ghcr.io/github/github-mcp-server")
        #expect(github.image?.environment == [MCPKeyValue(name: "GITHUB_PERSONAL_ACCESS_TOKEN", secret: true)])
        #expect(found["github"]?.secrets[GlobalMCPSecrets.account(server: github.id, variable: "GITHUB_PERSONAL_ACCESS_TOKEN")]
            .map { String(decoding: $0.utf8, as: UTF8.self) } == "fixture-not-a-real-token")
        #expect(!String(decoding: try JSONEncoder().encode(github), as: UTF8.self).contains("fixture-not-a-real-token"))
        let gateway = try #require(found["gateway"]?.server)
        #expect(gateway.kind == .remote)
        #expect(gateway.remote?.headers == [MCPKeyValue(name: "Authorization", secret: true), MCPKeyValue(name: "X-Team", value: "platform")])
        #expect(found["gateway"]?.secrets.isEmpty == true, "a {env:…} reference is not a value")
        #expect(found["gateway"]?.notes.contains { $0.contains("Authorization") } == true)
        #expect(found["filesystem"]?.server == nil)
        #expect(found["filesystem"]?.refusal?.contains("runs npx on this Mac") == true)
        let legacy = try candidates("opencode-v1.json", .opencode)
        #expect(legacy["context7"]?.server?.kind == .remote)
        #expect(legacy["legacy"]?.refusal?.contains("uvx") == true)
        #expect(legacy["legacy"]?.notes.contains { $0.contains("Turned off") } == true)
    }

    @Test func claudeDesktopMountsAreFlaggedNotAppliedAndPrivilegeIsRefused() throws {
        let found = try candidates("claude_desktop_config.json", .claudeDesktop)
        let postgres = try #require(found["postgres"])
        #expect(postgres.server?.image?.mounts.isEmpty == true, "mounts are left out until the person includes them")
        #expect(postgres.mounts == [UserMount(path: "/Users/me/sql", readOnly: true)])
        #expect(postgres.notes.contains { $0.contains("/Users/me/sql") && $0.contains("read-only") })
        #expect(postgres.server?.image?.network == ImageMCPSpec.Network.none)
        #expect(postgres.server?.image?.args == ["postgresql://db/app"])
        #expect(postgres.server?.image?.environment == [MCPKeyValue(name: "PGPASSWORD", secret: true)])
        #expect(found["memory"]?.refusal?.contains("npx") == true)
        #expect(found["privileged"]?.refusal?.contains("--privileged") == true)
    }

    @Test func claudeCodeHTTPAndSSEBecomeRemoteAndComposeIsPointedAtStacks() throws {
        let found = try candidates("claude.json", .claudeCode)
        let sentry = try #require(found["sentry"]?.server)
        #expect(sentry.remote?.url == "https://mcp.sentry.example/mcp")
        #expect(found["sentry"]?.secrets.values.map { String(decoding: $0.utf8, as: UTF8.self) } == ["Bearer fixture-sentry-token"])
        #expect(found["plain"]?.refusal?.contains("plain http") == true, "plain http to another host is refused")
        #expect(found["compose"]?.refusal?.contains("compose-stack") == true)
        #expect(found.count == 3, "only the user-level servers")
    }

    @Test func cursorAndVSCodeServersConvertWithTheirNotes() throws {
        let cursor = try candidates("cursor-mcp.json", .cursor)
        #expect(cursor["linear"]?.server?.kind == .remote)
        let browser = try #require(cursor["browser"])
        #expect(browser.server?.image?.image == "mcr.example/playwright/mcp")
        #expect(browser.server?.image?.args == ["--headless"])
        #expect(browser.notes.contains { $0.contains("-t") } && browser.notes.contains { $0.contains("--pull") })
        let vscode = try candidates("vscode-mcp.json", .vscode)
        let gitlab = try #require(vscode["gitlab"])
        #expect(gitlab.server?.image?.environment.contains(MCPKeyValue(name: "GITLAB_TOKEN", secret: true)) == true)
        #expect(gitlab.server?.image?.environment.contains(MCPKeyValue(name: "GITLAB_URL", value: "https://gitlab.example.com")) == true)
        #expect(gitlab.secrets.isEmpty, "an ${input:…} placeholder is entered after import")
        #expect(gitlab.notes.contains { $0.contains("GITLAB_TOKEN") })
        #expect(vscode["docs"]?.server?.kind == .remote)
        #expect(vscode["broken"]?.refusal?.contains("--env-file") == true)
    }

    @Test func importReadsOnlyWhatExistsNeverWritesAndAvoidsNameClashes() throws {
        let home = root.appending(path: "home")
        let cursor = home.appending(path: ".cursor/mcp.json")
        try FileManager.default.createDirectory(at: cursor.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixtures.appending(path: "cursor-mcp.json"), to: cursor)
        let before = try FileManager.default.attributesOfItem(atPath: cursor.path)[.modificationDate] as? Date
        let found = MCPImport.readAll(home: home, existingNames: ["linear"])
        #expect(found.compactMap { $0.server?.name }.sorted() == ["browser", "linear-2"])
        #expect(try FileManager.default.attributesOfItem(atPath: cursor.path)[.modificationDate] as? Date == before)
        #expect(try Data(contentsOf: cursor) == Data(contentsOf: Self.fixtures.appending(path: "cursor-mcp.json")))
        #expect(MCPImport.parse(Data("{ nope".utf8), format: .cursor, source: "x").first?.refusal?.contains("not valid JSON") == true)
    }

    // MARK: Corporate network

    static func certificate(_ name: String, domain: TrustedCertificate.Domain, ca: Bool = true, selfSigned: Bool = true) -> TrustedCertificate {
        TrustedCertificate(der: Data("DER of \(name)".utf8), subject: name, domain: domain, isSelfSigned: selfSigned, isCertificateAuthority: ca)
    }

    @Test func enterpriseRootsAreChosenFromProfileInstalledCAsNeverPersonalCertificates() async throws {
        let corporate = Self.certificate("Acme Root CA", domain: .admin)
        let userRoot = Self.certificate("Someone's Test CA", domain: .user)
        let personal = Self.certificate("someone@acme.example", domain: .admin, ca: false, selfSigned: false)
        let (service, _) = try await makeService(certificates: [corporate, userRoot, personal, corporate])
        defer { service.stop() }
        let network = service.network
        #expect(network.candidates.map(\.subject) == ["Acme Root CA", "Someone's Test CA"], "a non-CA certificate is never offered")
        #expect(network.selected == [corporate.fingerprint], "the default: roots installed for all users only")
        #expect(network.trustEnabled && network.trustAutomatic)
        let directory = root.appending(path: "certs")
        let enterprise = try String(contentsOf: directory.appending(path: CorporateNetwork.enterpriseName), encoding: .utf8)
        let bundle = try String(contentsOf: directory.appending(path: CorporateNetwork.bundleName), encoding: .utf8)
        #expect(enterprise == corporate.pem)
        #expect(bundle.hasPrefix(TrustedCertificate(der: Data("anchor".utf8), subject: "", domain: .admin, isSelfSigned: true, isCertificateAuthority: true).pem))
        #expect(bundle.hasSuffix(corporate.pem))
        #expect(!bundle.contains(userRoot.der.base64EncodedString()) && !bundle.contains(personal.der.base64EncodedString()))
        #expect(!bundle.contains("PRIVATE KEY"))
        #expect(network.corporate.certificateDirectory == directory.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: CorporateNetwork.bundleName).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644, "readable by container users (certificates are public)")

        // Workspaces get it (and are recreated when the selection changes).
        var settings = service.environment(for: project).settings
        settings.image = "img"
        await service.update(project, settings: settings)
        #expect(service.workspaceSpec(service.environment(for: project))?.corporateNetwork?.certificateFingerprint == network.corporate.certificateFingerprint)

        // The person picks the user-trusted root too; turning trust off removes the bundles.
        await service.setNetworkSettings(NetworkSettings(selectedCertificates: [corporate.fingerprint, userRoot.fingerprint]))
        #expect(service.network.selected.count == 2)
        #expect(try String(contentsOf: directory.appending(path: CorporateNetwork.enterpriseName), encoding: .utf8).contains(userRoot.der.base64EncodedString()))
        await service.setNetworkSettings(NetworkSettings(trustEnterpriseCertificates: false))
        #expect(service.network.corporate.certificateDirectory == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: CorporateNetwork.enterpriseName).path))
        #expect(service.workspaceSpec(service.environment(for: project))?.corporateNetwork == nil)
    }

    @Test func anAdministratorsFingerprintsAndProxyWinAndNoRootsMeansOff() async throws {
        let corporate = Self.certificate("Acme Root CA", domain: .admin)
        let other = Self.certificate("Acme Old Root", domain: .admin)
        let managed = ManagedNetworkPolicy.Managed(trustEnterpriseCertificates: true, certificates: [other.fingerprint.uppercased()].map(CertificateFingerprint.normalize),
                                                   httpsProxy: "http://proxy.acme:8080", noProxy: [".acme.internal"], source: "configuration profile")
        let state = await EnvironmentService.computeNetwork(
            settings: NetworkSettings(trustEnterpriseCertificates: false, selectedCertificates: [corporate.fingerprint]), managed: managed,
            proxy: SystemProxySettings(httpProxy: "http://mac-proxy:1", source: "environment"),
            source: FakeCertificates(certificates: [corporate, other]), directory: root.appending(path: "managed-certs"))
        #expect(state.trustEnabled && state.managedTrust && state.managedCertificates)
        #expect(state.selected == [other.fingerprint])
        #expect(state.corporate.httpsProxy == "http://proxy.acme:8080" && state.corporate.httpProxy == nil)
        #expect(state.proxySource == "administrator")
        let none = await EnvironmentService.computeNetwork(settings: NetworkSettings(), managed: nil, proxy: SystemProxySettings(),
                                                           source: FakeCertificates(certificates: []), directory: root.appending(path: "none"))
        #expect(!none.trustEnabled && none.corporate.isEmpty, "a Mac with no enterprise roots changes nothing")
    }

    @Test func opencodeGetsTheEnterpriseBundleAndProxies() throws {
        let bundle = root.appending(path: "enterprise.pem")
        #expect(EnvironmentService.serverEnvironment(enterpriseBundle: bundle, proxy: SystemProxySettings(), managed: nil).isEmpty)
        try Data(Self.certificate("Acme Root CA", domain: .admin).pem.utf8).write(to: bundle)
        let environment = EnvironmentService.serverEnvironment(
            enterpriseBundle: bundle, proxy: SystemProxySettings(httpsProxy: "http://mac:1", noProxy: [".local"], source: "macOS network settings"),
            managed: nil)
        #expect(environment["NODE_EXTRA_CA_CERTS"] == bundle.path)
        #expect(environment["HTTPS_PROXY"] == "http://mac:1")
        #expect(environment["NO_PROXY"] == ".local,localhost,127.0.0.1,::1")
        let managed = EnvironmentService.serverEnvironment(
            enterpriseBundle: nil, proxy: SystemProxySettings(httpsProxy: "http://mac:1", source: "environment"),
            managed: .init(httpProxy: "http://corp:3128", source: "profile"))
        #expect(managed["HTTP_PROXY"] == "http://corp:3128" && managed["HTTPS_PROXY"] == nil, "an administrator's proxy replaces the Mac's")
    }

    @Test func gitLabRegistryHostsAreSuggestedNotGuessed() {
        #expect(EnvironmentService.gitLabRegistrySuggestions(instance: "https://gitlab.novacoast.com")
            == ["registry.gitlab.novacoast.com", "gitlab.novacoast.com:5050"])
    }

    @Test func signingInWithTheGitLabTokenStoresAReferenceNotTheToken() async throws {
        var (service, _) = try await makeService()
        service.stop()
        let tokens = InMemorySecretVault()
        try tokens.store(account: "https://gitlab.example.com", label: "t", value: SecretValue("glpat-fixture"))
        let registry = InMemorySecretVault()
        var configuration = try #require(service.configuration)
        configuration.gitLabTokens = tokens
        configuration.registryVault = registry
        service = EnvironmentService(configuration: configuration, store: try ProjectionStore(location: .inMemory))
        try service.signInWithGitLabToken(registry: "registry.gitlab.example.com", instance: "https://gitlab.example.com", username: "someone")
        let stored = try #require(try registry.read(account: "registry.gitlab.example.com"))
        #expect(!String(decoding: stored.utf8, as: UTF8.self).contains("glpat-fixture"), "the token stays in its own Keychain item")
        let auth = try #require(service.registryAuth(for: "registry.gitlab.example.com/team/image:1"))
        #expect(auth.username == "someone" && auth.password == "glpat-fixture")
        #expect(service.registryGitLabInstance("registry.gitlab.example.com") == "https://gitlab.example.com")
        #expect(throws: EnvironmentBlockedError.self) {
            try service.signInWithGitLabToken(registry: "r", instance: "https://other.example.com", username: "x")
        }
    }
}

/// Every file the service wrote (path → bytes).
final class Written: Sendable {
    let files = Mutex<[URL: Data]>([:])
}

/// Trusted certificates from fixtures (never the Mac's Keychain) and one built-in anchor.
struct FakeCertificates: TrustedCertificateSource {
    let certificates: [TrustedCertificate]
    func trustedCertificates() -> [TrustedCertificate] { certificates }
    func systemAnchors() -> [Data] { [Data("anchor".utf8)] }
}
