import Foundation

/// A typed error body. opencode encodes errors as `{ "_tag": "SessionNotFoundError", "message": …, …extra }`.
public struct ServerErrorBody: Decodable, Sendable, Hashable {
    public var tag: ServerErrorTag
    public var message: String
    /// The whole body, for tag-specific fields (`sessionID`, `field`, `resource`, `location`, …).
    public var fields: JSONValue

    private enum CodingKeys: String, CodingKey {
        case tag = "_tag"
        case message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(ServerErrorTag.self, forKey: .tag)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        fields = try JSONValue(from: decoder)
    }
}

/// The `_tag` of an error body.
public struct ServerErrorTag: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let invalidRequest: Self = "InvalidRequestError"
    public static let invalidCursor: Self = "InvalidCursorError"
    public static let unauthorized: Self = "UnauthorizedError"
    public static let sessionNotFound: Self = "SessionNotFoundError"
    public static let locationNotFound: Self = "LocationNotFoundError"
    public static let permissionNotFound: Self = "PermissionNotFoundError"
    public static let formNotFound: Self = "FormNotFoundError"
    public static let formAlreadySettled: Self = "FormAlreadySettledError"
    public static let formInvalidAnswer: Self = "FormInvalidAnswerError"
    public static let conflict: Self = "ConflictError"
    public static let serviceUnavailable: Self = "ServiceUnavailableError"
    public static let unknown: Self = "UnknownError"
}

/// Errors from `OpenCodeClient` and the event stream. Messages never include credentials or request bodies.
public enum OpenCodeError: Error, Sendable, CustomStringConvertible {
    /// The server answered with a non-success status. `body` is the decoded error body when it had one.
    case http(status: Int, body: ServerErrorBody?, operation: String)
    /// A success response whose body did not match the expected shape.
    case decoding(operation: String, reason: String)
    /// The request did not complete (connection refused, timed out, …).
    case transport(operation: String, code: URLError.Code)
    /// The response was not HTTP.
    case invalidResponse
    /// The event stream answered with something other than `text/event-stream`.
    case unexpectedContentType(String?)

    public var status: Int? {
        if case .http(let status, _, _) = self { status } else { nil }
    }

    public var tag: ServerErrorTag? {
        if case .http(_, let body, _) = self { body?.tag } else { nil }
    }

    public var description: String {
        switch self {
        case .http(let status, let body, let operation):
            if let body { "\(operation): HTTP \(status) \(body.tag): \(body.message)" } else { "\(operation): HTTP \(status)" }
        case .decoding(let operation, let reason):
            "\(operation): unexpected response shape (\(reason))"
        case .transport(let operation, let code):
            "\(operation): transport error \(code.rawValue)"
        case .invalidResponse:
            "response was not HTTP"
        case .unexpectedContentType(let type):
            "event stream returned content type \(type ?? "none")"
        }
    }
}
