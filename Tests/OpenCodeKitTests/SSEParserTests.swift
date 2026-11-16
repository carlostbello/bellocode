import Foundation
import Testing
@testable import OpenCodeKit

@Suite("SSE parser (WHATWG event stream)")
struct SSEParserTests {
    private func parse(_ text: String) throws -> [SSEEvent] {
        try parse(Array(text.utf8))
    }

    private func parse(_ bytes: [UInt8]) throws -> [SSEEvent] {
        var parser = SSEParser()
        return try parser.feed(bytes)
    }

    @Test func singleEvent() throws {
        #expect(try parse("data: hello\n\n") == [SSEEvent(data: "hello")])
    }

    @Test func multiLineDataIsJoinedWithLineFeed() throws {
        #expect(try parse("data: one\ndata: two\ndata:three\n\n") == [SSEEvent(data: "one\ntwo\nthree")])
    }

    @Test func emptyDataLineDispatchesEmptyString() throws {
        #expect(try parse("data\n\n") == [SSEEvent(data: "")])
        #expect(try parse("data:\n\n") == [SSEEvent(data: "")])
        #expect(try parse("data\ndata\n\n") == [SSEEvent(data: "\n")])
    }

    @Test func blockWithoutDataDispatchesNothing() throws {
        #expect(try parse("event: ping\n\n").isEmpty)
        #expect(try parse("id: 1\n\n").isEmpty)
        #expect(try parse("\n\n\n").isEmpty)
    }

    @Test func eventTypeIsSetAndResetPerEvent() throws {
        let events = try parse("event: add\ndata: 1\n\ndata: 2\n\n")
        #expect(events.map(\.type) == ["add", "message"])
    }

    @Test(arguments: ["\n", "\r", "\r\n"])
    func lineEndings(_ newline: String) throws {
        let text = "event: x\(newline)data: a\(newline)data: b\(newline)\(newline)data: c\(newline)\(newline)"
        #expect(try parse(text) == [SSEEvent(type: "x", data: "a\nb"), SSEEvent(data: "c")])
    }

    @Test func mixedLineEndings() throws {
        #expect(try parse("data: a\r\ndata: b\rdata: c\n\r\n") == [SSEEvent(data: "a\nb\nc")])
    }

    @Test func crlfSplitAcrossChunksIsOneLineEnding() throws {
        var parser = SSEParser()
        var events = try parser.feed(Array("data: a\r".utf8))
        events += try parser.feed(Array("\ndata: b\r".utf8))
        events += try parser.feed(Array("\n\r".utf8))
        events += try parser.feed(Array("\n".utf8))
        #expect(events == [SSEEvent(data: "a\nb")])
    }

    @Test func commentsAreIgnoredAndCounted() throws {
        var parser = SSEParser()
        let events = try parser.feed(Array(": heartbeat\n\n:another\ndata: x\n: mid\n\n".utf8))
        #expect(events == [SSEEvent(data: "x")])
        #expect(parser.commentCount == 3)
    }

    @Test func onlyOneLeadingSpaceIsStripped() throws {
        #expect(try parse("data:  two spaces\n\n") == [SSEEvent(data: " two spaces")])
        #expect(try parse("data:no space\n\n") == [SSEEvent(data: "no space")])
    }

    @Test func fieldWithoutColonUsesEmptyValue() throws {
        #expect(try parse("data\n\n") == [SSEEvent(data: "")])
    }

    @Test func unknownFieldsAreIgnored() throws {
        #expect(try parse("foo: bar\ndata: x\nDATA: y\n\n") == [SSEEvent(data: "x")])
    }

    @Test func colonsInValueAreKept() throws {
        #expect(try parse("data: {\"a\":\"b:c\"}\n\n") == [SSEEvent(data: "{\"a\":\"b:c\"}")])
    }

    @Test func idPersistsAcrossEventsAndCanBeReset() throws {
        let events = try parse("id: 7\ndata: a\n\ndata: b\n\nid\ndata: c\n\n")
        #expect(events.map(\.lastEventID) == ["7", "7", ""])
    }

    @Test func idContainingNullIsIgnored() throws {
        var bytes = Array("id: 1\ndata: a\n\nid: 2".utf8)
        bytes.append(0)
        bytes += Array("x\ndata: b\n\n".utf8)
        #expect(try parse(bytes).map(\.lastEventID) == ["1", "1"])
    }

