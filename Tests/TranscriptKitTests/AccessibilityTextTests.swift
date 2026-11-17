import AppKit
import BelloCore
import Foundation
import Testing

@testable import TranscriptKit

/// Review finding m2 (docs/reviews/M2-M4-review.md): each row is a static-text accessibility element with the
/// parameterized text attributes (string, line and bounds for a range, selection), backed by the row's layout.
/// Exercised through the NSAccessibility methods AppKit's accessibility bridge calls; VoiceOver itself is not run.
@Suite(.serialized) @MainActor struct AccessibilityTextTests {
    static let prose = String(repeating: "Wrapped prose keeps going across the column so that it needs several lines. ", count: 8)

    static func messages() -> [Message] {
        var builder = TranscriptSamples.Builder()
        builder.user("Explain the module")
        builder.assistant([.text("# Overview\n\n\(prose)\n\n```swift\nlet first = 1\nlet second = 2\nlet third = first + second\n```\n\nDone.")])
        return builder.messages
    }

    func replyCell(_ harness: ControllerTests.Harness) throws -> (cell: TranscriptCellView, index: Int) {
        let controller = harness.controller
        let index = try #require(controller.rows.firstIndex { if case .markdown = $0.content { true } else { false } })
        let cell = try #require(controller.cellView(index))
        return (cell, index)
    }

