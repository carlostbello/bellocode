import Darwin
import Dispatch
import Foundation
import Synchronization

/// Forwards a host loopback port to a port inside the workspace container *without* publishing it: every accepted TCP
/// connection becomes one exec running a tiny relay that connects to `127.0.0.1:<port>` inside the container. It works
/// for ports chosen after the container was created and for servers that listen only on the container's loopback
/// (Vite, Next and many others do by default), which a published port cannot reach.
public final class PortForwarder: Sendable {
    public let client: EngineClient
    public let container: String
    public let containerPort: Int
    public let relay: [String]
    private let listener: FileStream
    public let hostPort: Int
    private let tasks = Mutex<[Int: Task<Void, Never>]>([:])
    private let counter = Mutex(0)
    private let acceptQueue = DispatchQueue(label: "bellocode.forward.accept")

    /// Relay argv run inside the container; `$1` is the port. Needs bash (for /dev/tcp) and cat: present in
    /// Debian/Ubuntu-based images. A production image ships a static relay instead (see the spike report).
    public static func bashRelay(port: Int) -> [String] {
        let script = """
        exec 3<>/dev/tcp/127.0.0.1/$1 || exit 7
        ( cat <&3; kill -TERM -$$ 2>/dev/null ) &
        cat >&3
        kill -TERM -$$ 2>/dev/null
        """
        return ["bash", "-c", script, "relay", String(port)]
    }

    public init(client: EngineClient, container: String, containerPort: Int, hostPort: Int = 0, relay: [String]? = nil) throws {
        self.client = client
        self.container = container
        self.containerPort = containerPort
        self.relay = relay ?? Self.bashRelay(port: containerPort)
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

    /// Accepts until `stop()`. Each connection is relayed by its own task, owned by this forwarder.
    public func run() async {
        while !Task.isCancelled, !listener.isCancelled {
            guard let fd = await accept() else { break }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let peer = FileStream(fd: fd, owned: true, isSocket: true)
            let id = counter.withLock { value -> Int in
                value += 1
                return value
            }
            let task = Task { [self] in
                await relayConnection(peer)
                _ = tasks.withLock { $0.removeValue(forKey: id) }
            }
            tasks.withLock { $0[id] = task }
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
        guard let session = try? await ExecSession.start(client: client, container: container, argv: relay,
                                                          workingDir: nil, environment: [:], tty: false) else {
            peer.cancel()
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // host → container
                while let data = try? await peer.read(), !data.isEmpty {
                    if (try? await session.write(data)) == nil { break }
                }
                session.closeStdin()
            }
            group.addTask {
                // container → host
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

    public var activeConnections: Int { tasks.withLock { $0.count } }

    public func stop() {
        listener.cancel()
        Darwin.shutdown(listener.fd, SHUT_RDWR)
        for task in tasks.withLock({ Array($0.values) }) { task.cancel() }
    }
}
