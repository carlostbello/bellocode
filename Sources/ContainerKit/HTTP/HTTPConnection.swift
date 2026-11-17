import Foundation
import Synchronization

/// One HTTP/1.1 exchange on its own connection (the Engine API is cheap to connect to over a unix socket, and a
/// connection per request keeps hijacked and streaming responses independent). After a `101 Switching Protocols` or a
/// hijacked `200`, the same object becomes a raw bidirectional byte stream: `readRaw()` first drains bytes that arrived
/// with the head.
///
/// Reads are serialised by the caller (one reader at a time); writes may come from another task.
public final class HTTPConnection: Sendable {
    public let stream: FileStream
    private let pending = Mutex(Data())
    private let chunked = Mutex<ChunkedDecoder?>(nil)
    private let remainingLength = Mutex<Int?>(nil)
    private let finished = Mutex(false)

    public init(stream: FileStream) {
        self.stream = stream
    }

    public static func open(unixPath: String) throws -> HTTPConnection {
        HTTPConnection(stream: try FileStream.connect(unixPath: unixPath))
    }

    public func send(_ request: HTTPRequest) async throws {
        try await stream.write(request.serialized())
    }

    public func readHead() async throws -> HTTPResponseHead {
        while true {
            let head = try pending.withLock { buffer in try HTTPHeadParser.parse(&buffer) }
            if let head {
                switch head.framing {
                case .chunked: chunked.withLock { $0 = ChunkedDecoder() }
                case .length(let length): remainingLength.withLock { $0 = length }
                case .none: remainingLength.withLock { $0 = 0 }
                case .untilClose: break
                }
                return head
            }
            let data = try await stream.read()
            if data.isEmpty { throw HTTPParseError.unexpectedEnd }
            pending.withLock { $0.append(data) }
        }
    }

    /// The next piece of the decoded body, or nil at its end. Pull-driven: nothing is read from the socket until the
    /// consumer asks, so a slow consumer slows the daemon down instead of growing a buffer.
    public func nextBodyChunk() async throws -> Data? {
        if finished.withLock({ $0 }) { return nil }
        while true {
            // Serve what is already buffered.
            let buffered = pending.withLock { buffer -> Data in
                defer { buffer = Data() }
                return buffer
            }
            if !buffered.isEmpty || remainingLength.withLock({ $0 == 0 }) {
                if let payload = try decode(buffered) { return payload }
                if finished.withLock({ $0 }) { return nil }
            }
            let data = try await stream.read()
            if data.isEmpty {
                let complete = chunked.withLock { $0 == nil } && remainingLength.withLock { $0 == nil }
                finished.withLock { $0 = true }
                if complete { return nil }  // until-close framing ends here
                throw HTTPParseError.unexpectedEnd
            }
            pending.withLock { $0.append(data) }
        }
    }

    /// Decodes `input` per the body framing; returns nil when it produced nothing yet.
    private func decode(_ input: Data) throws -> Data? {
        if var decoder = chunked.withLock({ $0 }) {
            let (payload, rest) = try decoder.feed(input)
            chunked.withLock { $0 = decoder }
            if decoder.isDone {
                finished.withLock { $0 = true }
                pending.withLock { $0 = rest + $0 }
            }
            return payload.isEmpty ? (decoder.isDone ? nil : nil) : payload
        }
        if let remaining = remainingLength.withLock({ $0 }) {
            if remaining == 0 {
                finished.withLock { $0 = true }
                pending.withLock { $0 = input + $0 }
                return nil
            }
            let take = min(remaining, input.count)
            remainingLength.withLock { $0 = remaining - take }
            if take < input.count { pending.withLock { $0 = Data(input[(input.startIndex + take)...]) + $0 } }
            if remaining - take == 0 { finished.withLock { $0 = true } }
            return take == 0 ? nil : Data(input.prefix(take))
        }
        return input.isEmpty ? nil : input
    }

    /// Reads the whole body, refusing more than `limit` bytes.
    public func readBody(limit: Int = 32 * 1024 * 1024) async throws -> Data {
        var body = Data()
        while let chunk = try await nextBodyChunk() {
            body.append(chunk)
            if body.count > limit { throw HTTPParseError.bodyTooLarge(limit: limit) }
        }
        return body
    }

    /// Raw bytes after an upgrade (hijack). Empty means the peer closed its side.
    public func readRaw() async throws -> Data {
        let buffered = pending.withLock { buffer -> Data in
            defer { buffer = Data() }
            return buffer
        }
        if !buffered.isEmpty { return buffered }
        return try await stream.read()
    }

    public func write(_ data: Data) async throws { try await stream.write(data) }
    public func closeWrite() { stream.shutdownWrite() }
    public func cancel() { stream.cancel() }
}
