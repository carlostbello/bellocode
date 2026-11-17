import AppKit
import BelloCore
import Foundation
import Testing

@testable import TranscriptKit

@Suite struct HighlightTests {
    let highlighter = TokenizerHighlighter(costLimit: 100_000)

    func spans(_ code: String, _ language: String) -> [(String, TokenKind)] {
        let ns = code as NSString
        return highlighter.tokens(for: code, language: language).map { (ns.substring(with: NSRange(location: $0.location, length: $0.length)), $0.kind) }
    }

    func has(_ code: String, _ language: String, _ text: String, _ kind: TokenKind) -> Bool {
        spans(code, language).contains { $0.0 == text && $0.1 == kind }
    }

    @Test func coversTheCommonLanguages() {
        #expect(has("let x: Int = 42 // note", "swift", "let", .keyword))
        #expect(has("let x: Int = 42 // note", "swift", "Int", .type))
        #expect(has("let x: Int = 42 // note", "swift", "42", .number))
        #expect(has("let x: Int = 42 // note", "swift", "// note", .comment))
        #expect(has("@MainActor final class A {}", "swift", "@MainActor", .meta))
        #expect(has("const s = `a ${b}`; foo(1)", "ts", "`a ${b}`", .string))
        #expect(has("const s = `a ${b}`; foo(1)", "javascript", "foo", .function))
        #expect(has("def f(x):\n    return None  # done", "python", "def", .keyword))
        #expect(has("def f(x):\n    return None  # done", "py", "# done", .comment))
        #expect(has("\"\"\"doc\nstring\"\"\"", "python", "\"\"\"doc\nstring\"\"\"", .string))
        #expect(has("fn main() { let v: Vec<u8> = vec![]; }", "rust", "Vec", .type))
        #expect(has("#[derive(Debug)]", "rs", "#[derive(Debug)]", .meta))
        #expect(has("func main() { fmt.Println(\"hi\") }", "go", "\"hi\"", .string))
        #expect(has("SELECT id FROM users WHERE name = 'x'", "sql", "SELECT", .keyword))
        #expect(has("select id from t -- c", "sql", "-- c", .comment))
        #expect(has("{\"key\": \"value\", \"n\": 1, \"ok\": true}", "json", "\"key\"", .property))
        #expect(has("{\"key\": \"value\", \"n\": 1, \"ok\": true}", "json", "\"value\"", .string))
        #expect(has("{\"key\": \"value\", \"n\": 1, \"ok\": true}", "json", "true", .keyword))
        #expect(has("name: app # comment\ncount: 3\n", "yaml", "name", .property))
        #expect(has("name: app # comment\ncount: 3\n", "yml", "3", .number))
        #expect(has("name: app # comment\ncount: 3\n", "yaml", "# comment", .comment))
        #expect(has("export PATH=$HOME/bin; ls -la # list", "bash", "$HOME", .variable))
        #expect(has("export PATH=$HOME/bin; ls -la # list", "sh", "ls", .function))
        #expect(has("export PATH=$HOME/bin; ls -la # list", "zsh", "-la", .attribute))
        #expect(has("<div class=\"a\"><!-- c --></div>", "html", "<div", .tag))
        #expect(has("<div class=\"a\"><!-- c --></div>", "html", "class", .attribute))
        #expect(has("<div class=\"a\"><!-- c --></div>", "html", "<!-- c -->", .comment))
        #expect(has(".btn { color: #fff; margin: 4px; }", "css", ".btn", .type))
        #expect(has(".btn { color: #fff; margin: 4px; }", "css", "color", .property))
        #expect(has(".btn { color: #fff; margin: 4px; }", "css", "4px", .number))
        #expect(has("@@ -1 +1 @@\n-old\n+new\n", "diff", "+new", .diffAdded))
        #expect(has("@@ -1 +1 @@\n-old\n+new\n", "patch", "-old", .diffRemoved))
        #expect(has("@@ -1 +1 @@\n-old\n+new\n", "diff", "@@ -1 +1 @@", .diffHunk))
    }

