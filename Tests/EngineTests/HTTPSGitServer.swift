import ContainerKit
import Foundation
import Network
import Security
import Synchronization

/// A local HTTPS git server for tests: bare repositories under `root`, served by git's own `http-backend` (CGI) behind
/// an in-process TLS listener on 127.0.0.1, requiring HTTP Basic authentication with `password` (any username, as
/// GitLab does for personal access tokens). The certificate is a throwaway CA + leaf made with the system's
/// `/usr/bin/openssl` (test infrastructure only); `caFile` is what git is told to trust.
final class HTTPSGitServer: Sendable {
    let base: String
    let root: String
    let caFile: String
    let password: String
    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.https-git", attributes: .concurrent)
    /// Every request: method, path, whether it carried the right credentials, and its Authorization header's username.
    struct Request: Sendable { var method: String; var path: String; var authorized: Bool; var hadAuthorization: Bool }
    final class Log: Sendable {
        let entries = Mutex<[Request]>([])
    }
    let log = Log()
    func recorded() -> [Request] { log.entries.withLock { $0 } }

    var url: String { "https://127.0.0.1:\(port)" }

    init(password: String) throws {
        self.password = password
        base = HostGit.canonical(FileManager.default.temporaryDirectory.appending(path: "bellocode-https-\(UUID().uuidString)").path)
        root = base + "/repos"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        caFile = base + "/ca.pem"
        let identity = try Self.makeIdentity(in: base)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        let portBox = Mutex<UInt16>(0)
        listener.stateUpdateHandler = { [listener] state in
            if case .ready = state {
                portBox.withLock { $0 = listener.port?.rawValue ?? 0 }
                ready.signal()
            }
            if case .failed = state { ready.signal() }
        }
        let handler = Handler(root: root, password: password)
        let log = self.log
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            handler.serve(connection) { request in log.entries.withLock { $0.append(request) } }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 10)
        port = portBox.withLock { $0 }
        if port == 0 { throw CocoaError(.featureUnsupported) }
    }

    func stop() {
        listener.cancel()
        try? FileManager.default.removeItem(atPath: base)
    }

    /// Creates a bare repository `name` (for example `group/project.git`), optionally seeded from `seed` (a path).
    func makeRepository(_ name: String, seed: String? = nil) throws {
        let path = root + "/" + name
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let seed {
            try Self.git(["clone", "-q", "--bare", seed, path])
        } else {
            try Self.git(["init", "-q", "--bare", "-b", "main", path])
        }
        try Self.git(["config", "http.receivepack", "true"], in: path)
    }

    static func git(_ arguments: [String], in directory: String? = nil) throws {
        let process = Process()
        process.standardInput = FileHandle.nullDevice
        process.executableURL = URL(filePath: HostGit.realGit() ?? "/usr/bin/git")
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(filePath: directory) }
        process.environment = ["HOME": NSTemporaryDirectory(), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "PATH": HostGit.fixedPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        done.wait()
        if process.terminationStatus != 0 { throw CocoaError(.executableLoad) }
    }

    // MARK: Certificate

    static func makeIdentity(in folder: String) throws -> SecIdentity {
        let openssl = "/usr/bin/openssl"
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.standardInput = FileHandle.nullDevice
            process.executableURL = URL(filePath: openssl)
            process.arguments = arguments
            process.currentDirectoryURL = URL(filePath: folder)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            done.wait()
            if process.terminationStatus != 0 { throw CocoaError(.executableLoad, userInfo: ["arguments": arguments.joined(separator: " ")]) }
        }
        try Data("subjectAltName=IP:127.0.0.1,DNS:localhost\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n".utf8)
            .write(to: URL(filePath: folder + "/leaf.ext"))
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "30", "-subj", "/CN=BelloCode Test CA"])
        try run(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "leaf.key", "-out", "leaf.csr", "-subj", "/CN=127.0.0.1"])
        try run(["x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "leaf.pem", "-days", "30", "-extfile", "leaf.ext"])
        try run(["pkcs12", "-export", "-inkey", "leaf.key", "-in", "leaf.pem", "-out", "leaf.p12", "-passout", "pass:test"])
        let data = try Data(contentsOf: URL(filePath: folder + "/leaf.p12"))
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: "test", kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first, let identity = first[kSecImportItemIdentity as String]
        else { throw CocoaError(.coderInvalidValue) }
        return identity as! SecIdentity
    }

    // MARK: HTTP

    /// One request per connection (`Connection: close`), body by Content-Length or chunked, answered by http-backend.
    final class Handler: Sendable {
        let root: String
        let password: String
        init(root: String, password: String) {
            self.root = root
            self.password = password
        }

        final class Buffer: Sendable { let data = Mutex(Data()) }

        func serve(_ connection: NWConnection, record: @escaping @Sendable (Request) -> Void) {
            receive(connection, buffer: Buffer(), record: record)
        }

        func receive(_ connection: NWConnection, buffer: Buffer, record: @escaping @Sendable (Request) -> Void) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let data { buffer.data.withLock { $0.append(data) } }
                let current = buffer.data.withLock { $0 }
                if let parsed = Self.parse(current) {
                    self.respond(parsed, connection: connection, record: record)
                } else if complete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer, record: record)
                }
            }
        }

        struct Parsed { var method: String; var target: String; var headers: [String: String]; var body: Data }

        static func parse(_ data: Data) -> Parsed? {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let parts = head.first?.split(separator: " ") ?? []
            guard parts.count >= 2 else { return nil }
            var headers: [String: String] = [:]
            for line in head.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            var rest = Data(data[end.upperBound...])
            if let length = headers["content-length"].flatMap(Int.init) {
                guard rest.count >= length else { return nil }
                return Parsed(method: String(parts[0]), target: String(parts[1]), headers: headers, body: rest.prefix(length))
            }
            if headers["transfer-encoding"]?.lowercased() == "chunked" {
                var body = Data()
                while true {
                    guard let lineEnd = rest.range(of: Data("\r\n".utf8)) else { return nil }
                    let size = Int(String(decoding: rest[..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? "", radix: 16) ?? 0
                    let start = lineEnd.upperBound
                    if size == 0 { return Parsed(method: String(parts[0]), target: String(parts[1]), headers: headers, body: body) }
                    guard rest.count >= rest.distance(from: rest.startIndex, to: start) + size + 2 else { return nil }
                    body.append(rest[start..<rest.index(start, offsetBy: size)])
                    rest = Data(rest[rest.index(start, offsetBy: size + 2)...])
                }
            }
            return Parsed(method: String(parts[0]), target: String(parts[1]), headers: headers, body: Data())
        }

        func respond(_ request: Parsed, connection: NWConnection, record: @escaping @Sendable (Request) -> Void) {
            let authorization = request.headers["authorization"]
            var authorized = false
            if let authorization, authorization.hasPrefix("Basic "),
               let decoded = Data(base64Encoded: String(authorization.dropFirst(6))).map({ String(decoding: $0, as: UTF8.self) }),
               let colon = decoded.firstIndex(of: ":")
            {
                authorized = !decoded[..<colon].isEmpty && String(decoded[decoded.index(after: colon)...]) == password
            }
            let path = String(request.target.split(separator: "?", maxSplits: 1).first ?? "")
            record(Request(method: request.method, path: path, authorized: authorized, hadAuthorization: authorization != nil))
            var response: Data
            if !authorized {
                response = Data("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"GitLab\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            } else {
                response = cgi(request, path: path)
            }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }

        func cgi(_ request: Parsed, path: String) -> Data {
            let query = request.target.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let process = Process()
            process.executableURL = URL(filePath: HostGit.realGit() ?? "/usr/bin/git")
            process.arguments = ["http-backend"]
            var environment = [
                "GIT_PROJECT_ROOT": root, "GIT_HTTP_EXPORT_ALL": "1", "PATH_INFO": path, "REQUEST_METHOD": request.method,
                "QUERY_STRING": query, "REMOTE_USER": "tester", "REMOTE_ADDR": "127.0.0.1", "CONTENT_LENGTH": String(request.body.count),
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "HOME": NSTemporaryDirectory(), "PATH": HostGit.fixedPath,
            ]
            if let type = request.headers["content-type"] { environment["CONTENT_TYPE"] = type }
            if let encoding = request.headers["content-encoding"] { environment["HTTP_CONTENT_ENCODING"] = encoding }
            if let protocolHeader = request.headers["git-protocol"] { environment["GIT_PROTOCOL"] = protocolHeader }
            process.environment = environment
            let stdin = Pipe()
            let stdout = Pipe()
            // git http-backend may exit before reading the whole body: EPIPE, not SIGPIPE.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return Data("HTTP/1.1 500 Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8) }
            let body = request.body
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: body)
                try? stdin.fileHandleForWriting.close()
            }
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let separator = output.range(of: Data("\r\n\r\n".utf8)) ?? output.range(of: Data("\n\n".utf8))
            guard let separator else { return Data("HTTP/1.1 500 Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8) }
            var status = "200 OK"
            var headers = ""
            for line in String(decoding: output[..<separator.lowerBound], as: UTF8.self).split(whereSeparator: \.isNewline) {
                if line.lowercased().hasPrefix("status:") { status = line.dropFirst(7).trimmingCharacters(in: .whitespaces) } else { headers += line + "\r\n" }
            }
            let content = output[separator.upperBound...]
            return Data("HTTP/1.1 \(status)\r\n\(headers)Content-Length: \(content.count)\r\nConnection: close\r\n\r\n".utf8) + content
        }
    }
}
