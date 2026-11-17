import Darwin
import Dispatch
import Foundation
import Synchronization

/// Errors from the socket layer. Messages never contain payload bytes.
public enum SocketError: Error, Equatable, Sendable, CustomStringConvertible {
    case pathTooLong(Int)
    case system(operation: String, errno: Int32)
    case closed

    public var description: String {
        switch self {
        case .pathTooLong(let length): "socket path is \(length) bytes; the limit is 103"
        case .system(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
        case .closed: "connection closed"
        }
    }

    public var isConnectionRefusedOrMissing: Bool {
        if case .system("connect", let code) = self { return code == ECONNREFUSED || code == ENOENT }
        return false
    }
}

/// A blocking file descriptor driven from async code. Reads and writes run on their own serial queues so a blocked
/// read never holds a cooperative thread hostage for longer than the call; `cancel()` (or task cancellation) shuts the
/// descriptor down so a pending read returns. The descriptor is closed when the last reference goes away.
///
/// Reads must be issued by one consumer at a time (the HTTP reader serialises them); writes likewise.
public final class FileStream: Sendable {
    public let fd: Int32
    private let owned: Bool
    private let isSocket: Bool
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let cancelled = Mutex(false)

    public init(fd: Int32, owned: Bool, isSocket: Bool) {
        self.fd = fd
        self.owned = owned
        self.isSocket = isSocket
        readQueue = DispatchQueue(label: "bellocode.fd.read.\(fd)")
        writeQueue = DispatchQueue(label: "bellocode.fd.write.\(fd)")
    }

    deinit {
        if owned { Darwin.close(fd) }
    }

    /// Connects to a unix domain socket.
    public static func connect(unixPath path: String) throws -> FileStream {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError.pathTooLong(bytes.count) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system(operation: "socket", errno: errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        if result != 0 {
            let code = errno
            Darwin.close(fd)
            throw SocketError.system(operation: "connect", errno: code)
        }
        return FileStream(fd: fd, owned: true, isSocket: true)
    }

    public var isCancelled: Bool { cancelled.withLock { $0 } }

    /// Reads up to `maxLength` bytes. An empty result means end of stream.
    public func read(maxLength: Int = 64 * 1024) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                readQueue.async { [self] in
                    if isCancelled { return continuation.resume(returning: Data()) }
                    var buffer = Data(count: maxLength)
                    while true {
                        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, maxLength) }
                        if count >= 0 {
                            buffer.count = count
                            return continuation.resume(returning: buffer)
                        }
                        if errno == EINTR { continue }
                        if isCancelled || errno == ECONNRESET || errno == ENOTCONN || errno == EIO {
                            return continuation.resume(returning: Data())
                        }
                        return continuation.resume(throwing: SocketError.system(operation: "read", errno: errno))
                    }
                }
            }
        } onCancel: {
            cancel()
        }
    }

    /// Writes all of `data`.
    public func write(_ data: Data) async throws {
        if data.isEmpty { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writeQueue.async { [self] in
                do {
                    try writeAllBlocking(data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous write for callers that are already on a dedicated thread (signal handlers' queues, the helper).
    public func writeAllBlocking(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN {
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&pfd, 1, 100)
                        continue
                    }
                    throw SocketError.system(operation: "write", errno: errno)
                }
                offset += written
            }
        }
    }

    /// Half-close: the peer sees end of input (Docker forwards it to the process's stdin).
    public func shutdownWrite() {
        if isSocket { Darwin.shutdown(fd, SHUT_WR) }
    }

    /// Unblocks any pending read and refuses further reads.
    public func cancel() {
        let first = cancelled.withLock { value -> Bool in
            defer { value = true }
            return !value
        }
        if first, isSocket { Darwin.shutdown(fd, SHUT_RDWR) }
    }
}
