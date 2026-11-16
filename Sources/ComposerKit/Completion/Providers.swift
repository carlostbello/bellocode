import Foundation

/// `@` file mentions over one root directory. The index is built once, lazily, off the main actor and is bounded;
/// hidden entries and common build/dependency folders are skipped.
public actor FilePathCompletionProvider: CompletionProvider {
    public nonisolated let trigger: Character = "@"
    public nonisolated let requiresPromptStart = false
    public nonisolated let title = "Files"
    public nonisolated let root: URL
    public nonisolated let maxFiles: Int
    public nonisolated let maxResults: Int
    public static let skippedNames: Set<String> = [
        "node_modules", ".build", "build", "DerivedData", "dist", "target", "Pods", ".git", ".swiftpm", "vendor",
    ]

    private var indexTask: Task<[String], Never>?

    public init(root: URL, maxFiles: Int = 50_000, maxResults: Int = 50) {
        self.root = root.standardizedFileURL
        self.maxFiles = maxFiles
        self.maxResults = maxResults
    }

    public func completions(for query: String) async throws -> [CompletionItem] {
        let paths = await index()
        try Task.checkCancellation()
        let ranked = FuzzyMatcher.rank(query, paths, key: { $0 }, id: { $0 }, limit: maxResults)
        try Task.checkCancellation()
        let rootPath = root.path
        return ranked.map { path in
            let name = (path as NSString).lastPathComponent
            let folder = (path as NSString).deletingLastPathComponent
            return CompletionItem(
                id: path, title: name, subtitle: folder.isEmpty ? nil : folder, symbolName: "doc",
                token: ComposerToken(kind: .file, text: "@" + path, value: rootPath + "/" + path)
            )
        }
    }

    /// Relative paths of indexed files. Shared by every query; cancelling a query does not cancel indexing.
    public func index() async -> [String] {
        if let indexTask { return await indexTask.value }
        let root = self.root
        let limit = maxFiles
        let task = Task { Self.scan(root: root, limit: limit) }
        indexTask = task
        return await task.value
    }

    private static func scan(root: URL, limit: Int) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var paths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skippedNames.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            paths.append(String(path.dropFirst(prefix.count)))
            if paths.count >= limit { break }
        }
        paths.sort()
        return paths
    }
}

/// A slash command offered by `/` at the start of the prompt.
public struct SlashCommand: Hashable, Sendable {
    public var name: String
    public var summary: String
    public var symbolName: String

    public init(name: String, summary: String, symbolName: String = "command") {
        self.name = name
        self.summary = summary
        self.symbolName = symbolName
    }
}

/// `/` commands from a fixed list. opencode's own commands and skills arrive in a later package through the same
/// protocol.
public struct StaticSlashCommandProvider: CompletionProvider {
    public let trigger: Character = "/"
    public let requiresPromptStart = true
    public let title = "Commands"
    public var commands: [SlashCommand]

    public init(commands: [SlashCommand]) {
        self.commands = commands
    }

    public static let builtIn = StaticSlashCommandProvider(commands: [
        SlashCommand(name: "compact", summary: "Summarise the conversation to free context", symbolName: "arrow.down.right.and.arrow.up.left"),
        SlashCommand(name: "clear", summary: "Start a fresh session in this thread", symbolName: "eraser"),
        SlashCommand(name: "goal", summary: "Keep working across turns until a goal is met", symbolName: "target"),
        SlashCommand(name: "model", summary: "Choose the model for this thread", symbolName: "cpu"),
        SlashCommand(name: "review", summary: "Review the current changes", symbolName: "checklist"),
    ])

    public func completions(for query: String) async throws -> [CompletionItem] {
        let ranked = FuzzyMatcher.rank(query, commands, key: \.name, id: \.name, limit: 50)
        return ranked.map { command in
            CompletionItem(
                id: command.name, title: "/" + command.name, subtitle: command.summary, symbolName: command.symbolName,
                token: ComposerToken(kind: .command, text: "/" + command.name, value: command.name)
            )
        }
    }
}
