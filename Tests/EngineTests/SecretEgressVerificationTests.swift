import BelloCore
import Foundation
import Network
import Synchronization
import Testing

@testable import Engine
@testable import SecretKit

/// v1.0.1 verification (docs/reviews/v1.0.1-*-verification.md), the secret manager's side: a refused request's stored
/// use is lowered again and stays so after a relaunch (AV13); a revocation returns only once the proxy has a snapshot
/// without it (AF15); a short value saved as hidden by an earlier release is never activated (AF16); a thread's
/// environment replacements are ordered, so a stale one never lands after a revocation's (AF26, GV04).
@MainActor
@Suite("Secret egress verification", .serialized, .timeLimit(.minutes(3)))
struct SecretEgressVerificationTests {
    typealias Light = SecretValuePolicyBindingTests.Light
    static let binding = SecretBinding(host: "api.example.com", pathPrefixes: ["/v1"], locations: [.header("Authorization", prefix: "Bearer ")], maxUses: 5)

    // MARK: AV13

    /// Two requests reserve and store a use each; one is refused before sending. Only the other's use survives a relaunch.
    @Test func aReleasedUseIsLoweredInTheStoreAndStaysLoweredAfterRelaunch() async throws {
        let f = try await Light.make()
        let secret = try await f.manager.create(label: "Counted", value: SecretValue("sk_counted_0123456789"), mode: .placeholder, bindings: [Self.binding])
        let use = SubstitutionUse(account: secret.account, bindingID: Self.binding.id, sessionID: "ses", placeholder: "")
        #expect(f.manager.useLedger.reserve([use]) { _ in 5 })
        #expect(f.manager.useLedger.reserve([use]) { _ in 5 })
        #expect(await f.manager.recordUses([use]))
        #expect(f.manager.secret(secret.account)?.uses[Self.binding.id] == 2)
        // The first request is refused before anything is sent.
        f.manager.useLedger.release([use])
        await f.manager.releaseUses([use])
        #expect(f.manager.secret(secret.account)?.uses[Self.binding.id] == 1)
        let relaunched = try await Light.make(store: f.store, vault: f.vault)
        #expect(relaunched.manager.secret(secret.account)?.uses[Self.binding.id] == 1, "the refused use came back after a relaunch")
        #expect(relaunched.manager.useLedger.count(account: secret.account, bindingID: Self.binding.id) == 1)
    }

    /// End to end through the proxy and the manager's wiring: a one-use binding whose request cannot reach its
    /// destination (nothing sent) still has its use after a relaunch.
    @Test func aRefusedProxyRequestKeepsItsOnlyUseAcrossARelaunch() async throws {
        let f = try await Light.make()
        // An http binding is refused by Settings; it is written directly so the request can be plain (no TLS client).
        let binding = SecretBinding(scheme: "http", host: "down.test", pathPrefixes: ["/v1"], locations: [.header("Authorization", prefix: "Bearer ")], maxUses: 1)
        var row = ManagedSecret(account: "bcs_onceuse", name: "ONCE", label: "Once", mode: .placeholder, bindings: [binding])
        row.valueAccount = "bcs_onceuse.v1"
        try f.vault.store(account: "bcs_onceuse.v1", label: "Once", value: SecretValue("sk_once_0123456789"))
        try await f.store.saveManagedSecret(row)
        try await f.legacy.recordLabel(account: row.account, label: row.label)
        let placeholder = Placeholder.make()
        try await f.store.savePlaceholderGrant(PlaceholderGrant(placeholder: placeholder, account: row.account, sessionID: "ses", projectDirectory: "/project"))
        let launched = try await Light.make(store: f.store, vault: f.vault)
        let manager = launched.manager
        let proxy = EgressProxy(authority: try CertificateAuthority(commonName: "Test egress CA"), configuration: EgressProxyConfiguration(
            resolverOverrides: ["down.test": HostPort(host: "127.0.0.1", port: 1)]), ledger: manager.useLedger)
        let port = try await proxy.start()
        defer { proxy.stop() }
        proxy.setScopes([EgressScope(id: "test", token: "tok") { $0 == "/project" }])
        manager.proxy = proxy
        manager.connectUseAccounting(proxy)
        // Observes what the manager's recorder stored, then hands on to it.
        let recorded = MaxBox()
        proxy.setUseRecorder { [weak manager] uses in
            let stored = await manager?.recordUses(uses) ?? false
            await MainActor.run { recorded.note(manager?.secret(uses[0].account)?.uses[uses[0].bindingID] ?? 0) }
            return stored
        }
        await manager.refreshProxySnapshot()
        let response = try await RawEgressClient.exchange(port: port, token: "tok",
            request: "GET http://down.test/v1/x HTTP/1.1\r\nHost: down.test\r\nAuthorization: Bearer \(placeholder)\r\nConnection: close\r\n\r\n")
        #expect(response.hasPrefix("HTTP/1.1 502"), "\(response.prefix(80))")
        #expect(recorded.value == 1, "the use was stored before connecting")
        #expect(manager.secret(row.account)?.uses[binding.id] ?? 0 == 0, "this launch")
        let relaunched = try await Light.make(store: f.store, vault: f.vault)
        #expect(relaunched.manager.secret(row.account)?.uses[binding.id] ?? 0 == 0, "the unsent request used up the binding after a relaunch")
    }

