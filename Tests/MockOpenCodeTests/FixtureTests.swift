import Foundation
import Testing
@testable import MockOpenCode

@Suite("Fixture generator")
struct FixtureTests {
    static func digest(_ scenario: Scenario) -> String {
        var out = ""
        for session in scenario.sessions {
            out += session.json.serialized
            for message in scenario.messages[session.id] ?? [] { out += message.json.serialized }
        }
        for project in scenario.projects { out += project.json.serialized }
        return out
    }

    @Test func sameSeedSameBytes() {
        let a = FixtureGenerator(seed: 7).workspace(projectCount: 3, sessionCount: 25, messagesPerSession: 12)
        let b = FixtureGenerator(seed: 7).workspace(projectCount: 3, sessionCount: 25, messagesPerSession: 12)
        let c = FixtureGenerator(seed: 8).workspace(projectCount: 3, sessionCount: 25, messagesPerSession: 12)
        #expect(Self.digest(a) == Self.digest(b))
        #expect(Self.digest(a) != Self.digest(c))
    }

    @Test func workspaceShape() {
        let scenario = FixtureGenerator(seed: 3).workspace(projectCount: 4, sessionCount: 40, messagesPerSession: 6)
        #expect(scenario.projects.count == 4)
        #expect(scenario.sessions.count == 40)
        #expect(Set(scenario.sessions.map(\.projectID)).count == 4)
        let children = scenario.sessions.filter { $0.parentID != nil }
        #expect(children.count == 8)
        for child in children {
            let parent = scenario.sessions.first { $0.id == child.parentID }
            #expect(parent?.projectID == child.projectID)
        }
        #expect(scenario.sessions.allSatisfy { scenario.messages[$0.id]?.count == 6 })
        #expect(Set(scenario.sessions.map(\.id)).count == 40)
        // Session ids sort newest first, like the real server's.
        let ids = scenario.sessions.map(\.id)
        #expect(ids == ids.sorted(by: >))
    }

    @Test func largeSessionCoversEverySurface() throws {
        var scenario = Scenario.empty()
        let clock = ContinuousClock()
        let start = clock.now
        let id = FixtureGenerator(seed: 42).addLargeSession(to: &scenario, messageCount: 10_000)
        let elapsed = clock.now - start
        let messages = try #require(scenario.messages[id])
        #expect(messages.count == 10_000)
        #expect(Set(messages.map(\.id)).count == 10_000)
        #expect(elapsed < .seconds(30))

        var texts: [String] = []
        var tools: [ToolPart] = []
        var reasoning = 0
        for message in messages {
            guard case let .assistant(assistant) = message.kind else { continue }
            for part in assistant.content {
                switch part {
                case let .text(text): texts.append(text)
                case .reasoning: reasoning += 1
                case let .tool(tool): tools.append(tool)
                }
            }
        }
        let all = texts.joined(separator: "\n")
        #expect(reasoning > 100)
        #expect(texts.contains { $0.utf8.count > 100_000 && $0.contains("```swift") })
        for language in ["swift", "python", "typescript", "rust", "go", "json", "bash", "sql"] {
            #expect(all.contains("```\(language)\n"), "no \(language) block")
        }
        #expect(all.contains("\n| --- |") || all.contains("| --- |"))
        #expect(all.contains("![") && all.contains("https://picsum.photos/"))
        #expect(all.contains("## ") && all.contains("\n- ") && all.contains("1. ") && all.contains("](https://example.com/docs/"))
        #expect(all.contains("`") )
        #expect(tools.contains { $0.name == "edit" && $0.state.json["metadata"]?["diff"]?.stringValue?.contains("@@") == true })
        #expect(tools.contains { $0.name == "shell" && ($0.state.json["content"]?[0]?["text"]?.stringValue?.count ?? 0) > 5000 })
        #expect(tools.contains { $0.state.json["content"]?.arrayValue?.contains { $0["type"] == "file" } == true })
        #expect(tools.contains { $0.state.json["status"] == "error" })
        let cards = tools.filter { $0.name == "subagent" }
        #expect(!cards.isEmpty)
        for card in cards {
            let childID = try #require(card.state.json["metadata"]?["sessionID"]?.stringValue)
            #expect(scenario.sessions.first { $0.id == childID }?.parentID == id)
            #expect(scenario.messages[childID]?.isEmpty == false)
        }
    }

    @Test func largeScenarioThroughTheServer() async throws {
        let scenario = Scenario.large(seed: 5, projectCount: 3, sessionCount: 30, largeSessionMessages: 10_000)
        let server = MockOpenCodeServer(scenario: scenario, options: .testing)
        let client = TestClient(try await server.start())
        let found = try await client.get("/api/session?search=large%20transcript")["data"]?.arrayValue ?? []
        let id = try #require(found.first?["id"]?.stringValue)
        // Newest page first, then walk back with cursors.
        var page = try await client.get("/api/session/\(id)/message?limit=200")
        var total = page["data"]?.arrayValue?.count ?? 0
        while let next = page["cursor"]?["next"]?.stringValue {
            page = try await client.get("/api/session/\(id)/message?limit=1000&cursor=\(next)")
            let count = page["data"]?.arrayValue?.count ?? 0
            if count == 0 { break }
            total += count
        }
        #expect(total == 10_000)
        let projects = try await client.get("/api/project").arrayValue ?? []
        #expect(projects.count == 3)
        await server.stop()
    }
}
