// G1-A spike: deterministic standard workload (seed 42). Shared shape with the G1-B spike's brief; generated
// in-process so both candidates can be compared on identical data.

import Foundation

/// SplitMix64: small, fast and fully deterministic across runs and platforms.
public struct SpikeRNG: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }

    public mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    public mutating func chance(_ p: Double) -> Bool { unit() < p }
    public mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }

    public mutating func shuffle<T>(_ items: inout [T]) {
        guard items.count > 1 else { return }
        for i in stride(from: items.count - 1, to: 0, by: -1) {
            items.swapAt(i, Int(next() % UInt64(i + 1)))
        }
    }
}

// MARK: - Model

public enum SpikeRole: String, Sendable { case user, assistant }

public struct SpikeTool: Sendable, Hashable {
    public let id: String
    public let name: String
    public let title: String
    public let status: String
    public let output: [String]
}

public struct SpikeImage: Sendable, Hashable {
    public let id: String
    public let width: Int
    public let height: Int
    public let rgb: UInt32
    /// Delivery delay after the attachment is first drawn, in milliseconds (async arrival changes height).
    public let delayMS: Int
}

public struct SpikeDiff: Sendable, Hashable {
    public let id: String
    public let path: String
    public let lines: [String]
}

public enum SpikePart: Sendable, Hashable {
    case markdown(String)
    case tool(SpikeTool)
    case reasoning(id: String, text: String)
    case diff(SpikeDiff)
    case image(SpikeImage)
}

public struct SpikeMessage: Sendable, Identifiable, Hashable {
    public let id: String
    public let role: SpikeRole
    public let parts: [SpikePart]

    public init(id: String, role: SpikeRole, parts: [SpikePart]) {
        self.id = id
        self.role = role
        self.parts = parts
    }
}

public struct SpikeWorkloadStats: Sendable {
    public var messages = 0
    public var totalUTF8Bytes = 0
    public var tables = 0
    public var codeBlocks = 0
    public var hugeCodeBlockBytes = 0
    public var tools = 0
    public var reasoning = 0
    public var diffs = 0
    public var images = 0
}

public struct SpikeTranscript: Sendable {
    public let messages: [SpikeMessage]
    public let stats: SpikeWorkloadStats
    /// A string present only in one prose message (index `offscreenNeedleMessage`).
    public static let offscreenNeedle = "quokka-offscreen-needle"
    public static let offscreenNeedleMessage = 3001
    /// A string present only in the output of one tool card, which is collapsed by default.
    public static let collapsedNeedle = "wombat-collapsed-needle"
    /// The assistant message that holds the single 100 KB code block.
    public static let hugeBlockMessage = 5001
}

// MARK: - Generator