    /// AV13 (third round): the first refund's write is suspended while the second reservation is released; the
    /// second refund then runs. The database, the record and a relaunch all end at zero (no use charged).
    @Test func concurrentRefundsLeaveTheSameCountInTheStoreAndInMemory() async throws {
        let f = try await Light.make()
        let secret = try await f.manager.create(label: "Refunded", value: SecretValue("sk_refunded_0123456789"), mode: .placeholder, bindings: [Self.binding])
        let use = SubstitutionUse(account: secret.account, bindingID: Self.binding.id, sessionID: "ses", placeholder: "")
        #expect(f.manager.useLedger.reserve([use]) { _ in 5 })
        #expect(f.manager.useLedger.reserve([use]) { _ in 5 })
        #expect(await f.manager.recordUses([use]))
        #expect(f.manager.secret(secret.account)?.uses[Self.binding.id] == 2)

        let gate = SecretWriteGate(at: 1)
        await f.store.setWriteHook { try await gate.hook($0) }
        f.manager.useLedger.release([use])
        let first = Task { @MainActor in await f.manager.releaseUses([use]) }
        try await waitUntil("first refund writing") { gate.entered }
        // The second request is refused while the first refund's write is in flight.
        f.manager.useLedger.release([use])
        gate.release(proceed: true)
        await first.value
        await f.store.setWriteHook(nil)
        await f.manager.releaseUses([use])

        let stored = try await f.store.managedSecretRows().secrets.first { $0.account == secret.account }
        #expect(stored?.uses[Self.binding.id] ?? 0 == f.manager.secret(secret.account)?.uses[Self.binding.id] ?? 0, "database and memory disagree")
        #expect(f.manager.secret(secret.account)?.uses[Self.binding.id] ?? 0 == 0)
        let relaunched = try await Light.make(store: f.store, vault: f.vault)
        #expect(relaunched.manager.secret(secret.account)?.uses[Self.binding.id] ?? 0 == 0, "a refused use came back after a relaunch")
    }

    /// Many requests reserve, store and are refused at once (each refund racing the others' reservations and
    /// refunds): every count ends equal in the ledger, the record and the database, and nothing is charged.
    @Test func manyConcurrentReservationsAndRefundsAgree() async throws {
        let f = try await Light.make()
        let secret = try await f.manager.create(label: "Busy", value: SecretValue("sk_busy_0123456789"), mode: .placeholder, bindings: [Self.binding])
        let use = SubstitutionUse(account: secret.account, bindingID: Self.binding.id, sessionID: "ses", placeholder: "")
        let manager = f.manager
        let requests = (0..<40).map { _ in
            Task { @MainActor in
                guard manager.useLedger.reserve([use], limit: { _ in 1_000 }) else { return }
                _ = await manager.recordUses([use])
                await Task.yield()
                manager.useLedger.release([use])
                await manager.releaseUses([use])
            }
        }
        for request in requests { await request.value }
        let stored = try await f.store.managedSecretRows().secrets.first { $0.account == secret.account }
        #expect(manager.useLedger.count(account: secret.account, bindingID: Self.binding.id) == 0)
        #expect(manager.secret(secret.account)?.uses[Self.binding.id] ?? 0 == 0)
        #expect(stored?.uses[Self.binding.id] ?? 0 == 0, "the database kept a refunded use")
    }

