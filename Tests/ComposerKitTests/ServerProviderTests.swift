import Foundation
import Testing

@testable import ComposerKit

@Suite struct ServerProviderTests {
    struct Offline: Error {}

    @Test func slashListsCommandsAndSkillsOnceAndRanks() async throws {
        let loads = LoadCounter()
        let provider = ServerSlashCompletionProvider {
            await loads.increment()
            return [
                .init(kind: .command, id: "review", name: "review", detail: "Review changes"),
                .init(kind: .skill, id: "skill_1", name: "swift-testing", detail: nil),
            ]
        }
        let all = try await provider.completions(for: "")
        #expect(all.map(\.title) == ["/review", "/swift-testing"])
        #expect(all[0].token.kind == .command && all[0].token.value == "review")
        #expect(all[1].token.kind == .skill && all[1].token.value == "skill_1")
        let skills = try await provider.completions(for: "swi")
        #expect(skills.map(\.title) == ["/swift-testing"])
        #expect(await loads.count == 1, "the list is loaded once")
    }

    @Test func slashFallsBackWhenTheServerFails() async throws {
        let provider = ServerSlashCompletionProvider(fallback: StaticSlashCommandProvider.builtIn) { throw Offline() }
        let items = try await provider.completions(for: "comp")
        #expect(items.first?.title == "/compact")
    }

    @Test func mentionsOfferAgentsThenServerFiles() async throws {
        let provider = ServerMentionCompletionProvider(root: "/repo/", agents: [("explore", "Explores"), ("general", nil)]) { query in
            #expect(query == "ex")
            return ["src/explain.swift"]
        }
        let items = try await provider.completions(for: "ex")
        #expect(items.map(\.title) == ["@explore", "explain.swift"])
        #expect(items[0].token.kind == .agent)
        #expect(items[1].token == ComposerToken(id: items[1].token.id, kind: .file, text: "@src/explain.swift", value: "/repo/src/explain.swift"))
    }

    @Test func mentionsFallBackToTheLocalIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appending(path: "local.txt"), atomically: true, encoding: .utf8)
        let provider = ServerMentionCompletionProvider(root: root.path, fallback: FilePathCompletionProvider(root: root)) { _ in
            throw Offline()
        }
        let items = try await provider.completions(for: "loc")
        #expect(items.map(\.title) == ["local.txt"])
    }
}

actor LoadCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
