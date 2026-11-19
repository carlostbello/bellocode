import Compression
import Foundation
import Testing

@testable import SecretKit

/// The value scanner and response filter (docs/features/secrets.md "Responses").
@Suite("Secret scanner", .timeLimit(.minutes(1)))
struct ScannerTests {
    static let value = "sk_live_CANARY_7f3a9c1e5b2d4f60"
    let patterns = SecretPatterns(value: Data(ScannerTests.value.utf8))

    @Test func findsEveryCommonEncoding() {
        let v = Data(Self.value.utf8)
        let samples: [(String, Data, SecretPatterns.Form)] = [
            ("raw", Data("x=\(Self.value);".utf8), .raw),
            ("hex lower", Data(v.map { String(format: "%02x", $0) }.joined().utf8), .hex),
            ("hex upper", Data(v.map { String(format: "%02X", $0) }.joined().utf8), .hex),
            ("base64", Data(v.base64EncodedString().utf8), .base64),
            ("base64 offset 1", Data(Data("a".utf8 + v).base64EncodedString().utf8), .base64),
            ("base64 offset 2", Data(Data("ab".utf8 + v + Data("tail".utf8)).base64EncodedString().utf8), .base64),
            ("base64 wrapped", Data((Data("hdr".utf8 + v + v + v).base64EncodedString(options: .lineLength64Characters)).utf8), .base64),
            ("base64url", Data(Data("??>".utf8 + v).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").utf8), .base64),
        ]
        for (name, data, form) in samples {
            #expect(patterns.forms(in: data).contains(form), "\(name)")
        }
        #expect(patterns.forms(in: Data("nothing to see sk_live_CANARY".utf8)).isEmpty)
    }

    @Test func jsonAndURLForms() {
        let odd = "a/b\"c\\d é+&="
        let p = SecretPatterns(value: Data(odd.utf8))
        let json = try! JSONSerialization.data(withJSONObject: ["k": odd], options: [.withoutEscapingSlashes])
        #expect(!p.forms(in: json).isEmpty)
        let escapedSlash = Data(String(decoding: json, as: UTF8.self).replacingOccurrences(of: "/", with: "\\/").utf8)
        #expect(!p.forms(in: escapedSlash).isEmpty)
        let url = odd.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(p.forms(in: Data("q=\(url)".utf8)).contains(.url))
    }

    @Test func partialAndMixedEscapesAreFound() {
        let partial = Self.value.replacingOccurrences(of: "_", with: "%5F")
        #expect(patterns.forms(in: Data("Location: https://x/?k=Bearer%20\(partial)".utf8)) == [.decoded])
        let mixed = Self.value.replacingOccurrences(of: "C", with: "\\u0043")
        #expect(patterns.forms(in: Data("{\"a\":\"\(mixed)\"}".utf8)) == [.decoded])
        let nested = Self.value.replacingOccurrences(of: "_", with: "\\u0025\\u0035F")  // \u0025 = %, then 5F
        #expect(!patterns.forms(in: Data(nested.utf8)).isEmpty)
        // Found only in a decoded view: cannot be replaced, so blocked.
        #expect(patterns.redact(Data(partial.utf8), replacement: Data("p".utf8)) == nil)
    }

    @Test func redactsReplaceableFormsAndRefusesOthers() {
        let raw = Data("{\"echo\":\"Bearer \(Self.value)\"}".utf8)
        let redacted = patterns.redact(raw, replacement: Data("bcsec_X".utf8))
        #expect(redacted?.replaced == 1)
        #expect(!(redacted.map { ByteSearch.contains($0.data, Data(Self.value.utf8)) } ?? true))
        let encoded = Data(Data(Self.value.utf8).base64EncodedString().utf8)
        #expect(patterns.redact(encoded, replacement: Data("bcsec_X".utf8)) == nil)
    }

    static func gzip(_ data: Data) -> Data {
        let deflated = deflate(data)
        var out = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
        out.append(deflated)
        out.append(contentsOf: [UInt8](repeating: 0, count: 8))  // CRC and size are not checked by the scanner
        return out
    }

    static func deflate(_ data: Data) -> Data {
        let capacity = data.count + 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let size = data.withUnsafeBytes { compression_encode_buffer(destination, capacity, $0.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB) }
        return Data(bytes: destination, count: size)
    }

    static func brotli(_ data: Data) -> Data {
        let capacity = data.count + 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let size = data.withUnsafeBytes { compression_encode_buffer(destination, capacity, $0.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_BROTLI) }
        return Data(bytes: destination, count: size)
    }

    @Test func filterDecodesCompressedBodies() {
        let filter = ResponseFilter(secrets: [.init(account: "a", value: Data(Self.value.utf8), replacement: "bcsec_PLACEHOLDER")])
        let body = Data("token=\(Self.value)".utf8)
        for (encoding, encoded) in [("gzip", Self.gzip(body)), ("deflate", Self.deflate(body)), ("br", Self.brotli(body)), ("identity", body)] {
            guard case .pass(let headers, let out, let redactions) = filter.filter(headers: [HTTPField("Content-Encoding", encoding)], body: encoded) else {
                Issue.record("\(encoding) blocked"); continue
            }
            #expect(String(decoding: out, as: UTF8.self) == "token=bcsec_PLACEHOLDER", "\(encoding)")
            #expect(headers.first("Content-Encoding") == nil && headers.first("Content-Length") == String(out.count))
            #expect(redactions["a"] == 1)
        }
        let gzBase64 = Self.gzip(Data(Data(Self.value.utf8).base64EncodedString().utf8))
        guard case .block = filter.filter(headers: [HTTPField("Content-Encoding", "gzip")], body: gzBase64) else { Issue.record("gzip base64 passed"); return }
        guard case .block = filter.filter(headers: [HTTPField("Content-Encoding", "zstd")], body: body) else { Issue.record("zstd passed"); return }
        guard case .block = filter.filter(headers: [HTTPField("X-Echo", Data(Self.value.utf8).map { String(format: "%02x", $0) }.joined())], body: Data()) else {
            Issue.record("hex header passed"); return
        }
        guard case .pass(let h, _, _) = filter.filter(headers: [HTTPField("Location", "https://x/?k=\(Self.value)")], body: Data()) else { Issue.record("header"); return }
        #expect(h.first("Location") == "https://x/?k=bcsec_PLACEHOLDER")
    }

    @Test func decompressionBombIsBounded() {
        let big = Data(repeating: 0x41, count: 4 << 20)
        let filter = ResponseFilter(secrets: [.init(account: "a", value: Data(Self.value.utf8), replacement: "p")], bodyLimit: 1 << 20)
        guard case .block = filter.filter(headers: [HTTPField("Content-Encoding", "gzip")], body: Self.gzip(big)) else { Issue.record("bomb passed"); return }
    }

    @Test func pathNormalisation() {
        #expect(RequestPath.normalized("/v1/a%20b") == "/v1/a b")
        for bad in ["/v1/../x", "/v1/%2E%2E/x", "/a%2Fb", "x", "/a//b", "/a/%00", "/a%252e"] { #expect(RequestPath.normalized(bad) == nil, "\(bad)") }
    }

    @Test func certificateAuthorityIssuesTrustedLeaves() throws {
        let ca = try CertificateAuthority()
        let identity = try ca.identity(for: "api.example.com")
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        let trust = try #require({ () -> SecTrust? in
            var trust: SecTrust?
            SecTrustCreateWithCertificates([certificate!] as CFArray, SecPolicyCreateSSL(true, "api.example.com" as CFString), &trust)
            return trust
        }())
        SecTrustSetAnchorCertificates(trust, [ca.certificate] as CFArray)
        var error: CFError?
        #expect(SecTrustEvaluateWithError(trust, &error), "\(String(describing: error))")
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "other.example.com" as CFString))
        #expect(!SecTrustEvaluateWithError(trust, nil))
        // Restored from its key and certificate, the same authority.
        let restored = try CertificateAuthority(privateKeyData: try ca.privateKeyData(), certificateDER: ca.certificateDER)
        #expect(restored.fingerprint == ca.fingerprint)
        #expect(ca.pem.hasPrefix("-----BEGIN CERTIFICATE-----"))
        _ = try ca.identity(for: "127.0.0.1")
    }
}
