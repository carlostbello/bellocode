import Foundation

/// Marker for the kind of thing an `Identifier` names.
public protocol IdentifierKind: Sendable {}

/// A server-assigned (or client-chosen, for optimistic sends) identifier, typed by what it names so a session ID can
/// never be passed where a message ID is expected.
///
/// Row identity in every list is one of these, never an array index or a fresh UUID (AGENTS.md rule 1).
public struct Identifier<Kind: IdentifierKind>: RawRepresentable, Hashable, Comparable, Sendable, Codable,
    CustomStringConvertible, ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { rawValue }
}

public enum ProjectIDKind: IdentifierKind {}
public enum SessionIDKind: IdentifierKind {}
public enum MessageIDKind: IdentifierKind {}
public enum PartIDKind: IdentifierKind {}
public enum PermissionRequestIDKind: IdentifierKind {}
public enum QuestionIDKind: IdentifierKind {}

/// opencode project ID: the repository's root-commit hash, or a hash for a non-git directory.
public typealias ProjectID = Identifier<ProjectIDKind>
/// `ses_…`.
public typealias SessionID = Identifier<SessionIDKind>
/// `msg_…`. Also the ID of a prompt's inbox item: an admitted prompt becomes the user message with the same ID.
public typealias MessageID = Identifier<MessageIDKind>
/// A part's stable identity inside its message (see `Part.makeID`).
public typealias PartID = Identifier<PartIDKind>
/// `per_…`.
public typealias PermissionRequestID = Identifier<PermissionRequestIDKind>
/// `frm_…` (opencode calls questions "forms").
public typealias QuestionID = Identifier<QuestionIDKind>

/// A point in time as epoch milliseconds, exactly as the server sends it, so values survive a database round trip
/// without floating-point drift (equal before and after means "no change").
public struct Timestamp: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var milliseconds: Double

    public init(milliseconds: Double) { self.milliseconds = milliseconds }

    public init(_ date: Date) { milliseconds = (date.timeIntervalSince1970 * 1000).rounded() }

    public static var now: Timestamp { Timestamp(Date()) }

    public var date: Date { Date(timeIntervalSince1970: milliseconds / 1000) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.milliseconds < rhs.milliseconds }

    public init(from decoder: any Decoder) throws {
        milliseconds = try decoder.singleValueContainer().decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(milliseconds)
    }

    public var description: String { "\(Int64(milliseconds))ms" }
}

/// Opaque JSON kept as text (tool input, tool metadata, session metadata, unknown parts). BelloCore has no JSON model
/// of its own; callers that need structure decode it themselves.
public struct RawJSON: Hashable, Sendable, Codable, CustomStringConvertible {
    public var text: String

    public init(_ text: String) { self.text = text }

    public init(from decoder: any Decoder) throws {
        text = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    public var description: String { text }
}
