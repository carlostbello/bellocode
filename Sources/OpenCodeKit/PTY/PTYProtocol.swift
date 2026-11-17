import Foundation

/// The persistent-PTY WebSocket wire format (opencode 2.3.0, input protocol 1). Pure; tested without a server.
///
/// Server → client: text frames are JSON control messages; binary frames are raw PTY output. After connecting the
/// server sends `attached`, then **one** binary frame with the whole replay from `max(cursor, head)`, then
/// `replay_complete`, then live output and control messages, and finally `exited` and close 1000.
///
/// Client → server: binary frames `[flag u8][cols u16 BE][rows u16 BE][payload]`; flag 1 = input (payload = bytes
/// for the PTY), flag 0 = resize only (no payload). Every input frame carries the client's grid size, and the server
/// resizes to it, so input must always carry the size last sent as a resize.
public enum PTYWire {
    public static let headerLength = 5

    /// An input frame: bytes typed or pasted, with the client's current grid size.
    public static func inputFrame(_ payload: some Collection<UInt8>, size: PTYSize) -> Data {
        frame(flag: 1, size: size, payload: payload)
    }

    /// A resize-only frame.
    public static func resizeFrame(_ size: PTYSize) -> Data {
        frame(flag: 0, size: size, payload: EmptyCollection())
    }

    static func frame(flag: UInt8, size: PTYSize, payload: some Collection<UInt8>) -> Data {
        let size = size.clamped
        var data = Data(capacity: headerLength + payload.count)
        data.append(flag)
        data.append(UInt8(truncatingIfNeeded: size.cols >> 8))
        data.append(UInt8(truncatingIfNeeded: size.cols))
        data.append(UInt8(truncatingIfNeeded: size.rows >> 8))
        data.append(UInt8(truncatingIfNeeded: size.rows))
        data.append(contentsOf: payload)
        return data
    }

    /// Decodes a client frame (the mock server's side, and tests). nil when shorter than the header.
    public static func decodeClientFrame(_ data: Data) -> (isInput: Bool, size: PTYSize, payload: Data)? {
        guard data.count >= headerLength else { return nil }
        let bytes = [UInt8](data.prefix(headerLength))
        let cols = Int(bytes[1]) << 8 | Int(bytes[2])
        let rows = Int(bytes[3]) << 8 | Int(bytes[4])
        return (bytes[0] == 1, PTYSize(cols: cols, rows: rows), Data(data.dropFirst(headerLength)))
    }
}

/// `replay` of the `attached` message: which output byte range the next binary frame carries.
public struct PTYReplayWindow: Sendable, Hashable {
    /// The cursor the client asked for.
    public var requestedOffset: Int
    /// Where the replay actually starts: `max(requested, head)`.
    public var availableOffset: Int
    /// The end of output at attach time; live output continues from here.
    public var endOffset: Int
    /// Bytes between `requestedOffset` and `availableOffset` were dropped from the server's 2 MiB ring.
    public var truncated: Bool

    public init(requestedOffset: Int, availableOffset: Int, endOffset: Int, truncated: Bool) {
        self.requestedOffset = requestedOffset
        self.availableOffset = availableOffset
        self.endOffset = endOffset
        self.truncated = truncated
    }
}

/// A server control message (a text frame).
public enum PTYControlMessage: Sendable, Hashable {
    case attached(attachmentID: String, role: PTYRole, size: PTYSize?, replay: PTYReplayWindow)
    case replayComplete(endOffset: Int?)
    /// The PTY was resized (by any controller). `checkpoint` redraws the screen at the new size.
    case resized(PTYSize)
    case controllerChanged(attachmentID: String?)
    case exited(exitCode: Int?, finalOffset: Int?)
    case titleChanged(String)
    case foregroundProcessChanged(String?)
    /// A message this client does not know (forward compatible; ignored).
    case unknown(type: String)