    // MARK: AF15

    /// The revocation's snapshot is superseded by a newer refresh while both read the Keychain: the revocation returns
    /// only once that newer snapshot (without the revoked secret) is in the proxy.
    @Test func aSupersededRevocationRefreshWaitsForTheNewerSnapshot() async throws {
        let vault = SequencedVault()
        let store = try ProjectionStore(location: .inMemory)
        let legacy = SecretService(vault: vault, store: store, clock: SystemWallClock(), root: temporaryRoot())
        await legacy.load()
        let manager = SecretManager(store: store, vault: vault, legacy: legacy, clock: SystemWallClock(), configuration: nil)
        await manager.reload()
        let revoked = try await manager.create(label: "Revoked", value: SecretValue("sk_revoked_0123456789"), mode: .placeholder, bindings: [Self.binding])
        let other = try await manager.create(label: "Other", value: SecretValue("sk_other_0123456789"), mode: .placeholder, bindings: [Self.binding])
        let proxy = EgressProxy(authority: try CertificateAuthority(commonName: "Test egress CA"))
        manager.proxy = proxy
        await manager.refreshProxySnapshot()
        #expect(Set(proxy.currentSnapshot.secrets.keys) == [revoked.account, other.account])

        vault.gate(true)
        let seenAtReturn = Mutex<Set<String>?>(nil)
        let revocation = Task { @MainActor in
            try await manager.revoke(account: revoked.account)
            seenAtReturn.withLock { $0 = Set(proxy.currentSnapshot.secrets.keys) }
        }
        try await waitUntil("revocation reading the Keychain") { vault.entered == 1 }
        let newer = Task { @MainActor in await manager.refreshProxySnapshot() }
        try await waitUntil("newer refresh reading the Keychain") { vault.entered == 2 }
        vault.release(0)
        try await waitUntil("revocation returned or waiting") { seenAtReturn.withLock { $0 != nil } || manager.waitingSnapshotRefreshes == 1 }
        vault.release(1)
        try await revocation.value
        await newer.value
        let seen = try #require(seenAtReturn.withLock { $0 })
        #expect(!seen.contains(revoked.account), "the revocation returned while the proxy still had the revoked secret")
        #expect(seen.contains(other.account))
    }

    // MARK: AF16

    /// Rows saved by the earlier release: a 4-byte value in Placeholder and in Brokered mode. Neither is activated in
    /// its hidden mode; both are shown; a rotation to a longer value makes the secret usable again.
    @Test func aShortHiddenRowFromAnEarlierReleaseIsNeverActivated() async throws {
        let f = try await Light.make()
        for (account, mode) in [("bcs_shortph", SecretUseMode.placeholder), ("bcs_shortbr", .brokered)] {
            let row = ManagedSecret(account: account, name: account.uppercased(), label: account, mode: mode, bindings: [Self.binding])
            try f.vault.store(account: account, label: account, value: SecretValue("1234"))
            try await f.store.saveManagedSecret(row)
            try await f.legacy.recordLabel(account: account, label: account)
        }
        try await f.store.savePlaceholderGrant(PlaceholderGrant(placeholder: Placeholder.make(), account: "bcs_shortph", sessionID: "ses", projectDirectory: "/p"))
        let launched = try await Light.make(store: f.store, vault: f.vault)
        let manager = launched.manager
        #expect(manager.shortValueAccounts == ["bcs_shortph", "bcs_shortbr"], "shown in Settings")
        let proxy = EgressProxy(authority: try CertificateAuthority(commonName: "Test egress CA"))
        manager.proxy = proxy
        await manager.refreshProxySnapshot()
        #expect(proxy.currentSnapshot.values["bcs_shortph"] == nil, "the proxy got a value its scanner cannot find")
        await #expect(throws: (any Error).self) {
            try await manager.grant(account: "bcs_shortph", sessionID: SessionID("ses_new"), projectDirectory: "/p")
        }
        let caller = ExtrasCaller(sessionID: SessionID("ses"), projectID: ProjectID("p"), directory: "/p", projectDirectory: "/p")
        let brokered = await manager.httpRequest(.object(["url": .string("https://api.example.com/v1/x"),
                                                          "headers": .object(["Authorization": .string("Bearer {{secret:BCS_SHORTBR}}")])]), caller: caller)
        #expect(brokered.isError && brokered.text.contains("shorter than 8 bytes"), "\(brokered.text)")

