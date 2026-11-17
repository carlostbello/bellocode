import Darwin
import Foundation
import Testing

@testable import ContainerKit

/// Counts events and lets a task wait until the count reaches a value (no sleeps).
actor EventGate {
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func signal() {
        count += 1
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        for waiter in ready { waiter.1.resume() }
    }

    func wait(for target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }

    var value: Int { count }
}

/// M4 (docs/reviews/M3-M6-review.md): connection bookkeeping cannot leak, and stop closes active peers.
@Suite(.timeLimit(.minutes(3)))
struct PortForwarderTests {
    /// Connects to the forwarder and reads until end of stream (or a 10 s receive timeout). Returns true on EOF.
    static func connectAndReadToEnd(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return false }
        var byte: UInt8 = 0
        while true {
            let count = read(fd, &byte, 1)
            if count == 0 { return true }
            if count < 0 { return false }
        }
    }

    static func connect(_ port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return fd
    }

    @Test func connectionsThatEndBeforeTheyAreStoredDoNotLeakAdmission() async throws {
        let relayed = EventGate()
        let ended = EventGate()
        let spawned = EventGate()
        // The relay ends at once; the hook holds the accept loop until the connection has been unregistered, which is
        // exactly the interleaving that used to leave a stale entry behind (insert after the task removed itself).
        let forwarder = try PortForwarder(
            client: EngineClient(socketPath: "/nonexistent.sock"), container: "none", containerPort: 1, maxConnections: 4,
            relay: { _, _ in await relayed.signal() },
            afterSpawn: { [spawned, ended] in
                await spawned.signal()
                await ended.wait(for: await spawned.value)
            },
            onEnded: { await ended.signal() })
        let loop = Task { await forwarder.run() }
        defer { forwarder.stop(); loop.cancel() }
        for _ in 0..<40 {
            #expect(Self.connectAndReadToEnd(forwarder.hostPort))
        }
        #expect(await relayed.value == 40, "every connection was admitted and relayed, far past the limit of 4")
        #expect(forwarder.activeConnections == 0)
    }

    @Test func admissionIsBoundedAndStopClosesActivePeers() async throws {
        let started = EventGate()
        let forwarder = try PortForwarder(
            client: EngineClient(socketPath: "/nonexistent.sock"), container: "none", containerPort: 1, maxConnections: 3,
            relay: { _, peer in
                await started.signal()
                while let data = try? await peer.read(), !data.isEmpty {}
            },
            afterSpawn: nil)
        let loop = Task { await forwarder.run() }
        defer { loop.cancel() }
        let clients = (0..<3).map { _ in Self.connect(forwarder.hostPort) }
        await started.wait(for: 3)
        #expect(forwarder.activeConnections == 3)
        // A fourth is closed at once (over the limit).
        #expect(Self.connectAndReadToEnd(forwarder.hostPort))
        #expect(await started.value == 3)
        forwarder.stop()
        for fd in clients {
            var byte: UInt8 = 0
            #expect(read(fd, &byte, 1) == 0, "the peer sees end of stream after stop")
            close(fd)
        }
    }
}
