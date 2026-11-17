import Foundation
import Testing

@testable import ContainerKit

@Suite("HTTP and stream parsing")
struct ParsingTests {
    @Test func headParserWaitsForTerminatorAndKeepsRemainder() throws {
        var buffer = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nApi-Version: 1.56\r\nX-A: 1\r\nx-a: 2".utf8)
        #expect(try HTTPHeadParser.parse(&buffer) == nil)
        buffer.append(Data("\r\n\r\nok".utf8))
        let head = try #require(try HTTPHeadParser.parse(&buffer))
        #expect(head.status == 200)
        #expect(head.header("API-VERSION") == "1.56")
        #expect(head.header("x-a") == "1, 2")
        #expect(head.framing == .length(2))
        #expect(buffer == Data("ok".utf8))
    }

    @Test func framingRules() throws {
        func framing(_ text: String) throws -> HTTPResponseHead.BodyFraming {
            var buffer = Data((text + "\r\n\r\n").utf8)
            return try #require(try HTTPHeadParser.parse(&buffer)).framing
        }
        #expect(try framing("HTTP/1.1 101 UPGRADED\r\nUpgrade: tcp") == .none)
        #expect(try framing("HTTP/1.1 204 No Content") == .none)
        #expect(try framing("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 9") == .chunked)
        #expect(try framing("HTTP/1.1 200 OK") == .untilClose)
    }

    @Test func malformedStatusLineIsRejected() {
        var buffer = Data("SPDY nonsense\r\n\r\n".utf8)
        #expect(throws: HTTPParseError.malformedStatusLine) { try HTTPHeadParser.parse(&buffer) }
    }

    @Test func chunkedDecoderHandlesEveryByteBoundary() throws {
        let encoded = Data("5;ext=1\r\nhello\r\n1\r\n \r\n6\r\nworld!\r\n0\r\nTrailer: x\r\n\r\nNEXT".utf8)
        for split in 0...encoded.count {
            var decoder = ChunkedDecoder()
            let (a, restA) = try decoder.feed(encoded.prefix(split))
            let (b, restB) = try decoder.feed(encoded.dropFirst(split))
            #expect(String(decoding: a + b, as: UTF8.self) == "hello world!", "split at \(split)")
            #expect(decoder.isDone)
            #expect(String(decoding: restA + restB, as: UTF8.self) == "NEXT")
        }
        var bytewise = ChunkedDecoder()
        var out = Data()
        for byte in encoded.prefix(encoded.count - 4) { out += try bytewise.feed(Data([byte])).payload }
        #expect(out == Data("hello world!".utf8))
    }

    @Test func chunkedDecoderRejectsGarbage() {
        var decoder = ChunkedDecoder()
        #expect(throws: HTTPParseError.malformedChunk) { try decoder.feed(Data("zz\r\n".utf8)) }
    }

    @Test func demuxerReassemblesFramesAcrossArbitraryBoundaries() throws {
        let frames = StreamDemuxer.frame(.stdout, Data("out-1\n".utf8)) + StreamDemuxer.frame(.stderr, Data("err\n".utf8))
            + StreamDemuxer.frame(.stdout, Data()) + StreamDemuxer.frame(.stdout, Data("out-2".utf8))
        for split in 0...frames.count {
            var demuxer = StreamDemuxer()
            let chunks = try demuxer.feed(frames.prefix(split)) + demuxer.feed(frames.dropFirst(split))
            var out = Data(), err = Data()
            for chunk in chunks { if chunk.stream == .stderr { err += chunk.bytes } else { out += chunk.bytes } }
            #expect(out == Data("out-1\nout-2".utf8))
            #expect(err == Data("err\n".utf8))
            #expect(demuxer.isAtFrameBoundary)
        }
    }

    @Test func demuxerStreamsLargeFramesWithoutBufferingThem() throws {
        let payload = Data(repeating: 0x41, count: 3_000_000)
        let encoded = StreamDemuxer.frame(.stdout, payload)
        var demuxer = StreamDemuxer()
        var total = 0
        var largest = 0
        var index = 0
        while index < encoded.count {
            let piece = encoded[index..<min(encoded.count, index + 65_536)]
            for chunk in try demuxer.feed(Data(piece)) {
                total += chunk.bytes.count
                largest = max(largest, chunk.bytes.count)
            }
            index += 65_536
        }
        #expect(total == payload.count)
        #expect(largest <= 65_536, "emitted as it arrived")
        #expect(demuxer.isAtFrameBoundary)
    }

    @Test func demuxerRejectsUnknownStream() {
        var demuxer = StreamDemuxer()
        #expect(throws: DemuxError.badStreamType(9)) { try demuxer.feed(Data([9, 0, 0, 0, 0, 0, 0, 1, 0x41])) }
    }

    @Test func requestSerialisationHasHostAndLength() {
        let text = String(decoding: HTTPRequest(method: "POST", path: "/v1.45/containers/create?name=a", body: Data("{}".utf8)).serialized(), as: UTF8.self)
        #expect(text.hasPrefix("POST /v1.45/containers/create?name=a HTTP/1.1\r\nHost: docker\r\n"))
        #expect(text.contains("Content-Length: 2\r\n\r\n{}"))
        let empty = String(decoding: HTTPRequest(method: "POST", path: "/x").serialized(), as: UTF8.self)
        #expect(empty.contains("Content-Length: 0"))
    }

    @Test func tarHeadersHaveValidChecksumsAndPadding() throws {
        var tar = TarArchive()
        tar.add("Dockerfile", "FROM scratch\n")
        tar.entries.append(.init(path: "dir", isDirectory: true))
        let data = tar.data()
        #expect(data.count % 512 == 0)
        #expect(data.count == 512 + 512 + 512 + 1024)
        for offset in [0, 1024] {
            let header = [UInt8](data[offset..<(offset + 512)])
            var copy = header
            copy.replaceSubrange(148..<156, with: Array(repeating: 0x20, count: 8))
            let expected = copy.reduce(0) { $0 + Int($1) }
            let field = String(decoding: header[148..<154], as: UTF8.self)
            #expect(Int(field, radix: 8) == expected)
            #expect(String(decoding: header[257..<262], as: UTF8.self) == "ustar")
        }
        #expect(String(decoding: data[512..<525], as: UTF8.self) == "FROM scratch\n")
        #expect(data[1024 + 156] == UInt8(ascii: "5"))
    }

    @Test func referenceSplitting() {
        #expect(EngineClient.split("node:22-bookworm-slim") == ("node", "22-bookworm-slim"))
        #expect(EngineClient.split("registry.local:5000/team/img") == ("registry.local:5000/team/img", "latest"))
        #expect(EngineClient.split("registry.local:5000/team/img:1.2") == ("registry.local:5000/team/img", "1.2"))
        #expect(EngineClient.split("img@sha256:abc").0 == "img@sha256:abc")
    }
}
