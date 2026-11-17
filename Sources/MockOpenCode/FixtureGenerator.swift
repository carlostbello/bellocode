import Foundation

/// Deterministic, seeded generator for large scenarios: many sessions across projects, and long mixed transcripts.
///
/// Same seed, same output, byte for byte: ids, timestamps and text all come from ``SeededRandom`` and a clock that
/// advances from ``Scenario/startTime``. Nothing depends on the wall clock, the locale or hash ordering.
///
/// ```swift
/// let scenario = Scenario.large(seed: 42)               // 200 sessions in 8 projects + one 10,000-message session
/// let server = MockOpenCodeServer(scenario: scenario)
/// ```
public struct FixtureGenerator: Sendable {
    public let seed: UInt64

    public init(seed: UInt64) { self.seed = seed }

    /// The title of the session added by ``addLargeSession(to:messageCount:)``.
    public static let largeSessionTitle = "Large transcript fixture"

    // MARK: Workspace

    /// `projectCount` projects under `/tmp/mock-workspace`, `sessionCount` sessions spread across them (every fifth one
    /// a child of the session before it), each with `messagesPerSession` mixed messages.
    public func workspace(projectCount: Int, sessionCount: Int, messagesPerSession: Int) -> Scenario {
        var scenario = Scenario(defaultDirectory: "/tmp/mock-workspace/project-1", seed: seed)
        scenario.scripts = TurnScript.builtIns
        var context = Context(seed: seed, time: scenario.startTime)
        let projectCount = max(1, projectCount)
        for index in 1...projectCount {
            let directory = "/tmp/mock-workspace/project-\(index)"
            var project = MockProject(
                id: context.ids.hash40(), directory: directory, name: Self.projectNames[(index - 1) % Self.projectNames.count],
                time: context.tick(1000))
            project.active = project.created
            scenario.projects.append(project)
        }
        var previous: MockSession?
        for index in 0..<max(0, sessionCount) {
            let parent = index % 5 == 4 ? previous : nil
            let project = parent.flatMap { p in scenario.projects.first { $0.id == p.projectID } }
                ?? scenario.projects[index % projectCount]
            let created = context.tick(60_000)
            var session = MockSession(
                id: context.ids.make("ses", time: created, descending: true), parentID: parent?.id,
                projectID: project.id, directory: project.directory, slug: context.random.pick(Self.slugs),
                title: parent == nil ? context.title() : "\(context.title()) (@explore subagent)",
                agent: parent == nil ? "build" : "explore", model: .bigPickle, time: created)
            let messages = context.transcript(count: messagesPerSession, agent: session.agent ?? "build")
            session.updated = context.time
            session.idle = context.time
            session.outcome = "succeeded"
            session.tokens = messages.reduce(TokenUsage.zero) { total, message in
                if case let .assistant(a) = message.kind { total + (a.tokens ?? .zero) } else { total }
            }
            scenario.sessions.append(session)
            scenario.messages[session.id] = messages
            if parent == nil { previous = session }
        }
        return scenario
    }

    // MARK: Large session

    /// Adds one session with `messageCount` messages exercising every transcript surface: Markdown prose with
    /// headings, lists, GFM tables, links and inline code; fenced code in several languages, including one block of
    /// 100 KB; tool calls with long outputs; reasoning; diffs; images by URL; and sub-agent cards backed by real child
    /// sessions. Returns the new session's id.
    @discardableResult
    public func addLargeSession(to scenario: inout Scenario, messageCount: Int) -> String {
        var context = Context(seed: seed ^ 0x1A_46E5, time: scenario.startTime + 365 * 86_400_000)
        let directory = scenario.projects.first?.directory ?? scenario.defaultDirectory
        let projectID = scenario.projects.first?.id ?? context.ids.hash40()
        let created = context.tick(1000)
        var session = MockSession(
            id: context.ids.make("ses", time: created, descending: true), projectID: projectID, directory: directory,
            slug: "large-fixture", title: Self.largeSessionTitle, agent: "build", model: .bigPickle, time: created)
        context.hugeBlockAt = messageCount / 2
        context.childSessions = []
        context.parent = session
        let messages = context.transcript(count: messageCount, agent: "build")
        session.updated = context.time
        session.idle = context.time
        session.outcome = "succeeded"
        scenario.sessions.append(session)
        scenario.messages[session.id] = messages
        for (child, childMessages) in context.childSessions {
            scenario.sessions.append(child)
            scenario.messages[child.id] = childMessages
        }
        return session.id
    }

