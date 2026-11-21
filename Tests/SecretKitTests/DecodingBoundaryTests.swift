import Compression
import Foundation
import Testing

@testable import SecretKit

/// v1.0.0 review N02: a `\uXXXX` escape (or surrogate pair) ending exactly at the end of the inspected buffer must be
/// unescaped like any other, so a value echoed with its last character escaped is still found.
@Suite("JSON unescape at buffer boundaries", .timeLimit(.minutes(1)))
struct JSONUnescapeBoundaryTests {
    static func escape(_ scalar: Unicode.Scalar, upper: Bool = false) -> String {
        func four(_ v: UInt32) -> String { String(format: upper ? "\\u%04X" : "\\u%04x", v) }
        if scalar.value > 0xFFFF {
            let v = scalar.value - 0x10000
            return four(0xD800 + (v >> 10)) + four(0xDC00 + (v & 0x3FF))
        }
        return four(scalar.value)
    }

    @Test func escapeAtTheVeryEndIsDecoded() {
        #expect(SecretPatterns.jsonUnescaped(Data("abcd123\\u0034".utf8)) == Data("abcd1234".utf8))
        #expect(SecretPatterns.jsonUnescaped(Data("\\u0041".utf8)) == Data("A".utf8))
        // A surrogate pair occupying the final 12 bytes.
        #expect(SecretPatterns.jsonUnescaped(Data("x\\ud83d\\ude00".utf8)) == Data("x😀".utf8))
        #expect(SecretPatterns.jsonUnescaped(Data("\\uD83D\\uDE00".utf8)) == Data("😀".utf8))
    }

    @Test func theExampleFromTheReviewIsBlockedByTheResponseFilter() {
        let filter = ResponseFilter(secrets: [.init(account: "a", value: Data("abcd1234".utf8), replacement: "bcsec_X")])
        for body in ["abcd123\\u0034", "{\"k\":\"abcd123\\u0034\"}"] {
            if case .pass = filter.filter(headers: [], body: Data(body.utf8)) { Issue.record("body passed: escape at end") }
        }
        if case .pass = filter.filter(headers: [HTTPField("X-Echo", "abcd123\\u0034")], body: Data()) {
            Issue.record("header value passed with the last character escaped")
        }
    }

    /// Every scalar of the value escaped in turn, every suffix escaped, with 0…3 trailing bytes: always found.
    @Test func everyEscapePositionAndBoundaryIsFound() {
        for value in ["sk_live_CANARY_7f3a9c1e", "pässwörd-Ωmega-123", "tok😀en-🔑-value9"] {
            let patterns = SecretPatterns(value: Data(value.utf8))
            let scalars = Array(value.unicodeScalars)
            for index in scalars.indices {
                for upper in [false, true] {
                    var one = ""
                    var suffix = ""
                    for (k, s) in scalars.enumerated() {
                        one += k == index ? Self.escape(s, upper: upper) : String(s)
                        suffix += k >= index ? Self.escape(s, upper: upper) : String(s)
                    }
                    for text in [one, suffix] {
                        for trailing in ["", "\"", "\"}", " \\"] {
                            let body = Data(("{\"v\":\"" + text + trailing).utf8)
                            #expect(!patterns.forms(in: body).isEmpty, "\(value) escaped at \(index) (upper \(upper)) + \(trailing.debugDescription)")
                            #expect(!patterns.forms(in: Data((text + trailing).utf8)).isEmpty)
                        }
                    }
                }
            }
        }
    }

    /// Every truncation of escape-heavy text: never traps, never reads past the end, and every complete escape that
    /// fits is decoded exactly as a full-length decode would.
    @Test func everyTruncationIsSafeAndExact() {
        let text = "a\\u0041\\uD83D\\uDE00\\n\\x41\\u00e9\\\\\\u"
        let bytes = Array(text.utf8)
        for cut in 0...bytes.count {
            _ = SecretPatterns.jsonUnescaped(Data(bytes[0..<cut]))
        }
        // Prefixes that end on an escape boundary decode to the same prefix of the full decode.
        let boundaries = [1, 7, 19, 21, 25, 31, 33]
        let full = SecretPatterns.jsonUnescaped(Data(bytes))
        for cut in boundaries {
            let part = SecretPatterns.jsonUnescaped(Data(bytes[0..<cut]))
            #expect(full.starts(with: part), "cut \(cut)")
        }
        #expect(SecretPatterns.jsonUnescaped(Data(bytes[0..<7])) == Data("aA".utf8))
        #expect(SecretPatterns.jsonUnescaped(Data(bytes[0..<19])) == Data("aA😀".utf8))
        // A lone high surrogate at the end, and a truncated low half, decode without the pair.
        #expect(SecretPatterns.jsonUnescaped(Data(bytes[0..<13])) == Data("aA".utf8))
        #expect(SecretPatterns.jsonUnescaped(Data(bytes[0..<18])).starts(with: Data("aA".utf8)))
    }
}
