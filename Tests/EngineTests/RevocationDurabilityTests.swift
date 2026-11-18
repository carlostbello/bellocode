import BelloCore
import Foundation
import Synchronization
import Testing

@testable import Engine

/// A vault whose deletions can be refused (a Keychain that says no).
final class RefusingVault: SecretVault {
    let inner = InMemorySecretVault()
    let refuseDelete = Mutex(false)
    func store(account: String, label: String, value: SecretValue) throws { try inner.store(account: account, label: label, value: value) }
    func read(account: String) throws -> SecretValue? { try inner.read(account: account) }
    func delete(account: String) throws {
        if refuseDelete.withLock({ $0 }) { throw CocoaError(.userCancelled) }
        try inner.delete(account: account)
    }
}

struct StoreRefused: Error {}

/// S7 (docs/reviews/deep-review-1.md): a revocation succeeds only when its durable deletion did; failures are shown
/// and retried, and a token the person believed removed is never reused.
@Suite("Revocation durability", .timeLimit(.minutes(3)))
@MainActor
struct RevocationDurabilityTests {
    @Test func aNetworkGrantWhoseDeletionFailsIsBlockedPendingAndSurvivesARestartRevoked() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bellocode-s7-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProjectionStore(location: .inMemory)
        let visuals = VisualService(store: store, directory: directory)
        await visuals.load()
        await visuals.approveNetwork("v_1", hosts: ["cdn.example.com"], always: true)
        #expect(visuals.networkGrants == ["cdn.example.com"])

        await store.setWriteHook { _ in throw StoreRefused() }
        await #expect(throws: ExtrasError.self) { try await visuals.revokeNetwork("cdn.example.com") }
        #expect(visuals.networkGrants.isEmpty, "blocked at once")
        #expect(visuals.pendingNetworkRevocations == ["cdn.example.com"], "shown as removal pending, not as done")
        #expect(try await store.grants(.network) == ["cdn.example.com"], "the row is still there")

        // Restart while the store still refuses: the grant is not brought back.
        let restarted = VisualService(store: store, directory: directory)
        await restarted.load()
        #expect(restarted.networkGrants.isEmpty)
        #expect(restarted.pendingNetworkRevocations == ["cdn.example.com"])

        // The store recovers: the retry completes the revocation.
        await store.setWriteHook(nil)
        try await restarted.retryPendingRevocations()
        #expect(restarted.pendingNetworkRevocations.isEmpty)
        #expect(try await store.grants(.network).isEmpty)
        let third = VisualService(store: store, directory: directory)
        await third.load()
        #expect(third.networkGrants.isEmpty && third.pendingNetworkRevocations.isEmpty)
    }

    func makeService(_ tokens: RefusingVault, store: ProjectionStore) async -> MergeRequestService {
        let service = MergeRequestService(
            store: store, clock: ManualWallClock(Date(timeIntervalSince1970: 1_800_000_000)), transport: FixtureForgeTransport(),
            tokens: tokens, baseInterval: 120, maxBackoff: 1_800, autoPoll: false)
        await service.start()
        return service
    }

    @Test func aGitLabInstanceIsRemovedOnlyWhenItsTokenIsDeleted() async throws {
        let store = try ProjectionStore(location: .inMemory)
        let tokens = RefusingVault()
        let service = await makeService(tokens, store: store)
        let instance = try await service.saveInstance(baseURL: "https://code.corp.test", token: SecretValue("glpat-OLD"))
        tokens.refuseDelete.withLock { $0 = true }
        await #expect(throws: ExtrasError.self) { try await service.removeInstance(instance) }
        #expect(service.instances.contains(instance), "still listed: the person is not told it is gone")
        #expect(service.instanceProblems[instance.baseURL]?.contains("could not be deleted") == true)
        tokens.refuseDelete.withLock { $0 = false }
        try await service.removeInstance(instance)
        #expect(!service.instances.contains(instance))
        #expect(try tokens.read(account: instance.baseURL) == nil)
    }

    @Test func reAddingAnAddressNeverReusesAnOldToken() async throws {
        let store = try ProjectionStore(location: .inMemory)
        let tokens = RefusingVault()
        let service = await makeService(tokens, store: store)
        let old = try await service.saveInstance(baseURL: "https://code.corp.test", token: SecretValue("glpat-OLD"))
        // The address is removed, and a token for it turns up in the Keychain again (an item the deletion did not reach,
        // such as a duplicate from an earlier install).
        try await service.removeInstance(old)
        try tokens.store(account: old.baseURL, label: "left over", value: SecretValue("glpat-OLD"))
        // A restart in between: the removal is remembered in the store.
        let restarted = await makeService(tokens, store: store)
        tokens.refuseDelete.withLock { $0 = true }
        await #expect(throws: ExtrasError.self) { _ = try await restarted.saveInstance(baseURL: "https://code.corp.test", token: nil) }
        #expect(restarted.instances.isEmpty, "not added on top of the old token")
        tokens.refuseDelete.withLock { $0 = false }
        let instance = try await restarted.saveInstance(baseURL: "https://code.corp.test", token: nil)
        #expect(try tokens.read(account: instance.baseURL) == nil, "the old token was deleted, not reused")
        #expect(!restarted.instancesWithToken.contains(instance.baseURL))
        // With a new token the new one is stored.
        _ = try await restarted.saveInstance(baseURL: "https://code.corp.test", token: SecretValue("glpat-NEW"))
        #expect(try tokens.read(account: instance.baseURL).map { String(decoding: $0.utf8, as: UTF8.self) } == "glpat-NEW")
    }
}
