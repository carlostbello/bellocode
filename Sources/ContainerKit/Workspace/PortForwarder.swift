import Darwin
import Dispatch
import Foundation
import Synchronization
import os

private let signposter = OSSignposter(subsystem: "app.bellocode.ContainerKit", category: "forward")

/// Forwards a host loopback port to a port inside the workspace container *without* publishing it: every accepted TCP
/// connection becomes one exec running a relay (`ContainerProbes.relayScript`) that connects to the port on the
/// container's loopback. It needs no recreate or sidecar, works for ports chosen after the container was created, and
/// reaches servers that listen only on the container's loopback, which a published port cannot.
///
/// The host side listens on 127.0.0.1 only, so nothing on the network can reach it (unlike a Rancher Desktop published
/// port bound to 0.0.0.0, which is forwarded to every interface of the Mac). Connections are bounded (`maxConnections`);
/// beyond that a connection is closed at once. Each connection's task is owned by the forwarder and cancelled by `stop()`.
public final class PortForwarder: Sendable {
    public let client: EngineClient
    public let container: String
    public let containerPort: Int
    public let containerHost: String
    public let user: String?
    public let maxConnections: Int
    private let listener: FileStream
    public let hostPort: Int
    /// One accepted connection: its peer (closed by `stop()`) and, once spawned, its relay task.
    private struct Slot {
        var peer: FileStream
        var task: Task<Void, Never>?
    }

    /// Connections are registered *before* their relay task starts and removed by the task when it ends; a task that
    /// ends before it was stored is never stored (M4 in docs/reviews/M3-M6-review.md: the old order inserted after
    /// spawning, so a connection that finished at once left a stale entry and admission eventually stuck at the limit).
    private let slots = Mutex<[Int: Slot]>([:])
    private let counter = Mutex(0)
    /// Relays a connection; injected by tests (the default execs the relay in the container).
    private let relay: (@Sendable (PortForwarder, FileStream) async -> Void)?
    /// Test hook run after a relay task was spawned and before it is stored.
    let afterSpawn: (@Sendable () async -> Void)?
    /// Test hook run by a relay task after its connection was unregistered.
    let onEnded: (@Sendable () async -> Void)?
    private let served = Mutex(0)
    private let acceptQueue = DispatchQueue(label: "bellocode.forward.accept")

    /// - Parameters:
    ///   - containerHost: where the relay connects inside the container (`127.0.0.1`, or `::1` for an IPv6 listener).
    ///   - hostPort: 0 picks a free port; otherwise the same port number is tried (keeps URLs stable).
    public convenience init(client: EngineClient, container: String, containerPort: Int, containerHost: String = "127.0.0.1",
                            hostPort: Int = 0, user: String? = nil, maxConnections: Int = 64) throws {
        try self.init(client: client, container: container, containerPort: containerPort, containerHost: containerHost, hostPort: hostPort,
                      user: user, maxConnections: maxConnections, relay: nil, afterSpawn: nil, onEnded: nil)
    }

    init(client: EngineClient, container: String, containerPort: Int, containerHost: String = "127.0.0.1",
         hostPort: Int = 0, user: String? = nil, maxConnections: Int = 64,
         relay: (@Sendable (PortForwarder, FileStream) async -> Void)?, afterSpawn: (@Sendable () async -> Void)?,
         onEnded: (@Sendable () async -> Void)? = nil) throws {
        self.relay = relay
        self.afterSpawn = afterSpawn
        self.onEnded = onEnded
        self.client = client
        self.container = container
        self.containerPort = containerPort
        self.containerHost = containerHost
        self.user = user
        self.maxConnections = maxConnections
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system(operation: "socket", errno: errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(hostPort).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")  // loopback only
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            throw SocketError.system(operation: "bind", errno: code)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.hostPort = Int(UInt16(bigEndian: actual.sin_port))
        listener = FileStream(fd: fd, owned: true, isSocket: true)
    }

    /// `http://127.0.0.1:<hostPort>/`
    public var url: URL { URL(string: "http://127.0.0.1:\(hostPort)/")! }

    /// Accepts until `stop()` or cancellation. Each connection is relayed by its own task, owned by this forwarder.
    public func run() async {
        await withTaskCancellationHandler {
            while !Task.isCancelled, !listener.isCancelled {
                guard let fd = await accept() else { break }
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                let peer = FileStream(fd: fd, owned: true, isSocket: true)
                let id = counter.withLock { value -> Int in
                    value += 1
                    return value
                }
                // Admission and registration in one step, before anything runs.
                let admitted = slots.withLock { slots -> Bool in
                    guard slots.count < maxConnections else { return false }
                    slots[id] = Slot(peer: peer, task: nil)
                    return true
                }
                guard admitted else {
                    peer.cancel()
                    continue
                }
                let task = Task { [self] in
                    if let relay { await relay(self, peer) } else { await relayConnection(peer) }
                    peer.cancel()
                    _ = slots.withLock { $0.removeValue(forKey: id) }
                    await onEnded?()
                }
                await afterSpawn?()
                // Stored only while the connection is still registered (it may already have ended).
                slots.withLock { slots in
                    if slots[id] != nil { slots[id]?.task = task }
                }
            }
        } onCancel: {
            stop()
        }
    }

    private func accept() async -> Int32? {
        await withCheckedContinuation { continuation in
            acceptQueue.async { [listener] in
                while true {
                    // Poll so that `stop()` is noticed even where shutdown(2) does not wake accept(2).
                    var pfd = pollfd(fd: listener.fd, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&pfd, 1, 200)
                    if listener.isCancelled { return continuation.resume(returning: nil) }
                    if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                    let fd = Darwin.accept(listener.fd, nil, nil)
                    if fd >= 0 { return continuation.resume(returning: fd) }
                    if errno == EINTR { continue }
                    return continuation.resume(returning: nil)
                }
            }
        }
    }

    private func relayConnection(_ peer: FileStream) async {
        let state = signposter.beginInterval("connection")
        defer { signposter.endInterval("connection", state) }
        guard let session = try? await ExecSession.start(
            client: client, container: container, argv: ContainerProbes.relayScript(host: containerHost, port: containerPort),
            workingDir: nil, environment: [:], user: user, tty: false)
        else {
            peer.cancel()
            return
        }
        served.withLock { $0 += 1 }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // host → container
                while let data = try? await peer.read(), !data.isEmpty {
                    if (try? await session.write(data)) == nil { break }
                }
                session.closeStdin()
            }
            group.addTask {
                // container → host. stderr (the relay's own message) is dropped, never shown to the browser.
                do {
                    for try await chunk in session.output() where chunk.stream == .stdout {
                        try await peer.write(chunk.bytes)
                    }
                } catch {}
                peer.cancel()
                session.close()
            }
        }
    }

    public var activeConnections: Int { slots.withLock { $0.count } }
    /// Connections relayed so far.
    public var connectionCount: Int { served.withLock { $0 } }

    public func stop() {
        listener.cancel()
        Darwin.shutdown(listener.fd, SHUT_RDWR)
        // Close every active peer (its browser sees the connection end) and cancel the relays.
        for slot in slots.withLock({ Array($0.values) }) {
            slot.peer.cancel()
            slot.task?.cancel()
        }
    }
}
