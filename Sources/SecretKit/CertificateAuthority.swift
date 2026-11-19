import CryptoKit
import Foundation
import Security
import Synchronization

/// Minimal DER encoding for X.509 certificates.
enum DER {
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func sequence(_ parts: [[UInt8]]) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    static func set(_ parts: [[UInt8]]) -> [UInt8] { tlv(0x31, parts.flatMap { $0 }) }
    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var content = Array(bytes.drop { $0 == 0 })
        if content.isEmpty { content = [0] }
        if content[0] & 0x80 != 0 { content.insert(0, at: 0) }
        return tlv(0x02, content)
    }
    static func integer(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        return integer(bytes)
    }
    static func bitString(_ bytes: [UInt8], unusedBits: UInt8 = 0) -> [UInt8] { tlv(0x03, [unusedBits] + bytes) }
    static func octetString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }
    static func boolean(_ value: Bool) -> [UInt8] { tlv(0x01, [value ? 0xFF : 0x00]) }
    static func utf8String(_ text: String) -> [UInt8] { tlv(0x0C, Array(text.utf8)) }
    static func explicit(_ number: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | number, content) }

    static func oid(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").compactMap { Int($0) }
        var content: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for part in parts.dropFirst(2) {
            var stack: [UInt8] = [UInt8(part & 0x7F)]
            var value = part >> 7
            while value > 0 {
                stack.insert(UInt8(0x80 | (value & 0x7F)), at: 0)
                value >>= 7
            }
            content += stack
        }
        return tlv(0x06, content)
    }

    static func time(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2026
        if year >= 2050 {
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            return tlv(0x18, Array(formatter.string(from: date).utf8))
        }
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Array(formatter.string(from: date).utf8))
    }

    static func name(commonName: String, organization: String) -> [UInt8] {
        sequence([
            set([sequence([oid("2.5.4.10"), utf8String(organization)])]),
            set([sequence([oid("2.5.4.3"), utf8String(commonName)])]),
        ])
    }

    static func extensionField(_ oidString: String, critical: Bool, _ value: [UInt8]) -> [UInt8] {
        sequence([oid(oidString)] + (critical ? [boolean(true)] : []) + [octetString(value)])
    }

    /// One TLV at `offset`: its tag, the content's range and the end of the whole element. Nil when malformed.
    static func element(_ bytes: [UInt8], at offset: Int) -> (tag: UInt8, content: Range<Int>, end: Int)? {
        guard offset + 2 <= bytes.count else { return nil }
        let tag = bytes[offset]
        var index = offset + 1
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), index + count <= bytes.count else { return nil }
            length = 0
            for byte in bytes[index..<index + count] { length = length << 8 | Int(byte) }
            index += count
        }
        guard length >= 0, index + length <= bytes.count else { return nil }
        return (tag, index..<index + length, index + length)
    }

    /// The certificate's TBS subject Name and subject public key info, as encoded (whole TLVs).
    static func subjectAndKey(certificate der: [UInt8]) -> (subject: [UInt8], spki: [UInt8])? {
        guard let certificate = element(der, at: 0), certificate.tag == 0x30,
              let tbs = element(der, at: certificate.content.lowerBound), tbs.tag == 0x30 else { return nil }
        var fields: [(tag: UInt8, range: Range<Int>)] = []
        var offset = tbs.content.lowerBound
        while offset < tbs.content.upperBound, fields.count < 7, let field = element(der, at: offset) {
            fields.append((field.tag, offset..<field.end))
            offset = field.end
        }
        // [0] version (optional), serial, signature algorithm, issuer, validity, subject, subject public key info.
        if fields.first?.tag == 0xA0 { fields.removeFirst() }
        guard fields.count >= 6, fields[4].tag == 0x30, fields[5].tag == 0x30 else { return nil }
        return (Array(der[fields[4].range]), Array(der[fields[5].range]))
    }
}

public struct CertificateError: Error, CustomStringConvertible, Sendable {
    public var description: String
    init(_ description: String) { self.description = description }
}

// `SecIdentityCreate` is exported by Security.framework on macOS but not declared in the SDK headers; it pairs a
// certificate with its private key without adding either to a keychain.
@_silgen_name("SecIdentityCreate")
private func SecIdentityCreateWithKey(_ allocator: CFAllocator?, _ certificate: SecCertificate, _ privateKey: SecKey) -> Unmanaged<SecIdentity>?

