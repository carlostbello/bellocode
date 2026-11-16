import Foundation

/// `Project` (`GET /api/project`). The id is the repository's root-commit hash, or `global` for non-git directories.
public struct Project: Codable, Sendable, Hashable, Identifiable {
    public struct Icon: Codable, Sendable, Hashable {
        public var url: String?
        public var override: String?
        public var color: String?
    }

    public struct Commands: Codable, Sendable, Hashable {
        /// Startup script run when creating a new worktree.
        public var start: String?
    }

    public struct Time: Codable, Sendable, Hashable {
        public var created: Double
        public var updated: Double
        public var active: Double?
        public var archived: Double?
    }

    public var id: String
    public var canonical: String
    public var vcs: String?
    public var name: String?
    public var icon: Icon?
    public var commands: Commands?
    public var time: Time
    public var sandboxes: [String]
}
