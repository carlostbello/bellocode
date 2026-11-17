import Foundation

// Accessors, literals and conversions for free-form JSON (plugin RPC payloads such as `experimental.browser`, whose
// actions and results are open-ended and validated by the server against per-operation schemas).

extension JSONValue {
    public var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value else { return nil }
        return Int(exactly: value)
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    public var isNull: Bool {
        if case .null = self { true } else { false }
    }

    /// Converts a Foundation object graph (from `JSONSerialization` or WebKit's script results) into a JSON value.
    /// Values JSON cannot represent become their description.
    public init(foundation value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { JSONValue(foundation: $0) })
        case let dictionary as [String: Any]: self = .object(dictionary.mapValues { JSONValue(foundation: $0) })
        case let date as Date: self = .number(date.timeIntervalSince1970 * 1000)
        default: self = .string(String(describing: value!))
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Compact JSON with sorted keys (stable, so equal values encode to equal bytes).
    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Compact JSON text, or `<unencodable>` (non-finite numbers).
    public var compactText: String {
        (try? encodedData()).map { String(decoding: $0, as: UTF8.self) } ?? "<unencodable>"
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
}
