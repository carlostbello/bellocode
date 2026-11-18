import BelloCore
import ContainerKit
import Darwin
import Foundation
import Security
import Synchronization
import os

/// Answers BelloCode's git credential helper (`GitCredentialHelper`) with the person's GitLab token, only for git
/// processes the app launched (docs/features/git-parity.md, "HTTPS credentials").
///
/// Guarantees (each is tested in `GitCredentialTests`):
/// 1. **Only granted processes.** A grant is a 32-byte random identifier registered by `GitRunner` before it launches
///    one authenticated git, bound to that git's process ID once launched, and revoked when it exits (or after 10
///    minutes, or 8 answers). The peer of every connection must descend from the granted process (checked with
///    `LOCAL_PEERPID` and the kernel's parent chain), so another process that learns a grant cannot use it.
/// 2. **Only the configured instances, only HTTPS.** The request's protocol must be `https` and its host and port one
///    of the grant's origins, which come from Settings ▸ GitLab. Anything else gets no answer.
/// 3. **Token read per request** from the Keychain (`tokens`), sent once over a socket in a 0700 folder of the app's
///    temporary directory, never written, logged or kept.
/// 4. **Refusals are recorded** per grant (reason only), and `erase` from git (the server rejected the token) is
///    recorded as `rejected`, so the caller can tell the person why authentication failed.
public final class GitCredentialBroker: Sendable {
    public struct Origin: Hashable, Sendable {
        public var host: String
        public var port: Int
        public init(host: String, port: Int) {
            self.host = host.lowercased()
            self.port = port
        }
        public init?(instance: GitLabInstance) {
            guard !instance.isPlainHTTP, let host = URL(string: instance.baseURL)?.host() else { return nil }
            self.init(host: host, port: instance.effectivePort)
        }
        /// git's `host` field: `name` or `name:port`.
        public init?(gitHost: String) {
            var host = gitHost
            var port = 443
            if let colon = gitHost.lastIndex(of: ":"), !gitHost.hasSuffix("]"), let value = Int(gitHost[gitHost.index(after: colon)...]) {
                host = String(gitHost[..<colon])
                port = value
            }
            guard !host.isEmpty else { return nil }
            self.init(host: host, port: port)
        }
    }

    public enum Outcome: Sendable, Equatable {
        case answered
        case refused(String)
        /// git reported that the server rejected the token (`erase` after an answer).
        case rejected
    }

    /// A one-shot permission for one git process.
    public struct Grant: Sendable, Hashable {
        public let identifier: String
    }

    struct GrantState {
        var origins: Set<Origin>
        var pid: pid_t?
        var created: ContinuousClock.Instant
        var answers = 0
        var outcomes: [Outcome] = []
        var revoked = false
    }

    struct State {
        var grants: [String: GrantState] = [:]
        var instances: [GitLabInstance] = []
    }

    static let log = Logger(subsystem: "dev.bellocode.engine", category: "git-credential")
    public static let grantLifetime: Duration = .seconds(600)
    public static let maxAnswers = 8
    static let maxGrants = 64

    public let socketPath: String
    private let directory: String
    private let tokens: any SecretVault
    private let state = Mutex(State())
    private let listener: Int32
    private let queue = DispatchQueue(label: "dev.bellocode.git-credential", attributes: .concurrent)
    private let source: any DispatchSourceRead