/// The egress proxy's certificate authority (docs/features/secrets.md "Egress"). One P-256 root, kept by the caller
/// (its private key in the Keychain); per-host leaf certificates are issued in memory and cached.
public final class CertificateAuthority: Sendable {
    public let certificateDER: Data
    /// CF key objects are immutable and thread-safe but not marked `Sendable`; the mutex carries them.
    private struct Keys {
        var privateKey: SecKey
        /// One key for every leaf (issuing is then one signature).
        var leafKey: SecKey
        var leaves: [String: SecIdentity] = [:]
    }

    private let keys: Mutex<Keys>
    private let subjectKeyID: [UInt8]
    /// The root's subject Name exactly as encoded in its certificate: every leaf's issuer (R05). A restored authority
    /// takes it from the persisted certificate, never from a default name, so leaves chain to the root clients trust.
    private let issuerName: [UInt8]
    private let leafSPKI: [UInt8]

    public var certificate: SecCertificate { SecCertificateCreateWithData(nil, certificateDER as CFData)! }
    public static let maxCachedLeaves = 256

    /// A new authority (`privateKeyData`: nil) or one restored from its key (X9.63) and certificate. A restore takes the
    /// subject from the certificate (`commonName` is then unused) and throws if the certificate is unreadable or holds
    /// another key.
    public init(privateKeyData: Data? = nil, certificateDER: Data? = nil, commonName: String = "BelloCode Egress CA") throws {
        let key: SecKey
        if let privateKeyData {
            var error: Unmanaged<CFError>?
            guard let restored = SecKeyCreateWithData(privateKeyData as CFData, [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            ] as CFDictionary, &error) else { throw CertificateError("The CA key could not be restored.") }
            key = restored
        } else {
            key = try Self.makeKey()
        }
        let spki = try Self.spki(of: key)
        subjectKeyID = Array(Insecure.SHA1.hash(data: Data(Self.publicKeyBits(of: key))))
        if let certificateDER {
            // Restore: the certificate must parse and hold this key's public half; its subject is the issuer.
            guard SecCertificateCreateWithData(nil, certificateDER as CFData) != nil,
                  let (subject, certificateSPKI) = DER.subjectAndKey(certificate: Array(certificateDER))
            else { throw CertificateError("The CA certificate could not be read.") }
            guard certificateSPKI == spki else { throw CertificateError("The CA certificate does not match its key.") }
            self.certificateDER = certificateDER
            issuerName = subject
        } else {
            let der = try Self.sign(
                tbs: Self.tbs(serial: Self.serial(), issuer: DER.name(commonName: commonName, organization: "BelloCode"),
                              subject: DER.name(commonName: commonName, organization: "BelloCode"),
                              notBefore: Date().addingTimeInterval(-3_600), notAfter: Date().addingTimeInterval(825 * 86_400),
                              spki: spki, extensions: [
                                DER.extensionField("2.5.29.19", critical: true, DER.sequence([DER.boolean(true), DER.integer(0)])),
                                DER.extensionField("2.5.29.15", critical: true, DER.bitString([0x06], unusedBits: 1)),
                                DER.extensionField("2.5.29.14", critical: false, DER.octetString(subjectKeyID)),
                              ]),
                key: key)
            guard SecCertificateCreateWithData(nil, Data(der) as CFData) != nil else { throw CertificateError("The CA certificate is invalid.") }
            self.certificateDER = Data(der)
            issuerName = DER.name(commonName: commonName, organization: "BelloCode")
        }
        let leafKey = try Self.makeKey()
        leafSPKI = try Self.spki(of: leafKey)
        keys = Mutex(Keys(privateKey: key, leafKey: leafKey))
    }

