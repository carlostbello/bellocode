import Foundation
import Network
import Testing
@testable import MockOpenCode

/// m2 (docs/reviews/M1-review.md): a connection burst faster than the mock consumes cannot grow its accept queue.
@Suite struct ListenerBoundTests {
    @Test func burstBeyondTheBacklogIsRejected() async throws {
        let queue = DispatchQueue(label: "listener-bound-test")
        let listener = try await LoopbackListener.start(queue: queue, backlog: 4)
        defer { listener.stop() }
        let clients = (0..<12).map { _ in
            NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listener.port)!, using: .tcp)
        }
        for client in clients { client.start(queue: queue) }
        defer { for client in clients { client.cancel() } }
        // Nothing consumes `connections`: four wait, the rest are refused as they arrive.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while listener.rejected < 8, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(listener.rejected == 8)
        var iterator = listener.connections.makeAsyncIterator()
        var waiting = 0
        for _ in 0..<4 { if await iterator.next() != nil { waiting += 1 } }
        #expect(waiting == 4)
    }
}