    // MARK: Content

    static let projectNames = ["atlas", "beacon", "cinder", "delta", "ember", "fjord", "garnet", "harbor", "iris", "juniper"]
    static let slugs = ["silent-otter", "clever-canyon", "playful-knight", "brave-comet", "quiet-harbor", "amber-falcon"]
    static let words = """
        the a an session model stream token view layout cache render buffer anchor scroll transcript message parser \
        server client window panel sidebar composer terminal browser diff commit branch worktree project agent tool \
        request reply event queue delta frame width height offset index state actor task value result error retry \
        quickly carefully then while because after before during into over under across between fast stable native
        """.split(whereSeparator: \.isWhitespace).map(String.init)
    /// Realistic thread titles and prose (snapshot reviews judge the design, not the data). Chosen from the same random
    /// draws as the old word salad, so every count, ID and timestamp of a seeded scenario is unchanged.
    static let titles = [
        "Fix flaky parser recovery test", "Migrate sessions to passkeys", "Pick a CI cache strategy", "Release checklist 2.4",
        "Audit tokenizer edge cases", "Write fence regression tests", "Bump swift-markdown to 0.9", "Tidy CI cache keys",
        "Speed up cold launch", "Add retry to the upload client", "Fix sidebar scroll jump", "Document the plugin API",
        "Split the settings view model", "Profile transcript layout", "Handle offline reconnects", "Rename the build target",
        "Cache syntax highlighting", "Review the auth middleware", "Port the CLI to Swift concurrency", "Trim the Docker image",
        "Fix dark mode contrast", "Add keyboard shortcuts for tabs", "Investigate memory growth", "Clean up feature flags",
        "Stream large diffs lazily", "Make the queue cancellable", "Upgrade the SQLite schema", "Localise error messages",
        "Draft the 2.5 release notes", "Reproduce the crash on launch", "Shorten test run time", "Validate webhook payloads",
    ]
    static let sentences = [
        "The failure comes from two suites sharing one line buffer, so a second feed can land past the stable end.",
        "I read the parser and its tests first to see where the state is kept between calls.",
        "Making the buffer per instance fixes the race without measurable cost on the benchmark.",
        "The cache key includes the lockfile hash, so a dependency bump invalidates it as expected.",
        "Nothing else references the old helper, so it is safe to delete it in the same change.",
        "The test passes fifty runs in a row with the fix and fails eleven times without it.",
        "I kept the public API unchanged and moved the logic into a private extension.",
        "Next I will add a regression test for nested fences and run the full suite.",
        "The reconnect path rebuilds state from the list endpoints instead of replaying events.",
        "Launch spends most of its time decoding the cache before the first frame is drawn.",
        "Deferring that work until after the window appears cuts cold launch by about a third.",
        "The middleware checks the session before the CSRF token, which is the order we want.",
        "Two call sites still pass a raw string; I converted them to the typed identifier.",
        "The schema migration is versioned and the test covers both upgrade and a fresh install.",
        "Large diffs now build their rows off the main thread and stream into the view.",
        "I could not reproduce the crash with a clean profile, so it likely depends on old data.",
        "The image drops from 1.2 GB to 410 MB after removing the build toolchain from the final stage.",
        "Contrast on secondary labels was below 4.5 to 1 in dark mode; the new token fixes it.",
        "Cancelling a queued item now removes it at once and tells the server in the background.",
        "The flag has been on for everyone for two releases, so the old path can go.",
    ]
    static let languages = ["swift", "python", "typescript", "rust", "go", "json", "bash", "sql", "ruby", "c"]

