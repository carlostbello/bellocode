import Darwin
import Dispatch
import Foundation
import Synchronization

@testable import ContainerKit

/// An in-process HTTP/1.1 server on a unix socket, standing in for the Docker daemon. Each connection's request is
/// parsed and handed to `handler`, which writes whatever bytes it wants (including a 101 and a raw stream).
final class FakeEngineServer: Sendable {
    struct Request: Sendable {
        var method: String
        var target: String
        var headers: [String: String]
        var body: Data
        var path: String { String(target.split(separator: "?").first ?? "") }
    }

    typealias Handler = @Sendable (Request, FileStream) async throws -> Void

    let path: String
    private let listener: Int32
    private let handler: Handler
    let requests = Mutex<[Request]>([])
    private let queue = DispatchQueue(label: "fake-engine.accept")
    private let stopped = Mutex(false)

    init(handler: @escaping Handler) throws {
        path = "/tmp/bcck-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        self.handler = handler
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else { throw SocketError.system(operation: "bind", errno: errno) }
        let listener = listener
        queue.async { [self] in
            while !stopped.withLock({ $0 }) {
                var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                if poll(&pfd, 1, 100) <= 0 { continue }
                let fd = accept(listener, nil, nil)
                if fd < 0 { continue }
                // A write after the client hung up must fail, not raise SIGPIPE (which ends the whole test process).
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                let stream = FileStream(fd: fd, owned: true, isSocket: true)
                Task { await self.serve(stream) }
            }
        }
    }

    func stop() {
        stopped.withLock { $0 = true }
        close(listener)
        unlink(path)
    }

    var client: EngineClient { EngineClient(socketPath: path) }

    private func serve(_ stream: FileStream) async {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.range(of: terminator) == nil {
            guard let data = try? await stream.read(), !data.isEmpty else { return }
            buffer.append(data)
        }
        let range = buffer.range(of: terminator)!
        let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
        var body = Data(buffer[range.upperBound...])
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        while body.count < length {
            guard let data = try? await stream.read(), !data.isEmpty else { break }
            body.append(data)
        }
        let request = Request(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: body)
        requests.withLock { $0.append(request) }
        try? await handler(request, stream)
        stream.cancel()
    }
}

extension FileStream {
    func respond(_ status: Int, json: String? = nil, headers: [String: String] = [:]) async throws {
        var text = "HTTP/1.1 \(status) X\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        let body = Data((json ?? "").utf8)
        if json != nil { text += "Content-Type: application/json\r\n" }
        text += "Content-Length: \(body.count)\r\n\r\n"
        try await write(Data(text.utf8) + body)
    }

    func respondChunked(_ status: Int, chunks: [Data]) async throws {
        try await write(Data("HTTP/1.1 \(status) OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        for chunk in chunks {
            try await write(Data(String(chunk.count, radix: 16).utf8) + Data("\r\n".utf8) + chunk + Data("\r\n".utf8))
        }
        try await write(Data("0\r\n\r\n".utf8))
    }
}
