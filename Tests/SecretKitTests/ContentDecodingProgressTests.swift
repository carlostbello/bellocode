import Compression
import Foundation
import Testing

@testable import SecretKit

/// v1.0.0 review N08: a decoder step that neither consumes nor produces must end the decode as corrupt instead of
/// spinning (the libcompression behaviour GzipInflater 2652885 met).
@Suite("Content decoding progress", .timeLimit(.minutes(1)))
struct ContentDecodingProgressTests {
    @Test func aStalledDecoderIsCorruptNotASpin() {
        var calls = 0
        let stalled: ContentDecoding.Process = { _, _ in
            calls += 1
            // Keeps a regression from hanging the suite: after many calls, fail as the old loop eventually would.
            if calls > 1_000 { return COMPRESSION_STATUS_ERROR }
            return COMPRESSION_STATUS_OK  // consumed 0 bytes, produced 0 bytes, src_size still > 0
        }
        #expect(throws: ContentDecoding.Corrupt.self) {
            _ = try ContentDecoding.stream(Data([0x01, 0x02, 0x03]), algorithm: COMPRESSION_ZLIB, limit: 1 << 20, process: stalled)
        }
        #expect(calls == 1, "the decoder was called \(calls) times without progress")
    }

    @Test func malformedBodiesEndPromptly() {
        let payload = Data((0..<5_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let filter = ResponseFilter(secrets: [.init(account: "a", value: Data("sk_live_CANARY_7f3a9c1e".utf8), replacement: "bcsec_X")])
        for encoding in ["gzip", "deflate", "br"] {
            for sample in [payload.prefix(40), Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3]) + payload.prefix(30), Data(repeating: 0xFF, count: 64)] {
                if case .pass(_, let body, _) = filter.filter(headers: [HTTPField("Content-Encoding", encoding)], body: sample) {
                    #expect(body.count <= ResponseFilter.defaultBodyLimit)
                }
            }
        }
    }
}
