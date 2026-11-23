import BelloCore
import Foundation
import Synchronization
import Testing

@testable import SecretKit

/// v1.0.0 review N13 (3): a request refused before it is sent gives its reserved uses back, so a failed recording
/// never uses up a limited binding; A12: a request whose secret changed before the first hop sends nothing.
@Suite("Broker use reservation", .serialized, .timeLimit(.minutes(2)))
struct BrokerUseReservationTests {
    @Test func aUseThatCouldNotBeRecordedIsNotBurned() async throws {
        let f = try await BrokerTests.fixture(maxUses: 1)
        defer { f.stop() }
        let ledger = SecretUseLedger()
        let refusing = SecretBroker(extraAnchors: [f.ca.certificateDER], ledger: ledger) { _ in false }
        let request = SecretBroker.Request(url: f.origin + "/v1/ok", headers: ["Authorization": "Bearer {{secret:API_KEY}}"])
        let refused = await refusing.perform(request, secrets: f.secrets, sessionID: "ses", projectDirectory: "/p")
        #expect(refused.text.hasPrefix("BelloCode refused"))
        #expect(refused.reserved.isEmpty, "nothing was sent, so nothing is reported as used")
        #expect(ledger.count(account: f.secret.account, bindingID: f.secret.bindings[0].id) == 0)
        #expect(f.server.requestCount == 0)
        // The binding's single use is still available once recording works.
        let working = SecretBroker(extraAnchors: [f.ca.certificateDER], ledger: ledger) { _ in true }
        let sent = await working.perform(request, secrets: f.secrets, sessionID: "ses", projectDirectory: "/p")
        #expect(sent.text.hasPrefix("Status: 200"), "\(sent.text)")
        #expect(ledger.count(account: f.secret.account, bindingID: f.secret.bindings[0].id) == 1)
    }

    /// AV13: the secret changes after the use was stored and before the request is sent: the stored use is lowered again.
    @Test func aChangeAfterRecordingLowersTheStoredUse() async throws {
        let f = try await BrokerTests.fixture(maxUses: 1)
        defer { f.stop() }
        let ledger = SecretUseLedger()
        let recorded = Mutex<[SubstitutionUse]>([])
        let released = Mutex<[SubstitutionUse]>([])
        let checks = Mutex(0)
        var broker = SecretBroker(extraAnchors: [f.ca.certificateDER], ledger: ledger) { uses in recorded.withLock { $0 += uses }; return true }
        broker.releaseUses = { uses in released.withLock { $0 += uses } }
        // Authorized at the first check, changed by the one right before sending.
        broker.stillAuthorized = { checks.withLock { $0 += 1; return $0 == 1 } }
        let outcome = await broker.perform(.init(url: f.origin + "/v1/ok", headers: ["Authorization": "Bearer {{secret:API_KEY}}"]),
                                           secrets: f.secrets, sessionID: "ses", projectDirectory: "/p")
        #expect(outcome.text.contains("changed while this request was in progress"), "\(outcome.text)")
        #expect(recorded.withLock { $0.count } == 1)
        #expect(released.withLock { $0.map(\.bindingID) } == [f.secret.bindings[0].id])
        #expect(ledger.count(account: f.secret.account, bindingID: f.secret.bindings[0].id) == 0)
        #expect(f.server.requestCount == 0)
    }

    @Test func aChangedSecretSendsNothing() async throws {
        let f = try await BrokerTests.fixture()
        defer { f.stop() }
        var broker = SecretBroker(extraAnchors: [f.ca.certificateDER])
        broker.stillAuthorized = { false }
        let outcome = await broker.perform(.init(url: f.origin + "/v1/ok", headers: ["Authorization": "Bearer {{secret:API_KEY}}"]),
                                           secrets: f.secrets, sessionID: "ses", projectDirectory: "/p")
        #expect(outcome.text.contains("changed while this request was in progress"), "\(outcome.text)")
        #expect(f.server.requestCount == 0)
    }
}
