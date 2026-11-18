import Darwin
import Foundation

/// Opaque per-thread placeholders: `bcsec_` and 40 base62 characters (≈ 238 bits from the system CSPRNG).
public enum Placeholder {
    public static let prefix = "bcsec_"
    public static let bodyLength = 40
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)

    public static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: bodyLength)
        var out = prefix
        // Rejection sampling keeps the alphabet uniform.
        var index = 0
        while index < bodyLength {
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { continue }
            for byte in bytes where index < bodyLength && byte < 248 {
                out.unicodeScalars.append(UnicodeScalar(alphabet[Int(byte % 62)]))
                index += 1
            }
        }
        return out
    }

    public static func isPlaceholder(_ text: String) -> Bool {
        guard text.hasPrefix(prefix), text.utf8.count == prefix.utf8.count + bodyLength else { return false }
        return text.utf8.dropFirst(prefix.utf8.count).allSatisfy(isBase62)
    }

    static func isBase62(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    /// Every complete placeholder in `data`, and whether a prefix appears that is not a complete placeholder (a split,
    /// truncated or altered one). Case-insensitive for the prefix, so `BCSEC_` counts as a fragment.
    public static func find(in data: Data) -> (placeholders: [String], fragments: Int) {
        let bytes = [UInt8](data)
        let needle = Array(prefix.utf8)
        var found: [String] = []
        var fragments = 0
        guard bytes.count >= needle.count else { return ([], 0) }
        var index = 0
        while index <= bytes.count - needle.count {
            var match = true
            for offset in 0..<needle.count where lower(bytes[index + offset]) != needle[offset] {
                match = false
                break
            }
            if !match { index += 1; continue }
            let start = index + needle.count
            let end = start + bodyLength
            let exactPrefix = Array(bytes[index..<start]) == needle
            let precededOK = index == 0 || !isBase62(bytes[index - 1])
            if exactPrefix, precededOK, end <= bytes.count, bytes[start..<end].allSatisfy(isBase62),
               end == bytes.count || !isBase62(bytes[end]) {
                found.append(String(decoding: bytes[index..<end], as: UTF8.self))
                index = end
            } else {
                fragments += 1
                index = start
            }
        }
        return (found, fragments)
    }

    private static func lower(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }

    /// Encoded forms of the prefix (base64 at every alignment, hex, percent and JSON escapes). A request that carries
    /// one is trying to hide a placeholder from the substitution rules, so it is refused.
    public static let encodedPrefixPatterns: [Data] = {
        let value = Data(prefix.utf8)
        var patterns = SecretPatterns.encodedForms(of: value, minimumBase64Core: 6)
        // The raw prefix is handled by `find`; only alternative spellings here.
        patterns.removeAll { $0 == value }
        patterns.append(Data("bcsec%5f".utf8))
        patterns.append(Data("bcsec%5F".utf8))
        patterns.append(Data("bcsec\\u005f".utf8))
        patterns.append(Data("bcsec\\u005F".utf8))
        return Array(Set(patterns))
    }()

    public static func containsEncodedPrefix(_ data: Data) -> Bool {
        encodedPrefixPatterns.contains { ByteSearch.contains(data, $0, caseInsensitive: true) }
    }
}

/// How a secret value can look in a response: the value itself and its common encodings.
public struct SecretPatterns: Sendable {
    public enum Form: String, Sendable, Hashable {
        case raw, json, url, hex, base64
        /// Found only after percent-decoding or JSON-unescaping the whole text (any mix of escaped and plain
        /// characters, nested escapes): cannot be replaced in place.
        case decoded
        /// Whether a response with this form may be passed on with the occurrence replaced by the placeholder.
        public var replaceable: Bool { self == .raw || self == .json || self == .url }
    }

    public struct Pattern: Sendable, Hashable {
        public var bytes: Data
        public var form: Form
        public var caseInsensitive: Bool
    }

    public let patterns: [Pattern]