        try await manager.rotate(account: "bcs_shortph", value: SecretValue("sk_long_enough_0123"))
        #expect(!manager.shortValueAccounts.contains("bcs_shortph"))
        #expect(proxy.currentSnapshot.values["bcs_shortph"].map { String(decoding: $0.utf8, as: UTF8.self) } == "sk_long_enough_0123")
        var visible = try #require(manager.secret("bcs_shortbr"))
        visible.mode = .visible
        visible.bindings = []
        try await manager.update(visible, confirmVisible: true)
        #expect(manager.shortValueAccounts.isEmpty, "a Visible short value is fine")
    }

    // MARK: AF26, GV04

    /// The reconnect loop has read a visible value and is about to send it when the person revokes the secret. The
    /// revocation's replacement is sent after the loop's, so the server ends with the value removed and nothing pending.
    @Test func aStaleEnvironmentReplacementNeverLandsAfterARevocation() async throws {
        let fixture = try await SecretCommandApprovalTests.Fixture.start()
        defer { Task { await fixture.stop() } }
        let manager = try #require(fixture.engine.secretManager)
        let session = try await fixture.engine.createThread(in: SecretCommandApprovalTests.project, title: "env")
        let value = "zz-ENV-stale-\(UUID().uuidString.prefix(8))"
        let secret = try await manager.create(label: "Stale key", value: SecretValue(value), mode: .visible, confirmVisible: true)
        try await manager.grant(account: secret.account, sessionID: session.id, projectDirectory: SecretCommandApprovalTests.project)
        #expect(await fixture.harness.server.environmentText.contains(value), "delivered")

        let gate = SendGateMain()
        manager.environmentSendHook = { _ in await gate.holdFirst() }
        let loop = Task { @MainActor in await manager.applyEnvironment(session.id.rawValue) }
        try await waitUntil("the loop's request computed and held") { gate.held }
        let revocation = Task { @MainActor in try await manager.revoke(account: secret.account) }
        let revoked = OnceFlag()
        Task { @MainActor in _ = try? await revocation.value; _ = revoked.set() }
        try await waitUntil("revocation done or queued") { revoked.isSet || manager.waitingEnvironmentWriters(session.id.rawValue) == 1 }
        gate.release()
        await loop.value
        try await revocation.value
        manager.environmentSendHook = nil
        #expect(!(await fixture.harness.server.environmentText.contains(value)), "the stale replacement landed after the revocation's")
        #expect(manager.pendingEnvironmentSessions.isEmpty)
    }

    /// AF26 (third round): two visible secrets of one thread are revoked while an earlier replacement is in flight. The
    /// first revocation's replacement is superseded by the second's before it is sent; the first revocation returns only
    /// once the second's replacement (which removes both values) has been answered.
    @Test func aSupersededRevocationWaitsForTheReplacementThatRemovesItsValue() async throws {
        let fixture = try await SecretCommandApprovalTests.Fixture.start()
        defer { Task { await fixture.stop() } }
        let manager = try #require(fixture.engine.secretManager)
        let session = try await fixture.engine.createThread(in: SecretCommandApprovalTests.project, title: "env")
        let id = session.id.rawValue
        let first = "zz-ENV-first-\(UUID().uuidString.prefix(8))"
        let second = "zz-ENV-second-\(UUID().uuidString.prefix(8))"
        let a = try await manager.create(label: "First key", value: SecretValue(first), mode: .visible, confirmVisible: true)
        let b = try await manager.create(label: "Second key", value: SecretValue(second), mode: .visible, confirmVisible: true)
        try await manager.grant(account: a.account, sessionID: session.id, projectDirectory: SecretCommandApprovalTests.project)
        try await manager.grant(account: b.account, sessionID: session.id, projectDirectory: SecretCommandApprovalTests.project)
        let delivered = await fixture.harness.server.environmentText
        #expect(delivered.contains(first) && delivered.contains(second), "delivered")

        let gate = SendGateSequence()
        manager.environmentSendHook = { _ in await gate.hold() }
        let loop = Task { @MainActor in await manager.applyEnvironment(id) }
        try await waitUntil("an earlier replacement held") { gate.arrived == 1 }
        let revokedFirst = OnceFlag()
        let revokeFirst = Task { @MainActor in try await manager.revoke(account: a.account); _ = revokedFirst.set() }
        try await waitUntil("first revocation queued") { manager.waitingEnvironmentWriters(id) == 1 }
        let revokeSecond = Task { @MainActor in try await manager.revoke(account: b.account) }
        try await waitUntil("second revocation queued") { manager.waitingEnvironmentWriters(id) == 2 }
        gate.release(1)
        await loop.value
        // The first revocation's replacement was superseded; the second's is computed and held before it is sent.
        try await waitUntil("second revocation's replacement held") { gate.arrived == 2 }
        try await waitUntil("first revocation returned or waiting") { revokedFirst.isSet || manager.waitingEnvironmentSettlements(id) == 1 }
        #expect(!revokedFirst.isSet, "the first revocation returned before any replacement removing its value was answered")
        #expect(await fixture.harness.server.environmentText.contains(first), "precondition: the server still has the value")
        gate.release(2)
        try await revokeFirst.value
        try await revokeSecond.value
        manager.environmentSendHook = nil
        let after = await fixture.harness.server.environmentText
        #expect(!after.contains(first) && !after.contains(second))
        #expect(manager.pendingEnvironmentSessions.isEmpty)
        #expect(manager.waitingEnvironmentSettlements(id) == 0)
    }
}

