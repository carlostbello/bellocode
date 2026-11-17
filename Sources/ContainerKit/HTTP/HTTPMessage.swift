import Foundation

/// An HTTP/1.1 request for the Engine API. Bodies are small JSON documents or a tar build context.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [(String, String)]
    public var body: Data?

    public init(method: String, path: String, headers: [(String, String)] = [], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    /// Serialised request. `Host` is required by HTTP/1.1; the daemon ignores its value.
    public func serialized() -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nUser-Agent: BelloCode-ContainerKit\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        if let body {
            head += "Content-Length: \(body.count)\r\n"
        } else if method == "POST" || method == "PUT" {
            head += "Content-Length: 0\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }
}

public struct HTTPResponseHead: Sendable, Equatable {
    public var status: Int
    public var reason: String
    public var headers: [String: String]  // lower-cased names; repeated headers joined with ", "

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public enum BodyFraming: Equatable, Sendable {
        case none
        case length(Int)
        case chunked
        case untilClose
    }

    /// RFC 9112 section 6.3, for responses to non-HEAD requests.
    public var framing: BodyFraming {
        if status == 101 || status == 204 || status == 304 || (100..<200).contains(status) { return .none }
        if let encoding = header("transfer-encoding"), encoding.lowercased().contains("chunked") { return .chunked }
        if let length = header("content-length").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
            return .length(length)
        }
        return .untilClose
    }
}

public enum HTTPParseError: Error, Equatable, Sendable {
    case malformedStatusLine
    case malformedHeader
    case headTooLarge
    case malformedChunk
    case bodyTooLarge(limit: Int)
    case unexpectedEnd
}

/// Pure response-head parser: consumes the head from the front of `buffer` once `\r\n\r\n` has arrived.
public enum HTTPHeadParser {
    public static let maxHeadBytes = 64 * 1024
    private static let terminator = Data("\r\n\r\n".utf8)

    public static func parse(_ buffer: inout Data) throws -> HTTPResponseHead? {
        guard let range = buffer.range(of: terminator) else {
            if buffer.count > maxHeadBytes { throw HTTPParseError.headTooLarge }
            return nil
        }
        let headData = buffer[buffer.startIndex..<range.lowerBound]
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        buffer = Data(buffer)  // re-base indices
        guard let text = String(data: headData, encoding: .utf8) ?? String(data: headData, encoding: .isoLatin1) else {
            throw HTTPParseError.malformedStatusLine
        }
        var lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
            throw HTTPParseError.malformedStatusLine
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformedHeader }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        return HTTPResponseHead(status: status, reason: parts.count > 2 ? String(parts[2]) : "", headers: headers)
    }
}

/// Incremental chunked transfer-coding decoder (RFC 9112 section 7.1). Feed arbitrary byte boundaries; it emits
/// payload bytes as soon as they arrive, so a long-lived stream (events, logs, pull progress) is never buffered whole.
public struct ChunkedDecoder: Sendable {
    private enum State: Sendable { case size, data(remaining: Int), dataCRLF, trailer, done }
    private var state: State = .size
    private var line = Data()
    public private(set) var isDone = false

    public init() {}

    /// Returns the payload decoded from `input`. Bytes after the final chunk are returned in `rest`.
    public mutating func feed(_ input: Data) throws -> (payload: Data, rest: Data) {
        var payload = Data()
        var index = input.startIndex
        while index < input.endIndex {
            switch state {
            case .done:
                return (payload, Data(input[index...]))
            case .size, .trailer, .dataCRLF:
                let byte = input[index]
                index += 1
                if byte == 0x0A {
                    let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                    line.removeAll(keepingCapacity: true)
                    switch state {
                    case .size:
                        let hex = text.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                        guard let size = Int(hex, radix: 16), size >= 0 else { throw HTTPParseError.malformedChunk }
                        state = size == 0 ? .trailer : .data(remaining: size)
                    case .dataCRLF:
                        guard text.isEmpty else { throw HTTPParseError.malformedChunk }
                        state = .size
                    case .trailer:
                        if text.isEmpty {
                            state = .done
                            isDone = true
                        }
                    default: break
                    }
                } else {
                    line.append(byte)
                    if line.count > 4096 { throw HTTPParseError.malformedChunk }
                }
            case .data(let remaining):
                let available = input.endIndex - index
                let take = min(available, remaining)
                payload.append(input[index..<(index + take)])
                index += take
                state = remaining - take == 0 ? .dataCRLF : .data(remaining: remaining - take)
            }
        }
        return (payload, Data())
    }
}
