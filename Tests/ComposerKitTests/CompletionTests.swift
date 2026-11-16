import Foundation
import Testing
@testable import ComposerKit

@Suite struct TriggerDetectionTests {
    let triggers: [Character: Bool] = ["@": false, "/": true]

    func query(_ text: String, caret: Int? = nil, excluded: [NSRange] = []) -> CompletionQuery? {
        let string = text as NSString
        return CompletionTriggerDetector.query(in: string, caret: caret ?? string.length, triggers: triggers, excluded: excluded)
    }

    @Test func mentions() {
        #expect(query("@") == CompletionQuery(trigger: "@", text: "", range: NSRange(location: 0, length: 1)))
        #expect(query("look at @src/ma")?.text == "src/ma")
        #expect(query("look at @src/ma")?.range == NSRange(location: 8, length: 7))
        #expect(query("mail me@host") == nil)
        #expect(query("@a b") == nil)
        #expect(query("👩‍💻 @x")?.text == "x")
        #expect(query("@abc", caret: 2)?.text == "a")
    }

    @Test func slashOnlyAtPromptStart() {
        #expect(query("/rev")?.text == "rev")
        #expect(query("  /rev")?.text == "rev")
        #expect(query("run /rev") == nil)
        #expect(query("path a/b") == nil)
    }

    @Test func tokensNeverStartAQuery() {
        #expect(query("@done", excluded: [NSRange(location: 0, length: 5)]) == nil)
    }
}

@Suite struct FuzzyMatcherTests {
    @Test func scoresAndRejects() {
        #expect(FuzzyMatcher.score("msw", "Sources/App/main.swift") != nil)
        #expect(FuzzyMatcher.score("xyz", "Sources/App/main.swift") == nil)
        #expect(FuzzyMatcher.score("", "anything") == 0)
    }

    @Test func fileNameAndSegmentHitsRankFirst() {
        let paths = [
            "Tests/AppTests/MainTests.swift", "Sources/App/main.swift", "Sources/Domain/maintenance/Info.swift",
            "Sources/Mobile/AppInfo.swift",
        ]
        let ranked = FuzzyMatcher.rank("main", paths, key: { $0 }, id: { $0 }, limit: 10)
        #expect(ranked.first == "Sources/App/main.swift")
        let scattered = ranked.firstIndex(of: "Sources/Mobile/AppInfo.swift") ?? -1
        let named = ranked.firstIndex(of: "Tests/AppTests/MainTests.swift") ?? -1
        #expect(named >= 0 && scattered > named, "\(ranked)")
    }

    @Test func orderIsTotalAndStable() {
        let paths = ["b/x.swift", "a/x.swift", "c/x.swift"]
        let once = FuzzyMatcher.rank("x", paths, key: { $0 }, id: { $0 }, limit: 10)
        let twice = FuzzyMatcher.rank("x", paths.reversed(), key: { $0 }, id: { $0 }, limit: 10)
        #expect(once == twice)
        #expect(once == ["a/x.swift", "b/x.swift", "c/x.swift"])
        #expect(FuzzyMatcher.rank("x", paths, key: { $0 }, id: { $0 }, limit: 2).count == 2)
    }
}

@Suite struct ProviderTests {
    @Test func filePathsSkipDependenciesAndAreBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "composer-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["Sources/App/main.swift", "README.md", "node_modules/x/main.js", ".git/main", ".hidden/main.txt"] {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let provider = FilePathCompletionProvider(root: root)
        let items = try await provider.completions(for: "main")
        #expect(items.map(\.id) == ["Sources/App/main.swift"])
        #expect(items.first?.token.text == "@Sources/App/main.swift")
        #expect(items.first?.token.value.hasSuffix("/Sources/App/main.swift") == true)
        #expect(await provider.index().count == 2)
        let bounded = FilePathCompletionProvider(root: root, maxFiles: 1)
        #expect(await bounded.index().count == 1)
    }

    @Test func slashCommands() async throws {
        let items = try await StaticSlashCommandProvider.builtIn.completions(for: "co")
        #expect(items.first?.title == "/compact")
        #expect(items.first?.token.kind == .command)
    }
}

/// A provider whose answers are controlled by the test.
private actor ScriptedProvider: CompletionProvider {
    nonisolated let trigger: Character = "@"
    nonisolated let requiresPromptStart = false
    nonisolated let title = "Scripted"
    private(set) var queries: [String] = []
    var delays: [String: Duration] = [:]

    func setDelay(_ delay: Duration, for query: String) { delays[query] = delay }

    func completions(for query: String) async throws -> [CompletionItem] {
        queries.append(query)
        if let delay = delays[query] { try await Task.sleep(for: delay) }
        return ["\(query)-1", "\(query)-2", "shared"].map {
            CompletionItem(id: $0, title: $0, token: ComposerToken(kind: .file, text: "@" + $0, value: $0))
        }
    }
}

@MainActor
@Suite struct CompletionSessionTests {
    private func q(_ text: String) -> CompletionQuery {
        CompletionQuery(trigger: "@", text: text, range: NSRange(location: 0, length: text.utf16.count + 1))
    }

    @Test func debouncesRefinementsAndDropsStaleResults() async {
        let provider = ScriptedProvider()
        let session = CompletionSession(providers: [provider], debounce: .milliseconds(20))
        session.update(q("a"))
        #expect(session.state == .loading(q("a")))
        await session.settle()
        #expect(session.items.map(\.id) == ["a-1", "a-2", "shared"])
        session.moveSelection(by: 2)
        #expect(session.selectedItem?.id == "shared")
        // Quick refinements: only the last one is queried; rows stay visible meanwhile.
        session.update(q("ab"))
        session.update(q("abc"))
        #expect(session.state == .showing(q("abc"), isRefreshing: true))
        #expect(!session.items.isEmpty)
        await session.settle()
        #expect(await provider.queries == ["a", "abc"])
        #expect(session.selectedItem?.id == "shared", "selection kept by identity")
    }

    @Test func slowAnswerForAnOldQueryIsIgnored() async {
        let provider = ScriptedProvider()
        await provider.setDelay(.milliseconds(80), for: "slow")
        let session = CompletionSession(providers: [provider], debounce: .zero)
        session.update(q("slow"))
        session.update(nil)
        #expect(!session.isOpen)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(!session.isOpen && session.items.isEmpty)
    }

    @Test func unknownTriggerCloses() {
        let session = CompletionSession(providers: [ScriptedProvider()])
        session.update(CompletionQuery(trigger: "#", text: "", range: NSRange(location: 0, length: 1)))
        #expect(!session.isOpen)
        #expect(session.triggers == ["@": false])
    }
}
