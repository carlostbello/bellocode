import Darwin
import Foundation
import Synchronization

/// How `bellocode-opencode` gets the running server's per-launch password without it ever being in a file
/// (docs/features/opencode-config.md, "Command-line tool"; A03 in docs/reviews/v1.0.0-astra-review.md).
///
/// The agent's host file tools (opencode's read, glob, grep, edit) run as this user and, in Full access, can read the
/// app's support folder. So the connection file names the server (URL, pid, version) but holds no secret. The password
/// is handed out by the app over a unix socket:
/// - in the per-user temporary folder (`confstr(_CS_DARWIN_USER_TEMP_DIR)`, mode 0700), under a name derived from
///   the data root, so both sides find it without reading anything an agent could write;
/// - the socket is 0600; a file tool cannot read a socket, and connecting needs code, which the agent only runs in
///   containers that do not mount this folder;
/// - each connection's peer must have this user's uid, and in a bundled build be the bundled `bellocode-opencode`
///   (its executable path, `LOCAL_PEERPID` + `proc_pidpath`); the client checks the server's uid in turn.
public final class CLIPasswordBroker: Sendable {
    public let socketPath: String
    private let reply: Data
    private let allowedPeers: Set<String>?
    private let listener: Int32
    private let queue = DispatchQueue(label: "dev.bellocode.cli-password")
    private let source: any DispatchSourceRead
    private let closed = Mutex(false)
    /// The socket file this broker created (device, inode), so `stop` never removes a newer broker's socket.
    private let identity: (dev: Int32, ino: UInt64)

    public enum BrokerError: Error, Sendable, Equatable, CustomStringConvertible {
        case socket(String)
        public var description: String { switch self { case .socket(let why): "CLI password socket: \(why)" } }
    }

    /// Starts listening for `directories`. `allowedPeers`: canonical executable paths allowed to connect (nil: any
    /// process of this user).
    public init(directories: OpenCodeDirectories, pid: Int32, password: String, allowedPeers: Set<String>?) throws(BrokerError) {
        guard let path = Self.socketPath(for: directories) else { throw .socket("no per-user temporary folder") }
        socketPath = path
        self.allowedPeers = allowedPeers
        var encoded = (try? JSONSerialization.data(withJSONObject: ["pid": Int(pid), "password": password])) ?? Data()
        encoded.append(0x0A)
        reply = encoded
        // A leftover socket (a crash) or a file planted at the path: remove it if it is ours, never follow a link.
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), (info.st_mode & S_IFMT) != S_IFDIR else { throw .socket("something else is at \(path)") }
            unlink(path)
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = Self.unixAddress(path) else { throw .socket("cannot create") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // No umask change: it is process-wide and would race other threads creating files. The folder is the user's
        // private 0700 temporary folder, and the socket is narrowed to 0600 right after bind.
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw .socket("cannot listen (errno \(errno))")
        }
        var made = stat()
        guard lstat(path, &made) == 0 else {
            close(fd)
            throw .socket("socket vanished")
        }
        identity = (made.st_dev, made.st_ino)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { stop() }

    /// Stops answering and removes the socket (only if it is still this broker's).
    public func stop() {
        let already = closed.withLock { value -> Bool in
            defer { value = true }
            return value
        }
        guard !already else { return }
        source.cancel()
        var current = stat()
        if lstat(socketPath, &current) == 0, current.st_dev == identity.dev, current.st_ino == identity.ino {
            unlink(socketPath)
        }
    }

    private func acceptPending() {
        while true {
            let connection = accept(listener, nil, nil)
            if connection < 0 { return }
            defer { close(connection) }
            serve(connection)
        }
    }

    private func serve(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        guard Self.peerAllowed(fd, allowedPeers: allowedPeers) else { return }
        _ = reply.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// The peer has this user's uid and, when `allowedPeers` is set, runs one of those executables.
    static func peerAllowed(_ fd: Int32, allowedPeers: Set<String>?) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
        guard let allowedPeers else { return true }
        var peer: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0, peer > 0,
              let path = executablePath(of: peer)
        else { return false }
        return allowedPeers.contains(path)
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return canonical(String(cString: buffer))
    }

    /// `path` with links resolved (the form `proc_pidpath` reports), or `path` when it does not exist.
    public static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Shared with the client

    /// `<per-user temp>/bc-cli-<hash of the data root>.sock`: short enough for `sun_path`, private to the user.
    public static func socketPath(for directories: OpenCodeDirectories) -> String? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 else { return nil }
        let folder = String(cString: buffer)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in directories.dataRoot.standardizedFileURL.path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        let name = "bc-cli-" + String(hash, radix: 16) + ".sock"
        return (folder as NSString).appendingPathComponent(name)
    }

    static func unixAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        return address
    }
}

/// The client side, used by `bellocode-opencode`.
public enum CLIPasswordClient {
    public enum FetchError: Error, Sendable, Equatable, CustomStringConvertible {
        case unavailable(String)
        public var description: String { switch self { case .unavailable(let why): "BelloCode did not hand over its server's password (\(why))" } }
    }

    /// The password of the server with `pid`, from the running app.
    public static func password(directories: OpenCodeDirectories, pid: Int32) throws(FetchError) -> String {
        guard let path = CLIPasswordBroker.socketPath(for: directories), var address = CLIPasswordBroker.unixAddress(path) else {
            throw .unavailable("no socket path")
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .unavailable("socket") }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw .unavailable("not answering") }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw .unavailable("socket owned by another user") }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while data.count < 8 * 1024 {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            data.append(contentsOf: chunk[0..<count])
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let password = object["password"] as? String, !password.isEmpty, let served = object["pid"] as? Int
        else { throw .unavailable("refused") }
        guard served == Int(pid) else { throw .unavailable("it serves another server") }
        return password
    }
}

/// The exclusive lifetime lease on one opencode data root (A13): BelloCode holds it from before it launches its server
/// until that server has exited, and `bellocode-opencode` holds it (across `execve`) while a private standalone server
/// runs. Whoever does not get it does not start a server on that data. `flock` on `<run>/opencode.lock`: released by
/// the kernel when the holder exits, so a crash never leaves it held.
public final class OpenCodeDataLock: Sendable {
    let fd: Int32
    private let released = Mutex(false)

    init(fd: Int32) { self.fd = fd }

    public enum LockError: Error, Sendable, Equatable, CustomStringConvertible {
        case unavailable(String)
        public var description: String { switch self { case .unavailable(let why): "cannot open opencode's data lock: \(why)" } }
    }

    public static func file(for directories: OpenCodeDirectories) -> URL { directories.runDirectory.appending(path: "opencode.lock") }

    /// The lease, or nil when another process holds it now.
    public static func tryAcquire(_ directories: OpenCodeDirectories) throws(LockError) -> OpenCodeDataLock? {
        let folder = directories.runDirectory
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw .unavailable("cannot create \(folder.path)")
        }
        let fd = open(file(for: directories).path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .unavailable("errno \(errno)") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            close(fd)
            throw .unavailable("the lock is not a private regular file")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let busy = errno == EWOULDBLOCK
            close(fd)
            if busy { return nil }
            throw .unavailable("errno \(errno)")
        }
        return OpenCodeDataLock(fd: fd)
    }

    /// Keeps the lease open in the program `execve` starts (the standalone opencode), so it lasts as long as that server.
    public func keepAcrossExec() { _ = fcntl(fd, F_SETFD, 0) }

    public func release() {
        let already = released.withLock { value -> Bool in
            defer { value = true }
            return value
        }
        if !already { close(fd) }
    }

    deinit { release() }
}
