import Foundation
import Testing

@testable import TranscriptKit

/// A GFM corpus covering the constructs agents write, including the ones that make streaming hard (lists that turn
/// loose, setext headings, tables, nested quotes, fences with inner backticks, task lists, HTML).
enum Corpus {
    static let markdown = """
        # Plan

        I'll look at `Parser.swift` first, then **update** the *tests* and ~~old code~~. See [the docs](https://example.com/docs "Docs").

        Setext heading
        ==============

        - one
        - two with `code`
          continued line
        - three

        1. first
        2. second

           nested paragraph in item two

           - inner bullet
           - [x] done task
           - [ ] open task

        > A quote with **bold**
        > continuing.
        >
        > > nested quote

        | Column | Value | Notes |
        | :----- | ----: | :---: |
        | a      | 1     | ok    |
        | b `x`  | 22    | [link](https://e.com) |

        ```swift
        let value = "string with ``` inside"
        func run() async throws -> Int { 42 }
        ```

        ~~~
        tilde fence
        ~~~

            indented code

        ---

        ![diagram](https://example.com/d.png)

        <div>raw html</div>

        Final paragraph with a hard
        break and an autolink https://example.com and a footnote-like [^1] marker.
        """
}

@Suite struct MarkdownParserTests {
    @Test func parsesGFMConstructs() {
        let blocks = MarkdownParser.blocks(Corpus.markdown)
        let kinds = blocks.map { block -> String in
            switch block.kind {
            case .paragraph: "p"
            case .heading(let level, _): "h\(level)"
            case .listItem(let marker, let checkbox, _): "li(\(marker)\(checkbox.map { $0 ? "x" : "o" } ?? ""))"
            case .code(let language, _): "code(\(language ?? ""))"
            case .table: "table"
            case .rule: "hr"
            case .image: "img"
            }
        }
        #expect(kinds.prefix(4) == ["h1", "p", "h1", "li(•)"])
        #expect(kinds.contains("li(◦x)") && kinds.contains("li(◦o)"))
        #expect(kinds.contains("table") && kinds.contains("hr") && kinds.contains("img") && kinds.contains("code(swift)"))
        #expect(kinds.contains("code(html)"), "HTML blocks stay readable as code")
        let table = blocks.compactMap { if case .table(let table) = $0.kind { table } else { nil } }.first
        #expect(table?.alignments == [.left, .right, .center])
        #expect(table?.rows.count == 2)
        #expect(table?.rows[1][2].runs.first?.link == "https://e.com")
        let quote = blocks.filter { $0.quoteDepth == 2 }
        #expect(quote.count == 1, "nested quote depth")
        let nested = blocks.first { if case .listItem(_, true, _) = $0.kind { true } else { false } }
        #expect(nested?.indent == 1)
        let code = blocks.compactMap { if case .code("swift", let code) = $0.kind { code } else { nil } }.first
        #expect(code?.contains("``` inside") == true)
    }

    @Test func inlineStylesAndLinks() {
        let blocks = MarkdownParser.blocks("Use **bold *both*** and `x` with [a](https://a.b) ~~gone~~.")
        guard case .paragraph(let text) = blocks.first?.kind else { Issue.record("no paragraph"); return }
        #expect(text.text == "Use bold both and x with a gone.")
        #expect(text.runs.contains { $0.traits == [.bold, .italic] })
        #expect(text.runs.contains { $0.traits == .code })
        #expect(text.link(at: (text.text as NSString).range(of: "a gone").location)?.url == "https://a.b")
        #expect(text.runs.contains { $0.traits == .strike })
    }

    @Test func sourceRangesCoverTopLevelBlocks() {
        let source = "# A\n\npara\n\n- x\n- y\n"
        let top = MarkdownParser.parse(source)
        #expect(top.map(\.sourceStart) == [0, 5, 11])
        #expect(top[2].blocks.count == 2)
    }
}

