import BelloCore
import Foundation
import OpenCodeKit

/// A `/` entry the server offers: a slash command (`GET /api/command`) or a skill (`GET /api/skill`).
public struct SlashEntry: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable { case command, skill }
    public var kind: Kind
    /// The command name, or the skill ID.
    public var id: String
    /// What is typed after `/`.
    public var name: String
    public var detail: String?

    public init(kind: Kind, id: String, name: String, detail: String? = nil) {
        self.kind = kind
        self.id = id
        self.name = name
        self.detail = detail
    }
}

extension Engine {
    /// Commands and skills for a location, commands first. Either list failing alone still returns the other.
    public func slashEntries(directory: String) async throws -> [SlashEntry] {
        let client = try await clientOrOffline()
        async let commands = client.commands(directory: directory)
        async let skills = client.skills(directory: directory)
        let commandList = try? await commands
        let skillList = try? await skills
        if commandList == nil, skillList == nil { throw EngineError.failed("Commands could not be loaded.") }
        return (commandList ?? []).map { SlashEntry(kind: .command, id: $0.name, name: $0.name, detail: $0.description) }
            + (skillList ?? []).map { SlashEntry(kind: .skill, id: $0.id, name: $0.name, detail: $0.description) }
    }

    /// Files below `directory` matching `query`, ranked by the server (`GET /api/fs/find`), as relative paths.
    public func findFiles(directory: String, query: String, limit: Int = 50) async throws -> [String] {
        let client = try await clientOrOffline()
        do {
            return try await client.findFiles(directory: directory, query: query, type: .file, limit: limit).map(\.path)
        } catch {
            throw EngineError.from(error)
        }
    }

    /// Agents that can be mentioned with `@` (sub-agents, not hidden), from the cached catalog.
    public func mentionableAgents(directory: String) -> [AgentEntry] {
        (root.catalog.catalog(for: directory)?.agents ?? []).filter { !$0.hidden && $0.mode != .primary }
    }

    private func clientOrOffline() async throws -> OpenCodeClient {
        do {
            return try await core.currentClient()
        } catch {
            throw EngineError.from(error)
        }
    }
}