    /// Generation state: random source, ids and a clock that only moves forward.
    struct Context {
        var random: SeededRandom
        var ids: IdentifierGenerator
        var time: Int64
        var counter = 0
        var hugeBlockAt: Int?
        var parent: MockSession?
        var childSessions: [(MockSession, [MockMessage])] = []

        init(seed: UInt64, time: Int64) {
            random = SeededRandom(seed: seed)
            ids = IdentifierGenerator(seed: seed &+ 1)
            self.time = time
        }

        mutating func tick(_ maxStep: Int) -> Int64 {
            time += Int64(random.int(in: 1...max(1, maxStep)))
            return time
        }

        mutating func words(_ range: ClosedRange<Int>) -> String {
            (0..<random.int(in: range)).map { _ in random.pick(FixtureGenerator.words) }.joined(separator: " ")
        }

        /// The same draws as `words(range)`, folded into an index (keeps the random sequence of the old generator).
        mutating func draw(_ range: ClosedRange<Int>) -> Int {
            var index = 0
            for _ in 0..<random.int(in: range) { index = index &* 31 &+ random.int(in: 0...(FixtureGenerator.words.count - 1)) }
            return abs(index)
        }

        mutating func sentence() -> String {
            FixtureGenerator.sentences[draw(6...16) % FixtureGenerator.sentences.count]
        }

        mutating func title() -> String {
            FixtureGenerator.titles[draw(2...5) % FixtureGenerator.titles.count]
        }

        mutating func paragraph() -> String {
            var parts: [String] = []
            for _ in 0..<random.int(in: 2...5) {
                var sentence = sentence()
                if random.chance(0.3) { sentence += " See `\(random.pick(FixtureGenerator.words))Cache.swift`." }
                if random.chance(0.2) {
                    sentence += " [Docs](https://example.com/docs/\(random.pick(FixtureGenerator.words))#\(counter))."
                }
                parts.append(sentence)
            }
            return parts.joined(separator: " ")
        }

        mutating func code(language: String, lines: Int) -> String {
            let body = (0..<lines).map { line -> String in
                switch language {
                case "swift": "    let \(random.pick(FixtureGenerator.words))\(line) = compute(\(line), \"\(words(1...3))\")"
                case "python": "    \(random.pick(FixtureGenerator.words))_\(line) = compute(\(line), \"\(words(1...3))\")"
                case "typescript": "  const \(random.pick(FixtureGenerator.words))\(line): number = compute(\(line));"
                case "rust": "    let \(random.pick(FixtureGenerator.words))_\(line) = compute(\(line))?;"
                case "go": "\t\(random.pick(FixtureGenerator.words))\(line) := compute(\(line))"
                case "json": "  \"\(random.pick(FixtureGenerator.words))\(line)\": \(random.int(in: 0...9999)),"
                case "bash": "echo \"\(words(1...4))\" | grep -c \(random.pick(FixtureGenerator.words))"
                case "sql": "SELECT id, \(random.pick(FixtureGenerator.words)) FROM t\(line) WHERE n > \(line);"
                default: "  \(random.pick(FixtureGenerator.words))(\(line)); /* \(words(1...4)) */"
                }
            }
            return "```\(language)\n" + body.joined(separator: "\n") + "\n```"
        }

        /// A fenced block of about 100 KB.
        mutating func hugeCode() -> String {
            var lines: [String] = []
            var size = 0
            var line = 0
            while size < 100_000 {
                let text = "    static let entry\(line) = Entry(id: \(line), name: \"\(words(2...4))\", weight: \(random.int(in: 0...9999)))"
                size += text.utf8.count + 1
                lines.append(text)
                line += 1
            }
            return "```swift\nenum Table {\n" + lines.joined(separator: "\n") + "\n}\n```"
        }