    public init(value: Data) {
        var out: [Pattern] = [Pattern(bytes: value, form: .raw, caseInsensitive: false)]
        for json in Self.jsonEscapes(value) where json != value { out.append(Pattern(bytes: json, form: .json, caseInsensitive: false)) }
        for url in Self.percentEncodings(value) where url != value { out.append(Pattern(bytes: url, form: .url, caseInsensitive: false)) }
        out.append(Pattern(bytes: Data(value.map { String(format: "%02x", $0) }.joined().utf8), form: .hex, caseInsensitive: true))
        for core in Self.base64Cores(value, minimum: 8) { out.append(Pattern(bytes: core, form: .base64, caseInsensitive: false)) }
        var seen = Set<Data>()
        patterns = out.filter { !$0.bytes.isEmpty && seen.insert($0.bytes).inserted }
    }

    /// All encoded spellings (no form tags), for placeholder-prefix detection.
    static func encodedForms(of value: Data, minimumBase64Core: Int) -> [Data] {
        var out = [value]
        out += jsonEscapes(value)
        out += percentEncodings(value)
        out.append(Data(value.map { String(format: "%02x", $0) }.joined().utf8))
        out += base64Cores(value, minimum: minimumBase64Core)
        return out
    }

    /// JSON string escapes: minimal (quote, backslash, controls), with `\/`, and with every non-ASCII byte sequence
    /// as `\uXXXX`.
    static func jsonEscapes(_ value: Data) -> [Data] {
        guard let text = String(data: value, encoding: .utf8) else { return [] }
        func escape(_ slash: Bool, _ unicode: Bool) -> Data {
            var out = ""
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "/" where slash: out += "\\/"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if scalar.value < 0x20 || (unicode && scalar.value > 0x7E) {
                        if scalar.value > 0xFFFF {
                            let v = scalar.value - 0x10000
                            out += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                        } else {
                            out += String(format: "\\u%04x", scalar.value)
                        }
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
                }
            }
            return Data(out.utf8)
        }
        return Array(Set([escape(false, false), escape(true, false), escape(false, true), escape(true, true)]))
    }

    /// Percent-encodings: RFC 3986 unreserved kept (upper and lower hex), form encoding (space as `+`), and every
    /// byte encoded.
    static func percentEncodings(_ value: Data) -> [Data] {
        func encode(keep: (UInt8) -> Bool, upper: Bool, plus: Bool) -> Data {
            var out = ""
            for byte in value {
                if keep(byte) {
                    out.unicodeScalars.append(UnicodeScalar(byte))
                } else if plus, byte == 0x20 {
                    out += "+"
                } else {
                    out += String(format: upper ? "%%%02X" : "%%%02x", byte)
                }
            }
            return Data(out.utf8)
        }
        let unreserved: (UInt8) -> Bool = { Placeholder.isBase62($0) || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F || $0 == 0x7E }
        return Array(Set([
            encode(keep: unreserved, upper: true, plus: false), encode(keep: unreserved, upper: false, plus: false),
            encode(keep: unreserved, upper: true, plus: true), encode(keep: { _ in false }, upper: true, plus: false),
            encode(keep: { _ in false }, upper: false, plus: false),
        ]))
    }

    /// The part of the base64 encoding that depends only on `value`, for each of the three byte alignments it can have
    /// inside a longer encoded stream, in the standard and URL-safe alphabets.
    static func base64Cores(_ value: Data, minimum: Int) -> [Data] {
        var out: [Data] = []
        let n = value.count
        for alignment in 0..<3 {
            let padded = Data(repeating: 0, count: alignment) + value + Data([0, 0, 0])
            let encoded = Array(padded.base64EncodedString().utf8)
            let firstBit = 8 * alignment
            let lastBit = 8 * (alignment + n)
            var core: [UInt8] = []
            for (index, char) in encoded.enumerated() where 6 * index >= firstBit && 6 * index + 6 <= lastBit {
                core.append(char)
            }
            guard core.count >= minimum else { continue }
            let standard = Data(core)
            out.append(standard)
            let urlSafe = Data(core.map { $0 == UInt8(ascii: "+") ? UInt8(ascii: "-") : $0 == UInt8(ascii: "/") ? UInt8(ascii: "_") : $0 })
            out.append(urlSafe)
        }
        return Array(Set(out))
    }

    /// The forms found in `data`: each pattern as is (base64 and hex also after removing line breaks), then the value
    /// in decoded views of the whole text (percent-decoded, `+` as space, JSON-unescaped, and both in either order), so
    /// partial or mixed escaping is caught too.
    public func forms(in data: Data) -> Set<Form> {
        var found = Set<Form>()
        lazy var unwrapped: Data = Self.removingLineBreaks(data)
        for pattern in patterns where !found.contains(pattern.form) {
            if ByteSearch.contains(data, pattern.bytes, caseInsensitive: pattern.caseInsensitive) {
                found.insert(pattern.form)
            } else if pattern.form == .base64 || pattern.form == .hex, ByteSearch.contains(unwrapped, pattern.bytes, caseInsensitive: pattern.caseInsensitive) {
                found.insert(pattern.form)
            }
        }
        if found.isEmpty, let raw = patterns.first?.bytes {
            for view in Self.decodedViews(data) where ByteSearch.contains(view, raw) {
                found.insert(.decoded)
                break
            }
        }
        return found
    }

    /// Percent-decoded (`%XX`, optionally `+` as space), JSON-unescaped (`\uXXXX`, `\/`, `\"`, `\\`, `\n`…) and both
    /// combinations. Only views that differ from the input are returned.
    static func decodedViews(_ data: Data) -> [Data] {
        let hasPercent = data.contains(0x25)
        let hasBackslash = data.contains(0x5C)
        let hasPlus = data.contains(0x2B)
        guard hasPercent || hasBackslash || hasPlus else { return [] }
        var views: [Data] = []
        if hasPercent || hasPlus {
            views.append(percentDecoded(data, plusAsSpace: false))
            if hasPlus { views.append(percentDecoded(data, plusAsSpace: true)) }
        }
        if hasBackslash {
            let unescaped = jsonUnescaped(data)
            views.append(unescaped)
            if unescaped.contains(0x25) { views.append(percentDecoded(unescaped, plusAsSpace: false)) }
        }
        if hasPercent, let first = views.first, first.contains(0x5C) { views.append(jsonUnescaped(first)) }
        return views.filter { $0 != data }
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    static func percentDecoded(_ data: Data, plusAsSpace: Bool) -> Data {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count, let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(plusAsSpace && bytes[i] == 0x2B ? 0x20 : bytes[i])
                i += 1
            }
        }
        return Data(out)
    }

    static func jsonUnescaped(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        func scalar(at index: Int) -> UInt32? {
            guard index + 4 < bytes.count + 0, index + 4 <= bytes.count else { return nil }
            var value: UInt32 = 0
            for k in 0..<4 {
                guard let digit = hexValue(bytes[index + k]) else { return nil }
                value = value << 4 | UInt32(digit)
            }
            return value
        }
        while i < bytes.count {
            guard bytes[i] == 0x5C, i + 1 < bytes.count else {
                out.append(bytes[i])
                i += 1
                continue
            }
            let next = bytes[i + 1]
            switch next {
            case UInt8(ascii: "u"), UInt8(ascii: "U"):
                if var value = scalar(at: i + 2) {
                    var consumed = 6
                    if (0xD800...0xDBFF).contains(value), i + 11 < bytes.count + 1, bytes.count > i + 7, bytes[i + 6] == 0x5C,
                       bytes[i + 7] == UInt8(ascii: "u"), let low = scalar(at: i + 8), (0xDC00...0xDFFF).contains(low) {
                        value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                        consumed = 12
                    }
                    if let unicode = UnicodeScalar(value) {
                        out += Array(String(Character(unicode)).utf8)
                    }
                    i += consumed
                    continue
                }
                out.append(bytes[i])
                i += 1
            case UInt8(ascii: "n"): out.append(0x0A); i += 2
            case UInt8(ascii: "r"): out.append(0x0D); i += 2
            case UInt8(ascii: "t"): out.append(0x09); i += 2
            case UInt8(ascii: "b"): out.append(0x08); i += 2
            case UInt8(ascii: "f"): out.append(0x0C); i += 2
            case UInt8(ascii: "x"):
                if i + 3 < bytes.count, let hi = hexValue(bytes[i + 2]), let lo = hexValue(bytes[i + 3]) {
                    out.append(hi << 4 | lo)
                    i += 4
                } else {
                    out.append(bytes[i]); i += 1
                }
            default:
                out.append(next)
                i += 2
            }
        }
        return Data(out)
    }

    /// Replaces the replaceable forms with `replacement`. Returns nil when a non-replaceable form is present.
    public func redact(_ data: Data, replacement: Data) -> (data: Data, replaced: Int)? {
        let present = forms(in: data)
        if present.contains(where: { !$0.replaceable }) { return nil }
        var current = data
        var count = 0
        // Longest first, so a JSON escape that contains the raw value is replaced whole.
        for pattern in patterns.filter({ $0.form.replaceable }).sorted(by: { $0.bytes.count > $1.bytes.count }) {
            let (next, replaced) = ByteSearch.replaceAll(current, pattern.bytes, with: replacement)
            current = next
            count += replaced
        }
        // Replacing must not have produced a detectable form (it cannot, but never pass on what was not checked).
        if !forms(in: current).isEmpty { return nil }
        return (current, count)
    }

    static func removingLineBreaks(_ data: Data) -> Data {
        guard data.contains(0x0A) || data.contains(0x0D) else { return data }
        return Data(data.filter { $0 != 0x0A && $0 != 0x0D })
    }
}