    /// Starts listening in a new private folder under `temporaryDirectory`. Throws when the socket cannot be made.
    public init(tokens: any SecretVault, temporaryDirectory: String = NSTemporaryDirectory()) throws {
        self.tokens = tokens
        var random = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        let folder = (temporaryDirectory as NSString).appendingPathComponent("bc-git-" + random.map { String(format: "%02x", $0) }.joined())
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = folder
        socketPath = folder + "/c"
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = GitCredentialHelper.unixAddress(socketPath) else { throw GitError.launchFailed("credential socket") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw GitError.launchFailed("credential socket")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
        try? FileManager.default.removeItem(atPath: directory)
    }

    // MARK: Configuration

    /// The GitLab instances the helper may answer for (Settings ▸ GitLab).
    public func setInstances(_ instances: [GitLabInstance]) { state.withLock { $0.instances = instances } }
    public var instances: [GitLabInstance] { state.withLock { $0.instances } }

    /// The instance a URL belongs to (HTTPS, same host and port, path under its prefix), if configured.
    public func instance(forURL url: String) -> GitLabInstance? {
        guard let parsed = GitRemoteURL(url), parsed.scheme == "https" else { return nil }
        return instances.filter { instance in
            guard let origin = Origin(instance: instance) else { return false }
            let prefix = instance.pathPrefix
            return origin == Origin(host: parsed.host, port: parsed.port) && (prefix.isEmpty || parsed.path.hasPrefix(prefix + "/"))
        }.max { $0.pathPrefix.count < $1.pathPrefix.count }
    }

    // MARK: Grants

    /// Registers a grant for `origins` (call `bind` once the process runs, `revoke` when it ends).
    public func grant(origins: Set<Origin>) -> Grant {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let identifier = bytes.map { String(format: "%02x", $0) }.joined()
        state.withLock { state in
            state.grants = state.grants.filter { !$0.value.revoked && ContinuousClock.now - $0.value.created < Self.grantLifetime }
            if state.grants.count >= Self.maxGrants, let oldest = state.grants.min(by: { $0.value.created < $1.value.created })?.key {
                state.grants.removeValue(forKey: oldest)
            }
            state.grants[identifier] = GrantState(origins: origins, created: .now)
        }
        return Grant(identifier: identifier)
    }

    public func bind(_ grant: Grant, pid: pid_t) { state.withLock { $0.grants[grant.identifier]?.pid = pid } }

    /// Ends the grant; returns what happened under it.
    @discardableResult
    public func revoke(_ grant: Grant) -> [Outcome] {
        state.withLock { $0.grants.removeValue(forKey: grant.identifier)?.outcomes ?? [] }
    }

    func inspect<T>(_ read: (State) -> T) -> T { state.withLock { read($0) } }

    public func outcomes(_ grant: Grant) -> [Outcome] { state.withLock { $0.grants[grant.identifier]?.outcomes ?? [] } }

    // MARK: Serving

    private func acceptPending() {
        while true {
            let connection = accept(listener, nil, nil)
            if connection < 0 { return }
            queue.async { [weak self] in
                defer { close(connection) }
                self?.serve(connection)
            }
        }
    }

    private func serve(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var peer: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0,
              let data = GitCredentialHelper.readAll(fd, limit: GitCredentialHelper.messageLimit)
        else { return }
        let request = GitCredentialHelper.parse(data)
        guard let reply = answer(request, peer: peer) else { return }
        _ = GitCredentialHelper.writeAll(fd, reply)
    }

    /// The reply for one request (nil: no answer). Internal for tests.
    func answer(_ request: [String: String], peer: pid_t) -> Data? {
        guard let identifier = request["grant"], let operation = request["operation"] else { return nil }
        // The process ID is bound right after launch; a very early request waits for it briefly.
        var bound: GrantState?
        for _ in 0..<200 {
            bound = state.withLock { $0.grants[identifier] }
            if bound == nil || bound?.pid != nil { break }
            usleep(10_000)
        }
        guard let grant = bound, !grant.revoked, ContinuousClock.now - grant.created < Self.grantLifetime, let pid = grant.pid else {
            Self.log.notice("credential request without a valid grant")
            return nil
        }
        func refuse(_ reason: String) -> Data? {
            state.withLock { $0.grants[identifier]?.outcomes.append(.refused(reason)) }
            Self.log.notice("credential request refused: \(reason, privacy: .public)")
            return nil
        }
        guard Self.descends(peer, from: pid) else { return refuse("not a process BelloCode launched") }
        if operation == "erase" {
            state.withLock { state in
                if state.grants[identifier]?.outcomes.contains(.answered) == true { state.grants[identifier]?.outcomes.append(.rejected) }
            }
            return nil
        }
        guard operation == "get" else { return nil }
        guard request["protocol"] == "https" else { return refuse("not HTTPS") }
        guard let host = request["host"], let origin = Origin(gitHost: host), grant.origins.contains(origin) else {
            return refuse("host is not a configured GitLab instance")
        }
        let instance = instances.first { Origin(instance: $0) == origin }
        guard let instance else { return refuse("host is not a configured GitLab instance") }
        let allowed = state.withLock { state -> Bool in
            guard state.grants[identifier] != nil, state.grants[identifier]!.answers < Self.maxAnswers else { return false }
            state.grants[identifier]!.answers += 1
            return true
        }
        guard allowed else { return refuse("too many requests") }
        guard let token = (try? tokens.read(account: instance.baseURL)) ?? nil, !token.isEmpty,
              let password = String(data: token.utf8, encoding: .utf8)
        else { return refuse("no token for \(instance.host)") }
        state.withLock { $0.grants[identifier]?.outcomes.append(.answered) }
        // GitLab accepts any non-empty username with a personal access token (docs.gitlab.com, personal access tokens).
        return GitCredentialHelper.encode([("username", "bellocode"), ("password", password)])
    }

    /// Whether `pid` is `ancestor` or one of its descendants (at most 16 levels).
    static func descends(_ pid: pid_t, from ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<16 {
            if current == ancestor { return true }
            guard current > 1, let parent = parentProcess(current) else { return false }
            current = parent
        }
        return false
    }

    static func parentProcess(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

/// A git remote URL: `https://[user@]host[:port]/path`, `ssh://[user@]host[:port]/path` or scp-like `user@host:path`.
public struct GitRemoteURL: Hashable, Sendable {
    public var scheme: String
    public var user: String?
    public var host: String
    public var port: Int
    /// Without the leading slash (`group/project.git`).
    public var path: String

    public init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("://") {
            guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty
            else { return nil }
            self.scheme = scheme
            user = components.user
            self.host = host.lowercased()
            port = components.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 22)
            path = String(components.path.drop { $0 == "/" })
        } else {
            // scp-like: [user@]host:path (no slash before the colon).
            guard let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/"), !text[..<colon].isEmpty else { return nil }
            let authority = text[..<colon]
            scheme = "ssh"
            if let at = authority.lastIndex(of: "@") {
                user = String(authority[..<at])
                host = authority[authority.index(after: at)...].lowercased()
            } else {
                user = nil
                host = authority.lowercased()
            }
            port = 22
            path = String(text[text.index(after: colon)...].drop { $0 == "/" })
        }
        guard !path.isEmpty else { return nil }
    }

    public var isSSH: Bool { scheme == "ssh" || scheme == "git+ssh" || scheme == "ssh+git" }

    /// `group/project` (no `.git`).
    public var projectPath: String { path.hasSuffix(".git") ? String(path.dropLast(4)) : path }

    /// The HTTPS URL of the same project on `instance` (for "Switch Remote to HTTPS"), when the host matches.
    public func httpsEquivalent(on instance: GitLabInstance) -> String? {
        guard isSSH || scheme == "https", host == instance.host.lowercased() else { return nil }
        let prefix = instance.pathPrefix
        let relative = prefix.isEmpty || path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.isEmpty ? 0 : prefix.count + 1)) : path
        let project = relative.hasSuffix(".git") ? String(relative.dropLast(4)) : relative
        return instance.baseURL + "/" + project + ".git"
    }
}

/// Which token scopes a git operation needs over HTTPS (docs.gitlab.com/user/profile/personal_access_tokens: "To
/// clone, fetch, and pull, use a token with the read_repository scope. To push, use a token with the
/// write_repository scope. The api scope also grants these permissions." `read_api` does not).
public enum GitTokenScopes {
    public enum Need: Sendable { case read, write }

    /// nil when `scopes` suffice or are unknown; otherwise the sentence to show.
    public static func problem(_ need: Need, scopes: [String]?) -> String? {
        guard let scopes else { return nil }
        let set = Set(scopes)
        if set.contains("api") { return nil }
        switch need {
        case .read:
            if set.contains("read_repository") || set.contains("write_repository") { return nil }
            return "Your GitLab token cannot read repositories over HTTPS. Create a token with the read_repository and write_repository scopes (or api) and replace it in Settings ▸ GitLab."
        case .write:
            if set.contains("write_repository") { return nil }
            return "Your GitLab token cannot push over HTTPS. Create a token with the write_repository scope (or api) and replace it in Settings ▸ GitLab."
        }
    }
}
