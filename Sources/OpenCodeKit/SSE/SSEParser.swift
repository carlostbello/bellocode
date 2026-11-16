import Foundation

/// One dispatched server-sent event.
public struct SSEEvent: Sendable, Hashable {
    /// The `event` field, or `"message"` when the event named none.
    public var type: String
    /// The `data` lines joined with `"\n"`.
    public var data: String
    /// The last event ID in effect when this event was dispatched (persists across events, per the specification).
    public var lastEventID: String

    public init(type: String = "message", data: String, lastEventID: String = "") {
        self.type = type
        self.data = data
        self.lastEventID = lastEventID
    }
}

/// An incremental `text/event-stream` parser following the WHATWG HTML specification, section 9.2.6
/// ("Interpreting an event stream").
///
/// Bytes may arrive split at any boundary, including inside a UTF-8 sequence or between CR and LF. The parser strips
/// one leading BOM, accepts CR, LF and CRLF line endings, ignores comment lines, joins multi-line `data`, tracks `id`
/// (ignoring values that contain NULL) and `retry` (ASCII digits only), and dispatches on a blank line. Invalid UTF-8
/// is replaced with U+FFFD, as the specification's UTF-8 decode requires. A trailing event without its blank line is
/// discarded at end of stream.
///
/// Every line and every event is bounded by `maxEventBytes`; exceeding it throws `SSEParser.Failure.eventTooLarge`
/// so the caller can drop the connection and resynchronise rather than buffer without limit.
public struct SSEParser: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case eventTooLarge(limit: Int)
    }

    public let maxEventBytes: Int

    /// The most recent valid `retry` value, if any.
    public private(set) var reconnectionTime: Duration?
    /// The last event ID buffer.
    public private(set) var lastEventID = ""
    /// Number of comment lines seen (heartbeats).
    public private(set) var commentCount = 0

    private enum BOMState { case expecting(matched: Int), done }

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    private var bomState = BOMState.expecting(matched: 0)
    private var line: [UInt8] = []
    private var previousWasCR = false
    private var dataBuffer = ""
    private var dataBytes = 0
    private var hasData = false
    private var eventType = ""

    public init(maxEventBytes: Int = 16 * 1024 * 1024) {
        precondition(maxEventBytes > 0)
        self.maxEventBytes = maxEventBytes
    }

    /// Feeds bytes and returns the events they complete, in order.
    public mutating func feed(_ bytes: some Sequence<UInt8>) throws(Failure) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes {
            if let event = try push(byte) { events.append(event) }
        }
        return events
    }

    /// Feeds one byte; returns the event it completes, if any.
    public mutating func push(_ byte: UInt8) throws(Failure) -> SSEEvent? {
        if case .expecting(let matched) = bomState {
            if byte == Self.bom[matched] {
                bomState = matched + 1 == Self.bom.count ? .done : .expecting(matched: matched + 1)
                return nil
            }
            bomState = .done
            // A partial BOM prefix was not a BOM after all: replay those bytes as content.
            var pending: SSEEvent?
            for replayed in Self.bom.prefix(matched) {
                if let event = try consume(replayed) { pending = event }
            }
            if let event = try consume(byte) { return event }
            return pending
        }
        return try consume(byte)
    }

    /// Signals end of stream. Per the specification, a partially received event is discarded.
    public mutating func finish() {
        line.removeAll()
        previousWasCR = false
        resetEvent()
        bomState = .expecting(matched: 0)
    }

    // MARK: - Line splitting

    private mutating func consume(_ byte: UInt8) throws(Failure) -> SSEEvent? {
        switch byte {
        case UInt8(ascii: "\n"):
            if previousWasCR {
                previousWasCR = false
                return nil
            }
            return try endLine()
        case UInt8(ascii: "\r"):
            previousWasCR = true
            return try endLine()
        default:
            previousWasCR = false
            guard line.count < maxEventBytes else { throw .eventTooLarge(limit: maxEventBytes) }
            line.append(byte)
            return nil
        }
    }

    private mutating func endLine() throws(Failure) -> SSEEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return dispatch() }
        if line[0] == UInt8(ascii: ":") {
            commentCount &+= 1
            return nil
        }
        let field: [UInt8].SubSequence
        var value: [UInt8].SubSequence
        if let colon = line.firstIndex(of: UInt8(ascii: ":")) {
            field = line[..<colon]
            value = line[(colon + 1)...]
            if value.first == UInt8(ascii: " ") { value = value.dropFirst() }
        } else {
            field = line[...]
            value = []
        }
        try process(field: field, value: value)
        return nil
    }

    // MARK: - Fields

    private mutating func process(field: ArraySlice<UInt8>, value: ArraySlice<UInt8>) throws(Failure) {
        switch String(decoding: field, as: UTF8.self) {
        case "event":
            eventType = String(decoding: value, as: UTF8.self)
        case "data":
            dataBytes += value.count + 1
            guard dataBytes <= maxEventBytes else { throw .eventTooLarge(limit: maxEventBytes) }
            dataBuffer += String(decoding: value, as: UTF8.self)
            dataBuffer += "\n"
            hasData = true
        case "id":
            if !value.contains(0) { lastEventID = String(decoding: value, as: UTF8.self) }
        case "retry":
            if !value.isEmpty, value.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                let milliseconds = Int64(String(decoding: value, as: UTF8.self))
            {
                reconnectionTime = .milliseconds(milliseconds)
            }
        default:
            break
        }
    }

    private mutating func dispatch() -> SSEEvent? {
        defer { resetEvent() }
        guard hasData else { return nil }
        var data = dataBuffer
        if data.hasSuffix("\n") { data.removeLast() }
        return SSEEvent(type: eventType.isEmpty ? "message" : eventType, data: data, lastEventID: lastEventID)
    }

    private mutating func resetEvent() {
        dataBuffer = ""
        dataBytes = 0
        hasData = false
        eventType = ""
    }
}
