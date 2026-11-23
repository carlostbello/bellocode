import BelloCore
import Foundation
import SecretKit
import Testing

@testable import Engine

/// v1.0.1 final checks (docs/reviews/v1.0.1-astra-final-check.md): use accounting never undoes a revocation (AF03); a
/// thread's placeholder grant never delivers a replacement value in clear text (AF04); a short value never enters a
/// hidden mode, even racing a rotation (AF16); a failed environment cleanup is retried after a reconnect (AF26).
@MainActor
@Suite("Secret policy races", .serialized, .timeLimit(.minutes(3)))
struct SecretPolicyRaceTests {
    typealias Light = SecretValuePolicyBindingTests.Light
    static let binding = SecretBinding(host: "api.example.com", pathPrefixes: ["/v1"], locations: [.header("Authorization", prefix: "Bearer ")], maxUses: 5)

    /// AF03: a use count captured before a revocation and written after it must not bring the active row back.
    @Test func aUseCountWrittenAroundARevocationNeverUndoesIt() async throws {
        let f = try await Light.make()
        let secret = try await f.manager.create(label: "Race key", value: SecretValue("sk_race_0123456789"), mode: .placeholder, bindings: [Self.binding])
        let use = SubstitutionUse(account: secret.account, bindingID: Self.binding.id, sessionID: "ses", placeholder: "")
        #expect(f.manager.useLedger.reserve([use]) { _ in 5 })
        // The count's row write is held (slow storage) after it read the secret as active.
        let gate = SecretWriteGate(at: 1)
        await f.store.setWriteHook { try await gate.hook($0) }
        let counted = Task { @MainActor in await f.manager.recordUses([use]) }
        try await waitUntil("count held") { gate.entered }
        let revocation = Task { @MainActor in try await f.manager.revoke(account: secret.account) }
        let revoked = OnceFlag()
        Task { @MainActor in _ = try? await revocation.value; _ = revoked.set() }
        // The revocation either finishes meanwhile (unfenced) or waits for the count's write (fenced).
        try await waitUntil("revocation done or waiting") { revoked.isSet || f.manager.waitingRowWriters(secret.account) == 1 }
        gate.release(proceed: true)
        #expect(await counted.value)
        try await revocation.value
        await f.store.setWriteHook(nil)

        #expect(f.manager.secret(secret.account)?.revoked == true)
        let relaunched = try await Light.make(store: f.store, vault: f.vault)
        let durable = try #require(relaunched.manager.secret(secret.account))
        #expect(durable.revoked, "the relaunch must not accept the secret again")
        #expect(durable.uses[Self.binding.id] == 1, "the use is counted too")
    }

    /// AF04: thread A holds only a placeholder; the owner saves a replacement under the same label from thread B and
    /// confirms Visible. A's environment (rebuilt at a reconnect) never gets the new value.
    @Test func aPlaceholderGrantNeverDeliversAReplacementInClearText() async throws {
        let f = try await Light.make()
        let created = try await f.manager.create(label: "Swap key", value: SecretValue("sk_swap_placeholder_0123"), mode: .placeholder, bindings: [Self.binding])
        let a = try await f.manager.grant(account: created.account, sessionID: SessionID("ses_a"), projectDirectory: "/p")
        #expect(Placeholder.isPlaceholder(a.placeholder))
        #expect(await f.manager.secretVariables(for: "ses_a")["SWAP_KEY"] == a.placeholder)

        let replaced = try await f.manager.create(label: "Swap key", value: SecretValue("sk_swap_visible_98765"), mode: .visible, confirmVisible: true)
        #expect(replaced.account == created.account)
        let b = try await f.manager.grant(account: created.account, sessionID: SessionID("ses_b"), projectDirectory: "/p")
        #expect(b.placeholder.hasPrefix("visible_"))
        #expect(await f.manager.secretVariables(for: "ses_b")["SWAP_KEY"] == "sk_swap_visible_98765", "B was allowed to see it")

        #expect(await f.manager.secretVariables(for: "ses_a")["SWAP_KEY"] == nil, "A never received a visible grant")
        #expect(f.manager.placeholder(account: created.account, sessionID: SessionID("ses_a")) == nil, "A's placeholder grant is retired")
        #expect(try await f.store.placeholderGrants().allSatisfy { $0.sessionID == "ses_b" }, "retired durably")
        // A asks again: it gets a grant of the current kind, never its old placeholder.
        let again = try await f.manager.grant(account: created.account, sessionID: SessionID("ses_a"), projectDirectory: "/p")
        #expect(again.placeholder.hasPrefix("visible_"))
    }

