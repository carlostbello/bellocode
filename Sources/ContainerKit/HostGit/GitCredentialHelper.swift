import Darwin
import Foundation

/// BelloCode's own git credential helper (docs/features/git-parity.md, "HTTPS credentials").
///
/// git asks a helper for a username and password when an HTTPS server answers 401. For the configured GitLab
/// instances, the only helper git may ask is this one (`HostGit` resets the helper list for each exact remote URL
/// and adds `bellocode-exec --git-credential`), and it answers only for a git process the app itself launched:
///
/// - the app (`GitCredentialBroker`, Engine) listens on a Unix socket in a private per-launch folder (0700);
/// - before launching an authenticated git, the app registers a one-shot *grant* bound to the allowed installations and,
///   once launched, to that git's process ID; the grant's random identifier and the socket path are put in that git's
///   environment only (never opencode's, never a container's, never an agent shell's);
/// - this helper forwards git's request plus the grant to the socket; the broker checks the grant, that the peer
///   process descends from the granted git, that the request is `https` to an allowed origin, then reads the token
///   from the Keychain and answers. The grant ends when git exits.
///
/// The token therefore travels Keychain → app → socket → helper → git's memory, and nowhere else: not in arguments,
/// environment, `.git/config`, remote URLs, logs or the transcript. `store` and `erase` are never passed to another
/// helper (there is none for these URLs); `erase` (git saying the server rejected the answer) is reported to the
/// broker so the app can say the token was refused.
public enum GitCredentialHelper {
    /// The argument that selects helper mode in `bellocode-exec`.
    public static let modeArgument = "--git-credential"
    public static let socketVariable = "BELLOCODE_GIT_CREDENTIAL_SOCKET"
    public static let grantVariable = "BELLOCODE_GIT_CREDENTIAL_GRANT"
    /// The most a request or answer may be (git's own requests are a few hundred bytes).
    public static let messageLimit = 16 << 10

    /// The `credential.<url>.helper` value: a shell snippet (git runs helpers through `sh`), the path single-quoted.
    public static func helperValue(path: String) -> String {
        "!'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' " + modeArgument
    }

    // MARK: git's credential format

    /// `key=value` lines up to a blank line or the end (git's credential protocol). Unknown keys are kept; a key that
    /// repeats keeps its last value except `capability[]`/`wwwauth[]`, which are dropped.
    public static func parse(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for line in String(decoding: data.prefix(messageLimit), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { break }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            if key.hasSuffix("[]") { continue }
            result[key] = String(line[line.index(after: equals)...])
        }
        return result
    }

    /// Encodes `fields` in git's format (values with a newline or NUL are refused by dropping the field).
    public static func encode(_ fields: [(String, String)]) -> Data {
        var text = ""
        for (key, value) in fields where !value.contains("\n") && !value.contains("\0") && !key.contains("=") {
            text += "\(key)=\(value)\n"
        }
        return Data((text + "\n").utf8)
    }

    // MARK: Helper process

    /// `bellocode-exec --git-credential <get|store|erase>`. Never returns. Prints nothing (git then tries no one
    /// else and fails) unless the broker answers.
    public static func main(arguments: [String], environment: [String: String]) -> Never {
        let operation = arguments.first ?? ""
        let input = FileHandle.standardInput.readData(ofLength: messageLimit)
        guard ["get", "erase", "store"].contains(operation),
              let socket = environment[socketVariable], let grant = environment[grantVariable], !grant.isEmpty
        else { exit(0) }
        // `store` carries the password back: nothing to do (the app already has it), and it is never forwarded.
        if operation == "store" { exit(0) }
        var request = parse(input)
        request.removeValue(forKey: "password")
        var fields: [(String, String)] = [("operation", operation), ("grant", grant)]
        for key in ["protocol", "host", "path", "username"] { if let value = request[key] { fields.append((key, value)) } }
        guard let reply = exchange(socketPath: socket, message: encode(fields)) else { exit(0) }
        if operation == "get" {
            let answer = parse(reply)
            if let username = answer["username"], let password = answer["password"] {
                FileHandle.standardOutput.write(encode([("username", username), ("password", password)]))
            }
        }
        exit(0)
    }

    /// One request/answer over the Unix socket (5 s limit each way). nil on any failure.
    public static func exchange(socketPath: String, message: Data) -> Data? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        guard var address = unixAddress(socketPath) else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, writeAll(fd, message) else { return nil }
        shutdown(fd, SHUT_WR)
        return readAll(fd, limit: messageLimit)
    }

    // MARK: Socket utilities (shared with the broker)

    public static func unixAddress(_ path: String) -> sockaddr_un? {
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

    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written <= 0 {
                    if written < 0, errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    /// Reads until the peer closes, a blank line ends a message, or `limit` (nil when the limit is exceeded).
    public static func readAll(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return data }
            data.append(contentsOf: buffer[0..<count])
            if data.count > limit { return nil }
            if data.count >= 2, data.suffix(2) == Data([10, 10]) { return data }
            if data == Data([10]) { return data }
        }
    }
}

/// What one authenticated git launch needs from `HostGit`: the helper, the socket and grant (environment of that git
/// only), and the exact remote URLs whose credential and connection settings BelloCode pins.
public struct GitCredentialSetup: Sendable, Hashable {
    /// `bellocode-exec` (the helper); allowed to execute inside the network sandbox.
    public var helperPath: String
    public var socketPath: String
    public var grant: String
    /// Exact remote URLs on configured instances (as git will see them, after `insteadOf`).
    public var urls: [String]
    /// Remotes whose `remote.<name>.proxy` is reset (a repository could route a remote through its own proxy).
    public var remoteNames: [String]

    public init(helperPath: String, socketPath: String, grant: String, urls: [String], remoteNames: [String]) {
        self.helperPath = helperPath
        self.socketPath = socketPath
        self.grant = grant
        self.urls = urls
        self.remoteNames = remoteNames
    }

    /// Configuration for each URL, read after every file and with the same URL specificity as anything a repository
    /// can write (an exact URL cannot be out-matched), so these win:
    /// - `credential.<url>.helper` reset, then only BelloCode's helper (a repository's own helper for the same URL would
    ///   otherwise be asked first and receive the password on `store`);
    /// - TLS verification on, no proxy, no `curloptResolve` host mapping, no extra headers: a repository cannot send
    ///   the request (and the token) anywhere but the instance itself.
    public var overrides: [(String, String)] {
        var pairs: [(String, String)] = []
        for url in urls {
            pairs += [
                ("credential.\(url).helper", ""),
                ("credential.\(url).helper", GitCredentialHelper.helperValue(path: helperPath)),
                // git sends the repository path, so the broker can tell installations behind one host apart.
                ("credential.\(url).useHttpPath", "true"),
                ("http.\(url).sslVerify", "true"),
                ("http.\(url).proxy", ""),
                ("http.\(url).curloptResolve", ""),
                ("http.\(url).extraHeader", ""),
                ("http.\(url).emptyAuth", "false"),
            ]
        }
        for name in remoteNames { pairs.append(("remote.\(name).proxy", "")) }
        return pairs
    }
}