public enum SpikeWorkload {
    public static func generate(seed: UInt64 = 42, messageCount: Int = 10_000) -> SpikeTranscript {
        var rng = SpikeRNG(seed: seed)
        let gen = Generator()
        let assistantSlots = messageCount / 2

        enum Feature { case table, code, tool, reasoning, diff, image }
        var features: [Feature] = []
        features += Array(repeating: .table, count: 400)
        features += Array(repeating: .code, count: 1_500)
        features += Array(repeating: .tool, count: 2_000)
        features += Array(repeating: .reasoning, count: 300)
        features += Array(repeating: .diff, count: 200)
        features += Array(repeating: .image, count: 100)
        rng.shuffle(&features)
        var perSlot = Array(repeating: [Feature](), count: assistantSlots)
        for feature in features {
            var slot = rng.int(0...(assistantSlots - 1))
            // One reasoning block per message at most.
            while feature == .reasoning, perSlot[slot].contains(.reasoning) { slot = (slot + 1) % assistantSlots }
            perSlot[slot].append(feature)
        }

        var stats = SpikeWorkloadStats()
        var messages: [SpikeMessage] = []
        messages.reserveCapacity(messageCount)
        var collapsedNeedlePlaced = false

        for index in 0..<messageCount {
            let id = String(format: "msg-%05d", index)
            if index % 2 == 0 {
                let text = gen.userProse(&rng)
                messages.append(SpikeMessage(id: id, role: .user, parts: [.markdown(text)]))
                stats.totalUTF8Bytes += text.utf8.count
                continue
            }
            let slot = index / 2
            var parts: [SpikePart] = []
            var markdown = ""
            func flush() {
                if !markdown.isEmpty { parts.append(.markdown(markdown)); markdown = "" }
            }
            var slotFeatures = perSlot[slot]
            if let r = slotFeatures.firstIndex(of: .reasoning) {
                slotFeatures.remove(at: r)
                let text = gen.reasoning(&rng)
                parts.append(.reasoning(id: "rsn-\(index)", text: text))
                stats.reasoning += 1
                stats.totalUTF8Bytes += text.utf8.count
            }
            markdown += gen.assistantProse(&rng)
            if index == SpikeTranscript.offscreenNeedleMessage {
                markdown += "\n\nThe \(SpikeTranscript.offscreenNeedle) is documented here.\n"
            }
            if index == SpikeTranscript.hugeBlockMessage {
                let block = gen.hugeCodeBlock(&rng, bytes: 100 * 1_024)
                markdown += "\n\nHere is the full generated fixture:\n\n```json\n" + block + "```\n"
                stats.hugeCodeBlockBytes = block.utf8.count
            }
            for (n, feature) in slotFeatures.enumerated() {
                switch feature {
                case .table:
                    markdown += "\n\n" + gen.table(&rng)
                    stats.tables += 1
                case .code:
                    markdown += "\n\n" + gen.codeFence(&rng)
                    stats.codeBlocks += 1
                case .tool:
                    flush()
                    var tool = gen.tool(&rng, id: "tool-\(index)-\(n)")
                    if !collapsedNeedlePlaced, index > 7_000 {
                        var output = tool.output
                        output.insert("warning: \(SpikeTranscript.collapsedNeedle) found in cache layer", at: output.count / 2)
                        tool = SpikeTool(id: tool.id, name: tool.name, title: tool.title, status: tool.status, output: output)
                        collapsedNeedlePlaced = true
                    }
                    parts.append(.tool(tool))
                    stats.tools += 1
                    stats.totalUTF8Bytes += tool.output.reduce(tool.title.utf8.count) { $0 + $1.utf8.count + 1 }
                case .diff:
                    flush()
                    let diff = gen.diff(&rng, id: "diff-\(index)-\(n)")
                    parts.append(.diff(diff))
                    stats.diffs += 1
                    stats.totalUTF8Bytes += diff.lines.reduce(0) { $0 + $1.utf8.count + 1 }
                case .image:
                    flush()
                    parts.append(.image(gen.image(&rng, id: "img-\(index)-\(n)")))
                    stats.images += 1
                case .reasoning:
                    break
                }
                if rng.chance(0.5) { markdown += "\n\n" + gen.paragraph(&rng) }
            }
            flush()
            for case let .markdown(text) in parts { stats.totalUTF8Bytes += text.utf8.count }
            messages.append(SpikeMessage(id: id, role: .assistant, parts: parts))
        }
        stats.messages = messages.count
        return SpikeTranscript(messages: messages, stats: stats)
    }

    /// A page of 100 older messages, prepended in the anchor test.
    public static func olderPage(seed: UInt64 = 4_242, count: Int = 100) -> [SpikeMessage] {
        var rng = SpikeRNG(seed: seed)
        let gen = Generator()
        return (0..<count).map { index in
            let id = String(format: "old-%05d", index)
            if index % 2 == 0 { return SpikeMessage(id: id, role: .user, parts: [.markdown(gen.userProse(&rng))]) }
            var parts: [SpikePart] = [.markdown(gen.assistantProse(&rng))]
            if rng.chance(0.3) { parts.append(.markdown(gen.codeFence(&rng))) }
            if rng.chance(0.3) { parts.append(.tool(gen.tool(&rng, id: "oldtool-\(index)"))) }
            return SpikeMessage(id: id, role: .assistant, parts: parts)
        }
    }