        mutating func table() -> String {
            let columns = random.int(in: 2...5)
            let header = (0..<columns).map { _ in title() }
            var rows = ["| " + header.joined(separator: " | ") + " |", "|" + String(repeating: " --- |", count: columns)]
            for _ in 0..<random.int(in: 2...8) {
                rows.append("| " + (0..<columns).map { _ in words(1...3) }.joined(separator: " | ") + " |")
            }
            return rows.joined(separator: "\n")
        }

        mutating func list(ordered: Bool) -> String {
            (1...random.int(in: 2...6)).map { index in
                let marker = ordered ? "\(index)." : "-"
                var item = "\(marker) \(sentence())"
                if random.chance(0.25) { item += "\n   - \(sentence())" }
                return item
            }.joined(separator: "\n")
        }

        mutating func diff(path: String) -> String {
            var lines = ["--- a/\(path)", "+++ b/\(path)"]
            var start = random.int(in: 1...400)
            for _ in 0..<random.int(in: 1...3) {
                let removed = random.int(in: 0...4)
                let added = random.int(in: 1...6)
                lines.append("@@ -\(start),\(removed + 2) +\(start),\(added + 2) @@")
                lines.append("     \(words(2...6))")
                for _ in 0..<removed { lines.append("-    \(words(2...8))") }
                for _ in 0..<added { lines.append("+    \(words(2...8))") }
                lines.append("     \(words(2...6))")
                start += random.int(in: 20...80)
            }
            return lines.joined(separator: "\n") + "\n"
        }

        /// Assistant Markdown mixing every block kind.
        mutating func markdown(huge: Bool) -> String {
            var blocks: [String] = []
            if random.chance(0.4) { blocks.append("## \(title())") }
            blocks.append(paragraph())
            for _ in 0..<random.int(in: 0...4) {
                switch random.int(in: 0...7) {
                case 0: blocks.append("### \(title())")
                case 1: blocks.append(list(ordered: false))
                case 2: blocks.append(list(ordered: true))
                case 3: blocks.append(table())
                case 4: blocks.append(code(language: random.pick(FixtureGenerator.languages), lines: random.int(in: 3...30)))
                case 5: blocks.append("![\(words(1...3))](https://picsum.photos/seed/\(counter)/640/360)")
                case 6: blocks.append("> \(sentence())")
                default: blocks.append(paragraph())
                }
            }
            if huge { blocks.append("Here is the full generated table:\n\n" + hugeCode()) }
            return blocks.joined(separator: "\n\n")
        }

        mutating func toolPart(at created: Int64) -> AssistantPart {
            let id = ids.uuid()
            let kind = random.int(in: 0...5)
            func done(_ name: String, _ input: JSONValue, _ output: String, _ metadata: JSONValue?, files: [ToolContent] = []) -> AssistantPart {
                .tool(
                    ToolPart(
                        id: id, name: name,
                        state: .completed(input: input, content: [.text(output)] + files, metadata: metadata),
                        created: created, ran: created + 5, completed: created + 5 + Int64(random.int(in: 10...4000))))
            }
            switch kind {
            case 0:
                let lines = random.int(in: 20...600)
                let output = (0..<lines).map { "[\($0)] \(words(3...12))" }.joined(separator: "\n")
                return done("shell", ["command": .string("swift test --filter \(title().replacingOccurrences(of: " ", with: ""))")],
                    output, ["exit": 0, "truncated": .bool(lines > 500)])
            case 1:
                let path = "Sources/\(title().replacingOccurrences(of: " ", with: ""))/\(random.pick(FixtureGenerator.words)).swift"
                return done("read", ["path": .string(path)], code(language: "swift", lines: random.int(in: 10...120)), nil)
            case 2:
                let path = "Sources/App/\(random.pick(FixtureGenerator.words)).swift"
                return done("edit", ["path": .string(path)], "Edited \(path)", ["diff": .string(diff(path: path))])
            case 3:
                return done(
                    "glob", ["pattern": "**/*.swift"],
                    (0..<random.int(in: 3...80)).map { "Sources/\(random.pick(FixtureGenerator.words))/\($0).swift" }.joined(separator: "\n"),
                    nil)
            case 4:
                let url = "https://picsum.photos/seed/tool\(counter)/800/450"
                return done(
                    "webfetch", ["url": .string(url)], "Fetched image (800×450).", nil,
                    files: [.file(uri: url, mime: "image/jpeg", name: "screenshot.jpg")])
            default:
                let failed = ToolPart(
                    id: id, name: "shell",
                    state: .error(
                        input: ["command": "make lint"], error: StructuredError(type: "tool", message: "exit status 2"),
                        metadata: ["exit": 2]),
                    created: created, ran: created + 3, completed: created + 900)
                return .tool(failed)
            }
        }

