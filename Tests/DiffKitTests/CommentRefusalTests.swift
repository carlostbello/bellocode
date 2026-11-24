import AppKit
import Engine
import Testing

@testable import DiffKit

/// R6-01 (docs/reviews/v1.0.2-astra-r6-check.md): a review comment the owner refuses (for example, the composer's draft
/// has not loaded) keeps its editor and text, and no line is marked; an accepted one closes the editor and marks the lines.
@MainActor @Suite(.timeLimit(.minutes(3))) struct CommentRefusalTests {
    final class Owner: DiffViewControllerDelegate {
        var accept = false
        var received: [DiffReviewComment] = []
        func diffViewController(_ controller: DiffViewController, revertHunk hunkIndex: Int, in file: DiffFile) {}
        func diffViewController(_ controller: DiffViewController, addComment comment: DiffReviewComment) -> Bool {
            received.append(comment)
            return accept
        }
        func diffViewController(_ controller: DiffViewController, open file: DiffFile, line: Int?) {}
    }

    static let file = DiffFile.compute(path: "Sources/App.swift", old: "let a = 1\n", new: "let a = 2\nlet b = 3\n")

    @Test func aRefusedCommentKeepsItsEditorAndMarksNothing() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let diff = DiffViewController()
        window.contentView = diff.view
        diff.view.frame = window.contentLayoutRect
        diff.view.layoutSubtreeIfNeeded()
        let owner = Owner()
        diff.delegate = owner
        await withCheckedContinuation { continuation in
            diff.onDisplay = {
                diff.onDisplay = nil
                continuation.resume()
            }
            diff.display([Self.file])
        }
        diff.selectLines(path: "Sources/App.swift", side: .new, 2...2)
        diff.beginComment()
        let editor = try #require(diff.pendingCommentEditor)
        editor.text = "Why 3?"

        editor.submit(nil)
        #expect(owner.received.map(\.text) == ["Why 3?"])
        #expect(diff.commentMarks.isEmpty, "a refused comment marks no line")
        #expect(diff.pendingCommentEditor === editor && editor.text == "Why 3?", "the editor keeps the text")

        owner.accept = true
        editor.submit(nil)
        #expect(owner.received.count == 2)
        #expect(diff.commentMarks.contains(DiffCommentMark(path: "Sources/App.swift", side: .new, line: 2)))
    }
}
