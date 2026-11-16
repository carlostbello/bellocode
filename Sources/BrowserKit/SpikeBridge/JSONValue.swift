// SPIKE (gate G3, docs/spikes/G3-browser-bridge.md). Throwaway prototype code; production BrowserKit replaces it.

import Foundation

/// An arbitrary JSON value: browser actions and results are open-ended, so the spike keeps them as data.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var double: Double? { if case .number(let value) = self { value } else { nil } }
    public var int: Int? { double.flatMap { $0.rounded() == $0 ? Int(exactly: $0) : nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }

    /// Converts a Foundation object graph (from `JSONSerialization` or WebKit) into a JSON value.
    public init(foundation value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { JSONValue(foundation: $0) })
        case let dictionary as [String: Any]: self = .object(dictionary.mapValues { JSONValue(foundation: $0) })
        default: self = .string(String(describing: value!))
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public var compactText: String {
        (try? encoded()).map { String(decoding: $0, as: UTF8.self) } ?? "<unencodable>"
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Integers must stay integers: the plugin's schemas use Schema.Int for generation, counts and bytes.
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
}