    @Test func rowsExposeTextByLineRangeAndBounds() async throws {
        let harness = ControllerTests.Harness(messages: Self.messages(), size: NSSize(width: 700, height: 900))
        defer { harness.close() }
        await harness.settle()
        let (cell, _) = try replyCell(harness)
        #expect(cell.isAccessibilityElement())
        #expect(cell.accessibilityRole() == .staticText)
        let value = try #require(cell.accessibilityValue() as? String)
        let string = value as NSString
        #expect(value.hasPrefix("Overview\n"))
        #expect(value.contains("let third = first + second"))
        #expect(cell.accessibilityNumberOfCharacters() == string.length)
        #expect(cell.accessibilityString(for: NSRange(location: 0, length: 8)) == "Overview")
        #expect(cell.accessibilityAttributedString(for: NSRange(location: 0, length: 8))?.string == "Overview")

        // Lines tile the text in order; wrapped prose yields more lines than it has newlines.
        var lines: [NSRange] = []
        var line = 0
        while lines.count < 200, case let range = cell.accessibilityRange(forLine: line), range.location != NSNotFound {
            lines.append(range)
            line += 1
            if range.location + range.length >= string.length { break }
        }
        #expect(lines.first?.location == 0)
        for (a, b) in zip(lines, lines.dropFirst()) { #expect(a.location + a.length == b.location, "lines are contiguous") }
        #expect(lines.last.map { $0.location + $0.length } == string.length)
        let proseStart = string.range(of: "Wrapped prose").location
        let proseLines = lines.filter { $0.location >= proseStart && $0.location < proseStart + (Self.prose as NSString).length }
        #expect(proseLines.count >= 3, "the paragraph wraps into \(proseLines.count) lines")
        for (number, range) in lines.enumerated() {
            #expect(cell.accessibilityLine(for: range.location) == number)
            if range.length > 1 { #expect(cell.accessibilityLine(for: range.location + range.length - 1) == number) }
        }
        let codeLine = try #require(lines.firstIndex { string.substring(with: $0).hasPrefix("let second = 2") })
        #expect(string.substring(with: lines[codeLine]).hasPrefix("let second = 2"), "monospaced lines come from the layout")

        // Bounds: each line has a frame inside the row, stacked top to bottom (screen y grows upwards).
        let rowFrame = try #require(cell.window).convertToScreen(cell.convert(cell.bounds, to: nil))
        var previousTop = CGFloat.greatestFiniteMagnitude
        for range in lines where range.length > 1 {
            let frame = cell.accessibilityFrame(for: NSRange(location: range.location, length: range.length - 1))
            #expect(frame.width > 1 && frame.height > 1)
            #expect(rowFrame.insetBy(dx: -1, dy: -1).contains(frame), "line frame \(frame) inside row \(rowFrame)")
            #expect(frame.maxY <= previousTop + 0.5)
            previousTop = frame.maxY
        }
        // Range for a point: the middle of a word of the second code line maps back into that line.
        let target = lines[codeLine]
        let wordFrame = cell.accessibilityFrame(for: NSRange(location: target.location + 4, length: 6))
        let hit = cell.accessibilityRange(for: NSPoint(x: wordFrame.midX, y: wordFrame.midY))
        #expect(hit.location >= target.location + 4 && hit.location <= target.location + 10, "hit \(hit) for \(target)")
        #expect(cell.accessibilityRange(for: 0) == NSRange(location: 0, length: 1))
        #expect(cell.accessibilityStyleRange(for: 0) == NSRange(location: 0, length: 8), "a style run is a block")
        #expect(cell.accessibilityVisibleCharacterRange() == NSRange(location: 0, length: string.length))
    }

    @Test func accessibilitySelectionIsTheTranscriptSelection() async throws {
        let harness = ControllerTests.Harness(messages: Self.messages(), size: NSSize(width: 700, height: 900))
        defer { harness.close() }
        await harness.settle()
        let controller = harness.controller
        let (cell, _) = try replyCell(harness)
        let string = try #require(cell.accessibilityValue() as? String) as NSString
        let range = string.range(of: "let third = first")
        cell.setAccessibilitySelectedTextRange(range)
        #expect(controller.selectedText() == "let third = first")
        #expect(cell.accessibilitySelectedTextRange() == range)
        #expect(cell.accessibilitySelectedText() == "let third = first")
        #expect(cell.accessibilityInsertionPointLineNumber() == cell.accessibilityLine(for: range.location))
        // A selection made with the mouse or keyboard reads back through accessibility.
        controller.selectAll()
        #expect(cell.accessibilitySelectedTextRange() == NSRange(location: 0, length: string.length))
        controller.clearSelection()
        #expect(cell.accessibilitySelectedText() == nil)
    }

    /// The text follows streaming, and a finished reply is announced once (not per token, not again on later
    /// revisions).
    @Test func streamingReplyUpdatesTextAndIsAnnouncedOnce() async throws {
        let harness = ControllerTests.Harness(messages: Self.messages(), size: NSSize(width: 700, height: 900))
        defer { harness.close() }
        await harness.settle()
        let controller = harness.controller
        let id = MessageID("msg_live")
        let partID = Part.makeID(message: id, .text(ordinal: 0))
        var text = ""
        for revision in 1...12 {
            text += "Token \(revision) arrives. "
            let streaming = revision < 12
            harness.source.update(
                Message(
                    id: id, sessionID: TranscriptSamples.session, kind: .assistant(AssistantInfo(isOpen: streaming)),
                    created: Timestamp(milliseconds: 1.9e12), parts: [Part(id: partID, index: 0, content: .text(text), isStreaming: streaming)],
                    revision: revision))
            await harness.settle()
        }
        let index = try #require(controller.rowIndex[.part(partID)])
        let cell = try #require(controller.cellView(index))
        #expect((cell.accessibilityValue() as? String) == text.trimmingCharacters(in: .whitespaces))
        #expect(controller.announcementCount == 1)
        harness.source.update(
            Message(
                id: id, sessionID: TranscriptSamples.session, kind: .assistant(AssistantInfo(isOpen: false)),
                created: Timestamp(milliseconds: 1.9e12), parts: [Part(id: partID, index: 0, content: .text(text + "Edited."))], revision: 13))
        await harness.settle()
        #expect(controller.announcementCount == 1, "a later revision is not announced again")
    }

    /// A reply far taller than the viewport: lines come from the monospaced layout arithmetically, the visible range
    /// is the part on screen, and off-screen lines of the row still have bounds (no other row is materialised).
    @Test func tallRowsReportTheirVisiblePart() async throws {
        var builder = TranscriptSamples.Builder()
        builder.user("Dump it")
        let code = (1...3_000).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        builder.assistant([.text("Start.\n\n```swift\n\(code)\n```\n\nEnd of dump.")])
        let harness = ControllerTests.Harness(messages: builder.messages, size: NSSize(width: 700, height: 600))
        defer { harness.close() }
        await harness.settle()
        let (cell, _) = try replyCell(harness)
        let string = try #require(cell.accessibilityValue() as? String) as NSString
        let lastLine = cell.accessibilityLine(for: string.length - 1)
        #expect(lastLine >= 3_000, "one line per code line: \(lastLine)")
        let visible = cell.accessibilityVisibleCharacterRange()
        #expect(visible.length > 0 && visible.length < string.length / 10, "visible \(visible) of \(string.length)")
        #expect(visible.location + visible.length == string.length, "the end of the reply is on screen (following)")
        let line500 = cell.accessibilityRange(forLine: cell.accessibilityLine(for: string.range(of: "let line500 =").location))
        #expect(string.substring(with: line500).hasPrefix("let line500 = 500"))
        let frame = cell.accessibilityFrame(for: line500)
        #expect(frame.height > 1 && frame.height < 40, "an off-screen line has its own bounds: \(frame)")
    }
}