/// Byte search on `Data` (memmem; a case-insensitive scan for hex and encoded prefixes).
public enum ByteSearch {
    public static func contains(_ haystack: Data, _ needle: Data, caseInsensitive: Bool = false) -> Bool {
        range(haystack, needle, from: 0, caseInsensitive: caseInsensitive) != nil
    }

    /// Offsets are from the first byte (0), whatever the `Data`'s own start index (slices are rebased).
    public static func range(_ haystack: Data, _ needle: Data, from start: Int, caseInsensitive: Bool = false) -> Range<Int>? {
        let haystack = rebased(haystack)
        let needle = rebased(needle)
        guard !needle.isEmpty, haystack.count - start >= needle.count else { return nil }
        if caseInsensitive {
            let h = [UInt8](haystack)
            let n = [UInt8](needle).map(lower)
            var i = start
            let first = n[0]
            while i <= h.count - n.count {
                if lower(h[i]) == first {
                    var j = 1
                    while j < n.count, lower(h[i + j]) == n[j] { j += 1 }
                    if j == n.count { return i..<(i + n.count) }
                }
                i += 1
            }
            return nil
        }
        return haystack.withUnsafeBytes { (hay: UnsafeRawBufferPointer) -> Range<Int>? in
            needle.withUnsafeBytes { (pin: UnsafeRawBufferPointer) -> Range<Int>? in
                guard let base = hay.baseAddress, let p = pin.baseAddress else { return nil }
                guard let hit = memmem(base + start, hay.count - start, p, pin.count) else { return nil }
                let offset = base.distance(to: UnsafeRawPointer(hit))
                return offset..<(offset + pin.count)
            }
        }
    }

    public static func count(_ haystack: Data, _ needle: Data) -> Int {
        var n = 0
        var from = 0
        while let r = range(haystack, needle, from: from) {
            n += 1
            from = r.upperBound
        }
        return n
    }

    static func rebased(_ data: Data) -> Data { data.startIndex == 0 ? data : Data(data) }

    public static func replaceAll(_ haystack: Data, _ needle: Data, with replacement: Data) -> (Data, Int) {
        let haystack = rebased(haystack)
        var out = Data()
        var from = 0
        var count = 0
        while let r = range(haystack, needle, from: from) {
            out.append(haystack.subdata(in: from..<r.lowerBound))
            out.append(replacement)
            from = r.upperBound
            count += 1
        }
        guard count > 0 else { return (haystack, 0) }
        out.append(haystack.subdata(in: from..<haystack.count))
        return (out, count)
    }

    private static func lower(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }
}
