import BelloCore
import ContainerKit
import Foundation
import MockOpenCode
import OpenCodeKit
import SecretKit
import Synchronization
import Testing

@testable import Engine

/// Holds the N-th secret-store write (an empty batch: the secret tables, labels and grants) until opened, or forever
/// (a crash at that point). Engine projection writes are non-empty batches and pass.
final class SecretWriteGate: Sendable {
    private struct State {
        var count = 0
        var entered = false
        var waiter: CheckedContinuation<Void, any Error>?
        var released: Bool? = nil  // nil: still held; true: proceed; false: fail
    }

    let target: Int
    private let state = Mutex(State())
    init(at target: Int) { self.target = target }

    var entered: Bool { state.withLock { $0.entered } }

    func hook(_ batch: StoreBatch) async throws {
        guard batch.isEmpty else { return }
        let hold = state.withLock { state -> Bool in
            state.count += 1
            if state.count == target { state.entered = true }
            return state.count == target
        }
        guard hold else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let decided = state.withLock { state -> Bool? in
                if state.released == nil { state.waiter = continuation }
                return state.released
            }
            switch decided {
            case nil: break
            case true?: continuation.resume()
            case false?: continuation.resume(throwing: CancellationError())
            }
        }
    }

    func release(proceed: Bool) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            state.released = proceed
            defer { state.waiter = nil }
            return state.waiter
        }
        if proceed { waiter?.resume() } else { waiter?.resume(throwing: CancellationError()) }
    }
}

struct InjectedStoreFailure: Error {}

/// v1.0.0 review A02: a new Keychain value is never usable under the policy that protected the previous one. While a
/// save is in flight, after a metadata write fails and after a crash at any store boundary, every path that can read
/// the value (approved commands, references) gets the old value under the old policy or nothing.
@MainActor
@Suite("Secret value bound to its policy", .serialized, .timeLimit(.minutes(3)))
struct SecretValuePolicyBindingTests {
    static let binding = SecretBinding(host: "api.example.com", pathPrefixes: ["/v1"], locations: [.header("Authorization", prefix: "Bearer ")])

    @MainActor struct Light {
        let store: ProjectionStore
        let vault: InMemorySecretVault
        let legacy: SecretService
        let manager: SecretManager

        static func make(store: ProjectionStore? = nil, vault: InMemorySecretVault? = nil) async throws -> Light {
            let store = try store ?? ProjectionStore(location: .inMemory)
            let vault = vault ?? InMemorySecretVault()
            let legacy = SecretService(vault: vault, store: store, clock: SystemWallClock(), root: temporaryRoot())
            await legacy.load()
            let manager = SecretManager(store: store, vault: vault, legacy: legacy, clock: SystemWallClock(), configuration: nil)
            await manager.reload()
            return Light(store: store, vault: vault, legacy: legacy, manager: manager)
        }

        /// What an approved command would receive for `account` under the revision it was approved at.
        func commandValue(_ account: String, revision: String) throws -> String? {
            guard let valueAccount = manager.commandValueAccount(account: account, revision: revision, projectDirectory: nil) else { return nil }
            return try vault.read(account: valueAccount).map { String(decoding: $0.utf8, as: UTF8.self) }
        }
    }

    /// Crash (the save never resumes) at each store write of replacing a commands-only value with a brokered one, then
    /// relaunch over the same database and Keychain.
    @Test func aCrashAtAnyStoreBoundaryNeverPairsTheNewValueWithTheOldPolicy() async throws {
        for crashAt in 1...5 {
            let first = try await Light.make()
            let old = try await first.manager.create(label: "Deploy key", value: SecretValue("old-value-\(crashAt)-abcdef"), mode: .visible, commandsOnly: true)
            let oldRevision = try #require(first.manager.commandRevision(account: old.account, projectDirectory: nil))
            let gate = SecretWriteGate(at: crashAt)
            await first.store.setWriteHook { try await gate.hook($0) }
            let finished = OnceFlag()
            let save = Task { @MainActor in
                defer { _ = finished.set() }
                try await first.manager.create(label: "Deploy key", value: SecretValue("new-value-\(crashAt)-ghijkl"), mode: .brokered, bindings: [Self.binding])
            }
            try await waitUntil("gate \(crashAt) or done") { gate.entered || finished.isSet }
            if !gate.entered { _ = try await save.value; continue }
            // While held: the old policy still governs, with the old value only.
            #expect(try first.commandValue(old.account, revision: oldRevision).map { $0.hasPrefix("old-") } ?? true, "crash at \(crashAt): in flight")

            await first.store.setWriteHook(nil)
            let relaunched = try await Light.make(store: first.store, vault: first.vault)
            for secret in relaunched.manager.secrets where secret.label == "Deploy key" {
                if let revision = relaunched.manager.commandRevision(account: secret.account, projectDirectory: nil) {
                    let value = try relaunched.commandValue(secret.account, revision: revision)
                    #expect(value?.hasPrefix("new-") != true, "crash at \(crashAt): a command could receive the new value")
                }
                if secret.mode == .brokered {
                    let value = try relaunched.vault.read(account: secret.activeValueAccount).map { String(decoding: $0.utf8, as: UTF8.self) }
                    #expect(value?.hasPrefix("new-") == true, "crash at \(crashAt): brokered with the new value")
                }
            }
            gate.release(proceed: false)
            _ = try? await save.value
        }
    }

