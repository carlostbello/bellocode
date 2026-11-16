// G3 spike: pure-logic checks (SSE framing, contract encoding, key chords). The WebKit operations are exercised by
// `BrowserSpike --selftest`, which needs a window and a run loop.

import AppKit
import Foundation
import Testing
@testable import BrowserKit

@Test func sseParserHandlesArbitraryChunkBoundaries() {
    let stream = "\u{FEFF}data: {\"a\":1}\r\n\r\n: heartbeat\n\nevent: x\ndata: line1\ndata: line2\r\rdata: tail"
    let bytes = Array(stream.utf8)
    for split in 1..<bytes.count {
        var parser = SSEParser()
        let events = parser.feed(bytes[..<split]) + parser.feed(bytes[split...])
        #expect(events == [SSEEvent(type: "message", data: "{\"a\":1}"), SSEEvent(type: "x", data: "line1\nline2")])
    }
}

@Test func controlEventsDecode() {
    #expect(BrowserControl(json: ["type": "attached", "connectionID": "c", "version": 4]) == .attached(connectionID: "c", version: 4))
    #expect(BrowserControl(json: ["type": "command", "connectionID": "c", "requestID": "r"]) == .command(connectionID: "c", requestID: "r"))
    #expect(BrowserControl(json: ["type": "cancel", "connectionID": "c", "requestID": "r"]) == .cancel(connectionID: "c", requestID: "r"))
    #expect(BrowserControl(json: ["type": "future", "connectionID": "c"]) == .unrecognized(connectionID: "c", type: "future"))
    #expect(BrowserControl(json: ["type": "command", "connectionID": "c"]) == nil)
}

@Test func outcomesEncodeToTheContractShape() throws {
    let file = BrowserFile(id: "file_00000000-0000-0000-0000-000000000000", name: "s.png", mime: "image/png", data: Data([1, 2]))
    let success = BrowserOutcome.success(BrowserResult(value: ["generation": 3], files: [file])).json
    #expect(success == ["type": "success", "result": ["value": ["generation": 3], "files": [["id": "file_00000000-0000-0000-0000-000000000000", "name": "s.png", "mime": "image/png", "data": "AQI="]]]])
    // Integers stay integers on the wire: the plugin validates Schema.Int fields.
    #expect(String(decoding: try JSONValue.number(3).encoded(), as: UTF8.self) == "3")
    let failure = BrowserOutcome.failure(BrowserFailure("unsupported", "no")).json
    #expect(failure == ["type": "failure", "code": "unsupported", "message": "no"])
    let command = try BrowserCommand(json: ["action": ["type": "click", "tabID": "tab_x", "ref": "e1"], "generation": 2, "files": []])
    #expect(command.type == "click" && command.tabID == "tab_x" && command.generation == 2)
}

@Test func tabIDsMatchTheContractPattern() {
    #expect(BrowserContract.newTabID().wholeMatch(of: /tab_[a-f0-9-]{36}/) != nil)
    #expect(BrowserContract.newFileID().wholeMatch(of: /file_[a-f0-9-]{36}/) != nil)
}

@MainActor
@Test func keyChordsParseLikeTheReferenceDesktop() throws {
    let enter = try NativeInput.parse("Enter")
    #expect(enter.keyCode == 36 && enter.characters == "\r")
    let selectAll = try NativeInput.parse("Meta+A")
    #expect(selectAll.flags == .command && selectAll.charactersIgnoringModifiers == "a")
    #expect(NativeInput.editingAction(selectAll) == #selector(NSText.selectAll(_:)))
    #expect(try NativeInput.parse("B").flags == .shift)
    #expect(try NativeInput.parse("Control+Shift+ArrowLeft").flags == [.control, .shift])
    #expect(try NativeInput.parse("F5").keyCode == 96)
    #expect(try NativeInput.parse("Control++").characters == "+")
    #expect(throws: BrowserFailure.self) { try NativeInput.parse("Hyper+X") }
    #expect(throws: BrowserFailure.self) { try NativeInput.parse("Banana") }
}
