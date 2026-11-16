import Foundation

/// A JSON value with ordered object keys.
///
/// The mock writes every response and event through this type so the bytes are deterministic (same input, same
/// output) and keys appear in the same order as the real server's (`id`, `created`, `type`, `location`, `data`, ...).
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    /// Ordered key/value pairs. Keys are unique; ``subscript(_:)`` setter replaces in place.
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.int(a), .int(b)): a == b
        case let (.double(a), .double(b)): a == b
        case let (.int(a), .double(b)), let (.double(b), .int(a)): Double(a) == b
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)):
            a.count == b.count && a.allSatisfy { pair in b.contains { $0.0 == pair.0 && $0.1 == pair.1 } }
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case let .bool(v): hasher.combine(v)
        case let .int(v): hasher.combine(Double(v))
        case let .double(v): hasher.combine(v)
        case let .string(v): hasher.combine(v)
        case let .array(v): hasher.combine(v)
        case let .object(v): hasher.combine(v.count)
        }
    }

    // MARK: Access

    public subscript(key: String) -> JSONValue? {
        get {
            guard case let .object(pairs) = self else { return nil }
            return pairs.first { $0.0 == key }?.1
        }
        set {
            guard case var .object(pairs) = self else { return }
            if let index = pairs.firstIndex(where: { $0.0 == key }) {
                if let newValue { pairs[index].1 = newValue } else { pairs.remove(at: index) }
            } else if let newValue {
                pairs.append((key, newValue))
            }
            self = .object(pairs)
        }
    }

    public subscript(index: Int) -> JSONValue? {
        guard case let .array(items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    public var stringValue: String? { if case let .string(v) = self { v } else { nil } }
    public var boolValue: Bool? { if case let .bool(v) = self { v } else { nil } }
    public var arrayValue: [JSONValue]? { if case let .array(v) = self { v } else { nil } }
    public var objectValue: [(String, JSONValue)]? { if case let .object(v) = self { v } else { nil } }
    public var isNull: Bool { if case .null = self { true } else { false } }

    public var intValue: Int? {
        switch self {
        case let .int(v): v
        case let .double(v) where v.rounded() == v && abs(v) < 9.0e15: Int(v)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .int(v): Double(v)
        case let .double(v): v
        default: nil
        }
    }

    /// Returns a copy of an object with `nil` values dropped, so optional fields are omitted like the real server.
    public static func compact(_ pairs: [(String, JSONValue?)]) -> JSONValue {
        .object(pairs.compactMap { key, value in value.map { (key, $0) } })
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(elements) }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Serialisation

extension JSONValue {
    /// Compact UTF-8 JSON, matching JavaScript's `JSON.stringify` for the values the mock produces.
    public var data: Data { Data(serialized.utf8) }

    public var serialized: String {
        var out = ""
        out.reserveCapacity(64)
        write(into: &out)
        return out
    }

    func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(v): out += v ? "true" : "false"
        case let .int(v): out += String(v)
        case let .double(v): out += Self.format(v)
        case let .string(v): Self.writeString(v, into: &out)
        case let .array(items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case let .object(pairs):
            out += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { out += "," }
                Self.writeString(pair.0, into: &out)
                out += ":"
                pair.1.write(into: &out)
            }
            out += "}"
        }
    }

    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }

    static func writeString(_ string: String, into out: inout String) {
        out += "\""
        var pending = string.unicodeScalars.startIndex
        let scalars = string.unicodeScalars
        var index = scalars.startIndex
        while index != scalars.endIndex {
            let scalar = scalars[index]
            let escape: String? =
                switch scalar {
                case "\"": "\\\""
                case "\\": "\\\\"
                case "\n": "\\n"
                case "\r": "\\r"
                case "\t": "\\t"
                case "\u{08}": "\\b"
                case "\u{0C}": "\\f"
                default:
                    scalar.value < 0x20 ? String(format: "\\u%04x", scalar.value) : nil
                }
            if let escape {
                out.unicodeScalars.append(contentsOf: scalars[pending..<index])
                out += escape
                pending = scalars.index(after: index)
            }
            index = scalars.index(after: index)
        }
        out.unicodeScalars.append(contentsOf: scalars[pending..<scalars.endIndex])
        out += "\""
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, Sendable, CustomStringConvertible {
    public let description: String
}

extension JSONValue {
    /// Parses JSON. Object keys come back sorted, because Foundation's parser does not keep source order; the mock
    /// only parses request bodies and fixture files, where order carries no meaning.
    public static func parse(_ data: Data) throws -> JSONValue {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONParseError(description: "Expected a valid JSON body")
        }
        return try JSONValue(foundation: object)
    }

    public static func parse(_ string: String) throws -> JSONValue { try parse(Data(string.utf8)) }

    init(foundation object: Any) throws {
        switch object {
        case is NSNull: self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                let double = number.doubleValue
                self = double.rounded() == double && abs(double) < 9.0e15 ? .int(Int(double)) : .double(double)
            } else {
                self = .int(number.intValue)
            }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(try array.map(JSONValue.init(foundation:)))
        case let dictionary as [String: Any]:
            self = .object(try dictionary.keys.sorted().map { ($0, try JSONValue(foundation: dictionary[$0]!)) })
        default:
            throw JSONParseError(description: "Unsupported JSON value \(type(of: object))")
        }
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicKey.self) {
            self = .object(
                try keyed.allKeys.map(\.stringValue).sorted().map {
                    ($0, try keyed.decode(JSONValue.self, forKey: DynamicKey(stringValue: $0)))
                })
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !unkeyed.isAtEnd { items.append(try unkeyed.decode(JSONValue.self)) }
            self = .array(items)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Int.self) {
            self = .int(value)
        } else if let value = try? single.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try single.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var single = encoder.singleValueContainer()
            try single.encodeNil()
        case let .bool(v):
            var single = encoder.singleValueContainer()
            try single.encode(v)
        case let .int(v):
            var single = encoder.singleValueContainer()
            try single.encode(v)
        case let .double(v):
            var single = encoder.singleValueContainer()
            try single.encode(v)
        case let .string(v):
            var single = encoder.singleValueContainer()
            try single.encode(v)
        case let .array(items):
            var unkeyed = encoder.unkeyedContainer()
            for item in items { try unkeyed.encode(item) }
        case let .object(pairs):
            var keyed = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in pairs { try keyed.encode(value, forKey: DynamicKey(stringValue: key)) }
        }
    }
}
