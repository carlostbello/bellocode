import BelloCore
import ContainerKit
import Foundation
import GRDB
import Security
import SecretKit
import Testing

@testable import Engine

/// The secret manager's store and rules (docs/features/secrets.md): migration `v11-secret-manager`, modes, scopes,
/// confirmation of visible values, rotation keeping placeholders, revocation, the audit bound, legacy adoption.
@MainActor
@Suite("Secret manager", .serialized, .timeLimit(.minutes(2)))
struct SecretManagerTests {
    static let value = SecretValue("sk_test_0123456789abcdef")

    struct Fixture {
        let store: ProjectionStore
        let vault: InMemorySecretVault
        let legacy: SecretService
        let manager: SecretManager
    }

    func fixture() async throws -> Fixture {
        let store = try ProjectionStore(location: .inMemory)
        let vault = InMemorySecretVault()
        let root = FileManager.default.temporaryDirectory.appending(path: "bc-secret-tests-\(UUID().uuidString.prefix(8))")
        let legacy = SecretService(vault: vault, store: store, clock: SystemWallClock(), root: root)
        await legacy.load()
        let manager = SecretManager(store: store, vault: vault, legacy: legacy, clock: SystemWallClock(), configuration: nil)
        await manager.reload()
        return Fixture(store: store, vault: vault, legacy: legacy, manager: manager)
    }

    static let binding = SecretBinding(host: "api.example.com", pathPrefixes: ["/v1"], locations: [.header("Authorization", prefix: "Bearer ")])