    /// Decodes one text frame; nil when it is not a JSON object with a string `type`.
    public static func decode(_ text: String) -> PTYControlMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let type = object["type"] as? String
        else { return nil }
        func int(_ value: Any?) -> Int? { (value as? NSNumber).map(\.intValue) }
        switch type {
        case "attached":
            let info = object["info"] as? [String: Any]
            let size = (info?["size"] as? [String: Any]).flatMap { size -> PTYSize? in
                guard let cols = int(size["cols"]), let rows = int(size["rows"]) else { return nil }
                return PTYSize(cols: cols, rows: rows)
            }
            let replay = object["replay"] as? [String: Any] ?? [:]
            let requested = int(replay["requestedOffset"]) ?? 0
            let available = int(replay["availableOffset"]) ?? requested
            return .attached(
                attachmentID: object["attachmentID"] as? String ?? "",
                role: (object["role"] as? String).flatMap(PTYRole.init(rawValue:)) ?? .controller, size: size,
                replay: PTYReplayWindow(
                    requestedOffset: requested, availableOffset: available,
                    endOffset: int(replay["endOffset"]) ?? available, truncated: replay["truncated"] as? Bool ?? false))
        case "replay_complete":
            return .replayComplete(endOffset: int(object["endOffset"]))
        case "resized":
            return .resized(PTYSize(cols: int(object["cols"]) ?? 0, rows: int(object["rows"]) ?? 0))
        case "controller_changed":
            return .controllerChanged(attachmentID: object["attachmentID"] as? String)
        case "exited":
            return .exited(exitCode: int(object["exitCode"]), finalOffset: int(object["finalOffset"]))
        case "title_changed":
            return .titleChanged(object["title"] as? String ?? "")
        case "foreground_process_changed":
            return .foregroundProcessChanged(object["process"] as? String)
        default:
            return .unknown(type: type)
        }
    }
}

/// Tracks the output byte offset of one attachment so a reconnect resumes exactly where this one stopped
/// ("reconnect from cursor"), and decides when the emulator must be cleared first.
///
/// Rules (docs/spikes/G5-terminal.md): offsets are byte offsets into the PTY's output; the replay starts at
/// `availableOffset`; the reconnect cursor is `endOffset` plus live bytes received since. The emulator's content is
/// kept only when the replay continues exactly from the bytes it already holds; otherwise (first attach of a fresh
/// emulator, truncated ring, or a server whose output does not reach our cursor) it is reset and the replay
/// rebuilds it (AGENTS.md rule 12: a reconnect is not a replay of what we missed unless it provably is).
public struct PTYStreamState: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        case connecting
        case replaying
        case live
    }

    /// What the consumer must do before feeding the replay.
    public enum AttachDecision: Sendable, Hashable {
        /// The replay continues the emulator's content.
        case append
        /// Clear the emulator (and its scrollback) first. `trimmed` = the server no longer has some of the output.
        case reset(trimmed: Bool)
    }

    public private(set) var phase: Phase = .connecting
    /// The offset of the next output byte: the `cursor` for the next connect.
    public private(set) var offset: Int
    /// Whether the emulator holds output up to `offset` (false for a fresh emulator).
    public private(set) var emulatorHasContent: Bool

    public init(cursor: Int = 0, emulatorHasContent: Bool = false) {
        offset = max(0, cursor)
        self.emulatorHasContent = emulatorHasContent && cursor > 0
    }

    /// The cursor to connect with: our offset if the emulator holds that output, else 0 (replay everything).
    public var connectCursor: Int { emulatorHasContent ? offset : 0 }

    /// A new socket is about to connect.
    public mutating func beginConnect() {
        phase = .connecting
        if !emulatorHasContent { offset = 0 }
    }

    /// Handles `attached`. Returns whether to keep or reset the emulator before the replay bytes.
    public mutating func attached(_ replay: PTYReplayWindow) -> AttachDecision {
        phase = .replaying
        let continues = emulatorHasContent && replay.requestedOffset == offset && replay.availableOffset == offset
            && !replay.truncated && replay.endOffset >= offset
        offset = replay.availableOffset
        emulatorHasContent = true
        if continues { return .append }
        return .reset(trimmed: replay.truncated || replay.availableOffset > 0)
    }

    /// Counts output bytes (replay or live).
    public mutating func received(_ count: Int) {
        offset += count
        emulatorHasContent = true
    }

    /// Handles `replay_complete`. The server's `endOffset` is authoritative.
    public mutating func replayComplete(endOffset: Int?) {
        if let endOffset { offset = endOffset }
        phase = .live
    }

    /// The emulator was replaced (a new view): the next connect replays everything.
    public mutating func emulatorDiscarded() {
        emulatorHasContent = false
        offset = 0
        phase = .connecting
    }
}