    @Test func retryAcceptsOnlyDigits() throws {
        var parser = SSEParser()
        _ = try parser.feed(Array("retry: 1500\n\n".utf8))
        #expect(parser.reconnectionTime == .milliseconds(1500))
        _ = try parser.feed(Array("retry: 2s\n\nretry: -1\n\nretry:\n\n".utf8))
        #expect(parser.reconnectionTime == .milliseconds(1500))
    }

    @Test func leadingBOMIsStrippedOnce() throws {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        #expect(try parse(bom + Array("data: a\n\n".utf8)) == [SSEEvent(data: "a")])
        // A second BOM is content: it makes the first line's field name "\u{FEFF}data", which is unknown.
        #expect(try parse(bom + bom + Array("data: a\n\n".utf8)).isEmpty)
    }

    @Test func bomSplitAcrossChunks() throws {
        var parser = SSEParser()
        var events = try parser.feed([0xEF])
        events += try parser.feed([0xBB])
        events += try parser.feed([0xBF] + Array("data: a\n\n".utf8))
        #expect(events == [SSEEvent(data: "a")])
    }

    @Test func partialBOMPrefixIsContent() throws {
        // 0xEF 0xBB followed by something else is not a BOM; the bytes are kept (and decode as U+FFFD).
        let events = try parse([0xEF, 0xBB] + Array("data: a\n\ndata: b\n\n".utf8))
        #expect(events == [SSEEvent(data: "b")])
    }

    @Test func utf8SplitAcrossChunksDecodesIntact() throws {
        let text = "data: héllo → 🌍 \u{2019}\n\n"
        let bytes = Array(text.utf8)
        for split in 1..<bytes.count {
            var parser = SSEParser()
            let events = try parser.feed(bytes[..<split]) + parser.feed(bytes[split...])
            #expect(events == [SSEEvent(data: "héllo → 🌍 \u{2019}")], "split at \(split)")
        }
    }

    @Test func invalidUTF8IsReplaced() throws {
        let events = try parse(Array("data: a".utf8) + [0xFF] + Array("b\n\n".utf8))
        #expect(events == [SSEEvent(data: "a\u{FFFD}b")])
    }

    @Test func unterminatedEventIsDiscardedAtEndOfStream() throws {
        var parser = SSEParser()
        #expect(try parser.feed(Array("data: complete\n\ndata: partial\n".utf8)) == [SSEEvent(data: "complete")])
        parser.finish()
        #expect(try parser.feed(Array("\n".utf8)).isEmpty)
    }

    @Test func oversizedLineThrows() {
        var parser = SSEParser(maxEventBytes: 16)
        #expect(throws: SSEParser.Failure.eventTooLarge(limit: 16)) {
            try parser.feed(Array("data: 0123456789abcdef\n\n".utf8))
        }
    }

    @Test func oversizedMultiLineEventThrows() {
        var parser = SSEParser(maxEventBytes: 16)
        #expect(throws: SSEParser.Failure.eventTooLarge(limit: 16)) {
            try parser.feed(Array("data: 01234\ndata: 56789\ndata: abcde\n\n".utf8))
        }
    }

    @Test func recordedSampleParsesIdenticallyAtEveryChunking() throws {
        let sample = Array(try Repo.eventsSample)
        var whole = SSEParser()
        let expected = try whole.feed(sample)
        #expect(expected.count == 50)
        #expect(whole.commentCount == 30)  // heartbeats

        var byteAtATime = SSEParser()
        var events: [SSEEvent] = []
        for byte in sample {
            if let event = try byteAtATime.push(byte) { events.append(event) }
        }
        #expect(events == expected)

        var generator = SeededGenerator(seed: 0x5EED)
        for _ in 0..<20 {
            var parser = SSEParser()
            var chunked: [SSEEvent] = []
            var index = 0
            while index < sample.count {
                let length = Int.random(in: 1...257, using: &generator)
                let end = min(sample.count, index + length)
                chunked += try parser.feed(sample[index..<end])
                index = end
            }
            #expect(chunked == expected)
        }
    }

    @Test func recordedSampleWithCRLFLineEndings() throws {
        let sample = try Repo.eventsSample
        let text = String(decoding: sample, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")
        var lf = SSEParser()
        var crlf = SSEParser()
        #expect(try crlf.feed(Array(text.utf8)) == lf.feed(Array(sample)))
    }
}

/// Deterministic SplitMix64 for reproducible chunking.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