    /// Markdown streamed into the tail: prose, a list, a table and a code fence, repeated to `bytes`.
    public static func streamScript(seed: UInt64 = 4_243, bytes: Int = 90_000) -> String {
        var rng = SpikeRNG(seed: seed)
        let gen = Generator()
        var out = ""
        var round = 0
        while out.utf8.count < bytes {
            round += 1
            out += "## Step \(round): \(gen.sentence(&rng, words: 4...7))\n\n"
            out += gen.paragraph(&rng) + "\n\n"
            out += gen.list(&rng) + "\n\n"
            out += gen.paragraph(&rng) + "\n\n"
            out += gen.table(&rng) + "\n\n"
            out += gen.codeFence(&rng, lines: 20...40) + "\n\n"
        }
        return out
    }
}

// MARK: - Text generation

private struct Generator {
    let words = """
    the a to of and in that is for it with as on this be are by from at or an we you can if not will when which \
    request response server client session message stream token cache layer buffer render layout view model state \
    actor task thread queue event handler update value index offset range height width frame scroll anchor viewport \
    parser decoder encoder schema field record table column row commit branch merge worktree diff patch file path \
    build test run fix check verify measure compile deploy retry timeout error warning result output input config \
    option default setting project module package target dependency version release debug trace profile signpost \
    latency throughput memory budget limit bound overflow resync reconnect replay snapshot delta revision generation
    """.split(separator: " ").map(String.init)
    let identifiers = ["sessionID", "messageStore", "layoutCache", "renderQueue", "applyDelta", "TranscriptView",
                       "EventHub", "parseFrame", "anchorOffset", "streamBuffer", "flushPending", "viewportRange",
                       "ProjectionStore", "reconcile", "fetchPage", "measureHeight", "scrollToLatest", "configPath"]
    let languages = ["swift", "typescript", "python", "rust", "go", "bash", "json"]

    func word(_ rng: inout SpikeRNG) -> String { rng.pick(words) }

    func sentence(_ rng: inout SpikeRNG, words count: ClosedRange<Int> = 8...20) -> String {
        let n = rng.int(count)
        var parts: [String] = []
        parts.reserveCapacity(n)
        for i in 0..<n {
            var w = word(&rng)
            if i == 0 { w = w.prefix(1).uppercased() + w.dropFirst() }
            let roll = rng.unit()
            if roll < 0.04 { w = "`\(rng.pick(identifiers))()`" }
            else if roll < 0.06 { w = "**\(w)**" }
            else if roll < 0.08 { w = "*\(w)*" }
            else if roll < 0.09 { w = "[\(w) docs](https://example.com/\(w))" }
            parts.append(w)
        }
        return parts.joined(separator: " ") + "."
    }

    func paragraph(_ rng: inout SpikeRNG) -> String {
        (0..<rng.int(2...4)).map { _ in sentence(&rng) }.joined(separator: " ")
    }

    func list(_ rng: inout SpikeRNG) -> String {
        var lines: [String] = []
        let ordered = rng.chance(0.3)
        for i in 1...rng.int(2...5) {
            lines.append(ordered ? "\(i). \(sentence(&rng, words: 4...10))" : "- \(sentence(&rng, words: 4...10))")
            if rng.chance(0.35) {
                for _ in 0..<rng.int(1...2) { lines.append("  - \(sentence(&rng, words: 3...8))") }
                if rng.chance(0.3) { lines.append("    - \(sentence(&rng, words: 3...6))") }
            }
        }
        return lines.joined(separator: "\n")
    }

