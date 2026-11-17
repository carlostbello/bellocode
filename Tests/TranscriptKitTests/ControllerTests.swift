import AppKit
import BelloCore
import Foundation
import Testing

@testable import TranscriptKit

/// The production controller in a real (offscreen) window: geometry, anchoring, follow, streaming, find and copy.
@Suite(.serialized) @MainActor struct ControllerTests {
    @MainActor final class Harness {
        let window: NSWindow
        let viewController: TranscriptViewController
        let source: StaticTranscriptSource
        var controller: TranscriptController { viewController.controller }

        init(messages: [Message], older: [[Message]] = [], size: NSSize = NSSize(width: 800, height: 600)) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            viewController = TranscriptViewController()
            window.contentViewController = viewController
            window.setContentSize(size)
            viewController.view.layoutSubtreeIfNeeded()
            source = StaticTranscriptSource(messages: messages, older: older)
            viewController.controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("transcript-tests-\(UUID().uuidString)"))
            viewController.bind(source)
        }

        func settle() async { await controller.settle() }

        func close() {
            controller.close()
            window.close()
        }
    }

    static func longTranscript(turns: Int) -> [Message] {
        var builder = TranscriptSamples.Builder()
        for turn in 0..<turns {
            builder.user("Question \(turn): how does the anchor behave when content above changes?")
            builder.assistant([
                .tool(name: "read", input: #"{"filePath":"a\#(turn).swift"}"#, output: "line\nline\nline", status: .completed),
                .tool(name: "bash", input: #"{"command":"swift test"}"#, output: "ok", status: .completed),
            ])
            builder.assistant([.text("Answer \(turn). " + String(repeating: "The viewport keeps its anchor. ", count: 6 + turn % 5) + "\n\n```swift\nlet turn = \(turn)\n```")])
        }
        return builder.messages
    }

    /// NSTableView estimates row offsets it has not been asked for; `forceTableGeometry` must keep the table's
    /// geometry exactly equal to the model's heights (the G1-B spike's regression test).
    @Test func tableGeometryMatchesTheModelExactly() async {
        let harness = Harness(messages: Self.longTranscript(turns: 120))
        defer { harness.close() }
        await harness.settle()
        let controller = harness.controller
        #expect(controller.rows.count > 300)
        for index in stride(from: 0, to: controller.rows.count, by: 7) {
            #expect(abs(controller.tableOffset(ofRow: index) - controller.modelOffset(ofRow: index)) < 0.01, "row \(index)")
        }
        // Expand a group far above and check again.
        let groups = controller.rows.filter { if case .work = $0.content { true } else { false } }
        controller.toggle(row: groups[3].id, key: .group)
        controller.flushHeights()
        for index in stride(from: 0, to: controller.rows.count, by: 5) {
            #expect(abs(controller.tableOffset(ofRow: index) - controller.modelOffset(ofRow: index)) < 0.01, "row \(index) after expand")
        }
    }

    @Test func opensAtTheBottomFollowingAndShowsNoPill() async {
        let harness = Harness(messages: Self.longTranscript(turns: 40))
        defer { harness.close() }
        await harness.settle()
        #expect(harness.controller.following)
        #expect(abs(harness.controller.distanceFromBottom) < 1)
        #expect(!harness.controller.isJumpPillVisible)
    }

    /// Height changes above the viewport (expansion, measured heights, a prepended page) move nothing on screen.
    @Test func anchorHoldsWhenContentAboveChanges() async {
        let older = [Array(Self.longTranscript(turns: 10).map { message in
            var copy = message
            copy.id = MessageID("old_" + message.id.rawValue)
            copy.parts = message.parts.map { part in
                var part = part
                part.id = PartID("old_" + part.id.rawValue)
                return part
            }
            copy.created = Timestamp(milliseconds: message.created.milliseconds - 1e9)
            return copy
        })]
        let harness = Harness(messages: Self.longTranscript(turns: 60), older: older)
        defer { harness.close() }
        await harness.settle()
        let controller = harness.controller
        controller.userScroll(by: -2_500)
        await harness.settle()
        #expect(!controller.following)
        func topRow() -> (RowID, CGFloat) {
            let visible = controller.scrollView.contentView.bounds
            let row = controller.tableView.row(at: NSPoint(x: 1, y: visible.minY + 1)) - 1
            return (controller.rows[row].id, controller.rowRect(row).minY - visible.minY)
        }
        let before = topRow()
        // Expand a group above the viewport.
        let visibleTop = controller.tableView.row(at: NSPoint(x: 1, y: controller.scrollView.contentView.bounds.minY)) - 1
        if let above = controller.rows[..<max(0, visibleTop - 3)].last(where: { if case .work = $0.content { true } else { false } }) {
            controller.toggle(row: above.id, key: .group)
        }
        await harness.settle()
        let afterExpand = topRow()
        #expect(afterExpand.0 == before.0 && abs(afterExpand.1 - before.1) < 0.5, "expand above: \(before) → \(afterExpand)")
        // Prepend an older page.
        await harness.source.transcriptLoadOlder()
        await harness.settle()
        let afterPrepend = topRow()
        #expect(afterPrepend.0 == before.0 && abs(afterPrepend.1 - before.1) < 0.5, "prepend: \(before) → \(afterPrepend)")
        #expect(controller.rows.first?.id.rawValue.contains("old_") == true)
    }

    /// Streaming: following stays at the bottom with 0 pt distance, the tail re-renders alone, and the finished rows
    /// equal a one-shot parse; scrolling up releases and shows the pill; jump-to-latest rejoins.
    @Test func streamingFollowsReleasesAndRejoins() async {
        let base = Self.longTranscript(turns: 20)
        let harness = Harness(messages: base)
        defer { harness.close() }
        await harness.settle()
        let controller = harness.controller
        let id = MessageID("msg_stream")
        let user = Message(id: MessageID("msg_user_s"), sessionID: TranscriptSamples.session, kind: .user(UserContent(text: "Stream please")), created: Timestamp(milliseconds: 1.9e12))
        harness.source.update(user)
        await harness.settle()
        let full = TranscriptSamples.markdownReply + "\n\n" + Corpus.markdown
        let utf8 = Array(full.utf8)
        var revision = 1
        var position = 0
        var tailRowsSeen = Set<RowID>()
        while position < utf8.count {
            position = min(utf8.count, position + 97)
            while position < utf8.count, (utf8[position] & 0xC0) == 0x80 { position += 1 }
            revision += 1
            let text = String(decoding: utf8[..<position], as: UTF8.self)
            let streaming = position < utf8.count
            let part = Part(id: Part.makeID(message: id, .text(ordinal: 0)), index: 0, content: .text(text), isStreaming: streaming)
            harness.source.update(
                Message(id: id, sessionID: TranscriptSamples.session, kind: .assistant(AssistantInfo(isOpen: streaming)), created: Timestamp(milliseconds: 1.9e12 + 1), parts: [part], revision: revision))
            await harness.settle()
            tailRowsSeen.formUnion(controller.streamingRowIDs)
            #expect(controller.following)
            #expect(abs(controller.distanceFromBottom) < 1, "distance \(controller.distanceFromBottom) at \(position)")
        }
        await harness.settle()
        #expect(tailRowsSeen.count == 1, "only the tail row streams")
        #expect(controller.streamingRowIDs.isEmpty, "the tail is reconciled at completion")
        let tailID = RowID.part(Part.makeID(message: id, .text(ordinal: 0)))
        let index = try! #require(controller.rows.firstIndex { $0.id == tailID })
        #expect(controller.blocks(row: index) == MarkdownParser.blocks(full).map { RenderBlock(.markdown($0, tone: .normal)) })

        // Release by scrolling up; the pill appears (debounced) and new output marks it.
        controller.userScroll(by: -800)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(!controller.following)
        #expect(controller.isJumpPillVisible)
        controller.jumpToLatest()
        #expect(controller.following && !controller.isJumpPillVisible)
        #expect(abs(controller.distanceFromBottom) < 1)
    }

    @Test func newTurnAnchorsThePromptNearTheTop() async {
        let harness = Harness(messages: Self.longTranscript(turns: 10), size: NSSize(width: 800, height: 700))
        defer { harness.close() }
        await harness.settle()
        let controller = harness.controller
        let user = Message(
            id: MessageID("msg_new"), sessionID: TranscriptSamples.session, kind: .user(UserContent(text: "A new question")),
            created: Timestamp(milliseconds: 1.95e12), delivery: .sending)
        harness.source.update(user)
        await harness.settle()
        let index = try! #require(controller.rows.firstIndex { $0.id == RowID.message(MessageID("msg_new")) })
        let rowTop = controller.rowRect(index).minY + TranscriptTheme.turnGap
        let top = controller.scrollView.contentView.bounds.minY
        #expect(abs(rowTop - top - 12) < 2, "prompt at the top: \(rowTop - top)")
        #expect(controller.following)
    }

    @Test func selectionCopyAndCommands() async {
        let harness = Harness(messages: TranscriptSamples.mixed(), size: NSSize(width: 900, height: 1400))
        defer { harness.close() }
        await harness.settle()
        let controller = harness.controller
        controller.selectAll()
        let text = controller.selectedText()
        #expect(text.hasPrefix("The streaming transcript jumps"))
        #expect(text.contains("I found the problem."))
        #expect(text.contains("File\tChange\tLines"))
        #expect(!text.contains("Test run with"), "collapsed tool output is not copied")
        controller.copySelection()
        #expect(controller.pasteboard.string(forType: .string) == text)
        #expect(controller.pasteboard.string(forType: .markdown)?.contains("| File | Change | Lines |") == true)
        // Copy Message on the reply copies its Markdown.
        controller.clearSelection()
        let reply = try! #require(controller.rows.firstIndex { if case .markdown = $0.content { true } else { false } })
        controller.select(from: TranscriptPosition(rowID: controller.rows[reply].id, block: 0, offset: 0), to: TranscriptPosition(rowID: controller.rows[reply].id, block: 0, offset: 1))
        controller.copyAsMarkdown()
        #expect(controller.pasteboard.string(forType: .string) == "I")
        controller.clearSelection()
        controller.contextRow = controller.rows[reply].id
        controller.copyMessage()
        #expect(controller.pasteboard.string(forType: .markdown)?.contains("## What changed") == true)
        // Copy Code.
        let code = try! #require(controller.blocks(row: reply).firstIndex { if case .markdown(let block, _) = $0.kind, case .code = block.kind { true } else { false } })
        controller.contextCode = (controller.rows[reply].id, code)
        controller.copyCode()
        #expect(controller.pasteboard.string(forType: .string)?.hasPrefix("func update(") == true)
        // Turn navigation and last failure.
        controller.goToTurn(previous: true)
        #expect(controller.hasFailure)
        controller.goToLastFailure()
        #expect(!controller.following || controller.distanceFromBottom <= 2)
    }

    @Test func findRevealsMatchesInsideCollapsedContent() async {
        let harness = Harness(messages: TranscriptSamples.mixed(), size: NSSize(width: 900, height: 500))
        defer { harness.close() }
        await harness.settle()
        let controller = harness.controller
        controller.showFind()
        controller.setFindQuery("5 tests passed", debounce: false)
        for _ in 0..<50 where controller.findMatches.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        await harness.settle()
        #expect(controller.findMatches.count == 1)
        let match = controller.findMatches[0]
        #expect(controller.isExpanded(row: match.rowID, key: .group))
        if case .work(let group)? = controller.rows.first(where: { $0.id == match.rowID })?.content, let bash = group.items.first(where: { $0.name == "bash" }) {
            #expect(controller.isExpanded(row: match.rowID, key: .tool(bash.id)))
        }
        let rect = try! #require(controller.visibleRectOfCurrentMatch())
        #expect(controller.scrollView.bounds.intersects(rect), "the match is on screen")
        controller.closeFind()
        #expect(controller.findMatches.isEmpty)
    }

    @Test func restorationAnchorRoundTrips() async {
        let messages = Self.longTranscript(turns: 50)
        let harness = Harness(messages: messages)
        defer { harness.close() }
        await harness.settle()
        #expect(harness.controller.scrollAnchor == nil, "at the bottom")
        harness.controller.userScroll(by: -3_000)
        await harness.settle()
        let anchor = try! #require(harness.controller.scrollAnchor)
        let second = Harness(messages: messages)
        defer { second.close() }
        second.controller.restore(anchor: anchor)
        await second.settle()
        let restored = try! #require(second.controller.scrollAnchor)
        #expect(restored.messageID == anchor.messageID)
        #expect(abs(restored.offset - anchor.offset) < 1)
    }

    @Test func emptyThreadShowsTheEmptyState() async {
        let harness = Harness(messages: [])
        defer { harness.close() }
        await harness.settle()
        #expect(!harness.controller.emptyLabel.isHidden)
    }
}
