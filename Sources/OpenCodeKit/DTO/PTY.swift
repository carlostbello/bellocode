import Foundation

// Persistent PTYs (`/api/experimental/session/{id}/terminal`, `/api/experimental/persistent-pty/{id}`), opencode 2.3.0.
// Shapes from Contracts/opencode-2.3.0/openapi.json (`PersistentPty.*`); behaviour observed in docs/spikes/G5-terminal.md.

/// A terminal grid size in cells.
public struct PTYSize: Codable, Sendable, Hashable, CustomStringConvertible {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    /// The contract requires both dimensions to be positive, and the input protocol carries them as UInt16.
    public var clamped: PTYSize { PTYSize(cols: min(max(cols, 1), 65_535), rows: min(max(rows, 1), 65_535)) }

    public var description: String { "\(cols)x\(rows)" }
}

/// `PersistentPty.Info.status`.
public struct PTYStatus: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let running: Self = "running"
    public static let exited: Self = "exited"
}

/// `PersistentPty.Info`. The server removes a PTY as soon as it exits (list `[]`, GET 404), so `exited` is rarely
/// seen here; the `exited` WebSocket frame is the reliable exit signal.
public struct PTYInfo: Decodable, Sendable, Hashable, Identifiable {
    /// Retained output, as byte offsets: `head` is the oldest byte still replayable, `tail` the end.
    public struct Output: Decodable, Sendable, Hashable {
        public var head: Int
        public var tail: Int
    }

    public var id: String
    public var title: String
    public var command: String
    public var args: [String]
    public var cwd: String
    public var status: PTYStatus
    public var pid: Int
    public var exitCode: Int?
    public var sessionID: String
    public var userTitle: String?
    public var foregroundProcess: String?
    public var size: PTYSize
    public var output: Output
}

/// `PersistentPty.CreateInput`. `env` replaces the server's environment for the child (the server's own is isolated),
/// so pass the user's `HOME`, `PATH`, `LANG`, `TERM`.
public struct PTYCreateRequest: Encodable, Sendable, Hashable {
    public var command: String?
    public var args: [String]
    public var cwd: String?
    public var title: String
    public var env: [String: String]
    public var size: PTYSize?

    public init(
        command: String? = nil, args: [String] = [], cwd: String? = nil, title: String, env: [String: String] = [:],
        size: PTYSize? = nil
    ) {
        self.command = command
        self.args = args
        self.cwd = cwd
        self.title = title
        self.env = env
        self.size = size
    }
}

/// `PersistentPty.UpdateInput`. `title: .some(nil)` clears the user title.
public struct PTYUpdateRequest: Encodable, Sendable, Hashable {
    public var size: PTYSize?
    public var title: String??
    public var attachmentID: String?

    public init(size: PTYSize? = nil, title: String?? = nil, attachmentID: String? = nil) {
        self.size = size
        self.title = title
        self.attachmentID = attachmentID
    }

    private enum CodingKeys: String, CodingKey { case size, title, attachmentID }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(attachmentID, forKey: .attachmentID)
        switch title {
        case .none: break
        case .some(.none): try container.encodeNil(forKey: .title)
        case .some(.some(let value)): try container.encode(value, forKey: .title)
        }
    }
}

/// `PersistentPty.Snapshot`: the screen as text plus VT bytes (`checkpoint`) that redraw it on a fresh emulator.
public struct PTYSnapshot: Decodable, Sendable, Hashable {
    public struct Cursor: Decodable, Sendable, Hashable {
        public var x: Int
        public var y: Int
    }

    public var info: PTYInfo
    public var text: String
    /// Base64 on the wire; decoded here.
    public var checkpoint: Data
    public var cursor: Cursor

    private enum CodingKeys: String, CodingKey { case info, text, checkpoint, cursor }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        info = try container.decode(PTYInfo.self, forKey: .info)
        text = try container.decode(String.self, forKey: .text)
        checkpoint = Data(base64Encoded: try container.decode(String.self, forKey: .checkpoint)) ?? Data()
        cursor = try container.decode(Cursor.self, forKey: .cursor)
    }
}

/// `PersistentPty.ReadResult`: what the agent sees of a session's current terminal (`lines` = bottom screen rows).
public struct PTYReadResult: Decodable, Sendable, Hashable {
    public struct Screen: Decodable, Sendable, Hashable {
        public var text: String
        public var cols: Int
        public var rows: Int
    }

    public var ptyID: String
    public var title: String
    public var cwd: String
    public var foregroundProcess: String?
    public var screen: Screen
}

/// The role of a WebSocket attachment. One controller at a time; observers are read-only.
public enum PTYRole: String, Sendable, Hashable {
    case controller
    case observer
}
