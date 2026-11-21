import BelloCore
import Foundation
import Testing

@testable import SecretKit

/// v1.0.0 review N19 (3): a tunnel that fails while it is being established leaves no bookkeeping or inspection
/// connection behind, and a response that ends early is reported as unreadable, not as too large.
@Suite("Egress proxy tunnel cleanup", .serialized, .timeLimit(.minutes(2)))
struct ProxyTunnelCleanupTests {
    @Test func aTunnelThatFailsWhileOpeningLeavesNothingBehind() async throws {
        let f = try await ProxyTests.makeFixture()
        defer { f.stop() }
        f.proxy.faults.withLock { $0.failTunnelEstablished = true }
        for _ in 0..<3 {
            _ = try? await f.client.get("https://bound.test/v1/ok", headers: ["Authorization": "Bearer \(f.placeholder)"])
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while f.proxy.pendingTunnelCount > 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(f.proxy.pendingTunnelCount == 0, "tunnel entries left after failed opens")
        // The proxy still works afterwards.
        f.proxy.faults.withLock { $0.failTunnelEstablished = false }
        let (status, _, _) = try await f.client.get("https://bound.test/v1/ok", headers: ["Authorization": "Bearer \(f.placeholder)"])
        #expect(status == 200)
    }

    @Test func aResponseThatEndsEarlyIsNotCalledTooLarge() async throws {
        let f = try await ProxyTests.makeFixture()
        defer { f.stop() }
        let (status, _, body) = try await f.client.get("https://bound.test/v1/truncated", headers: ["Authorization": "Bearer \(f.placeholder)"])
        let text = String(decoding: body, as: UTF8.self)
        #expect(status == 502)
        #expect(text.contains("could not be read"), "\(text)")
        #expect(!text.contains("too large"), "\(text)")
    }
}
