import Foundation

/// One parsed HTTP/1.1 request.
public struct HTTPRequest: Sendable {
    public var method: String
    /// The request target as sent, for example `/api/session?limit=2`.
    public var target: String
    /// The percent-decoded path without the query.
    public var path: String
    /// Query items in order; repeated names (`types=a&types=b`) are kept.
    public var query: [(name: String, value: String)]
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public func queryValue(_ name: String) -> String? { query.first { $0.name == name }?.value }
    public func queryValues(_ name: String) -> [String] { query.filter { $0.name == name }.map(\.value) }

    var wantsClose: Bool {
        headers["connection"]?.lowercased().contains("close") == true
    }
}

/// One HTTP response with a complete body.
public struct HTTPResponse: Sendable, Error {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("content-type", "application/json")], body: value.data)
    }

    public static func noContent() -> HTTPResponse { HTTPResponse(status: 204) }

    /// The real server's error envelope: `{"_tag": "...", "message": "...", ...}`.
    public static func error(_ status: Int, tag: String, message: String, extra: [(String, JSONValue)] = []) -> HTTPResponse {
        var pairs: [(String, JSONValue)] = [("_tag", .string(tag))]
        pairs += extra
        pairs.append(("message", .string(message)))
        return .json(.object(pairs), status: status)
    }

    /// Serialised status line, headers and body. `keepAlive` adds the same connection headers the real server sends.
    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var hasLength = false
        for (name, value) in headers {
            if name.lowercased() == "content-length" { hasLength = true }
            head += "\(name): \(value)\r\n"
        }
        if !hasLength, status != 204, status != 304 { head += "content-length: \(body.count)\r\n" }
        head += keepAlive ? "Connection: keep-alive\r\nKeep-Alive: timeout=5\r\n" : "Connection: close\r\n"
        head += "\r\n"
        var data = Data(head.utf8)
        if status != 204 { data.append(body) }
        return data
    }

    /// Head of a chunked `text/event-stream` response, with the real server's headers.
    static func eventStreamHead() -> Data {
        let lines: [String] = [
            "HTTP/1.1 200 OK",
            "cache-control: no-cache, no-transform",
            "x-accel-buffering: no",
            "x-content-type-options: nosniff",
            "content-type: text/event-stream",
            "Connection: keep-alive",
            "Keep-Alive: timeout=5",
            "Transfer-Encoding: chunked",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    static func chunk(_ payload: Data) -> Data {
        var data = Data(String(payload.count, radix: 16).utf8)
        data.append(contentsOf: [13, 10])
        data.append(payload)
        data.append(contentsOf: [13, 10])
        return data
    }

    static let lastChunk = Data("0\r\n\r\n".utf8)

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "Status \(status)"
        }
    }
}

enum HTTPParseError: Error, Equatable {
    case malformed(String)
    case headersTooLarge
    case bodyTooLarge
    case unsupported(String)

    var response: HTTPResponse {
        switch self {
        case let .malformed(message): .error(400, tag: "InvalidRequestError", message: message)
        case .headersTooLarge: .error(431, tag: "InvalidRequestError", message: "Request headers too large")
        case .bodyTooLarge: .error(413, tag: "InvalidRequestError", message: "Request body too large")
        case let .unsupported(message): .error(400, tag: "InvalidRequestError", message: message)
        }
    }
}

/// Incremental HTTP/1.1 request parser. Feed bytes as they arrive; take complete requests out.
struct HTTPRequestParser {
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 32 * 1024 * 1024

    private var buffer = Data()

    mutating func append(_ data: Data) { buffer.append(data) }

    /// Returns the next complete request, or `nil` if more bytes are needed.
    mutating func next() throws(HTTPParseError) -> HTTPRequest? {
        guard let headerEnd = buffer.firstRange(of: Data([13, 10, 13, 10])) else {
            if buffer.count > Self.maxHeaderBytes { throw .headersTooLarge }
            return nil
        }
        guard let headText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            throw .malformed("Request head is not UTF-8")
        }
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw .malformed("Bad request line") }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw .malformed("Bad header line") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        if headers["transfer-encoding"].map({ $0.lowercased() != "identity" }) == true {
            throw .unsupported("Chunked request bodies are not supported by the mock")
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { throw .malformed("Bad content-length") }
        guard length <= Self.maxBodyBytes else { throw .bodyTooLarge }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])

        let target = String(requestLine[1])
        let (path, query) = Self.split(target: target)
        return HTTPRequest(
            method: String(requestLine[0]).uppercased(), target: target, path: path, query: query, headers: headers,
            body: body)
    }

    static func split(target: String) -> (String, [(name: String, value: String)]) {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts[0])
        let path = rawPath.removingPercentEncoding ?? rawPath
        guard parts.count == 2 else { return (path, []) }
        let items = parts[1].split(separator: "&").map { pair -> (name: String, value: String) in
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                let plus = s.replacingOccurrences(of: "+", with: " ")
                return plus.removingPercentEncoding ?? plus
            }
            return (decode(kv[0]), kv.count == 2 ? decode(kv[1]) : "")
        }
        return (path, items)
    }
}
