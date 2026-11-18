import Foundation
import Testing

/// Fails when code under `Sources/` uses a timer on the system's uptime clock. On macOS 27 (Darwin 27.0) such timers
/// were seen not to fire while the process is otherwise idle, which hung timeouts and froze periodic UI. Use
/// BelloCore's `ContinuousDeadline` / `ContinuousTicker`, DesignSystem's `ContinuousTimeline`, a `Task.sleep(for:)`
/// (ContinuousClock) in an owned task, or `asyncAfter(wallDeadline:)` where a dispatch callback is required.
///
/// A use that is genuinely fine goes in `allowlist` with a one-line reason. Comment lines are not scanned.
@Suite("Uptime-clock timer guard")
struct TimerGuardTests {
    /// Banned API shapes. Each is a regular expression matched against one line of Swift (comments stripped).
    static let banned: [(name: String, pattern: String)] = [
        ("DispatchQueue.asyncAfter(deadline:)", #"asyncAfter\(\s*deadline:"#),
        ("dispatch timer source on the uptime clock", #"\.schedule\(\s*deadline:"#),
        ("Foundation Timer", #"Timer\.scheduledTimer|(?:^|[^A-Za-z0-9_])Timer\(|Timer\.publish|NSTimer"#),
        ("perform(_:afterDelay:) / cancelPreviousPerformRequests", #"afterDelay:"#),
        ("RunLoop.run(until:) / run(mode:before:)", #"(?:^|[^A-Za-z0-9_])run\(\s*until:|\.run\(\s*mode:[^)]*before:"#),
        ("SuspendingClock", #"\.suspending(?![A-Za-z0-9_])|SuspendingClock"#),
        ("Task.sleep(nanoseconds:) (uptime-clock delay)", #"sleep\(\s*nanoseconds:"#),
        ("dispatch wait(timeout:) on DispatchTime", #"\.wait\(\s*timeout:"#),
        ("CFRunLoopTimer", #"CFRunLoopTimer"#),
        ("SwiftUI periodic TimelineView", #"TimelineView\(\s*\.(periodic|everyMinute)"#),
    ]

    /// Every banned pattern contains one of these literally.
    static let keywords = ["asyncAfter", "schedule(", "Timer", "afterDelay", "run(", "uspending", "nanoseconds", "wait(", "TimelineView"]

    /// `(path relative to the package root, text the offending line contains, why it is fine)`.
    static let allowlist: [(path: String, contains: String, reason: String)] = [
        ("Sources/BelloCodeApp/Support/MainRunLoop.swift", "RunLoop.main.run(until:",
         "spins the main run loop for snapshot harnesses; a ContinuousClock task wakes it at the deadline"),
        ("Sources/TerminalDemo/Support.swift", "DispatchQueue.main.asyncAfter(deadline: scheduled",
         "demo latency probe measuring dispatch-timer lateness while the main thread is busy; not run by tests"),
    ]

    static var packageRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    struct Hit: CustomStringConvertible {
        var path: String
        var line: Int
        var text: String
        var rule: String
        var description: String { "\(path):\(line): \(rule): \(text)" }
    }

    static func scan() throws -> [Hit] {
        let root = packageRoot
        let sources = root.appending(path: "Sources")
        let rules = try banned.map { (name: $0.name, regex: try Regex($0.pattern)) }
        var hits: [Hit] = []
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else { return [] }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path(percentEncoded: false).dropFirst(root.path(percentEncoded: false).count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = Self.code(of: String(rawLine))
                // Cheap prefilter: Swift Regex over every line of the tree is slow.
                guard !line.isEmpty, Self.keywords.contains(where: { line.contains($0) }) else { continue }
                for rule in rules where line.contains(rule.regex) {
                    hits.append(Hit(path: relative, line: index + 1, text: line, rule: rule.name))
                }
            }
        }
        return hits
    }

    /// The line without leading whitespace and without a `//` comment (a `//` inside a string literal ends the scan
    /// early, which can only hide a hit on that line's tail; acceptable for a guard).
    static func code(of line: String) -> String {
        var code = line.trimmingCharacters(in: .whitespaces)
        if code.hasPrefix("*") || code.hasPrefix("/*") { return "" }
        if let comment = code.range(of: "//") {
            let prefix = code[..<comment.lowerBound]
            // Keep URLs ("https://") intact.
            if !prefix.hasSuffix(":") { code = String(prefix) }
        }
        return code.trimmingCharacters(in: .whitespaces)
    }

    @Test func productionCodeUsesNoUptimeClockTimers() throws {
        let hits = try Self.scan()
        #expect(!hits.isEmpty || FileManager.default.fileExists(atPath: Self.packageRoot.appending(path: "Sources").path),
                "Sources/ not found from \(#filePath)")
        let unexpected = hits.filter { hit in
            !Self.allowlist.contains { hit.path == $0.path && hit.text.contains($0.contains) }
        }
        #expect(unexpected.isEmpty, """
            Uptime-clock timers may not fire while the process is idle (macOS 27). Use ContinuousDeadline / \
            ContinuousTicker (BelloCore), ContinuousTimeline (DesignSystem), Task.sleep(for:) or \
            asyncAfter(wallDeadline:), or add an allowlist entry with a reason:
            \(unexpected.map(\.description).joined(separator: "\n"))
            """)
    }

    @Test func allowlistHasNoStaleEntries() throws {
        let hits = try Self.scan()
        let stale = Self.allowlist.filter { entry in !hits.contains { $0.path == entry.path && $0.text.contains(entry.contains) } }
        #expect(stale.isEmpty, "Allowlist entries that no longer match anything: \(stale.map { "\($0.path): \($0.contains)" })")
        #expect(Self.allowlist.allSatisfy { !$0.reason.isEmpty })
    }

    @Test func rulesCatchEachBannedShape() throws {
        let samples = [
            "queue.asyncAfter(deadline: .now() + 1) { }",
            "source.schedule(deadline: .now(), repeating: 1)",
            "let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }",
            "let t = Timer(timeInterval: 1, repeats: true) { _ in }",
            "perform(#selector(go), with: nil, afterDelay: 1)",
            "RunLoop.current.run(until: Date())",
            "try await Task.sleep(for: .seconds(1), clock: .suspending)",
            "try await Task.sleep(nanoseconds: 1_000)",
            "_ = group.wait(timeout: .now() + 1)",
            "TimelineView(.periodic(from: .now, by: 1)) { _ in }",
        ]
        let rules = try Self.banned.map { try Regex($0.pattern) }
        for sample in samples {
            #expect(rules.contains { sample.contains($0) }, "not caught: \(sample)")
            #expect(Self.keywords.contains { sample.contains($0) }, "prefilter skips: \(sample)")
        }
        let fine = [
            "queue.asyncAfter(wallDeadline: .now() + 1) { }",
            "try await Task.sleep(for: .seconds(1))",
            "autoscrollTimer?.stop()",
            "let ticker = ContinuousTicker(every: .seconds(1)) { }",
            "// asyncAfter(deadline:) in a comment",
        ]
        for sample in fine { #expect(!rules.contains { Self.code(of: sample).contains($0) }, "false positive: \(sample)") }
    }
}
