// SPIKE G1-B: deterministic standard workload (seed 42), generated in-process.
//
// 10,000 messages alternating user/assistant (~10 MB), plus one older page of 100 messages used by the prepend test,
// plus a deterministic streaming tail script.

import CoreGraphics
import Foundation

public struct SpikeRNG: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    /// SplitMix64.
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    public mutating func chance(_ p: Double) -> Bool { unit() < p }

    public mutating func pick<T>(_ array: [T]) -> T { array[Int(next() % UInt64(array.count))] }
}

public struct SpikeWorkload: Sendable {
    /// The 10,000 messages shown at open.
    public var items: [SpikeItem]
    /// One older page of 100 messages, prepended by the anchor test.
    public var olderPage: [SpikeItem]
    public var stats: Stats

    public struct Stats: Sendable, Codable {
        public var messages = 0
        public var totalUTF8Bytes = 0
        public var tables = 0
        public var codeBlocks = 0
        public var hugeCodeBlockBytes = 0
        public var toolCalls = 0
        public var reasoningBlocks = 0
        public var diffs = 0
        public var images = 0
        public var proseBytes = 0
        public var codeBytes = 0
        public var toolOutputBytes = 0
        public var diffBytes = 0
        public var reasoningBytes = 0
    }

    public static let seed: UInt64 = 42
    public static let messageCount = 10_000

    // MARK: Generation

    private enum Feature { case table, code, tool, reasoning, diff, image, huge }

    public static func generate() -> SpikeWorkload {
        var rng = SpikeRNG(seed: seed)
        let assistantCount = messageCount / 2
        var plan = [[Feature]](repeating: [], count: assistantCount)
        func scatter(_ feature: Feature, _ count: Int) {
            for _ in 0..<count { plan[rng.int(0...(assistantCount - 1))].append(feature) }
        }
        scatter(.table, 400)
        scatter(.code, 1_500)
        scatter(.tool, 2_000)
        var reasoningSlots = Set<Int>()
        while reasoningSlots.count < 300 { reasoningSlots.insert(rng.int(0...(assistantCount - 1))) }
        for slot in reasoningSlots.sorted() { plan[slot].append(.reasoning) }
        scatter(.diff, 200)
        scatter(.image, 100)
        plan[assistantCount * 3 / 5].append(.huge)

        var stats = Stats()
        var items: [SpikeItem] = []
        items.reserveCapacity(messageCount)
        var nextImageID = 1
        // Stable IDs: the older page uses 1_000..<1_100, the main transcript 2_000..<12_000.
        for index in 0..<messageCount {
            let id = 2_000 + index
            if index % 2 == 0 {
                items.append(SpikeItem(id: id, role: .user, parts: [.markdown(userText(&rng))], revision: 1))
            } else {
                let features = plan[index / 2]
                var parts: [SpikePart] = []
                if features.contains(where: { if case .reasoning = $0 { true } else { false } }) {
                    parts.append(.reasoning(paragraphs(&rng, count: rng.int(2...5))))
                    stats.reasoningBlocks += 1
                }
                var markdown = assistantIntro(&rng)
                func flushMarkdown() {
                    if !markdown.isEmpty { parts.append(.markdown(markdown)); markdown = "" }
                }
                for feature in features {
                    switch feature {
                    case .reasoning:
                        continue
                    case .table:
                        markdown += "\n\n" + table(&rng) + "\n\n" + sentence(&rng)
                        stats.tables += 1
                    case .code:
                        markdown += "\n\n" + codeFence(&rng, lines: rng.int(5...80)) + "\n\n" + sentence(&rng)
                        stats.codeBlocks += 1
                    case .huge:
                        let fence = hugeFence(&rng)
                        stats.hugeCodeBlockBytes = fence.utf8.count
                        markdown += "\n\nHere is the whole generated file:\n\n" + fence + "\n\nThat is the complete file."
                    case .tool:
                        flushMarkdown()
                        parts.append(.tool(tool(&rng)))
                        stats.toolCalls += 1
                    case .diff:
                        flushMarkdown()
                        parts.append(.diff(diff(&rng)))
                        stats.diffs += 1
                    case .image:
                        flushMarkdown()
                        parts.append(.image(image(&rng, id: nextImageID)))
                        nextImageID += 1
                        stats.images += 1
                    }
                }
                if rng.chance(0.5) { markdown += "\n\n" + paragraphs(&rng, count: 1) }
                flushMarkdown()
                items.append(SpikeItem(id: id, role: .assistant, parts: parts, revision: 1))
            }
        }
        stats.messages = items.count
        stats.totalUTF8Bytes = items.reduce(0) { $0 + $1.utf8Count }
        for item in items {
            for part in item.parts {
                switch part {
                case .markdown(let text):
                    var inFence = false
                    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                        if line.hasPrefix("```") { inFence.toggle(); continue }
                        if inFence { stats.codeBytes += line.utf8.count + 1 } else { stats.proseBytes += line.utf8.count + 1 }
                    }
                case .tool(let tool): stats.toolOutputBytes += tool.output.utf8.count
                case .diff(let text): stats.diffBytes += text.utf8.count
                case .reasoning(let text): stats.reasoningBytes += text.utf8.count
                case .image: break
                }
            }
        }