    @Test func unknownLanguagesArePlainAndRunsAreOrdered() {
        #expect(highlighter.tokens(for: "anything at all", language: "klingon").isEmpty)
        #expect(highlighter.tokens(for: "anything", language: nil).isEmpty)
        let runs = highlighter.tokens(for: "let a = \"x\" // y\nvar b = 2", language: "swift")
        #expect(zip(runs, runs.dropFirst()).allSatisfy { $0.location + $0.length <= $1.location })
    }

    @Test func unterminatedConstructsNeverOverrun() {
        for code in ["\"open string", "/* open comment", "```", "'", "<div class=\"x", "{\"a\": "] {
            for language in ["swift", "json", "html", "css", "shell", "python"] {
                let units = code.utf16.count
                #expect(highlighter.tokens(for: code, language: language).allSatisfy { $0.location + $0.length <= units })
            }
        }
    }

    @Test func cachesByContent() async {
        let highlighter = TokenizerHighlighter(costLimit: 1_000)
        _ = highlighter.tokens(for: "let a = 1", language: "swift")
        _ = highlighter.tokens(for: "let a = 1", language: "swift")
        #expect(highlighter.cachedEntryCount == 1)
        for index in 0..<200 { _ = highlighter.tokens(for: "let value\(index) = \(index) // padding padding", language: "swift") }
        #expect(highlighter.cachedEntryCount < 60, "bounded by cost")
        let async = await highlighter.highlight("let a = 1", language: "swift")
        #expect(!async.isEmpty)
    }
}

@Suite struct SelectionTests {
    func row(_ id: String, _ blocks: [RenderBlock], visible: [Bool]? = nil, source: String? = nil) -> CopyRow {
        CopyRow(id: RowID(id), blocks: blocks, visible: visible ?? blocks.map { _ in true }, markdownSource: source)
    }

    func md(_ text: String) -> [RenderBlock] { MarkdownParser.blocks(text).map { RenderBlock(.markdown($0, tone: .normal)) } }

    @Test func plainCopyAcrossRowsBlocksListsTablesAndCode() {
        let first = row("a", md("Intro paragraph.\n\n- one\n- two\n\n| x | y |\n|---|---|\n| 1 | 2 |"), source: "src-a")
        let second = row("b", md("```swift\nlet a = 1\n```\n\nAfter."), source: "src-b")
        let start = TranscriptPosition(rowID: RowID("a"), block: 0, offset: 6)
        let end = TranscriptPosition(rowID: RowID("b"), block: 1, offset: 3)
        let text = SelectionText.plain([first, second], start: start, end: end)
        #expect(text == "paragraph.\n\n• one\n• two\n\nx\ty\n1\t2\n\nlet a = 1\n\nAft")
        // Markdown: the first row is partial (plain), nothing of the second is whole either.
        let whole = SelectionText.markdown(
            [first, second], start: TranscriptPosition(rowID: RowID("a"), block: 0, offset: 0),
            end: TranscriptPosition(rowID: RowID("b"), block: 1, offset: 6))
        #expect(whole == "src-a\n\nsrc-b")
    }

    @Test func collapsedBlocksAreSkipped() {
        let item = ToolItem(id: PartID("t"), name: "bash", category: .command, verb: "Ran", target: "ls", status: .done, input: "$ ls", output: "a\nb")
        let blocks = [RenderBlock(.toolHeader(item)), RenderBlock(.toolDetail(item), visibility: .expanded(.tool(PartID("t"))))]
        let collapsed = row("w", blocks, visible: [true, false])
        let text = SelectionText.plain(
            [collapsed], start: TranscriptPosition(rowID: RowID("w"), block: 0, offset: 0),
            end: TranscriptPosition(rowID: RowID("w"), block: 1, offset: 99))
        #expect(text == "Ran ls")
        let expanded = row("w", blocks)
        let all = SelectionText.plain(
            [expanded], start: TranscriptPosition(rowID: RowID("w"), block: 0, offset: 0),
            end: TranscriptPosition(rowID: RowID("w"), block: 1, offset: 99))
        #expect(all == "Ran ls\n$ ls\n\na\nb")
    }

