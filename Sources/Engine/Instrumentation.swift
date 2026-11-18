import Foundation
import os

/// Signposts and logs for the Engine. Never log content (message text, prompts, tool input or output) or credentials:
/// only counts, durations, identifiers' kinds and error categories.
enum EngineSignposts {
    static let subsystem = "app.bellocode.Engine"
    /// Event receipt and reduce.
    static let events = OSSignposter(subsystem: subsystem, category: "Events")
    /// Publishing to presentation models.
    static let publish = OSSignposter(subsystem: subsystem, category: "Publish")
    /// Database reads and writes.
    static let database = OSSignposter(subsystem: subsystem, category: "Database")
    /// Resync from the list endpoints.
    static let sync = OSSignposter(subsystem: subsystem, category: "Sync")
    /// GitLab 2: review loads (versions, diff, discussions) and submits.
    static let gitLab = OSSignposter(subsystem: subsystem, category: "GitLab")
    /// Auto mode: one interval per request decision (policy, review, reply).
    static let auto = OSSignposter(subsystem: subsystem, category: "Auto")
    static let log = Logger(subsystem: subsystem, category: "Engine")
}

extension OSSignposter {
    /// Runs `body` inside a signpost interval.
    func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = beginInterval(name)
        defer { endInterval(name, state) }
        return try body()
    }

    func measure<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = beginInterval(name)
        defer { endInterval(name, state) }
        return try await body()
    }
}
