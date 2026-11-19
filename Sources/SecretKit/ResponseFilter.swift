import Compression
import Foundation

/// Decoding of response bodies before scanning (identity, gzip, deflate, brotli). Anything else cannot be scanned.
public enum ContentDecoding {
    public struct Unsupported: Error, Sendable { public var encoding: String }
    public struct Corrupt: Error, Sendable {}
    public struct TooLarge: Error, Sendable {}

    /// Decodes `data` per a `Content-Encoding` list (applied in order, so decoded in reverse), bounded by `limit`.
    public static func decode(_ data: Data, contentEncoding: String?, limit: Int) throws -> Data {
        let codings = (contentEncoding ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "identity" }
        var current = data
        for coding in codings.reversed() {
            switch coding {
            case "gzip", "x-gzip": current = try gunzip(current, limit: limit)
            case "deflate": current = try inflateZlibOrRaw(current, limit: limit)
            case "br": current = try decompress(current, algorithm: COMPRESSION_BROTLI, limit: limit)
            default: throw Unsupported(encoding: coding)
            }
        }
        return current
    }

    static func gunzip(_ data: Data, limit: Int) throws -> Data {
        // Concatenated members are allowed (RFC 1952); each: header, raw deflate, 8-byte trailer.
        var output = Data()
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            guard bytes.count - offset >= 18, bytes[offset] == 0x1F, bytes[offset + 1] == 0x8B, bytes[offset + 2] == 8 else {
                if output.isEmpty { throw Corrupt() } else { break }
            }
            let flags = bytes[offset + 3]
            var index = offset + 10
            if flags & 0x04 != 0 {
                guard index + 2 <= bytes.count else { throw Corrupt() }
                index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
            }
            if flags & 0x08 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }
            if flags & 0x10 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }
            if flags & 0x02 != 0 { index += 2 }
            guard index < bytes.count else { throw Corrupt() }
            let (inflated, consumed) = try inflateRaw(Data(bytes[index...]), limit: limit - output.count)
            output.append(inflated)
            offset = index + consumed + 8
        }
        return output
    }

    static func inflateZlibOrRaw(_ data: Data, limit: Int) throws -> Data {
        let bytes = [UInt8](data)
        // zlib wrapper: CMF/FLG with (CMF*256+FLG) % 31 == 0 and method 8.
        if bytes.count >= 2, bytes[0] & 0x0F == 8, (Int(bytes[0]) * 256 + Int(bytes[1])) % 31 == 0 {
            return try inflateRaw(Data(bytes[2...]), limit: limit).0
        }
        return try inflateRaw(data, limit: limit).0
    }

    /// Raw deflate. Returns the output and how many input bytes the stream used.
    static func inflateRaw(_ data: Data, limit: Int) throws -> (Data, Int) {
        try stream(data, algorithm: COMPRESSION_ZLIB, limit: limit)
    }

    static func decompress(_ data: Data, algorithm: compression_algorithm, limit: Int) throws -> Data {
        try stream(data, algorithm: algorithm, limit: limit).0
    }

    private static func stream(_ data: Data, algorithm: compression_algorithm, limit: Int) throws -> (Data, Int) {
        guard !data.isEmpty else { return (Data(), 0) }
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { throw Corrupt() }
        defer { compression_stream_destroy(streamPointer) }
        let chunk = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { destination.deallocate() }
        var output = Data()
        return try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> (Data, Int) in
            streamPointer.pointee.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
            streamPointer.pointee.src_size = source.count
            while true {
                streamPointer.pointee.dst_ptr = destination
                streamPointer.pointee.dst_size = chunk
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(destination, count: chunk - streamPointer.pointee.dst_size)
                if output.count > limit { throw TooLarge() }
                switch status {
                case COMPRESSION_STATUS_OK:
                    if streamPointer.pointee.src_size == 0, streamPointer.pointee.dst_size == chunk { throw Corrupt() }
                    continue
                case COMPRESSION_STATUS_END:
                    return (output, source.count - streamPointer.pointee.src_size)
                default:
                    throw Corrupt()
                }
            }
        }
    }
}

/// What to do with a response from a destination that may have received a secret.
public enum ResponseVerdict: Sendable {
    /// Pass on: `body` decoded (no Content-Encoding), with any raw or simply escaped occurrence replaced.
    case pass(headers: [HTTPField], body: Data, redactions: [String: Int])
    /// Refused: the value is present in a form that cannot be replaced, or the body cannot be scanned.
    case block(reason: String, accounts: [String])
}

/// Scans a complete response (headers and decoded body) for secret values and their encodings.
public struct ResponseFilter: Sendable {
    public struct Secret: Sendable {
        public var account: String
        public var patterns: SecretPatterns
        /// What the agent sees instead (its placeholder, or a fixed marker).
        public var replacement: String

        public init(account: String, value: Data, replacement: String) {
            self.account = account
            patterns = SecretPatterns(value: value)
            self.replacement = replacement
        }
    }

    public var secrets: [Secret]
    public var bodyLimit: Int

    public init(secrets: [Secret], bodyLimit: Int = ResponseFilter.defaultBodyLimit) {
        self.secrets = secrets
        self.bodyLimit = bodyLimit
    }

    /// 16 MiB decoded.
    public static let defaultBodyLimit = 16 << 20

    public func filter(headers: [HTTPField], body: Data) -> ResponseVerdict {
        let decoded: Data
        do {
            decoded = try ContentDecoding.decode(body, contentEncoding: headers.first("Content-Encoding"), limit: bodyLimit)
        } catch let error as ContentDecoding.Unsupported {
            return .block(reason: "The response uses a content encoding BelloCode cannot inspect (\(error.encoding)).", accounts: [])
        } catch is ContentDecoding.TooLarge {
            return .block(reason: "The response is too large for BelloCode to inspect (more than \(bodyLimit >> 20) MB).", accounts: [])
        } catch {
            return .block(reason: "The response body could not be decoded for inspection.", accounts: [])
        }
        var outHeaders = headers
        outHeaders.remove("Content-Encoding")
        outHeaders.remove("Transfer-Encoding")
        outHeaders.remove("Content-Length")
        var outBody = decoded
        var redactions: [String: Int] = [:]
        var blocked: [String] = []
        for secret in secrets {
            let replacement = Data(secret.replacement.utf8)
            for index in outHeaders.indices {
                for part in [\HTTPField.name, \HTTPField.value] {
                    let data = Data(outHeaders[index][keyPath: part].utf8)
                    guard !secret.patterns.forms(in: data).isEmpty else { continue }
                    guard let (redacted, count) = secret.patterns.redact(data, replacement: replacement) else {
                        blocked.append(secret.account)
                        continue
                    }
                    if part == \HTTPField.name { outHeaders[index].name = String(decoding: redacted, as: UTF8.self) } else {
                        outHeaders[index].value = String(decoding: redacted, as: UTF8.self)
                    }
                    redactions[secret.account, default: 0] += count
                }
            }
            guard !secret.patterns.forms(in: outBody).isEmpty else { continue }
            guard let (redacted, count) = secret.patterns.redact(outBody, replacement: replacement) else {
                blocked.append(secret.account)
                continue
            }
            outBody = redacted
            redactions[secret.account, default: 0] += count
        }
        if !blocked.isEmpty {
            return .block(reason: "The response contained a secret's value in an encoded form, so BelloCode did not pass it on.", accounts: Array(Set(blocked)).sorted())
        }
        outHeaders.append(HTTPField("Content-Length", String(outBody.count)))
        return .pass(headers: outHeaders, body: outBody, redactions: redactions)
    }
}