    /// Crash at each store write of saving a brand-new brokered secret: the relaunch never adopts the label as a
    /// commands-only secret.
    @Test func aCrashDuringAFirstSaveIsNeverAdoptedForCommands() async throws {
        for crashAt in 1...4 {
            let first = try await Light.make()
            let gate = SecretWriteGate(at: crashAt)
            await first.store.setWriteHook { try await gate.hook($0) }
            let finished = OnceFlag()
            let save = Task { @MainActor in
                defer { _ = finished.set() }
                try await first.manager.create(label: "Fresh key", value: SecretValue("brand-new-value-\(crashAt)"), mode: .brokered, bindings: [Self.binding])
            }
            try await waitUntil("gate \(crashAt) or done") { gate.entered || finished.isSet }
            if !gate.entered { _ = try await save.value; continue }
            await first.store.setWriteHook(nil)
            let relaunched = try await Light.make(store: first.store, vault: first.vault)
            let usable = relaunched.manager.secrets.filter { $0.label == "Fresh key" }
                .filter { relaunched.manager.commandRevision(account: $0.account, projectDirectory: nil) != nil }
            #expect(usable.isEmpty, "crash at \(crashAt): adopted as a commands-only secret")
            gate.release(proceed: false)
            _ = try? await save.value
        }
    }

    /// A failed metadata write at each boundary: the save fails, the old policy keeps the old value, and no new value is
    /// left behind in the Keychain.
    @Test func aFailedWriteLeavesTheOldPairAndNoOrphanValue() async throws {
        for failAt in 1...4 {
            let f = try await Light.make()
            let old = try await f.manager.create(label: "Deploy key", value: SecretValue("old-value-abcdef"), mode: .visible, commandsOnly: true)
            let revision = try #require(f.manager.commandRevision(account: old.account, projectDirectory: nil))
            let items = f.vault.count
            let counter = Mutex(0)
            await f.store.setWriteHook { batch in
                guard batch.isEmpty else { return }
                if counter.withLock({ $0 += 1; return $0 }) == failAt { throw InjectedStoreFailure() }
            }
            var failed = false
            do { try await f.manager.create(label: "Deploy key", value: SecretValue("new-value-ghijkl"), mode: .brokered, bindings: [Self.binding]) } catch { failed = true }
            await f.store.setWriteHook(nil)
            let current = try #require(f.manager.secret(old.account))
            if failed {
                #expect(current.mode == .visible, "fail at \(failAt): the old policy stays")
                #expect(try f.commandValue(old.account, revision: revision) == "old-value-abcdef", "fail at \(failAt)")
                #expect(f.vault.count == items, "fail at \(failAt): the unused new value was removed")
            } else {
                #expect(current.mode == .brokered)
                #expect(f.manager.commandRevision(account: old.account, projectDirectory: nil) == nil)
                #expect(try f.vault.read(account: current.activeValueAccount)?.utf8 == Data("new-value-ghijkl".utf8))
            }
            // A relaunch agrees with what the running app showed.
            let relaunched = try await Light.make(store: f.store, vault: f.vault)
            #expect(relaunched.manager.secret(old.account)?.mode == current.mode, "fail at \(failAt)")
        }
    }

    /// The end-to-end race from the review: an approval answered while the new value is being saved.
    @Test func anApprovalAnsweredDuringTheSaveNeverRunsWithTheNewValue() async throws {
        let fixture = try await SecretCommandApprovalTests.Fixture.start()
        defer { Task { await fixture.stop() } }
        let session = try await fixture.engine.createThread(in: SecretCommandApprovalTests.project, title: "deploy")
        try await waitUntil("graph") { fixture.engine.orchestration.node(session.id) != nil }
        let manager = try #require(fixture.engine.secretManager)
        for gateAt in 1...4 {
            let label = "Deploy key \(gateAt)"
            _ = await fixture.call("request_secret", ["label": .string(label), "reason": "To deploy."], session: session.id)
            let card = try #require(await fixture.engine.core.appRequests().first { if case .secret = $0.kind { true } else { false } })
            try await fixture.engine.extras.respond(to: card.id, .saveManagedSecret(SecretValue("old-value-\(gateAt)-abcdef"), SecretChoice(mode: .command)))
            let wake = try #require(await fixture.harness.server.syntheticTexts.last)
            let reference = try #require(wake.split(separator: " ").first { $0.hasPrefix(ContainerSecretReferences.prefix) }.map(String.init))
            _ = await fixture.call("secret_exec", ["secretRef": .string(reference), "name": "T", "command": .string("deploy \(gateAt)")], session: session.id)
            let (approval, _) = try #require(await fixture.approvalCard())

            let gate = SecretWriteGate(at: gateAt)
            await fixture.engine.store.setWriteHook { try await gate.hook($0) }
            let finished = OnceFlag()
            let save = Task { @MainActor in
                defer { _ = finished.set() }
                try await manager.create(label: label, value: SecretValue("new-value-\(gateAt)-ghijkl"), mode: .brokered, bindings: [Self.binding])
            }
            try await waitUntil("gate \(gateAt) or done") { gate.entered || finished.isSet }
            await fixture.engine.store.setWriteHook(nil)
            try? await fixture.engine.extras.respond(to: approval.id, .approve(always: false))
            gate.release(proceed: true)
            _ = try await save.value
            let calls = fixture.runtime.secretCalls.withLock { $0 }
            #expect(!calls.contains { String(decoding: $0.secret, as: UTF8.self).hasPrefix("new-value-\(gateAt)") },
                    "held at write \(gateAt): the approved command received the new, brokered value")
        }
    }
}