    @Test func rowSelectionsAndOrdering() {
        let order = ["a": 0, "b": 1, "c": 2]
        let index: (RowID) -> Int? = { order[$0.rawValue] }
        let selection = TranscriptSelection(
            anchor: TranscriptPosition(rowID: RowID("c"), block: 1, offset: 2),
            focus: TranscriptPosition(rowID: RowID("a"), block: 0, offset: 5))
        #expect(selection.ordered(index)?.start.rowID == RowID("a"))
        let first = selection.rowSelection(row: 0, rowID: RowID("a"), index)
        #expect(first?.start?.offset == 5 && first?.end == nil)
        #expect(first?.range(forBlock: 0, length: 10)?.range == 5..<10 && first?.range(forBlock: 0, length: 10)?.extends == true)
        let middle = selection.rowSelection(row: 1, rowID: RowID("b"), index)
        #expect(middle?.start == nil && middle?.end == nil)
        let last = selection.rowSelection(row: 2, rowID: RowID("c"), index)
        #expect(last?.range(forBlock: 0, length: 4)?.range == 0..<4)
        #expect(last?.range(forBlock: 1, length: 4)?.range == 0..<2)
        #expect(last?.range(forBlock: 2, length: 4) == nil)
    }

    @Test func wordParagraphAndGraphemeSteps() {
        let text = "Hello, wörld_1 👩‍👩‍👧 end\nnext line"
        let ns = text as NSString
        #expect(ns.substring(with: NSRange(SelectionText.wordRange(in: text, at: 9))) == "wörld_1")
        #expect(ns.substring(with: NSRange(SelectionText.paragraphRange(in: text, at: 2))) == "Hello, wörld_1 👩‍👩‍👧 end")
        let emoji = ns.range(of: "👩‍👩‍👧")
        #expect(SelectionText.step(in: text, from: emoji.location, forward: true) == emoji.location + emoji.length)
        #expect(SelectionText.step(in: text, from: emoji.location + emoji.length, forward: false) == emoji.location)
    }

    @Test func findMatchesAreCaseAndDiacriticInsensitive() {
        let entries = [
            FindIndexEntry(rowID: RowID("a"), version: 1, blocks: ["Café STREAM", "nothing"]),
            FindIndexEntry(rowID: RowID("b"), version: 1, blocks: ["streams stream"]),
        ]
        let matches = FindSearch.matches(entries, query: "stream")
        #expect(matches.count == 3)
        #expect(FindSearch.matches(entries, query: "cafe").first?.range == 0..<4)
        let order = ["a": 0, "b": 1]
        let at = FindSearch.firstIndex(in: matches, atOrAfter: TranscriptPosition(rowID: RowID("b"), block: 0, offset: 3)) { order[$0.rawValue] }
        #expect(at == 2)
    }
}

@Suite @MainActor struct LayoutTests {
    func theme() -> TranscriptTheme {
        TranscriptTheme.resolve(appearance: NSAppearance(named: .aqua)!, baseSize: 13, revision: 1)
    }

    func layout(_ row: TranscriptRow, ui: RowUIState = RowUIState(), width: CGFloat = 600) -> RowLayout {
        LayoutEngine.layoutNow(
            RowLayoutInput(row: row, ui: ui, width: width, theme: theme(), topPadding: 0, imageSizes: [:], highlighter: TokenizerHighlighter.shared),
            fonts: TranscriptFonts(theme: theme()))
    }

    /// Selectable text in every visible block equals the block's plain text (selection, copy and find agree).
    @Test func layoutLengthsMatchPlainText() {
        let rows = RowBuilder.rows(for: TranscriptSamples.mixed(), isRunning: false)
        for row in rows {
            var ui = RowUIState()
            for key in [ExpansionKey.reasoning, .group] { ui.overrides[key] = true }
            if case .work(let group) = row.content { for item in group.items { ui.overrides[.tool(item.id)] = true } }
            let layout = layout(row, ui: ui)
            let blocks = RenderBlocks.blocks(for: row)
            #expect(layout.blocks.count == blocks.count)
            for (block, laidOut) in zip(blocks, layout.blocks) where !laidOut.isHidden {
                let expected = (block.plainText as NSString).length
                if case .markdown(let markdown, _) = block.kind, case .rule = markdown.kind { continue }
                #expect(laidOut.plainLength == expected, "\(row.id) \(block.kind)")
            }
        }
    }

