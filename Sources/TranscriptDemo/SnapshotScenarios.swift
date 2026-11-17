import AppKit
import BelloCore
import TranscriptKit
import DesignSystem

/// Renders transcript states to PNG in light and dark (the shell cannot take screenshots: views render themselves).
@MainActor
struct SnapshotScenarios {
    let window: NSWindow
    let only: Set<String>
    static let directory = URL(fileURLWithPath: "build/snapshots")

    struct Case {
        var name: String
        var size = NSSize(width: 900, height: 860)
        var messages: () -> [Message]
        var prepare: (TranscriptController) async -> Void = { _ in }
    }

    func run() async -> Bool {
        // In-process renders cannot capture vibrancy: draw glass surfaces with their solid fallback.
        DSGlassView.forcesSolidFallback = true
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        var written = 0
        for item in cases where only.isEmpty || only.contains(item.name) {
            for dark in [false, true] {
                if await render(item, dark: dark) { written += 1 } else { return false }
            }
        }
        print("wrote \(written) snapshots to \(Self.directory.path)")
        return true
    }

    func render(_ item: Case, dark: Bool) async -> Bool {
        let controller = TranscriptViewController()
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(item.size)
        window.setFrameOrigin(NSPoint(x: 60, y: 60))
        window.orderFrontRegardless()
        controller.view.layoutSubtreeIfNeeded()
        controller.bind(StaticTranscriptSource(messages: item.messages()))
        await controller.controller.settle()
        await item.prepare(controller.controller)
        await controller.controller.settle()
        controller.view.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return false }
        // Without font smoothing: `cacheDisplay` darkens stems so 13 pt regular reads as medium (implementation-guide).
        context.cgContext.setAllowsFontSmoothing(false)
        context.cgContext.setShouldSmoothFonts(false)
        view.displayIgnoringOpacity(view.bounds, in: context)
        let url = Self.directory.appending(path: "transcript-\(item.name)-\(dark ? "dark" : "light").png")
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url) } catch { print("FAIL \(url.path): \(error)"); return false }
        print("wrote \(url.lastPathComponent)")
        controller.close()
        window.contentViewController = nil
        return true
    }

    // MARK: Cases

    var cases: [Case] {
        [
            Case(name: "mixed", size: NSSize(width: 900, height: 1500), messages: TranscriptSamples.mixed),
            Case(name: "streaming-table", messages: { Self.streaming(cutAfter: "| `MarkdownParser.swift` |") }),
            Case(name: "streaming-code", messages: { Self.streaming(cutAfter: "let display = Self.displayPrefix(") }),
            Case(name: "workgroup-collapsed", size: NSSize(width: 900, height: 420), messages: Self.workGroup),
            Case(
                name: "workgroup-expanded", size: NSSize(width: 900, height: 560), messages: Self.workGroup,
                prepare: { controller in
                    if let id = controller.rowID(where: { if case .work = $0.content { true } else { false } }) {
                        controller.toggle(row: id, key: .group)
                        if case .work(let group)? = controller.rows.first(where: { $0.id == id })?.content, let bash = group.items.last {
                            controller.toggle(row: id, key: .tool(bash.id))
                        }
                    }
                }),
            Case(name: "tool-live", size: NSSize(width: 900, height: 480), messages: Self.liveTool),
            Case(
                name: "tool-failed", size: NSSize(width: 900, height: 460), messages: Self.failedTool,
                prepare: { controller in
                    if let row = controller.rows.first(where: { $0.isFailure }), case .work(let group) = row.content, let item = group.items.first {
                        controller.toggle(row: row.id, key: .tool(item.id))
                    }
                }),
            Case(
                name: "reasoning-expanded", size: NSSize(width: 900, height: 520), messages: Self.reasoning,
                prepare: { controller in
                    if let id = controller.rowID(where: { if case .reasoning = $0.content { true } else { false } }) {
                        controller.toggle(row: id, key: .reasoning)
                    }
                }),
            Case(
                name: "selection", size: NSSize(width: 900, height: 900), messages: TranscriptSamples.mixed,
                prepare: { controller in
                    let rows = controller.rows
                    guard let markdown = rows.firstIndex(where: { if case .markdown = $0.content { true } else { false } }) else { return }
                    let start = TranscriptPosition(rowID: rows[markdown].id, block: 7, offset: 4)
                    let endIndex = min(rows.count - 1, markdown + 3)
                    let end = TranscriptPosition(rowID: rows[endIndex].id, block: 0, offset: 20)
                    controller.select(from: start, to: end)
                    controller.reveal(FindMatch(rowID: rows[markdown].id, block: 7, range: 4..<5))
                    controller.tableView.window?.makeFirstResponder(controller.tableView)
                }),
            Case(
                name: "find", size: NSSize(width: 900, height: 900), messages: TranscriptSamples.mixed,
                prepare: { controller in
                    controller.showFind()
                    controller.findBarField.stringValue = "stream"
                    controller.setFindQuery("stream", debounce: false)
                    try? await Task.sleep(for: .milliseconds(300))
                    controller.findNext()
                }),
            Case(
                name: "jump-pill", size: NSSize(width: 900, height: 700), messages: TranscriptSamples.mixed,
                prepare: { controller in
                    controller.userScroll(by: -600)
                    try? await Task.sleep(for: .milliseconds(400))
                }),
            Case(name: "cards", size: NSSize(width: 900, height: 560), messages: Self.cards),
            Case(name: "wide-table-long-line", size: NSSize(width: 820, height: 760), messages: Self.wide),
            Case(name: "user-attachments", size: NSSize(width: 900, height: 400), messages: Self.attachments),
        ]
    }

    static func streaming(cutAfter marker: String) -> [Message] {
        var builder = TranscriptSamples.Builder()
        builder.user("Explain the streaming fix and show the code.")
        let text = TranscriptSamples.markdownReply
        let cut = text.range(of: marker).map { String(text[..<$0.upperBound]) } ?? text
        builder.assistant([.text(cut, streaming: true)], open: true)
        return builder.messages
    }

    static func workGroup() -> [Message] {
        var builder = TranscriptSamples.Builder()
        builder.user("Run the tests and summarise failures.")
        builder.assistant([
            .tool(name: "read", input: #"{"filePath":"Package.swift"}"#, output: "// swift-tools-version: 6.4", status: .completed, seconds: 0.1),
            .tool(name: "read", input: #"{"filePath":"Sources/TranscriptKit/Transcript/Controller/TranscriptController.swift"}"#, output: "import AppKit", status: .completed, seconds: 0.2),
            .tool(name: "glob", input: #"{"pattern":"Tests/**/*.swift"}"#, output: "Tests/TranscriptKitTests/MarkdownTests.swift\nTests/TranscriptKitTests/RowModelTests.swift", status: .completed, seconds: 0.1),
            .tool(name: "bash", input: #"{"command":"swift test --filter TranscriptKitTests 2>&1 | tail -20"}"#, output: "◇ Test run started.\n✔ Test everySplitPointMatchesOneShot() passed after 0.83 seconds.\n✔ Test characterStreamIsPrefixStable() passed after 0.41 seconds.\n✔ Suite MarkdownStreamTests passed after 1.24 seconds.\n✔ Test run with 48 tests in 9 suites passed after 3.10 seconds.", status: .completed, seconds: 3.1),
        ])
        builder.assistant([.text("All 48 transcript tests pass. Nothing to fix.")])
        return builder.messages
    }

    static func liveTool() -> [Message] {
        var builder = TranscriptSamples.Builder()
        builder.user("Build the release app.")
        builder.assistant([
            .tool(name: "read", input: #"{"filePath":"Makefile"}"#, output: "app:\n\tScripts/make-app.sh", status: .completed, seconds: 0.1),
            .tool(
                name: "bash", input: #"{"command":"make app"}"#, output: "", status: .running,
                metadata: #"{"output":"Building for production...\n[1/412] Compiling BelloCore Message.swift\n[37/412] Compiling Engine ThreadModel.swift\n[112/412] Compiling TranscriptKit LayoutEngine.swift\n[198/412] Compiling TranscriptKit TranscriptController.swift\n[260/412] Compiling ComposerKit ComposerController.swift\n[301/412] Linking BelloCode\n[344/412] Signing build/BelloCode.app"}"#),
        ], open: true)
        return builder.messages
    }

    static func failedTool() -> [Message] {
        var builder = TranscriptSamples.Builder()
        builder.user("Apply the patch to the README.")
        builder.assistant([
            .tool(
                name: "edit",
                input: ###"{"filePath":"README.md","oldString":"## Build\nRun make app.","newString":"## Build\nRun `make app`, then `make smoke`."}"###,
                output: "", status: .failed, seconds: 0.1, error: "oldString not found in README.md (the file changed since it was read)"),
        ])
        builder.assistant([.text("The edit failed because the README changed. I'll re-read it and try again.")])
        return builder.messages
    }

    static func reasoning() -> [Message] {
        var builder = TranscriptSamples.Builder()
        builder.user("Why does the anchor drift when an image loads above the viewport?")
        builder.assistant([
            .reasoning("""
                The anchor is captured as (row, block, offset) before the height change. When the image arrives the row \
                above re-lays out and NSTableView moves every row below it.

                - If restore runs before `noteHeightOfRows`, the offset is stale.
                - The table also estimates rows it has not asked about, so `rect(ofRow:)` must be forced from the changed row.

                So the fix is ordering: note heights, force geometry, then restore.
                """),
            .text("It drifts because the restore ran before the table recomputed its geometry. The fix is to note the new heights, force `rect(ofRow:)` from the changed row, then restore the anchor."),
        ])
        return builder.messages
    }

    static func cards() -> [Message] {
        var builder = TranscriptSamples.Builder()
        builder.user("Split the work between two agents.")
        builder.assistant([
            .subagent(description: "Audit accessibility labels in TranscriptKit", agent: "explore", status: .running, child: "ses_child_a"),
            .subagent(description: "Profile scrolling in the release build", agent: "general", status: .completed, child: "ses_child_b"),
            .subagent(description: "Update the feature note", agent: "general", status: .failed, child: "ses_child_c"),
        ])
        builder.assistant([.text("Two agents are done; one failed.")], error: ErrorInfo(type: "provider", message: "The provider closed the connection (502). Your prompt was kept; send it again to retry.", status: 502))
        builder.other("compaction", json: #"{"status":"completed","reason":"auto"}"#)
        builder.turnEnd(.interrupted)
        return builder.messages
    }

    static func wide() -> [Message] {
        var builder = TranscriptSamples.Builder()
        builder.user("Compare the spike and production numbers in one table, and show the minified bundle line.")
        let longLine = "const bundle = [" + (0..<60).map { "\"chunk-\($0)-\(String(repeating: "x", count: 6))\"" }.joined(separator: ", ") + "];"
        builder.assistant([
            .text("""
                | Scenario | Spike p50 | Spike p95 | Spike p99 | Production p50 | Production p95 | Production p99 | Frames > 16.7 ms | Frames > 33 ms | Notes |
                | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
                | S2 down | 8.3 | 8.3 | 16.9 | 8.3 | 8.3 | 16.8 | 1.2 % | 1 | traversal at 3× realistic flick speed |
                | S3 stream | 8.3 | 8.3 | 8.3 | 8.3 | 8.3 | 8.4 | 1 | 0 | 100 deltas per second through the Engine |

                ```javascript
                \(longLine)
                ```
                """)
        ])
        return builder.messages
    }

    static func attachments() -> [Message] {
        var builder = TranscriptSamples.Builder()
        let image = Self.sampleImageURL()
        builder.user(
            "Here is the screenshot and the log from @build/logs/smoke.txt — why does the window open blank?",
            files: [
                FileReference(uri: image.absoluteString, mime: "image/png", name: "blank-window.png"),
                FileReference(uri: "file:///tmp/smoke.txt", mime: "text/plain", name: "smoke.txt"),
            ])
        builder.user("Also, what about this one?", sending: true)
        return builder.messages
    }

    /// A small generated PNG for attachment snapshots.
    static func sampleImageURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "transcript-sample.png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let size = NSSize(width: 480, height: 300)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0.18, green: 0.2, blue: 0.26, alpha: 1).setFill()
            rect.fill()
            NSColor(srgbRed: 0.33, green: 0.55, blue: 0.95, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 400, height: 180), xRadius: 14, yRadius: 14).fill()
            NSColor.white.withAlphaComponent(0.85).setFill()
            for row in 0..<4 { NSRect(x: 70, y: 70 + row * 34, width: 300 - row * 40, height: 14).fill() }
            return true
        }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        return url
    }
}