    /// The private key (X9.63), for the caller to keep in the Keychain.
    public func privateKeyData() throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = keys.withLock({ SecKeyCopyExternalRepresentation($0.privateKey, &error) as Data? }) else { throw CertificateError("The CA key could not be exported.") }
        return data
    }

    public var pem: String { Self.pem(certificateDER) }

    public static func pem(_ der: Data) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
    }

    /// SHA-256 of the certificate (hex).
    public var fingerprint: String { SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined() }

    /// A TLS identity for `host` (a DNS name or an IP literal), cached.
    public func identity(for host: String) throws -> SecIdentity {
        let key = host.lowercased()
        return try keys.withLock { keys in
            if let cached = keys.leaves[key] { return cached }
            let identity = try issue(key, keys: keys)
            if keys.leaves.count >= Self.maxCachedLeaves { keys.leaves.removeAll() }
            keys.leaves[key] = identity
            return identity
        }
    }

    private func issue(_ key: String, keys: Keys) throws -> SecIdentity {
        let san: [UInt8]
        if let ip = Self.ipBytes(key) {
            san = DER.sequence([DER.tlv(0x87, ip)])
        } else {
            san = DER.sequence([DER.tlv(0x82, Array(key.utf8))])
        }
        let leafKeyID = Array(Insecure.SHA1.hash(data: Data(leafSPKI)))
        let der = try Self.sign(
            tbs: Self.tbs(serial: Self.serial(), issuer: issuerName,
                          subject: DER.name(commonName: String(key.prefix(64)), organization: "BelloCode egress proxy"),
                          notBefore: Date().addingTimeInterval(-3_600), notAfter: Date().addingTimeInterval(30 * 86_400),
                          spki: leafSPKI, extensions: [
                            DER.extensionField("2.5.29.19", critical: true, DER.sequence([])),
                            DER.extensionField("2.5.29.15", critical: true, DER.bitString([0x80], unusedBits: 7)),
                            DER.extensionField("2.5.29.37", critical: false, DER.sequence([DER.oid("1.3.6.1.5.5.7.3.1")])),
                            DER.extensionField("2.5.29.17", critical: false, san),
                            DER.extensionField("2.5.29.14", critical: false, DER.octetString(leafKeyID)),
                            DER.extensionField("2.5.29.35", critical: false, DER.sequence([DER.tlv(0x80, subjectKeyID)])),
                          ]),
            key: keys.privateKey)
        guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData),
              let identity = SecIdentityCreateWithKey(nil, certificate, keys.leafKey)?.takeRetainedValue()
        else { throw CertificateError("The certificate for \(key) could not be made.") }
        return identity
    }

    // MARK: Building blocks

    static func makeKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256,
        ] as CFDictionary, &error) else { throw CertificateError("A key could not be generated.") }
        return key
    }

    static func publicKeyBits(of key: SecKey) -> [UInt8] {
        guard let pub = SecKeyCopyPublicKey(key), let data = SecKeyCopyExternalRepresentation(pub, nil) as Data? else { return [] }
        return Array(data)
    }

    static func spki(of key: SecKey) throws -> [UInt8] {
        let bits = publicKeyBits(of: key)
        guard bits.count == 65 else { throw CertificateError("Unexpected public key.") }
        return DER.sequence([DER.sequence([DER.oid("1.2.840.10045.2.1"), DER.oid("1.2.840.10045.3.1.7")]), DER.bitString(bits)])
    }

    static func serial() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] &= 0x7F
        bytes[0] |= 0x01
        return bytes
    }

    static let signatureAlgorithm = DER.sequence([DER.oid("1.2.840.10045.4.3.2")])

    static func tbs(serial: [UInt8], issuer: [UInt8], subject: [UInt8], notBefore: Date, notAfter: Date, spki: [UInt8],
                    extensions: [[UInt8]]) -> [UInt8] {
        DER.sequence([
            DER.explicit(0, DER.integer(2)), DER.integer(serial), signatureAlgorithm, issuer,
            DER.sequence([DER.time(notBefore), DER.time(notAfter)]), subject, spki,
            DER.explicit(3, DER.sequence(extensions)),
        ])
    }

    static func sign(tbs: [UInt8], key: SecKey) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &error) as Data? else {
            throw CertificateError("Signing failed.")
        }
        return DER.sequence([tbs, signatureAlgorithm, DER.bitString(Array(signature))])
    }

    static func ipBytes(_ host: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        var v6 = in6_addr()
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if inet_pton(AF_INET6, trimmed, &v6) == 1 { return withUnsafeBytes(of: v6) { Array($0) } }
        return nil
    }
}