    /// AF16: Settings cannot put a value shorter than the scanner's minimum into Brokered or Placeholder.
    @Test func settingsCannotMoveAShortValueIntoAHiddenMode() async throws {
        let f = try await Light.make()
        let short = try await f.manager.create(label: "Pin", value: SecretValue("1234"), mode: .visible, confirmVisible: true)
        for mode in [SecretUseMode.brokered, .placeholder] {
            var next = try #require(f.manager.secret(short.account))
            next.mode = mode
            next.bindings = [Self.binding]
            do {
                try await f.manager.update(next)
                Issue.record("\(mode): a 4-byte value became hidden")
            } catch {
                #expect(ExtrasError.message(error).contains("shorter than 8 bytes"), "\(error)")
            }
            #expect(f.manager.secret(short.account)?.mode == .visible, "the previous mode is kept")
        }
        let relaunched = try await Light.make(store: f.store, vault: f.vault)
        #expect(relaunched.manager.secret(short.account)?.mode == .visible)
        // A long enough value can be protected.
        let long = try await f.manager.create(label: "Long", value: SecretValue("sk_long_0123456789"), mode: .visible, confirmVisible: true)
        var protected = try #require(f.manager.secret(long.account))
        protected.mode = .brokered
        protected.bindings = [Self.binding]
        try await f.manager.update(protected)
        #expect(f.manager.secret(long.account)?.mode == .brokered)
    }

    /// AF16: a short rotation validated while the secret was Visible, activating after a mode change to Brokered, never
    /// leaves a short value in a hidden mode.
    @Test func aShortRotationRacingAModeChangeNeverEndsHidden() async throws {
        let f = try await Light.make()
        let secret = try await f.manager.create(label: "Racy", value: SecretValue("sk_racy_0123456789"), mode: .visible, confirmVisible: true)
        // Rotation writes: 1 pending value, 2 activation (held), 3 retired-value cleanup.
        let gate = SecretWriteGate(at: 2)
        await f.store.setWriteHook { try await gate.hook($0) }
        let rotation = Task { @MainActor in try await f.manager.rotate(account: secret.account, value: SecretValue("1234")) }
        try await waitUntil("activation held") { gate.entered }
        var next = try #require(f.manager.secret(secret.account))
        next.mode = .brokered
        next.bindings = [Self.binding]
        let change = Task { @MainActor in try await f.manager.update(next) }
        let changed = OnceFlag()
        Task { @MainActor in _ = try? await change.value; _ = changed.set() }
        try await waitUntil("mode change done or waiting") { changed.isSet || f.manager.waitingRowWriters(secret.account) == 1 }
        gate.release(proceed: true)
        _ = try? await rotation.value
        _ = try? await change.value
        await f.store.setWriteHook(nil)

        func hiddenShort(_ manager: SecretManager) throws -> Bool {
            let now = try #require(manager.secret(secret.account))
            let value = try #require(try f.vault.read(account: now.activeValueAccount))
            return now.mode != .visible && value.utf8.count < 8
        }
        #expect(try !hiddenShort(f.manager), "this launch: a short value is hidden")
        #expect(try !hiddenShort(try await Light.make(store: f.store, vault: f.vault).manager), "after relaunch: a short value is hidden")
    }

    /// AF26: revoking a thread's only visible secret while its environment request cannot reach the (still running)
    /// server: shown as pending, and replaced once the client reconnects.
    @Test func aFailedEnvironmentCleanupIsRetriedAfterAReconnect() async throws {
        let fixture = try await SecretCommandApprovalTests.Fixture.start()
        defer { Task { await fixture.stop() } }
        let manager = try #require(fixture.engine.secretManager)
        let session = try await fixture.engine.createThread(in: SecretCommandApprovalTests.project, title: "env")
        let value = "zz-ENV-visible-\(UUID().uuidString.prefix(8))"
        let secret = try await manager.create(label: "Env key", value: SecretValue(value), mode: .visible, confirmVisible: true)
        try await manager.grant(account: secret.account, sessionID: session.id, projectDirectory: SecretCommandApprovalTests.project)
        #expect(await fixture.harness.server.environmentText.contains(value), "delivered")

        await fixture.harness.server.injectHTTPFault(.status(503, method: "PUT", pathPrefix: "/api/session/\(session.id.rawValue)/environment"))
        try await manager.revoke(account: secret.account)
        #expect(await fixture.harness.server.environmentText.contains(value), "the cleanup did not reach the server")
        #expect(manager.pendingEnvironmentSessions.contains(session.id.rawValue), "shown as pending, not done")

        // A transient disconnect: the same server process, a new connection.
        await fixture.harness.server.dropEventStreams()
        try await waitUntil("cleanup retried", timeout: .seconds(20)) { manager.pendingEnvironmentSessions.isEmpty }
        #expect(!(await fixture.harness.server.environmentText.contains(value)), "new commands no longer receive the old value")
    }
}