    @Test func longCodeLinesScrollInsteadOfTruncating() {
        let line = String(repeating: "x", count: 3_000)
        let row = TranscriptRow(
            id: RowID("p:code"), messageID: MessageID("m"), turnID: nil, role: .assistant,
            content: .markdown(text: "```\n\(line)\n```", isStreaming: false), version: 1, created: Timestamp(milliseconds: 0))
        let layout = layout(row)
        let block = layout.blocks[0]
        #expect(block.plainLength == 3_000)
        #expect(block.scroll?.scrollsHorizontally == true)
        #expect((block.scroll?.contentSize.width ?? 0) > 3_000 * 5)
        // Hit-testing far into the scrolled content reaches the end of the line.
        let offset = CGPoint(x: block.scroll!.maxOffset.x, y: 0)
        let hit = block.hitTest(CGPoint(x: block.scroll!.viewport.maxX - 2, y: block.scroll!.viewport.midY), scrollOffset: offset)
        #expect(hit > 2_900)
    }

    @Test func wideTablesScrollAndNarrowOnesDoNot() {
        let wide = "| " + (0..<12).map { "Column \($0)" }.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 12) + "\n| " + (0..<12).map { "v\($0)" }.joined(separator: " | ") + " |"
        let make = { (text: String) in
            TranscriptRow(
                id: RowID("p:t"), messageID: MessageID("m"), turnID: nil, role: .assistant, content: .markdown(text: text, isStreaming: false),
                version: 1, created: Timestamp(milliseconds: 0))
        }
        #expect(layout(make(wide)).blocks[0].scroll?.scrollsHorizontally == true)
        #expect(layout(make("| a | b |\n|---|---|\n| 1 | 2 |")).blocks[0].scroll == nil)
    }

    @Test func collapsedBlocksTakeNoSpaceAndExpandingGrowsTheRow() {
        let rows = RowBuilder.rows(for: TranscriptSamples.mixed(), isRunning: false)
        guard let work = rows.first(where: { if case .work = $0.content { true } else { false } }) else { Issue.record("no work"); return }
        let collapsed = layout(work)
        var ui = RowUIState()
        ui.overrides[.group] = true
        let expanded = layout(work, ui: ui)
        #expect(expanded.height > collapsed.height)
        #expect(collapsed.blocks.filter(\.isHidden).allSatisfy { $0.size == .zero && $0.plainLength == 0 })
        // Hit-testing never lands in a hidden block.
        for y in stride(from: 0, to: collapsed.height, by: 3) {
            let hit = collapsed.hitTest(CGPoint(x: 40, y: y))
            #expect(!collapsed.blocks[hit.block].isHidden)
        }
    }

    @Test func userBubbleIsRightAlignedAndCompact() {
        let row = TranscriptRow(
            id: RowID("m:u"), messageID: MessageID("u"), turnID: nil, role: .user, content: .user(UserRowContent(text: "Short prompt")),
            version: 1, created: Timestamp(milliseconds: 0))
        let layout = layout(row, width: 700)
        let bubble = layout.blocks[0].decorations[0].rect
        #expect(bubble.maxX == 700)
        #expect(bubble.width < 200)
    }

    @Test func estimatesAreInTheRightBallpark() {
        let rows = RowBuilder.rows(for: TranscriptSamples.mixed(), isRunning: false)
        for row in rows {
            let exact = layout(row).height
            let estimate = LayoutEngine.estimate(row, width: 600, theme: theme(), topPadding: 0)
            #expect(estimate > exact * 0.3 && estimate < exact * 3 + 40, "\(row.id): \(estimate) vs \(exact)")
        }
    }
}
