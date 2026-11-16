import Foundation

/// `/` commands and skills listed by the server. The list is loaded once per provider (one per thread directory) and
/// ranked locally; a failed load is retried on the next query and falls back to `fallback` meanwhile.
public actor ServerSlashCompletionProvider: CompletionProvider {
    /// One entry from the server: a command (`/name args` runs it) or a skill (mentioned as `/name`).
    public struct Entry: Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case command, skill }
        public var kind: Kind
        /// Command name or skill ID (the token's value).
        public var id: String
        public var name: String
        public var detail: String?

        public init(kind: Kind, id: String, name: String, detail: String? = nil) {
            self.kind = kind
            self.id = id
            self.name = name
            self.detail = detail
        }
    }

    public nonisolated let trigger: Character = "/"
    public nonisolated let requiresPromptStart = true
    public nonisolated let title = "Commands"
    private let load: @Sendable () async throws -> [Entry]
    private let fallback: (any CompletionProvider)?
    private var loading: Task<[Entry], any Error>?
    private var entries: [Entry]?

    public init(fallback: (any CompletionProvider)? = nil, load: @escaping @Sendable () async throws -> [Entry]) {
        self.load = load
        self.fallback = fallback
    }

    public func completions(for query: String) async throws -> [CompletionItem] {
        let list: [Entry]
        do {
            list = try await currentEntries()
        } catch {
            try Task.checkCancellation()
            if let fallback { return try await fallback.completions(for: query) }
            throw error
        }
        try Task.checkCancellation()
        let ranked = FuzzyMatcher.rank(query, list, key: \.name, id: \.id, limit: 50)
        return ranked.map { entry in
            switch entry.kind {
            case .command:
                CompletionItem(
                    id: "command:\(entry.id)", title: "/" + entry.name, subtitle: entry.detail, symbolName: "command",
                    token: ComposerToken(kind: .command, text: "/" + entry.name, value: entry.id))
            case .skill:
                CompletionItem(
                    id: "skill:\(entry.id)", title: "/" + entry.name, subtitle: entry.detail ?? "Skill",
                    symbolName: "sparkles", token: ComposerToken(kind: .skill, text: "/" + entry.name, value: entry.id))
            }
        }
    }

    private func currentEntries() async throws -> [Entry] {
        if let entries { return entries }
        let task = loading ?? Task { try await load() }
        loading = task
        do {
            let value = try await task.value
            entries = value
            return value
        } catch {
            loading = nil
            throw error
        }
    }
}

/// `@` mentions: matching agents first (`@explore`), then files from the server's ranked file search for the thread's
/// directory. When the server search fails (offline, older server), the local index (`FilePathCompletionProvider`)
/// answers instead, so `@` always works.
public struct ServerMentionCompletionProvider: CompletionProvider {
    public let trigger: Character = "@"
    public let requiresPromptStart = false
    public let title = "Files and agents"
    /// Absolute directory the server's relative paths are under.
    public let root: String
    public var agents: [(name: String, detail: String?)]
    private let search: @Sendable (String) async throws -> [String]
    private let fallback: FilePathCompletionProvider?
    public var limit = 50

    public init(
        root: String, agents: [(name: String, detail: String?)] = [], fallback: FilePathCompletionProvider? = nil,
        search: @escaping @Sendable (String) async throws -> [String]
    ) {
        self.root = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
        self.agents = agents
        self.search = search
        self.fallback = fallback
    }

    public func completions(for query: String) async throws -> [CompletionItem] {
        let agentItems = FuzzyMatcher.rank(query, agents.map(\.name), key: { $0 }, id: { $0 }, limit: 5).map { name in
            CompletionItem(
                id: "agent:\(name)", title: "@" + name, subtitle: agents.first { $0.name == name }?.detail ?? "Agent",
                symbolName: "person.crop.circle", token: ComposerToken(kind: .agent, text: "@" + name, value: name))
        }
        let files: [CompletionItem]
        do {
            let paths = try await search(query)
            try Task.checkCancellation()
            files = paths.prefix(limit).map { path in
                let name = (path as NSString).lastPathComponent
                let folder = (path as NSString).deletingLastPathComponent
                return CompletionItem(
                    id: path, title: name, subtitle: folder.isEmpty ? nil : folder, symbolName: "doc",
                    token: ComposerToken(kind: .file, text: "@" + path, value: root + "/" + path))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard let fallback else { throw error }
            files = try await fallback.completions(for: query)
        }
        return agentItems + files
    }
}
