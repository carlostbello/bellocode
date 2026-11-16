// SPIKE G1-B tests: tail-only re-parse matches a full parse at every streaming step; layout offsets agree with the
// plain text used by selection and copy.

import CoreGraphics
import Testing
@testable import TranscriptKit

@Suite("Spike G1-B rows")
struct SpikeRowsTests {
    private func describe(_ block: SpikeBlock) -> String {
        switch block {
        case .prose(_, let kind): "prose(\(kind)):\(block.plainText(expanded: true))"
        case .code: "code:\(block.plainText(expanded: true))"
        case .table: "table:\(block.plainText(expanded: true))"
        default: "other:\(block.plainText(expanded: true))"
        }
    }

    @Test("Tail-only parse equals a full parse after every delta")
    func tailOnlyParseIsPrefixStable() {
        let script = String(SpikeWorkload.tailScript(minimumBytes: 6_000).prefix(6_000))
        let deltas = SpikeWorkload.tailDeltas(script)
        var source = ""
        var stableEnd = 0
        var stable: [SpikeBlock] = []
        for delta in deltas {
            source += delta
            let suffix = String(decoding: source.utf8.dropFirst(stableEnd), as: UTF8.self)
            let parsed = SpikeMarkdown.parse(suffix)
            if parsed.count >= 2 {
                stable += parsed[0..<(parsed.count - 1)].map(\.block)
                stableEnd += parsed[parsed.count - 1].sourceStart
            }
            let incremental = (stable + (parsed.last.map { [$0.block] } ?? [])).map(describe)
            let full = SpikeMarkdown.parse(source).map(\.block).map(describe)
            #expect(incremental == full)
            if incremental != full { return }
        }
    }

    @Test("Workload tail script and deltas are deterministic")
    func deterministic() {
        #expect(SpikeWorkload.tailScript(minimumBytes: 2_000) == SpikeWorkload.tailScript(minimumBytes: 2_000))
        let deltas = SpikeWorkload.tailDeltas(SpikeWorkload.tailScript(minimumBytes: 2_000))
        #expect(deltas.allSatisfy { (1...16).contains($0.count) || $0 == deltas.last })
    }

    @Test("Block layout lengths match the plain text used for selection and copy")
    func layoutMatchesPlainText() {
        let markdown = """
            ### Heading

            Some **bold** and `code` with a [link](https://example.com).

            - item one
              - nested item
            1. ordered

            | A | B |
            | --- | --- |
            | `x` | two words |

            ```swift
            let a = 1
            let b = "two"
            ```
            """
        let tool = SpikeTool(name: "bash", title: "swift build", status: .completed, output: "line 1\nline 2\nline 3",
                             expandedByDefault: false)
        let item = SpikeItem(id: 1, role: .assistant,
                             parts: [.markdown(markdown), .tool(tool), .reasoning("thinking text"), .diff("+a\n-b\n c")],
                             revision: 1)
        let theme = SpikeTheme(text: .black, secondary: .black, link: .black, codeBackground: .black, cardBackground: .black,
                               cardStroke: .black, userBubble: .black, keyword: .black, string: .black, comment: .black,
                               number: .black, diffAdd: .black, diffDel: .black, diffHunk: .black, error: .black, ok: .black,
                               selection: .black, findHighlight: .black)
        let fonts = SpikeFonts(theme: theme)
        for block in SpikeMarkdown.blocks(for: item) {
            for expanded in [false, true] {
                let layout = SpikeLayoutEngine.layoutBlock(block, expanded: expanded, imageSizes: [:], width: 500, fonts: fonts)
                #expect(layout.plainLength == block.plainText(expanded: expanded).utf16.count, "\(describe(block))")
                // Hitting far past the end lands on the end; far before the start lands on 0.
                #expect(layout.hitTest(CGPoint(x: 10_000, y: 100_000)) == layout.plainLength)
                #expect(layout.hitTest(CGPoint(x: -10, y: -100)) == 0)
            }
        }
    }

    @Test("Row selection ranges")
    func rowSelection() {
        let selection = SpikeRowSelection(startBlock: 1, startOffset: 3, endBlock: 2, endOffset: 4)
        #expect(selection.range(forBlock: 0, length: 10) == nil)
        #expect(selection.range(forBlock: 1, length: 10) == 3..<11)  // continues past the block
        #expect(selection.range(forBlock: 2, length: 10) == 0..<4)
        #expect(selection.range(forBlock: 3, length: 10) == nil)
    }
}
