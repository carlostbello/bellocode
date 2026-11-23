import Foundation
import Network
import Testing

@testable import SecretKit

/// v1.0.1 third verification, AV2-04: a gateway's scope (what projects its connections may use secrets of) is judged as
/// it is now, at every request, at the dispatch, and while a write is in flight, never as it was when a kept-alive
/// connection opened. A project removed from the shared workspace loses secret access on connections already open.
@Suite("Egress scope changes on open connections", .serialized, .timeLimit(.minutes(3)))
struct EgressScopeChangeTests {
    typealias Plain = EgressDispatchTests.Plain
    static let canary = EgressDispatchTests.canary

    /// The token the fixture's scope uses (read back from the proxy: `make` keeps it private).
    static func narrowed(_ f: Plain, admits: @escaping @Sendable (String) -> Bool) throws -> EgressScope {
        let token = try #require(f.proxy.scopeTokensForTesting.first)
        return EgressScope(id: "test", token: token, admitsProject: admits)
    }

    func keepAliveRequest(_ f: Plain) -> String {
        "GET http://plain.test/v1/echo HTTP/1.1\r\nHost: plain.test\r\nAuthorization: Bearer \(f.placeholder)\r\n\r\n"
    }

    /// One kept-alive connection: a request substituted under the scope that admits the project, then the project is
    /// removed from the scope; the next request on the same connection is refused and the value does not leave.
    @Test func aRemovedProjectLosesSecretAccessOnAKeptAliveConnection() async throws {
        let f = try await EgressDispatchTests.make()
        defer { f.stop() }
        let client = try await KeepAliveClient.open(port: f.gateway.port)
        defer { client.close() }
        let first = try #require(try await client.exchange(keepAliveRequest(f)))
        #expect(first.status == 200, "\(first.status)")
        #expect(f.server.requestCount == 1)

        f.proxy.setScopes([try Self.narrowed(f) { _ in false }])
        let second = try await client.exchange(keepAliveRequest(f))
        #expect(second?.status == 403, "the old scope's membership was used: \(second?.status ?? 0)")
        #expect(f.server.requestCount == 1, "a request of the removed project reached its bound service")
        #expect(f.reservedUses == 1, "only the first request's use is counted")
    }

    /// The scope is withdrawn altogether while a connection is open: its next request is refused and it is closed.
    @Test func aWithdrawnScopeEndsItsOpenConnections() async throws {
        let f = try await EgressDispatchTests.make()
        defer { f.stop() }
        let client = try await KeepAliveClient.open(port: f.gateway.port)
        defer { client.close() }
        #expect(try await client.exchange(keepAliveRequest(f))?.status == 200)

        f.proxy.setScopes([])
        let refused = try await client.exchange(keepAliveRequest(f))
        #expect(refused?.status == 403, "\(refused?.status ?? 0)")
        #expect(try await client.exchange(keepAliveRequest(f)) == nil, "the connection stays open after its scope was withdrawn")
        #expect(f.server.requestCount == 1)
    }

    /// The scope narrows after the request passed its last check, while its write is pending: publishing the scope
    /// cancels the write and returns only once it has ended; nothing reaches the destination.
    @Test func aScopeNarrowedDuringTheWriteStopsIt() async throws {
        let f = try await EgressDispatchTests.make(maxUses: 3)
        defer { f.stop() }
        let gate = SendGate()
        f.proxy.faults.withLock { $0.beforeSend = { await gate.hold() } }
        let request = Task { try await f.exchange(f.request("/v1/echo")) }
        await gate.waitUntilHeld()
        #expect(f.proxy.dispatchCount == 1, "authorized and registered")
        let narrowed = try Self.narrowed(f) { _ in false }
        let published = OnceBox()
        let publish = Task {
            await f.proxy.publishScopes([narrowed])
            published.set(f.proxy.dispatchCount)
        }
        try await waitUntilTrue { published.value != nil || f.proxy.dispatchCancelledCount == 1 }
        #expect(published.value == nil, "the scope change returned while the request could still be written")
        gate.release()
        await publish.value
        #expect(published.value == 0)
        let response = try await request.value
        #expect(EgressDispatchTests.text(response).hasPrefix("HTTP/1.1 403"), "\(EgressDispatchTests.text(response).prefix(120))")
        #expect(!EgressDispatchTests.leaked(Self.canary, in: f.server.receivedBytes))
        #expect(f.server.requestCount == 0)
        #expect(f.reservedUses == 0, "nothing was written: the use is given back")
    }

    /// A scope change that keeps the project (another root added) does not disturb the open connection.
    @Test func aScopeChangeThatKeepsTheProjectLeavesTheConnectionWorking() async throws {
        let f = try await EgressDispatchTests.make()
        defer { f.stop() }
        let client = try await KeepAliveClient.open(port: f.gateway.port)
        defer { client.close() }
        #expect(try await client.exchange(keepAliveRequest(f))?.status == 200)
        f.proxy.setScopes([try Self.narrowed(f) { $0 == "/project" || $0 == "/other" }])
        #expect(try await client.exchange(keepAliveRequest(f))?.status == 200)
        #expect(f.server.requestCount == 2)
    }
}

/// One client connection to a gateway, kept alive across requests.
final class KeepAliveClient: Sendable {
    struct Response: Equatable {
        var status: Int
        var body: Data
    }

    let wire: WireConnection

    private init(wire: WireConnection) { self.wire = wire }

    static func open(port: UInt16) async throws -> KeepAliveClient {
        let wire = WireConnection(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp),
                                  queue: DispatchQueue(label: "keep-alive-client"))
        try await wire.start()
        return KeepAliveClient(wire: wire)
    }

    /// Sends `request` and reads its response; nil when the proxy closed the connection instead.
    func exchange(_ request: String) async throws -> Response? {
        do { try await wire.send(Data(request.utf8)) } catch { return nil }
        guard let data = try? await wire.readHead(), let head = HTTPHead(data), head.startLine.count > 1, let status = Int(head.startLine[1]),
              let framing = head.responseFraming(requestMethod: "GET") else { return nil }
        let body = framing == .untilClose ? Data() : try await wire.readBody(framing, limit: 1 << 20)
        return Response(status: status, body: body)
    }

    func close() { wire.cancel() }
}
