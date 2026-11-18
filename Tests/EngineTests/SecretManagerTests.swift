import BelloCore
import Foundation
import GRDB
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
        #expect(try f.vault.read(account: brokered.account)?.utf8 == Self.value.utf8)
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
        #expect(try f.vault.read(account: secret.account)?.utf8 == Data("sk_test_rotated_value_42".utf8))
        try await f.manager.revoke(account: secret.account)
        #expect(f.manager.placeholder(account: secret.account, sessionID: SessionID("ses_1")) == nil)
        #expect(f.manager.secret(secret.account)?.revoked == true)
        let audit = await f.manager.audit(account: secret.account)
        #expect(Set(audit.map(\.outcome)).isSuperset(of: [.created, .rotated, .revoked]))
        await f.manager.delete(account: secret.account)
        #expect(f.manager.secret(secret.account) == nil)
        #expect(try f.vault.read(account: secret.account) == nil)
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
