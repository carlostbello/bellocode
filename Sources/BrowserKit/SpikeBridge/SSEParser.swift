// SPIKE (gate G3). Minimal WHATWG event-stream parser (engineering rule 11); OpenCodeKit owns the production one.

import Foundation

public struct SSEEvent: Sendable, Equatable {
    public var type: String
    public var data: String
    public var id: String?
}

/// Parses `text/event-stream` bytes per https://html.spec.whatwg.org/multipage/server-sent-events.html, accepting
/// arbitrary chunk boundaries (including a CRLF split across chunks) and multi-line `data`.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var lastWasCR = false
    private var data: [UInt8] = []
    private var hasData = false
    private var eventType = ""
    public private(set) var lastEventID: String?
    public private(set) var retry: Int?

    public init() {}

    public mutating func feed<Bytes: Sequence>(_ bytes: Bytes) -> [SSEEvent] where Bytes.Element == UInt8 {
        var events: [SSEEvent] = []
        for byte in bytes { if let event = feed(byte) { events.append(event) } }
        return events
    }

    public mutating func feed(_ byte: UInt8) -> SSEEvent? {
        // A UTF-8 BOM at the very start of the stream is dropped.
        if atStreamStart {
            let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
            if byte == bom[pendingBOM.count] {
                pendingBOM.append(byte)
                if pendingBOM.count == bom.count { atStreamStart = false; pendingBOM = [] }
                return nil
            }
            atStreamStart = false
            let replay = pendingBOM
            pendingBOM = []
            var event: SSEEvent?
            for earlier in replay { event = feedContent(earlier) ?? event }
            return feedContent(byte) ?? event
        }
        return feedContent(byte)
    }

    private var atStreamStart = true
    private var pendingBOM: [UInt8] = []

    private mutating func feedContent(_ byte: UInt8) -> SSEEvent? {
        if lastWasCR {
            lastWasCR = false
            if byte == 0x0A { return nil }  // the LF of a CRLF pair
        }
        switch byte {
        case 0x0D:
            lastWasCR = true
            return endLine()
        case 0x0A:
            return endLine()
        default:
            line.append(byte)
            return nil
        }
    }

    private mutating func endLine() -> SSEEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return dispatch() }
        if line.first == 0x3A { return nil }  // comment
        let field: [UInt8]
        var value: [UInt8]
        if let colon = line.firstIndex(of: 0x3A) {
            field = Array(line[..<colon])
            value = Array(line[(colon + 1)...])
            if value.first == 0x20 { value.removeFirst() }
        } else {
            field = line
            value = []
        }
        switch String(decoding: field, as: UTF8.self) {
        case "event": eventType = String(decoding: value, as: UTF8.self)
        case "data":
            data.append(contentsOf: value)
            data.append(0x0A)
            hasData = true
        case "id":
            if !value.contains(0) { lastEventID = String(decoding: value, as: UTF8.self) }
        case "retry":
            if !value.isEmpty, value.allSatisfy({ (0x30...0x39).contains($0) }) { retry = Int(String(decoding: value, as: UTF8.self)) }
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer { data.removeAll(keepingCapacity: true); hasData = false; eventType = "" }
        guard hasData else { return nil }
        if data.last == 0x0A { data.removeLast() }
        return SSEEvent(type: eventType.isEmpty ? "message" : eventType, data: String(decoding: data, as: UTF8.self), id: lastEventID)
    }
}
