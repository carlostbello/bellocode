import Foundation

/// `Permission.Request`: a pending approval.
public struct PermissionRequest: Codable, Sendable, Hashable, Identifiable {
    /// `Permission.Source`: the tool call that asked.
    public struct Source: Codable, Sendable, Hashable {
        public var type: String
        public var messageID: String?
        public var id: String?
    }

    public var id: String
    public var sessionID: String
    /// `read`, `edit`, `shell`, … (plugins may add more).
    public var action: String
    public var resources: [String]
    /// Patterns that an `always` reply would save.
    public var save: [String]?
    public var metadata: JSONValue?
    public var source: Source?
    public var message: String?
}

/// `Permission.Reply`.
public struct PermissionDecision: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let once: Self = "once"
    public static let always: Self = "always"
    public static let reject: Self = "reject"
}

struct PermissionReplyBody: Encodable, Sendable {
    let decision: PermissionDecision
    let message: String?
}