    func userProse(_ rng: inout SpikeRNG) -> String {
        var parts = [paragraph(&rng)]
        if rng.chance(0.25) { parts.append(paragraph(&rng)) }
        if rng.chance(0.1) { parts.append(list(&rng)) }
        return parts.joined(separator: "\n\n")
    }

    func assistantProse(_ rng: inout SpikeRNG) -> String {
        var parts: [String] = []
        if rng.chance(0.2) { parts.append("### \(sentence(&rng, words: 3...6).dropLast())") }
        parts.append(paragraph(&rng))
        if rng.chance(0.3) { parts.append(list(&rng)) }
        if rng.chance(0.25) { parts.append(paragraph(&rng)) }
        return parts.joined(separator: "\n\n")
    }

    func reasoning(_ rng: inout SpikeRNG) -> String {
        (0..<rng.int(1...3)).map { _ in paragraph(&rng) }.joined(separator: "\n\n")
    }

    func table(_ rng: inout SpikeRNG) -> String {
        let columns = rng.int(3...5)
        let rows = rng.int(3...12)
        var header: [String] = []
        for _ in 0..<columns { header.append(word(&rng).capitalized) }
        var out = "| " + header.joined(separator: " | ") + " |\n"
        out += "|" + Array(repeating: " --- |", count: columns).joined() + "\n"
        for _ in 0..<rows {
            var cells: [String] = []
            for c in 0..<columns {
                switch (c + rng.int(0...2)) % 3 {
                case 0: cells.append(String(rng.int(0...99_999)))
                case 1: cells.append("`\(rng.pick(identifiers))`")
                default: cells.append((0..<rng.int(1...3)).map { _ in word(&rng) }.joined(separator: " "))
                }
            }
            out += "| " + cells.joined(separator: " | ") + " |\n"
        }
        return out
    }