        var older: [SpikeItem] = []
        for index in 0..<100 {
            let id = 1_000 + index
            if index % 2 == 0 {
                older.append(SpikeItem(id: id, role: .user, parts: [.markdown(userText(&rng))], revision: 1))
            } else {
                var text = assistantIntro(&rng)
                if rng.chance(0.3) { text += "\n\n" + codeFence(&rng, lines: rng.int(5...30)) }
                older.append(SpikeItem(id: id, role: .assistant, parts: [.markdown(text)], revision: 1))
            }
        }
        return SpikeWorkload(items: items, olderPage: older, stats: stats)
    }

    // MARK: Streaming tail script

    /// Deterministic assistant answer used for the streaming tail: prose, a table and a code fence, repeated.
    public static func tailScript(minimumBytes: Int = 80_000) -> String {
        var rng = SpikeRNG(seed: seed &+ 7)
        var text = ""
        var section = 1
        while text.utf8.count < minimumBytes {
            text += "## Step \(section): \(words(&rng, count: 4).capitalized)\n\n"
            text += paragraphs(&rng, count: 2) + "\n\n"
            text += list(&rng) + "\n\n"
            text += table(&rng) + "\n\n"
            text += sentence(&rng) + "\n\n"
            text += codeFence(&rng, lines: rng.int(12...30)) + "\n\n"
            text += paragraphs(&rng, count: 1) + "\n\n"
            section += 1
        }
        return text
    }

    /// Splits `script` into deltas of 1 to 16 characters (deterministic).
    public static func tailDeltas(_ script: String) -> [String] {
        var rng = SpikeRNG(seed: seed &+ 11)
        var deltas: [String] = []
        var index = script.startIndex
        while index < script.endIndex {
            let length = rng.int(1...16)
            let end = script.index(index, offsetBy: length, limitedBy: script.endIndex) ?? script.endIndex
            deltas.append(String(script[index..<end]))
            index = end
        }
        return deltas
    }

    // MARK: Text pieces

    private static let vocabulary: [String] = """
        the a session server stream token buffer layout render model view message thread worktree branch commit \
        patch diff file build test cache height width scroll anchor selection window pane sidebar composer agent \
        tool output status request response event socket process child parent queue actor task update revision \
        project config value result error state change offset index range block fence table list heading link \
        image placeholder frame display refresh latency budget memory resident peak cold warm open close page \
        prepend append insert remove expand collapse reasoning approval question permission terminal browser \
        quickly carefully only never always usually then because while after before when so but and or with \
        from into over under between across through inside outside small large stable visible hidden pinned
        """.split(separator: " ").map(String.init)

    private static let identifiers = [
        "layoutCache", "rowHeight", "sessionID", "applyDelta", "flushPending", "visibleRange", "anchorOffset",
        "measure()", "TranscriptRow", "EventDecoder", "SSEParser", "commitInterval", "reloadData()", "Package.swift",
    ]

    private static func words(_ rng: inout SpikeRNG, count: Int) -> String {
        (0..<count).map { _ in rng.pick(vocabulary) }.joined(separator: " ")
    }

    private static func sentence(_ rng: inout SpikeRNG) -> String {
        var parts: [String] = []
        let count = rng.int(4...13)
        for index in 0..<count {
            var word = rng.pick(vocabulary)
            let roll = rng.unit()
            if roll < 0.04 {
                word = "`\(rng.pick(identifiers))`"
            } else if roll < 0.06 {
                word = "[\(word) docs](https://example.com/\(word)/\(rng.int(1...999)))"
            } else if roll < 0.08 {
                word = "**\(word)**"
            } else if roll < 0.10 {
                word = "*\(word)*"
            }
            if index == 0 { word = word.prefix(1).uppercased() + word.dropFirst() }
            parts.append(word)
        }
        return parts.joined(separator: " ") + "."
    }

    private static func paragraphs(_ rng: inout SpikeRNG, count: Int) -> String {
        (0..<count).map { _ in
            (0..<rng.int(1...3)).map { _ in sentence(&rng) }.joined(separator: " ")
        }.joined(separator: "\n\n")
    }

    private static func list(_ rng: inout SpikeRNG) -> String {
        let ordered = rng.chance(0.4)
        var lines: [String] = []
        for index in 1...rng.int(2...5) {
            lines.append((ordered ? "\(index). " : "- ") + sentence(&rng))
            if rng.chance(0.35) {
                for _ in 0..<rng.int(1...3) { lines.append("  - " + sentence(&rng)) }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func userText(_ rng: inout SpikeRNG) -> String {
        var text = paragraphs(&rng, count: rng.chance(0.3) ? 2 : 1)
        if rng.chance(0.15) { text += "\n\n" + list(&rng) }
        return text
    }

    private static func assistantIntro(_ rng: inout SpikeRNG) -> String {
        var text = ""
        if rng.chance(0.25) { text += "### \(words(&rng, count: rng.int(2...5)).capitalized)\n\n" }
        text += paragraphs(&rng, count: rng.int(1...2))
        if rng.chance(0.35) { text += "\n\n" + list(&rng) }
        return text
    }

    private static func table(_ rng: inout SpikeRNG) -> String {
        let columns = rng.int(2...5)
        let rows = rng.int(3...12)
        var lines: [String] = []
        lines.append("| " + (0..<columns).map { _ in rng.pick(vocabulary).capitalized }.joined(separator: " | ") + " |")
        lines.append("|" + String(repeating: " --- |", count: columns))
        for _ in 0..<rows {
            lines.append("| " + (0..<columns).map { _ in
                rng.chance(0.2) ? "`\(rng.pick(identifiers))`" : words(&rng, count: rng.int(1...4))
            }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private static let languages = ["swift", "typescript", "python", "rust", "go", "json", "bash"]

    private static func codeLine(_ rng: inout SpikeRNG, language: String, depth: Int) -> String {
        let indent = String(repeating: "  ", count: depth)
        let name = rng.pick(identifiers).replacingOccurrences(of: "()", with: "").replacingOccurrences(of: ".", with: "_")
        let number = rng.int(0...4096)
        switch language {
        case "swift":
            return indent + rng.pick([
                "let \(name)\(number) = try await fetch(\"\(rng.pick(vocabulary))\")",
                "func \(name)(_ value: Int) -> Bool { value > \(number) }",
                "if \(name).isEmpty { return nil } // \(words(&rng, count: 2))",
                "guard let item = cache[\(number)] else { continue }",
                "self.\(name) = \(name).map { $0 * \(number) }",
            ])
        case "typescript":
            return indent + rng.pick([
                "const \(name) = await fetchJson(`/api/\(rng.pick(vocabulary))`, { limit: \(number) });",
                "export function \(name)(value: number): boolean { return value > \(number); }",
                "if (!\(name)) { return undefined; } // \(words(&rng, count: 3))",
                "for (const row of rows) { total += row.\(name) ?? 0; }",
            ])
        case "python":
            return indent + rng.pick([
                "\(name) = client.fetch(\"\(rng.pick(vocabulary))\", limit=\(number))",
                "def \(name)(value: int) -> bool: return value > \(number)",
                "if not \(name): return None  # \(words(&rng, count: 3))",
                "for row in rows: total += row.get(\"\(name)\", 0)",
            ])
        case "rust":
            return indent + rng.pick([
                "let \(name) = client.fetch(\"\(rng.pick(vocabulary))\", \(number)).await?;",
                "pub fn \(name)(value: u32) -> bool { value > \(number) }",
                "if \(name).is_empty() { return None; } // \(words(&rng, count: 3))",
                "match state { State::Open => \(number), _ => 0 }",
            ])
        case "go":
            return indent + rng.pick([
                "\(name), err := client.Fetch(ctx, \"\(rng.pick(vocabulary))\", \(number))",
                "func \(name)(value int) bool { return value > \(number) }",
                "if err != nil { return nil, err } // \(words(&rng, count: 3))",
                "for _, row := range rows { total += row.Value }",
            ])
        case "json":
            return indent + "\"\(name)\": { \"\(rng.pick(vocabulary))\": \(number), \"enabled\": \(rng.chance(0.5)) },"
        default:
            return indent + rng.pick([
                "swift build -c release --product \(name)",
                "grep -rn \"\(rng.pick(vocabulary))\" Sources | head -\(number % 50)",
                "export \(name.uppercased())=\(number)",
                "echo \"\(words(&rng, count: 3))\" >> build/log.txt",
            ])
        }
    }

    private static func codeFence(_ rng: inout SpikeRNG, lines: Int) -> String {
        let language = rng.pick(languages)
        var body: [String] = []
        var depth = 0
        for _ in 0..<lines {
            body.append(codeLine(&rng, language: language, depth: depth))
            depth = max(0, min(3, depth + rng.int(-1...1)))
        }
        return "```\(language)\n" + body.joined(separator: "\n") + "\n```"
    }

    private static func hugeFence(_ rng: inout SpikeRNG) -> String {
        var body: [String] = []
        var bytes = 0
        var depth = 0
        while bytes < 100 * 1024 {
            let line = codeLine(&rng, language: "swift", depth: depth)
            bytes += line.utf8.count + 1
            body.append(line)
            depth = max(0, min(3, depth + rng.int(-1...1)))
        }
        return "```swift\n" + body.joined(separator: "\n") + "\n```"
    }

    private static func tool(_ rng: inout SpikeRNG) -> SpikeTool {
        let name = rng.pick(["bash", "read", "edit", "grep", "glob", "write", "webfetch"])
        let title: String = switch name {
        case "bash": "swift \(rng.pick(["build", "test", "package resolve"])) \(rng.pick(["-c release", "--parallel", ""]))"
        case "read", "edit", "write": "Sources/\(rng.pick(["Engine", "TranscriptKit", "OpenCodeKit"]))/\(rng.pick(identifiers)).swift"
        case "grep": "\(rng.pick(vocabulary)) in Sources"
        case "glob": "**/*.\(rng.pick(["swift", "md", "json"]))"
        default: "https://example.com/\(rng.pick(vocabulary))"
        }
        let u = rng.unit()
        let lineCount = 1 + Int(199 * u * u * u)
        var lines: [String] = []
        for index in 0..<lineCount {
            lines.append(rng.chance(0.5)
                ? "\(index + 1): \(words(&rng, count: rng.int(1...4)))"
                : "[\(rng.int(1...400))/\(lineCount)] Compiling \(rng.pick(identifiers))")
        }
        let status: SpikeToolStatus = rng.chance(0.08) ? .error : .completed
        return SpikeTool(name: name, title: title, status: status, output: lines.joined(separator: "\n"),
                         expandedByDefault: rng.chance(0.2))
    }

    private static func diff(_ rng: inout SpikeRNG) -> String {
        let file = "Sources/\(rng.pick(["Engine", "TranscriptKit", "DiffKit"]))/\(rng.pick(identifiers)).swift"
        var lines = ["--- a/\(file)", "+++ b/\(file)"]
        let total = rng.int(10...60)
        var start = rng.int(1...400)
        while lines.count < total {
            lines.append("@@ -\(start),7 +\(start),8 @@")
            for _ in 0..<rng.int(4...12) where lines.count < total {
                let roll = rng.unit()
                let code = codeLine(&rng, language: "swift", depth: rng.int(0...2))
                lines.append((roll < 0.25 ? "-" : roll < 0.55 ? "+" : " ") + code)
            }
            start += rng.int(20...80)
        }
        return lines.joined(separator: "\n")
    }

    private static func image(_ rng: inout SpikeRNG, id: Int) -> SpikeImageRef {
        SpikeImageRef(imageID: id,
                      pixelSize: CGSize(width: rng.int(160...1200), height: rng.int(90...700)),
                      colour: UInt32(truncatingIfNeeded: rng.next()) | 0x40_40_40,
                      delay: 0.2 + rng.unit() * 4.8)
    }
}
