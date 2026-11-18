import Foundation
import Network
import Synchronization

public struct WireError: Error, CustomStringConvertible, Sendable, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }
    static let closed = WireError("connection closed")
    static let tooLarge = WireError("message too large")
}

/// One NWConnection with a read buffer, used by one task at a time (the actor serialises the rest).
actor WireConnection {
    nonisolated let connection: NWConnection
    private var buffer = Data()
    private var finished = false
    private let queue: DispatchQueue
    /// Last read or write (the proxy's idle watchdog closes connections that stop moving).
    private(set) var lastActivity = ContinuousClock.now

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Starts the connection and waits until it is ready, fails, or stays `.waiting` (no path, refused) for longer
    /// than `waitingGrace`; loopback connects were seen to pass through `.waiting` for a moment.
    func start(waitingGrace: Duration = .seconds(2)) async throws {
        let once = Mutex(false)
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let finish: @Sendable (Result<Void, any Error>) -> Void = { result in
                guard once.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let error): finish(.failure(error))
                case .cancelled: finish(.failure(WireError.closed))
                case .waiting(let error):
                    Task {
                        try? await Task.sleep(for: waitingGrace)
                        if case .waiting = connection.state {
                            finish(.failure(error))
                            connection.cancel()
                        }
                    }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Bytes received but not consumed yet (handed on when a connection turns into a tunnel).
    func takeBuffer() -> Data {
        defer { buffer = Data() }
        return Data(buffer)
    }

    /// Receives more bytes into the buffer; false at end of stream.
    @discardableResult
    func receiveMore(maximum: Int = 256 * 1024) async throws -> Bool {
        if finished { return false }
        let (data, complete): (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let error, data == nil || data?.isEmpty == true {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
        lastActivity = .now
        if let data, !data.isEmpty { buffer.append(data) }
        if complete { finished = true }
        return (data?.isEmpty == false) || !complete
    }

    /// A message head (through the blank line), at most `limit` bytes; nil at a clean end of stream.
    func readHead(limit: Int = 64 * 1024) async throws -> Data? {
        while true {
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = Data(buffer[buffer.startIndex..<range.upperBound])
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return head
            }
            if buffer.count > limit { throw WireError.tooLarge }
            if !(try await receiveMore()) {
                if buffer.isEmpty { return nil }
                throw WireError.closed
            }
        }
    }

    /// One CRLF-terminated line (without the CRLF).
    func readLine(limit: Int = 8 * 1024) async throws -> String {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            if let range = buffer.range(of: Data("\n".utf8)) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            if buffer.count > limit { throw WireError.tooLarge }
            if !(try await receiveMore()) { throw WireError.closed }
        }
    }

    func read(exactly count: Int) async throws -> Data {
        while buffer.count < count {
            if !(try await receiveMore()) { throw WireError.closed }
        }
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }

    /// Whatever is buffered, or the next received bytes; nil at end of stream.
    func readSome() async throws -> Data? {
        if buffer.isEmpty, !(try await receiveMore()), buffer.isEmpty { return nil }
        return takeBuffer()
    }

    /// Everything until the peer closes, bounded.
    func readToEnd(limit: Int) async throws -> Data {
        while try await receiveMore() {
            if buffer.count > limit { throw WireError.tooLarge }
        }
        return takeBuffer()
    }

    func send(_ data: Data) async throws {
        lastActivity = .now
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Half-close for writing (end of a tunnelled stream).
    func sendEnd() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }

    nonisolated func cancel() { connection.cancel() }
}

/// A parsed HTTP/1.x message head.
public struct HTTPHead: Sendable {
    public var startLine: [String]
    public var fields: [HTTPField]
    public var version: String

    /// Parses a head (start line and fields). Obsolete line folding and stray whitespace before the colon are refused
    /// (request smuggling relies on parser disagreements).
    public init?(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        while lines.last == "" { lines.removeLast() }
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        startLine = parts
        var fields: [HTTPField] = []
        for line in lines.dropFirst() {
            if line.first == " " || line.first == "\t" { return nil }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon])
            guard !name.isEmpty, !name.contains(" "), !name.contains("\t") else { return nil }
            fields.append(HTTPField(name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        self.fields = fields
        version = parts[0].hasPrefix("HTTP/") ? parts[0] : parts[2]
    }

    public init(startLine: [String], fields: [HTTPField]) {
        self.startLine = startLine
        self.fields = fields
        version = startLine.first?.hasPrefix("HTTP/") == true ? startLine[0] : (startLine.last ?? "HTTP/1.1")
    }

    public var serialized: Data {
        var text = startLine.joined(separator: " ") + "\r\n"
        for field in fields { text += "\(field.name): \(field.value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    /// Body framing per RFC 9112: chunked, a length, or (responses only) until close. Conflicting or invalid framing is
    /// nil (refused).
    public enum Framing: Sendable, Equatable { case empty, length(Int), chunked, untilClose }

    public func requestFraming() -> Framing? {
        let transfer = fields.all("Transfer-Encoding").map { $0.lowercased() }
        let lengths = fields.all("Content-Length")
        if !transfer.isEmpty {
            guard lengths.isEmpty, transfer.joined(separator: ",").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) == ["chunked"] else { return nil }
            return .chunked
        }
        if lengths.isEmpty { return .empty }
        guard Set(lengths).count == 1, let length = Int(lengths[0]), length >= 0 else { return nil }
        return length == 0 ? .empty : .length(length)
    }

    public func responseFraming(requestMethod: String) -> Framing? {
        guard let status = Int(startLine.count > 1 ? startLine[1] : "") else { return nil }
        if requestMethod == "HEAD" || (100..<200).contains(status) || status == 204 || status == 304 { return .empty }
        let transfer = fields.all("Transfer-Encoding").map { $0.lowercased() }
        if !transfer.isEmpty {
            return transfer.joined(separator: ",").lowercased().hasSuffix("chunked") ? .chunked : .untilClose
        }
        let lengths = fields.all("Content-Length")
        if lengths.isEmpty { return .untilClose }
        guard Set(lengths).count == 1, let length = Int(lengths[0]), length >= 0 else { return nil }
        return .length(length)
    }
}

extension WireConnection {
    /// Reads a whole body per `framing` (chunked decoded), bounded.
    func readBody(_ framing: HTTPHead.Framing, limit: Int) async throws -> Data {
        switch framing {
        case .empty: return Data()
        case .length(let count):
            guard count <= limit else { throw WireError.tooLarge }
            return try await read(exactly: count)
        case .untilClose: return try await readToEnd(limit: limit)
        case .chunked:
            var body = Data()
            while true {
                let sizeLine = try await readLine()
                let sizeText = sizeLine.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(sizeText, radix: 16), size >= 0 else { throw WireError("invalid chunk size") }
                if size == 0 {
                    // Trailers until a blank line (dropped).
                    while !(try await readLine()).isEmpty {}
                    return body
                }
                guard body.count + size <= limit else { throw WireError.tooLarge }
                body.append(try await read(exactly: size))
                guard try await readLine().isEmpty else { throw WireError("invalid chunk") }
            }
        }
    }

    /// Copies a body per `framing` to `sink` without buffering it whole (unbound destinations).
    func relayBody(_ framing: HTTPHead.Framing, to sink: WireConnection) async throws {
        switch framing {
        case .empty: return
        case .length(var remaining):
            while remaining > 0 {
                if buffer.isEmpty, !(try await receiveMore()) { throw WireError.closed }
                let take = min(remaining, buffer.count)
                let piece = buffer.prefix(take)
                buffer.removeFirst(take)
                remaining -= take
                try await sink.send(Data(piece))
            }
        case .untilClose:
            while let piece = try await readSome() { try await sink.send(piece) }
        case .chunked:
            while true {
                let sizeLine = try await readLine()
                let sizeText = sizeLine.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(sizeText, radix: 16), size >= 0 else { throw WireError("invalid chunk size") }
                try await sink.send(Data("\(String(size, radix: 16))\r\n".utf8))
                if size == 0 {
                    while true {
                        let line = try await readLine()
                        try await sink.send(Data((line + "\r\n").utf8))
                        if line.isEmpty { return }
                    }
                }
                try await sink.send(try await read(exactly: size))
                _ = try await readLine()
                try await sink.send(Data("\r\n".utf8))
            }
        }
    }
}
