import BelloCore
import ContainerKit
import Foundation
import SecretKit
import Testing

@testable import Engine

/// v1.0.0 review N13: secrets follow code-root removal at once; a stale Settings copy never overwrites use counts,
/// rotation or revocation; grant deletions that fail are visible and never resurrect a grant; the shared workspace's
/// scope carries the raw allowlists of the projects it serves.
@MainActor
@Suite("Secret scope changes", .serialized, .timeLimit(.minutes(3)))
struct SecretScopeChangeTests {
    static let binding = SecretBinding(host: "api.example.com", pathPrefixes: ["/v1"], locations: [.header("Authorization", prefix: "Bearer ")], maxUses: 5)

    @Test func removingACodeRootRevokesGrantsForProjectsUnderIt() async throws {
        let fixture = try await SecretCommandApprovalTests.Fixture.start()
        defer { Task { await fixture.stop() } }
        let base = fixture.root.appending(path: "roots").path
        let rootA = base + "/a", rootB = base + "/b"
        for path in [rootA, rootB + "/proj"] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        let canonicalB = CodeRootPaths.standardize(rootB)
        await fixture.engine.environments.setCodeRoots([rootA, rootB])
        let manager = try #require(fixture.engine.secretManager)
        try await waitUntil("roots") { manager.codeRoots().count == 2 }
        let secret = try await manager.create(label: "Roots key", value: SecretValue("sk_roots_0123456789"), mode: .placeholder, scope: .codeRoots,
                                              bindings: [Self.binding])
        let project = (manager.codeRoots().first { $0.hasSuffix("/b") } ?? canonicalB) + "/proj"
        _ = try await manager.grant(account: secret.account, sessionID: SessionID("ses_b"), projectDirectory: project)
        #expect(manager.placeholder(account: secret.account, sessionID: SessionID("ses_b")) != nil)

        await fixture.engine.environments.setCodeRoots([rootA])
        try await waitUntil("grant dropped", timeout: .seconds(5)) { manager.placeholder(account: secret.account, sessionID: SessionID("ses_b")) == nil }
        #expect(try await fixture.engine.store.placeholderGrants().isEmpty, "the grant's row is gone too")
    }

    @Test func aStaleSettingsCopyKeepsUsesRotationAndRevocation() async throws {
        let f = try await SecretValuePolicyBindingTests.Light.make()
        let created = try await f.manager.create(label: "Stale key", value: SecretValue("sk_stale_0123456789"), mode: .placeholder, bindings: [Self.binding])
        let stale = try #require(f.manager.secret(created.account))  // what Settings rendered
        // Meanwhile: a use is counted, the value rotated, the secret revoked.
        let use = SubstitutionUse(account: created.account, bindingID: Self.binding.id, sessionID: "ses", placeholder: "")
        #expect(f.manager.useLedger.reserve([use]) { _ in 5 })
        #expect(await f.manager.recordUses([use]))
        try await f.manager.rotate(account: created.account, value: SecretValue("sk_stale_rotated_98765"))
        try await f.manager.revoke(account: created.account)
        let before = try #require(f.manager.secret(created.account))

        var edited = stale
        edited.bindings.append(SecretBinding(host: "other.example.com", locations: [.header("X-Key", prefix: "")]))
        try await f.manager.update(edited)
        for manager in [f.manager, try await SecretValuePolicyBindingTests.Light.make(store: f.store, vault: f.vault).manager] {
            let after = try #require(manager.secret(created.account))
            #expect(after.bindings.count == 2, "the edit applied")
            #expect(after.uses[Self.binding.id] == 1, "use count kept")
            #expect(abs((after.rotated?.timeIntervalSince1970 ?? 0) - (before.rotated?.timeIntervalSince1970 ?? 1)) < 0.001, "rotation kept")
            #expect(after.valueAccount == before.valueAccount, "the current value kept")
            #expect(after.revoked, "revocation kept")
        }
    }

    @Test func aGrantWhoseDeletionFailedIsNotBroughtBack() async throws {
        let f = try await SecretValuePolicyBindingTests.Light.make()
        let secret = try await f.manager.create(label: "Grant key", value: SecretValue("sk_grant_0123456789"), mode: .placeholder, bindings: [Self.binding])
        _ = try await f.manager.grant(account: secret.account, sessionID: SessionID("ses_g"), projectDirectory: "/p")
        try await f.manager.revoke(account: secret.account)
        // The revocation's grant deletion failed earlier, so the row is still there; then BelloCode relaunches.
        try await f.store.savePlaceholderGrant(PlaceholderGrant(placeholder: Placeholder.make(), account: secret.account, sessionID: "ses_g", projectDirectory: "/p"))
        let relaunched = try await SecretValuePolicyBindingTests.Light.make(store: f.store, vault: f.vault)
        #expect(relaunched.manager.placeholder(account: secret.account, sessionID: SessionID("ses_g")) == nil, "a revoked secret's grant came back")
        #expect(try await f.store.placeholderGrants().isEmpty, "the stale row is removed at launch")
    }

    @Test func aFailedGrantDeletionIsShown() async throws {
        let f = try await SecretValuePolicyBindingTests.Light.make()
        let secret = try await f.manager.create(label: "Shown key", value: SecretValue("sk_shown_0123456789"), mode: .placeholder, bindings: [Self.binding])
        _ = try await f.manager.grant(account: secret.account, sessionID: SessionID("ses_s"), projectDirectory: "/p")
        var visible = try #require(f.manager.secret(secret.account))
        visible.mode = .visible
        let counter = SecretWriteGate(at: 2)  // the second secret write: the grant deletion after the policy write
        await f.store.setWriteHook { batch in
            guard batch.isEmpty else { return }
            if counter.entered { return }
            try await counter.hook(batch)
        }
        let change = Task { @MainActor in try await f.manager.update(visible, confirmVisible: true) }
        try await waitUntil("held at the grant deletion") { counter.entered }
        counter.release(proceed: false)
        try await change.value
        await f.store.setWriteHook(nil)
        #expect(f.manager.placeholder(account: secret.account, sessionID: SessionID("ses_s")) == nil, "no use now")
        #expect(f.manager.lastError?.contains("could not update its database") == true, "\(f.manager.lastError ?? "nil")")
    }

    @Test func theSharedWorkspaceScopeCarriesItsProjectsRawAllowlists() async throws {
        let f = try await SecretValuePolicyBindingTests.Light.make()
        let project = "/tmp/bc-raw-\(UUID().uuidString.prefix(6))/repo"
        defer { UserDefaults.standard.removeObject(forKey: "secrets.rawEgress.\(project)") }
        let root = (project as NSString).deletingLastPathComponent
        f.manager.rebuildScope("shared-key", token: "tok", roots: [root])
        f.manager.setRawEgressAllowlist(["db.internal.example:5432"], projectDirectory: project)
        #expect(f.manager.scopes["shared-key"]?.rawAllowlist == [HostPort(host: "db.internal.example", port: 5432)])
        f.manager.setRawEgressAllowlist([], projectDirectory: project)
        #expect(f.manager.scopes["shared-key"]?.rawAllowlist.isEmpty == true)
    }
}