    func codeLine(_ rng: inout SpikeRNG, language: String, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent * 4)
        let a = rng.pick(identifiers), b = rng.pick(identifiers), n = rng.int(0...4_096)
        switch language {
        case "swift":
            return pad + rng.pick(["let \(a) = try await \(b)(id: \(n))", "if \(a).isEmpty { return nil }",
                                  "// \(sentence(&rng, words: 3...7))", "func \(a)(_ value: Int) -> String {",
                                  "guard let \(a) = \(b)[\(n)] else { throw SpikeError.missing }", "}"])
        case "typescript":
            return pad + rng.pick(["const \(a) = await \(b)(\(n));", "if (!\(a)) { return undefined; }",
                                  "// \(sentence(&rng, words: 3...7))", "export function \(a)(value: number): string {",
                                  "return \(b).map((x) => x + \(n));", "}"])
        case "python":
            return pad + rng.pick(["\(a) = \(b)(\(n))", "if not \(a):", "    return None",
                                  "# \(sentence(&rng, words: 3...7))", "def \(a)(value: int) -> str:",
                                  "for item in \(b): yield item * \(n)"])
        case "rust":
            return pad + rng.pick(["let \(a) = \(b)(\(n))?;", "if \(a).is_empty() { return None; }",
                                  "// \(sentence(&rng, words: 3...7))", "pub fn \(a)(value: u32) -> String {",
                                  "match \(b) { Some(x) => x, None => \(n) }", "}"])
        case "go":
            return pad + rng.pick(["\(a), err := \(b)(\(n))", "if err != nil { return nil, err }",
                                  "// \(sentence(&rng, words: 3...7))", "func \(a)(value int) string {",
                                  "return fmt.Sprintf(\"%d\", \(n))", "}"])
        case "bash":
            return pad + rng.pick(["export \(a.uppercased())=\(n)", "if [ -z \"$\(a)\" ]; then exit 1; fi",
                                  "# \(sentence(&rng, words: 3...7))", "swift build -c release --product \(a)",
                                  "echo \"\(b) done in \(n) ms\""])
        default:
            return pad + rng.pick(["\"\(a)\": \(n),", "\"\(b)\": \"\(word(&rng))\",", "\"enabled\": true,",
                                  "\"items\": [\(n), \(n + 1), \(n + 2)],"])
        }
    }

    func codeFence(_ rng: inout SpikeRNG, lines: ClosedRange<Int> = 5...80) -> String {
        let language = rng.pick(languages)
        var out = "```\(language)\n"
        var indent = 0
        for _ in 0..<rng.int(lines) {
            out += codeLine(&rng, language: language, indent: indent) + "\n"
            indent = max(0, min(3, indent + rng.int(-1...1)))
        }
        return out + "```"
    }

    func hugeCodeBlock(_ rng: inout SpikeRNG, bytes: Int) -> String {
        var out = ""
        out.reserveCapacity(bytes + 100)
        while out.utf8.count < bytes - 64 {
            out += codeLine(&rng, language: "json", indent: rng.int(0...2)) + "\n"
        }
        while out.utf8.count < bytes - 1 { out += " " }
        return out + "\n"
    }

    func tool(_ rng: inout SpikeRNG, id: String) -> SpikeTool {
        let name = rng.pick(["bash", "read", "edit", "grep", "glob", "write", "webfetch", "task"])
        let title: String
        switch name {
        case "bash": title = rng.pick(["swift test --filter \(rng.pick(identifiers))", "npm run build", "git status --short", "make smoke"])
        case "read", "edit", "write": title = "Sources/\(rng.pick(identifiers))/\(rng.pick(identifiers)).swift"
        case "grep", "glob": title = "\"\(rng.pick(identifiers))\" in Sources/"
        default: title = sentence(&rng, words: 3...6)
        }
        let status = rng.chance(0.88) ? "completed" : (rng.chance(0.7) ? "failed" : "cancelled")
        let count = 1 + Int(pow(rng.unit(), 2.2) * 199)
        var output: [String] = []
        output.reserveCapacity(count)
        for i in 0..<count {
            switch rng.int(0...3) {
            case 0: output.append("[\(i)] \(sentence(&rng, words: 3...9))")
            case 1: output.append(codeLine(&rng, language: rng.pick(languages), indent: 0))
            case 2: output.append("Sources/\(rng.pick(identifiers)).swift:\(rng.int(1...900)): \(word(&rng)) \(word(&rng))")
            default: output.append("ok \(rng.int(1...500)) - \(rng.pick(identifiers)) (\(rng.int(1...999)) ms)")
            }
        }
        return SpikeTool(id: id, name: name, title: title, status: status, output: output)
    }

    func diff(_ rng: inout SpikeRNG, id: String) -> SpikeDiff {
        let language = rng.pick(["swift", "typescript", "go"])
        let path = "Sources/\(rng.pick(identifiers))/\(rng.pick(identifiers)).\(language == "swift" ? "swift" : language == "go" ? "go" : "ts")"
        var lines = ["--- a/\(path)", "+++ b/\(path)"]
        let count = rng.int(10...60)
        var start = rng.int(1...400)
        while lines.count < count + 2 {
            let hunk = min(count + 2 - lines.count, rng.int(6...20))
            lines.append("@@ -\(start),\(hunk) +\(start),\(hunk + 1) @@")
            for _ in 0..<max(1, hunk - 1) {
                let roll = rng.unit()
                let prefix = roll < 0.6 ? " " : (roll < 0.8 ? "-" : "+")
                lines.append(prefix + codeLine(&rng, language: language, indent: rng.int(0...2)))
            }
            start += rng.int(20...80)
        }
        return SpikeDiff(id: id, path: path, lines: lines)
    }

    func image(_ rng: inout SpikeRNG, id: String) -> SpikeImage {
        SpikeImage(id: id, width: rng.int(120...900), height: rng.int(80...600),
                   rgb: UInt32(truncatingIfNeeded: rng.next() & 0xFF_FFFF), delayMS: rng.int(50...1_500))
    }
}
