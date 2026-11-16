import Foundation

/// Any JSON value. Used for free-form fields (`metadata`, tool `input`) and for events or unions this package does not
/// model yet, so unknown shapes are carried through instead of failing a decode.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var numberValue: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }
}

/// A JSON number that the contract may also encode as the strings `"Infinity"`, `"-Infinity"` or `"NaN"`
/// (OpenAPI: `number | enum["Infinity","-Infinity","NaN"]`).
public struct FlexibleNumber: Sendable, Hashable, Codable {
    public var value: Double

    public init(_ value: Double) { self.value = value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
            return
        }
        switch try container.decode(String.self) {
        case "Infinity": value = .infinity
        case "-Infinity": value = -.infinity
        default: value = .nan
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if value.isNaN {
            try container.encode("NaN")
        } else if value.isInfinite {
            try container.encode(value > 0 ? "Infinity" : "-Infinity")
        } else {
            try container.encode(value)
        }
    }
}

/// A string enum whose unknown cases decode instead of failing. Conforming types are `RawRepresentable` structs with
/// `static let` constants for the known cases, so a newer server that adds a case never breaks decoding.
public protocol OpenEnum: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible,
    ExpressibleByStringLiteral where RawValue == String
{
    init(rawValue: String)
}

extension OpenEnum {
    public init(stringLiteral value: String) { self.init(rawValue: value) }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}