        /// A sub-agent card: a `subagent` tool part pointing at a real child session.
        mutating func subagentPart(at created: Int64) -> AssistantPart {
            let id = ids.uuid()
            let description = title()
            guard let parent else {
                return .tool(
                    ToolPart(
                        id: id, name: "subagent",
                        state: .completed(input: ["agent": "explore", "description": .string(description)], content: [.text("{}")], metadata: nil),
                        created: created))
            }
            let childCreated = created + 10
            var child = MockSession(
                id: ids.make("ses", time: childCreated, descending: true), parentID: parent.id, projectID: parent.projectID,
                directory: parent.directory, slug: "child-\(childSessions.count)", title: "\(description) (@explore subagent)",
                agent: "explore", model: .bigPickle, time: childCreated)
            let savedTime = time
            time = childCreated
            let saved = parent
            self.parent = nil
            let messages = transcript(count: 4, agent: "explore")
            self.parent = saved
            child.updated = time
            child.idle = time
            child.outcome = "succeeded"
            time = savedTime
            childSessions.append((child, messages))
            let input: JSONValue = ["agent": "explore", "description": .string(description), "prompt": .string(sentence())]
            let metadata: JSONValue = ["sessionID": .string(child.id), "status": "completed"]
            return .tool(
                ToolPart(
                    id: id, name: "subagent",
                    state: .completed(input: input, content: [.text(metadata.serialized)], metadata: metadata),
                    created: created, ran: created + 5, completed: created + 5000))
        }

        /// `count` messages alternating one user prompt with one to three assistant steps.
        mutating func transcript(count: Int, agent: String) -> [MockMessage] {
            var messages: [MockMessage] = []
            messages.reserveCapacity(count)
            while messages.count < count {
                counter += 1
                let userTime = tick(120_000)
                var prompt = sentence()
                if random.chance(0.3) { prompt += "\n\n" + list(ordered: false) }
                messages.append(.user(id: ids.make("msg", time: userTime), text: prompt, time: userTime))
                let steps = random.int(in: 1...3)
                for step in 0..<steps where messages.count < count {
                    counter += 1
                    let created = tick(3000)
                    var content: [AssistantPart] = []
                    if random.chance(0.35) {
                        content.append(.reasoning(text: paragraph(), created: created, completed: created + 400))
                    }
                    let last = step == steps - 1
                    let huge = hugeBlockAt.map { messages.count >= $0 } ?? false
                    if huge { hugeBlockAt = nil }
                    if last || random.chance(0.5) { content.append(.text(markdown(huge: huge))) }
                    if !last {
                        content.append(parent != nil && random.chance(0.08) ? subagentPart(at: created) : toolPart(at: created))
                    }
                    var message = AssistantMessage(
                        id: ids.make("msg", time: created), agent: agent, model: .bigPickle, created: created, content: content)
                    message.firstToken = created + 300
                    message.streamed = created + 900
                    message.completed = tick(5000)
                    message.finish = last ? "stop" : "tool-calls"
                    message.cost = 0
                    message.tokens = TokenUsage(
                        input: random.int(in: 500...20_000), output: random.int(in: 20...2000),
                        reasoning: random.int(in: 0...500), cacheRead: 4096)
                    messages.append(.assistant(message))
                }
            }
            return messages
        }
    }
}
