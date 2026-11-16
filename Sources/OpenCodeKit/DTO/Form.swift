import Foundation

/// `Form.Info`: a structured question (the `question` tool) or an MCP elicitation awaiting an answer.
public struct FormInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var sessionID: String
    public var title: String
    public var metadata: JSONValue?
    public var fields: [FormField]
}

/// `Form.Field`. The contract's union (string, number, integer, boolean, multiselect, external) is flattened into one
/// tolerant struct; fields that do not apply to a `type` are nil.
public struct FormField: Codable, Sendable, Hashable {
    public struct Option: Codable, Sendable, Hashable {
        public var value: String
        public var label: String
        public var description: String?
    }

    public var key: String
    public var type: FormFieldType
    public var title: String?
    public var description: String?
    public var required: Bool?
    public var hidden: Bool?
    /// Conditional visibility rules (`Form.When`), kept raw.
    public var when: [JSONValue]?
    public var options: [Option]?
    /// Whether a custom answer is allowed besides `options`.
    public var custom: Bool?
    public var placeholder: String?
    public var format: String?
    public var pattern: String?
    public var minLength: Int?
    public var maxLength: Int?
    public var minimum: Double?
    public var maximum: Double?
    public var minItems: Int?
    public var maxItems: Int?
    /// The field's default value, whose JSON type depends on `type`.
    public var `default`: JSONValue?
    /// For `external` fields: the URL to open.
    public var url: String?
}

public struct FormFieldType: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let string: Self = "string"
    public static let number: Self = "number"
    public static let integer: Self = "integer"
    public static let boolean: Self = "boolean"
    public static let multiselect: Self = "multiselect"
    public static let external: Self = "external"
}

/// `Form.Value`.
public enum FormValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case strings([String])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String].self) {
            self = .strings(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(FlexibleNumber(value))
        case .bool(let value): try container.encode(value)
        case .strings(let value): try container.encode(value)
        }
    }
}

struct FormReplyBody: Encodable, Sendable {
    let answer: [String: FormValue]
}