@Suite struct MarkdownStreamTests {
    /// Feeding the corpus split at every point, the streamed blocks after `finish` equal a one-shot parse, and every
    /// intermediate state equals the one-shot parse of what is displayed (the prefix-stability claim).
    @Test func everySplitPointMatchesOneShot() {
        let source = Corpus.markdown
        let expected = MarkdownParser.blocks(source)
        let utf8 = Array(source.utf8)
        var checkedIntermediate = 0
        for split in stride(from: 0, through: utf8.count, by: 1) {
            // Only split on character boundaries.
            guard split == utf8.count || (utf8[split] & 0xC0) != 0x80 else { continue }
            var stream = MarkdownStream()
            let first = String(decoding: utf8[..<split], as: UTF8.self)
            stream.update(first)
            if split % 7 == 0 {
                #expect(stream.blocks == MarkdownParser.blocks(stream.displayed), "intermediate at \(split)")
                checkedIntermediate += 1
            }
            stream.update(source)
            stream.finish(source)
            #expect(stream.blocks == expected, "split \(split)")
        }
        #expect(checkedIntermediate > 50)
    }

    /// Character-by-character streaming: each state equals the one-shot parse of the displayed prefix, the stable
    /// prefix only grows, and the finished result equals the one-shot parse.
    @Test func characterStreamIsPrefixStable() {
        let source = Corpus.markdown
        var stream = MarkdownStream()
        var text = ""
        var previousStable: [MarkdownBlock] = []
        for character in source {
            text.append(character)
            stream.update(text)
            let stable = Array(stream.blocks.prefix(stream.stableBlockCount))
            #expect(Array(stable.prefix(previousStable.count)) == previousStable, "stable prefix changed at \(text.count)")
            previousStable = stable
            if text.count % 5 == 0 {
                #expect(stream.blocks == MarkdownParser.blocks(stream.displayed), "at \(text.count)")
                #expect(text.hasPrefix(stream.displayed))
            }
        }
        stream.finish(source)
        #expect(stream.blocks == MarkdownParser.blocks(source))
    }

    @Test func lineBufferHoldsHeadingsMarkersAndTableHeaders() {
        #expect(MarkdownStream.displayPrefix("Intro\n\n## Heading\n") == "Intro\n\n")
        #expect(MarkdownStream.displayPrefix("Intro\n\n## Heading\nBody") == "Intro\n\n## Heading\n")
        #expect(MarkdownStream.displayPrefix("- a\n- \n") == "- a\n")
        #expect(MarkdownStream.displayPrefix("Text\n\n| a | b |\n") == "Text\n\n")
        #expect(MarkdownStream.displayPrefix("Text\n\n| a | b |\n|---|---|\n") == "Text\n\n| a | b |\n|---|---|\n")
        #expect(MarkdownStream.displayPrefix("```swift\nlet a = 1\nlet b") == "```swift\nlet a = 1\n", "partial code line waits")
        #expect(MarkdownStream.displayPrefix("A paragraph that is stil") == "A paragraph that is", "whole words of a paragraph")
        #expect(MarkdownStream.displayPrefix("Done.\n\n- ite") == "Done.\n\n", "a partial list line waits")
    }

    @Test func replacedSourceResets() {
        var stream = MarkdownStream()
        stream.update("# A\n\nfirst paragraph\n\nsecond\n")
        stream.update("Completely different\n\ntext\n")
        stream.finish("Completely different\n\ntext\n")
        #expect(stream.blocks == MarkdownParser.blocks("Completely different\n\ntext\n"))
    }

    @Test func referenceDefinitionsDisableIncrementalParsing() {
        let source = "See [docs][d] here.\n\nMore text.\n\n[d]: https://example.com\n"
        var stream = MarkdownStream()
        var text = ""
        for character in source {
            text.append(character)
            stream.update(text)
        }
        stream.finish(source)
        #expect(stream.blocks == MarkdownParser.blocks(source))
        guard case .paragraph(let first) = stream.blocks.first?.kind else { Issue.record("no paragraph"); return }
        #expect(first.runs.first?.link == "https://example.com")
    }
}