    /// R05: quit and reopen. The second launch restores the CA from the Keychain key and the certificate on disk; a leaf
    /// it issues must pass Security framework chain validation against the root the containers trusted on first run.
    @Test func authoritySurvivesARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bc-egress-ca-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = SecretManagerConfiguration(directory: directory, authorityVault: InMemorySecretVault())
        let first = try await fixture().manager.loadAuthority(configuration)
        let relaunched = try await fixture().manager.loadAuthority(configuration)
        #expect(relaunched.fingerprint == first.fingerprint, "restored, not recreated")
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(try relaunched.identity(for: "registry.npmjs.org"), &certificate)
        var trust: SecTrust?
        SecTrustCreateWithCertificates([try #require(certificate)] as CFArray, SecPolicyCreateSSL(true, "registry.npmjs.org" as CFString), &trust)
        let evaluation = try #require(trust)
        SecTrustSetAnchorCertificates(evaluation, [SecCertificateCreateWithData(nil, first.certificateDER as CFData)!] as CFArray)
        SecTrustSetAnchorCertificatesOnly(evaluation, true)
        var error: CFError?
        #expect(SecTrustEvaluateWithError(evaluation, &error), "\(String(describing: error))")
    }

    @Test func migrationCreatesTablesAndRoundTrips() async throws {
        let f = try await fixture()
        let tables = try await f.store.writer.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
        #expect(Set(tables).isSuperset(of: ["app_managed_secret", "app_secret_placeholder", "app_secret_audit"]))
        let secret = ManagedSecret(account: "bcs_x", name: "X", label: "X", mode: .placeholder, bindings: [Self.binding], created: Date(timeIntervalSince1970: 1_000))
        try await f.store.saveManagedSecret(secret)
        #expect(try await f.store.managedSecrets() == [secret])
        let grant = PlaceholderGrant(placeholder: Placeholder.make(), account: "bcs_x", sessionID: "ses_1", projectDirectory: "/p")
        try await f.store.savePlaceholderGrant(grant)
        #expect(try await f.store.placeholderGrants().map(\.placeholder) == [grant.placeholder])
        // The audit is bounded per secret.
        let entries = (0..<(ProjectionStore.auditLimitPerSecret + 25)).map {
            SecretAuditEntry(account: "bcs_x", at: Date(timeIntervalSince1970: Double($0)), destination: "https://api.example.com/v1", outcome: .substituted)
        }
        try await f.store.appendAudit(entries)
        let kept = try await f.store.auditEntries(account: "bcs_x", limit: 10_000)
        #expect(kept.count == ProjectionStore.auditLimitPerSecret)
        #expect(kept.first?.at == Date(timeIntervalSince1970: Double(ProjectionStore.auditLimitPerSecret + 24)))
        try await f.store.deleteManagedSecret(account: "bcs_x")
        #expect(try await f.store.managedSecrets().isEmpty)
        #expect(try await f.store.placeholderGrants().isEmpty)
        #expect(try await f.store.auditEntries(account: "bcs_x").isEmpty)
    }

    @Test func modesNeedTheirConditions() async throws {
        let f = try await fixture()
        await #expect(throws: (any Error).self) { try await f.manager.create(label: "P", value: Self.value, mode: .placeholder) }
        await #expect(throws: (any Error).self) { try await f.manager.create(label: "V", value: Self.value, mode: .visible) }
        await #expect(throws: (any Error).self) {
            try await f.manager.create(label: "Short", value: SecretValue("1234"), mode: .brokered, bindings: [Self.binding])
        }
        await #expect(throws: (any Error).self) {
            try await f.manager.create(label: "Wild", value: Self.value, mode: .placeholder,
                                       bindings: [SecretBinding(host: "*.example.com", locations: [.header("X")])])
        }
        let visible = try await f.manager.create(label: "V", value: Self.value, mode: .visible, confirmVisible: true)
        #expect(visible.visibleConfirmed)
        let brokered = try await f.manager.create(label: "OpenAI key", value: Self.value, mode: .brokered, bindings: [Self.binding])
        #expect(brokered.name == "OPENAI_KEY" && brokered.operation == "http")
        // The store never holds the value.
        let raw = try await f.store.writer.read { db in try Data.fetchAll(db, sql: "SELECT json FROM app_managed_secret") }
        #expect(!raw.contains { ByteSearch.contains($0, Self.value.utf8) })
        #expect(try f.vault.read(account: brokered.activeValueAccount)?.utf8 == Self.value.utf8)
    }

    @Test func rotateKeepsPlaceholdersAndRevokeDropsThem() async throws {
        let f = try await fixture()
        let secret = try await f.manager.create(label: "Key", value: Self.value, mode: .placeholder, scope: .project("/p"), bindings: [Self.binding])
        let grant = try await f.manager.grant(account: secret.account, sessionID: SessionID("ses_1"), projectDirectory: "/p")
        #expect(Placeholder.isPlaceholder(grant.placeholder))
        let again = try await f.manager.grant(account: secret.account, sessionID: SessionID("ses_1"), projectDirectory: "/p")
        #expect(again.placeholder == grant.placeholder, "one thread, one placeholder")
        await #expect(throws: (any Error).self) {
            try await f.manager.grant(account: secret.account, sessionID: SessionID("ses_2"), projectDirectory: "/other")
        }
        try await f.manager.rotate(account: secret.account, value: SecretValue("sk_test_rotated_value_42"))
        #expect(f.manager.placeholder(account: secret.account, sessionID: SessionID("ses_1")) == grant.placeholder)
        let rotated = try #require(f.manager.secret(secret.account))
        #expect(try f.vault.read(account: rotated.activeValueAccount)?.utf8 == Data("sk_test_rotated_value_42".utf8))
        #expect(f.vault.count == 1, "the previous value is removed once the new one is active")
        try await f.manager.revoke(account: secret.account)
        #expect(f.manager.placeholder(account: secret.account, sessionID: SessionID("ses_1")) == nil)
        #expect(f.manager.secret(secret.account)?.revoked == true)
        let audit = await f.manager.audit(account: secret.account)
        #expect(Set(audit.map(\.outcome)).isSuperset(of: [.created, .rotated, .revoked]))
        await f.manager.delete(account: secret.account)
        #expect(f.manager.secret(secret.account) == nil)
        #expect(try f.vault.read(account: secret.account) == nil)
        #expect(f.vault.count == 0, "every value of the secret is gone")
    }

    @Test func legacySecretsAreAdoptedForApprovedCommandsOnly() async throws {
        let f = try await fixture()
        _ = try await f.legacy.save(label: "npm token", value: Self.value)
        await f.manager.reload()
        let adopted = try #require(f.manager.secrets.first { $0.label == "npm token" })
        #expect(adopted.mode == .visible && !adopted.visibleConfirmed && adopted.name == "NPM_TOKEN")
        // Not handed out by "Use Saved Value" as a visible value: the command path applies.
        #expect(try await f.manager.useSaved(label: "npm token", sessionID: SessionID("ses_1"), projectDirectory: "/p") == nil)
    }

    /// R09: a metadata row that cannot be decoded must not let the surviving legacy label re-adopt the secret as a
    /// commands-only secret (losing revocation, scope and bindings); the row is kept and the problem shown.
    @Test func unreadableMetadataQuarantinesInsteadOfReadopting() async throws {
        let f = try await fixture()
        let secret = try await f.manager.create(label: "Deploy key", value: Self.value, mode: .placeholder, scope: .project("/p"), bindings: [Self.binding])
        try await f.manager.revoke(account: secret.account)
        try await f.store.writer.write { db in
            try db.execute(sql: "UPDATE app_managed_secret SET json = ? WHERE account = ?", arguments: [Data("{not json".utf8), secret.account])
        }
        // Relaunch.
        let relaunched = SecretManager(store: f.store, vault: f.vault, legacy: f.legacy, clock: SystemWallClock(), configuration: nil)
        await relaunched.reload()
        #expect(relaunched.secret(secret.account) == nil, "never reclassified (as a legacy commands-only secret or otherwise)")
        #expect(relaunched.quarantinedAccounts == [secret.account])
        #expect(relaunched.metadataProblem?.contains("Deploy key") == true, "\(relaunched.metadataProblem ?? "no problem shown")")
        #expect(relaunched.commandRevision(account: secret.account, projectDirectory: "/p") == nil, "not eligible for approved commands")
        #expect(try await relaunched.useSaved(label: "Deploy key", sessionID: SessionID("ses_1"), projectDirectory: "/p") == nil)
        let raw = try await f.store.writer.read { db in try Data.fetchOne(db, sql: "SELECT json FROM app_managed_secret WHERE account = ?", arguments: [secret.account]) }
        #expect(raw == Data("{not json".utf8), "the original row is kept, not replaced")
        await #expect(throws: (any Error).self) { try await relaunched.create(label: "Deploy key", value: Self.value, mode: .visible, confirmVisible: true) }
        // Delete clears it.
        await relaunched.delete(account: secret.account)
        #expect(relaunched.quarantinedAccounts.isEmpty && relaunched.metadataProblem == nil)
    }

    /// R09: a failed metadata query is not "no metadata": nothing is adopted and no secret is usable.
    @Test func failedMetadataQueryFailsClosed() async throws {
        let f = try await fixture()
        let secret = try await f.manager.create(label: "Ops token", value: Self.value, mode: .brokered, bindings: [Self.binding])
        try await f.manager.revoke(account: secret.account)
        try await f.store.writer.write { db in try db.execute(sql: "ALTER TABLE app_managed_secret RENAME TO app_managed_secret_hidden") }
        let relaunched = SecretManager(store: f.store, vault: f.vault, legacy: f.legacy, clock: SystemWallClock(), configuration: nil)
        await relaunched.reload()
        #expect(relaunched.secrets.isEmpty, "the legacy label was not adopted as a commands-only secret")
        #expect(relaunched.commandRevision(account: secret.account, projectDirectory: nil) == nil)
        #expect(relaunched.metadataProblem != nil, "the failure is shown")
        try await f.store.writer.write { db in try db.execute(sql: "ALTER TABLE app_managed_secret_hidden RENAME TO app_managed_secret") }
        await relaunched.reload()
        #expect(relaunched.secret(secret.account)?.revoked == true && relaunched.secret(secret.account)?.mode == .brokered, "policy intact")
        #expect(relaunched.metadataProblem == nil)
    }

    /// R13: narrowing a secret's scope revokes grants of threads in projects it no longer admits (placeholder and
    /// visible), and the visible-environment builder checks the current scope at every delivery.
    @Test func narrowingScopeRevokesOutOfScopeGrants() async throws {
        let f = try await fixture()
        let visible = try await f.manager.create(label: "Visible key", value: Self.value, mode: .visible, confirmVisible: true)
        let hidden = try await f.manager.create(label: "Hidden key", value: SecretValue("sk_test_hidden_0123456789"), mode: .placeholder, bindings: [Self.binding])
        for secret in [visible, hidden] {
            try await f.manager.grant(account: secret.account, sessionID: SessionID("ses_a"), projectDirectory: "/a")
            try await f.manager.grant(account: secret.account, sessionID: SessionID("ses_b"), projectDirectory: "/b")
        }
        #expect(await f.manager.secretVariables(for: "ses_b")["VISIBLE_KEY"] != nil)
        for secret in [visible, hidden] {
            var narrowed = try #require(f.manager.secret(secret.account))
            narrowed.scope = .project("/a")
            try await f.manager.update(narrowed)
        }
        let b = await f.manager.secretVariables(for: "ses_b")
        #expect(b["VISIBLE_KEY"] == nil && b["HIDDEN_KEY"] == nil, "the excluded project keeps nothing")
        #expect(f.manager.placeholder(account: hidden.account, sessionID: SessionID("ses_b")) == nil)
        let a = await f.manager.secretVariables(for: "ses_a")
        #expect(a["VISIBLE_KEY"] != nil && a["HIDDEN_KEY"] != nil, "the project still in scope keeps its grants")
        #expect(try await f.store.placeholderGrants().allSatisfy { $0.sessionID == "ses_a" }, "dropped durably")
        // A rotated visible value never reaches the excluded thread.
        try await f.manager.rotate(account: visible.account, value: SecretValue("sk_test_rotated_after_narrowing"))
        #expect(await f.manager.secretVariables(for: "ses_b").isEmpty)
    }

    @Test func environmentBuilderChecksTheCurrentScope() async throws {
        let f = try await fixture()
        f.manager.codeRoots = { ["/repos"] }
        let secret = try await f.manager.create(label: "Roots key", value: Self.value, mode: .visible, scope: .codeRoots, confirmVisible: true)
        try await f.manager.grant(account: secret.account, sessionID: SessionID("ses_r"), projectDirectory: "/repos/app")
        #expect(await f.manager.secretVariables(for: "ses_r")["ROOTS_KEY"] != nil)
        // The code root is removed: the grant no longer admits delivery.
        f.manager.codeRoots = { [] }
        #expect(await f.manager.secretVariables(for: "ses_r")["ROOTS_KEY"] == nil)
    }

    /// R08: whatever image a workspace runs (in a project container or the shared workspace), its gateway is
    /// BelloCode's own image, so the scope token and the outbound bridge never reach project-controlled code.
    @Test func workspaceGatewayUsesBelloCodesImage() {
        let project = WorkspaceSpec(projectRoot: "/repos/app", image: "registry.example/app-dev:latest")
        let shared = WorkspaceSpec.shared(roots: ["/repos"], image: "ghcr.io/someone/workspace:1")
        for var spec in [project, shared] {
            spec.egress = EgressAttachment(network: EgressGateway.networkName(spec.projectKey), caFingerprint: "f")
            let gateway = SecretManager.gatewaySpec(for: spec, proxyPort: 40_000, token: "t")
            #expect(gateway.image == nil && gateway.resolvedImage == EgressGatewayImage.tag, "\(spec.image)")
            #expect(gateway.scopeKey == spec.egress?.scopeKey)
        }
    }

    @Test func agentListingNeverShowsValues() async throws {
        let f = try await fixture()
        _ = try await f.manager.create(label: "Key", value: Self.value, mode: .brokered, bindings: [Self.binding])
        let caller = ExtrasCaller(sessionID: SessionID("ses_1"), projectID: ProjectID("p"), directory: "/p", projectDirectory: "/p")
        let listing = f.manager.listSecrets(caller: caller).text
        #expect(listing.contains("{{secret:KEY}}"))
        #expect(!listing.contains(String(decoding: Self.value.utf8, as: UTF8.self)))
    }

    @Test func cardChoiceBecomesABinding() throws {
        let binding = try SecretManager.binding(from: SecretChoice(mode: .placeholder, destination: "https://api.openai.com/", headerName: "Authorization",
                                                                   headerPrefix: "Bearer ", pathPrefix: "v1", methods: "get, post"))
        #expect(binding.host == "api.openai.com" && binding.port == 443 && binding.pathPrefixes == ["/v1"] && binding.methods == ["GET", "POST"])
        #expect(binding.locations == [.header("Authorization", prefix: "Bearer ")])
        let basic = try SecretManager.binding(from: SecretChoice(mode: .brokered, destination: "jira.example.com:8443", headerName: "Authorization", headerPrefix: "Basic"))
        #expect(basic.port == 8443 && basic.locations == [.basicAuthPassword])
    }
}