/// Holds every environment send until its number is released (main actor; numbered from 1 by arrival).
@MainActor
final class SendGateSequence {
    private(set) var arrived = 0
    private var released: Set<Int> = []
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]

    func hold() async {
        arrived += 1
        let number = arrived
        guard !released.contains(number) else { return }
        await withCheckedContinuation { waiting[number] = $0 }
    }

    func release(_ number: Int) {
        released.insert(number)
        waiting.removeValue(forKey: number)?.resume()
    }
}

/// The highest value noted.
final class MaxBox: Sendable {
    private let stored = Mutex(0)
    func note(_ value: Int) { stored.withLock { $0 = max($0, value) } }
    var value: Int { stored.withLock { $0 } }
}

/// Holds the first environment send until released (main actor).
@MainActor
final class SendGateMain {
    private(set) var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var used = false

    func holdFirst() async {
        guard !used else { return }
        used = true
        held = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// A vault whose reads, once gated, each wait for their own release (by arrival order).
final class SequencedVault: SecretVault {
    private let inner = InMemorySecretVault()
    private let state = Mutex<(gating: Bool, gates: [DispatchSemaphore])>((false, []))

    func gate(_ on: Bool) { state.withLock { $0.gating = on } }
    var entered: Int { state.withLock { $0.gates.count } }
    func release(_ index: Int) { state.withLock { $0.gates[index] }.signal() }

    func store(account: String, label: String, value: SecretValue) throws { try inner.store(account: account, label: label, value: value) }
    func read(account: String) throws -> SecretValue? {
        let gate = state.withLock { state -> DispatchSemaphore? in
            guard state.gating else { return nil }
            let gate = DispatchSemaphore(value: 0)
            state.gates.append(gate)
            return gate
        }
        gate?.wait()
        return try inner.read(account: account)
    }
    func delete(account: String) throws { try inner.delete(account: account) }
}

/// Plain HTTP to the egress proxy's front, as a gateway relays it: the scope preamble, then the request; every byte
/// until the proxy closes.
enum RawEgressClient {
    static func exchange(port: UInt16, token: String, request: String) async throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "raw-egress-client")
        let started = Mutex(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                let result: Result<Void, any Error>?
                switch state {
                case .ready: result = .success(())
                case .failed(let error), .waiting(let error): result = .failure(error)
                default: result = nil
                }
                guard let result, started.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            connection.start(queue: queue)
        }
        defer { connection.cancel() }
        connection.send(content: Data("BCEGRESS \(token)\n\(request)".utf8), completion: .idempotent)
        var received = Data()
        while true {
            let (data, complete): (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                    if let error, data?.isEmpty ?? true { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, complete)) }
                }
            }
            if let data { received.append(data) }
            if complete || (data?.isEmpty ?? true) { break }
        }
        return String(decoding: received, as: UTF8.self)
    }
}
